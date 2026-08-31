import SwiftUI
import PDFKit

// MARK: - Drag Mode

/// Describes what part of a selected annotation is being dragged.
enum DragMode: Equatable {
    case body                      // move entire annotation
    case startHandle               // move startPoint only (arrow/line)
    case endHandle                 // move endPoint only (arrow/line)
    case midHandle                 // bend the arrow shaft (curved/double arrows)
    case vertexHandle              // move the angle tool's corner point (points[0])
    case corner(minXFixed: Bool, minYFixed: Bool)  // resize rectangle via one corner
    case textLeftEdge              // resize text bubble from the left
    case textRightEdge             // resize text bubble from the right
}

/// The handle tap radius in image-pixel units used for hit testing.
private let handleHitRadius: CGFloat = 12

/// The corner inset from the bounding-rect edge that counts as a "corner handle" hit.
private let cornerHitInset: CGFloat = 16

// MARK: - Canvas View

/// The interactive canvas that displays the screenshot with annotations.
/// Handles gesture input for creating and manipulating annotations.
///
/// `scale` is passed in from the parent (EditorView) — it represents
/// view-points per image-pixel and incorporates both fit-to-view and zoom.
struct EditorCanvasView: View {
    let image: NSImage
    let imagePixelSize: CGSize  // actual CGImage pixel dimensions
    let scale: CGFloat          // view-points per image-pixel (from parent)
    let displayBackingScale: CGFloat  // monitor backing scale (used in export rendering)
    var dpiScaleFactor: CGFloat = 1   // image pixel-density (2 for 144-DPI Retina); thickens annotation dims
    /// The active editor mode. Annotation interaction is gated to `.annotate` only.
    var editorMode: EditorMode = .annotate
    /// When set, the base layer renders the PDF page as vector content instead
    /// of a raster `Image(nsImage:)`. The `image` property is still used as
    /// `sourceImage` for pixelate annotations.
    var pdfPageSource: PDFPageSource? = nil
    /// In-document find highlights for the active PDF page: all matches on the
    /// page (tinted) and the current match (emphasized).
    var searchHighlights: [PDFSelection] = []
    var activeSearchHighlight: PDFSelection? = nil
    /// Link follow handlers for the active PDF page.
    var onOpenPDFURL: ((URL) -> Void)? = nil
    var onGoToPDFDestination: ((PDFDestination) -> Void)? = nil
    /// In single-page View mode, a wheel gesture past the page's scroll extent
    /// flips to the adjacent page (+1 next / −1 previous).
    var onFlipPDFPage: ((Int) -> Void)? = nil
    var shadowIntensity: Double = 0 // drop shadow opacity (0 = none, 1 = full)
    var showBorderOutline: Bool = false

    @Binding var annotations: [Annotation]
    @Binding var selectedAnnotationID: UUID?
    @Binding var currentTool: AnnotationTool
    @Binding var currentStyle: AnnotationStyle
    @Binding var cropRect: CGRect
    @Binding var isCropping: Bool
    /// The allowed crop area in image-pixel space. When a background gradient is
    /// active this is the screenshot content region; otherwise the full image.
    var cropBoundsRect: CGRect? = nil
    /// Locks the crop region to a fixed width/height ratio when non-nil.
    var cropAspectRatio: CGFloat? = nil
    /// Fine straighten angle (degrees) previewed live during crop mode by
    /// rotating the image + annotation layer; baked on Apply.
    var straightenDialAngle: Double = 0
    /// Whether the straightening grid should be shown (while actively adjusting).
    var showCropGrid: Bool = false

    var watermarkSettings: WatermarkSettings = WatermarkSettings()

    /// Called when the user finishes creating or modifying an annotation (for undo).
    var onCommit: () -> Void = {}
    /// Called when the user begins / ends a crop handle drag, so the grid shows.
    var onCropAdjustBegan: () -> Void = {}
    var onCropAdjustEnded: () -> Void = {}

    /// Annotation currently being drawn (not yet committed).
    @State private var pendingAnnotation: Annotation?
    /// For text editing
    @State private var editingTextID: UUID?
    @State private var editingText: String = ""
    /// True while editing a freshly-placed (never committed) text annotation.
    /// Drives undo bookkeeping in `commitTextEdit`: a new bubble must not leave
    /// an empty ghost annotation in the undo snapshot.
    @State private var editingTextIsNew: Bool = false
    /// Measured content size reported back by GrowingTextField
    @State private var editingContentSize: CGSize = .zero
    /// Drag state for moving / reshaping selected annotations
    @State private var isDraggingAnnotation: Bool = false
    /// Pre-drag snapshot of the annotation being moved/resized
    @State private var dragStartAnnotation: Annotation?
    /// Live-updated annotation during drag (local @State, avoids binding cascade)
    @State private var draggingAnnotation: Annotation?
    /// The image-space point where the drag started (for delta computation)
    @State private var dragStartImagePoint: CGPoint = .zero
    /// Which part of the annotation is being dragged
    @State private var dragMode: DragMode = .body
    /// Ensure we only push one undo snapshot per drag interaction.
    @State private var didCaptureUndoForCurrentDrag: Bool = false
    /// ID of the annotation currently being dragged — set once at drag start, cleared at drag end.
    /// Used in the committed annotations filter so it doesn't re-evaluate on every drag tick
    /// (unlike `draggingAnnotation?.id` which changes every frame as the struct updates).
    @State private var draggingAnnotationID: UUID?
    /// Whether the dragged annotation is snapped to the horizontal/vertical center of the image.
    @State private var snapH: Bool = false
    @State private var snapV: Bool = false

    /// Live Shift-key state, tracked via a `.flagsChanged` monitor. Reading
    /// `NSEvent.modifierFlags` directly inside a DragGesture's `onChanged` can
    /// return stale flags mid-drag (Option-duplicate works because it's read once
    /// at drag start; Shift-snap is read every frame), so angle/square locking
    /// silently stopped engaging. The monitor updates this on every press/release.
    @State private var isShiftKeyDown: Bool = false
    @State private var flagsMonitor: Any?

    private var canvasWidth: CGFloat { imagePixelSize.width * scale }
    private var canvasHeight: CGFloat { imagePixelSize.height * scale }

    /// Corner radius for the display-time "card" treatment — subtle rounded
    /// corners + drop shadow shown when no template background is applied,
    /// consistent across screenshots, images, and PDF pages (single or
    /// multiple). It's zero when a background is present, since the composed
    /// template image already carries its own corners; PDFs never take a
    /// background, so they always round. Display-only — the exported/raw image
    /// is unaffected.
    private var cardCornerRadius: CGFloat { showBorderOutline ? 6 : 0 }

    /// PDF text selection is active in View mode (always) and when the Text
    /// Selection tool is chosen in Annotate mode. Only PDF pages have a text
    /// layer, so it never applies to raster images.
    private var isTextSelectionActive: Bool {
        guard pdfPageSource != nil else { return false }
        return editorMode == .view || (editorMode == .annotate && currentTool == .textSelect)
    }

    /// Annotation drawing/selection gestures are attached only when actively
    /// marking up — Annotate mode with a drawing tool. On a PDF page the Text
    /// Selection tool suppresses them (and View mode never attaches them) so the
    /// page's backing NSView receives the mouse events it needs for selection.
    /// The Text Selection tool is PDF-only, so on a raster image gestures stay
    /// enabled even if `currentTool` is left on `.textSelect` after a switch.
    private var annotationGesturesEnabled: Bool {
        guard editorMode == .annotate else { return false }
        if pdfPageSource != nil && currentTool == .textSelect { return false }
        return true
    }

