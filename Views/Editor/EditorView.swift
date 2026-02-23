import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// Root view for the screenshot editor window.
struct EditorView: View {
    /// The URL of the captured screenshot file.
    let imageURL: URL

    /// Optional template for applying a background.
    let template: ScreenshotTemplate?

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
    /// nil = no background; non-nil = background enabled with that gradient.
    @State private var selectedGradient: BuiltInGradient? = nil
    /// Local copies of template padding/cornerRadius for live editing in the bottom toolbar.
    @State private var editorAspectRatioID: UUID? = nil
    @State private var editorPadding: Int = 80
    @State private var editorCornerRadius: Int = 24

    // Annotation state
    @State private var annotations: [Annotation] = []
    @State private var selectedAnnotationID: UUID?
    @State private var currentTool: AnnotationTool = .arrow
    @State private var currentStyle: AnnotationStyle = AnnotationStyle()

    // Crop state
    @State private var isCropping: Bool = false
    @State private var cropRect: CGRect = .zero

    // Zoom state
    @State private var zoomLevel: CGFloat = 1.0  // 1.0 = fit to view
    @State private var fitScale: CGFloat = 0.5   // computed base scale to fit image
    @State private var lastViewSize: CGSize = .zero  // cached for re-fitting after image swap

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

    private let zoomSteps: [CGFloat] = [0.25, 0.5, 0.75, 1.0, 1.5, 2.0, 3.0]
    private var editorAspectRatios: [AspectRatio] {
        appSettings?.aspectRatios ?? Constants.defaultAspectRatios
    }
    private var selectedEditorAspectRatio: AspectRatio? {
        guard let id = editorAspectRatioID else { return nil }
        return editorAspectRatios.first(where: { $0.id == id })
    }

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                // Canvas area — GeometryReader always fills available space
                // so the window frame is respected even before the image loads.
                GeometryReader { geo in
                    Group {
                        if let image {
                            ScrollView([.horizontal, .vertical], showsIndicators: zoomLevel > 1.0) {
                                EditorCanvasView(
                                    image: image,
                                    imagePixelSize: imagePixelSize,
                                    scale: effectiveScale,
                                    displayBackingScale: displayBackingScale,
                                    showShadow: selectedGradient == nil,
                                    annotations: $annotations,
                                    selectedAnnotationID: $selectedAnnotationID,
                                    currentTool: $currentTool,
                                    currentStyle: $currentStyle,
                                    cropRect: $cropRect,
                                    isCropping: $isCropping,
                                    onCommit: pushUndo
                                )
                                .padding(.top, 60)  // clear space for floating toolbar
                                .padding(20)
                            }
                            .background(Color(nsColor: .controlBackgroundColor))
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

                // Bottom toolbar with sliders and action buttons
                EditorBottomToolbarView(
                    aspectRatios: editorAspectRatios,
                    selectedAspectRatioID: $editorAspectRatioID,
                    padding: $editorPadding,
                    cornerRadius: $editorCornerRadius,
                    useTemplateBackground: selectedGradient != nil,
                    onTrash: { showTrashAlert = true },
                    onCopy: copyToClipboard,
                    onSaveAs: saveAs
                )
                .background(.clear)

                // Status bar with zoom controls
                statusBar
            }

            // Floating glass toolbar overlaid at the top
            EditorToolbarView(
                currentTool: $currentTool,
                currentStyle: $currentStyle,
                isCropping: $isCropping,
                selectedAnnotationID: $selectedAnnotationID,
                annotations: $annotations,
                canUndo: !undoStack.isEmpty,
                hasTemplate: template != nil,
                selectedGradient: $selectedGradient,
                onApplyCrop: applyCrop,
                onCancelCrop: cancelCrop,
                onUndo: undo,
                onDone: saveOverwrite
            )
        }
        .onAppear {
            if let appSettings, let template {
                editorAspectRatioID = preferOriginalAspectRatio ? nil : appSettings.selectedRatioID
                editorPadding = template.padding
                editorCornerRadius = template.cornerRadius
                if appSettings.editorUseTemplateBackground {
                    if case .builtInGradient(let gradient) = template.wallpaperSource {
                        selectedGradient = gradient
                    } else {
                        selectedGradient = .oceanDreams
                    }
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
        .onChange(of: selectedGradient) { oldValue, newValue in
            let wasEnabled = oldValue != nil
            let isEnabled = newValue != nil
            appSettings?.editorUseTemplateBackground = isEnabled
            if let rawImage {
                if wasEnabled != isEnabled {
                    let oldOrigin = wasEnabled ? screenshotOriginInTemplatedCanvas(for: rawImage, padding: editorPadding, aspectRatio: selectedEditorAspectRatio?.ratio) : .zero
                    let newOrigin = isEnabled ? screenshotOriginInTemplatedCanvas(for: rawImage, padding: editorPadding, aspectRatio: selectedEditorAspectRatio?.ratio) : .zero
                    shiftAnnotations(by: CGPoint(x: newOrigin.x - oldOrigin.x, y: newOrigin.y - oldOrigin.y))
                }
                applyDisplayImage(from: rawImage)
            }
        }
        .onChange(of: editorPadding) { oldValue, newValue in
            appSettings?.screenshotTemplate.padding = newValue
            if selectedGradient != nil, let rawImage {
                let oldOrigin = screenshotOriginInTemplatedCanvas(for: rawImage, padding: oldValue, aspectRatio: selectedEditorAspectRatio?.ratio)
                let newOrigin = screenshotOriginInTemplatedCanvas(for: rawImage, padding: newValue, aspectRatio: selectedEditorAspectRatio?.ratio)
                shiftAnnotations(by: CGPoint(x: newOrigin.x - oldOrigin.x, y: newOrigin.y - oldOrigin.y))
                applyDisplayImage(from: rawImage)
            }
        }
        .onChange(of: editorAspectRatioID) { oldID, newID in
            if selectedGradient != nil, let rawImage {
                // Keep annotations anchored to screenshot content when the
                // background canvas expands/contracts to match selected ratio.
                let oldRatio = aspectRatioValue(for: oldID)
                let newRatio = aspectRatioValue(for: newID)
                let oldOrigin = screenshotOriginInTemplatedCanvas(for: rawImage, padding: editorPadding, aspectRatio: oldRatio)
                let newOrigin = screenshotOriginInTemplatedCanvas(for: rawImage, padding: editorPadding, aspectRatio: newRatio)
                shiftAnnotations(by: CGPoint(x: newOrigin.x - oldOrigin.x, y: newOrigin.y - oldOrigin.y))
                applyDisplayImage(from: rawImage)
            }
        }
        .onChange(of: editorCornerRadius) { _, newValue in
            appSettings?.screenshotTemplate.cornerRadius = newValue
            if selectedGradient != nil, let rawImage {
                applyDisplayImage(from: rawImage)
            }
        }
        .onChange(of: selectedAnnotationID) { _, newID in
            if let id = newID,
               let ann = annotations.first(where: { $0.id == id }) {
                currentStyle = ann.style
            }
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
                .focusable(false)
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
                .focusable(false)
                .help("Zoom In")

                Button {
                    zoomLevel = 1.0
                } label: {
                    Text("Fit")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("Reset Zoom")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.clear)
    }

    // MARK: - Zoom

    private func updateFitScale(viewSize: CGSize) {
        guard imagePixelSize.width > 0, imagePixelSize.height > 0 else { return }
        // Content in the scroll view adds:
        // - top clear space for floating toolbar
        // - outer canvas padding
        let horizontalChrome: CGFloat = 40  // 20pt left + 20pt right
        let verticalChrome: CGFloat = 100   // 60pt top clearance + 20pt top + 20pt bottom
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

        var displayCG = cgSource
        if let gradient = selectedGradient, let template {
            // Build a template with the current editor slider values and selected gradient
            var editorTemplate = template
            editorTemplate.padding = editorPadding
            editorTemplate.cornerRadius = editorCornerRadius
            editorTemplate.wallpaperSource = .builtInGradient(gradient)
            let renderer = TemplateRenderer()
            if let templated = try? renderer.applyTemplate(
                editorTemplate,
                to: cgSource,
                backingScale: displayBackingScale,
                targetAspectRatio: selectedEditorAspectRatio?.ratio
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
        // Check if the crop rect is already the full image — nothing to do
        let fullRect = CGRect(origin: .zero, size: imagePixelSize)
        guard cropRect != fullRect,
              !cropRect.isEmpty,
              let cgImage = currentCGImage()
        else {
            isCropping = false
            currentTool = .select
            return
        }

        // Clamp the crop rect to actual image bounds
        let clampedCrop = cropRect.intersection(CGRect(x: 0, y: 0,
                                                       width: CGFloat(cgImage.width),
                                                       height: CGFloat(cgImage.height)))
        guard !clampedCrop.isEmpty,
              let croppedCGImage = cgImage.cropping(to: clampedCrop)
        else {
            isCropping = false
            currentTool = .select
            return
        }

        pushUndo()

        // Update the displayed image
        let newSize = NSSize(width: croppedCGImage.width, height: croppedCGImage.height)
        let newNSImage = NSImage(size: newSize)
        newNSImage.addRepresentation(NSBitmapImageRep(cgImage: croppedCGImage))
        image = newNSImage
        currentDisplayCGImage = croppedCGImage
        imagePixelSize = CGSize(width: croppedCGImage.width, height: croppedCGImage.height)

        // Shift all annotations so their coordinates are relative to the new top-left
        let originX = clampedCrop.minX
        let originY = clampedCrop.minY
        annotations = annotations.map { ann in
            var shifted = ann
            shifted.startPoint = CGPoint(x: ann.startPoint.x - originX,
                                         y: ann.startPoint.y - originY)
            shifted.endPoint = CGPoint(x: ann.endPoint.x - originX,
                                       y: ann.endPoint.y - originY)
            if !ann.points.isEmpty {
                shifted.points = ann.points.map {
                    CGPoint(x: $0.x - originX, y: $0.y - originY)
                }
            }
            return shifted
        }

        // Reset crop rect to full new image
        cropRect = CGRect(origin: .zero, size: imagePixelSize)

        isCropping = false
        currentTool = .select
    }

    private func cancelCrop() {
        cropRect = CGRect(origin: .zero, size: imagePixelSize)
        isCropping = false
        currentTool = .select
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
    private func screenshotOriginInTemplatedCanvas(for source: NSImage, padding: Int, aspectRatio: Double?) -> CGPoint {
        guard let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return .zero
        }

        let screenshotW = CGFloat(cg.width)
        let screenshotH = CGFloat(cg.height)
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

        return CGPoint(
            x: (canvasW - screenshotW) / 2,
            y: (canvasH - screenshotH) / 2
        )
    }

    private func aspectRatioValue(for id: UUID?) -> Double? {
        guard let id else { return nil }
        return editorAspectRatios.first(where: { $0.id == id })?.ratio
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

    // MARK: - Undo

    private func pushUndo() {
        undoStack.append(EditorSnapshot(
            annotations: annotations,
            image: image,
            imagePixelSize: imagePixelSize,
            cropRect: cropRect
        ))
    }

    private func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        annotations = snapshot.annotations
        if let snapImage = snapshot.image {
            image = snapImage
            imagePixelSize = snapshot.imagePixelSize
            // Re-extract the CGImage from the snapshot's bitmap representation
            // so currentDisplayCGImage stays consistent with the restored image.
            currentDisplayCGImage = (snapImage.representations.first as? NSBitmapImageRep)?.cgImage
                ?? snapImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        cropRect = snapshot.cropRect ?? CGRect(origin: .zero, size: imagePixelSize)
        selectedAnnotationID = nil
    }

    // MARK: - Save

    /// Returns the current CGImage for rendering/export, using the stored reference
    /// to avoid re-scaling via NSImage.cgImage(forProposedRect:).
    private func currentCGImage() -> CGImage? {
        if let cg = currentDisplayCGImage { return cg }
        return image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    private func copyToClipboard() {
        guard let cgImage = currentCGImage() else { return }

        let renderer = AnnotationRenderer()
        guard let outputImage = try? renderer.render(image: cgImage, annotations: annotations, backingScale: displayBackingScale, cropRect: nil)
        else { return }

        let size = NSSize(width: outputImage.width, height: outputImage.height)
        let finalImage = NSImage(size: size)
        finalImage.addRepresentation(NSBitmapImageRep(cgImage: outputImage))

        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([finalImage])
        onDismiss()
    }

    private func saveOverwrite() {
        do {
            try exportAndSave(to: imageURL)
            onDismiss()
        } catch {
            showSaveError(error)
        }
    }

    private func saveAs() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = imageURL.lastPathComponent
        let ext = imageURL.pathExtension.lowercased()
        let contentType: UTType = ext == "png" ? .png : ext == "heic" ? .heic : .jpeg
        panel.allowedContentTypes = [contentType]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try exportAndSave(to: url)
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
            cropRect: nil
        )

        let ext = url.pathExtension.lowercased()
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

    private func showSaveError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Save Failed"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}
