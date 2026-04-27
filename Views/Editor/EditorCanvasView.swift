import SwiftUI

// MARK: - Drag Mode

/// Describes what part of a selected annotation is being dragged.
enum DragMode {
    case body                      // move entire annotation
    case startHandle               // move startPoint only (arrow/line)
    case endHandle                 // move endPoint only (arrow/line)
    case corner(minXFixed: Bool, minYFixed: Bool)  // resize rectangle via one corner
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
    let displayBackingScale: CGFloat  // monitor backing scale for true 1x measurements
    var shadowIntensity: Double = 0 // drop shadow opacity (0 = none, 1 = full)

    @Binding var annotations: [Annotation]
    @Binding var selectedAnnotationID: UUID?
    @Binding var currentTool: AnnotationTool
    @Binding var currentStyle: AnnotationStyle
    @Binding var cropRect: CGRect
    @Binding var isCropping: Bool
    /// The allowed crop area in image-pixel space. When a background gradient is
    /// active this is the screenshot content region; otherwise the full image.
    var cropBoundsRect: CGRect? = nil

    var watermarkSettings: WatermarkSettings = WatermarkSettings()

    /// Called when the user finishes creating or modifying an annotation (for undo).
    var onCommit: () -> Void = {}

    /// Annotation currently being drawn (not yet committed).
    @State private var pendingAnnotation: Annotation?
    /// For text editing
    @State private var editingTextID: UUID?
    @State private var editingText: String = ""
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