    /// Live straighten angle applied to the image + annotation layers. Only
    /// non-zero during crop mode (the dial resets on enter/apply/cancel).
    private var cropStraightenAngle: Double {
        isCropping ? straightenDialAngle : 0
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Base image + gesture layer combined (so gestures don't block other views)
            Group {
                if let page = pdfPageSource?.page {
                    // pointSize must be the page's own point size — the extent
                    // `page.draw(with: .mediaBox)` fills — NOT imagePixelSize /
                    // displayBackingScale. Non-active pages can be rasterized at a
                    // different backing scale (preload uses a lighter one), so
                    // deriving pointSize from imagePixelSize would mis-scale the
                    // live view and clip it to the lower-left corner.
                    PDFPageView(page: page,
                                pointSize: page.rotatedMediaBoxSize,
                                isTextSelectable: isTextSelectionActive,
                                searchHighlights: searchHighlights,
                                activeSearchHighlight: activeSearchHighlight,
                                onOpenURL: onOpenPDFURL,
                                onGoToDestination: onGoToPDFDestination,
                                paginatedScroll: editorMode == .view,
                                onFlipPage: onFlipPDFPage)
                    .frame(width: canvasWidth, height: canvasHeight)
                    .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 3)
                } else {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: canvasWidth, height: canvasHeight)
                        .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
                        .shadow(color: showBorderOutline ? .black.opacity(0.18) : .clear, radius: 10, x: 0, y: 3)
                }
            }
            .shadow(color: .black.opacity(0.5 * shadowIntensity), radius: 60 * shadowIntensity, x: 0, y: 28 * shadowIntensity)
            .overlay(
                Group {
                    if showBorderOutline {
                        RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                            .stroke(Color.primary.opacity(0.15), lineWidth: 1)
                    }
                }
                .allowsHitTesting(false)
            )
            .contentShape(Rectangle())
            // Canvas gestures attach only while actively marking up (see
            // `annotationGesturesEnabled`). When the Text Selection tool is
            // active, or in View mode, no SwiftUI gesture is installed on the
            // canvas, so the PDF page's backing NSView receives the mouse events
            // it needs for interactive text selection (see `_PDFPageNSView`).
            .gesture(annotationGesturesEnabled ? canvasGesture : nil)
            .gesture(annotationGesturesEnabled
                     ? SpatialTapGesture(count: 2).onEnded { handleDoubleTap(at: $0.location) }
                     : nil)
            .gesture(annotationGesturesEnabled
                     ? SpatialTapGesture(count: 1).onEnded { handleTap(at: $0.location) }
                     : nil)
            .onAppear {
                guard flagsMonitor == nil else { return }
                flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { event in
                    isShiftKeyDown = event.modifierFlags.contains(.shift)
                    return event
                }
            }
            .onDisappear {
                if let monitor = flagsMonitor {
                    NSEvent.removeMonitor(monitor)
                    flagsMonitor = nil
                }
            }
            // Live straighten preview — rotate the image about the canvas center.
            // Annotations get the identical rotation below so they stay glued.
            .rotationEffect(.degrees(cropStraightenAngle), anchor: .center)

            // Annotations clipped to image bounds
            ZStack(alignment: .topLeading) {
                // Committed annotations — isolated into a subview so it doesn't
                // re-evaluate on every drag tick (draggingAnnotation changes every frame,
                // but draggingAnnotationID is stable throughout a single drag).
                CommittedAnnotationsView(
                    annotations: annotations,
                    excludeEditingID: editingTextID,
                    excludeDraggingID: draggingAnnotationID,
                    selectedAnnotationID: isDraggingAnnotation ? nil : selectedAnnotationID,
                    scale: scale,
                    displayBackingScale: displayBackingScale,
                    dpiScaleFactor: dpiScaleFactor,
                    sourceImage: image,
                    imagePixelSize: imagePixelSize
                )

                // Live drag proxy — only this view updates during drag (local @State).
                if let dragging = draggingAnnotation {
                    AnnotationOverlayView(
                        annotation: dragging,
                        scale: scale,
                        displayBackingScale: displayBackingScale,
                        dpiScaleFactor: dpiScaleFactor,
                        isSelected: false,
                        sourceImage: dragging.tool == .pixelate ? image : nil,
                        imagePixelSize: imagePixelSize
                    )
                    .allowsHitTesting(false)
                }

                // Pending annotation being drawn
                if let pending = pendingAnnotation {
                    AnnotationOverlayView(
                        annotation: pending,
                        scale: scale,
                        displayBackingScale: displayBackingScale,
                        dpiScaleFactor: dpiScaleFactor,
                        isSelected: false,
                        sourceImage: pending.tool == .pixelate ? image : nil,
                        imagePixelSize: imagePixelSize
                    )
                    .allowsHitTesting(false)
                }
            }
            .frame(width: canvasWidth, height: canvasHeight)
            .clipped()
            .allowsHitTesting(false)
            // Match the base image's straighten rotation so annotations stay glued.
            .rotationEffect(.degrees(cropStraightenAngle), anchor: .center)

            // Snap alignment guides shown during drag
            if isDraggingAnnotation {
                snapGuideLines
            }

            // Inline text editing styled to match the final pill appearance
            if let editID = editingTextID,
               let idx = annotations.firstIndex(where: { $0.id == editID }) {
                let ann = annotations[idx]
                let scaledFontSize = ann.style.fontSize * scale
                let hPad = scaledFontSize * 0.55
                let pos = CGPoint(
                    x: ann.startPoint.x * scale,
                    y: ann.startPoint.y * scale
                )
                let fixedInnerW: CGFloat? = ann.textWidth.map { $0 * scale - hPad * 2 }
                let contentW = fixedInnerW ?? max(editingContentSize.width, scaledFontSize * 2)
                let contentH = max(editingContentSize.height, scaledFontSize * 1.2)
                GrowingTextField(
                    text: $editingText,
                    fontSize: scaledFontSize,
                    textColor: NSColor(ann.style.textBubbleForeground),
                    onSizeChange: { editingContentSize = $0 }
                )
                .frame(width: contentW, height: contentH)
                .padding(.horizontal, hPad)
                .padding(.vertical, scaledFontSize * 0.25)
                .background(
                    RoundedRectangle(cornerRadius: scaledFontSize * 0.45, style: .continuous)
                        .fill(ann.style.textBubbleBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: scaledFontSize * 0.45, style: .continuous)
                        .stroke(.white, lineWidth: 2)
                )
                .padding(2)
                .overlay(
                    RoundedRectangle(cornerRadius: scaledFontSize * 0.45, style: .continuous)
                        .stroke(ann.style.textBubbleBackground, lineWidth: 2)
                )
                .position(x: pos.x, y: pos.y)
            }

            // Watermark preview — non-interactive, mirrors export placement
            watermarkPreviewOverlay

