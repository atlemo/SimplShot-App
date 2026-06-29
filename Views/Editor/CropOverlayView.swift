import SwiftUI

/// Preset aspect ratios offered for the crop tool. `.free` allows any rectangle;
/// the others lock the crop region (and its handle drags) to a fixed ratio.
enum CropAspectPreset: String, CaseIterable, Identifiable {
    case free = "Free"
    case square = "1:1"
    case fourThree = "4:3"
    case threeTwo = "3:2"
    case sixteenNine = "16:9"
    case threeFour = "3:4"
    case nineSixteen = "9:16"

    var id: String { rawValue }

    /// width / height, or nil for a freeform crop.
    var ratio: CGFloat? {
        switch self {
        case .free:        return nil
        case .square:      return 1
        case .fourThree:   return 4.0 / 3.0
        case .threeTwo:    return 3.0 / 2.0
        case .sixteenNine: return 16.0 / 9.0
        case .threeFour:   return 3.0 / 4.0
        case .nineSixteen: return 9.0 / 16.0
        }
    }
}

/// Displays a crop rectangle with draggable edges/corners over the canvas.
/// `cropRect` is in **image-pixel coordinates**; `scale` maps to view coords.
/// `cropBoundsRect` constrains the draggable area (screenshot content only when
/// a background gradient is active, full image otherwise).
/// `aspectRatio` (width/height) locks the crop shape when non-nil; the interior
/// can always be dragged to reposition the selection.
struct CropOverlayView: View {
    @Binding var cropRect: CGRect
    let scale: CGFloat          // view points per image pixel
    let cropBoundsRect: CGRect  // allowed crop area in image pixels
    var aspectRatio: CGFloat? = nil
    /// Fine straighten angle (degrees). When non-zero the crop is auto-inscribed
    /// to the largest upright rectangle that fits inside the tilted image, and
    /// drags clamp to that inscribed region instead of the full image.
    var straightenAngle: CGFloat = 0
    /// Whether to show the straightening grid (while actively adjusting).
    var showGrid: Bool = false
    /// Called when a handle/move drag begins / ends, so the grid can fade in/out.
    var onAdjustBegan: () -> Void = {}
    var onAdjustEnded: () -> Void = {}

    /// Snapshot of cropRect when a handle/move drag begins.
    @State private var dragStartRect: CGRect? = nil

    /// The crop region the handles clamp to: the full bounds normally, or the
    /// largest upright inscribed rectangle when a straighten angle is active.
    private var effectiveBounds: CGRect {
        guard straightenAngle != 0 else { return cropBoundsRect }
        let insc = EditorView.largestInscribedSize(cropBoundsRect.size, degrees: Double(straightenAngle))
        var w = insc.width, h = insc.height
        if let ratio = aspectRatio, w > 0, h > 0 {
            if w / h > ratio { w = h * ratio } else { h = w / ratio }
        }
        return CGRect(x: cropBoundsRect.midX - w / 2,
                      y: cropBoundsRect.midY - h / 2,
                      width: w, height: h)
    }

    private let handleSize: CGFloat = 10
    private let dimColor = Color.black.opacity(0.45)
    private let minSize: CGFloat = 20  // minimum crop size in image pixels

