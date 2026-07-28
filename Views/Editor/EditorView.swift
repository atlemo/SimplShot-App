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
    /// True while applyEditorTemplate writes its batch of template properties.
    /// The per-property onChange handlers skip their annotation shifts during
    /// the batch — applyEditorTemplate defers one authoritative shift instead.
    @State private var isApplyingTemplatePreset: Bool = false
    /// Set while a coalesced display re-render is already queued, so the many
    /// template-property onChange handlers that fire together (e.g. applying a
    /// template changes ~7 settings at once) trigger only one render.
    @State private var displayRefreshScheduled: Bool = false
    /// Latest-wins bookkeeping for the asynchronous display-render pipeline,
    /// including the annotation shift that must commit atomically with the
    /// re-rendered bitmap.
    @State private var renderCoordinator = DisplayRenderCoordinator()

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
    @State private var dpiScaleFactor: CGFloat = 1.0  // For high-DPI images (1.0 = 72 DPI, 2.0 = 144 DPI, etc.)
    @State private var imagePixelSize: CGSize = .zero
    /// The display's backing scale factor (e.g. 2.0 on Retina, 3.0 on 3× displays).
    /// Used in export rendering to scale strokes and other elements to image resolution.
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
    /// Additional fine straighten angle (degrees) being dragged this crop session.
    /// Reset to 0 on entering crop mode; baked into `straightenAngle` on Apply.
    @State private var straightenDialAngle: Double = 0
    /// True while the user is actively dragging a crop handle or the straighten
    /// slider — drives the straightening grid's visibility.
    @State private var isAdjustingCrop: Bool = false

    // Zoom state
    @State private var zoomLevel: CGFloat = 1.0  // 1.0 = fit to view
    @State private var fitScale: CGFloat = 0.5   // computed base scale to fit image
    @State private var lastViewSize: CGSize = .zero  // cached for re-fitting after image swap
    /// Transient pinch-zoom bookkeeping. Lives in a reference-type box (not
    /// individual @State values) because magnify ticks arrive faster than the
    /// canvas can re-layout, and mutating plain @State on every tick would
    /// invalidate the view tree without driving any UI.
    @State private var magnifyState = MagnifyGestureState()

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
    /// Fine straighten angle (degrees) applied after `rotationSteps` and before
    /// crop in the display pipeline. screenshotCropRect and annotations live in
    /// the resulting straightened coordinate space.
    @State private var straightenAngle: Double = 0
    /// Shared Core Image context for photo adjustments. Created once, reused every frame.
    @State private var ciContext: CIContext = CIContext()

    // Sidebar — always Pro mode (simple floating toolbar has been removed).
    // NavigationSplitView drives sidebar visibility; showProSidebar is a derived bool.
    @State private var columnVisibility: NavigationSplitViewVisibility
    @State private var shadowIntensity: Double = 1.0
    @State private var screenshotAlignment: CanvasAlignment = .middleCenter
    @State private var watermarkSettings: WatermarkSettings = WatermarkSettings()
    @FocusState private var isCopyButtonFocused: Bool

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
        // The watermark is part of the template, so it auto-applies only when the
        // user has templates enabled in Settings ("Apply selected template to
        // screenshots"). With the toggle off the image opens with no watermark,
        // matching the no-background behaviour in `onAppear`.
        let useTemplate = appSettings?.screenshotTemplate.isEnabled ?? false
        _watermarkSettings = State(initialValue:
            useTemplate ? resolvedTemplate.watermarkSettings : WatermarkSettings()
        )
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
        // PDFs open in View mode (reading-first); raster sessions in Annotate.
        let isPDF = sessions.first?.pdfPageSource != nil
        _editorMode = State(initialValue: isPDF ? .view : .annotate)
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

    /// "Apply background & effects to all open images" — when on, the active
    /// image's wallpaper, padding, corner radius, shadow, alignment and aspect
    /// ratio are mirrored onto every other open image as they're edited.
    @State private var applyTemplateToAllImages = false
    /// Drives the confirm alert shown when enabling the toggle would overwrite
    /// other images' individual template edits.
    @State private var showApplyToAllConfirm = false
    /// Debounce token for the coalesced sibling template re-render.
    @State private var siblingSyncToken = 0
    /// Debounce token for refreshing the active image's own thumbnail as its
    /// display image changes (so the strip updates without leaving the image).
    @State private var activeThumbnailToken = 0
    @State private var keyMonitor: Any?
    @State private var magnifyMonitor: Any?
    @State private var middleMouseMonitor: Any?
    @State private var flagsMonitor: Any?
    @State private var showingCopyCursor: Bool = false
    @State private var middleMouseDragOrigin: NSPoint?
    @State private var middleMouseScrollOrigin: NSPoint?
    @State private var nsScrollView: NSScrollView?
    @State private var canvasViewportFrame: CGRect = .zero
    // In-document find (PDF only).
    @State private var isFindBarVisible = false
    @State private var findQuery = ""
    @State private var findMatches: [PDFSelection] = []
    @State private var currentMatchIndex = 0
    @State private var findFocusToken = 0
    // Parsed PDF outline (table of contents), cached per document group.
    @State private var pdfOutlineNodes: [PDFOutlineNode] = []
    @State private var outlineGroupID: UUID?
    @State private var showPDFInfo = false
    // Continuous (scroll-all-pages) reading mode — View mode + PDF only.
    @State private var pdfContinuousScroll = false
    @State private var continuousScrollTarget: Int?
    @State private var continuousVisiblePage = 0
    /// The NSWindow hosting this editor. Captured via WindowAccessor so the
    /// local key-event monitor can scope its handling to events targeted at
    /// this window (when multiple editor windows are open).
    @State private var hostingWindow: NSWindow?


    /// The actual scale applied to the image: fitScale * zoomLevel.
    /// Units: view-points per image-pixel.
    private var effectiveScale: CGFloat {
        fitScale * zoomLevel
    }

    /// The zoom percentage relative to the image's *natural* size.
    /// Natural size is when effectiveScale == 1/dpiScaleFactor: a normal 72-DPI
    /// image shows 1 image pixel per logical point at 100%, while a 144-DPI (2×)
    /// screenshot shows 2 image pixels per point at 100% (i.e. it opens at half
    /// its pixel dimensions, the size it was captured to be viewed at).
    private var displayZoomPercent: CGFloat {
        // Continuous PDF scrolling has its own scale model: zoom 1.0 == fit-to-width,
        // which reads as 100%. effectiveScale (single-page) doesn't apply there.
        if isContinuousPDF { return zoomLevel * 100 }
        guard effectiveScale > 0 else { return 100 }
        return effectiveScale * dpiScaleFactor * 100
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
            // Kept on this outer layer (not in `bodyWithObservers`) so the long
            // observer chain stays within the Swift type-checker's budget.
            .onChange(of: templateSignature) { _, _ in
                guard !isRestoringSession, applyTemplateToAllImages else { return }
                scheduleSiblingTemplateSync()
            }
            .alert("Apply to all open images?", isPresented: $showApplyToAllConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Apply to All") { confirmApplyTemplateToAllImages() }
            } message: {
                Text("This replaces every other open image's background and effects with the current image's style. Annotations, crops and photo adjustments are kept.")
            }
    }

    // Split into two computed properties to help the Swift type checker
    // with the long chain of .onChange modifiers.

    private var bodyBase: some View {
        navigationContent
            .onAppear {
            if let appSettings {
                editorPadding = template.padding
                editorCornerRadius = template.cornerRadius
                // Templates (background, padding, shadow) never auto-apply to a
                // PDF — only screenshots get the beautification treatment by
                // default. PDFs would need an explicit opt-in.
                //
                // And only when the user has turned templates on in Settings
                // ("Apply selected template to screenshots",
                // `screenshotTemplate.isEnabled`). With the toggle off the
                // screenshot opens as-is — `selectedWallpaper` stays nil.
                // Previously the editor's selected template (which defaults to the
                // first in the list) was applied unconditionally, so every
                // screenshot got a background regardless of the setting.
                if !isPDFSession,
                   appSettings.screenshotTemplate.isEnabled,
                   let savedTemplate = appSettings.selectedEditorTemplate {
                    applyEditorTemplate(savedTemplate)
                }
            }
            loadImage()
            propagateInitialTemplateToOtherSessions()
            preloadThumbnails()
            installKeyMonitorIfNeeded()
            refreshPDFOutlineIfNeeded()
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
        .onReceive(NotificationCenter.default.publisher(for: .editorActionCommand)) { notification in
            guard notification.object as? NSWindow === hostingWindow,
                  let action = notification.userInfo?["action"] as? String
            else { return }
            handleMenuAction(action)
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
                if wasEnabled != isEnabled, !isApplyingTemplatePreset {
                    let cropSize = screenshotCropRect.isEmpty ? rawImage.size : screenshotCropRect.size
                    let oldOrigin = wasEnabled ? screenshotOriginInTemplatedCanvas(screenshotPixelSize: cropSize, padding: editorPadding, aspectRatio: selectedEditorAspectRatio?.ratio, alignment: screenshotAlignment) : .zero
                    let newOrigin = isEnabled ? screenshotOriginInTemplatedCanvas(screenshotPixelSize: cropSize, padding: editorPadding, aspectRatio: selectedEditorAspectRatio?.ratio, alignment: screenshotAlignment) : .zero
                    deferAnnotationShift(by: CGPoint(x: newOrigin.x - oldOrigin.x, y: newOrigin.y - oldOrigin.y))
                }
                scheduleDisplayRefresh()
            }
        }
        .onChange(of: editorPadding) { oldValue, newValue in
            guard !isRestoringSession else { return }
            appSettings?.screenshotTemplate.padding = newValue
            if selectedWallpaper != nil, let rawImage {
                if !isApplyingTemplatePreset {
                    let cropSize = screenshotCropRect.isEmpty ? rawImage.size : screenshotCropRect.size
                    let oldOrigin = screenshotOriginInTemplatedCanvas(screenshotPixelSize: cropSize, padding: oldValue, aspectRatio: selectedEditorAspectRatio?.ratio, alignment: screenshotAlignment)
                    let newOrigin = screenshotOriginInTemplatedCanvas(screenshotPixelSize: cropSize, padding: newValue, aspectRatio: selectedEditorAspectRatio?.ratio, alignment: screenshotAlignment)
                    deferAnnotationShift(by: CGPoint(x: newOrigin.x - oldOrigin.x, y: newOrigin.y - oldOrigin.y))
                }
                scheduleDisplayRefresh()
            }
        }
        .onChange(of: editorAspectRatioID) { oldID, newID in
            guard !isRestoringSession else { return }
            if selectedWallpaper != nil, let rawImage {
                if !isApplyingTemplatePreset {
                    let cropSize = screenshotCropRect.isEmpty ? rawImage.size : screenshotCropRect.size
                    let oldRatio = aspectRatioValue(for: oldID)
                    let newRatio = aspectRatioValue(for: newID)
                    // Pass the current alignment — omitting it defaulted to
                    // .middleCenter and computed a wrong shift for any other
                    // alignment.
                    let oldOrigin = screenshotOriginInTemplatedCanvas(screenshotPixelSize: cropSize, padding: editorPadding, aspectRatio: oldRatio, alignment: screenshotAlignment)
                    let newOrigin = screenshotOriginInTemplatedCanvas(screenshotPixelSize: cropSize, padding: editorPadding, aspectRatio: newRatio, alignment: screenshotAlignment)
                    deferAnnotationShift(by: CGPoint(x: newOrigin.x - oldOrigin.x, y: newOrigin.y - oldOrigin.y))
                }
                scheduleDisplayRefresh()
            }
        }
        .onChange(of: editorCornerRadius) { _, newValue in
            guard !isRestoringSession else { return }
            appSettings?.screenshotTemplate.cornerRadius = newValue
            if selectedWallpaper != nil, rawImage != nil {
                scheduleDisplayRefresh()
            }
        }
        .onChange(of: photoAdjustments) { _, _ in
            guard !isRestoringSession else { return }
            if rawImage != nil {
                scheduleDisplayRefresh()
            }
        }
    }

    private var bodyWithObservers: some View {
        bodyBase
        .onChange(of: screenshotAlignment) { oldAlignment, newAlignment in
            guard !isRestoringSession else { return }
            if selectedWallpaper != nil, let rawImage {
                if !isApplyingTemplatePreset {
                    let cropSize = screenshotCropRect.isEmpty ? rawImage.size : screenshotCropRect.size
                    let oldOrigin = screenshotOriginInTemplatedCanvas(screenshotPixelSize: cropSize, padding: editorPadding, aspectRatio: selectedEditorAspectRatio?.ratio, alignment: oldAlignment)
                    let newOrigin = screenshotOriginInTemplatedCanvas(screenshotPixelSize: cropSize, padding: editorPadding, aspectRatio: selectedEditorAspectRatio?.ratio, alignment: newAlignment)
                    deferAnnotationShift(by: CGPoint(x: newOrigin.x - oldOrigin.x, y: newOrigin.y - oldOrigin.y))
                }
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
            if selectedWallpaper != nil, rawImage != nil {
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
        .onReceive(NotificationCenter.default.publisher(
            for: NSView.frameDidChangeNotification,
            object: nsScrollView?.documentView
        )) { _ in
            // The canvas finished resizing for an in-flight pinch-zoom step —
            // apply the scroll-anchor correction now, in the same pass as the
            // resize, instead of racing it from a detached async block (which
            // made content visibly shift and settle on every zoom step).
            guard let origin = magnifyState.pendingScrollOrigin,
                  let scrollView = nsScrollView else { return }
            finishZoomAnchorCorrection(scrollView: scrollView, origin: origin)
        }
        .alert("Delete Screenshot?", isPresented: $showTrashAlert) {
            Button("Delete", role: .destructive) {
                trashScreenshot()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The file will be moved to the Trash.")
        }
        .sheet(isPresented: $showPDFInfo) {
            if let doc = pdfDocument {
                PDFInfoView(
                    document: doc,
                    page: activePDFPage(),
                    url: activeSession?.pdfPageSource?.sourceURL,
                    onClose: { showPDFInfo = false }
                )
            }
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
        // Top controls are NOT a window toolbar — see `topActionBar`, which lives
        // inside `detailContent` (right of the sidebar) so it follows the content
        // and slides with the sidebar, mirroring the bottom toolbar.
    }

    // MARK: - Toolbar Trailing Action

    /// Trailing save/done/copy button label (depends on session count, PDF edit
    /// state, and whether anything's been edited).
    private var saveActionLabel: String {
        let isMulti = sessions.count > 1
        let isPDFDone = isPDFSession && !pdfDocumentHasEdits
        let hasEdits = anySessionHasEdits
        if isPDFDone { return "Done" }
        if isMulti { return hasEdits ? "Save All" : "Done" }
        return hasEdits ? "Save & Copy" : "Copy"
    }

    private var saveActionHelp: String {
        let isMulti = sessions.count > 1
        let isPDFDone = isPDFSession && !pdfDocumentHasEdits
        let hasEdits = anySessionHasEdits
        if isPDFDone { return "Close the document" }
        if isMulti { return hasEdits ? "Save all open images and close" : "Close all images" }
        return hasEdits ? "Save, close and copy the image to your clipboard" : "Copy the image to your clipboard"
    }

    /// Width of the Annotate/Edit sidebar (kept in sync with `sidebarContent`).
    private let sidebarWidth: CGFloat = 260
    /// Space reserved for the macOS window controls when content extends into a
    /// transparent full-size title bar and the detail view starts at x=0.
    private let titlebarLeadingControlInset: CGFloat = 82

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
            straightenDialAngle: $straightenDialAngle,
            isAdjustingCrop: $isAdjustingCrop,
            isPDFSession: isPDFSession,
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
            onResizeImage: resizeImage,
            applyToAllImagesAvailable: applyToAllImagesAvailable,
            applyTemplateToAllImages: applyTemplateToAllImagesBinding
        )
        .frame(width: sidebarWidth)
        .background(.thickMaterial)
    }

    // MARK: - Top Action Bar

    @AppStorage("debugSimulateSonomaAppearance") private var simulateSonoma = false

    /// Glass on macOS 26 (unless the Sonoma-appearance debug flag is set) — same
    /// rule `EditorBottomToolbarView` uses, so both bars share one material.
    private var topBarUseGlass: Bool {
        guard #available(macOS 26, *) else { return false }
        return !simulateSonoma
    }

    @ViewBuilder
    private func topBarGlassContainer<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if #available(macOS 26, *), !simulateSonoma {
            GlassEffectContainer(spacing: 8) { content() }
        } else {
            content()
        }
    }

    /// Top controls in three zones (mirrors `EditorBottomToolbarView`): Undo
    /// (+ PDF page nav) in glass pills on the leading edge — same x-position as
    /// the bottom bar's pixel-dimensions readout — the glass-pill mode toggle
    /// centred, and the prominent blue Save/Copy button trailing. Both side zones
    /// expand equally so the toggle centres over the canvas; living in
    /// `detailContent` (right of the sidebar) makes the whole bar slide with it.
    private var topActionBar: some View {
        topBarGlassContainer {
            HStack(alignment: .center, spacing: 0) {
                // Leading — Undo, then PDF page navigator (PDF sessions only),
                // each in its own glass pill.
                HStack(spacing: 8) {
                    if editorMode == .view {
                        Color.clear
                            .frame(width: 34, height: 34)
                    } else {
                        Button(action: undo) {
                            Image(systemName: "arrow.uturn.backward")
                                .frame(width: 34, height: 34)
                                .contentShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(ToolbarHoverButtonStyle())
                        .help("Undo")
                        .keyboardShortcut("z", modifiers: .command)
                        .disabled(undoStack.isEmpty)
                        .pillBackground(useGlass: topBarUseGlass)
                    }

                    if isPDFSession {
                        pdfPageNavigator
                            .pillBackground(useGlass: topBarUseGlass)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Centre — mode toggle (draws its own glass pill)
                EditorModeToggle(editorMode: $editorMode, isPDFSession: isPDFSession)

                // Trailing — Save / Copy (primary)
                Group {
                    if #available(macOS 26, *), topBarUseGlass {
                        Button(action: saveOverwrite) {
                            Text(saveActionLabel)
                                .padding(.horizontal, 6)
                        }
                        .buttonStyle(.glassProminent)
                        .focused($isCopyButtonFocused)
                    } else {
                        Button(action: saveOverwrite) {
                            Text(saveActionLabel)
                                .padding(.horizontal, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .focused($isCopyButtonFocused)
                    }
                }
                .controlSize(.large)
                .buttonBorderShape(.capsule)
                .help(saveActionHelp)
                .keyboardShortcut("s", modifiers: .command)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .defaultFocus($isCopyButtonFocused, true)
            .padding(.leading, topActionBarLeadingPadding)
            .padding(.trailing, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)
        }
    }

    private var topActionBarLeadingPadding: CGFloat {
        let basePadding: CGFloat = 12
        return detailContentStartsAtWindowLeadingEdge
            ? basePadding + titlebarLeadingControlInset
            : basePadding
    }

    private var detailContentStartsAtWindowLeadingEdge: Bool {
        editorMode == .view || !showProSidebar
    }

    // MARK: - Detail Content

    private var detailContent: some View {
        VStack(spacing: 0) {
            topActionBar
            // Canvas and thumbnail strip are siblings (not an overlay) so the
            // strip reserves its own width — the canvas `GeometryReader` then
            // measures only the visible area, keeping fit-to-window and page
            // content clear of the strip in every mode.
            HStack(spacing: 0) {
                GeometryReader { geo in
                    Group {
                        if isContinuousPDF, let doc = pdfDocument {
                            // Read-only scroll through all PDF pages (View mode).
                            ContinuousPDFView(
                                document: doc,
                                scrollTarget: $continuousScrollTarget,
                                visiblePage: $continuousVisiblePage,
                                zoom: zoomLevel,
                                highlights: { searchHighlights(on: $0) },
                                activeHighlight: { activeSearchHighlight(on: $0) },
                                onOpenURL: openPDFLinkURL,
                                onGoToDestination: goToPDFDestination
                            )
                        } else if let image {
                            // Indicators stay enabled at all zoom levels: toggling them at
                            // the 1.0 boundary forced a scroller reconfiguration mid-gesture.
                            // Overlay scrollers auto-hide when the content fits anyway.
                            ScrollView([.horizontal, .vertical], showsIndicators: true) {
                                EditorCanvasView(
                                    image: image,
                                    imagePixelSize: imagePixelSize,
                                    scale: effectiveScale,
                                    displayBackingScale: displayBackingScale,
                                    dpiScaleFactor: dpiScaleFactor,
                                    editorMode: editorMode,
                                    pdfPageSource: activeSession?.pdfPageSource,
                                    searchHighlights: searchHighlightsForActivePage,
                                    activeSearchHighlight: activeSearchHighlightForPage,
                                    onOpenPDFURL: openPDFLinkURL,
                                    onGoToPDFDestination: goToPDFDestination,
                                    onFlipPDFPage: { goToAdjacentPDFPage($0) },
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
                                    straightenDialAngle: straightenDialAngle,
                                    showCropGrid: isAdjustingCrop,
                                    watermarkSettings: watermarkSettings,
                                    onCommit: pushUndo,
                                    onCropAdjustBegan: { isAdjustingCrop = true },
                                    onCropAdjustEnded: { isAdjustingCrop = false }
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
                // Find bar overlays the canvas (not the strip) so it stays
                // centred over the page content.
                .overlay(alignment: .top) {
                    if isFindBarVisible {
                        PDFFindBar(
                            query: $findQuery,
                            currentMatch: currentMatchIndex,
                            totalMatches: findMatches.count,
                            focusToken: findFocusToken,
                            onNext: findNext,
                            onPrevious: findPrevious,
                            onClose: closeFindBar
                        )
                        .padding(.top, 12)
                        .onChange(of: findQuery) { _, _ in runSearch() }
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.15), value: isFindBarVisible)

                if sessions.count > 1 {
                    ThumbnailStripView(
                        sessions: sessions,
                        activeID: thumbnailActiveID,
                        onSelect: { selectPageSession($0) },
                        onRemove: { removeSession($0) },
                        onMove: { from, to in
                            sessions.move(fromOffsets: IndexSet(integer: from),
                                          toOffset: to > from ? to + 1 : to)
                        },
                        outline: pdfOutlineNodes,
                        activePageIndex: activeSession?.pdfPageSource?.pageIndex,
                        onSelectOutline: { selectOutlineNode($0) }
                    )
                    .padding(.leading, 8)
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
                annotationsCount: annotations.count,
                displayZoomPercent: Int(displayZoomPercent),
                onZoomOut: zoomOut,
                onZoomIn: zoomIn,
                onZoomReset: { zoomLevel = 1.0; syncZoomToPDFGroup() },
                onFitWidth: fitToWidth,
                onActualSize: actualSize
            )
            .offset(y: -3)
        }
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        .ignoresSafeArea(.container, edges: .top)
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

        // Pick up the backing scale of the screen this window is actually on
        // (an editor dragged to a 1×/3× secondary display would otherwise use
        // the key screen's scale). Falls back to NSScreen.main before the
        // window reference is captured.
        displayBackingScale = (hostingWindow?.screen ?? NSScreen.main)?.backingScaleFactor ?? 2.0

        let fitToView = min(scaleX, scaleY)
        if isPDFSession {
            // PDFs render as live vector at any scale, so fit them to the viewport
            // and enlarge if needed (like a PDF viewer).
            fitScale = fitToView
        } else {
            // Raster images: show at natural 1:1 size (accounting for DPI scale),
            // but scale down if too big to fit in the viewport.
            // For 2x images (144 DPI), cap at 0.5 so they display at half size (natural).
            let trueSizeCap = 1.0 / dpiScaleFactor
            fitScale = min(fitToView, trueSizeCap)
        }
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

    /// Zoom preset: natural size (100%). For a normal image this is 1 image
    /// pixel == 1 logical point; for a 144-DPI (2×) screenshot it is 2 image
    /// pixels == 1 logical point, matching the size it was captured to be viewed at.
    private func actualSize() {
        // Continuous PDF: "100%" is the fit-to-width baseline (zoom 1.0).
        if isContinuousPDF { zoomLevel = 1.0; syncZoomToPDFGroup(); return }
        guard fitScale > 0 else { return }
        let naturalScale = 1.0 / dpiScaleFactor
        zoomLevel = min(max(naturalScale / fitScale, minZoomLevel), maxZoomLevel)
        syncZoomToPDFGroup()
    }

    /// Zoom preset: scale the full image/page to fit the available viewport.
    /// Unlike the default fit scale for raster screenshots, this command can scale
    /// up past true size because the user explicitly asked to fill the view.
    private func zoomToFit() {
        // Continuous PDF: fitting means fit-to-width (zoom 1.0).
        if isContinuousPDF { zoomLevel = 1.0; syncZoomToPDFGroup(); return }
        guard fitScale > 0,
              imagePixelSize.width > 0,
              imagePixelSize.height > 0,
              lastViewSize.width > 0,
              lastViewSize.height > 0 else { return }

        let availableWidth = max(lastViewSize.width - 42, 100) // 40 chrome + 2 fudge
        let availableHeight = max(lastViewSize.height - 42, 100)
        let target = min(availableWidth / imagePixelSize.width, availableHeight / imagePixelSize.height)
        zoomLevel = min(max(target / fitScale, minZoomLevel), maxZoomLevel)
        syncZoomToPDFGroup()
    }

    /// Zoom preset: scale so the image width fills the available viewport width.
    private func fitToWidth() {
        // Continuous PDF: pages already fit the viewport width at zoom 1.0.
        if isContinuousPDF { zoomLevel = 1.0; syncZoomToPDFGroup(); return }
        guard fitScale > 0, imagePixelSize.width > 0, lastViewSize.width > 0 else { return }
        let availableWidth = max(lastViewSize.width - 42, 100) // 40 chrome + 2 fudge
        let target = availableWidth / imagePixelSize.width
        zoomLevel = min(max(target / fitScale, minZoomLevel), maxZoomLevel)
        syncZoomToPDFGroup()
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
                    session.dpiScaleFactor = metadata.dpiScaleFactor
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
            // Never carry a template background onto a PDF page.
            session.selectedWallpaper = session.isPDF ? nil : active.selectedWallpaper
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
        // handlers which queue a canvas re-render. Flush it so the session
        // stores the freshly-rendered image (and its thumbnail refreshes),
        // not a stale frame from before the template was applied.
        DispatchQueue.main.async {
            flushPendingDisplayRender()
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

        // Never apply a template background to a PDF page.
        session.selectedWallpaper = session.isPDF ? nil : template.wallpaperSource
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

    // MARK: - Apply Background & Effects To All Images

    /// True when the toggle should be offered: more than one raster image is
    /// open. PDF pages never take a background, so they don't count.
    private var applyToAllImagesAvailable: Bool {
        sessions.filter { !$0.isPDF }.count > 1
    }

    /// The template fields mirrored by "apply to all". Used as one `onChange`
    /// trigger so a change to any of them syncs the others.
    private struct TemplateSignature: Equatable {
        var wallpaper: WallpaperSource?
        var padding: Int
        var cornerRadius: Int
        var shadow: Double
        var alignment: CanvasAlignment
        var aspectRatioID: UUID?
    }
    private var templateSignature: TemplateSignature {
        TemplateSignature(
            wallpaper: selectedWallpaper, padding: editorPadding,
            cornerRadius: editorCornerRadius, shadow: shadowIntensity,
            alignment: screenshotAlignment, aspectRatioID: editorAspectRatioID
        )
    }

    /// Binding for the sidebar toggle. Turning it on while other images carry
    /// diverging template edits routes through a confirmation first.
    private var applyTemplateToAllImagesBinding: Binding<Bool> {
        Binding(
            get: { applyTemplateToAllImages },
            set: { newValue in
                if newValue {
                    if otherImagesDivergeFromActiveTemplate() {
                        showApplyToAllConfirm = true   // ask before overwriting
                    } else {
                        applyTemplateToAllImages = true
                    }
                } else {
                    applyTemplateToAllImages = false
                }
            }
        )
    }

    /// True if any other open image's background/effects differ from the active
    /// image's — i.e. enabling "apply to all" would overwrite individual edits.
    private func otherImagesDivergeFromActiveTemplate() -> Bool {
        for session in sessions
        where session.id != activeSessionID && !session.isPDF {
            if session.selectedWallpaper != selectedWallpaper
                || session.editorPadding != editorPadding
                || session.editorCornerRadius != editorCornerRadius
                || session.shadowIntensity != shadowIntensity
                || session.screenshotAlignment != screenshotAlignment
                || session.editorAspectRatioID != editorAspectRatioID {
                return true
            }
        }
        return false
    }

    /// Confirm-handler for the alert: enable the toggle and push the active
    /// image's style onto every other open image right away.
    private func confirmApplyTemplateToAllImages() {
        applyTemplateToAllImages = true
        flushPendingDisplayRender()
        applyCurrentTemplateToOtherImages()
    }

    /// Coalesced (debounced) sibling sync used during live edits, so a slider
    /// drag re-renders the other images once it settles, not every tick.
    private func scheduleSiblingTemplateSync() {
        guard applyTemplateToAllImages, applyToAllImagesAvailable else { return }
        siblingSyncToken &+= 1
        let token = siblingSyncToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard token == siblingSyncToken else { return }   // superseded
            applyCurrentTemplateToOtherImages()
        }
    }

    /// Run any pending sibling sync immediately (before a session switch/save).
    private func flushSiblingTemplateSync() {
        guard applyTemplateToAllImages else { return }
        siblingSyncToken &+= 1   // cancel any pending debounce
        applyCurrentTemplateToOtherImages()
    }

    /// Copies the active image's background + effects (wallpaper, padding,
    /// corner radius, shadow, alignment, aspect ratio) onto every other open
    /// image, shifting each one's annotations to track the new template canvas
    /// and re-rendering it. Watermark, photo adjustments, crop, rotation and
    /// annotations stay per-image; PDF pages are skipped (they take no
    /// background). Mirrors `applyTemplate(_:toSession:)` but reads live @State
    /// instead of a preset and leaves the watermark untouched.
    private func applyCurrentTemplateToOtherImages() {
        let activeRatio = selectedEditorAspectRatio?.ratio
        for session in sessions
        where session.id != activeSessionID && !session.isPDF {
            let cropSize = session.screenshotCropRect.isEmpty
                ? (session.rawImage?.size ?? session.imagePixelSize)
                : session.screenshotCropRect.size
            let oldRatio = editorAspectRatios.first(where: { $0.id == session.editorAspectRatioID })?.ratio
            let oldOrigin: CGPoint = (session.selectedWallpaper != nil)
                ? screenshotOriginInTemplatedCanvas(
                    screenshotPixelSize: cropSize, padding: session.editorPadding,
                    aspectRatio: oldRatio, alignment: session.screenshotAlignment)
                : .zero
            let newOrigin: CGPoint = (selectedWallpaper != nil)
                ? screenshotOriginInTemplatedCanvas(
                    screenshotPixelSize: cropSize, padding: editorPadding,
                    aspectRatio: activeRatio, alignment: screenshotAlignment)
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
            session.selectedWallpaper = selectedWallpaper
            session.editorPadding = editorPadding
            session.editorCornerRadius = editorCornerRadius
            session.shadowIntensity = shadowIntensity
            session.screenshotAlignment = screenshotAlignment
            session.editorAspectRatioID = editorAspectRatioID
            if session.rawImage != nil {
                renderSessionDisplay(session)
            }
        }
    }

    /// Mirror of `applyDisplayImage` that operates on a session instead of @State.
    /// Updates the session's display image, derived metadata, and thumbnail.
    private func renderSessionDisplay(_ session: ImageSession) {
        guard let rawImg = session.rawImage,
              let cgSourceOriginal = rawImg.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return }

        // Apply this session's rotation up front (same model as applyDisplayImage).
        var cgSource = Self.rotateCGImage90(cgSourceOriginal, steps: session.rotationSteps, ciContext: ciContext)
            ?? cgSourceOriginal

        // Apply fine straighten after the 90° rotation, before crop.
        if session.straightenAngle != 0,
           let straightened = Self.rotateCGImageArbitrary(cgSource, degrees: session.straightenAngle, ciContext: ciContext) {
            cgSource = straightened
        }

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
        // Templates never apply to PDF pages (mirrors the active-display guard
        // `wallpaper: isPDFSession ? nil` in displayRenderSpec).
        if !session.isPDF, let wallpaper = session.selectedWallpaper {
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
        originalSession.dpiScaleFactor = metadata.dpiScaleFactor
        let (sw, sh) = Self.rotatedDims(width: CGFloat(cgImage.width),
                                        height: CGFloat(cgImage.height),
                                        steps: originalSession.rotationSteps)
        originalSession.screenshotCropRect = CGRect(x: 0, y: 0, width: sw, height: sh)

        if activeSessionID == sessionID {
            // Reflect into @State and trigger the active display pipeline.
            // dpiScaleFactor must be set before applyDisplayImage so the fit-scale
            // pass uses it, and before saveActiveSessionState so the @State value
            // (not a stale default) is the one persisted back to the session.
            rawImage = nsImage
            imageMetadata = metadata
            dpiScaleFactor = metadata.dpiScaleFactor
            screenshotCropRect = originalSession.screenshotCropRect
            applyDisplayImage(from: nsImage)
            saveActiveSessionState()
        } else {
            // User has navigated away. Pre-render the display image into the
            // session so that when they come back, no work is needed.
            renderSessionDisplay(originalSession)
        }
    }

    /// Coalesces display re-renders into a single request on the next runloop
    /// tick. Applying a template mutates ~7 @State properties at once, each
    /// firing its own onChange; without coalescing that would start ~7 renders.
    private func scheduleDisplayRefresh() {
        guard !displayRefreshScheduled else { return }
        displayRefreshScheduled = true
        DispatchQueue.main.async {
            displayRefreshScheduled = false
            startDisplayRender()
        }
    }

    /// Serial queue for display-pipeline renders (rotate → crop → adjust →
    /// template). Serial so the active session's TemplateRenderer caches are
    /// only ever touched by one render at a time; latest-wins via generations.
    private static let displayRenderQueue = DispatchQueue(
        label: "com.simplshot.displayRender",
        qos: .userInteractive
    )

    /// Snapshot of every input the display render reads, captured on the main
    /// thread so the background pass touches no @State.
    private struct DisplayRenderSpec {
        var rotationSteps: Int
        var straightenAngle: Double
        var screenshotCropRect: CGRect
        var photoAdjustments: PhotoAdjustments
        var wallpaper: WallpaperSource?
        var padding: Int
        var cornerRadius: Int
        var aspectRatio: Double?
        var shadowIntensity: Double
        var alignment: CanvasAlignment
        var backingScale: CGFloat
    }

    private func displayRenderSpec() -> DisplayRenderSpec {
        DisplayRenderSpec(
            rotationSteps: rotationSteps,
            straightenAngle: straightenAngle,
            screenshotCropRect: screenshotCropRect,
            photoAdjustments: photoAdjustments,
            wallpaper: isPDFSession ? nil : selectedWallpaper,
            padding: editorPadding,
            cornerRadius: editorCornerRadius,
            aspectRatio: selectedEditorAspectRatio?.ratio,
            shadowIntensity: shadowIntensity,
            alignment: screenshotAlignment,
            backingScale: displayBackingScale
        )
    }

    /// Starts a latest-wins background render of the display image, keeping the
    /// main thread free during slider drags. Stale queued requests are skipped
    /// before doing any work; each completed render commits atomically — the
    /// bitmap, the derived sizes, and the annotation shift snapshotted for it —
    /// so annotations can never move ahead of the image they are drawn over.
    private func startDisplayRender() {
        guard let rawImage else { return }
        guard let sourceCG = rawImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            // Non-bitmap source — the synchronous path has a fallback for it.
            applyDisplayImage(from: rawImage)
            return
        }

        let generation = renderCoordinator.advanceGeneration()
        renderCoordinator.hasUncommittedRender = true
        let shiftTarget = renderCoordinator.cumulativeShift
        let spec = displayRenderSpec()
        let renderer = templateRenderer
        let context = ciContext
        let baseTemplate = template

        Self.displayRenderQueue.async {
            // Superseded while queued — skip without rendering.
            guard renderCoordinator.isCurrent(generation) else { return }
            let displayCG = Self.composeDisplayImage(
                source: sourceCG,
                spec: spec,
                template: baseTemplate,
                renderer: renderer,
                ciContext: context
            )
            DispatchQueue.main.async {
                // Progressive latest-wins: commit anything newer than the last
                // commit (so the preview keeps updating mid-drag even when every
                // render is superseded before it finishes), drop renders that
                // lost to a newer commit (e.g. a synchronous flush).
                guard generation > renderCoordinator.lastCommittedGeneration else { return }
                renderCoordinator.lastCommittedGeneration = generation
                if renderCoordinator.isCurrent(generation) {
                    renderCoordinator.hasUncommittedRender = false
                }
                shiftAnnotations(by: renderCoordinator.takeShift(upTo: shiftTarget))
                commitDisplayImage(displayCG)
            }
        }
    }

    /// Synchronously completes any pending display work (accumulated annotation
    /// shift + in-flight background render) so @State reflects the freshest
    /// template settings. Call before exports, session switches, and geometry
    /// edits that read annotation positions.
    private func flushPendingDisplayRender() {
        guard renderCoordinator.isDirty, let rawImg = rawImage else { return }
        applyDisplayImage(from: rawImg)
    }

    /// Synchronous render + commit. Used by one-shot edits (crop, rotate,
    /// resize, image load) that need the result immediately. Also flushes any
    /// annotation shift the async pipeline still owes and supersedes in-flight
    /// background renders, so this path always commits the freshest state.
    private func applyDisplayImage(from source: NSImage) {
        shiftAnnotations(by: renderCoordinator.takeShift(upTo: renderCoordinator.cumulativeShift))
        renderCoordinator.lastCommittedGeneration = renderCoordinator.advanceGeneration()
        renderCoordinator.hasUncommittedRender = false

        guard let cgSourceOriginal = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            image = source
            currentDisplayCGImage = nil
            imagePixelSize = source.size
            cropRect = CGRect(origin: .zero, size: source.size)
            return
        }

        // Run on the render queue (synchronously) so the TemplateRenderer's
        // caches stay confined to one render at a time.
        let spec = displayRenderSpec()
        let displayCG = Self.displayRenderQueue.sync {
            Self.composeDisplayImage(
                source: cgSourceOriginal,
                spec: spec,
                template: template,
                renderer: templateRenderer,
                ciContext: ciContext
            )
        }
        commitDisplayImage(displayCG)
    }

    /// The display pipeline: rotation → non-destructive crop → photo
    /// adjustments → template compositing. Pure function of its inputs (no
    /// @State access) so it can run on the render queue.
    private static func composeDisplayImage(
        source cgSourceOriginal: CGImage,
        spec: DisplayRenderSpec,
        template: ScreenshotTemplate,
        renderer: TemplateRenderer,
        ciContext: CIContext
    ) -> CGImage {
        // Apply rotation FIRST so all subsequent geometry (crop, adjustments,
        // template) operates in the rotated coordinate space. screenshotCropRect
        // and annotations are also stored in this rotated-raw coord space.
        var cgSource = rotateCGImage90(cgSourceOriginal, steps: spec.rotationSteps, ciContext: ciContext)
            ?? cgSourceOriginal

        // Apply fine straighten after the 90° rotation, before crop. Expands the
        // canvas to the rotated bounding box (transparent corners), which the
        // auto-inscribed crop always excludes.
        if spec.straightenAngle != 0,
           let straightened = rotateCGImageArbitrary(cgSource, degrees: spec.straightenAngle, ciContext: ciContext) {
            cgSource = straightened
        }

        // Apply non-destructive crop to the (rotated) raw screenshot before compositing.
        var croppedCG = cgSource
        if !spec.screenshotCropRect.isEmpty {
            let fullBounds = CGRect(x: 0, y: 0,
                                    width: CGFloat(cgSource.width), height: CGFloat(cgSource.height))
            let clampedCrop = spec.screenshotCropRect.intersection(fullBounds)
            if !clampedCrop.isEmpty, clampedCrop != fullBounds,
               let cropped = cgSource.cropping(to: clampedCrop) {
                croppedCG = cropped
            }
        }

        // Apply photo adjustments (non-destructive CI filter chain).
        // Runs in Edit mode when any slider is non-default, but the result is
        // always available for export regardless of current mode.
        if !spec.photoAdjustments.isDefault {
            croppedCG = spec.photoAdjustments.apply(to: croppedCG, ciContext: ciContext)
        }

        var displayCG = croppedCG
        if let wallpaper = spec.wallpaper {
            // Build a template with the current editor slider values and selected wallpaper,
            // applied to the already-cropped screenshot (never the raw+wallpaper composite).
            var editorTemplate = template
            editorTemplate.padding = spec.padding
            editorTemplate.cornerRadius = spec.cornerRadius
            editorTemplate.wallpaperSource = wallpaper
            editorTemplate.watermarkSettings = WatermarkSettings()
            if let templated = try? renderer.applyTemplate(
                editorTemplate,
                to: croppedCG,
                backingScale: spec.backingScale,
                targetAspectRatio: spec.aspectRatio,
                shadowIntensity: spec.shadowIntensity,
                alignment: spec.alignment
            ) {
                displayCG = templated
            }
        }
        return displayCG
    }

    /// Writes a rendered display image into @State in one transaction, keeping
    /// fitScale in step so the canvas doesn't re-fit on a later frame.
    private func commitDisplayImage(_ displayCG: CGImage) {
        let size = CGSize(width: displayCG.width, height: displayCG.height)
        let nsImage = NSImage(size: size)
        nsImage.addRepresentation(NSBitmapImageRep(cgImage: displayCG))
        image = nsImage
        currentDisplayCGImage = displayCG
        imagePixelSize = size
        cropRect = CGRect(origin: .zero, size: size)
        updateFitScale(viewSize: lastViewSize)
        // Keep the active image's own thumbnail in step with its live display,
        // so the strip updates while you stay on the image (e.g. changing the
        // background) instead of only after switching away and back.
        scheduleActiveThumbnailRefresh()
    }

    /// Debounced refresh of the active session's thumbnail from its current
    /// display image. Debounced because a slider drag commits many frames — only
    /// the last needs a new thumbnail. Skipped when no strip is shown.
    private func scheduleActiveThumbnailRefresh() {
        guard sessions.count > 1 else { return }
        activeThumbnailToken &+= 1
        let token = activeThumbnailToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            guard token == activeThumbnailToken, let active = activeSession else { return }
            active.generateThumbnail(from: image)
        }
    }

    // MARK: - Crop

    private func applyCrop() {
        flushPendingDisplayRender()

        // Fine straighten is applied here (no-wallpaper only — see the gating on
        // the sidebar slider). It composes the dial angle onto the cumulative
        // `straightenAngle`, recomputes `screenshotCropRect` in the new
        // straightened-from-raw space, and rotates annotations about the display
        // center so they stay glued. Handled separately and returns early.
        if straightenDialAngle != 0, selectedWallpaper == nil,
           let rawImg = rawImage,
           let rawCG = rawImg.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            applyStraightenCrop(rawCG: rawCG, rawImg: rawImg)
            return
        }

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

    /// Bakes the fine straighten (`straightenDialAngle`) together with the crop
    /// rectangle. No-wallpaper path only, so the displayed image equals the
    /// screenshot and there is no gradient offset to account for.
    ///
    /// Coordinate model (all sizes in image pixels):
    /// - `D`        — current displayed (cropped) screenshot = `imagePixelSize`.
    /// - `D0`       — raw image after the 90° rotation (opaque base).
    /// - `O_old`    — full straightened image at the *old* angle = bbox(D0, old).
    /// - `O_new`    — full straightened image at the *new* angle = bbox(D0, new).
    /// - `C`        — old `screenshotCropRect` (region of `O_old` shown as `D`).
    /// The visible crop maps to `O_new` by a pure translation `c' − D.center`,
    /// where `c'` is the rotated image of `C`'s center.
    private func applyStraightenCrop(rawCG: CGImage, rawImg: NSImage) {
        let dial = straightenDialAngle
        let newAngle = straightenAngle + dial

        let D = imagePixelSize
        let dCenter = CGPoint(x: D.width / 2, y: D.height / 2)

        let (d0w, d0h) = Self.rotatedDims(width: CGFloat(rawCG.width),
                                          height: CGFloat(rawCG.height),
                                          steps: rotationSteps)
        let d0 = CGSize(width: d0w, height: d0h)
        let oOld = Self.rotatedBoundingBoxSize(d0, degrees: straightenAngle)
        let oNew = Self.rotatedBoundingBoxSize(d0, degrees: newAngle)

        let cRect = screenshotCropRect.isEmpty
            ? CGRect(origin: .zero, size: oOld)
            : screenshotCropRect
        let cCenter = CGPoint(x: cRect.midX, y: cRect.midY)

        // c' = rotate(C.center − O_old.center, dial) + O_new.center
        let rotatedOffset = Self.rotatePointAboutCenter(
            CGPoint(x: cCenter.x - oOld.width / 2, y: cCenter.y - oOld.height / 2),
            degrees: dial, center: .zero)
        let cPrime = CGPoint(x: rotatedOffset.x + oNew.width / 2,
                             y: rotatedOffset.y + oNew.height / 2)

        // New crop in O_new space = the user's cropRect translated by (c' − D.center).
        let shift = CGPoint(x: cPrime.x - dCenter.x, y: cPrime.y - dCenter.y)
        var newCrop = cropRect.offsetBy(dx: shift.x, dy: shift.y)
        // Clamp into the new straightened image bounds.
        let oNewBounds = CGRect(origin: .zero, size: oNew)
        newCrop = newCrop.intersection(oNewBounds)
        guard !newCrop.isEmpty else { cancelCrop(); return }

        // Push pre-straighten state for undo (captured in enterCropMode).
        if let snapshot = preCropSnapshot {
            undoStack.append(snapshot)
            preCropSnapshot = nil
        } else {
            pushUndo()
        }

        // Rotate each annotation about the display center by the dial angle, then
        // translate into the new crop's origin: a' = rotate(a) − cropRect.origin.
        let cropOrigin = cropRect.origin
        annotations = annotations.map { ann in
            var a = ann
            let remap: (CGPoint) -> CGPoint = { p in
                let r = Self.rotatePointAboutCenter(p, degrees: dial, center: dCenter)
                return CGPoint(x: r.x - cropOrigin.x, y: r.y - cropOrigin.y)
            }
            a.startPoint = remap(ann.startPoint)
            a.endPoint = remap(ann.endPoint)
            if !ann.points.isEmpty { a.points = ann.points.map(remap) }
            return a
        }
        selectedAnnotationID = nil

        straightenAngle = newAngle
        screenshotCropRect = newCrop
        applyDisplayImage(from: rawImg)
        saveActiveSessionState()

        straightenDialAngle = 0
        isAdjustingCrop = false
        isCropping = false
        currentTool = .select
    }

    /// Expands the display to the full uncropped image and positions the crop rect
    /// over the previously-cropped region so the user can readjust from the original.
    private func enterCropMode() {
        flushPendingDisplayRender()

        // Each crop session starts unconstrained.
        cropAspectPreset = .free
        // Fine straighten is adjusted fresh each crop session.
        straightenDialAngle = 0
        isAdjustingCrop = false
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
            rotationSteps: rotationSteps,
            straightenAngle: straightenAngle
        )

        // Remember the current crop so cancel can restore it.
        preCropScreenshotCropRect = screenshotCropRect

        // screenshotCropRect is in rotated-raw dims, so swap if rotation is odd.
        let (rotW, rotH) = Self.rotatedDims(width: CGFloat(cg.width),
                                            height: CGFloat(cg.height),
                                            steps: rotationSteps)
        let fullBounds = CGRect(x: 0, y: 0, width: rotW, height: rotH)

        if selectedWallpaper == nil {
            cropRect = CGRect(origin: .zero, size: imagePixelSize)
            return
        }

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
        flushPendingDisplayRender()

        // Discard any in-progress straighten — nothing is committed on cancel.
        straightenDialAngle = 0
        isAdjustingCrop = false

        if selectedWallpaper == nil, screenshotCropRect == preCropScreenshotCropRect {
            cropRect = CGRect(origin: .zero, size: imagePixelSize)
            preCropSnapshot = nil
            isCropping = false
            currentTool = .select
            return
        }

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
        flushPendingDisplayRender()
        guard let rawImg = rawImage,
              let srcCG = rawImg.cgImage(forProposedRect: nil, context: nil, hints: nil),
              imagePixelSize.width > 0, imagePixelSize.height > 0,
              targetWidth > 0, targetHeight > 0
        else { return }

        // scaleX/scaleY are in display (rotated) space. The raw bitmap is
        // unrotated, so for odd quarter-turns its axes are swapped relative to
        // the display: the displayed width corresponds to the source height.
        let scaleX = CGFloat(targetWidth) / imagePixelSize.width
        let scaleY = CGFloat(targetHeight) / imagePixelSize.height
        let (srcScaleX, srcScaleY) = rotationSteps % 2 == 0 ? (scaleX, scaleY) : (scaleY, scaleX)
        let newW = max(1, Int((CGFloat(srcCG.width) * srcScaleX).rounded()))
        let newH = max(1, Int((CGFloat(srcCG.height) * srcScaleY).rounded()))

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
            // fontSize and textWidth are stored in image-pixel space (unlike
            // strokeWidth, which is logical points), so they must scale with
            // the image or text bubbles change size relative to the content.
            a.style.fontSize = ann.style.fontSize * min(scaleX, scaleY)
            if let w = ann.style.textWidth {
                a.style.textWidth = w * scaleX
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

    /// Queues a template-driven annotation shift to be applied atomically with
    /// the next display commit (async render or synchronous flush), so the
    /// annotations never move ahead of the bitmap they are drawn over — the
    /// cause of the visible "shift, then settle" while dragging the padding
    /// slider.
    private func deferAnnotationShift(by delta: CGPoint) {
        renderCoordinator.cumulativeShift.x += delta.x
        renderCoordinator.cumulativeShift.y += delta.y
    }

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
        // One authoritative annotation shift for the whole template change,
        // computed old-state → template-state BEFORE any writes. The
        // per-property onChange handlers each compute their delta with the
        // OTHER properties already at their new values, so their sum does not
        // telescope to origin(new) − origin(old) when a template changes
        // several origin-affecting properties at once (padding, aspect ratio
        // and alignment couple inside screenshotOriginInTemplatedCanvas) —
        // annotations would land offset. The handlers skip their shifts while
        // isApplyingTemplatePreset is set.
        let newAspectID = normalizedAspectRatioID(template.aspectRatioID)
        if let rawImage {
            let cropSize = screenshotCropRect.isEmpty ? rawImage.size : screenshotCropRect.size
            let oldOrigin: CGPoint = selectedWallpaper != nil
                ? screenshotOriginInTemplatedCanvas(
                    screenshotPixelSize: cropSize, padding: editorPadding,
                    aspectRatio: selectedEditorAspectRatio?.ratio, alignment: screenshotAlignment)
                : .zero
            let newOrigin: CGPoint = template.wallpaperSource != nil
                ? screenshotOriginInTemplatedCanvas(
                    screenshotPixelSize: cropSize, padding: template.padding,
                    aspectRatio: aspectRatioValue(for: newAspectID), alignment: template.alignment)
                : .zero
            deferAnnotationShift(by: CGPoint(x: newOrigin.x - oldOrigin.x, y: newOrigin.y - oldOrigin.y))
        }

        isApplyingTemplatePreset = true
        selectedWallpaper = template.wallpaperSource
        editorPadding = template.padding
        editorCornerRadius = template.cornerRadius
        shadowIntensity = template.shadowIntensity
        screenshotAlignment = template.alignment
        editorAspectRatioID = newAspectID
        watermarkSettings = template.watermarkSettings
        // Clear on the next runloop tick — after SwiftUI has fired the
        // onChange observers for the writes above (same pattern as
        // isRestoringSession in restoreSessionState).
        DispatchQueue.main.async {
            isApplyingTemplatePreset = false
        }
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
        if !annotations[idx].points.isEmpty {   // freeDraw stroke / angle vertex
            annotations[idx].points = annotations[idx].points.map {
                CGPoint(x: $0.x + delta.width, y: $0.y + delta.height)
            }
        }
    }

    private func installKeyMonitorIfNeeded() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // PDF find shortcuts — handled before the text-field passthrough so
            // Esc / ⌘G work even while the find field has focus.
            if isPDFSession, let win = hostingWindow, event.window === win {
                let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                let key = event.charactersIgnoringModifiers?.lowercased()
                if mods == .command, key == "f" { showFindBar(); return nil }
                if mods == .command, key == "i" { showPDFInfo = true; return nil }
                if isFindBarVisible {
                    if event.keyCode == 53 { closeFindBar(); return nil }            // Esc
                    if mods == .command, key == "g" { findNext(); return nil }       // ⌘G
                    if mods == [.command, .shift], key == "g" { findPrevious(); return nil } // ⌘⇧G
                }
            }

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
            // Scope to this editor's window: every editor installs its own local
            // monitor, so without this check a Delete in any window of the app
            // would delete the selection in every open editor.
            if event.keyCode == 51 || event.keyCode == 117 {
                if hasBlockedModifier { return event }
                guard let win = hostingWindow, event.window === win else { return event }
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

            // PDF page-navigation keys: Home/End, Page Up/Down, and Space /
            // ⇧Space (Space only in View mode, where it's unambiguous).
            if isPDFSession, let win = hostingWindow, event.window === win {
                let onlyShift = event.modifierFlags
                    .intersection([.command, .option, .control]).isEmpty
                switch event.keyCode {
                case 115: goToPDFPageNumber(1); return nil                             // Home
                case 119: goToPDFPageNumber(pdfDocument?.pageCount ?? 1); return nil    // End
                case 116: goToAdjacentPDFPage(-1); return nil                          // Page Up
                case 121: goToAdjacentPDFPage(1); return nil                           // Page Down
                case 49 where onlyShift && editorMode == .view:                        // Space
                    goToAdjacentPDFPage(event.modifierFlags.contains(.shift) ? -1 : 1)
                    return nil
                default: break
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
        magnifyState.lastLocationInWindow = event.locationInWindow
        magnifyState.pendingMagnification *= (1 + event.magnification)
        // One zoom step at a time: while a re-layout + anchor correction is in
        // flight, further pinch ticks accumulate into pendingMagnification and
        // are applied as the next step once the canvas resize lands. This keeps
        // a slow layout (large image, many annotations) from piling up state
        // writes it can't keep pace with.
        if magnifyState.pendingScrollOrigin == nil {
            applyPendingMagnification()
        }
    }

    /// Applies the accumulated pinch factor as a single zoom step and computes
    /// the scroll origin that keeps the content under the cursor anchored. The
    /// origin is applied when the canvas resize actually lands (frameDidChange
    /// observer in `bodyWithObservers`), not from a detached async tick that
    /// races SwiftUI's layout — that race is what made annotations visibly
    /// shift and then settle on every zoom step.
    private func applyPendingMagnification() {
        let factor = magnifyState.pendingMagnification
        magnifyState.pendingMagnification = 1.0
        guard factor != 1.0 else { return }

        let oldScale = effectiveScale
        let newZoom = min(max(zoomLevel * factor, minZoomLevel), maxZoomLevel)
        guard newZoom != zoomLevel else { return }

        guard let scrollView = nsScrollView, oldScale > 0 else {
            zoomLevel = newZoom
            syncZoomToPDFGroup()
            return
        }

        let scaleFactor = (fitScale * newZoom) / oldScale

        // Keep the content point under the cursor pinned across the zoom step.
        // The document view is FLIPPED (top-left origin, y-down), so do all the
        // math in its own coordinate space — never mix in window coords, which
        // are y-up. `convert(_:from: nil)` maps the cursor straight into doc
        // space (handling both the flip and the current scroll), and
        // `documentVisibleRect` is already in that same space. The previous
        // version combined a y-up cursor offset with a y-down scroll origin,
        // inverting the vertical anchor so content drifted out of view on pinch.
        let windowPoint = magnifyState.lastLocationInWindow
        let visibleRect = scrollView.documentVisibleRect
        var newOrigin = visibleRect.origin

        if let docView = scrollView.documentView {
            // Content point currently under the cursor (current scale).
            let cursorInDoc = docView.convert(windowPoint, from: nil)
            // Cursor's pixel offset from the visible top-left — a screen-stable
            // quantity that must remain the same after the content scales about
            // the document origin.
            let offsetX = cursorInDoc.x - visibleRect.origin.x
            let offsetY = cursorInDoc.y - visibleRect.origin.y
            newOrigin = NSPoint(
                x: cursorInDoc.x * scaleFactor - offsetX,
                y: cursorInDoc.y * scaleFactor - offsetY
            )
        }

        magnifyState.pendingScrollOrigin = newOrigin
        zoomLevel = newZoom
        syncZoomToPDFGroup()

        // Fallback: a microscopic zoom step can round to an identical canvas
        // frame, in which case frameDidChange never fires. Apply on the next
        // runloop turn rather than leaving the gesture stuck waiting for a
        // resize that won't come. No-op when the observer already ran.
        DispatchQueue.main.async {
            guard magnifyState.pendingScrollOrigin == newOrigin else { return }
            finishZoomAnchorCorrection(scrollView: scrollView, origin: newOrigin)
        }
    }

    /// Re-anchors the viewport after a zoom step's canvas resize, then applies
    /// any pinch movement that accumulated while the resize was in flight.
    private func finishZoomAnchorCorrection(scrollView: NSScrollView, origin: NSPoint) {
        magnifyState.pendingScrollOrigin = nil
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        if magnifyState.pendingMagnification != 1.0 {
            applyPendingMagnification()
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

    // MARK: - PDF Navigation (shared by Find, Links, Outline)

    /// The shared `PDFDocument` backing the active PDF session (nil for images).
    private var pdfDocument: PDFDocument? {
        activeSession?.pdfPageSource?.document
    }

    /// Sessions belonging to the active PDF's page group, keyed for page lookups.
    private var activePDFGroupSessions: [ImageSession] {
        guard let gid = activeSession?.pdfGroupID else { return [] }
        return sessions.filter { $0.pdfGroupID == gid }
    }

    /// 1-based page number of the active PDF page, or nil for images.
    private var currentPDFPageNumber: Int? {
        activeSession?.pdfPageSource.map { $0.pageIndex + 1 }
    }

    /// Switches to the session showing `page` and, if a page-space `rect` is
    /// given, scrolls it into view once the new page has laid out. Used by Find,
    /// internal links, and the outline.
    private func jumpToPDFPage(_ page: PDFPage, scrollingTo rect: CGRect? = nil) {
        guard let doc = page.document else { return }
        let idx = doc.index(for: page)
        // In continuous mode, scroll the stacked view to the page instead of
        // switching the single-page session.
        if isContinuousPDF {
            continuousScrollTarget = idx
            return
        }
        guard let target = sessions.first(where: {
            $0.pdfPageSource?.document === doc && $0.pdfPageSource?.pageIndex == idx
        }) else { return }
        if target.id != activeSessionID {
            switchToSession(target.id)
        }
        guard let rect else { return }
        // Defer so the (possibly newly switched) page has laid out and fitScale
        // settled before we read effectiveScale / imagePixelSize for the scroll.
        DispatchQueue.main.async { scrollPDFRectIntoView(rect, on: page) }
    }

    /// Scrolls the canvas so a page-space `rect` (PDF points, bottom-left origin)
    /// is visible, with margin. No-op if the canvas scroll view isn't ready.
    private func scrollPDFRectIntoView(_ rect: CGRect, on page: PDFPage) {
        guard let docView = nsScrollView?.documentView else { return }
        let pointSize = page.rotatedMediaBoxSize
        guard pointSize.width > 0, pointSize.height > 0 else { return }
        // page-points → canvas points (canvasW = imagePixelSize.w * effectiveScale).
        let kx = imagePixelSize.width / pointSize.width * effectiveScale
        let ky = imagePixelSize.height / pointSize.height * effectiveScale
        let pad: CGFloat = 20 // matches the canvas `.padding(20)`
        let docRect = CGRect(
            x: rect.minX * kx + pad,
            y: (pointSize.height - rect.maxY) * ky + pad,
            width: rect.width * kx,
            height: rect.height * ky
        )
        docView.scrollToVisible(docRect.insetBy(dx: -60, dy: -60))
    }

    /// Jumps to a 1-based page number within the active PDF.
    private func goToPDFPageNumber(_ oneBased: Int) {
        guard let gid = activeSession?.pdfGroupID,
              let doc = activeSession?.pdfPageSource?.document else { return }
        let idx = oneBased - 1
        guard idx >= 0, idx < doc.pageCount else { return }
        if isContinuousPDF {
            continuousScrollTarget = idx
            return
        }
        guard let target = sessions.first(where: {
            $0.pdfGroupID == gid && $0.pdfPageSource?.pageIndex == idx
        }) else { return }
        switchToSession(target.id)
    }

    /// Moves `delta` pages from the current one (clamped: out-of-range no-ops).
    private func goToAdjacentPDFPage(_ delta: Int) {
        if isContinuousPDF {
            let count = pdfDocument?.pageCount ?? 1
            continuousScrollTarget = min(max(continuousVisiblePage + delta, 0), count - 1)
            return
        }
        guard let current = currentPDFPageNumber else { return }
        goToPDFPageNumber(current + delta)
    }

    /// Leading toolbar control: ‹ [page] / total › for the active PDF.
    @ViewBuilder
    private var pdfPageNavigator: some View {
        let total = pdfDocument?.pageCount ?? activePDFGroupSessions.count
        let current = isContinuousPDF ? continuousVisiblePage + 1 : (currentPDFPageNumber ?? 1)
        HStack(spacing: 4) {
            pdfNavIconButton("chevron.left", help: "Previous Page") { goToAdjacentPDFPage(-1) }
                .disabled(current <= 1)

            TextField("", value: Binding(
                get: { current },
                set: { goToPDFPageNumber($0) }
            ), format: .number)
            .textFieldStyle(.roundedBorder)
            .frame(width: 38)
            .multilineTextAlignment(.center)

            Text("/ \(total)")
                .foregroundStyle(.secondary)
                .monospacedDigit()

            pdfNavIconButton("chevron.right", help: "Next Page") { goToAdjacentPDFPage(1) }
                .disabled(current >= total)

            if editorMode == .view {
                Divider().frame(height: 14)
                pdfNavIconButton(
                    pdfContinuousScroll ? "rectangle.stack.fill" : "rectangle.stack",
                    help: pdfContinuousScroll ? "Single Page View" : "Continuous Scroll"
                ) { toggleContinuousScroll() }
            }

            Divider().frame(height: 14)

            pdfNavIconButton("rotate.left", help: "Rotate Left") { rotatePDFPage(deltaSteps: 3) }
            pdfNavIconButton("rotate.right", help: "Rotate Right") { rotatePDFPage(deltaSteps: 1) }
        }
        .frame(height: 34)
    }

    /// One icon button in the PDF page navigator. The hover highlight is sized to
    /// a fixed glyph-hugging frame (matching the bottom toolbar's button style)
    /// rather than the oversized default toolbar-button background.
    @ViewBuilder
    private func pdfNavIconButton(
        _ systemName: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .frame(width: 30, height: 30)
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(ToolbarHoverButtonStyle())
        .help(help)
    }

    /// Toggles the continuous (all-pages) reading view. Entering, it starts
    /// scrolled to the single-page view's page; leaving, it switches the
    /// single-page session to whichever page the reader was last looking at, so
    /// the two views stay in sync either way.
    private func toggleContinuousScroll() {
        if pdfContinuousScroll {
            if let target = sessions.first(where: { $0.pdfPageSource?.pageIndex == continuousVisiblePage }) {
                switchToSession(target.id)
            }
        } else {
            continuousVisiblePage = activeSession?.pdfPageSource?.pageIndex ?? 0
        }
        pdfContinuousScroll.toggle()
    }

    /// Thumbnail / strip selection. In continuous mode every page is already on
    /// screen, so switching the single-page session would be invisible — instead
    /// scroll the stacked view to the chosen page. Otherwise switch sessions.
    private func selectPageSession(_ id: UUID) {
        if isContinuousPDF,
           let idx = sessions.first(where: { $0.id == id })?.pdfPageSource?.pageIndex {
            continuousScrollTarget = idx
            return
        }
        switchToSession(id)
    }

    /// Which thumbnail the strip highlights: in continuous mode it follows the
    /// page nearest the viewport centre (so it tracks scrolling and clicks);
    /// otherwise the active single-page session.
    private var thumbnailActiveID: UUID? {
        if isContinuousPDF {
            return sessions.first(where: { $0.pdfPageSource?.pageIndex == continuousVisiblePage })?.id
        }
        return activeSessionID
    }

    // MARK: - In-Document Find (PDF)

    /// Search matches that fall on the currently-displayed page (tinted).
    private var searchHighlightsForActivePage: [PDFSelection] {
        guard isFindBarVisible, let page = activePDFPage() else { return [] }
        return findMatches.filter { $0.pages.contains(page) }
    }

    /// The current match, if it is on the displayed page (emphasized).
    private var activeSearchHighlightForPage: PDFSelection? {
        guard isFindBarVisible, let page = activePDFPage(),
              findMatches.indices.contains(currentMatchIndex) else { return nil }
        let match = findMatches[currentMatchIndex]
        return match.pages.contains(page) ? match : nil
    }

    /// True when the continuous (scroll-all-pages) PDF reading view is showing.
    private var isContinuousPDF: Bool {
        isPDFSession && editorMode == .view && pdfContinuousScroll
    }

    /// Search matches on a given page — used by the continuous view to highlight
    /// any page, not just the single active one.
    private func searchHighlights(on page: PDFPage) -> [PDFSelection] {
        guard isFindBarVisible else { return [] }
        return findMatches.filter { $0.pages.contains(page) }
    }

    private func activeSearchHighlight(on page: PDFPage) -> PDFSelection? {
        guard isFindBarVisible, findMatches.indices.contains(currentMatchIndex) else { return nil }
        let match = findMatches[currentMatchIndex]
        return match.pages.contains(page) ? match : nil
    }

    /// Re-runs the document search for the current query and jumps to the first
    /// match. Called as the query changes.
    private func runSearch() {
        guard let doc = pdfDocument, !findQuery.isEmpty else {
            findMatches = []
            currentMatchIndex = 0
            return
        }
        findMatches = doc.findString(findQuery, withOptions: [.caseInsensitive])
        currentMatchIndex = 0
        if !findMatches.isEmpty { focusMatch(0) }
    }

    /// Selects match `index`, switching to its page and scrolling it into view.
    private func focusMatch(_ index: Int) {
        guard findMatches.indices.contains(index) else { return }
        currentMatchIndex = index
        let match = findMatches[index]
        if let page = match.pages.first {
            jumpToPDFPage(page, scrollingTo: match.bounds(for: page))
        }
    }

    private func findNext() {
        guard !findMatches.isEmpty else { return }
        focusMatch((currentMatchIndex + 1) % findMatches.count)
    }

    private func findPrevious() {
        guard !findMatches.isEmpty else { return }
        focusMatch((currentMatchIndex - 1 + findMatches.count) % findMatches.count)
    }

    private func showFindBar() {
        guard isPDFSession else { return }
        isFindBarVisible = true
        findFocusToken += 1 // (re)focus the field, even if already open
    }

    private func closeFindBar() {
        isFindBarVisible = false
        findQuery = ""
        findMatches = []
        currentMatchIndex = 0
    }

    // MARK: - PDF Links

    /// Opens an external link the user clicked in the PDF. This is a deliberate
    /// user action on their own document; the destination is shown on hover.
    private func openPDFLinkURL(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// Follows an internal go-to link: switches to the destination page and
    /// scrolls to the destination point (when the PDF specifies one).
    private func goToPDFDestination(_ dest: PDFDestination) {
        guard let page = dest.page else { return }
        let pt = dest.point
        let unspecified = pt.x == kPDFDestinationUnspecifiedValue
            || pt.y == kPDFDestinationUnspecifiedValue
        let rect: CGRect? = unspecified
            ? nil
            : CGRect(x: pt.x - 4, y: pt.y - 12, width: 8, height: 16)
        jumpToPDFPage(page, scrollingTo: rect)
    }

    // MARK: - PDF Outline (Table of Contents)

    /// Rebuilds the cached outline when the active PDF document changes. Parsing
    /// once (not per render) keeps `PDFOutlineNode` ids stable for `ForEach`.
    private func refreshPDFOutlineIfNeeded() {
        let gid = activeSession?.pdfGroupID
        guard gid != outlineGroupID else { return }
        outlineGroupID = gid
        pdfOutlineNodes = PDFOutlineNode.tree(from: pdfDocument?.outlineRoot)
    }

    /// Jumps to an outline entry's destination page (and point, when specified).
    private func selectOutlineNode(_ node: PDFOutlineNode) {
        guard let page = node.page else { return }
        let rect: CGRect? = node.point.map {
            CGRect(x: $0.x - 4, y: $0.y - 12, width: 8, height: 16)
        }
        jumpToPDFPage(page, scrollingTo: rect)
    }

    // MARK: - Menu Actions

    /// Dispatches a menu-bar command (posted by `EditorWindowController` to this
    /// window) to the matching editor action.
    private func handleMenuAction(_ action: String) {
        switch action {
        case "saveAs":       saveAs()
        case "print":        printImage()
        case "find":         showFindBar()
        case "findNext":     findNext()
        case "findPrevious": findPrevious()
        case "documentInfo": if isPDFSession { showPDFInfo = true }
        case "nextPage":     goToAdjacentPDFPage(1)
        case "previousPage": goToAdjacentPDFPage(-1)
        case "actualSize":   actualSize()
        case "fitWidth":     fitToWidth()
        case "fitPage":      zoomToFit()
        case "zoomIn":       zoomIn()
        case "zoomOut":      zoomOut()
        case "rotateLeft":   if isPDFSession { rotatePDFPage(deltaSteps: 3) } else { rotate(deltaSteps: 3) }
        case "rotateRight":  if isPDFSession { rotatePDFPage(deltaSteps: 1) } else { rotate(deltaSteps: 1) }
        default: break
        }
    }

    private func trashScreenshot() {
        try? FileManager.default.trashItem(at: imageURL, resultingItemURL: nil)

        // With multiple images open, only close the trashed one — dismissing the
        // whole editor would silently discard the other sessions' unsaved edits.
        // PDF pages share one file, so trashing it removes the entire group.
        guard sessions.count > 1, let active = activeSession else {
            onDismiss()
            return
        }
        if let groupID = active.pdfGroupID {
            let groupIDs = sessions.filter { $0.pdfGroupID == groupID }.map(\.id)
            guard groupIDs.count < sessions.count else {
                onDismiss()
                return
            }
            for id in groupIDs {
                removeSession(id)
            }
        } else {
            removeSession(active.id)
        }
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

        flushPendingDisplayRender()
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

    /// Rotates the active PDF page by `delta` × 90° clockwise. Unlike the raster
    /// `rotate(deltaSteps:)`, this drives the live VECTOR view (and export) via
    /// `page.rotation`, re-renders the raster for the thumbnail, and rotates any
    /// annotations about the page so they stay anchored to the content.
    private func rotatePDFPage(deltaSteps delta: Int) {
        guard isPDFSession,
              let session = activeSession,
              let src = session.pdfPageSource,
              let page = src.document.page(at: src.pageIndex) else { return }
        let d = ((delta % 4) + 4) % 4
        guard d != 0 else { return }

        flushPendingDisplayRender()
        pushUndo()
        selectedAnnotationID = nil

        // Rotate annotations (image-pixel space) to follow the content. PDFs have
        // no template/crop, so no gradient-offset remap is needed.
        let oldSize = imagePixelSize
        if !annotations.isEmpty {
            annotations = annotations.map { ann in
                var a = ann
                a.startPoint = Self.rotatePoint90(ann.startPoint, steps: d, in: oldSize)
                a.endPoint = Self.rotatePoint90(ann.endPoint, steps: d, in: oldSize)
                if !ann.points.isEmpty {
                    a.points = ann.points.map { Self.rotatePoint90($0, steps: d, in: oldSize) }
                }
                return a
            }
        }

        // Rotate the page itself — drives the live vector view and PDF export.
        page.rotation = ((page.rotation + d * 90) % 360 + 360) % 360

        // Re-render the raster (thumbnail + raster export) at the new orientation.
        guard let cg = src.renderPage(backingScale: displayBackingScale) else { return }
        let newSize = CGSize(width: cg.width, height: cg.height)
        let nsImage = NSImage(size: NSSize(width: newSize.width, height: newSize.height))
        nsImage.addRepresentation(NSBitmapImageRep(cgImage: cg))

        // A PDF page is the whole "screenshot" (no crop). Reset the crop rect to
        // the rotated raster's bounds so composeDisplayImage doesn't clip the new
        // orientation to the pre-rotation rect (which squished the aspect).
        screenshotCropRect = CGRect(origin: .zero, size: newSize)
        session.screenshotCropRect = screenshotCropRect

        rawImage = nsImage
        session.rawImage = nsImage
        applyDisplayImage(from: nsImage)        // commits image, imagePixelSize, currentDisplayCGImage
        session.generateThumbnail(from: nsImage)
        updateFitScale(viewSize: lastViewSize)
        saveActiveSessionState()
    }

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

    // MARK: - Fine straighten geometry

    /// Rotates a CGImage by an arbitrary angle (degrees), expanding the canvas to
    /// the rotated bounding box (transparent corners). Positive degrees rotate the
    /// content **clockwise** to match SwiftUI's `rotationEffect` (CoreImage is
    /// CCW-positive, hence the negated angle). Used for fine straighten after the
    /// 90° rotation and before crop.
    static func rotateCGImageArbitrary(_ image: CGImage, degrees: Double, ciContext: CIContext) -> CGImage? {
        guard degrees != 0 else { return image }
        let radians = CGFloat(-degrees * .pi / 180)
        let ci = CIImage(cgImage: image)
        let rotated = ci.transformed(by: CGAffineTransform(rotationAngle: radians))
        let shifted = rotated.transformed(
            by: CGAffineTransform(translationX: -rotated.extent.minX, y: -rotated.extent.minY))
        return ciContext.createCGImage(shifted, from: CGRect(origin: .zero, size: rotated.extent.size))
    }

    /// Rotates `p` about `center` by `degrees`. Positive = clockwise in the
    /// top-left-origin (y-down) image-pixel space, matching `rotationEffect` and
    /// `rotateCGImageArbitrary` so annotations stay glued to the image.
    static func rotatePointAboutCenter(_ p: CGPoint, degrees: Double, center c: CGPoint) -> CGPoint {
        let r = degrees * .pi / 180
        let cosT = cos(r), sinT = sin(r)
        let dx = p.x - c.x, dy = p.y - c.y
        return CGPoint(x: c.x + dx * cosT - dy * sinT,
                       y: c.y + dx * sinT + dy * cosT)
    }

    /// Axis-aligned bounding-box size of `size` rotated by `degrees`.
    static func rotatedBoundingBoxSize(_ size: CGSize, degrees: Double) -> CGSize {
        let r = abs(degrees) * .pi / 180
        let c = abs(cos(r)), s = abs(sin(r))
        return CGSize(width: size.width * c + size.height * s,
                      height: size.width * s + size.height * c)
    }

    /// Largest upright (axis-aligned) rectangle that fits inside `size` rotated by
    /// `degrees` — the classic "rotatedRectWithMaxArea". Used to auto-inscribe the
    /// crop so the tilted image never shows empty corners.
    static func largestInscribedSize(_ size: CGSize, degrees: Double) -> CGSize {
        let w = size.width, h = size.height
        guard w > 0, h > 0 else { return .zero }
        let ang = abs(degrees).truncatingRemainder(dividingBy: 180) * .pi / 180
        let sinA = abs(sin(ang)), cosA = abs(cos(ang))
        let widthIsLonger = w >= h
        let longSide = widthIsLonger ? w : h
        let shortSide = widthIsLonger ? h : w
        let wr: CGFloat, hr: CGFloat
        if shortSide <= 2 * sinA * cosA * longSide || abs(sinA - cosA) < 1e-10 {
            let x = 0.5 * shortSide
            if widthIsLonger {
                wr = sinA == 0 ? w : x / sinA
                hr = cosA == 0 ? h : x / cosA
            } else {
                wr = cosA == 0 ? w : x / cosA
                hr = sinA == 0 ? h : x / sinA
            }
        } else {
            let cos2a = cosA * cosA - sinA * sinA
            wr = (w * cosA - h * sinA) / cos2a
            hr = (h * cosA - w * sinA) / cos2a
        }
        return CGSize(width: max(0, wr), height: max(0, hr))
    }

    // MARK: - Undo

    /// Maximum undo depth. Snapshots retain full-resolution bitmaps (`image`,
    /// and after crop/rotate/resize a distinct `rawImage`), so an unbounded
    /// stack can pin hundreds of MB during a long session on a large screenshot.
    private static let maxUndoDepth = 50

    private func pushUndo() {
        if undoStack.count >= Self.maxUndoDepth {
            undoStack.removeFirst(undoStack.count - Self.maxUndoDepth + 1)
        }
        undoStack.append(EditorSnapshot(
            annotations: annotations,
            image: image,
            rawImage: rawImage,
            selectedWallpaper: selectedWallpaper,
            imagePixelSize: imagePixelSize,
            cropRect: cropRect,
            screenshotCropRect: screenshotCropRect,
            photoAdjustments: photoAdjustments,
            rotationSteps: rotationSteps,
            straightenAngle: straightenAngle
        ))
    }

    private func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        // Settle any pending shift/render first — a deferred shift belongs to
        // the pre-undo annotations and must not land on the restored ones.
        flushPendingDisplayRender()
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
        straightenAngle = snapshot.straightenAngle
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
        session.dpiScaleFactor = dpiScaleFactor
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
        session.straightenAngle = straightenAngle
        session.undoStack = undoStack
        session.templateRenderer = templateRenderer
        session.generateThumbnail()
    }

    /// Populates @State from the given ImageSession. Sets `isRestoringSession` for
    /// the duration of the surrounding render pass so the onChange observers don't
    /// treat these assignments as user edits.
    private func restoreSessionState(from session: ImageSession) {
        isRestoringSession = true

        // Supersede any in-flight display render — it belongs to the previous
        // session and must not commit into this one's @State.
        renderCoordinator.invalidate()

        // Rebuild the cached outline if we've switched to a different document.
        refreshPDFOutlineIfNeeded()

        image = session.image
        rawImage = session.rawImage
        currentDisplayCGImage = session.currentDisplayCGImage
        imageMetadata = session.metadata
        imagePixelSize = session.imagePixelSize
        screenshotCropRect = session.screenshotCropRect
        dpiScaleFactor = session.dpiScaleFactor
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
        straightenAngle = session.straightenAngle
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
        // Settle any in-flight render/shift so the stored session state is a
        // consistent image + annotations pair.
        flushPendingDisplayRender()
        flushSiblingTemplateSync()
        saveActiveSessionState()
        activeSessionID = id
        restoreSessionState(from: target)
        // Edit mode (photo adjustments) doesn't apply to PDFs — snap to Annotate.
        if target.isPDF && editorMode == .edit {
            editorMode = .annotate
        }
        // The Text Selection tool is PDF-only — fall back to Select on images.
        if !target.isPDF && currentTool == .textSelect {
            currentTool = .select
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
                if !target.isPDF && currentTool == .textSelect {
                    currentTool = .select
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
        flushPendingDisplayRender()
        let renderer = AnnotationRenderer()
        renderer.styleScale = dpiScaleFactor
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
            let item = NSPasteboardItem()
            // Unique name per copy: a fixed name lets a later copy (e.g. from a
            // second editor window) overwrite the file a recipient app hasn't
            // read yet. Only attach the URL if the write actually succeeded.
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("SimplShot_pasted_\(UUID().uuidString.prefix(8)).png")
            if (try? pngData.write(to: tempURL)) != nil {
                item.setString(tempURL.absoluteString, forType: .fileURL)
            }
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
            flushPendingDisplayRender()
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
        } catch AnnotationRenderer.RenderError.unsupportedEncodeFormat {
            // Source is a decode-only format (e.g. JPEG XL) with no encodable
            // equivalent — can't overwrite in place, so offer "Save As" instead.
            saveAs()
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
        renderer.styleScale = session.dpiScaleFactor
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
    /// Covers every format the app can open (Finder/drag-drop/Open File), so a
    /// save-overwrite never writes mismatched bytes (e.g. JPEG data into a .gif).
    static func writeImage(_ cgImage: CGImage, to url: URL) throws {
        let ext = url.pathExtension.lowercased()

        #if !APPSTORE
        if ext == "webp" {
            let data = try WebPEncoder().encode(cgImage, config: .preset(.photo, quality: 80))
            try data.write(to: url)
            return
        }
        #endif

        let utType: CFString
        var isLossy = false
        switch ext {
        case "png":         utType = UTType.png.identifier as CFString
        case "heic":        utType = UTType.heic.identifier as CFString; isLossy = true
        case "tiff", "tif": utType = UTType.tiff.identifier as CFString
        case "gif":         utType = UTType.gif.identifier as CFString
        case "bmp":         utType = UTType.bmp.identifier as CFString
        case "avif":        utType = "public.avif" as CFString; isLossy = true
        // HEIF is decode-only in ImageIO; HEIC is the equivalent encodable
        // container (HEIF + HEVC), so a .heif overwrite stays a valid HEIF file.
        case "heif":        utType = "public.heic" as CFString; isLossy = true
        case "jp2":         utType = "public.jpeg-2000" as CFString; isLossy = true
        case "psd":         utType = "com.adobe.photoshop-image" as CFString
        // JPEG XL: ImageIO can decode but not encode, and there is no equivalent
        // container — overwrite is impossible. Caller falls back to "Save As".
        case "jxl":         throw AnnotationRenderer.RenderError.unsupportedEncodeFormat
        default:            utType = UTType.jpeg.identifier as CFString; isLossy = true
        }

        var properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: 72.0,
            kCGImagePropertyDPIHeight: 72.0,
        ]
        if isLossy {
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
        flushPendingDisplayRender()

        let panel = NSSavePanel()

        // Held for the lifetime of the (modal) panel so its popup target stays alive.
        var formatPicker: SaveFormatPicker?

        if isPDFSession {
            let pdfName = imageURL.deletingPathExtension().lastPathComponent + ".pdf"
            panel.nameFieldStringValue = pdfName
            panel.allowedContentTypes = [.pdf]
        } else {
            let ext = imageURL.pathExtension.lowercased()
            let jp2Type = UTType("public.jpeg-2000")
            let psdType = UTType("com.adobe.photoshop-image")
            let sourceType: UTType
            switch ext {
            case "png":          sourceType = .png
            // HEIF re-encodes as its equivalent HEIC container.
            case "heic", "heif": sourceType = .heic
            case "jp2":          sourceType = jp2Type ?? .png
            case "psd":          sourceType = psdType ?? .png
            // JPEG XL is decode-only — default to lossless PNG, not lossy JPEG.
            case "jxl":          sourceType = .png
            #if !APPSTORE
            case "webp":         sourceType = .webP
            #endif
            default:             sourceType = .jpeg
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
            if let jp2Type { formats.append(.init(label: "JPEG 2000", type: jp2Type, ext: "jp2")) }
            if let psdType { formats.append(.init(label: "Photoshop", type: psdType, ext: "psd")) }
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
        renderer.styleScale = dpiScaleFactor
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
        flushPendingDisplayRender()
        saveActiveSessionState()

        var images: [NSImage] = []
        let renderer = AnnotationRenderer()

        for session in sessions {
            let cg = session.currentDisplayCGImage
                ?? session.image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            // Each session may have its own DPI (mixed 1×/2× images in one print job).
            renderer.styleScale = session.dpiScaleFactor
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

        // Add a rotation control to the system print panel so a wide (landscape)
        // screenshot can be rotated 90° to fill a portrait page, and vice versa.
        printOperation.printPanel.addAccessoryController(
            PrintRotationAccessoryController(printInfo: printOperation.printInfo)
        )

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

/// How each image is rotated relative to the page before being placed.
/// Stored as an `Int` in `NSPrintInfo.dictionary()` under `printRotationKey`
/// so the print-panel accessory and the print view share one source of truth.
private enum PrintRotation: Int, CaseIterable {
    case none = 0
    case auto = 1              // rotate 90° only when it fills the page better
    case clockwise = 2         // 90° clockwise
    case counterClockwise = 3  // 90° counterclockwise

    var localizedName: String {
        switch self {
        case .none:             return "None"
        case .auto:             return "Auto (fit page)"
        case .clockwise:        return "90° Clockwise"
        case .counterClockwise: return "90° Counterclockwise"
        }
    }

    /// Rotation to apply (in degrees, counterclockwise-positive) for a given
    /// image on a page of `pageSize`. `.auto` rotates only when the image's
    /// orientation differs from the page's.
    func angle(for imageSize: NSSize, pageSize: NSSize) -> CGFloat {
        switch self {
        case .none:             return 0
        case .clockwise:        return -90
        case .counterClockwise: return 90
        case .auto:
            let imageIsLandscape = imageSize.width >= imageSize.height
            let pageIsLandscape = pageSize.width >= pageSize.height
            return imageIsLandscape == pageIsLandscape ? 0 : 90
        }
    }
}

/// Key under which the chosen `PrintRotation` (raw value) is stored in the
/// shared `NSPrintInfo.dictionary()`.
private let printRotationKey = "SimplShotPrintRotation"

/// Reads the selected rotation out of a print info dictionary, defaulting to
/// `.auto` so landscape screenshots fill portrait pages without extra steps.
private func printRotation(from printInfo: NSPrintInfo) -> PrintRotation {
    let raw = (printInfo.dictionary()[printRotationKey] as? Int) ?? PrintRotation.auto.rawValue
    return PrintRotation(rawValue: raw) ?? .auto
}

/// Key under which the chosen scale (an integer percentage) is stored in the
/// shared `NSPrintInfo.dictionary()`.
private let printScaleKey = "SimplShotPrintScale"

/// Percentage presets offered by the Scale popup. 100 % = fit to page (the
/// default), smaller values shrink the content, larger values enlarge it (and
/// may spill past the page, which is then clipped).
private let printScalePresets = [25, 50, 75, 100, 125, 150, 200]

/// Reads the selected scale percentage, defaulting to 100 % (fit to page).
private func printScalePercent(from printInfo: NSPrintInfo) -> Int {
    (printInfo.dictionary()[printScaleKey] as? Int) ?? 100
}

/// A control added to the system print panel that lets the user rotate the
/// printed content 90° (e.g. print a landscape screenshot as portrait).
private final class PrintRotationAccessoryController: NSViewController, NSPrintPanelAccessorizing {
    private let printInfo: NSPrintInfo

    /// Selected rotation, as a `PrintRotation` raw value. `@objc dynamic` so the
    /// print panel can observe it (see `keyPathsForValuesAffectingPreview`) and
    /// refresh the preview when it changes.
    @objc dynamic var rotationMode: Int {
        didSet { printInfo.dictionary()[printRotationKey] = rotationMode }
    }

    /// Selected scale, as an integer percentage. `@objc dynamic` for the same
    /// preview-observation reason as `rotationMode`.
    @objc dynamic var scalePercent: Int {
        didSet { printInfo.dictionary()[printScaleKey] = scalePercent }
    }

    init(printInfo: NSPrintInfo) {
        self.printInfo = printInfo
        self.rotationMode = printRotation(from: printInfo).rawValue
        self.scalePercent = printScalePercent(from: printInfo)
        super.init(nibName: nil, bundle: nil)
        // Seed the dictionary so the print view sees the defaults immediately.
        printInfo.dictionary()[printRotationKey] = rotationMode
        printInfo.dictionary()[printScaleKey] = scalePercent
        title = "Layout"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private let rowHeight: CGFloat = 44
    private let leftInset: CGFloat = 20
    private let rightInset: CGFloat = 16

    override func loadView() {
        // Print-panel accessories are laid out by frame, not Auto Layout, so
        // build a frame-based view. Origin is bottom-left (view is not flipped).
        // The container is flexible-width so the panel can stretch it to fill
        // the accessory column (matching the width of the system sections); each
        // row's label is pinned left and its popup pinned right — native
        // label-left / value-right rows, like the "Media & Quality" card.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: rowHeight * 2))
        container.autoresizingMask = [.width]

        // Top row: Rotate. Bottom row: Scale. (Bottom-left origin → the top row
        // sits at the higher y.)
        let rotatePopup = makeRow(
            in: container, title: "Rotate:", centerY: rowHeight + rowHeight / 2,
            action: #selector(rotationChanged(_:)))
        for rotation in PrintRotation.allCases {
            let item = NSMenuItem(title: rotation.localizedName, action: nil, keyEquivalent: "")
            item.tag = rotation.rawValue
            rotatePopup.menu?.addItem(item)
        }
        rotatePopup.selectItem(withTag: rotationMode)

        let scalePopup = makeRow(
            in: container, title: "Scale:", centerY: rowHeight / 2,
            action: #selector(scaleChanged(_:)))
        for percent in printScalePresets {
            let item = NSMenuItem(title: "\(percent)%", action: nil, keyEquivalent: "")
            item.tag = percent
            scalePopup.menu?.addItem(item)
        }
        scalePopup.selectItem(withTag: scalePercent)

        // Hairline separator between the two rows, matching the system card.
        let separator = NSBox(frame: NSRect(x: leftInset, y: rowHeight,
                                            width: container.frame.width - leftInset, height: 1))
        separator.boxType = .separator
        separator.autoresizingMask = [.width]
        container.addSubview(separator)

        self.view = container
    }

    /// Builds one label-left / popup-right row and adds it to `container`,
    /// returning the popup so the caller can populate its menu.
    private func makeRow(in container: NSView, title: String,
                         centerY: CGFloat, action: Selector) -> NSPopUpButton {
        let label = NSTextField(labelWithString: title)
        label.alignment = .left
        label.sizeToFit()
        label.frame.origin = NSPoint(x: leftInset, y: centerY - label.frame.height / 2)
        label.autoresizingMask = [.maxXMargin]
        container.addSubview(label)

        let popupWidth: CGFloat = 210
        let popupHeight: CGFloat = 25
        let popup = NSPopUpButton(
            frame: NSRect(x: container.frame.width - rightInset - popupWidth,
                          y: centerY - popupHeight / 2,
                          width: popupWidth, height: popupHeight),
            pullsDown: false)
        popup.target = self
        popup.action = action
        popup.autoresizingMask = [.minXMargin]  // stay pinned to the right edge
        container.addSubview(popup)
        return popup
    }

    @objc private func rotationChanged(_ sender: NSPopUpButton) {
        rotationMode = sender.selectedTag()
    }

    @objc private func scaleChanged(_ sender: NSPopUpButton) {
        scalePercent = sender.selectedTag()
    }

    // MARK: NSPrintPanelAccessorizing

    func localizedSummaryItems() -> [[NSPrintPanel.AccessorySummaryKey: String]] {
        let rotationName = (PrintRotation(rawValue: rotationMode) ?? .auto).localizedName
        return [
            [.itemName: "Rotation", .itemDescription: rotationName],
            [.itemName: "Scale", .itemDescription: "\(scalePercent)%"],
        ]
    }

    func keyPathsForValuesAffectingPreview() -> Set<String> {
        ["rotationMode", "scalePercent"]
    }
}

/// An NSView that paginates a list of images, one per printed page.
/// Each image is scaled to fit within the page's printable area while
/// preserving its aspect ratio, optionally rotated 90° (see `PrintRotation`).
private class MultiPagePrintView: NSView {
    private let images: [NSImage]

    init(images: [NSImage]) {
        self.images = images
        super.init(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Printable area of a single page (paper size minus margins) for the
    /// active print operation. All pagination math derives from this so the
    /// frame, page rects, and drawing stay consistent.
    private func printablePageSize() -> NSSize {
        let printInfo = NSPrintOperation.current?.printInfo ?? NSPrintInfo.shared
        let paperSize = printInfo.paperSize
        return NSSize(
            width: paperSize.width - printInfo.leftMargin - printInfo.rightMargin,
            height: paperSize.height - printInfo.topMargin - printInfo.bottomMargin
        )
    }

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        // AppKit validates pagination immediately after this call, so the frame
        // must already span every page here — not just in `rectForPage`.
        // Leaving it at the init size trips an AppKit pagination assertion
        // (a debugger breakpoint) that halts the app under Xcode.
        let page = printablePageSize()
        frame = NSRect(x: 0, y: 0, width: page.width,
                       height: page.height * CGFloat(images.count))
        range.pointee = NSRange(location: 1, length: images.count)
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect {
        let pageSize = printablePageSize()
        frame = NSRect(x: 0, y: 0, width: pageSize.width,
                       height: pageSize.height * CGFloat(images.count))
        return NSRect(x: 0, y: pageSize.height * CGFloat(page - 1),
                      width: pageSize.width, height: pageSize.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current else { return }
        let printInfo = NSPrintOperation.current?.printInfo ?? NSPrintInfo.shared
        let pageSize = printablePageSize()
        let printableWidth = pageSize.width
        let printableHeight = pageSize.height
        let rotation = printRotation(from: printInfo)
        // User scale multiplies the fit-to-page size: 100 % = fit, <100 % shrinks,
        // >100 % enlarges (and may spill past the page, which is clipped).
        let userScale = CGFloat(printScalePercent(from: printInfo)) / 100.0

        for (index, image) in images.enumerated() {
            let pageOriginY = printableHeight * CGFloat(index)
            let pageRect = NSRect(x: 0, y: pageOriginY,
                                  width: printableWidth, height: printableHeight)
            guard dirtyRect.intersects(pageRect) else { continue }

            let imageSize = image.size
            guard imageSize.width > 0, imageSize.height > 0 else { continue }

            let angle = rotation.angle(for: imageSize, pageSize: pageSize)
            let rotated = abs(angle) == 90

            // When rotated 90°, the page's width/height axes swap relative to
            // the image, so fit against the swapped extents.
            let availW = rotated ? printableHeight : printableWidth
            let availH = rotated ? printableWidth : printableHeight
            let fitScale = min(availW / imageSize.width,
                               availH / imageSize.height,
                               1.0)
            let scale = fitScale * userScale
            let drawW = imageSize.width * scale
            let drawH = imageSize.height * scale

            context.saveGraphicsState()
            // Rotate about the page center, then draw the image centered there.
            let transform = NSAffineTransform()
            transform.translateX(by: printableWidth / 2,
                                 yBy: pageOriginY + printableHeight / 2)
            transform.rotate(byDegrees: angle)
            transform.concat()
            image.draw(in: NSRect(x: -drawW / 2, y: -drawH / 2, width: drawW, height: drawH),
                       from: .zero, operation: .sourceOver, fraction: 1.0)
            context.restoreGraphicsState()
        }
    }
}

/// Holder for in-flight pinch-zoom state. Magnify events multiply into
/// `pendingMagnification`; one zoom step (state write + canvas re-layout +
/// scroll-anchor correction) is in flight at a time, marked by a non-nil
/// `pendingScrollOrigin`. Ticks that arrive mid-flight accumulate and are
/// applied as the next step once the resize lands.
private final class MagnifyGestureState {
    var pendingMagnification: CGFloat = 1.0
    var pendingScrollOrigin: NSPoint?
    var lastLocationInWindow: NSPoint = .zero
}

/// Coordinates the asynchronous display-render pipeline. Generations implement
/// latest-wins: stale queued renders are skipped before doing any work, and a
/// completed render commits only if it is newer than the last commit.
///
/// The template-driven annotation shift (padding/wallpaper/aspect/alignment
/// changes) is tracked as a running total (`cumulativeShift`) plus the portion
/// already applied (`appliedShift`). Each render snapshots the total at its
/// start and, at commit, applies exactly the difference to the applied amount —
/// so the shift lands once and only once no matter which renders get skipped
/// or commit progressively. (Tracking per-render deltas instead double-applies
/// when two overlapping renders both commit.)
///
/// Reference type so per-tick bookkeeping doesn't invalidate the SwiftUI view
/// tree; only `generation` crosses threads (guarded by the lock).
private final class DisplayRenderCoordinator {
    private let lock = NSLock()
    private var generation = 0

    // Main-thread-only bookkeeping.
    /// Total shift requested since the last invalidation. Running sum — never
    /// reduced by commits.
    var cumulativeShift: CGPoint = .zero
    /// The portion of `cumulativeShift` already applied to the annotations.
    private var appliedShift: CGPoint = .zero
    var lastCommittedGeneration = 0
    var hasUncommittedRender = false

    var isDirty: Bool { hasUncommittedRender || cumulativeShift != appliedShift }

    /// Returns the shift still owed up to `target` (a snapshot of
    /// `cumulativeShift`) and marks it applied. Commits happen in generation
    /// order, so targets are monotone and each delta is applied exactly once.
    func takeShift(upTo target: CGPoint) -> CGPoint {
        let delta = CGPoint(x: target.x - appliedShift.x, y: target.y - appliedShift.y)
        appliedShift = target
        return delta
    }

    func advanceGeneration() -> Int {
        lock.lock(); defer { lock.unlock() }
        generation += 1
        return generation
    }

    func isCurrent(_ g: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return g == generation
    }

    /// Supersedes all pending work and clears bookkeeping (session switches).
    func invalidate() {
        lastCommittedGeneration = advanceGeneration()
        cumulativeShift = .zero
        appliedShift = .zero
        hasUncommittedRender = false
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