            // Crop overlay — on top, handles its own gestures
            if isCropping {
                CropOverlayView(
                    cropRect: $cropRect,
                    scale: scale,
                    cropBoundsRect: cropBoundsRect ?? CGRect(origin: .zero, size: imagePixelSize),
                    aspectRatio: cropAspectRatio,
                    straightenAngle: straightenDialAngle,
                    showGrid: showCropGrid,
                    onAdjustBegan: onCropAdjustBegan,
                    onAdjustEnded: onCropAdjustEnded
                )
                .frame(width: canvasWidth, height: canvasHeight, alignment: .topLeading)
            }
        }
        .frame(width: canvasWidth, height: canvasHeight)
    }

    // MARK: - Watermark Preview

    @ViewBuilder
    private var watermarkPreviewOverlay: some View {
        if watermarkSettings.isEnabled, let path = watermarkSettings.imagePath {
            WatermarkPreview(
                path: path,
                settings: watermarkSettings,
                scale: scale,
                displayBackingScale: displayBackingScale,
                canvasWidth: canvasWidth,
                canvasHeight: canvasHeight
            )
        }
    }

    // MARK: - Snap Guides

    @ViewBuilder
    private var snapGuideLines: some View {
        if snapH {
            Path { p in
                p.move(to: CGPoint(x: canvasWidth / 2, y: 0))
                p.addLine(to: CGPoint(x: canvasWidth / 2, y: canvasHeight))
            }
            .stroke(Color.accentColor.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            .allowsHitTesting(false)
        }
        if snapV {
            Path { p in
                p.move(to: CGPoint(x: 0, y: canvasHeight / 2))
                p.addLine(to: CGPoint(x: canvasWidth, y: canvasHeight / 2))
            }
            .stroke(Color.accentColor.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            .allowsHitTesting(false)
        }
    }

    // MARK: - Gestures

    private var canvasGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                // Don't handle gestures while editing text or cropping
                if editingTextID != nil { return }
                if currentTool == .crop { return }

                let startInImage = viewToImage(value.startLocation)
                let currentInImage = viewToImage(value.location)

                // On first drag frame, decide: move existing annotation or draw new?
                if pendingAnnotation == nil && !isDraggingAnnotation {
                    let (hitID, mode) = hitTestWithMode(startInImage)
                    if let hitID {
                        if let idx = annotations.firstIndex(where: { $0.id == hitID }) {
                            // Option+drag on body → duplicate: leave original in place, drag a new copy
                            if mode == .body && NSEvent.modifierFlags.contains(.option) {
                                var duplicate = annotations[idx]
                                duplicate = Annotation(
                                    tool: duplicate.tool,
                                    startPoint: duplicate.startPoint,
                                    endPoint: duplicate.endPoint,
                                    points: duplicate.points,
                                    curvature: duplicate.curvature,
                                    style: duplicate.style,
                                    text: duplicate.text,
                                    textWidth: duplicate.textWidth,
                                    stepNumber: duplicate.stepNumber
                                )
                                onCommit()
                                annotations.append(duplicate)
                                selectedAnnotationID = duplicate.id
                                isDraggingAnnotation = true
                                draggingAnnotationID = duplicate.id
                                dragStartAnnotation = duplicate
                                draggingAnnotation = duplicate
                            } else {
                                selectedAnnotationID = hitID
                                isDraggingAnnotation = true
                                draggingAnnotationID = hitID
                                dragStartAnnotation = annotations[idx]
                                draggingAnnotation = annotations[idx]
                            }
                            dragStartImagePoint = startInImage
                            dragMode = mode
                            didCaptureUndoForCurrentDrag = false
                        }
                        applyDragDelta(currentInImage)
                        return
                    }
                    // Nothing hit — start drawing (only if not select/text/numberedStep)
                    if currentTool != .select && currentTool != .text && currentTool != .numberedStep {
                        if currentTool == .freeDraw {
                            pendingAnnotation = Annotation(
                                tool: currentTool,
                                startPoint: startInImage,
                                endPoint: currentInImage,
                                points: [startInImage, currentInImage],
                                style: currentStyle
                            )
                        } else {
                            pendingAnnotation = Annotation(
                                tool: currentTool,
                                startPoint: startInImage,
                                endPoint: currentInImage,
                                // Angle tool: vertex starts at the drag midpoint
                                // (a flat 180°); the user bends it afterwards.
                                points: currentTool == .angle
                                    ? [CGPoint(x: (startInImage.x + currentInImage.x) / 2,
                                               y: (startInImage.y + currentInImage.y) / 2)]
                                    : [],
                                style: currentStyle
                            )
                        }
                    }
                    return
                }

                // Continue an in-progress drag or draw
                if isDraggingAnnotation {
                    applyDragDelta(currentInImage)
                } else if pendingAnnotation != nil {
                    let tool = pendingAnnotation?.tool
                    if tool == .freeDraw {
                        if let last = pendingAnnotation?.points.last {
                            // Reduce jitter by only storing points that moved enough.
                            if dist(last, currentInImage) >= 2.0 {
                                pendingAnnotation?.points.append(currentInImage)
                            }
                        } else {
                            pendingAnnotation?.points.append(currentInImage)
                        }
                        pendingAnnotation?.endPoint = pendingAnnotation?.points.last ?? currentInImage
                    } else if isAngleLockTool(tool) || tool == .angle,
                              isShiftDown,
                              let start = pendingAnnotation?.startPoint {
                        pendingAnnotation?.endPoint = constrainTo45Degree(start: start, end: currentInImage)
                    } else if isShiftDown && (tool == .rectangle || tool == .circle || tool == .triangle || tool == .star || tool == .spotlight),
                       let start = pendingAnnotation?.startPoint {
                        pendingAnnotation?.endPoint = constrainToSquare(start: start, end: currentInImage)
                    } else {
                        pendingAnnotation?.endPoint = currentInImage
                    }
                    // Angle tool: keep the vertex at the midpoint while the
                    // outer points are being placed.
                    if tool == .angle, let pa = pendingAnnotation {
                        pendingAnnotation?.points = [CGPoint(x: (pa.startPoint.x + pa.endPoint.x) / 2,
                                                             y: (pa.startPoint.y + pa.endPoint.y) / 2)]
                    }
                }
            }
            .onEnded { _ in
                if editingTextID != nil { return }
                if currentTool == .crop { return }

                if isDraggingAnnotation {
                    finishSelectDrag()
                } else if pendingAnnotation != nil, currentTool != .text {
                    // Commit the pending annotation
                    if let annotation = pendingAnnotation {
                        onCommit()
                        annotations.append(annotation)
                        selectedAnnotationID = annotation.id
                    }
                    pendingAnnotation = nil
                } else {
                    pendingAnnotation = nil
                }
            }
    }

    private func handleTap(at location: CGPoint) {
        // If we're editing text, commit and switch to select so we
        // don't immediately place a new text bubble on the same click.
        if editingTextID != nil {
            commitTextEdit()
            currentTool = .select
            return
        }

        let pointInImage = viewToImage(location)

        // Text tool: place new text
        if currentTool == .text {
            // But if tapping on an existing text annotation, edit it instead
            if let hitID = hitTestBody(pointInImage),
               let ann = annotations.first(where: { $0.id == hitID }),
               ann.tool == .text {
                beginTextEdit(id: hitID, text: ann.text)
                return
            }
            placeText(at: pointInImage)
            return
        }

        // Numbered step tool: place new step
        if currentTool == .numberedStep {
            placeNumberedStep(at: pointInImage)
            return
        }

        // Any tool: tap on annotation to select it
        if let hitID = hitTestBody(pointInImage) {
            selectedAnnotationID = hitID
        } else {
            selectedAnnotationID = nil
        }
    }

    // MARK: - Drag Application

    /// Snap threshold in image-pixel units.
    private var snapThreshold: CGFloat { 6.0 / scale }

    /// Apply the current drag delta to the local drag proxy (avoids mutating the binding).
    private func applyDragDelta(_ currentInImage: CGPoint) {
        guard var ann = dragStartAnnotation else { return }

        if !didCaptureUndoForCurrentDrag {
            onCommit()
            didCaptureUndoForCurrentDrag = true
        }

        var dx = currentInImage.x - dragStartImagePoint.x
        var dy = currentInImage.y - dragStartImagePoint.y

        if isShiftDown && dragMode == .body {
            if abs(dx) >= abs(dy) { dy = 0 } else { dx = 0 }
        }

        switch dragMode {
        case .body:
            ann.startPoint = CGPoint(x: ann.startPoint.x + dx,
                                     y: ann.startPoint.y + dy)
            ann.endPoint   = CGPoint(x: ann.endPoint.x + dx,
                                     y: ann.endPoint.y + dy)
            if !ann.points.isEmpty {   // freeDraw stroke / angle vertex
                ann.points = ann.points.map {
                    CGPoint(x: $0.x + dx, y: $0.y + dy)
                }
            }

            let centerX = imagePixelSize.width / 2
            let centerY = imagePixelSize.height / 2
            let annCenter = CGPoint(
                x: (ann.boundingRect.midX),
                y: (ann.boundingRect.midY)
            )

            var snapDx: CGFloat = 0
            var snapDy: CGFloat = 0
            let didSnapH = abs(annCenter.x - centerX) < snapThreshold
            let didSnapV = abs(annCenter.y - centerY) < snapThreshold

            if didSnapH { snapDx = centerX - annCenter.x }
            if didSnapV { snapDy = centerY - annCenter.y }

            if snapDx != 0 || snapDy != 0 {
                ann.startPoint.x += snapDx
                ann.startPoint.y += snapDy
                ann.endPoint.x += snapDx
                ann.endPoint.y += snapDy
                if !ann.points.isEmpty {   // freeDraw stroke / angle vertex
                    ann.points = ann.points.map {
                        CGPoint(x: $0.x + snapDx, y: $0.y + snapDy)
                    }
                }
            }

            snapH = didSnapH
            snapV = didSnapV

        case .startHandle:
            let newStart = CGPoint(x: ann.startPoint.x + dx,
                                   y: ann.startPoint.y + dy)
            if ann.tool == .angle, isShiftDown {
                // Snap the measured angle to 45° steps (rotate about the vertex).
                ann.startPoint = AngleGeometry.snapOuterPoint(newStart, vertex: ann.angleVertex, other: ann.endPoint)
            } else if isAngleLockTool(ann.tool), isShiftDown {
                ann.startPoint = constrainTo45Degree(start: ann.endPoint, end: newStart)
            } else {
                ann.startPoint = newStart
            }
            snapH = false
            snapV = false

        case .endHandle:
            let newEnd = CGPoint(x: ann.endPoint.x + dx,
                                 y: ann.endPoint.y + dy)
            if ann.tool == .angle, isShiftDown {
                ann.endPoint = AngleGeometry.snapOuterPoint(newEnd, vertex: ann.angleVertex, other: ann.startPoint)
            } else if isAngleLockTool(ann.tool), isShiftDown {
                ann.endPoint = constrainTo45Degree(start: ann.startPoint, end: newEnd)
            } else {
                ann.endPoint = newEnd
            }
            snapH = false
            snapV = false

        case .vertexHandle:
            let origVertex = ann.angleVertex
            var newVertex = CGPoint(x: origVertex.x + dx, y: origVertex.y + dy)
            if isShiftDown {
                // Snap the measured angle to 45° steps (project onto the
                // inscribed-angle circle for the nearest target).
                newVertex = AngleGeometry.snapVertex(newVertex, a: ann.startPoint, b: ann.endPoint)
            }
            ann.points = [newVertex]
            snapH = false
            snapV = false

        case .midHandle:
            // Keep the curve's midpoint under the cursor: solve for the
            // local-frame curvature whose B(0.5) is the dragged point.
            let origMid = ann.arrowMidPoint
            let newMid = CGPoint(x: origMid.x + dx, y: origMid.y + dy)
            var curv = ArrowGeometry.curvature(start: ann.startPoint, end: ann.endPoint,
                                               passingThrough: newMid)
            // Snap back to perfectly straight when the bow is nearly flat.
            let length = dist(ann.startPoint, ann.endPoint)
            if abs(curv.dy) * length < snapThreshold {
                curv = CGVector(dx: 0.5, dy: 0)
            }
            ann.curvature = curv
            snapH = false
            snapV = false

        case .corner(let minXFixed, let minYFixed):
            let origRect = ann.boundingRect
            let draggedX = minXFixed ? origRect.maxX + dx : origRect.minX + dx
            let draggedY = minYFixed ? origRect.maxY + dy : origRect.minY + dy
            let fixedX = minXFixed ? origRect.minX : origRect.maxX
            let fixedY = minYFixed ? origRect.minY : origRect.maxY
            ann.startPoint = CGPoint(x: min(fixedX, draggedX),
                                     y: min(fixedY, draggedY))
            ann.endPoint   = CGPoint(x: max(fixedX, draggedX),
                                     y: max(fixedY, draggedY))
            snapH = false
            snapV = false

        case .textLeftEdge:
            let currentWidth = textBubbleWidth(for: ann)
            let minWidth = ann.style.fontSize * 2
            let newWidth = max(minWidth, currentWidth - dx * 2)
            ann.textWidth = newWidth
            snapH = false
            snapV = false

        case .textRightEdge:
            let currentWidth = textBubbleWidth(for: ann)
            let minWidth = ann.style.fontSize * 2
            let newWidth = max(minWidth, currentWidth + dx * 2)
            ann.textWidth = newWidth
            snapH = false
            snapV = false
        }

        draggingAnnotation = ann
    }

    private func finishSelectDrag() {
        // Commit the drag proxy back to the annotations array (single write)
        if let final = draggingAnnotation,
           let idx = annotations.firstIndex(where: { $0.id == final.id }) {
            annotations[idx] = final
        }
        isDraggingAnnotation = false
        draggingAnnotationID = nil
        dragStartAnnotation = nil
        draggingAnnotation = nil
        dragStartImagePoint = .zero
        dragMode = .body
        didCaptureUndoForCurrentDrag = false
        snapH = false
        snapV = false
    }

    // MARK: - Text Tool

    /// Default badge size (points) for a newly placed numbered step.
    private static let numberedStepDefaultFontSize: CGFloat = 40

    private func placeText(at point: CGPoint) {
        let annotation = Annotation(
            tool: .text,
            startPoint: point,
            endPoint: point,
            style: currentStyle,
            text: ""
        )
        annotations.append(annotation)
        selectedAnnotationID = annotation.id
        editingTextID = annotation.id
        editingTextIsNew = true
        editingText = ""
        editingContentSize = .zero
    }

    // MARK: - Numbered Step Tool

    private func placeNumberedStep(at point: CGPoint) {
        let nextNumber = (annotations.filter { $0.tool == .numberedStep }.map(\.stepNumber).max() ?? 0) + 1
        // Numbered badges use a dedicated default size, independent of the text
        // font, and are NOT DPI-scaled (the size shown in the size picker is the
        // literal stored value).
        var style = currentStyle
        style.fontSize = Self.numberedStepDefaultFontSize
        let annotation = Annotation(
            tool: .numberedStep,
            startPoint: point,
            endPoint: point,
            style: style,
            stepNumber: nextNumber
        )
        onCommit()
        annotations.append(annotation)
        selectedAnnotationID = annotation.id
    }

    private func commitTextEdit() {
        guard let editID = editingTextID,
              let idx = annotations.firstIndex(where: { $0.id == editID }) else {
            editingTextID = nil
            editingTextIsNew = false
            return
        }

        if editingText.isEmpty {
            if editingTextIsNew {
                // The empty bubble was never committed — drop it without an
                // undo entry, so undo can't resurrect an invisible annotation.
                annotations.remove(at: idx)
            } else {
                onCommit()
                annotations.remove(at: idx)
            }
            selectedAnnotationID = nil
        } else if editingTextIsNew {
            // Snapshot the state *without* the pending bubble so a single undo
            // removes the whole annotation instead of leaving an empty ghost.
            var ann = annotations.remove(at: idx)
            onCommit()
            ann.text = editingText
            annotations.insert(ann, at: idx)
        } else {
            onCommit()
            annotations[idx].text = editingText
        }
        editingTextID = nil
        editingTextIsNew = false
        editingContentSize = .zero
    }

    /// Begin inline editing of an existing text annotation.
    private func beginTextEdit(id: UUID, text: String) {
        selectedAnnotationID = id
        editingTextID = id
        editingTextIsNew = false
        editingText = text
        // Pre-compute the content size from the existing text so the bubble
        // shows at the correct size immediately (no zero-size flash).
        if let ann = annotations.first(where: { $0.id == id }) {
            editingContentSize = measureTextContentSize(text: text, fontSize: ann.style.fontSize * scale)
        } else {
            editingContentSize = .zero
        }
    }

    /// Measures the natural (unwrapped) size of `text` rendered with the given font size.
    private func measureTextContentSize(text: String, fontSize: CGFloat) -> CGSize {
        guard !text.isEmpty else { return .zero }
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let lines = text.components(separatedBy: "\n")
        let maxW = lines.map { line -> CGFloat in
            (line.isEmpty ? " " : line as NSString).size(withAttributes: attrs).width
        }.max() ?? 0
        let lineH = font.ascender + abs(font.descender)
        return CGSize(width: ceil(maxW), height: ceil(CGFloat(lines.count) * lineH))
    }

    /// Double-tap on a text annotation to edit it.
    private func handleDoubleTap(at location: CGPoint) {
        if editingTextID != nil {
            commitTextEdit()
            return
        }
        let pointInImage = viewToImage(location)
        if let hitID = hitTestBody(pointInImage),
           let ann = annotations.first(where: { $0.id == hitID }),
           ann.tool == .text {
            beginTextEdit(id: hitID, text: ann.text)
        }
    }

    // MARK: - Hit Testing

    /// Full hit-test: tries handles of the currently selected annotation first,
    /// then falls back to body hit-testing.
    /// Returns the annotation ID that was hit, plus the drag mode to use.
    private func hitTestWithMode(_ point: CGPoint) -> (UUID?, DragMode) {
        // If an annotation is already selected, check its handles first
        if let selID = selectedAnnotationID,
           let ann = annotations.first(where: { $0.id == selID }) {
            if let mode = hitTestHandles(point, annotation: ann) {
                return (selID, mode)
            }
        }
        // Fall back to body hit-test
        if let id = hitTestBody(point) {
            return (id, .body)
        }
        return (nil, .body)
    }

    /// Returns the DragMode if the point hits a handle of the given annotation, or nil.
    private func hitTestHandles(_ point: CGPoint, annotation: Annotation) -> DragMode? {
        // Radius in image pixels (convert handle visual size to image coords)
        let r = handleHitRadius / scale

        switch annotation.tool {
        case .arrow, .line, .measurement:
            if dist(point, annotation.startPoint) < r { return .startHandle }
            if dist(point, annotation.endPoint)   < r { return .endHandle }
            if annotation.tool == .arrow, annotation.style.arrowStyle.supportsCurvature,
               dist(point, annotation.arrowMidPoint) < r {
                return .midHandle
            }
            return nil

        case .angle:
            if dist(point, annotation.startPoint)  < r { return .startHandle }
            if dist(point, annotation.endPoint)    < r { return .endHandle }
            if dist(point, annotation.angleVertex) < r { return .vertexHandle }
            return nil

        case .rectangle, .circle, .triangle, .star, .pixelate, .spotlight:
            let rect = annotation.boundingRect
            let inset = cornerHitInset / scale
            let corners: [(CGPoint, DragMode)] = [
                (CGPoint(x: rect.minX, y: rect.minY), .corner(minXFixed: false, minYFixed: false)),
                (CGPoint(x: rect.maxX, y: rect.minY), .corner(minXFixed: true,  minYFixed: false)),
                (CGPoint(x: rect.minX, y: rect.maxY), .corner(minXFixed: false, minYFixed: true)),
                (CGPoint(x: rect.maxX, y: rect.maxY), .corner(minXFixed: true,  minYFixed: true)),
            ]
            for (corner, mode) in corners where dist(point, corner) < inset {
                return mode
            }
            return nil

        case .text:
            let bubbleWidth = textBubbleWidth(for: annotation)
            let halfW = bubbleWidth / 2
            let cx = annotation.startPoint.x
            let cy = annotation.startPoint.y
            let handleY = cy
            let leftHandle  = CGPoint(x: cx - halfW, y: handleY)
            let rightHandle = CGPoint(x: cx + halfW, y: handleY)
            if dist(point, leftHandle)  < r { return .textLeftEdge }
            if dist(point, rightHandle) < r { return .textRightEdge }
            return nil

        default:
            return nil
        }
    }

    /// The current bubble width in image pixels. Goes through
    /// `TextBubbleGeometry` so the hit test, the drawn handles
    /// (`AnnotationOverlayView.selectionHandles`) and the resize drag can't
    /// drift apart — see the warning on that type about measuring the natural
    /// width at the *displayed* font size.
    private func textBubbleWidth(for annotation: Annotation) -> CGFloat {
        TextBubbleGeometry.imageWidth(for: annotation, scale: scale)
    }

    /// Hit-test annotation bodies (ignores handles).
    private func hitTestBody(_ point: CGPoint) -> UUID? {
        for annotation in annotations.reversed() {
            let threshold: CGFloat = max(annotation.style.strokeWidth * 3, 10)

            switch annotation.tool {
            case .arrow, .line, .measurement:
                let hitDist: CGFloat
                if annotation.tool == .arrow && annotation.style.arrowStyle.supportsCurvature {
                    hitDist = distanceToQuadCurve(point: point,
                                                  start: annotation.startPoint,
                                                  control: annotation.arrowControlPoint,
                                                  end: annotation.endPoint)
                } else {
                    hitDist = distanceToSegment(point: point,
                                                start: annotation.startPoint,
                                                end: annotation.endPoint)
                }
                if hitDist < threshold {
                    return annotation.id
                }

            case .angle:
                let v = annotation.angleVertex
                if distanceToSegment(point: point, start: v, end: annotation.startPoint) < threshold
                    || distanceToSegment(point: point, start: v, end: annotation.endPoint) < threshold {
                    return annotation.id
                }

            case .freeDraw:
                if distanceToPolyline(point: point, points: annotation.points) < threshold {
                    return annotation.id
                }

            case .rectangle, .circle, .triangle, .star, .pixelate, .spotlight:
                let rect = annotation.boundingRect.insetBy(dx: -threshold, dy: -threshold)
                if rect.contains(point) {
                    return annotation.id
                }

            case .text:
                let fs = annotation.style.fontSize

                let vPad = fs * 0.25
                let bubbleW = textBubbleWidth(for: annotation)
                let lines = annotation.text.components(separatedBy: .newlines)
                let lineCount = max(lines.count, 1)
                let lineSpacing = fs * 0.22
                let estHeight = CGFloat(lineCount) * fs + CGFloat(max(0, lineCount - 1)) * lineSpacing + vPad * 2
                let textRect = CGRect(
                    x: annotation.startPoint.x - bubbleW / 2,
                    y: annotation.startPoint.y - estHeight / 2,
                    width: bubbleW,
                    height: estHeight
                )
                if textRect.contains(point) {
                    return annotation.id
                }

            case .numberedStep:
                let radius = annotation.style.fontSize * 0.7
                if hypot(point.x - annotation.startPoint.x, point.y - annotation.startPoint.y) < radius {
                    return annotation.id
                }

            case .select, .textSelect, .crop:
                break
            }
        }
        return nil
    }

    // MARK: - Geometry Helpers

    private func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    private func distanceToSegment(point: CGPoint, start: CGPoint, end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSq = dx * dx + dy * dy
        guard lengthSq > 0 else {
            return hypot(point.x - start.x, point.y - start.y)
        }
        let t = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSq))
        let proj = CGPoint(x: start.x + t * dx, y: start.y + t * dy)
        return hypot(point.x - proj.x, point.y - proj.y)
    }

    /// Samples a quadratic bezier (curved/double arrow shaft) and returns
    /// the minimum distance from `point` to any segment of the sampled polyline.
    private func distanceToQuadCurve(point: CGPoint, start: CGPoint, control cp: CGPoint, end: CGPoint) -> CGFloat {
        let steps = 20
        var best = CGFloat.greatestFiniteMagnitude
        var prev = start
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let mt = 1 - t
            let curr = CGPoint(x: mt * mt * start.x + 2 * mt * t * cp.x + t * t * end.x,
                               y: mt * mt * start.y + 2 * mt * t * cp.y + t * t * end.y)
            let d = distanceToSegment(point: point, start: prev, end: curr)
            if d < best { best = d }
            prev = curr
        }
        return best
    }

    private func distanceToPolyline(point: CGPoint, points: [CGPoint]) -> CGFloat {
        guard points.count >= 2 else {
            if let first = points.first {
                return hypot(point.x - first.x, point.y - first.y)
            }
            return .greatestFiniteMagnitude
        }

        var best = CGFloat.greatestFiniteMagnitude
        for i in 1..<points.count {
            let d = distanceToSegment(point: point, start: points[i - 1], end: points[i])
            if d < best { best = d }
        }
        return best
    }

    // MARK: - Coordinate Conversion

    private func viewToImage(_ viewPoint: CGPoint) -> CGPoint {
        CGPoint(x: viewPoint.x / scale, y: viewPoint.y / scale)
    }

    /// Constrain `end` so the bounding box from `start` is a perfect square,
    /// preserving the drag direction.
    private func constrainToSquare(start: CGPoint, end: CGPoint) -> CGPoint {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let side = max(abs(dx), abs(dy))
        return CGPoint(
            x: start.x + copysign(side, dx),
            y: start.y + copysign(side, dy)
        )
    }

    /// Constrain end point to nearest 45° direction from start, preserving drag length.
    private func constrainTo45Degree(start: CGPoint, end: CGPoint) -> CGPoint {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0 else { return start }

        let angle = atan2(dy, dx)
        let snap = (.pi / 4) * (angle / (.pi / 4)).rounded()
        return CGPoint(
            x: start.x + cos(snap) * length,
            y: start.y + sin(snap) * length
        )
    }

    private func isAngleLockTool(_ tool: AnnotationTool?) -> Bool {
        guard let tool else { return false }
        return tool == .measurement || tool == .arrow || tool == .line
    }

    private var isShiftDown: Bool {
        // Prefer the live monitor state (reliable mid-drag); fall back to the
        // static read in case a press happened before the monitor was installed.
        isShiftKeyDown || NSEvent.modifierFlags.contains(.shift)
    }

}