    var body: some View {
        let viewRect = scaledRect(cropRect)

        ZStack {
            // Dimmed area outside the crop
            CropDimOverlay(cropRect: viewRect)
                .fill(dimColor, style: FillStyle(eoFill: true))
                .allowsHitTesting(false)

            // Interior move area — drag to reposition the whole crop region.
            Rectangle()
                .fill(Color.white.opacity(0.001))
                .frame(width: viewRect.width, height: viewRect.height)
                .position(x: viewRect.midX, y: viewRect.midY)
                .gesture(moveGesture)

            // Crop border
            Rectangle()
                .stroke(Color.black.opacity(0.35), lineWidth: 3)
                .overlay(
                    Rectangle()
                        .stroke(Color.white, lineWidth: 1.5)
                )
                .frame(width: viewRect.width, height: viewRect.height)
                .position(x: viewRect.midX, y: viewRect.midY)
                .allowsHitTesting(false)

            // Straightening grid — shown only while actively adjusting.
            if showGrid {
                CropGridShape(rect: viewRect, divisions: 6)
                    .stroke(Color.white.opacity(0.55), lineWidth: 0.5)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            // Corner handles
            cropHandle(.topLeft, viewRect: viewRect)
            cropHandle(.topRight, viewRect: viewRect)
            cropHandle(.bottomLeft, viewRect: viewRect)
            cropHandle(.bottomRight, viewRect: viewRect)

            // Edge handles
            cropHandle(.top, viewRect: viewRect)
            cropHandle(.bottom, viewRect: viewRect)
            cropHandle(.left, viewRect: viewRect)
            cropHandle(.right, viewRect: viewRect)
        }
        .onChange(of: aspectRatio) { _, newRatio in
            if let ratio = newRatio {
                cropRect = fitRect(cropRect, to: ratio)
            }
        }
        .onChange(of: straightenAngle) { _, _ in
            // Auto-inscribe: snap the crop to the largest upright rect that fits
            // inside the tilted image, so empty corners never show.
            cropRect = effectiveBounds
        }
        .animation(.easeInOut(duration: 0.15), value: showGrid)
    }

    // MARK: - Handle Views

    private func cropHandle(_ edge: CropEdge, viewRect: CGRect) -> some View {
        let center = edge.center(in: viewRect)
        let isCorner = edge.isCorner

        return RoundedRectangle(cornerRadius: isCorner ? 2 : 1)
            .fill(Color.white)
            .overlay(
                RoundedRectangle(cornerRadius: isCorner ? 2 : 1)
                    .stroke(Color.black.opacity(0.5), lineWidth: 1)
            )
            .frame(width: isCorner ? handleSize : (edge.isHorizontal ? handleSize * 2 : handleSize),
                   height: isCorner ? handleSize : (edge.isHorizontal ? handleSize : handleSize * 2))
            .position(center)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dragStartRect == nil {
                            dragStartRect = cropRect
                            onAdjustBegan()
                        }
                        if let startRect = dragStartRect {
                            applyDrag(edge: edge, translation: value.translation, startRect: startRect)
                        }
                    }
                    .onEnded { _ in
                        dragStartRect = nil
                        onAdjustEnded()
                    }
            )
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragStartRect == nil {
                    dragStartRect = cropRect
                    onAdjustBegan()
                }
                if let startRect = dragStartRect {
                    applyMove(translation: value.translation, startRect: startRect)
                }
            }
            .onEnded { _ in
                dragStartRect = nil
                onAdjustEnded()
            }
    }

    // MARK: - Drag Handling

    /// Repositions the whole crop region, clamped so it stays within bounds.
    private func applyMove(translation: CGSize, startRect: CGRect) {
        let bounds = effectiveBounds
        let dx = translation.width / scale
        let dy = translation.height / scale
        var rect = startRect
        rect.origin.x = min(max(startRect.origin.x + dx, bounds.minX),
                            bounds.maxX - rect.width)
        rect.origin.y = min(max(startRect.origin.y + dy, bounds.minY),
                            bounds.maxY - rect.height)
        cropRect = rect
    }

    private func applyDrag(edge: CropEdge, translation: CGSize, startRect: CGRect) {
        // translation is cumulative from drag start, applied to the startRect snapshot
        let dx = translation.width / scale
        let dy = translation.height / scale

        let rect: CGRect
        if let ratio = aspectRatio {
            rect = resizeLocked(edge: edge, dx: dx, dy: dy, startRect: startRect, ratio: ratio)
        } else {
            rect = resizeFree(edge: edge, dx: dx, dy: dy, startRect: startRect)
        }

        let clamped = clampToBounds(rect)
        if clamped.width >= minSize, clamped.height >= minSize {
            cropRect = clamped
        }
    }

    /// Freeform resize — each dragged edge/corner moves independently.
    private func resizeFree(edge: CropEdge, dx: CGFloat, dy: CGFloat, startRect: CGRect) -> CGRect {
        var rect = startRect
        switch edge {
        case .topLeft:
            rect.origin.x = min(startRect.origin.x + dx, startRect.maxX - minSize)
            rect.origin.y = min(startRect.origin.y + dy, startRect.maxY - minSize)
            rect.size.width = max(startRect.size.width - dx, minSize)
            rect.size.height = max(startRect.size.height - dy, minSize)
        case .topRight:
            rect.origin.y = min(startRect.origin.y + dy, startRect.maxY - minSize)
            rect.size.width = max(startRect.size.width + dx, minSize)
            rect.size.height = max(startRect.size.height - dy, minSize)
        case .bottomLeft:
            rect.origin.x = min(startRect.origin.x + dx, startRect.maxX - minSize)
            rect.size.width = max(startRect.size.width - dx, minSize)
            rect.size.height = max(startRect.size.height + dy, minSize)
        case .bottomRight:
            rect.size.width = max(startRect.size.width + dx, minSize)
            rect.size.height = max(startRect.size.height + dy, minSize)
        case .top:
            rect.origin.y = min(startRect.origin.y + dy, startRect.maxY - minSize)
            rect.size.height = max(startRect.size.height - dy, minSize)
        case .bottom:
            rect.size.height = max(startRect.size.height + dy, minSize)
        case .left:
            rect.origin.x = min(startRect.origin.x + dx, startRect.maxX - minSize)
            rect.size.width = max(startRect.size.width - dx, minSize)
        case .right:
            rect.size.width = max(startRect.size.width + dx, minSize)
        }
        return rect
    }

    /// Aspect-locked resize — derives the second dimension from `ratio`, anchored
    /// at the opposite corner (corners) or the opposite edge + perpendicular
    /// center (edges).
    private func resizeLocked(edge: CropEdge, dx: CGFloat, dy: CGFloat,
                              startRect: CGRect, ratio: CGFloat) -> CGRect {
        let minW = max(minSize, minSize * ratio)
        let minH = minW / ratio

        switch edge {
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            // Drive the size from whichever axis the pointer moved more, then
            // anchor at the diagonally opposite corner.
            let desiredW = edge.movesLeft ? startRect.width - dx : startRect.width + dx
            let desiredH = edge.movesUp   ? startRect.height - dy : startRect.height + dy
            var w = max(desiredW, desiredH * ratio)
            w = max(w, minW)
            let h = w / ratio
            let anchorX = edge.movesLeft ? startRect.maxX : startRect.minX
            let anchorY = edge.movesUp   ? startRect.maxY : startRect.minY
            let x = edge.movesLeft ? anchorX - w : anchorX
            let y = edge.movesUp   ? anchorY - h : anchorY
            return CGRect(x: x, y: y, width: w, height: h)

        case .left, .right:
            // Width driven by the drag; height follows ratio, centered vertically.
            let desiredW = edge == .left ? startRect.width - dx : startRect.width + dx
            let w = max(desiredW, minW)
            let h = w / ratio
            let x = edge == .left ? startRect.maxX - w : startRect.minX
            let y = startRect.midY - h / 2
            return CGRect(x: x, y: y, width: w, height: h)

        case .top, .bottom:
            // Height driven by the drag; width follows ratio, centered horizontally.
            let desiredH = edge == .top ? startRect.height - dy : startRect.height + dy
            let h = max(desiredH, minH)
            let w = h * ratio
            let x = startRect.midX - w / 2
            let y = edge == .top ? startRect.maxY - h : startRect.minY
            return CGRect(x: x, y: y, width: w, height: h)
        }
    }

    // MARK: - Bounds Clamping

    /// Clamps `rect` into `cropBoundsRect`. When an aspect ratio is active the
    /// rect is scaled down (preserving the ratio) before being nudged inside.
    private func clampToBounds(_ rect: CGRect) -> CGRect {
        let bounds = effectiveBounds
        var rect = rect
        if let ratio = aspectRatio {
            if rect.width > bounds.width {
                rect.size.width = bounds.width
                rect.size.height = rect.width / ratio
            }
            if rect.height > bounds.height {
                rect.size.height = bounds.height
                rect.size.width = rect.height * ratio
            }
            rect.origin.x = min(max(rect.minX, bounds.minX), bounds.maxX - rect.width)
            rect.origin.y = min(max(rect.minY, bounds.minY), bounds.maxY - rect.height)
        } else {
            rect.origin.x = max(rect.minX, bounds.minX)
            rect.origin.y = max(rect.minY, bounds.minY)
            rect.size.width = min(rect.width, bounds.maxX - rect.origin.x)
            rect.size.height = min(rect.height, bounds.maxY - rect.origin.y)
        }
        return rect
    }

    /// Reshapes `rect` to `ratio`, keeping its center and fitting within bounds.
    private func fitRect(_ rect: CGRect, to ratio: CGFloat) -> CGRect {
        let bounds = effectiveBounds
        var w = rect.width
        var h = w / ratio
        if h > rect.height {
            h = rect.height
            w = h * ratio
        }
        if w > bounds.width {
            w = bounds.width
            h = w / ratio
        }
        if h > bounds.height {
            h = bounds.height
            w = h * ratio
        }
        var fitted = CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
        fitted.origin.x = min(max(fitted.minX, bounds.minX), bounds.maxX - w)
        fitted.origin.y = min(max(fitted.minY, bounds.minY), bounds.maxY - h)
        return fitted
    }

    // MARK: - Coordinate Helpers

    private func scaledRect(_ rect: CGRect) -> CGRect {
        CGRect(
            x: rect.origin.x * scale,
            y: rect.origin.y * scale,
            width: rect.width * scale,
            height: rect.height * scale
        )
    }
}

