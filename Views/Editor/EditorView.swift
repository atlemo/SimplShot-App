import SwiftUI
import StoreKit
import UniformTypeIdentifiers
import AppKit
import CoreImage
import ImageIO
import PDFKit
#if !APPSTORE
import WebP
#endif

/// Root view for the screenshot editor window.
struct EditorView: View {
    /// All image URLs loaded into this editor session.
    let imageURLs: [URL]

    /// Template for applying a background. Falls back to `.default` so the
    /// editor can always add/change a gradient even when no template was passed.
    let template: ScreenshotTemplate

    /// Optional app settings for reading/writing persisted editor preferences.
    var appSettings: AppSettings?

    /// When true, start with "Original" aspect ratio regardless of app defaults.
    var preferOriginalAspectRatio: Bool = false

    /// Callback when the editor is done (save or discard) — closes the window.
    var onDismiss: () -> Void = {}
    var onModeChange: (EditorMode) -> Void = { _ in }
    var onEditModeAvailabilityChange: (Bool) -> Void = { _ in }

    // Multi-image session state
    @State private var sessions: [ImageSession] = []
    @State private var activeSessionID: UUID?
    /// Set to true while restoreSessionState is mutating @State, so the
    /// onChange observers don't treat session-switches as user edits
    /// (which would re-shift annotations or overwrite app defaults).
    @State private var isRestoringSession: Bool = false
    /// Set while a coalesced display re-render is already queued, so the many
    /// template-property onChange handlers that fire together (e.g. applying a
    /// template changes ~7 settings at once) trigger only one render.
    @State private var displayRefreshScheduled: Bool = false

    private var activeSession: ImageSession? {
        sessions.first(where: { $0.id == activeSessionID })
    }

    /// Convenience accessor — the active session's URL.
    private var imageURL: URL {
        activeSession?.imageURL ?? imageURLs[0]
    }

    /// True when the active session is a PDF page — hides template/background UI.
    private var isPDFSession: Bool {
        activeSession?.isPDF ?? false
    }

    /// True if the active PDF document (all sessions sharing pdfGroupID) has any
    /// edits. Active-session edits live in @State; other-session edits live on
    /// the ImageSession itself. Used to switch the toolbar's "Save All" → "Done"
    /// when nothing has been changed.
    private var activeSessionHasEdits: Bool {
        if !annotations.isEmpty { return true }
        if !photoAdjustments.isDefault { return true }
        if watermarkSettings.isEnabled { return true }
        if selectedWallpaper != nil { return true }
        if !undoStack.isEmpty { return true }
        return false
    }

    private var anySessionHasEdits: Bool {
        if activeSessionHasEdits { return true }
        for session in sessions where session.id != activeSessionID {
            if sessionHasEdits(session) { return true }
        }
        return false
    }

    private var pdfDocumentHasEdits: Bool {
        guard let groupID = activeSession?.pdfGroupID else { return false }
        // Active session — @State is the live source of truth for these fields.
        if !annotations.isEmpty { return true }
        if photoAdjustments != .default { return true }
        if watermarkSettings.isEnabled { return true }
        if !undoStack.isEmpty { return true }
        // Other pages in the same PDF group — read directly from ImageSession.
        for session in sessions where session.pdfGroupID == groupID && session.id != activeSessionID {
            if !session.annotations.isEmpty { return true }
            if session.photoAdjustments != .default { return true }
            if session.watermarkSettings.isEnabled { return true }
        }
        return false
    }

    @State private var image: NSImage?
    @State private var rawImage: NSImage?
    @State private var currentDisplayCGImage: CGImage?
    @State private var imageMetadata: ImageMetadata?
    @State private var imagePixelSize: CGSize = .zero
    /// The display's backing scale factor (e.g. 2.0 on Retina, 3.0 on 3× displays).
    /// Used to compute "true size" — where 100% shows the image at its logical point dimensions.
    @State private var displayBackingScale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2.0
    /// nil = no background; non-nil = background enabled with that wallpaper.
    @State private var selectedWallpaper: WallpaperSource? = nil
    /// Local copies of template padding/cornerRadius for live editing in the bottom toolbar.
    @State private var editorAspectRatioID: UUID? = nil
    @State private var editorPadding: Int = 80
    @State private var editorCornerRadius: Int = 24

    /// Persistent renderer so `flattenNativeCorners` cache survives across slider ticks.
    @State private var templateRenderer = TemplateRenderer()

    // Annotation state
    @State private var annotations: [Annotation] = []
    @State private var selectedAnnotationID: UUID?
    @State private var currentTool: AnnotationTool = .freeDraw
    @State private var currentStyle: AnnotationStyle = AnnotationStyle()

    // Crop state
    @State private var isCropping: Bool = false
    @State private var cropRect: CGRect = .zero
    /// Selected crop aspect-ratio preset (`.free` = unconstrained).
    @State private var cropAspectPreset: CropAspectPreset = .free
    /// Non-destructive crop in raw screenshot pixel space.
    /// Applied before the gradient so rawImage is never mutated by crop.
    @State private var screenshotCropRect: CGRect = .zero
    /// Saved crop rect before entering crop mode, so cancel restores it.
    @State private var preCropScreenshotCropRect: CGRect = .zero
    /// Pre-crop undo snapshot, captured at the start of enterCropMode() so that
    /// applyCrop() can push the correct pre-crop state rather than the expanded-image state.
    @State private var preCropSnapshot: EditorSnapshot? = nil

    // Zoom state
    @State private var zoomLevel: CGFloat = 1.0  // 1.0 = fit to view
    @State private var fitScale: CGFloat = 0.5   // computed base scale to fit image
    @State private var lastViewSize: CGSize = .zero  // cached for re-fitting after image swap

    @Environment(\.requestReview) private var requestReview

    // 3-in-1 mode state
    /// The active editor mode. Controls which sidebar content and canvas interactions are shown.
    /// Initialized in `init` from the explicit `initialMode` or `.annotate` as the fallback.
    @State private var editorMode: EditorMode
    /// Non-destructive photo adjustments applied via Core Image in the display pipeline.
    @State private var photoAdjustments: PhotoAdjustments = .default
    /// Number of 90° clockwise rotations applied to the raw image (0–3).
    /// Applied at the top of the display pipeline; screenshotCropRect and
    /// annotations live in the rotated-raw coordinate space.
    @State private var rotationSteps: Int = 0
    /// Shared Core Image context for photo adjustments. Created once, reused every frame.
    @State private var ciContext: CIContext = CIContext()

    // Sidebar — always Pro mode (simple floating toolbar has been removed).
    // NavigationSplitView drives sidebar visibility; showProSidebar is a derived bool.
    @State private var columnVisibility: NavigationSplitViewVisibility
    @State private var shadowIntensity: Double = 1.0
    @State private var screenshotAlignment: CanvasAlignment = .middleCenter
    @State private var watermarkSettings: WatermarkSettings = WatermarkSettings()

    init(
        imageURL: URL,
        template: ScreenshotTemplate? = nil,
        appSettings: AppSettings? = nil,
        preferOriginalAspectRatio: Bool = false,
        initialMode: EditorMode? = nil,
        onDismiss: @escaping () -> Void = {},
        onModeChange: @escaping (EditorMode) -> Void = { _ in },
        onEditModeAvailabilityChange: @escaping (Bool) -> Void = { _ in }
    ) {
        self.init(
            imageURLs: [imageURL],
            template: template,
            appSettings: appSettings,
            preferOriginalAspectRatio: preferOriginalAspectRatio,
            initialMode: initialMode,
            onDismiss: onDismiss,
            onModeChange: onModeChange,
            onEditModeAvailabilityChange: onEditModeAvailabilityChange
        )
    }

    init(
        imageURLs: [URL],
        template: ScreenshotTemplate? = nil,
        appSettings: AppSettings? = nil,
        preferOriginalAspectRatio: Bool = false,
        initialMode: EditorMode? = nil,
        onDismiss: @escaping () -> Void = {},
        onModeChange: @escaping (EditorMode) -> Void = { _ in },
        onEditModeAvailabilityChange: @escaping (Bool) -> Void = { _ in }
    ) {
        precondition(!imageURLs.isEmpty, "EditorView requires at least one image URL")
        self.imageURLs = imageURLs
        let resolvedTemplate = template ?? appSettings?.defaultCaptureTemplate ?? .default
        self.template = resolvedTemplate
        self.appSettings = appSettings
        self.preferOriginalAspectRatio = preferOriginalAspectRatio
        self.onDismiss = onDismiss
        self.onModeChange = onModeChange
        self.onEditModeAvailabilityChange = onEditModeAvailabilityChange

        let newSessions = imageURLs.map { ImageSession(imageURL: $0) }
        _sessions = State(initialValue: newSessions)
        _activeSessionID = State(initialValue: newSessions.first?.id)

        // Resolve the starting editor mode: explicit caller override > Annotate default.
        // Callers that go through the user's preference (e.g. AppDelegate when opening
        // from Finder) resolve the setting themselves and pass the concrete mode in.
        _editorMode = State(initialValue: initialMode ?? .annotate)

        // Always start with the sidebar shown — simple mode has been removed.
        _columnVisibility = State(initialValue: .all)
        _watermarkSettings = State(initialValue: resolvedTemplate.watermarkSettings)
#if !APPSTORE
        _editorAspectRatioID = State(initialValue:
            preferOriginalAspectRatio ? nil : appSettings?.selectedRatioID
        )
#endif
    }

    init(
        sessions: [ImageSession],
        appSettings: AppSettings? = nil,
        onDismiss: @escaping () -> Void = {},
        onModeChange: @escaping (EditorMode) -> Void = { _ in },
        onEditModeAvailabilityChange: @escaping (Bool) -> Void = { _ in }
    ) {
        precondition(!sessions.isEmpty, "EditorView requires at least one session")
        self.imageURLs = sessions.map { $0.imageURL }
        self.template = appSettings?.defaultCaptureTemplate ?? .default
        self.appSettings = appSettings
        self.preferOriginalAspectRatio = false
        self.onDismiss = onDismiss
        self.onModeChange = onModeChange
        self.onEditModeAvailabilityChange = onEditModeAvailabilityChange

        _sessions = State(initialValue: sessions)
        _activeSessionID = State(initialValue: sessions.first?.id)
        _editorMode = State(initialValue: .annotate)
        _columnVisibility = State(initialValue: .all)
        _watermarkSettings = State(initialValue: WatermarkSettings())
    }

    private var showProSidebar: Bool { columnVisibility != .detailOnly }
    /// Binding<Bool> adapter so child views (toolbar, sidebar) don't need to know
    /// about NavigationSplitViewVisibility directly.
    private var showProSidebarBinding: Binding<Bool> {
        Binding(
            get: { columnVisibility != .detailOnly },
            set: { columnVisibility = $0 ? .all : .detailOnly }
        )
    }

    // Undo
    @State private var undoStack: [EditorSnapshot] = []

    // Alerts
    @State private var showTrashAlert: Bool = false
    @State private var keyMonitor: Any?
    @State private var magnifyMonitor: Any?
    @State private var middleMouseMonitor: Any?
    @State private var flagsMonitor: Any?
    @State private var showingCopyCursor: Bool = false
    @State private var middleMouseDragOrigin: NSPoint?
    @State private var middleMouseScrollOrigin: NSPoint?
    @State private var nsScrollView: NSScrollView?
    @State private var canvasViewportFrame: CGRect = .zero
    /// The NSWindow hosting this editor. Captured via WindowAccessor so the
    /// local key-event monitor can scope its handling to events targeted at
    /// this window (when multiple editor windows are open).
    @State private var hostingWindow: NSWindow?


    /// The actual scale applied to the image: fitScale * zoomLevel.
    /// Units: view-points per image-pixel.
    private var effectiveScale: CGFloat {
        fitScale * zoomLevel
    }

    /// The zoom percentage relative to "true size" (1:1 with the original window).
    /// True size is when effectiveScale == 1/backingScale.
    private var displayZoomPercent: CGFloat {
        let trueSizeScale = 1.0 / displayBackingScale
        guard trueSizeScale > 0 else { return 100 }
        return effectiveScale / trueSizeScale * 100
    }

    /// The screenshot content's bounding rect inside the display canvas, in image-pixel space.
    /// When a gradient is active this is the inset screenshot region; otherwise the full canvas.
    private var screenshotBoundsInDisplay: CGRect {
        if selectedWallpaper != nil, !screenshotCropRect.isEmpty {
            let offset = screenshotOriginInTemplatedCanvas(
                screenshotPixelSize: screenshotCropRect.size,
                padding: editorPadding,
                aspectRatio: selectedEditorAspectRatio?.ratio,
                alignment: screenshotAlignment
            )
            return CGRect(x: offset.x, y: offset.y,
                          width: screenshotCropRect.width, height: screenshotCropRect.height)
        }
        return CGRect(origin: .zero, size: imagePixelSize)
    }

