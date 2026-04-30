import SwiftUI
import StoreKit
import UniformTypeIdentifiers
import AppKit
#if !APPSTORE
import WebP
#endif

/// Root view for the screenshot editor window.
struct EditorView: View {
    /// The URL of the captured screenshot file.
    let imageURL: URL

    /// Template for applying a background. Falls back to `.default` so the
    /// editor can always add/change a gradient even when no template was passed.
    let template: ScreenshotTemplate

    /// Optional app settings for reading/writing persisted editor preferences.
    var appSettings: AppSettings?

    /// When true, start with "Original" aspect ratio regardless of app defaults.
    var preferOriginalAspectRatio: Bool = false

    /// Callback when the editor is done (save or discard) — closes the window.
    var onDismiss: () -> Void = {}

    @State private var image: NSImage?
    @State private var rawImage: NSImage?
    @State private var currentDisplayCGImage: CGImage?
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
    @State private var currentTool: AnnotationTool = .arrow
    @State private var currentStyle: AnnotationStyle = AnnotationStyle()

    // Crop state
    @State private var isCropping: Bool = false
    @State private var cropRect: CGRect = .zero
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

    // Sidebar / pro mode
    // NavigationSplitView drives sidebar visibility; showProSidebar is a derived bool.
    // Initialized from appSettings so the layout is correct from the first frame
    // (avoids a geometry race when NavigationSplitView animates the sidebar in).
    @State private var columnVisibility: NavigationSplitViewVisibility
    @State private var shadowIntensity: Double = 1.0
    @State private var screenshotAlignment: CanvasAlignment = .middleCenter
    @State private var watermarkSettings: WatermarkSettings = WatermarkSettings()