// MARK: - Watermark Preview

/// Live watermark preview that loads its image **off the main thread** (so a slow
/// or blocking path — e.g. on a removed/disconnected volume — never freezes the
/// editor) and holds the decoded image in `@State` so the constantly
/// re-evaluating canvas body doesn't redo the work. Placement mirrors the export.
private struct WatermarkPreview: View {
    let path: String
    let settings: WatermarkSettings
    let scale: CGFloat
    let displayBackingScale: CGFloat
    let canvasWidth: CGFloat
    let canvasHeight: CGFloat

    @State private var image: NSImage?

    var body: some View {
        // A concrete ZStack (not a Group) hosts the `.task`: modifiers on a Group
        // distribute to its children, so a `.task` on a conditionally-empty Group
        // never runs. `Color.clear` + an explicit canvas-sized frame keep the view
        // present (so the load fires) and give `.position` the canvas coordinate space.
        ZStack(alignment: .topLeading) {
            Color.clear
            if let image {
                let marginH = CGFloat(settings.edgeOffset) * scale
                let marginV = CGFloat(settings.bottomOffset) * scale
                // widthPx is in logical points; scale by zoom level for display.
                let targetW = max(1, CGFloat(settings.widthPx) * scale)
                let rawSize = image.size
                let aspect = rawSize.height > 0 ? rawSize.width / rawSize.height : 1.0
                let targetH = max(1, targetW / aspect)
                let pos = position(targetW: targetW, targetH: targetH, marginH: marginH, marginV: marginV)
                Image(nsImage: image)
                    .resizable()
                    .frame(width: targetW, height: targetH)
                    .opacity(settings.opacity)
                    .position(x: pos.x, y: pos.y)
            }
        }
        .frame(width: canvasWidth, height: canvasHeight)
        .allowsHitTesting(false)
        .task(id: path) {
            let loadPath = path
            let loaded = await Task.detached(priority: .userInitiated) {
                WatermarkImageCache.image(atPath: loadPath)
            }.value
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }

    private func position(targetW: CGFloat, targetH: CGFloat, marginH: CGFloat, marginV: CGFloat) -> CGPoint {
        switch settings.position {
        case .topLeft:
            return CGPoint(x: marginH + targetW / 2, y: marginV + targetH / 2)
        case .topRight:
            return CGPoint(x: canvasWidth - marginH - targetW / 2, y: marginV + targetH / 2)
        case .bottomLeft:
            return CGPoint(x: marginH + targetW / 2, y: canvasHeight - marginV - targetH / 2)
        case .bottomRight:
            return CGPoint(x: canvasWidth - marginH - targetW / 2, y: canvasHeight - marginV - targetH / 2)
        }
    }
}

// MARK: - PDF Page View (Vector Rendering)

/// Draws a `PDFPage` directly via Core Graphics so vector content stays sharp
/// at any zoom level. The view re-renders on every resize/display change.
private struct PDFPageView: NSViewRepresentable {
    let page: PDFPage
    let pointSize: CGSize
    /// When true (View mode), the backing view lets the user select and copy
    /// the page's text. Disabled in Annotate mode, where canvas drags draw
    /// annotations instead.
    var isTextSelectable: Bool = false
    /// Search-match selections on this page (drawn tinted) and the active match
    /// (emphasized) during an in-document find.
    var searchHighlights: [PDFSelection] = []
    var activeSearchHighlight: PDFSelection? = nil
    /// Link follow handlers (external URL / internal go-to destination).
    var onOpenURL: ((URL) -> Void)? = nil
    var onGoToDestination: ((PDFDestination) -> Void)? = nil
    /// When true (single-page View mode), wheel scrolling past the page's
    /// scroll extent flips pages rather than doing nothing.
    var paginatedScroll: Bool = false
    /// Flip to the adjacent page (+1 next / −1 previous).
    var onFlipPage: ((Int) -> Void)? = nil