    private let zoomSteps: [CGFloat] = [0.25, 0.5, 0.75, 1.0, 1.5, 2.0, 3.0]
    private let minZoomLevel: CGFloat = 0.25
    private let maxZoomLevel: CGFloat = 5.0
    private var editorAspectRatios: [AspectRatio] {
#if !APPSTORE
        appSettings?.enabledAspectRatios ?? Constants.defaultAspectRatios
#else
        Constants.defaultAspectRatios
#endif
    }
    private var selectedEditorAspectRatio: AspectRatio? {
        guard let id = editorAspectRatioID else { return nil }
        return editorAspectRatios.first(where: { $0.id == id })
    }
    private var hasUnsavedTemplateChanges: Bool {
        guard let template = appSettings?.selectedEditorTemplate else { return false }
        return template.wallpaperSource != selectedWallpaper
            || template.padding != editorPadding
            || template.cornerRadius != editorCornerRadius
            || template.shadowIntensity != shadowIntensity
            || template.aspectRatioID != editorAspectRatioID
            || template.alignment != screenshotAlignment
            || template.watermarkSettings != watermarkSettings
    }

    var body: some View {
        bodyWithObservers
    }

    // Split into two computed properties to help the Swift type checker
    // with the long chain of .onChange modifiers.

    private var bodyBase: some View {
        navigationContent
            .onAppear {
            if let appSettings {
                editorPadding = template.padding
                editorCornerRadius = template.cornerRadius
                if appSettings.editorUseTemplateBackground || appSettings.screenshotTemplate.isEnabled {
                    selectedWallpaper = template.wallpaperSource
                }
                if let savedTemplate = appSettings.selectedEditorTemplate {
                    applyEditorTemplate(savedTemplate)
                }
            }
            loadImage()
            propagateInitialTemplateToOtherSessions()
            preloadThumbnails()
            installKeyMonitorIfNeeded()
            onModeChange(editorMode)
            onEditModeAvailabilityChange(!isPDFSession)
        }
        .background(WindowAccessor { hostingWindow = $0 })
        .onReceive(NotificationCenter.default.publisher(for: .editorModeCommand)) { notification in
            guard notification.object as? NSWindow === hostingWindow,
                  let rawMode = notification.userInfo?["mode"] as? String,
                  let mode = EditorMode(rawValue: rawMode),
                  mode != .edit || !isPDFSession
            else { return }
            editorMode = mode
        }
        .onDisappear {
            removeKeyMonitor()
        }
        .onDeleteCommand(perform: deleteSelected)
        .onExitCommand {
            if isCropping {
                cancelCrop()
            }
        }
        .onChange(of: selectedWallpaper) { oldValue, newValue in
            guard !isRestoringSession else { return }
            let wasEnabled = oldValue != nil
            let isEnabled = newValue != nil
            appSettings?.editorUseTemplateBackground = isEnabled
            if let newValue {
                appSettings?.screenshotTemplate.wallpaperSource = newValue
            }
            if let rawImage {
                if wasEnabled != isEnabled {
                    let cropSize = screenshotCropRect.isEmpty ? rawImage.size : screenshotCropRect.size
                    let oldOrigin = wasEnabled ? screenshotOriginInTemplatedCanvas(screenshotPixelSize: cropSize, padding: editorPadding, aspectRatio: selectedEditorAspectRatio?.ratio, alignment: screenshotAlignment) : .zero
                    let newOrigin = isEnabled ? screenshotOriginInTemplatedCanvas(screenshotPixelSize: cropSize, padding: editorPadding, aspectRatio: selectedEditorAspectRatio?.ratio, alignment: screenshotAlignment) : .zero
                    shiftAnnotations(by: CGPoint(x: newOrigin.x - oldOrigin.x, y: newOrigin.y - oldOrigin.y))
                }
                scheduleDisplayRefresh()
            }
        }
        .onChange(of: editorPadding) { oldValue, newValue in
            guard !isRestoringSession else { return }
            appSettings?.screenshotTemplate.padding = newValue
            if selectedWallpaper != nil, let rawImage {
                let cropSize = screenshotCropRect.isEmpty ? rawImage.size : screenshotCropRect.size
                let oldOrigin = screenshotOriginInTemplatedCanvas(screenshotPixelSize: cropSize, padding: oldValue, aspectRatio: selectedEditorAspectRatio?.ratio, alignment: screenshotAlignment)
                let newOrigin = screenshotOriginInTemplatedCanvas(screenshotPixelSize: cropSize, padding: newValue, aspectRatio: selectedEditorAspectRatio?.ratio, alignment: screenshotAlignment)
                shiftAnnotations(by: CGPoint(x: newOrigin.x - oldOrigin.x, y: newOrigin.y - oldOrigin.y))
                scheduleDisplayRefresh()
            }
        }
        .onChange(of: editorAspectRatioID) { oldID, newID in
            guard !isRestoringSession else { return }
            if selectedWallpaper != nil, let rawImage {
                let cropSize = screenshotCropRect.isEmpty ? rawImage.size : screenshotCropRect.size
                let oldRatio = aspectRatioValue(for: oldID)
                let newRatio = aspectRatioValue(for: newID)
                let oldOrigin = screenshotOriginInTemplatedCanvas(screenshotPixelSize: cropSize, padding: editorPadding, aspectRatio: oldRatio)
                let newOrigin = screenshotOriginInTemplatedCanvas(screenshotPixelSize: cropSize, padding: editorPadding, aspectRatio: newRatio)
                shiftAnnotations(by: CGPoint(x: newOrigin.x - oldOrigin.x, y: newOrigin.y - oldOrigin.y))
                scheduleDisplayRefresh()
            }
        }
        .onChange(of: editorCornerRadius) { _, newValue in
            guard !isRestoringSession else { return }
            appSettings?.screenshotTemplate.cornerRadius = newValue
            if selectedWallpaper != nil, let rawImage {
                scheduleDisplayRefresh()
            }
        }
        .onChange(of: photoAdjustments) { _, _ in
            guard !isRestoringSession else { return }
            if let rawImage {
                scheduleDisplayRefresh()
            }
        }
    }

    private var bodyWithObservers: some View {
        bodyBase
        .onChange(of: screenshotAlignment) { oldAlignment, newAlignment in
            guard !isRestoringSession else { return }
            if selectedWallpaper != nil, let rawImage {
                let cropSize = screenshotCropRect.isEmpty ? rawImage.size : screenshotCropRect.size
                let oldOrigin = screenshotOriginInTemplatedCanvas(screenshotPixelSize: cropSize, padding: editorPadding, aspectRatio: selectedEditorAspectRatio?.ratio, alignment: oldAlignment)
                let newOrigin = screenshotOriginInTemplatedCanvas(screenshotPixelSize: cropSize, padding: editorPadding, aspectRatio: selectedEditorAspectRatio?.ratio, alignment: newAlignment)
                shiftAnnotations(by: CGPoint(x: newOrigin.x - oldOrigin.x, y: newOrigin.y - oldOrigin.y))
                scheduleDisplayRefresh()
            }
        }
        .onChange(of: columnVisibility) { _, newValue in
            appSettings?.editorShowProSidebar = (newValue != .detailOnly)
        }
        .onChange(of: editorMode) { _, newMode in
            // Persist the last-used mode so the "Last Used" default-on-open option works.
            appSettings?.lastUsedEditorMode = newMode
            onModeChange(newMode)
        }
        .onChange(of: isPDFSession) { _, isPDF in
            onEditModeAvailabilityChange(!isPDF)
        }
        .onChange(of: imagePixelSize) { _, _ in
            updateFitScale(viewSize: lastViewSize)
        }
        .onChange(of: shadowIntensity) { _, _ in
            guard !isRestoringSession else { return }
            if selectedWallpaper != nil, let rawImage {
                scheduleDisplayRefresh()
            }
        }
        .onChange(of: isCropping) { _, newValue in
            guard !isRestoringSession else { return }
            if newValue {
                enterCropMode()
            }
        }
        .onChange(of: selectedAnnotationID) { _, newID in
            guard !isRestoringSession else { return }
            if let id = newID,
               let ann = annotations.first(where: { $0.id == id }) {
                currentStyle = ann.style
            }
        }
        .onChange(of: currentTool) { _, newTool in
            guard !isRestoringSession else { return }
            handleToolChange(newTool)
        }
        .onChange(of: appSettings?.selectedEditorTemplateID) { _, newValue in
            guard let appSettings,
                  let id = newValue,
                  let template = appSettings.editorTemplates.first(where: { $0.id == id })
            else { return }
            applyTemplateToAllSessions(template)
        }
        .alert("Delete Screenshot?", isPresented: $showTrashAlert) {
            Button("Delete", role: .destructive) {
                trashScreenshot()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The file will be moved to the Trash.")
        }
    }

    // MARK: - Navigation Content

    private var navigationContent: some View {
        HStack(spacing: 0) {
            // Sidebar is hidden in View mode; can be collapsed via toggle in Annotate/Edit.
            if editorMode != .view && showProSidebar {
                sidebarContent
                    .transition(.move(edge: .leading))
            }
            detailContent
        }
        // Scoped animation: only animates the sidebar's insertion/removal transition.
        .animation(.easeInOut(duration: 0.2), value: showProSidebar)
        .animation(.easeInOut(duration: 0.2), value: editorMode)
        .toolbar {
            // [flexible spacer] — keeps mode toggle centred
            ToolbarItem(placement: .automatic) {
                Spacer()
            }

            // [Mode Toggle] — Annotate | Edit | View. Sidebar visibility is driven
            // by the mode (View hides it), so no separate panel-toggle button is needed.
            ToolbarItem(placement: .automatic) {
                EditorModeToggle(editorMode: $editorMode, isPDFSession: isPDFSession)
            }

            // [flexible spacer] — pins Undo & Done to far right
            ToolbarItem(placement: .automatic) {
                Spacer()
            }

            // [Undo & Done buttons] — far right, each in its own item to prevent style bleed
            ToolbarItem(placement: .automatic) {
                Button(action: undo) {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.bordered)
                .help("Undo")
                .keyboardShortcut("z", modifiers: .command)
                .disabled(undoStack.isEmpty)
            }
            ToolbarItem(placement: .automatic) {
                // With multiple images the clipboard can only hold one, so we drop the
                // "& Copy" suffix and skip the clipboard write (see saveOverwrite).
                // For an unedited PDF, label becomes "Done" since there's nothing to save.
                let isMulti = sessions.count > 1
                let isPDFDone = isPDFSession && !pdfDocumentHasEdits
                let hasEdits = anySessionHasEdits
                let label: String = isPDFDone
                    ? "Done"
                    : isMulti
                        ? (hasEdits ? "Save All" : "Done")
                        : (hasEdits ? "Save & Copy" : "Copy")
                let help: String = isPDFDone
                    ? "Close the document"
                    : isMulti
                        ? (hasEdits ? "Save all open images and close" : "Close all images")
                        : (hasEdits ? "Save, close and copy the image to your clipboard" : "Copy the image to your clipboard")
                Button(action: saveOverwrite) {
                    Text(label)
                        .padding(.horizontal, 6)
                }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
                    .help(help)
            }
        }
    }

    // MARK: - Sidebar Content

    private var sidebarContent: some View {
        EditorSidebarView(
            editorMode: $editorMode,
            photoAdjustments: $photoAdjustments,
            imageMetadata: imageMetadata,
            showProSidebar: showProSidebarBinding,
            currentTool: $currentTool,
            currentStyle: $currentStyle,
            selectedAnnotationID: $selectedAnnotationID,
            annotations: $annotations,
            isCropping: $isCropping,
            cropAspectPreset: $cropAspectPreset,
            selectedWallpaper: $selectedWallpaper,
            padding: $editorPadding,
            cornerRadius: $editorCornerRadius,
            shadowIntensity: $shadowIntensity,
            screenshotAlignment: $screenshotAlignment,
            aspectRatios: editorAspectRatios,
            selectedAspectRatioID: $editorAspectRatioID,
            editorTemplates: appSettings?.editorTemplates ?? [],
            selectedEditorTemplateID: Binding(
                get: { appSettings?.selectedEditorTemplateID },
                set: { appSettings?.selectedEditorTemplateID = $0 }
            ),
            hasUnsavedTemplateChanges: hasUnsavedTemplateChanges,
            hasTemplate: !isPDFSession,
            customBackgroundImages: appSettings?.customBackgroundImages ?? [],
            onAddCustomImage: addCustomBackgroundImage,
            onRemoveCustomImage: removeCustomBackgroundImage,
            customColors: appSettings?.customColors ?? [],
            onAddCustomColor: { appSettings?.addCustomColor($0) },
            onRemoveCustomColor: { appSettings?.removeCustomColor($0) },
            onOverwriteTemplate: overwriteSelectedTemplate,
            onSaveAsNewTemplate: saveAsNewTemplate,
            canUndo: !undoStack.isEmpty,
            onApplyCrop: applyCrop,
            onCancelCrop: cancelCrop,
            onEnterCrop: { isCropping = true; currentTool = .crop },
            onRotateLeft: rotateLeft,
            onRotateRight: rotateRight,
            onUndo: undo,
            onDone: saveOverwrite,
            watermarkSettings: watermarkSettingsBinding,
            onPickWatermarkImage: pickWatermarkImage,
            imagePixelSize: imagePixelSize,
            onResizeImage: resizeImage
        )
        .frame(width: 260)
        .background(.thickMaterial)
    }

    // MARK: - Detail Content

    private var detailContent: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .trailing) {
                GeometryReader { geo in
                    Group {
                        if let image {
                            ScrollView([.horizontal, .vertical], showsIndicators: zoomLevel > 1.0) {
                                EditorCanvasView(
                                    image: image,
                                    imagePixelSize: imagePixelSize,
                                    scale: effectiveScale,
                                    displayBackingScale: displayBackingScale,
                                    editorMode: editorMode,
                                    pdfPageSource: activeSession?.pdfPageSource,
                                    shadowIntensity: 0,
                                    showBorderOutline: selectedWallpaper == nil,
                                    annotations: $annotations,
                                    selectedAnnotationID: $selectedAnnotationID,
                                    currentTool: $currentTool,
                                    currentStyle: $currentStyle,
                                    cropRect: $cropRect,
                                    isCropping: $isCropping,
                                    cropBoundsRect: screenshotBoundsInDisplay,
                                    cropAspectRatio: cropAspectPreset.ratio,
                                    watermarkSettings: watermarkSettings,
                                    onCommit: pushUndo
                                )
                                .padding(20)
                                .background(ScrollViewAccessor { nsScrollView = $0 })
                            }
                        } else {
                            ContentUnavailableView("Unable to load image", systemImage: "photo.badge.exclamationmark")
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .onAppear {
                        lastViewSize = geo.size
                        canvasViewportFrame = geo.frame(in: .global)
                        updateFitScale(viewSize: geo.size)
                    }
                    .onChange(of: geo.size) { _, newSize in
                        lastViewSize = newSize
                        canvasViewportFrame = geo.frame(in: .global)
                        updateFitScale(viewSize: newSize)
                    }
                }

                if sessions.count > 1 {
                    ThumbnailStripView(
                        sessions: sessions,
                        activeID: activeSessionID,
                        onSelect: { switchToSession($0) },
                        onRemove: { removeSession($0) },
                        onMove: { from, to in
                            sessions.move(fromOffsets: IndexSet(integer: from),
                                          toOffset: to > from ? to + 1 : to)
                        }
                    )
                    .padding(.trailing, 12)
                    .padding(.vertical, 12)
                }
            }

            EditorBottomToolbarView(
                imagePixelSize: imagePixelSize,
                aspectRatios: editorAspectRatios,
                selectedAspectRatioID: $editorAspectRatioID,
                padding: $editorPadding,
                cornerRadius: $editorCornerRadius,
                useTemplateBackground: selectedWallpaper != nil,
                hideSliders: showProSidebar,
                onTrash: { showTrashAlert = true },
                onCancel: cancelEdits,
                onSaveAs: saveAs,
                onPrint: printImage,
                annotationsCount: annotations.count,
                displayZoomPercent: Int(displayZoomPercent),
                onZoomOut: zoomOut,
                onZoomIn: zoomIn,
                onZoomReset: { zoomLevel = 1.0; syncZoomToPDFGroup() }
            )
            .offset(y: -3)
        }
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
    }