    private var canvasWidth: CGFloat { imagePixelSize.width * scale }
    private var canvasHeight: CGFloat { imagePixelSize.height * scale }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Base image + gesture layer combined (so gestures don't block other views)
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: canvasWidth, height: canvasHeight)
                .shadow(color: .black.opacity(0.5 * shadowIntensity), radius: 60 * shadowIntensity, x: 0, y: 28 * shadowIntensity)
                .contentShape(Rectangle())
                .gesture(canvasGesture)
                .onTapGesture(count: 2) { location in
                    handleDoubleTap(at: location)
                }
                .onTapGesture { location in
                    handleTap(at: location)
                }

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
                sourceImage: image,
                imagePixelSize: imagePixelSize
            )

            // Live drag proxy — only this view updates during drag (local @State).
            // NO drawingGroup() here: for a single annotation, allocating a full
            // canvas-sized Metal buffer every frame is more expensive than the 2-3
            // Core Animation layers the shape naturally creates.
            if let dragging = draggingAnnotation {
                AnnotationOverlayView(
                    annotation: dragging,
                    scale: scale,
                    displayBackingScale: displayBackingScale,
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
                    isSelected: false,
                    sourceImage: pending.tool == .pixelate ? image : nil,
                    imagePixelSize: imagePixelSize
                )
                .allowsHitTesting(false)
            }

            // Inline text editing styled to match the final pill appearance
            if let editID = editingTextID,
               let idx = annotations.firstIndex(where: { $0.id == editID }) {
                let ann = annotations[idx]
                let scaledFontSize = ann.style.fontSize * scale
                let pos = CGPoint(
                    x: ann.startPoint.x * scale,
                    y: ann.startPoint.y * scale
                )
                let contentW = max(editingContentSize.width, scaledFontSize * 2)
                let contentH = max(editingContentSize.height, scaledFontSize * 1.2)
                GrowingTextField(
                    text: $editingText,
                    fontSize: scaledFontSize,
                    textColor: NSColor(ann.style.textBubbleForeground),
                    onSizeChange: { editingContentSize = $0 }
                )
                .frame(width: contentW, height: contentH)
                .padding(.horizontal, scaledFontSize * 0.55)
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
                    cropBoundsRect: cropBoundsRect ?? CGRect(origin: .zero, size: imagePixelSize)
                )
            }
        }
        .frame(width: canvasWidth, height: canvasHeight)
    }

    // MARK: - Watermark Preview

    @ViewBuilder
    private var watermarkPreviewOverlay: some View {
        if watermarkSettings.isEnabled,
           let path = watermarkSettings.imagePath,
           let nsImage = NSImage(contentsOfFile: path),
           nsImage.isValid {
            let marginH = canvasWidth * 0.02
            let marginV = canvasHeight * 0.02
            // widthPx is in logical points. At true-size zoom this simplifies to
            // widthPx × zoomLevel view-points, matching what the slider label shows.
            let targetW = max(1, CGFloat(watermarkSettings.widthPx) * scale * displayBackingScale)
            let rawSize = nsImage.size
            let aspect = rawSize.height > 0 ? rawSize.width / rawSize.height : 1.0
            let targetH = max(1, targetW / aspect)
            let pos = watermarkPreviewPosition(
                position: watermarkSettings.position,
                targetW: targetW, targetH: targetH, marginH: marginH, marginV: marginV
            )
            Image(nsImage: nsImage)
                .resizable()
                .frame(width: targetW, height: targetH)
                .opacity(watermarkSettings.opacity)
                .position(x: pos.x, y: pos.y)
                .allowsHitTesting(false)
        }
    }

    private func watermarkPreviewPosition(
        position: WatermarkPosition,
        targetW: CGFloat, targetH: CGFloat, marginH: CGFloat, marginV: CGFloat
    ) -> CGPoint {
        switch position {
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
                        // Drag an existing annotation regardless of current tool
                        if let idx = annotations.firstIndex(where: { $0.id == hitID }) {
                            selectedAnnotationID = hitID
                            isDraggingAnnotation = true
                            draggingAnnotationID = hitID
                            dragStartAnnotation = annotations[idx]
                            draggingAnnotation = annotations[idx]
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
                    } else if isAngleLockTool(tool),
                              isShiftDown,
                              let start = pendingAnnotation?.startPoint {
                        pendingAnnotation?.endPoint = constrainTo45Degree(start: start, end: currentInImage)
                    } else if isShiftDown && (tool == .rectangle || tool == .circle || tool == .spotlight),
                       let start = pendingAnnotation?.startPoint {
                        pendingAnnotation?.endPoint = constrainToSquare(start: start, end: currentInImage)
                    } else {
                        pendingAnnotation?.endPoint = currentInImage
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

    /// Apply the current drag delta to the local drag proxy (avoids mutating the binding).
    private func applyDragDelta(_ currentInImage: CGPoint) {
        guard var ann = dragStartAnnotation else { return }

        if !didCaptureUndoForCurrentDrag {
            onCommit()
            didCaptureUndoForCurrentDrag = true
        }

        let dx = currentInImage.x - dragStartImagePoint.x
        let dy = currentInImage.y - dragStartImagePoint.y

        switch dragMode {
        case .body:
            ann.startPoint = CGPoint(x: ann.startPoint.x + dx,
                                     y: ann.startPoint.y + dy)
            ann.endPoint   = CGPoint(x: ann.endPoint.x + dx,
                                     y: ann.endPoint.y + dy)
            if ann.tool == .freeDraw {
                ann.points = ann.points.map {
                    CGPoint(x: $0.x + dx, y: $0.y + dy)
                }
            }

        case .startHandle:
            let newStart = CGPoint(x: ann.startPoint.x + dx,
                                   y: ann.startPoint.y + dy)
            if isAngleLockTool(ann.tool), isShiftDown {
                ann.startPoint = constrainTo45Degree(start: ann.endPoint, end: newStart)
            } else {
                ann.startPoint = newStart
            }

        case .endHandle:
            let newEnd = CGPoint(x: ann.endPoint.x + dx,
                                 y: ann.endPoint.y + dy)
            if isAngleLockTool(ann.tool), isShiftDown {
                ann.endPoint = constrainTo45Degree(start: ann.startPoint, end: newEnd)
            } else {
                ann.endPoint = newEnd
            }

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
    }

    // MARK: - Text Tool

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
        editingText = ""
        editingContentSize = .zero
    }

    // MARK: - Numbered Step Tool

    private func placeNumberedStep(at point: CGPoint) {
        let nextNumber = (annotations.filter { $0.tool == .numberedStep }.map(\.stepNumber).max() ?? 0) + 1
        let annotation = Annotation(
            tool: .numberedStep,
            startPoint: point,
            endPoint: point,
            style: currentStyle,
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
            return
        }

        if editingText.isEmpty {
            onCommit()
            annotations.remove(at: idx)
            selectedAnnotationID = nil
        } else {
            onCommit()
            annotations[idx].text = editingText
        }
        editingTextID = nil
        editingContentSize = .zero
    }

    /// Begin inline editing of an existing text annotation.
    private func beginTextEdit(id: UUID, text: String) {
        selectedAnnotationID = id
        editingTextID = id
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
            return nil

        case .rectangle, .circle, .pixelate, .spotlight:
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

        default:
            return nil
        }
    }

    /// Hit-test annotation bodies (ignores handles).
    private func hitTestBody(_ point: CGPoint) -> UUID? {
        for annotation in annotations.reversed() {
            let threshold: CGFloat = max(annotation.style.strokeWidth * 3, 10)

            switch annotation.tool {
            case .arrow, .line, .measurement:
                let hitDist: CGFloat
                if annotation.tool == .arrow && annotation.style.arrowStyle == .curved {
                    hitDist = distanceToCurvedArrow(point: point,
                                                    start: annotation.startPoint,
                                                    end: annotation.endPoint)
                } else {
                    hitDist = distanceToSegment(point: point,
                                                start: annotation.startPoint,
                                                end: annotation.endPoint)
                }
                if hitDist < threshold {
                    return annotation.id
                }

            case .freeDraw:
                if distanceToPolyline(point: point, points: annotation.points) < threshold {
                    return annotation.id
                }

            case .rectangle, .circle, .pixelate, .spotlight:
                let rect = annotation.boundingRect.insetBy(dx: -threshold, dy: -threshold)
                if rect.contains(point) {
                    return annotation.id
                }

            case .text:
                let fs = annotation.style.fontSize
                let hPad = fs * 0.55
                let vPad = fs * 0.25
                let lines = annotation.text.components(separatedBy: .newlines)
                let lineCount = max(lines.count, 1)
                let widestLineChars = max(lines.map { $0.count }.max() ?? 0, 1)
                let lineSpacing = fs * 0.22
                let estWidth = max(CGFloat(widestLineChars) * fs * 0.6, 40) + hPad * 2
                let estHeight = CGFloat(lineCount) * fs + CGFloat(max(0, lineCount - 1)) * lineSpacing + vPad * 2
                let textRect = CGRect(
                    x: annotation.startPoint.x - estWidth / 2,
                    y: annotation.startPoint.y - estHeight / 2,
                    width: estWidth,
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

            case .select, .crop:
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

    /// Samples the quadratic bezier used by the curved arrow style and returns
    /// the minimum distance from `point` to any segment of the sampled polyline.
    private func distanceToCurvedArrow(point: CGPoint, start: CGPoint, end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let cp = CGPoint(x: (start.x + end.x) / 2 + dy * 0.3,
                         y: (start.y + end.y) / 2 - dx * 0.3)
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
        NSEvent.modifierFlags.contains(.shift)
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
