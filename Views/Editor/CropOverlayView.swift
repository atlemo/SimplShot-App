import SwiftUI

/// Displays a crop rectangle with draggable edges/corners over the canvas.
/// `cropRect` is in **image-pixel coordinates**; `scale` maps to view coords.
struct CropOverlayView: View {
    @Binding var cropRect: CGRect
    let imageSize: CGSize       // in image pixels
    let scale: CGFloat          // view points per image pixel

    /// Snapshot of cropRect when a handle drag begins.
    @State private var dragStartRect: CGRect? = nil

    private let handleSize: CGFloat = 10
    private let dimColor = Color.black.opacity(0.45)

    var body: some View {
        let viewRect = scaledRect(cropRect)

        ZStack {
            // Dimmed area outside the crop
            CropDimOverlay(cropRect: viewRect)
                .fill(dimColor, style: FillStyle(eoFill: true))
                .allowsHitTesting(false)

            // Crop border
            Rectangle()
                .stroke(Color.white, lineWidth: 1.5)
                .frame(width: viewRect.width, height: viewRect.height)
                .position(x: viewRect.midX, y: viewRect.midY)

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
    }

    // MARK: - Handle Views

    private func cropHandle(_ edge: CropEdge, viewRect: CGRect) -> some View {
        let center = edge.center(in: viewRect)
        let isCorner = edge.isCorner

        return RoundedRectangle(cornerRadius: isCorner ? 2 : 1)
            .fill(Color.white)
            .frame(width: isCorner ? handleSize : (edge.isHorizontal ? handleSize * 2 : handleSize),
                   height: isCorner ? handleSize : (edge.isHorizontal ? handleSize : handleSize * 2))
            .position(center)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dragStartRect == nil {
                            dragStartRect = cropRect
                        }
                        if let startRect = dragStartRect {
                            applyDrag(edge: edge, translation: value.translation, startRect: startRect)
                        }
                    }
                    .onEnded { _ in
                        dragStartRect = nil
                    }
            )
    }

    // MARK: - Drag Handling

    private func applyDrag(edge: CropEdge, translation: CGSize, startRect: CGRect) {
        // translation is cumulative from drag start, applied to the startRect snapshot
        let dx = translation.width / scale
        let dy = translation.height / scale
        var rect = startRect

        let minSize: CGFloat = 20  // minimum crop size in image pixels

        switch edge {
        case .topLeft:
            let newX = rect.origin.x + dx
            let newY = rect.origin.y + dy
            let newW = rect.size.width - dx
            let newH = rect.size.height - dy
            rect.origin.x = min(newX, startRect.maxX - minSize)
            rect.origin.y = min(newY, startRect.maxY - minSize)
            rect.size.width = max(newW, minSize)
            rect.size.height = max(newH, minSize)
        case .topRight:
            let newY = rect.origin.y + dy
            let newW = rect.size.width + dx
            let newH = rect.size.height - dy
            rect.origin.y = min(newY, startRect.maxY - minSize)
            rect.size.width = max(newW, minSize)
            rect.size.height = max(newH, minSize)
        case .bottomLeft:
            let newX = rect.origin.x + dx
            let newW = rect.size.width - dx
            let newH = rect.size.height + dy
            rect.origin.x = min(newX, startRect.maxX - minSize)
            rect.size.width = max(newW, minSize)
            rect.size.height = max(newH, minSize)
        case .bottomRight:
            rect.size.width = max(rect.size.width + dx, minSize)
            rect.size.height = max(rect.size.height + dy, minSize)
        case .top:
            let newY = rect.origin.y + dy
            let newH = rect.size.height - dy
            rect.origin.y = min(newY, startRect.maxY - minSize)
            rect.size.height = max(newH, minSize)
        case .bottom:
            rect.size.height = max(rect.size.height + dy, minSize)
        case .left:
            let newX = rect.origin.x + dx
            let newW = rect.size.width - dx
            rect.origin.x = min(newX, startRect.maxX - minSize)
            rect.size.width = max(newW, minSize)
        case .right:
            rect.size.width = max(rect.size.width + dx, minSize)
        }

        // Clamp to image bounds
        rect.origin.x = max(rect.origin.x, 0)
        rect.origin.y = max(rect.origin.y, 0)
        rect.size.width = min(rect.size.width, imageSize.width - rect.origin.x)
        rect.size.height = min(rect.size.height, imageSize.height - rect.origin.y)

        if rect.width >= minSize, rect.height >= minSize {
            cropRect = rect
        }
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