    // MARK: - Zoom

    private func updateFitScale(viewSize: CGSize) {
        guard imagePixelSize.width > 0, imagePixelSize.height > 0,
              viewSize.width > 0, viewSize.height > 0 else { return }
        // Content in the scroll view adds:
        // - 56pt top clearance for the floating toolbar overlay
        // - 20pt padding on the other three sides
        let horizontalChrome: CGFloat = 40  // 20pt left + 20pt right
        let verticalChrome: CGFloat = 40    // 20pt top + 20pt bottom
        let fitFudge: CGFloat = 2           // avoid off-by-1 scrollbar due rounding

        let availableWidth = max(viewSize.width - horizontalChrome - fitFudge, 100)
        let availableHeight = max(viewSize.height - verticalChrome - fitFudge, 100)
        let scaleX = availableWidth / imagePixelSize.width
        let scaleY = availableHeight / imagePixelSize.height

        // Pick up the current screen's backing scale (handles display changes).
        displayBackingScale = NSScreen.main?.backingScaleFactor ?? 2.0

        // "True size" scale: 1 image pixel = 1/backingScale view points.
        // At this scale the image displays at the same size as the original window.
        let trueSizeScale = 1.0 / displayBackingScale

        // Fit to view, but never scale up beyond true size.
        fitScale = min(min(scaleX, scaleY), trueSizeScale)
    }

    private func zoomIn() {
        if let next = zoomSteps.first(where: { $0 > zoomLevel }) {
            zoomLevel = min(next, maxZoomLevel)
            syncZoomToPDFGroup()
        }
    }

    private func zoomOut() {
        if let prev = zoomSteps.last(where: { $0 < zoomLevel }) {
            zoomLevel = max(prev, minZoomLevel)
            syncZoomToPDFGroup()
        }
    }

    /// When the active session belongs to a PDF group, mirror the current zoom level
    /// to all sibling pages so every page in the document zooms together.
    private func syncZoomToPDFGroup() {
        guard let groupID = activeSession?.pdfGroupID else { return }
        for session in sessions where session.pdfGroupID == groupID && session.id != activeSessionID {
            session.zoomLevel = zoomLevel
        }
    }

    /// Binding passed to the sidebar for watermark settings.
    /// When `isEnabled` is toggled, the new value is mirrored to all sibling
    /// PDF sessions so enabling/disabling affects the whole document at once.
    private var watermarkSettingsBinding: Binding<WatermarkSettings> {
        Binding(
            get: { watermarkSettings },
            set: { [self] newValue in
                let enabledChanged = newValue.isEnabled != watermarkSettings.isEnabled
                watermarkSettings = newValue
                if enabledChanged, let groupID = activeSession?.pdfGroupID {
                    for session in sessions where session.pdfGroupID == groupID && session.id != activeSessionID {
                        session.watermarkSettings.isEnabled = newValue.isEnabled
                    }
                }
            }
        )
    }

    // MARK: - Image Loading