    func makeNSView(context: Context) -> _PDFPageNSView {
        let v = _PDFPageNSView()
        v.page = page
        v.pdfPointSize = pointSize
        v.isTextSelectable = isTextSelectable
        v.searchHighlights = searchHighlights
        v.activeSearchHighlight = activeSearchHighlight
        v.onOpenURL = onOpenURL
        v.onGoToDestination = onGoToDestination
        v.paginatedScroll = paginatedScroll
        v.onFlipPage = onFlipPage
        return v
    }

    func updateNSView(_ v: _PDFPageNSView, context: Context) {
        // Drop any active selection when the displayed page changes (page or
        // session switch) so it can't linger onto unrelated content.
        if v.page !== page {
            v.clearSelection()
            v.window?.invalidateCursorRects(for: v) // rebuild link cursor rects
        }
        v.page = page
        v.pdfPointSize = pointSize
        v.isTextSelectable = isTextSelectable
        v.searchHighlights = searchHighlights
        v.activeSearchHighlight = activeSearchHighlight
        v.onOpenURL = onOpenURL
        v.onGoToDestination = onGoToDestination
        v.paginatedScroll = paginatedScroll
        v.onFlipPage = onFlipPage
        v.needsDisplay = true
    }
}

/// Backing NSView that draws a single PDF page into the current graphics
/// context. Because `draw(_:)` runs inside the window's display cycle,
/// the page is rasterized at the *current* backing-scale × view-transform,
/// keeping text and line art sharp regardless of zoom.
///
/// In View mode (`isTextSelectable`), it also supports native PDF text
/// selection (click-drag, double-click word, triple-click line) and copy
/// (⌘C or the right-click menu), reusing PDFKit's `PDFSelection`.
final class _PDFPageNSView: NSView {
    var page: PDFPage?
    var pdfPointSize: CGSize = .zero

