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
    var showShadow: Bool = false // show a drop shadow around the image

    @Binding var annotations: [Annotation]
    @Binding var selectedAnnotationID: UUID?
    @Binding var currentTool: AnnotationTool
    @Binding var currentStyle: AnnotationStyle
    @Binding var cropRect: CGRect
    @Binding var isCropping: Bool

    /// Called when the user finishes creating or modifying an annotation (for undo).
    var onCommit: () -> Void = {}

    /// Annotation currently being drawn (not yet committed).
    @State private var pendingAnnotation: Annotation?
    /// For text editing
    @State private var editingTextID: UUID?
    @State private var editingText: String = ""
    @FocusState private var isTextFieldFocused: Bool
    /// Drag state for moving / reshaping selected annotations
    @State private var isDraggingAnnotation: Bool = false
    /// Pre-drag snapshot of the annotation being moved/resized
    @State private var dragStartAnnotation: Annotation?
    /// The image-space point where the drag started (for delta computation)
    @State private var dragStartImagePoint: CGPoint = .zero
    /// Which part of the annotation is being dragged
    @State private var dragMode: DragMode = .body
    /// Ensure we only push one undo snapshot per drag interaction.
    @State private var didCaptureUndoForCurrentDrag: Bool = false

    private var canvasWidth: CGFloat { imagePixelSize.width * scale }
    private var canvasHeight: CGFloat { imagePixelSize.height * scale }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Base image + gesture layer combined (so gestures don't block other views)
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: canvasWidth, height: canvasHeight)
                .shadow(color: showShadow ? .black.opacity(0.25) : .clear, radius: 8, x: 0, y: 2)
                .contentShape(Rectangle())
                .gesture(canvasGesture)
                .onTapGesture(count: 2) { location in
                    handleDoubleTap(at: location)
                }
                .onTapGesture { location in
                    handleTap(at: location)
                }

            // Committed annotations (hide the one being text-edited)
            ForEach(annotations.filter { $0.id != editingTextID }) { annotation in
                AnnotationOverlayView(
                    annotation: annotation,
                    scale: scale,
                    displayBackingScale: displayBackingScale,
                    isSelected: annotation.id == selectedAnnotationID && !isDraggingAnnotation,
                    sourceImage: image,
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
                    sourceImage: image,
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
                TextField("Type here", text: $editingText)
                    .textFieldStyle(.plain)
                    .font(.system(size: scaledFontSize, weight: .medium))
                    .foregroundStyle(.white)
                    .tint(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, scaledFontSize * 0.55)
                    .padding(.vertical, scaledFontSize * 0.25)
                    .frame(minWidth: 100)
                    .fixedSize()
                    .background(Capsule().fill(ann.style.textBubbleBackground))
                    .overlay(Capsule().stroke(.white, lineWidth: 2))
                    .padding(2)
                    .overlay(Capsule().stroke(ann.style.textBubbleBackground, lineWidth: 2))
                    .focused($isTextFieldFocused)
                    .position(x: pos.x, y: pos.y)
                    .onSubmit {
                        commitTextEdit()
                    }
            }

            // Crop overlay — on top, handles its own gestures
            if isCropping {
                CropOverlayView(
                    cropRect: $cropRect,
                    imageSize: imagePixelSize,
                    scale: scale
                )
            }
        }
        .frame(width: canvasWidth, height: canvasHeight)
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
                            dragStartAnnotation = annotations[idx]
                            dragStartImagePoint = startInImage
                            dragMode = mode
                            didCaptureUndoForCurrentDrag = false
                        }
                        applyDragDelta(currentInImage)
                        return
                    }
                    // Nothing hit — start drawing (only if not select tool)
                    if currentTool != .select && currentTool != .text {
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
                    } else if tool == .measurement,
                              isShiftDown,
                              let start = pendingAnnotation?.startPoint {
                        pendingAnnotation?.endPoint = constrainTo45Degree(start: start, end: currentInImage)
                    } else if isShiftDown && (tool == .rectangle || tool == .circle),
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

        // Any tool: tap on annotation to select it
        if let hitID = hitTestBody(pointInImage) {
            selectedAnnotationID = hitID
        } else {
            selectedAnnotationID = nil
        }
    }

    // MARK: - Drag Application

    /// Apply the current drag delta to the annotation being dragged.
    private func applyDragDelta(_ currentInImage: CGPoint) {
        guard let startAnn = dragStartAnnotation,
              let idx = annotations.firstIndex(where: { $0.id == startAnn.id })
        else { return }

        if !didCaptureUndoForCurrentDrag {
            onCommit()
            didCaptureUndoForCurrentDrag = true
        }

        let dx = currentInImage.x - dragStartImagePoint.x
        let dy = currentInImage.y - dragStartImagePoint.y

        switch dragMode {
        case .body:
            annotations[idx].startPoint = CGPoint(x: startAnn.startPoint.x + dx,
                                                   y: startAnn.startPoint.y + dy)
            annotations[idx].endPoint   = CGPoint(x: startAnn.endPoint.x + dx,
                                                   y: startAnn.endPoint.y + dy)
            if startAnn.tool == .freeDraw {
                annotations[idx].points = startAnn.points.map {
                    CGPoint(x: $0.x + dx, y: $0.y + dy)
                }
            }

        case .startHandle:
            let newStart = CGPoint(x: startAnn.startPoint.x + dx,
                                   y: startAnn.startPoint.y + dy)
            if startAnn.tool == .measurement, isShiftDown {
                annotations[idx].startPoint = constrainTo45Degree(start: startAnn.endPoint, end: newStart)
            } else {
                annotations[idx].startPoint = newStart
            }

        case .endHandle:
            let newEnd = CGPoint(x: startAnn.endPoint.x + dx,
                                 y: startAnn.endPoint.y + dy)
            if startAnn.tool == .measurement, isShiftDown {
                annotations[idx].endPoint = constrainTo45Degree(start: startAnn.startPoint, end: newEnd)
            } else {
                annotations[idx].endPoint = newEnd
            }

        case .corner(let minXFixed, let minYFixed):
            let origRect = startAnn.boundingRect
            let draggedX = minXFixed ? origRect.maxX + dx : origRect.minX + dx
            let draggedY = minYFixed ? origRect.maxY + dy : origRect.minY + dy
            let fixedX = minXFixed ? origRect.minX : origRect.maxX
            let fixedY = minYFixed ? origRect.minY : origRect.maxY
            annotations[idx].startPoint = CGPoint(x: min(fixedX, draggedX),
                                                   y: min(fixedY, draggedY))
            annotations[idx].endPoint   = CGPoint(x: max(fixedX, draggedX),
                                                   y: max(fixedY, draggedY))
        }
    }

    private func finishSelectDrag() {
        isDraggingAnnotation = false
        dragStartAnnotation = nil
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
        isTextFieldFocused = true
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
    }

    /// Begin inline editing of an existing text annotation.
    private func beginTextEdit(id: UUID, text: String) {
        selectedAnnotationID = id
        editingTextID = id
        editingText = text
        isTextFieldFocused = true
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

        case .rectangle, .circle, .pixelate:
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
                if distanceToSegment(point: point,
                                     start: annotation.startPoint,
                                     end: annotation.endPoint) < threshold {
                    return annotation.id
                }

            case .freeDraw:
                if distanceToPolyline(point: point, points: annotation.points) < threshold {
                    return annotation.id
                }

            case .rectangle, .circle, .pixelate:
                let rect = annotation.boundingRect.insetBy(dx: -threshold, dy: -threshold)
                if rect.contains(point) {
                    return annotation.id
                }

            case .text:
                let fs = annotation.style.fontSize
                let hPad = fs * 0.55
                let vPad = fs * 0.25
                let estWidth = max(CGFloat(annotation.text.count) * fs * 0.6, 40) + hPad * 2
                let estHeight = fs + vPad * 2
                let textRect = CGRect(
                    x: annotation.startPoint.x - estWidth / 2,
                    y: annotation.startPoint.y - estHeight / 2,
                    width: estWidth,
                    height: estHeight
                )
                if textRect.contains(point) {
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

    private var isShiftDown: Bool {
        NSEvent.modifierFlags.contains(.shift)
    }
}