    /// Pre-loads thumbnails for all non-active sessions on a background queue.
    /// Intentionally does NOT populate `session.image` / `session.rawImage` — that way
    /// the first activation of a session falls into the `loadImage()` path and
    /// gets the editor's current template (wallpaper, padding) applied properly.
    /// Decode every not-yet-loaded session in the background so the user can
    /// click any thumbnail in the strip with no perceptible delay. Each session
    /// ends up with a cached `rawImage`, `metadata`, `screenshotCropRect`,
    /// `image`, and `thumbnail` — exactly what an active load would produce.
    private func preloadThumbnails() {
        let targets = sessions.filter { $0.id != activeSessionID && $0.rawImage == nil }
        guard !targets.isEmpty else { return }
        // Render preloaded PDF pages at the same backing scale as the active page
        // so every page's imagePixelSize is pointSize × backingScale. Switching to
        // a preloaded session reuses this image (loadImage is skipped when
        // session.image != nil), so a lighter scale here would make those pages
        // display smaller than page 0.
        let backingScale = displayBackingScale
        Self.imageLoadQueue.async {
            for session in targets {
                let decoded: (nsImage: NSImage, cgImage: CGImage)?
                if let pdfSource = session.pdfPageSource,
                   let cg = pdfSource.renderPage(backingScale: backingScale) {
                    let size = NSSize(width: cg.width, height: cg.height)
                    let img = NSImage(size: size)
                    img.addRepresentation(NSBitmapImageRep(cgImage: cg))
                    decoded = (img, cg)
                } else if let img = NSImage(contentsOf: session.imageURL),
                          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    decoded = (img, cg)
                } else {
                    continue
                }
                guard let decoded else { continue }
                let metadata = ImageMetadata.load(from: session.imageURL)
                DispatchQueue.main.async { [weak session] in
                    guard let session, session.rawImage == nil else { return }
                    // Cache decoded data on the session so a later switch is instant.
                    session.rawImage = decoded.nsImage
                    session.metadata = metadata
                    let (sw, sh) = Self.rotatedDims(width: CGFloat(decoded.cgImage.width),
                                                    height: CGFloat(decoded.cgImage.height),
                                                    steps: session.rotationSteps)
                    session.screenshotCropRect = CGRect(x: 0, y: 0, width: sw, height: sh)
                    // Produce session.image + thumbnail via the non-active-session renderer.
                    renderSessionDisplay(session)
                }
            }
        }
    }

    /// Copy the editor's resolved template defaults (set up in `.onAppear` for the
    /// first session) onto every other session, so switching to a never-activated
    /// image renders with the same wallpaper/padding/etc. instead of bare defaults.
    private func propagateInitialTemplateToOtherSessions() {
        guard let active = activeSession else { return }
        for session in sessions where session.id != active.id {
            session.editorPadding = active.editorPadding
            session.editorCornerRadius = active.editorCornerRadius
            session.selectedWallpaper = active.selectedWallpaper
            session.shadowIntensity = active.shadowIntensity
            session.editorAspectRatioID = active.editorAspectRatioID
            session.screenshotAlignment = active.screenshotAlignment
            session.watermarkSettings = active.watermarkSettings
        }
    }

    /// Apply a template preset to every open image so all of them switch to the
    /// new look at once. The active session goes through the @State path so the
    /// existing onChange machinery (appSettings persistence, annotation shift)
    /// fires normally; the rest are updated in place and re-rendered.
    private func applyTemplateToAllSessions(_ template: EditorTemplatePreset) {
        applyEditorTemplate(template)

        // After the synchronous @State writes above, SwiftUI schedules onChange
        // handlers which re-render the canvas. Once that's done, sync the
        // freshly-rendered @State back into the active session so its thumbnail
        // refreshes too.
        DispatchQueue.main.async {
            saveActiveSessionState()
        }

        for session in sessions where session.id != activeSessionID {
            applyTemplate(template, toSession: session)
        }
    }

    /// Apply a template's settings to a non-active session, shift its annotations
    /// to compensate for the new template-canvas offset, and re-render its display
    /// image if its raw image has been loaded.
    private func applyTemplate(_ template: EditorTemplatePreset, toSession session: ImageSession) {
        let newAspectRatioID = normalizedAspectRatioID(template.aspectRatioID)

        let cropSize = session.screenshotCropRect.isEmpty
            ? (session.rawImage?.size ?? session.imagePixelSize)
            : session.screenshotCropRect.size

        let oldRatio = editorAspectRatios.first(where: { $0.id == session.editorAspectRatioID })?.ratio
        let newRatio = editorAspectRatios.first(where: { $0.id == newAspectRatioID })?.ratio

        let oldOrigin: CGPoint = (session.selectedWallpaper != nil)
            ? screenshotOriginInTemplatedCanvas(
                screenshotPixelSize: cropSize,
                padding: session.editorPadding,
                aspectRatio: oldRatio,
                alignment: session.screenshotAlignment)
            : .zero
        let newOrigin: CGPoint = (template.wallpaperSource != nil)
            ? screenshotOriginInTemplatedCanvas(
                screenshotPixelSize: cropSize,
                padding: template.padding,
                aspectRatio: newRatio,
                alignment: template.alignment)
            : .zero
        let delta = CGPoint(x: newOrigin.x - oldOrigin.x, y: newOrigin.y - oldOrigin.y)

        if (delta.x != 0 || delta.y != 0), !session.annotations.isEmpty {
            session.annotations = session.annotations.map { ann in
                var a = ann
                a.startPoint = CGPoint(x: ann.startPoint.x + delta.x, y: ann.startPoint.y + delta.y)
                a.endPoint = CGPoint(x: ann.endPoint.x + delta.x, y: ann.endPoint.y + delta.y)
                if !ann.points.isEmpty {
                    a.points = ann.points.map { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) }
                }
                return a
            }
        }

        session.selectedWallpaper = template.wallpaperSource
        session.editorPadding = template.padding
        session.editorCornerRadius = template.cornerRadius
        session.shadowIntensity = template.shadowIntensity
        session.screenshotAlignment = template.alignment
        session.editorAspectRatioID = newAspectRatioID
        session.watermarkSettings = template.watermarkSettings

        // Sessions that have never been activated have no rawImage; their new
        // template settings will be picked up on first activation by loadImage.
        if session.rawImage != nil {
            renderSessionDisplay(session)
        }
    }

    /// Mirror of `applyDisplayImage` that operates on a session instead of @State.
    /// Updates the session's display image, derived metadata, and thumbnail.
    private func renderSessionDisplay(_ session: ImageSession) {
        guard let rawImg = session.rawImage,
              let cgSourceOriginal = rawImg.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return }

        // Apply this session's rotation up front (same model as applyDisplayImage).
        let cgSource = Self.rotateCGImage90(cgSourceOriginal, steps: session.rotationSteps, ciContext: ciContext)
            ?? cgSourceOriginal

        var croppedCG = cgSource
        if !session.screenshotCropRect.isEmpty {
            let fullBounds = CGRect(x: 0, y: 0,
                                    width: CGFloat(cgSource.width), height: CGFloat(cgSource.height))
            let clampedCrop = session.screenshotCropRect.intersection(fullBounds)
            if !clampedCrop.isEmpty, clampedCrop != fullBounds,
               let cropped = cgSource.cropping(to: clampedCrop) {
                croppedCG = cropped
            }
        }

        // Apply photo adjustments for this session (if any).
        if !session.photoAdjustments.isDefault {
            croppedCG = session.photoAdjustments.apply(to: croppedCG, ciContext: ciContext)
        }

        var displayCG = croppedCG
        if let wallpaper = session.selectedWallpaper {
            var editorTemplate = self.template
            editorTemplate.padding = session.editorPadding
            editorTemplate.cornerRadius = session.editorCornerRadius
            editorTemplate.wallpaperSource = wallpaper
            editorTemplate.watermarkSettings = WatermarkSettings()
            let aspectRatio = editorAspectRatios.first(where: { $0.id == session.editorAspectRatioID })?.ratio
            if let templated = try? session.templateRenderer.applyTemplate(
                editorTemplate,
                to: croppedCG,
                backingScale: displayBackingScale,
                targetAspectRatio: aspectRatio,
                shadowIntensity: session.shadowIntensity,
                alignment: session.screenshotAlignment
            ) {
                displayCG = templated
            }
        }

        let size = CGSize(width: displayCG.width, height: displayCG.height)
        let nsImage = NSImage(size: size)
        nsImage.addRepresentation(NSBitmapImageRep(cgImage: displayCG))
        session.image = nsImage
        session.currentDisplayCGImage = displayCG
        session.imagePixelSize = size
        session.cropRect = CGRect(origin: .zero, size: size)
        session.generateThumbnail(from: nsImage)
    }

    /// Decode the active session's image off the main thread. The UI stays
    /// responsive while the (potentially ~100ms) PNG decode runs in the
    /// background; results are dispatched back to main when ready.
    private func loadImage() {
        guard let session = activeSession else { return }
        let currentID = session.id
        let backingScale = displayBackingScale

        // PDF path
        if let pdfSource = session.pdfPageSource {
            let sourceURL = pdfSource.sourceURL
            Self.imageLoadQueue.async {
                guard let cgImage = pdfSource.renderPage(backingScale: backingScale) else { return }
                let metadata = ImageMetadata.load(from: sourceURL)
                let size = NSSize(width: cgImage.width, height: cgImage.height)
                let nsImage = NSImage(size: size)
                nsImage.addRepresentation(NSBitmapImageRep(cgImage: cgImage))
                DispatchQueue.main.async {
                    applyLoaded(image: nsImage, cgImage: cgImage, metadata: metadata, sessionID: currentID)
                }
            }
            return
        }

        // Non-PDF (image file on disk)
        let url = session.imageURL
        Self.imageLoadQueue.async {
            guard let nsImage = NSImage(contentsOf: url),
                  // Force decode here off the main thread.
                  let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else { return }
            let metadata = ImageMetadata.load(from: url)
            DispatchQueue.main.async {
                applyLoaded(image: nsImage, cgImage: cgImage, metadata: metadata, sessionID: currentID)
            }
        }
    }

    /// Background queue for image decoding. Concurrent so multiple sessions can
    /// be pre-decoded in parallel if we ever add prefetch.
    private static let imageLoadQueue = DispatchQueue(
        label: "com.simplshot.imageLoad",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// Main-thread continuation for `loadImage`. Writes the decoded image back
    /// to the originating session (so a later return-visit is instant), and if
    /// that session is still active, reflects into @State to trigger display.
    private func applyLoaded(image nsImage: NSImage, cgImage: CGImage, metadata: ImageMetadata, sessionID: UUID) {
        guard let originalSession = sessions.first(where: { $0.id == sessionID }) else { return }

        // Always populate the originating session so a later switch back is fast.
        originalSession.rawImage = nsImage
        originalSession.metadata = metadata
        let (sw, sh) = Self.rotatedDims(width: CGFloat(cgImage.width),
                                        height: CGFloat(cgImage.height),
                                        steps: originalSession.rotationSteps)
        originalSession.screenshotCropRect = CGRect(x: 0, y: 0, width: sw, height: sh)

        if activeSessionID == sessionID {
            // Reflect into @State and trigger the active display pipeline.
            rawImage = nsImage
            imageMetadata = metadata
            screenshotCropRect = originalSession.screenshotCropRect
            applyDisplayImage(from: nsImage)
            saveActiveSessionState()
        } else {
            // User has navigated away. Pre-render the display image into the
            // session so that when they come back, no work is needed.
            renderSessionDisplay(originalSession)
        }
    }

    /// Coalesces display re-renders into a single pass on the next runloop tick.
    /// Applying a template mutates ~7 @State properties at once, each firing its
    /// own onChange; without coalescing that runs `applyDisplayImage` ~7×. The
    /// async render reads the final @State, so the result is always up to date.
    private func scheduleDisplayRefresh() {
        guard !displayRefreshScheduled else { return }
        displayRefreshScheduled = true
        DispatchQueue.main.async {
            displayRefreshScheduled = false
            guard let rawImage else { return }
            applyDisplayImage(from: rawImage)
        }
    }

    private func applyDisplayImage(from source: NSImage) {
        guard let cgSourceOriginal = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            image = source
            currentDisplayCGImage = nil
            imagePixelSize = source.size
            cropRect = CGRect(origin: .zero, size: source.size)
            return
        }

        // Apply rotation FIRST so all subsequent geometry (crop, adjustments,
        // template) operates in the rotated coordinate space. screenshotCropRect
        // and annotations are also stored in this rotated-raw coord space.
        let cgSource = Self.rotateCGImage90(cgSourceOriginal, steps: rotationSteps, ciContext: ciContext)
            ?? cgSourceOriginal

        // Apply non-destructive crop to the (rotated) raw screenshot before compositing.
        var croppedCG = cgSource
        if !screenshotCropRect.isEmpty {
            let fullBounds = CGRect(x: 0, y: 0,
                                    width: CGFloat(cgSource.width), height: CGFloat(cgSource.height))
            let clampedCrop = screenshotCropRect.intersection(fullBounds)
            if !clampedCrop.isEmpty, clampedCrop != fullBounds,
               let cropped = cgSource.cropping(to: clampedCrop) {
                croppedCG = cropped
            }
        }

        // Apply photo adjustments (non-destructive CI filter chain).
        // Runs in Edit mode when any slider is non-default, but the result is
        // always available for export regardless of current mode.
        if !photoAdjustments.isDefault {
            croppedCG = photoAdjustments.apply(to: croppedCG, ciContext: ciContext)
        }

        var displayCG = croppedCG
        if let wallpaper = selectedWallpaper, !isPDFSession {
            // Build a template with the current editor slider values and selected wallpaper,
            // applied to the already-cropped screenshot (never the raw+wallpaper composite).
            var editorTemplate = template
            editorTemplate.padding = editorPadding
            editorTemplate.cornerRadius = editorCornerRadius
            editorTemplate.wallpaperSource = wallpaper
            editorTemplate.watermarkSettings = WatermarkSettings()
            if let templated = try? templateRenderer.applyTemplate(
                editorTemplate,
                to: croppedCG,
                backingScale: displayBackingScale,
                targetAspectRatio: selectedEditorAspectRatio?.ratio,
                shadowIntensity: shadowIntensity,
                alignment: screenshotAlignment
            ) {
                displayCG = templated
            }
        }

        let size = CGSize(width: displayCG.width, height: displayCG.height)
        let nsImage = NSImage(size: size)
        nsImage.addRepresentation(NSBitmapImageRep(cgImage: displayCG))
        image = nsImage
        currentDisplayCGImage = displayCG
        imagePixelSize = size
        cropRect = CGRect(origin: .zero, size: size)
    }

    // MARK: - Crop

    private func applyCrop() {
        // Compute the gradient offset so we can convert display-space cropRect
        // back to raw screenshot pixel space.
        let gradientOffset: CGPoint
        if selectedWallpaper != nil, !screenshotCropRect.isEmpty {
            gradientOffset = screenshotOriginInTemplatedCanvas(
                screenshotPixelSize: screenshotCropRect.size,
                padding: editorPadding,
                aspectRatio: selectedEditorAspectRatio?.ratio,
                alignment: screenshotAlignment
            )
        } else {
            gradientOffset = .zero
        }

        // Convert the display-space crop rect to raw-screenshot-relative coords.
        let rawRelativeCrop = CGRect(
            x: cropRect.minX - gradientOffset.x,
            y: cropRect.minY - gradientOffset.y,
            width: cropRect.width,
            height: cropRect.height
        )

        // If the crop covers the full current screenshot or is unchanged, cancel crop mode
        // (restore pre-crop state) instead of leaving annotations stranded in full-image coords.
        let currentScreenshotBounds = CGRect(origin: .zero, size: screenshotCropRect.size)
        guard rawRelativeCrop != currentScreenshotBounds,
              !rawRelativeCrop.isEmpty
        else {
            cancelCrop()
            return
        }

        // Clamp to current screenshot bounds.
        let clampedRawRelative = rawRelativeCrop.intersection(currentScreenshotBounds)
        guard !clampedRawRelative.isEmpty else {
            cancelCrop()
            return
        }

        // Build the new screenshotCropRect in original raw image pixel space.
        let newScreenshotCropRect = CGRect(
            x: screenshotCropRect.minX + clampedRawRelative.minX,
            y: screenshotCropRect.minY + clampedRawRelative.minY,
            width: clampedRawRelative.width,
            height: clampedRawRelative.height
        )

        guard newScreenshotCropRect != screenshotCropRect else {
            cancelCrop()
            return
        }

        // Push the pre-crop state captured in enterCropMode() so undo restores the
        // correct cropped image (not the expanded full-image intermediate state).
        if let snapshot = preCropSnapshot {
            undoStack.append(snapshot)
            preCropSnapshot = nil
        } else {
            pushUndo()
        }

        // Compute annotation shift: accounts for both crop origin movement and
        // any change in the gradient offset (which can shift if aspect ratio is used).
        let newGradientOffset: CGPoint
        if selectedWallpaper != nil {
            newGradientOffset = screenshotOriginInTemplatedCanvas(
                screenshotPixelSize: newScreenshotCropRect.size,
                padding: editorPadding,
                aspectRatio: selectedEditorAspectRatio?.ratio,
                alignment: screenshotAlignment
            )
        } else {
            newGradientOffset = .zero
        }

        let annotationShift = CGPoint(
            x: (newGradientOffset.x - gradientOffset.x) - clampedRawRelative.minX,
            y: (newGradientOffset.y - gradientOffset.y) - clampedRawRelative.minY
        )
        shiftAnnotations(by: annotationShift)

        // Update the non-destructive crop rect and re-render.
        // rawImage is never modified — gradient + crop are applied in applyDisplayImage.
        screenshotCropRect = newScreenshotCropRect
        if let rawImg = rawImage {
            applyDisplayImage(from: rawImg)
        }

        isCropping = false
        currentTool = .select
    }

    /// Expands the display to the full uncropped image and positions the crop rect
    /// over the previously-cropped region so the user can readjust from the original.
    private func enterCropMode() {
        // Each crop session starts unconstrained.
        cropAspectPreset = .free
        guard let rawImg = rawImage,
              let cg = rawImg.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            cropRect = screenshotBoundsInDisplay
            return
        }

        // Capture the pre-crop state for correct undo (before any state changes).
        preCropSnapshot = EditorSnapshot(
            annotations: annotations,
            image: image,
            rawImage: rawImage,
            selectedWallpaper: selectedWallpaper,
            imagePixelSize: imagePixelSize,
            cropRect: cropRect,
            screenshotCropRect: screenshotCropRect,
            photoAdjustments: photoAdjustments,
            rotationSteps: rotationSteps
        )

        // Remember the current crop so cancel can restore it.
        preCropScreenshotCropRect = screenshotCropRect

        // screenshotCropRect is in rotated-raw dims, so swap if rotation is odd.
        let (rotW, rotH) = Self.rotatedDims(width: CGFloat(cg.width),
                                            height: CGFloat(cg.height),
                                            steps: rotationSteps)
        let fullBounds = CGRect(x: 0, y: 0, width: rotW, height: rotH)

        // Compute the old gradient offset (before expanding).
        let oldGradientOffset: CGPoint
        if selectedWallpaper != nil, !screenshotCropRect.isEmpty {
            oldGradientOffset = screenshotOriginInTemplatedCanvas(
                screenshotPixelSize: screenshotCropRect.size,
                padding: editorPadding,
                aspectRatio: selectedEditorAspectRatio?.ratio,
                alignment: screenshotAlignment
            )
        } else {
            oldGradientOffset = .zero
        }

        // Expand to full image.
        screenshotCropRect = fullBounds
        applyDisplayImage(from: rawImg)

        // Compute the new gradient offset (after expanding to full image).
        let newGradientOffset: CGPoint
        if selectedWallpaper != nil {
            newGradientOffset = screenshotOriginInTemplatedCanvas(
                screenshotPixelSize: fullBounds.size,
                padding: editorPadding,
                aspectRatio: selectedEditorAspectRatio?.ratio,
                alignment: screenshotAlignment
            )
        } else {
            newGradientOffset = .zero
        }

        // Shift annotations so they stay anchored to the screenshot content.
        let annotationShift = CGPoint(
            x: (newGradientOffset.x - oldGradientOffset.x) + preCropScreenshotCropRect.minX,
            y: (newGradientOffset.y - oldGradientOffset.y) + preCropScreenshotCropRect.minY
        )
        if annotationShift.x != 0 || annotationShift.y != 0 {
            shiftAnnotations(by: annotationShift)
        }

        // Position the crop rect over the old cropped region in the new display.
        cropRect = CGRect(
            x: newGradientOffset.x + preCropScreenshotCropRect.minX,
            y: newGradientOffset.y + preCropScreenshotCropRect.minY,
            width: preCropScreenshotCropRect.width,
            height: preCropScreenshotCropRect.height
        )
    }

    private func cancelCrop() {
        // Compute gradient offset for the full image (current crop-mode state).
        let fullGradientOffset: CGPoint
        if selectedWallpaper != nil, !screenshotCropRect.isEmpty {
            fullGradientOffset = screenshotOriginInTemplatedCanvas(
                screenshotPixelSize: screenshotCropRect.size,
                padding: editorPadding,
                aspectRatio: selectedEditorAspectRatio?.ratio,
                alignment: screenshotAlignment
            )
        } else {
            fullGradientOffset = .zero
        }

        // Restore the pre-crop-mode crop and re-render.
        screenshotCropRect = preCropScreenshotCropRect
        if let rawImg = rawImage {
            applyDisplayImage(from: rawImg)
        }

        // Compute gradient offset for the restored crop.
        let restoredGradientOffset: CGPoint
        if selectedWallpaper != nil, !screenshotCropRect.isEmpty {
            restoredGradientOffset = screenshotOriginInTemplatedCanvas(
                screenshotPixelSize: screenshotCropRect.size,
                padding: editorPadding,
                aspectRatio: selectedEditorAspectRatio?.ratio,
                alignment: screenshotAlignment
            )
        } else {
            restoredGradientOffset = .zero
        }

        // Shift annotations back to match the restored display.
        let annotationShift = CGPoint(
            x: (restoredGradientOffset.x - fullGradientOffset.x) - preCropScreenshotCropRect.minX,
            y: (restoredGradientOffset.y - fullGradientOffset.y) - preCropScreenshotCropRect.minY
        )
        if annotationShift.x != 0 || annotationShift.y != 0 {
            shiftAnnotations(by: annotationShift)
        }

        cropRect = CGRect(origin: .zero, size: imagePixelSize)
        preCropSnapshot = nil
        isCropping = false
        currentTool = .select
    }

    // MARK: - Resize

    private func resizeImage(toWidth targetWidth: Int, height targetHeight: Int) {
        guard let rawImg = rawImage,
              let srcCG = rawImg.cgImage(forProposedRect: nil, context: nil, hints: nil),
              imagePixelSize.width > 0, imagePixelSize.height > 0,
              targetWidth > 0, targetHeight > 0
        else { return }

        let scaleX = CGFloat(targetWidth) / imagePixelSize.width
        let scaleY = CGFloat(targetHeight) / imagePixelSize.height
        let newW = max(1, Int((CGFloat(srcCG.width) * scaleX).rounded()))
        let newH = max(1, Int((CGFloat(srcCG.height) * scaleY).rounded()))

        let colorSpace = srcCG.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: newW,
            height: newH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let scaledCG = {
            ctx.interpolationQuality = .high
            ctx.draw(srcCG, in: CGRect(x: 0, y: 0, width: newW, height: newH))
            return ctx.makeImage()
        }() else { return }

        pushUndo()

        annotations = annotations.map { ann in
            var a = ann
            a.startPoint = CGPoint(x: ann.startPoint.x * scaleX, y: ann.startPoint.y * scaleY)
            a.endPoint   = CGPoint(x: ann.endPoint.x * scaleX,   y: ann.endPoint.y * scaleY)
            if !ann.points.isEmpty {
                a.points = ann.points.map { CGPoint(x: $0.x * scaleX, y: $0.y * scaleY) }
            }
            return a
        }

        screenshotCropRect = CGRect(
            x: screenshotCropRect.minX * scaleX,
            y: screenshotCropRect.minY * scaleY,
            width: screenshotCropRect.width * scaleX,
            height: screenshotCropRect.height * scaleY
        )

        let scaledNSImage = NSImage(size: NSSize(width: newW, height: newH))
        scaledNSImage.addRepresentation(NSBitmapImageRep(cgImage: scaledCG))
        rawImage = scaledNSImage
        applyDisplayImage(from: scaledNSImage)
    }

    // MARK: - Annotation Helpers

    /// Shifts all annotation points by `delta` in both X and Y (image pixel space).
    /// Used to keep annotations anchored to screenshot content when the template
    /// padding is added or removed (which expands/shrinks the canvas uniformly).
    private func shiftAnnotations(by delta: CGPoint) {
        guard !annotations.isEmpty, delta != .zero else { return }
        annotations = annotations.map { ann in
            var shifted = ann
            shifted.startPoint = CGPoint(x: ann.startPoint.x + delta.x,
                                         y: ann.startPoint.y + delta.y)
            shifted.endPoint   = CGPoint(x: ann.endPoint.x + delta.x,
                                         y: ann.endPoint.y + delta.y)
            if !ann.points.isEmpty {
                shifted.points = ann.points.map {
                    CGPoint(x: $0.x + delta.x, y: $0.y + delta.y)
                }
            }
            return shifted
        }
    }

    /// Returns the screenshot's top-left origin inside the templated canvas (image-pixel space).
    /// `screenshotPixelSize` must be the actual CGImage pixel dimensions of the (possibly cropped) screenshot.
    private func screenshotOriginInTemplatedCanvas(
        screenshotPixelSize: CGSize,
        padding: Int,
        aspectRatio: Double?,
        alignment: CanvasAlignment = .middleCenter
    ) -> CGPoint {
        let screenshotW = screenshotPixelSize.width
        let screenshotH = screenshotPixelSize.height
        let paddingPixels = CGFloat(padding) * displayBackingScale

        let baseW = screenshotW + paddingPixels * 2
        let baseH = screenshotH + paddingPixels * 2

        var canvasW = baseW
        var canvasH = baseH

        if let ratio = aspectRatio, ratio > 0 {
            let current = baseW / baseH
            if current < ratio {
                canvasW = baseH * ratio
            } else if current > ratio {
                canvasH = baseW / ratio
            }
        }

        let totalSpaceX = canvasW - screenshotW
        let totalSpaceY = canvasH - screenshotH
        return CGPoint(
            x: totalSpaceX * alignment.horizontalFraction,
            y: totalSpaceY * alignment.verticalFraction
        )
    }

    private func aspectRatioValue(for id: UUID?) -> Double? {
        guard let id else { return nil }
        return editorAspectRatios.first(where: { $0.id == id })?.ratio
    }

    private func normalizedAspectRatioID(_ id: UUID?) -> UUID? {
        guard let id else { return nil }
        return editorAspectRatios.contains(where: { $0.id == id }) ? id : nil
    }

    private func applyEditorTemplate(_ template: EditorTemplatePreset) {
        selectedWallpaper = template.wallpaperSource
        editorPadding = template.padding
        editorCornerRadius = template.cornerRadius
        shadowIntensity = template.shadowIntensity
        screenshotAlignment = template.alignment
        editorAspectRatioID = normalizedAspectRatioID(template.aspectRatioID)
        watermarkSettings = template.watermarkSettings
    }

    private func overwriteSelectedTemplate() {
        guard let appSettings,
              let selectedTemplate = appSettings.selectedEditorTemplate
        else { return }

        let alert = NSAlert()
        alert.messageText = "Save Template?"
        alert.informativeText = "Save the current setup to \"\(selectedTemplate.name)\"?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        saveCurrentTemplateSetup()
    }

    private func saveCurrentTemplateSetup() {
        guard let appSettings,
              let id = appSettings.selectedEditorTemplateID,
              let index = appSettings.editorTemplates.firstIndex(where: { $0.id == id })
        else { return }

        var templates = appSettings.editorTemplates
        templates[index].wallpaperSource = selectedWallpaper
        templates[index].padding = editorPadding
        templates[index].cornerRadius = editorCornerRadius
        templates[index].shadowIntensity = shadowIntensity
        templates[index].aspectRatioID = editorAspectRatioID
        templates[index].alignment = screenshotAlignment
        templates[index].watermarkSettings = watermarkSettings
        appSettings.editorTemplates = templates
    }

    private func saveAsNewTemplate() {
        guard let appSettings else { return }

        let alert = NSAlert()
        alert.messageText = "Save Template"
        alert.informativeText = "Enter a name for this template."
        alert.alertStyle = .informational

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        input.stringValue = suggestedTemplateName(existing: appSettings.editorTemplates.map(\.name))
        alert.accessoryView = input

        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        let template = EditorTemplatePreset(
            name: name,
            wallpaperSource: selectedWallpaper,
            padding: editorPadding,
            cornerRadius: editorCornerRadius,
            shadowIntensity: shadowIntensity,
            aspectRatioID: editorAspectRatioID,
            alignment: screenshotAlignment,
            watermarkSettings: watermarkSettings
        )
        appSettings.editorTemplates.append(template)
        appSettings.selectedEditorTemplateID = template.id
    }

    private func suggestedTemplateName(existing names: [String]) -> String {
        let base = "My template"
        guard names.contains(base) else { return base }
        var index = 2
        while names.contains("\(base) \(index)") {
            index += 1
        }
        return "\(base) \(index)"
    }

    // MARK: - Delete

    private func deleteSelected() {
        guard let id = selectedAnnotationID,
              let idx = annotations.firstIndex(where: { $0.id == id })
        else { return }

        pushUndo()
        annotations.remove(at: idx)
        selectedAnnotationID = nil
    }

    private func nudgeSelectedAnnotation(by delta: CGSize) {
        guard let id = selectedAnnotationID,
              let idx = annotations.firstIndex(where: { $0.id == id })
        else { return }

        pushUndo()
        annotations[idx].startPoint.x += delta.width
        annotations[idx].startPoint.y += delta.height
        annotations[idx].endPoint.x += delta.width
        annotations[idx].endPoint.y += delta.height
        if annotations[idx].tool == .freeDraw {
            annotations[idx].points = annotations[idx].points.map {
                CGPoint(x: $0.x + delta.width, y: $0.y + delta.height)
            }
        }
    }

    private func installKeyMonitorIfNeeded() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Don't steal events from text editing fields.
            if let firstResponder = event.window?.firstResponder {
                if firstResponder is NSTextView || firstResponder is NSTextField {
                    return event
                }
            }

            // Ignore when using command/option/control modified shortcuts.
            let blockedModifiers: NSEvent.ModifierFlags = [.command, .option, .control]
            let hasBlockedModifier = !event.modifierFlags.intersection(blockedModifiers).isEmpty

            // Cmd+1/2/3 → switch editor mode by visible segment position.
            // For PDFs the Edit segment is hidden, so Cmd+2 = View and Cmd+3 unbound.
            let isCmdOnly = event.modifierFlags
                .intersection([.command, .option, .control, .shift]) == [.command]
            if isCmdOnly,
               let win = hostingWindow,
               event.window === win,
               event.keyCode == 18 || event.keyCode == 19 || event.keyCode == 20 {
                let modes: [EditorMode] = isPDFSession ? [.annotate, .view] : [.annotate, .edit, .view]
                let index: Int
                switch event.keyCode {
                case 18: index = 0
                case 19: index = 1
                case 20: index = 2
                default: index = -1
                }
                if index >= 0 && index < modes.count {
                    editorMode = modes[index]
                    return nil
                }
                // Out of range (e.g. Cmd+3 in PDF mode) — swallow rather than passing through
                // so it can't fall into some other shortcut.
                return nil
            }

            // Backspace (51) or forward-delete (117) → delete selected annotation.
            if event.keyCode == 51 || event.keyCode == 117 {
                if hasBlockedModifier { return event }
                deleteSelected()
                return nil
            }

            // Arrow keys → nudge selected annotation, or navigate sessions.
            let isArrow = event.keyCode == 123 || event.keyCode == 124
                || event.keyCode == 125 || event.keyCode == 126
            if isArrow,
               let win = hostingWindow,
               event.window === win {
                // Nudge selected annotation (shift = 10px, otherwise 1px)
                let shiftOnly = event.modifierFlags.intersection([.command, .option, .control]).isEmpty
                if shiftOnly,
                   editorMode == .annotate,
                   selectedAnnotationID != nil {
                    let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
                    var nudge = CGSize.zero
                    switch event.keyCode {
                    case 123: nudge.width = -step  // left
                    case 124: nudge.width =  step  // right
                    case 126: nudge.height = -step // up
                    case 125: nudge.height =  step // down
                    default: break
                    }
                    nudgeSelectedAnnotation(by: nudge)
                    return nil
                }
                // Fall through to session navigation
                if !hasBlockedModifier, sessions.count > 1 {
                    switch event.keyCode {
                    case 123, 126:  // left, up → previous
                        goToPreviousSession()
                    case 124, 125:  // right, down → next
                        goToNextSession()
                    default: break
                    }
                    return nil
                }
            }

            return event
        }

        guard magnifyMonitor == nil else { return }
        magnifyMonitor = NSEvent.addLocalMonitorForEvents(matching: .magnify) { event in
            guard let win = hostingWindow, event.window === win else { return event }
            handleMagnifyEvent(event)
            return event
        }

        guard middleMouseMonitor == nil else { return }
        middleMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.otherMouseDown, .otherMouseDragged, .otherMouseUp]
        ) { event in
            guard event.buttonNumber == 2,
                  let win = hostingWindow, event.window === win,
                  zoomLevel > 1.0,
                  let scrollView = nsScrollView
            else { return event }

            switch event.type {
            case .otherMouseDown:
                middleMouseDragOrigin = event.locationInWindow
                middleMouseScrollOrigin = scrollView.contentView.bounds.origin
                NSCursor.closedHand.push()
                return nil
            case .otherMouseDragged:
                guard let dragOrigin = middleMouseDragOrigin,
                      let scrollOrigin = middleMouseScrollOrigin else { return event }
                let delta = NSPoint(
                    x: event.locationInWindow.x - dragOrigin.x,
                    y: event.locationInWindow.y - dragOrigin.y
                )
                let newOrigin = NSPoint(
                    x: scrollOrigin.x - delta.x,
                    y: scrollOrigin.y + delta.y
                )
                scrollView.contentView.scroll(to: newOrigin)
                scrollView.reflectScrolledClipView(scrollView.contentView)
                return nil
            case .otherMouseUp:
                middleMouseDragOrigin = nil
                middleMouseScrollOrigin = nil
                NSCursor.pop()
                return nil
            default:
                return event
            }
        }

        guard flagsMonitor == nil else { return }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            guard let win = hostingWindow, event.window === win else { return event }
            let optionDown = event.modifierFlags.contains(.option)
            if optionDown && editorMode == .annotate && !showingCopyCursor {
                NSCursor.dragCopy.push()
                showingCopyCursor = true
            } else if !optionDown && showingCopyCursor {
                NSCursor.pop()
                showingCopyCursor = false
            }
            return event
        }
    }

    private func handleMagnifyEvent(_ event: NSEvent) {
        let oldScale = effectiveScale
        let newZoom = min(max(zoomLevel * (1 + event.magnification), minZoomLevel), maxZoomLevel)
        let newScale = fitScale * newZoom

        guard let scrollView = nsScrollView, oldScale > 0 else {
            zoomLevel = newZoom
            syncZoomToPDFGroup()
            return
        }

        let scaleFactor = newScale / oldScale

        let windowPoint = event.locationInWindow
        let scrollOrigin = scrollView.documentVisibleRect.origin

        let cursorInClip = NSPoint(
            x: windowPoint.x - scrollView.convert(NSPoint.zero, to: nil).x,
            y: windowPoint.y - scrollView.convert(NSPoint.zero, to: nil).y
        )

        let contentPoint = NSPoint(
            x: scrollOrigin.x + cursorInClip.x,
            y: scrollOrigin.y + cursorInClip.y
        )

        let newContentPoint = NSPoint(
            x: contentPoint.x * scaleFactor,
            y: contentPoint.y * scaleFactor
        )

        let newOrigin = NSPoint(
            x: newContentPoint.x - cursorInClip.x,
            y: newContentPoint.y - cursorInClip.y
        )

        zoomLevel = newZoom
        syncZoomToPDFGroup()

        DispatchQueue.main.async {
            scrollView.contentView.scroll(to: newOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        if let monitor = magnifyMonitor {
            NSEvent.removeMonitor(monitor)
            magnifyMonitor = nil
        }
        if let monitor = middleMouseMonitor {
            NSEvent.removeMonitor(monitor)
            middleMouseMonitor = nil
        }
        if let monitor = flagsMonitor {
            if showingCopyCursor {
                NSCursor.pop()
                showingCopyCursor = false
            }
            NSEvent.removeMonitor(monitor)
            flagsMonitor = nil
        }
    }

    private func goToPreviousSession() {
        guard sessions.count > 1,
              let current = sessions.firstIndex(where: { $0.id == activeSessionID })
        else { return }
        let prev = (current - 1 + sessions.count) % sessions.count
        switchToSession(sessions[prev].id)
    }

    private func goToNextSession() {
        guard sessions.count > 1,
              let current = sessions.firstIndex(where: { $0.id == activeSessionID })
        else { return }
        let next = (current + 1) % sessions.count
        switchToSession(sessions[next].id)
    }

    private func trashScreenshot() {
        try? FileManager.default.trashItem(at: imageURL, resultingItemURL: nil)
        onDismiss()
    }

    // MARK: - Tool Change

    private func handleToolChange(_ tool: AnnotationTool) {
        if tool == .spotlight, imagePixelSize.width > 0, imagePixelSize.height > 0 {
            let insetX = imagePixelSize.width * 0.15
            let insetY = imagePixelSize.height * 0.15
            let spotlightRect = CGRect(
                x: insetX,
                y: insetY,
                width: imagePixelSize.width - insetX * 2,
                height: imagePixelSize.height - insetY * 2
            )
            pushUndo()
            let annotation = Annotation(
                tool: .spotlight,
                startPoint: spotlightRect.origin,
                endPoint: CGPoint(x: spotlightRect.maxX, y: spotlightRect.maxY),
                style: currentStyle
            )
            annotations.append(annotation)
            selectedAnnotationID = annotation.id
        }
    }

    // MARK: - Rotation

    /// Rotate by `delta` × 90° clockwise (use +1 for right, +3 for left).
    /// Updates rotationSteps, remaps annotations and screenshotCropRect so they
    /// stay anchored to the same visual content, then re-renders.
    private func rotate(deltaSteps delta: Int) {
        guard rawImage != nil else { return }
        let d = ((delta % 4) + 4) % 4
        guard d != 0 else { return }

        pushUndo()
        selectedAnnotationID = nil

        // Compute pre-rotation screenshot size (rotated-raw dims minus any crop).
        let oldScreenshotSize: CGSize = {
            if !screenshotCropRect.isEmpty { return screenshotCropRect.size }
            if let cg = rawImage?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                let (w, h) = Self.rotatedDims(width: CGFloat(cg.width),
                                              height: CGFloat(cg.height),
                                              steps: rotationSteps)
                return CGSize(width: w, height: h)
            }
            return imagePixelSize
        }()

        // Gradient offsets (template padding); .zero for PDFs/no-template sessions.
        let oldGradientOffset: CGPoint = {
            guard selectedWallpaper != nil, !isPDFSession else { return .zero }
            return screenshotOriginInTemplatedCanvas(
                screenshotPixelSize: oldScreenshotSize,
                padding: editorPadding,
                aspectRatio: selectedEditorAspectRatio?.ratio,
                alignment: screenshotAlignment
            )
        }()

        let newScreenshotSize: CGSize = (d % 2 == 0)
            ? oldScreenshotSize
            : CGSize(width: oldScreenshotSize.height, height: oldScreenshotSize.width)

        let newGradientOffset: CGPoint = {
            guard selectedWallpaper != nil, !isPDFSession else { return .zero }
            return screenshotOriginInTemplatedCanvas(
                screenshotPixelSize: newScreenshotSize,
                padding: editorPadding,
                aspectRatio: selectedEditorAspectRatio?.ratio,
                alignment: screenshotAlignment
            )
        }()

        // Remap each annotation point: display → screenshot-relative → rotate → new display.
        let remap: (CGPoint) -> CGPoint = { p in
            let sr = CGPoint(x: p.x - oldGradientOffset.x, y: p.y - oldGradientOffset.y)
            let rotated = Self.rotatePoint90(sr, steps: d, in: oldScreenshotSize)
            return CGPoint(x: rotated.x + newGradientOffset.x, y: rotated.y + newGradientOffset.y)
        }
        annotations = annotations.map { ann in
            var a = ann
            a.startPoint = remap(ann.startPoint)
            a.endPoint = remap(ann.endPoint)
            if !ann.points.isEmpty {
                a.points = ann.points.map(remap)
            }
            return a
        }

        // Remap screenshotCropRect: it's in rotated-raw dims, so rotate it within
        // the OLD rotated-raw dims to get the new rotated-raw position.
        if !screenshotCropRect.isEmpty,
           let cg = rawImage?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let (oldRotW, oldRotH) = Self.rotatedDims(width: CGFloat(cg.width),
                                                      height: CGFloat(cg.height),
                                                      steps: rotationSteps)
            screenshotCropRect = Self.rotateRect90(
                screenshotCropRect, steps: d,
                in: CGSize(width: oldRotW, height: oldRotH)
            )
        }

        rotationSteps = ((rotationSteps + d) % 4 + 4) % 4

        if let rawImg = rawImage {
            applyDisplayImage(from: rawImg)
        }
        saveActiveSessionState()
    }

    private func rotateLeft()  { rotate(deltaSteps: 3) }  // 90° CCW = +3 mod 4
    private func rotateRight() { rotate(deltaSteps: 1) }  // 90° CW

    // MARK: - Rotation helpers (pure, static)

    /// Returns (width, height) after applying `steps` × 90° rotation.
    /// Dimensions swap when steps is odd.
    static func rotatedDims(width: CGFloat, height: CGFloat, steps: Int) -> (CGFloat, CGFloat) {
        let s = ((steps % 4) + 4) % 4
        return (s % 2 == 0) ? (width, height) : (height, width)
    }

    /// Rotate a CGImage by `steps` × 90° clockwise (visual). Returns the input
    /// unchanged if steps is a multiple of 4.
    static func rotateCGImage90(_ image: CGImage, steps: Int, ciContext: CIContext) -> CGImage? {
        let s = ((steps % 4) + 4) % 4
        guard s != 0 else { return image }
        let orientation: CGImagePropertyOrientation
        switch s {
        case 1: orientation = .right   // 90° CW visual
        case 2: orientation = .down    // 180°
        case 3: orientation = .left    // 90° CCW visual
        default: orientation = .up
        }
        let ci = CIImage(cgImage: image).oriented(orientation)
        return ciContext.createCGImage(ci, from: ci.extent)
    }

    /// Rotate a point by `steps` × 90° clockwise within source dimensions
    /// `originalSize` (top-left origin, continuous coordinates). The result is
    /// in the rotated dimensions which are swapped if `steps` is odd.
    static func rotatePoint90(_ p: CGPoint, steps: Int, in originalSize: CGSize) -> CGPoint {
        let s = ((steps % 4) + 4) % 4
        let W = originalSize.width
        let H = originalSize.height
        switch s {
        case 1: return CGPoint(x: H - p.y, y: p.x)        // 90° CW
        case 2: return CGPoint(x: W - p.x, y: H - p.y)    // 180°
        case 3: return CGPoint(x: p.y, y: W - p.x)        // 90° CCW
        default: return p
        }
    }

    /// Rotate a rect by `steps` × 90° clockwise within source dimensions `originalSize`.
    static func rotateRect90(_ r: CGRect, steps: Int, in originalSize: CGSize) -> CGRect {
        let s = ((steps % 4) + 4) % 4
        let W = originalSize.width
        let H = originalSize.height
        switch s {
        case 1: return CGRect(x: H - r.minY - r.height, y: r.minX,
                              width: r.height, height: r.width)
        case 2: return CGRect(x: W - r.minX - r.width, y: H - r.minY - r.height,
                              width: r.width, height: r.height)
        case 3: return CGRect(x: r.minY, y: W - r.minX - r.width,
                              width: r.height, height: r.width)
        default: return r
        }
    }

    // MARK: - Undo

    private func pushUndo() {
        undoStack.append(EditorSnapshot(
            annotations: annotations,
            image: image,
            rawImage: rawImage,
            selectedWallpaper: selectedWallpaper,
            imagePixelSize: imagePixelSize,
            cropRect: cropRect,
            screenshotCropRect: screenshotCropRect,
            photoAdjustments: photoAdjustments,
            rotationSteps: rotationSteps
        ))
    }

    private func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        annotations = snapshot.annotations
        // Restore the non-destructive crop rect before re-rendering.
        if let scRect = snapshot.screenshotCropRect {
            screenshotCropRect = scRect
        }
        if let snapImage = snapshot.image {
            image = snapImage
            imagePixelSize = snapshot.imagePixelSize
            // Re-extract the CGImage from the snapshot's bitmap representation
            // so currentDisplayCGImage stays consistent with the restored image.
            currentDisplayCGImage = (snapImage.representations.first as? NSBitmapImageRep)?.cgImage
                ?? snapImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        rawImage = snapshot.rawImage
        selectedWallpaper = snapshot.selectedWallpaper
        cropRect = snapshot.cropRect ?? CGRect(origin: .zero, size: imagePixelSize)
        selectedAnnotationID = nil
        // Restore rotation BEFORE photoAdjustments so the re-render uses the right orientation.
        rotationSteps = snapshot.rotationSteps
        // Restore photo adjustments — triggers onChange which re-renders the display image.
        photoAdjustments = snapshot.photoAdjustments
    }

    // MARK: - Custom Background Images

    private func pickWatermarkImage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, .jpeg, .svg, .image]
        panel.title = "Choose Watermark Image"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        watermarkSettings.imagePath = url.path
        watermarkSettings.isEnabled = true
    }

    private func addCustomBackgroundImage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let path = appSettings?.addCustomBackgroundImage(from: url) {
            selectedWallpaper = .customImage(path: path)
        }
    }

    private func removeCustomBackgroundImage(_ path: String) {
        if case .customImage(let current) = selectedWallpaper, current == path {
            selectedWallpaper = nil
        }
        appSettings?.removeCustomBackgroundImage(at: path)
    }

    // MARK: - Session Management

    /// Snapshots the current @State values back into the active ImageSession.
    private func saveActiveSessionState() {
        guard let session = activeSession else { return }
        session.image = image
        session.rawImage = rawImage
        session.currentDisplayCGImage = currentDisplayCGImage
        session.metadata = imageMetadata
        session.imagePixelSize = imagePixelSize
        session.screenshotCropRect = screenshotCropRect
        session.annotations = annotations
        session.selectedAnnotationID = selectedAnnotationID
        session.isCropping = isCropping
        session.cropRect = cropRect
        session.preCropScreenshotCropRect = preCropScreenshotCropRect
        session.preCropSnapshot = preCropSnapshot
        session.zoomLevel = zoomLevel
        session.fitScale = fitScale
        session.selectedWallpaper = selectedWallpaper
        session.editorAspectRatioID = editorAspectRatioID
        session.editorPadding = editorPadding
        session.editorCornerRadius = editorCornerRadius
        session.shadowIntensity = shadowIntensity
        session.screenshotAlignment = screenshotAlignment
        session.watermarkSettings = watermarkSettings
        session.photoAdjustments = photoAdjustments
        session.rotationSteps = rotationSteps
        session.undoStack = undoStack
        session.templateRenderer = templateRenderer
        session.generateThumbnail()
    }

    /// Populates @State from the given ImageSession. Sets `isRestoringSession` for
    /// the duration of the surrounding render pass so the onChange observers don't
    /// treat these assignments as user edits.
    private func restoreSessionState(from session: ImageSession) {
        isRestoringSession = true

        image = session.image
        rawImage = session.rawImage
        currentDisplayCGImage = session.currentDisplayCGImage
        imageMetadata = session.metadata
        imagePixelSize = session.imagePixelSize
        screenshotCropRect = session.screenshotCropRect
        annotations = session.annotations
        selectedAnnotationID = session.selectedAnnotationID
        isCropping = session.isCropping
        cropRect = session.cropRect
        preCropScreenshotCropRect = session.preCropScreenshotCropRect
        preCropSnapshot = session.preCropSnapshot
        zoomLevel = session.zoomLevel
        fitScale = session.fitScale
        selectedWallpaper = session.selectedWallpaper
        editorAspectRatioID = session.editorAspectRatioID
        editorPadding = session.editorPadding
        editorCornerRadius = session.editorCornerRadius
        shadowIntensity = session.shadowIntensity
        screenshotAlignment = session.screenshotAlignment
        watermarkSettings = session.watermarkSettings
        photoAdjustments = session.photoAdjustments
        rotationSteps = session.rotationSteps
        // Note: editorMode is intentionally NOT restored per-session — the active mode
        // is global to the editor window, not tied to the image being viewed.
        undoStack = session.undoStack
        templateRenderer = session.templateRenderer

        // Clear on the next runloop tick — after SwiftUI has fired the onChange
        // observers for the assignments above.
        DispatchQueue.main.async {
            isRestoringSession = false
        }
    }

    /// Activate the session with the given id, restoring its persisted state and
    /// loading the image from disk if it hasn't been activated yet.
    private func switchToSession(_ id: UUID) {
        guard id != activeSessionID,
              let target = sessions.first(where: { $0.id == id })
        else { return }
        saveActiveSessionState()
        activeSessionID = id
        restoreSessionState(from: target)
        // Edit mode (photo adjustments) doesn't apply to PDFs — snap to Annotate.
        if target.isPDF && editorMode == .edit {
            editorMode = .annotate
        }
        if target.image == nil {
            loadImage()
        } else {
            updateFitScale(viewSize: lastViewSize)
        }
    }

    /// Remove a session from the strip. The strip is only visible when
    /// `sessions.count > 1`, so this should never be called for the final image —
    /// guard against misuse just in case.
    private func removeSession(_ id: UUID) {
        guard sessions.count > 1 else { return }
        guard let removedIdx = sessions.firstIndex(where: { $0.id == id }) else { return }

        if id == activeSessionID {
            let nextIdx = removedIdx > 0 ? removedIdx - 1 : 1
            let nextID = sessions[nextIdx].id
            sessions.remove(at: removedIdx)
            activeSessionID = nextID
            if let target = sessions.first(where: { $0.id == nextID }) {
                restoreSessionState(from: target)
                if target.isPDF && editorMode == .edit {
                    editorMode = .annotate
                }
                if target.image == nil {
                    loadImage()
                } else {
                    updateFitScale(viewSize: lastViewSize)
                }
            }
        } else {
            sessions.remove(at: removedIdx)
        }
    }

    // MARK: - Save

    /// Returns the current CGImage for rendering/export, using the stored reference
    /// to avoid re-scaling via NSImage.cgImage(forProposedRect:).
    private func currentCGImage() -> CGImage? {
        if let cg = currentDisplayCGImage { return cg }
        return image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// Produce the final composited image (page/screenshot + annotations +
    /// watermark) for a raster export path (clipboard, PNG, print).
    ///
    /// For an *uncropped* PDF page this re-rasterizes from the source page at the
    /// scan's native resolution so a high-DPI document isn't downsampled to the
    /// editor's on-screen resolution (point size × backing scale). Cropped PDF
    /// pages and non-PDF sessions composite onto the existing display raster.
    /// "Uncropped" is detected by comparing the display raster's pixel size to
    /// the full page size — a crop produces a smaller display image.
    private func composedRasterOutput(
        pdfPage: PDFPage?,
        displayCG: CGImage?,
        annotations: [Annotation],
        watermark: WatermarkSettings,
        renderer: AnnotationRenderer
    ) -> CGImage? {
        if let page = pdfPage {
            let full = page.rotatedMediaBoxSize
            let fullW = Int((full.width * displayBackingScale).rounded())
            let fullH = Int((full.height * displayBackingScale).rounded())
            let isCropped = displayCG.map { $0.width != fullW || $0.height != fullH } ?? false
            if !isCropped,
               let native = renderer.renderPDFPageNative(
                   page: page,
                   annotations: annotations,
                   displayBackingScale: displayBackingScale,
                   watermark: watermark
               ) {
                return native
            }
        }
        guard let cg = displayCG else { return nil }
        return try? renderer.render(
            image: cg,
            annotations: annotations,
            backingScale: displayBackingScale,
            cropRect: nil,
            watermark: watermark
        )
    }

    /// The active session's PDF page, if it is a PDF session.
    private func activePDFPage() -> PDFPage? {
        activeSession?.pdfPageSource.flatMap { $0.document.page(at: $0.pageIndex) }
    }

    private func copyToClipboard() {
        copyToClipboardSilent()
        onDismiss()
    }

    /// Copies the current image to the clipboard without dismissing the editor.
    private func copyToClipboardSilent() {
        let renderer = AnnotationRenderer()
        guard let outputImage = composedRasterOutput(
            pdfPage: activePDFPage(),
            displayCG: currentCGImage(),
            annotations: annotations,
            watermark: watermarkSettings,
            renderer: renderer
        ) else { return }

        let bitmapRep = NSBitmapImageRep(cgImage: outputImage)
        let size = NSSize(width: outputImage.width, height: outputImage.height)
        let finalImage = NSImage(size: size)
        finalImage.addRepresentation(bitmapRep)

        NSPasteboard.general.clearContents()

        // Write a single pasteboard item that carries both a file URL (so apps
        // like Slack derive a filename) and the TIFF image data. Using separate
        // writeObjects entries caused recipient apps to see two images.
        if let pngData = bitmapRep.representation(using: .png, properties: [:]) {
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("SimplShot_pasted.png")
            try? pngData.write(to: tempURL)

            let item = NSPasteboardItem()
            item.setString(tempURL.absoluteString, forType: .fileURL)
            if let tiffData = finalImage.tiffRepresentation {
                item.setData(tiffData, forType: .tiff)
            }
            item.setData(pngData, forType: .png)
            NSPasteboard.general.writeObjects([item])
        } else {
            NSPasteboard.general.writeObjects([finalImage])
        }
    }

    /// Discard all in-memory edits across every session and close the editor without
    /// writing to disk. The on-disk files remain untouched.
    private func cancelEdits() {
        // If there are any pending edits (annotations, adjustments, crop, etc.),
        // confirm before throwing them away.
        let hasEdits = sessions.contains { session in
            !session.annotations.isEmpty ||
            !session.photoAdjustments.isDefault ||
            !session.undoStack.isEmpty ||
            (session.id == activeSessionID &&
             (!annotations.isEmpty || !photoAdjustments.isDefault || !undoStack.isEmpty))
        }
        if hasEdits {
            let alert = NSAlert()
            alert.messageText = "Discard Edits?"
            alert.informativeText = "All unsaved annotations and adjustments will be lost."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Discard")
            alert.addButton(withTitle: "Keep Editing")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        onDismiss()
    }

    private func sessionHasEdits(_ session: ImageSession) -> Bool {
        !session.annotations.isEmpty ||
        !session.photoAdjustments.isDefault ||
        session.watermarkSettings.isEnabled ||
        session.selectedWallpaper != nil ||
        !session.undoStack.isEmpty
    }

    private func saveOverwrite() {
        do {
            saveActiveSessionState()

            // Group PDF sessions by their shared pdfGroupID and export each group
            // as a single multi-page PDF. Non-PDF sessions export individually.
            var handledPDFGroups: Set<UUID> = []
            for session in sessions {
                if let groupID = session.pdfGroupID {
                    guard !handledPDFGroups.contains(groupID) else { continue }
                    handledPDFGroups.insert(groupID)
                    let groupSessions = sessions.filter { $0.pdfGroupID == groupID }
                    let groupHasEdits = groupSessions.contains { sessionHasEdits($0) }
                    if groupHasEdits {
                        try PDFExportService.exportPDF(
                            sessions: groupSessions,
                            backingScale: displayBackingScale,
                            to: session.imageURL
                        )
                    }
                } else if sessionHasEdits(session) {
                    try writeSession(session, to: session.imageURL)
                }
            }

            if sessions.count == 1 {
                copyToClipboardSilent()
            }
            requestReviewIfEligible()
            onDismiss()
        } catch {
            showSaveError(error)
        }
    }

    /// Render and write one session to `url`. Returns silently when the session
    /// has no image data (e.g. user never activated this image — no edits to save).
    private func writeSession(_ session: ImageSession, to url: URL) throws {
        let cg = session.currentDisplayCGImage
            ?? session.image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        guard let cgImage = cg else { return }

        let renderer = AnnotationRenderer()
        let outputImage = try renderer.render(
            image: cgImage,
            annotations: session.annotations,
            backingScale: displayBackingScale,
            cropRect: nil,
            watermark: session.watermarkSettings
        )
        try Self.writeImage(outputImage, to: url)
    }

    /// Write a CGImage to disk, picking the encoder from the URL's extension.
    private static func writeImage(_ cgImage: CGImage, to url: URL) throws {
        let ext = url.pathExtension.lowercased()

        #if !APPSTORE
        if ext == "webp" {
            let data = try WebPEncoder().encode(cgImage, config: .preset(.photo, quality: 80))
            try data.write(to: url)
            return
        }
        #endif

        let utType: CFString
        switch ext {
        case "png":  utType = UTType.png.identifier as CFString
        case "heic": utType = UTType.heic.identifier as CFString
        default:     utType = UTType.jpeg.identifier as CFString
        }

        var properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: 72.0,
            kCGImagePropertyDPIHeight: 72.0,
        ]
        if ext != "png" {
            properties[kCGImageDestinationLossyCompressionQuality] = 0.9
        }

        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, utType, 1, nil) else {
            throw AnnotationRenderer.RenderError.cannotCreateOutputImage
        }
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw AnnotationRenderer.RenderError.cannotCreateOutputImage
        }
    }

    private func saveAs() {
        let panel = NSSavePanel()

        // Held for the lifetime of the (modal) panel so its popup target stays alive.
        var formatPicker: SaveFormatPicker?

        if isPDFSession {
            let pdfName = imageURL.deletingPathExtension().lastPathComponent + ".pdf"
            panel.nameFieldStringValue = pdfName
            panel.allowedContentTypes = [.pdf]
        } else {
            let ext = imageURL.pathExtension.lowercased()
            let sourceType: UTType
            switch ext {
            case "png":  sourceType = .png
            case "heic": sourceType = .heic
            #if !APPSTORE
            case "webp": sourceType = .webP
            #endif
            default:     sourceType = .jpeg
            }
            // Offer every supported raster format via an accessory popup,
            // defaulting to the source image's format (first entry).
            var formats: [SaveFormatPicker.Format] = [
                .init(label: "PNG", type: .png, ext: "png"),
                .init(label: "JPEG", type: .jpeg, ext: "jpg"),
                .init(label: "HEIC", type: .heic, ext: "heic"),
            ]
            #if !APPSTORE
            formats.append(.init(label: "WebP", type: .webP, ext: "webp"))
            #endif
            if let idx = formats.firstIndex(where: { $0.type == sourceType }) {
                formats.insert(formats.remove(at: idx), at: 0)
            }

            let baseName = imageURL.deletingPathExtension().lastPathComponent
            panel.nameFieldStringValue = baseName
            panel.allowedContentTypes = [formats[0].type]

            let picker = SaveFormatPicker(formats: formats, panel: panel)
            panel.accessoryView = picker.makeAccessoryView()
            formatPicker = picker
        }
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = formatPicker  // keep alive until the panel closes

        do {
            if isPDFSession, let groupID = activeSession?.pdfGroupID {
                saveActiveSessionState()
                let groupSessions = sessions.filter { $0.pdfGroupID == groupID }
                try PDFExportService.exportPDF(
                    sessions: groupSessions,
                    backingScale: displayBackingScale,
                    to: url
                )
            } else {
                try exportAndSave(to: url)
            }
            requestReviewIfEligible()
            onDismiss()
        } catch {
            showSaveError(error)
        }
    }

    private func exportAndSave(to url: URL) throws {
        guard let cgImage = currentCGImage() else { return }

        let renderer = AnnotationRenderer()
        // Crop is applied destructively in applyCrop(), so at export time
        // the image is already the cropped region — no crop rect needed.
        let outputImage = try renderer.render(
            image: cgImage,
            annotations: annotations,
            backingScale: displayBackingScale,
            cropRect: nil,
            watermark: watermarkSettings
        )
        try Self.writeImage(outputImage, to: url)
    }

    /// Request an App Store review after the user saves their 3rd screenshot with annotations.
    private func requestReviewIfEligible() {
        #if APPSTORE
        guard !annotations.isEmpty else { return }
        let key = Constants.UserDefaultsKeys.annotationSaveCount
        let count = UserDefaults.standard.integer(forKey: key) + 1
        UserDefaults.standard.set(count, forKey: key)
        if count == 3 {
            let alert = NSAlert()
            alert.messageText = "Enjoying SimplShot?"
            alert.informativeText = "We'd love your feedback — it helps us grow and make SimplShot even better!"
            alert.addButton(withTitle: "Rate SimplShot")
            alert.addButton(withTitle: "Not Now")
            alert.alertStyle = .informational
            if alert.runModal() == .alertFirstButtonReturn {
                requestReview()
            }
        }
        #endif
    }

    // MARK: - Print

    private func printImage() {
        saveActiveSessionState()

        var images: [NSImage] = []
        let renderer = AnnotationRenderer()

        for session in sessions {
            let cg = session.currentDisplayCGImage
                ?? session.image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            let page = session.pdfPageSource.flatMap { $0.document.page(at: $0.pageIndex) }
            guard let outputCG = composedRasterOutput(
                pdfPage: page,
                displayCG: cg,
                annotations: session.annotations,
                watermark: session.watermarkSettings,
                renderer: renderer
            ) else { continue }
            let size = NSSize(width: outputCG.width, height: outputCG.height)
            let nsImage = NSImage(size: size)
            nsImage.addRepresentation(NSBitmapImageRep(cgImage: outputCG))
            images.append(nsImage)
        }

        guard !images.isEmpty else { return }

        let printView = MultiPagePrintView(images: images)
        let printOperation = NSPrintOperation(view: printView)
        printOperation.printInfo.horizontalPagination = .fit
        printOperation.printInfo.verticalPagination = .clip
        printOperation.printInfo.isHorizontallyCentered = true
        printOperation.printInfo.isVerticallyCentered = true
        printOperation.runModal(for: hostingWindow ?? NSApp.keyWindow ?? NSWindow(),
                                delegate: nil, didRun: nil, contextInfo: nil)
    }

    private func showSaveError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Save Failed"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}