    /// Enables interactive text selection + copy. Set from the SwiftUI layer
    /// (true only in View mode). Disabling clears any active selection.
    var isTextSelectable: Bool = false {
        didSet {
            guard oldValue != isTextSelectable else { return }
            if !isTextSelectable { clearSelection() }
            window?.invalidateCursorRects(for: self)
            updateTrackingAreas()
        }
    }

    /// The current text selection, in PDF page space — drawn as a highlight and
    /// used as the source for copy.
    private var selection: PDFSelection?
    /// Anchor point (PDF page space) for an in-progress click-drag selection.
    private var dragAnchor: CGPoint?

    /// True while this page has live selected text. `EditorView`'s key monitor
    /// checks it so the customizable Save & Copy shortcut (⌘C by default) yields
    /// to the text copy in `performKeyEquivalent` below.
    var hasTextSelection: Bool { selection?.string?.isEmpty == false }

    /// Search-match highlights for THIS page, set from the SwiftUI layer during
    /// an in-document find. All matches are tinted; the active one is emphasized.
    var searchHighlights: [PDFSelection] = [] { didSet { needsDisplay = true } }
    var activeSearchHighlight: PDFSelection? { didSet { needsDisplay = true } }

    /// Invoked when the user clicks a link annotation: an external URL or an
    /// internal go-to destination. Set from the SwiftUI layer.
    var onOpenURL: ((URL) -> Void)?
    var onGoToDestination: ((PDFDestination) -> Void)?

    /// Single-page View mode: when the page fits the viewport, wheel travel
    /// flips pages instead of doing nothing.
    var paginatedScroll: Bool = false
    var onFlipPage: ((Int) -> Void)?
    /// Accumulated wheel travel toward the next flip, and a per-gesture latch so
    /// one trackpad swipe flips at most one page.
    private var pageFlipAccumulator: CGFloat = 0
    private var pageFlipArmed = true

    /// Link under the cursor at mouse-down — a single click (no drag) follows it.
    private var mouseDownLink: PDFAnnotation?
    /// Whether the current mouse sequence dragged (→ a text selection, not a click).
    private var didDrag = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { isTextSelectable }

    /// Clears any active or in-progress selection and redraws.
    func clearSelection() {
        guard selection != nil || dragAnchor != nil else { return }
        selection = nil
        dragAnchor = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let page, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let bounds = self.bounds

        ctx.saveGState()
        ctx.setFillColor(CGColor.white)
        ctx.fill(bounds)

        // PDFPage.draw uses CG's default bottom-left origin. Because this
        // view is flipped (isFlipped = true), we undo the flip first; everything
        // below then works in y-up content space (0,0 … bounds.size).
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)

        // Render the page filling the view. Kept on PDFKit's own draw (with a
        // plain fit scale) so the visible page stays byte-identical to the
        // raster/thumbnail path. `page.draw` internally maps the media-box origin
        // and the page's /Rotate to the context — so the page itself is always
        // positioned correctly here.
        ctx.saveGState()
        let sx = bounds.width / pdfPointSize.width
        let sy = bounds.height / pdfPointSize.height
        ctx.scaleBy(x: sx, y: sy)
        page.draw(with: .mediaBox, to: ctx)
        ctx.restoreGState()

        // Highlights must use the SAME transform CoreGraphics uses to draw the
        // page — NOT the plain fit scale above. `selectionsByLine().bounds` are
        // in PDF page space (default user space), so a non-zero media-box origin
        // or a /Rotate would shift/rotate them off the glyphs if filled under the
        // fit scale (which ignores both). `getDrawingTransform` reproduces
        // `page.draw`'s placement exactly, so each line lands on its text.
        // Order: search matches underneath, the user's selection on top.
        let dt = pageDrawingTransform()
        let pageRect = page.bounds(for: .mediaBox)
        func fillSelection(_ sel: PDFSelection, _ color: CGColor) {
            ctx.setFillColor(color)
            for line in sel.selectionsByLine() {
                let r = line.bounds(for: page).intersection(pageRect)
                guard !r.isNull, r.width > 0, r.height > 0 else { continue }
                ctx.fill(r.applying(dt))
            }
        }
        for match in searchHighlights {
            fillSelection(match, NSColor.systemYellow.withAlphaComponent(0.35).cgColor)
        }
        if let activeSearchHighlight {
            fillSelection(activeSearchHighlight, NSColor.systemOrange.withAlphaComponent(0.55).cgColor)
        }
        if let selection {
            fillSelection(selection, NSColor.selectedTextBackgroundColor.withAlphaComponent(0.5).cgColor)
        }

        ctx.restoreGState()
    }