    init(
        imageURL: URL,
        template: ScreenshotTemplate? = nil,
        appSettings: AppSettings? = nil,
        preferOriginalAspectRatio: Bool = false,
        onDismiss: @escaping () -> Void = {}
    ) {
        self.imageURL = imageURL
        let resolvedTemplate = template ?? appSettings?.defaultCaptureTemplate ?? .default
        self.template = resolvedTemplate
        self.appSettings = appSettings
        self.preferOriginalAspectRatio = preferOriginalAspectRatio
        self.onDismiss = onDismiss
        _columnVisibility = State(initialValue:
            appSettings?.editorShowProSidebar == true ? .all : .detailOnly
        )
        _watermarkSettings = State(initialValue: resolvedTemplate.watermarkSettings)
#if !APPSTORE
        _editorAspectRatioID = State(initialValue:
            preferOriginalAspectRatio ? nil : appSettings?.selectedRatioID
        )
#endif
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
    @State private var deleteKeyMonitor: Any?


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
            installDeleteKeyMonitorIfNeeded()
        }
        .onDisappear {
            removeDeleteKeyMonitor()
        }
        .onDeleteCommand(perform: deleteSelected)
        .onExitCommand {
            if isCropping {
                cancelCrop()
            }
        }
        .onChange(of: selectedWallpaper) { oldValue, newValue in
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
                applyDisplayImage(from: rawImage)
            }
        }
        .onChange(of: editorPadding) { oldValue, newValue in
            appSettings?.screenshotTemplate.padding = newValue
            if selectedWallpaper != nil, let rawImage {
                let cropSize = screenshotCropRect.isEmpty ? rawImage.size : screenshotCropRect.size
                let oldOrigin = screenshotOriginInTemplatedCanvas(screenshotPixelSize: cropSize, padding: oldValue, aspectRatio: selectedEditorAspectRatio?.ratio, alignment: screenshotAlignment)
                let newOrigin = screenshotOriginInTemplatedCanvas(screenshotPixelSize: cropSize, padding: newValue, aspectRatio: selectedEditorAspectRatio?.ratio, alignment: screenshotAlignment)
                shiftAnnotations(by: CGPoint(x: newOrigin.x - oldOrigin.x, y: newOrigin.y - oldOrigin.y))
                applyDisplayImage(from: rawImage)
            }
        }
        .onChange(of: editorAspectRatioID) { oldID, newID in
            if selectedWallpaper != nil, let rawImage {
                let cropSize = screenshotCropRect.isEmpty ? rawImage.size : screenshotCropRect.size
                let oldRatio = aspectRatioValue(for: oldID)
                let newRatio = aspectRatioValue(for: newID)
                let oldOrigin = screenshotOriginInTemplatedCanvas(screenshotPixelSize: cropSize, padding: editorPadding, aspectRatio: oldRatio)
                let newOrigin = screenshotOriginInTemplatedCanvas(screenshotPixelSize: cropSize, padding: editorPadding, aspectRatio: newRatio)
                shiftAnnotations(by: CGPoint(x: newOrigin.x - oldOrigin.x, y: newOrigin.y - oldOrigin.y))
                applyDisplayImage(from: rawImage)
            }
        }
        .onChange(of: editorCornerRadius) { _, newValue in
            appSettings?.screenshotTemplate.cornerRadius = newValue
            if selectedWallpaper != nil, let rawImage {
                applyDisplayImage(from: rawImage)
            }
        }
    }

    private var bodyWithObservers: some View {
        bodyBase
        .onChange(of: screenshotAlignment) { oldAlignment, newAlignment in
            if selectedWallpaper != nil, let rawImage {
                let cropSize = screenshotCropRect.isEmpty ? rawImage.size : screenshotCropRect.size
                let oldOrigin = screenshotOriginInTemplatedCanvas(screenshotPixelSize: cropSize, padding: editorPadding, aspectRatio: selectedEditorAspectRatio?.ratio, alignment: oldAlignment)
                let newOrigin = screenshotOriginInTemplatedCanvas(screenshotPixelSize: cropSize, padding: editorPadding, aspectRatio: selectedEditorAspectRatio?.ratio, alignment: newAlignment)
                shiftAnnotations(by: CGPoint(x: newOrigin.x - oldOrigin.x, y: newOrigin.y - oldOrigin.y))
                applyDisplayImage(from: rawImage)
            }
        }
        .onChange(of: columnVisibility) { _, newValue in
            appSettings?.editorShowProSidebar = (newValue != .detailOnly)
        }
        .onChange(of: imagePixelSize) { _, _ in
            updateFitScale(viewSize: lastViewSize)
        }
        .onChange(of: shadowIntensity) { _, _ in
            if selectedWallpaper != nil, let rawImage {
                applyDisplayImage(from: rawImage)
            }
        }
        .onChange(of: isCropping) { _, newValue in
            if newValue {
                enterCropMode()
            }
        }
        .onChange(of: selectedAnnotationID) { _, newID in
            if let id = newID,
               let ann = annotations.first(where: { $0.id == id }) {
                currentStyle = ann.style
            }
        }
        .onChange(of: currentTool) { _, newTool in
            handleToolChange(newTool)
        }
        .onChange(of: appSettings?.selectedEditorTemplateID) { _, newValue in
            guard let appSettings,
                  let id = newValue,
                  let template = appSettings.editorTemplates.first(where: { $0.id == id })
            else { return }
            applyEditorTemplate(template)
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
            if showProSidebar {
                sidebarContent
                    .transition(.move(edge: .leading))
            }
            detailContent
        }
        // Scoped animation: only animates the sidebar's insertion/removal transition.
        // Using .animation on the whole HStack could add overhead to every child view
        // change within the animation environment (including the canvas during drag).
        .animation(.easeInOut(duration: 0.2), value: showProSidebar)
        .toolbar {
            // [Panel Toggle Button]
            ToolbarItem(placement: .automatic) {
                Button {
                    columnVisibility = showProSidebar ? .detailOnly : .all
                } label: {
                    Image(systemName: "sidebar.leading")
                }
                .help(showProSidebar ? "Hide Sidebar" : "Show Sidebar")
            }

            // [flexible spacer] — always present, keeps tools centered
            ToolbarItem(placement: .automatic) {
                Spacer()
            }

            // [Main toolbar with all tools] — centered by surrounding spacers
            ToolbarItem(placement: .automatic) {
                EditorToolbarView(
                    showProSidebar: showProSidebar,
                    currentTool: $currentTool,
                    currentStyle: $currentStyle,
                    isCropping: $isCropping,
                    selectedAnnotationID: $selectedAnnotationID,
                    annotations: $annotations,
                    hasTemplate: true,
                    selectedWallpaper: $selectedWallpaper,
                    customBackgroundImages: appSettings?.customBackgroundImages ?? [],
                    onAddCustomImage: addCustomBackgroundImage,
                    onRemoveCustomImage: removeCustomBackgroundImage,
                    onApplyCrop: applyCrop,
                    onCancelCrop: cancelCrop
                )
            }

            // [flexible spacer] — always present, pins Undo & Done to far right
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
                Button("Done", action: saveOverwrite)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
                    .help("Save, close and copy the image to your clipboard")
            }
        }
    }

    // MARK: - Sidebar Content

    private var sidebarContent: some View {
        EditorSidebarView(
            showProSidebar: showProSidebarBinding,
            currentTool: $currentTool,
            currentStyle: $currentStyle,
            selectedAnnotationID: $selectedAnnotationID,
            annotations: $annotations,
            isCropping: $isCropping,
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
            hasTemplate: true,
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
            onUndo: undo,
            onDone: saveOverwrite,
            watermarkSettings: $watermarkSettings,
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
            GeometryReader { geo in
                Group {
                    if let image {
                        ScrollView([.horizontal, .vertical], showsIndicators: zoomLevel > 1.0) {
                            EditorCanvasView(
                                image: image,
                                imagePixelSize: imagePixelSize,
                                scale: effectiveScale,
                                displayBackingScale: displayBackingScale,
                                shadowIntensity: 0,
                                showBorderOutline: selectedWallpaper == nil,
                                annotations: $annotations,
                                selectedAnnotationID: $selectedAnnotationID,
                                currentTool: $currentTool,
                                currentStyle: $currentStyle,
                                cropRect: $cropRect,
                                isCropping: $isCropping,
                                cropBoundsRect: screenshotBoundsInDisplay,
                                watermarkSettings: watermarkSettings,
                                onCommit: pushUndo
                            )
                            .padding(20)
                        }
                    } else {
                        ContentUnavailableView("Unable to load image", systemImage: "photo.badge.exclamationmark")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .onAppear {
                    lastViewSize = geo.size
                    updateFitScale(viewSize: geo.size)
                }
                .onChange(of: geo.size) { _, newSize in
                    lastViewSize = newSize
                    updateFitScale(viewSize: newSize)
                }
            }

            EditorBottomToolbarView(
                aspectRatios: editorAspectRatios,
                selectedAspectRatioID: $editorAspectRatioID,
                padding: $editorPadding,
                cornerRadius: $editorCornerRadius,
                useTemplateBackground: selectedWallpaper != nil,
                hideSliders: showProSidebar,
                onTrash: { showTrashAlert = true },
                onSaveAs: saveAs
            )
            .background(.clear)

            statusBar
        }
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack(spacing: 12) {
            if imagePixelSize != .zero {
                Text("\(Int(imagePixelSize.width)) x \(Int(imagePixelSize.height)) px")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("\(annotations.count) annotation\(annotations.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider().frame(height: 14)

            // Zoom controls
            HStack(spacing: 4) {
                Button {
                    zoomOut()
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help("Zoom Out")

                Text("\(Int(displayZoomPercent))%")
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 40, alignment: .center)

                Button {
                    zoomIn()
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help("Zoom In")

                Button {
                    zoomLevel = 1.0
                } label: {
                    Text("Fit")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .help("Reset Zoom")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.clear)
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
            zoomLevel = next
        }
    }

    private func zoomOut() {
        if let prev = zoomSteps.last(where: { $0 < zoomLevel }) {
            zoomLevel = prev
        }
    }

    // MARK: - Image Loading

    private func loadImage() {
        guard let nsImage = NSImage(contentsOf: imageURL) else { return }
        rawImage = nsImage
        // Initialize the crop to the full raw image bounds (non-destructive crop starts at full size).
        if let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            screenshotCropRect = CGRect(x: 0, y: 0,
                                        width: CGFloat(cg.width), height: CGFloat(cg.height))
        }
        applyDisplayImage(from: nsImage)
    }
    private func applyDisplayImage(from source: NSImage) {
        guard let cgSource = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            image = source
            currentDisplayCGImage = nil
            imagePixelSize = source.size
            cropRect = CGRect(origin: .zero, size: source.size)
            return
        }

        // Apply non-destructive crop to the raw screenshot before compositing.
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

        var displayCG = croppedCG
        if let wallpaper = selectedWallpaper {
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
            screenshotCropRect: screenshotCropRect
        )

        // Remember the current crop so cancel can restore it.
        preCropScreenshotCropRect = screenshotCropRect

        let fullBounds = CGRect(x: 0, y: 0,
                                width: CGFloat(cg.width), height: CGFloat(cg.height))

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
              imagePixelSize.width > 0, targetWidth > 0, targetHeight > 0
        else { return }

        let scale = CGFloat(targetWidth) / imagePixelSize.width
        let newW = max(1, Int((CGFloat(srcCG.width) * scale).rounded()))
        let newH = max(1, Int((CGFloat(srcCG.height) * scale).rounded()))

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
            a.startPoint = CGPoint(x: ann.startPoint.x * scale, y: ann.startPoint.y * scale)
            a.endPoint   = CGPoint(x: ann.endPoint.x * scale,   y: ann.endPoint.y * scale)
            if !ann.points.isEmpty {
                a.points = ann.points.map { CGPoint(x: $0.x * scale, y: $0.y * scale) }
            }
            return a
        }

        screenshotCropRect = CGRect(
            x: screenshotCropRect.minX * scale,
            y: screenshotCropRect.minY * scale,
            width: screenshotCropRect.width * scale,
            height: screenshotCropRect.height * scale
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

    private func installDeleteKeyMonitorIfNeeded() {
        guard deleteKeyMonitor == nil else { return }
        deleteKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Backspace/Delete and forward-delete keys
            let isDeleteKey = event.keyCode == 51 || event.keyCode == 117
            guard isDeleteKey else { return event }

            // Preserve standard text editing behavior.
            if let firstResponder = NSApp.keyWindow?.firstResponder {
                if firstResponder is NSTextView || firstResponder is NSTextField {
                    return event
                }
            }

            // Ignore when using command/option/control modified shortcuts.
            let blockedModifiers: NSEvent.ModifierFlags = [.command, .option, .control]
            if !event.modifierFlags.intersection(blockedModifiers).isEmpty {
                return event
            }

            deleteSelected()
            return nil
        }
    }

    private func removeDeleteKeyMonitor() {
        if let monitor = deleteKeyMonitor {
            NSEvent.removeMonitor(monitor)
            deleteKeyMonitor = nil
        }
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

    // MARK: - Undo

    private func pushUndo() {
        undoStack.append(EditorSnapshot(
            annotations: annotations,
            image: image,
            rawImage: rawImage,
            selectedWallpaper: selectedWallpaper,
            imagePixelSize: imagePixelSize,
            cropRect: cropRect,
            screenshotCropRect: screenshotCropRect
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

    // MARK: - Save

    /// Returns the current CGImage for rendering/export, using the stored reference
    /// to avoid re-scaling via NSImage.cgImage(forProposedRect:).
    private func currentCGImage() -> CGImage? {
        if let cg = currentDisplayCGImage { return cg }
        return image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    private func copyToClipboard() {
        copyToClipboardSilent()
        onDismiss()
    }

    /// Copies the current image to the clipboard without dismissing the editor.
    private func copyToClipboardSilent() {
        guard let cgImage = currentCGImage() else { return }

        let renderer = AnnotationRenderer()
        guard let outputImage = try? renderer.render(image: cgImage, annotations: annotations, backingScale: displayBackingScale, cropRect: nil, watermark: watermarkSettings)
        else { return }

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

    private func saveOverwrite() {
        do {
            try exportAndSave(to: imageURL)
            copyToClipboardSilent()
            requestReviewIfEligible()
            onDismiss()
        } catch {
            showSaveError(error)
        }
    }

    private func saveAs() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = imageURL.lastPathComponent
        let ext = imageURL.pathExtension.lowercased()
        let contentType: UTType
        switch ext {
        case "png":  contentType = .png
        case "heic": contentType = .heic
        #if !APPSTORE
        case "webp": contentType = .webP
        #endif
        default:     contentType = .jpeg
        }
        panel.allowedContentTypes = [contentType]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try exportAndSave(to: url)
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

        let ext = url.pathExtension.lowercased()

        #if !APPSTORE
        // WebP encoding requires the swift-webp library; CGImageDestination
        // does not support WebP encoding on macOS.
        if ext == "webp" {
            let data = try WebPEncoder().encode(outputImage, config: .preset(.photo, quality: 80))
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
        CGImageDestinationAddImage(destination, outputImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw AnnotationRenderer.RenderError.cannotCreateOutputImage
        }
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

    private func showSaveError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Save Failed"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}