// MARK: - Crop Edge Enum

private enum CropEdge {
    case topLeft, topRight, bottomLeft, bottomRight
    case top, bottom, left, right

    var isCorner: Bool {
        switch self {
        case .topLeft, .topRight, .bottomLeft, .bottomRight: return true
        default: return false
        }
    }

    var isHorizontal: Bool {
        switch self {
        case .top, .bottom: return true
        default: return false
        }
    }

    /// True when the handle's horizontal motion shrinks/grows from the left side.
    var movesLeft: Bool {
        switch self {
        case .topLeft, .bottomLeft, .left: return true
        default: return false
        }
    }

    /// True when the handle's vertical motion shrinks/grows from the top side.
    var movesUp: Bool {
        switch self {
        case .topLeft, .topRight, .top: return true
        default: return false
        }
    }

    func center(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft:     return CGPoint(x: rect.minX, y: rect.minY)
        case .topRight:    return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft:  return CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .top:         return CGPoint(x: rect.midX, y: rect.minY)
        case .bottom:      return CGPoint(x: rect.midX, y: rect.maxY)
        case .left:        return CGPoint(x: rect.minX, y: rect.midY)
        case .right:       return CGPoint(x: rect.maxX, y: rect.midY)
        }
    }
}

// MARK: - Dim Overlay Shape (hole in the middle)

private struct CropDimOverlay: Shape {
    let cropRect: CGRect

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        path.addRect(cropRect)
        return path
    }
}

// MARK: - Straightening Grid

/// Evenly-spaced grid drawn inside `rect`. `divisions` is the number of cells per
/// axis (so `divisions - 1` interior lines each way) — denser than rule-of-thirds
/// to give a clear reference for leveling edges while straightening.
private struct CropGridShape: Shape {
    let rect: CGRect
    let divisions: Int

    func path(in _: CGRect) -> Path {
        var path = Path()
        guard divisions > 1, rect.width > 0, rect.height > 0 else { return path }
        for i in 1..<divisions {
            let fx = rect.minX + rect.width * CGFloat(i) / CGFloat(divisions)
            path.move(to: CGPoint(x: fx, y: rect.minY))
            path.addLine(to: CGPoint(x: fx, y: rect.maxY))
            let fy = rect.minY + rect.height * CGFloat(i) / CGFloat(divisions)
            path.move(to: CGPoint(x: rect.minX, y: fy))
            path.addLine(to: CGPoint(x: rect.maxX, y: fy))
        }
        return path
    }
}