    /// The transform that maps this page's user space into the view's y-up
    /// content space (0,0 … bounds.size) — exactly what the render path
    /// (`scaleBy(sx, sy)` + `page.draw`) produces. It bakes in the page's
    /// `/Rotate` and a non-zero media-box origin, so highlights and the
    /// mouse→page-space mapping track the rendered glyphs at any zoom.
    private func pageDrawingTransform() -> CGAffineTransform {
        guard bounds.width > 0, bounds.height > 0,
              pdfPointSize.width > 0, pdfPointSize.height > 0 else { return .identity }
        // The zoom scale: page point size → the (possibly enlarged) view bounds.
        // Identical to the `sx`/`sy` the render path applies in `draw`.
        let scale = CGAffineTransform(scaleX: bounds.width / pdfPointSize.width,
                                      y: bounds.height / pdfPointSize.height)
        guard let cgPage = page?.pageRef else { return scale }
        // `getDrawingTransform` captures the media-box origin and /Rotate, but it
        // CLAMPS scale at 1.0 for a rect larger than the page (it centres the page
        // instead of scaling up). Calling it with `rect: bounds` therefore left
        // highlights/hit-testing at 1× — correct only at 100% zoom, off above it.
        // So ask it only for the scale-1 normalisation (rect == the page's own
        // point size, where it's exact) and apply our own zoom `scale` on top.
        let normalize = cgPage.getDrawingTransform(.mediaBox,
                                                   rect: CGRect(origin: .zero, size: pdfPointSize),
                                                   rotate: 0,
                                                   preserveAspectRatio: false)
        return normalize.concatenating(scale)
    }

    // MARK: - Text Selection

    /// Converts a mouse event location into PDF page space (points, bottom-left
    /// origin) — the space PDFKit's selection and annotation-hit APIs use.
    ///
    /// Inverts `pageDrawingTransform()` so the mapping accounts for a non-zero
    /// media-box origin and the page's /Rotate, matching exactly where the page
    /// renders. Without this, a click lands on different page-space coordinates
    /// than the glyph under the cursor and the selection appears off-target.
    private func pagePoint(for event: NSEvent) -> CGPoint {
        let v = convert(event.locationInWindow, from: nil) // flipped: top-left origin
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        // Into y-up content space, then invert the page-drawing transform.
        let contentPoint = CGPoint(x: v.x, y: bounds.height - v.y)
        let dt = pageDrawingTransform()
        guard dt.a * dt.d - dt.b * dt.c != 0 else { // non-invertible → fallback
            let nx = v.x / bounds.width
            let ny = v.y / bounds.height
            return CGPoint(x: nx * pdfPointSize.width,
                           y: (1 - ny) * pdfPointSize.height)
        }
        return contentPoint.applying(dt.inverted())
    }

    override func mouseDown(with event: NSEvent) {
        guard isTextSelectable, let page else {
            super.mouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)
        let p = pagePoint(for: event)
        didDrag = false
        // Only a single click can follow a link; double/triple click selects.
        mouseDownLink = event.clickCount == 1 ? linkAnnotation(at: p) : nil
        switch event.clickCount {
        case 2:  // double-click selects the word
            selection = page.selectionForWord(at: p)
            dragAnchor = nil
        case 3:  // triple-click selects the line
            selection = page.selectionForLine(at: p)
            dragAnchor = nil
        default: // single click starts a drag selection (and clears any prior one)
            dragAnchor = p
            selection = nil
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isTextSelectable, let page, let anchor = dragAnchor else {
            super.mouseDragged(with: event)
            return
        }
        didDrag = true
        selection = page.selection(from: anchor, to: pagePoint(for: event))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isTextSelectable else {
            super.mouseUp(with: event)
            return
        }
        dragAnchor = nil
        // A click (no drag) that began and ended on the same link follows it,
        // rather than leaving a stray selection.
        if !didDrag, let link = mouseDownLink,
           linkAnnotation(at: pagePoint(for: event)) === link {
            followLink(link)
            selection = nil
            needsDisplay = true
        }
        mouseDownLink = nil
    }

    /// Wheel scrolling. The page sits on top of the surrounding scroll view, so
    /// without this the cursor being over the page would swallow the gesture.
    ///
    /// - Normal (Annotate/Edit, or a zoomed-in page that still has room to
    ///   scroll): forward to the enclosing scroll view so it pans/scrolls.
    /// - Single-page View mode with the page fully fitting the viewport
    ///   (`paginatedScroll`): there's nothing to pan, so wheel travel flips to
    ///   the adjacent page — like a paged document viewer.
    override func scrollWheel(with event: NSEvent) {
        guard let scrollView = enclosingScrollView else {
            super.scrollWheel(with: event)
            return
        }

        // Pan whenever we're not paginating, or the page still overflows the
        // viewport (zoomed in) and can scroll further.
        let overflow = (scrollView.documentView?.bounds.height ?? 0)
            > scrollView.contentView.bounds.height + 1
        guard paginatedScroll, !overflow else {
            pageFlipAccumulator = 0
            scrollView.scrollWheel(with: event)
            return
        }

        // The page fits — translate wheel travel into page flips.
        let precise = event.hasPreciseScrollingDeltas
        if precise {
            if event.phase.contains(.began) {
                pageFlipArmed = true
                pageFlipAccumulator = 0
            }
            if !event.momentumPhase.isEmpty { return } // ignore trackpad inertia
        }

        pageFlipAccumulator += event.scrollingDeltaY
        let threshold: CGFloat = precise ? 40 : 1
        guard pageFlipArmed, abs(pageFlipAccumulator) >= threshold else { return }

        onFlipPage?(pageFlipAccumulator < 0 ? 1 : -1) // scroll down → next page
        pageFlipAccumulator = 0
        if precise { pageFlipArmed = false } // one flip per trackpad swipe
    }

    // MARK: - Links

    /// The link annotation at a page-space point, or nil.
    private func linkAnnotation(at point: CGPoint) -> PDFAnnotation? {
        guard let annotation = page?.annotation(at: point),
              annotation.type == "Link" else { return nil }
        return annotation
    }

    private func followLink(_ annotation: PDFAnnotation) {
        if let url = annotation.url ?? (annotation.action as? PDFActionURL)?.url {
            onOpenURL?(url)
        } else if let dest = annotation.destination ?? (annotation.action as? PDFActionGoTo)?.destination {
            onGoToDestination?(dest)
        }
    }

    private func linkURL(at point: CGPoint) -> URL? {
        guard let link = linkAnnotation(at: point) else { return nil }
        return link.url ?? (link.action as? PDFActionURL)?.url
    }

    // MARK: - Copy

    @objc func copy(_ sender: Any?) {
        guard let text = selection?.string, !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// Selects all text on the page (⌘A), so ⌘C then copies the whole page.
    override func selectAll(_ sender: Any?) {
        guard isTextSelectable, let page else { return }
        selection = page.selection(for: page.bounds(for: .mediaBox))
        dragAnchor = nil
        needsDisplay = true
    }

    /// Handles ⌘C / ⌘A on the page. `performKeyEquivalent` is dispatched through
    /// the whole view hierarchy, so this works even though the status-bar app has
    /// no standard Edit menu.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isTextSelectable,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
        else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers {
        case "c" where selection?.string?.isEmpty == false:
            copy(nil)
            return true
        case "a":
            selectAll(nil)
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard isTextSelectable else { return nil }
        let menu = NSMenu()
        if selection?.string?.isEmpty == false {
            menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        }
        menu.addItem(withTitle: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "")
        return menu
    }

    // MARK: - Cursor + Tooltip

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        guard isTextSelectable else { return }
        // Drives the link hover tooltip only — the cursor itself is handled by
        // cursor rects below (which cooperate with overlapping SwiftUI views).
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved],
            owner: self
        ))
    }

    /// Cursor *rects* (not `NSCursor.set`) so the cursor respects view stacking:
    /// SwiftUI views layered on top (e.g. the find bar) keep the normal arrow,
    /// while text shows the I-beam and links show the pointing hand.
    override func resetCursorRects() {
        guard isTextSelectable else { return }
        addCursorRect(bounds, cursor: .iBeam)
        if let page {
            for annotation in page.annotations where annotation.type == "Link" {
                addCursorRect(viewRect(forPageRect: annotation.bounds), cursor: .pointingHand)
            }
        }
    }

    /// Converts a page-space rect (PDF points, bottom-left origin) to view coords.
    private func viewRect(forPageRect r: CGRect) -> CGRect {
        guard pdfPointSize.width > 0, pdfPointSize.height > 0 else { return .zero }
        let kx = bounds.width / pdfPointSize.width
        let ky = bounds.height / pdfPointSize.height
        return CGRect(x: r.minX * kx,
                      y: bounds.height - r.maxY * ky,
                      width: r.width * kx,
                      height: r.height * ky)
    }

    override func mouseMoved(with event: NSEvent) {
        guard isTextSelectable else {
            super.mouseMoved(with: event)
            return
        }
        // Show the destination URL on hover (transparency before opening).
        toolTip = linkURL(at: pagePoint(for: event))?.absoluteString
    }
}

// MARK: - Growing Text Field

/// An NSTextView-backed input that grows horizontally as the user types and
/// only breaks to a new line on an explicit Return key press.
/// The content size is reported via `onSizeChange` so the parent can frame it.
private struct GrowingTextField: NSViewRepresentable {
    @Binding var text: String
    let fontSize: CGFloat
    let textColor: NSColor
    var onSizeChange: (CGSize) -> Void = { _ in }