/// An NSView that paginates a list of images, one per printed page.
/// Each image is scaled to fit within the page's printable area while
/// preserving its aspect ratio.
private class MultiPagePrintView: NSView {
    private let images: [NSImage]

    init(images: [NSImage]) {
        self.images = images
        super.init(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        range.pointee = NSRange(location: 1, length: images.count)
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect {
        let printInfo = NSPrintOperation.current?.printInfo ?? NSPrintInfo.shared
        let paperSize = printInfo.paperSize
        let margins = NSEdgeInsets(
            top: printInfo.topMargin,
            left: printInfo.leftMargin,
            bottom: printInfo.bottomMargin,
            right: printInfo.rightMargin
        )
        let printableWidth = paperSize.width - margins.left - margins.right
        let printableHeight = paperSize.height - margins.top - margins.bottom

        frame = NSRect(x: 0, y: 0, width: printableWidth,
                       height: printableHeight * CGFloat(images.count))
        return NSRect(x: 0, y: printableHeight * CGFloat(page - 1),
                      width: printableWidth, height: printableHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current else { return }
        let printInfo = NSPrintOperation.current?.printInfo ?? NSPrintInfo.shared
        let paperSize = printInfo.paperSize
        let margins = NSEdgeInsets(
            top: printInfo.topMargin,
            left: printInfo.leftMargin,
            bottom: printInfo.bottomMargin,
            right: printInfo.rightMargin
        )
        let printableWidth = paperSize.width - margins.left - margins.right
        let printableHeight = paperSize.height - margins.top - margins.bottom

        context.saveGraphicsState()
        for (index, image) in images.enumerated() {
            let pageOriginY = printableHeight * CGFloat(index)
            let pageRect = NSRect(x: 0, y: pageOriginY,
                                  width: printableWidth, height: printableHeight)
            guard dirtyRect.intersects(pageRect) else { continue }

            let imageSize = image.size
            guard imageSize.width > 0, imageSize.height > 0 else { continue }
            let scale = min(printableWidth / imageSize.width,
                            printableHeight / imageSize.height,
                            1.0)
            let drawW = imageSize.width * scale
            let drawH = imageSize.height * scale
            let drawX = (printableWidth - drawW) / 2
            let drawY = pageOriginY + (printableHeight - drawH) / 2
            image.draw(in: NSRect(x: drawX, y: drawY, width: drawW, height: drawH),
                       from: .zero, operation: .sourceOver, fraction: 1.0)
        }
        context.restoreGraphicsState()
    }
}

/// Captures the NSWindow hosting a SwiftUI view, so AppKit-level code
/// (e.g. NSEvent local monitors) can scope its handling to this window.
private struct WindowAccessor: NSViewRepresentable {
    let callback: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            callback(view?.window)
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private struct ScrollViewAccessor: NSViewRepresentable {
    let callback: (NSScrollView?) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            var current: NSView? = view
            while let v = current {
                if let scrollView = v as? NSScrollView {
                    callback(scrollView)
                    return
                }
                current = v.superview
            }
            callback(nil)
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Drives an `NSSavePanel` accessory popup that lets the user pick the export
/// format. Bare (non-document) save panels don't provide a built-in format
/// selector, so we supply our own.
private final class SaveFormatPicker: NSObject {
    struct Format {
        let label: String
        let type: UTType
        let ext: String
    }

    private let formats: [Format]
    private weak var panel: NSSavePanel?

    init(formats: [Format], panel: NSSavePanel) {
        self.formats = formats
        self.panel = panel
    }

    func makeAccessoryView() -> NSView {
        let container = NSView()
        let label = NSTextField(labelWithString: "Format:")
        label.translatesAutoresizingMaskIntoConstraints = false

        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.addItems(withTitles: formats.map(\.label))
        popup.target = self
        popup.action = #selector(formatChanged(_:))

        container.addSubview(label)
        container.addSubview(popup)
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 44),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            popup.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            popup.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            popup.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])
        return container
    }

    @objc private func formatChanged(_ sender: NSPopUpButton) {
        guard let panel, formats.indices.contains(sender.indexOfSelectedItem) else { return }
        let format = formats[sender.indexOfSelectedItem]
        // Preserve whatever base name the user has typed, swap the extension.
        let base = (panel.nameFieldStringValue as NSString).deletingPathExtension
        panel.allowedContentTypes = [format.type]
        panel.nameFieldStringValue = base.isEmpty ? base : "\(base).\(format.ext)"
    }
}