    func makeNSView(context: Context) -> NSTextView {
        let tv = NSTextView()
        tv.delegate = context.coordinator
        tv.textColor = textColor
        tv.backgroundColor = .clear
        tv.drawsBackground = false
        tv.isRichText = false
        tv.allowsUndo = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isGrammarCheckingEnabled = false
        // Use left alignment: centering within an infinite-width container pushes
        // text to a huge X offset and clips it. Visual centering comes from equal
        // horizontal padding in the SwiftUI bubble wrapper instead.
        let paraStyle = NSMutableParagraphStyle()
        paraStyle.alignment = .left
        tv.defaultParagraphStyle = paraStyle
        tv.typingAttributes = [
            .paragraphStyle: paraStyle,
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: textColor,
        ]

        // Disable line wrapping so the view grows horizontally instead.
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        tv.isHorizontallyResizable = true
        tv.isVerticallyResizable = true
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                            height: CGFloat.greatestFiniteMagnitude)

        // Grab focus as soon as the view is inserted into the window.
        DispatchQueue.main.async {
            tv.window?.makeFirstResponder(tv)
        }
        return tv
    }

    func updateNSView(_ tv: NSTextView, context: Context) {
        if tv.string != text {
            tv.string = text
        }
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let paraStyle = NSMutableParagraphStyle()
        paraStyle.alignment = .left
        tv.typingAttributes = [
            .paragraphStyle: paraStyle,
            .font: font,
            .foregroundColor: textColor,
        ]
        tv.textColor = textColor
        context.coordinator.reportSize(tv)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: GrowingTextField
        init(_ parent: GrowingTextField) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            reportSize(tv)
        }

        func reportSize(_ tv: NSTextView) {
            guard let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            lm.ensureLayout(for: tc)
            let used = lm.usedRect(for: tc).size
            let minH = tv.font?.pointSize ?? parent.fontSize
            let size = CGSize(width: ceil(used.width), height: ceil(max(used.height, minH)))
            // Defer to avoid "modifying state during view update" — reportSize is
            // called from updateNSView which runs inside a SwiftUI layout pass.
            let callback = parent.onSizeChange
            DispatchQueue.main.async { callback(size) }
        }
    }
}

// MARK: - PDF Find Bar

/// A compact find bar overlaid at the top of the editor canvas for in-document
/// PDF search. `EditorView` owns the query + match state and drives
/// search/navigation; this view is presentation + input only.
struct PDFFindBar: View {
    @Binding var query: String
    /// 0-based index of the current match; ignored when `totalMatches == 0`.
    let currentMatch: Int
    let totalMatches: Int
    /// Bumped by the parent to (re)focus the field — e.g. when ⌘F is pressed
    /// while the bar is already open.
    let focusToken: Int

    var onNext: () -> Void
    var onPrevious: () -> Void
    var onClose: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))

            TextField("Find in document", text: $query)
                .textFieldStyle(.plain)
                .frame(width: 200)
                .focused($focused)
                .onSubmit { onNext() }

            Group {
                if totalMatches > 0 {
                    Text("\(currentMatch + 1) of \(totalMatches)")
                } else if !query.isEmpty {
                    Text("Not found")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()

            Divider().frame(height: 16)

            Button(action: onPrevious) {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.plain)
            .disabled(totalMatches == 0)
            .help("Previous match (⇧⏎)")

            Button(action: onNext) {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.plain)
            .disabled(totalMatches == 0)
            .help("Next match (⏎)")

            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Close (Esc)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .onAppear { focused = true }
        .onChange(of: focusToken) { _, _ in focused = true }
    }
}

// MARK: - Continuous PDF Scroll

/// Read-only vertical scroll of every page in a PDF, used in View mode. Each
/// page is a vector, text-selectable `PDFPageView` sized to fit the width; there
/// are no annotation overlays (annotation editing stays in the single-page
/// canvas). Pages load lazily so large documents stay responsive.
struct ContinuousPDFView: View {
    let document: PDFDocument
    /// Set by the parent (Find / outline / links / page controls) to scroll to a
    /// page; the view resets it to nil after scrolling.
    @Binding var scrollTarget: Int?
    /// Reports the page nearest the viewport centre back to the parent so the
    /// page indicator tracks scrolling.
    @Binding var visiblePage: Int
    /// Zoom factor relative to fit-to-width: 1.0 fills the viewport width, >1
    /// enlarges pages (enabling horizontal scroll), <1 shrinks them. Driven by
    /// the editor's zoom controls.
    var zoom: CGFloat = 1
    var highlights: (PDFPage) -> [PDFSelection] = { _ in [] }
    var activeHighlight: (PDFPage) -> PDFSelection? = { _ in nil }
    var onOpenURL: ((URL) -> Void)? = nil
    var onGoToDestination: ((PDFDestination) -> Void)? = nil

    var body: some View {
        GeometryReader { geo in
            // Fit-to-width baseline (zoom == 1), then scaled by the zoom factor.
            let fitWidth = max(geo.size.width - 32, 50)
            let pageWidth = max(fitWidth * zoom, 50)
            ScrollViewReader { proxy in
                // Both axes: vertical to scroll the page stack, horizontal so a
                // page wider than the viewport (zoom > fit) can be panned.
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(spacing: 14) {
                        ForEach(0..<document.pageCount, id: \.self) { i in
                            pageRow(i, width: pageWidth).id(i)
                        }
                    }
                    .padding(.vertical, 16)
                    // Fill at least the viewport and pin to the top: pages stay
                    // horizontally centred, but when the stack is shorter than the
                    // viewport (e.g. a short PDF zoomed out) the slack falls below
                    // instead of splitting symmetrically above and below. When the
                    // content is larger, its intrinsic size drives scrolling on
                    // both axes.
                    .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .top)
                }
                .coordinateSpace(name: "continuousPDF")
                .onPreferenceChange(ContinuousPageMidKey.self) { mids in
                    let center = geo.size.height / 2
                    if let nearest = mids.min(by: { abs($0.value - center) < abs($1.value - center) }),
                       nearest.key != visiblePage {
                        visiblePage = nearest.key
                    }
                }
                .onChange(of: scrollTarget) { _, target in
                    guard let target else { return }
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(target, anchor: .top)
                    }
                    DispatchQueue.main.async { scrollTarget = nil }
                }
                .onAppear {
                    if visiblePage > 0 { proxy.scrollTo(visiblePage, anchor: .top) }
                }
            }
        }
    }

    @ViewBuilder
    private func pageRow(_ i: Int, width: CGFloat) -> some View {
        if let page = document.page(at: i) {
            let size = page.rotatedMediaBoxSize
            let aspect = size.height > 0 ? size.width / size.height : 0.75
            let height = aspect > 0 ? width / aspect : width
            PDFPageView(
                page: page,
                pointSize: size,
                isTextSelectable: true,
                searchHighlights: highlights(page),
                activeSearchHighlight: activeHighlight(page),
                onOpenURL: onOpenURL,
                onGoToDestination: onGoToDestination
            )
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 2)
            .background(
                GeometryReader { g in
                    Color.clear.preference(
                        key: ContinuousPageMidKey.self,
                        value: [i: g.frame(in: .named("continuousPDF")).midY]
                    )
                }
            )
        }
    }
}

/// Reports each rendered page's vertical midpoint so the container can pick the
/// page nearest the viewport centre.
private struct ContinuousPageMidKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - PDF Document Info

/// A small modal showing the PDF's metadata (⌘I). Presented as a sheet by
/// `EditorView`.
struct PDFInfoView: View {
    let document: PDFDocument
    let page: PDFPage?
    let url: URL?
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Document Info").font(.headline)
                Spacer()
                Button("Done", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.bottom, 14)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 8) {
                ForEach(Array(infoRows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        Text(row.0)
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                        Text(row.1)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private var infoRows: [(LocalizedStringKey, String)] {
        var rows: [(LocalizedStringKey, String)] = []
        let attrs = document.documentAttributes ?? [:]
        if let title = attrs[PDFDocumentAttribute.titleAttribute] as? String, !title.isEmpty {
            rows.append(("Title", title))
        }
        if let author = attrs[PDFDocumentAttribute.authorAttribute] as? String, !author.isEmpty {
            rows.append(("Author", author))
        }
        rows.append(("Pages", "\(document.pageCount)"))
        if let url {
            rows.append(("File", url.lastPathComponent))
            if let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                rows.append(("Size", ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)))
            }
        }
        if let page {
            let s = page.rotatedMediaBoxSize
            rows.append(("Page size", "\(Int(s.width.rounded())) × \(Int(s.height.rounded())) pt"))
        }
        return rows
    }
}
