import SwiftUI

/// Renders a single annotation shape in view coordinates.
/// The parent is responsible for mapping image-pixel coords → view coords via `scale`.
struct AnnotationOverlayView: View {
    let annotation: Annotation
    let scale: CGFloat         // view points per image pixel
    let isSelected: Bool

    var body: some View {
        ZStack {
            annotationShape
            if isSelected {
                selectionHandles
            }
        }
    }

    // MARK: - Shape Rendering

    @ViewBuilder
    private var annotationShape: some View {
        let start = scaled(annotation.startPoint)
        let end = scaled(annotation.endPoint)
        let rect = scaledBoundingRect

        switch annotation.tool {
        case .arrow:
            ArrowShape(start: start, end: end, lineWidth: annotation.style.strokeWidth)
                .stroke(annotation.style.strokeColor, style: StrokeStyle(lineWidth: annotation.style.strokeWidth, lineCap: .round))
            // Arrowhead as a filled triangle (drawn on top of the shortened line)
            ArrowHeadShape(start: start, end: end, lineWidth: annotation.style.strokeWidth)
                .fill(annotation.style.strokeColor)

        case .line:
            Path { path in
                path.move(to: start)
                path.addLine(to: end)
            }
            .stroke(annotation.style.strokeColor, lineWidth: annotation.style.strokeWidth)

        case .rectangle:
            Rectangle()
                .stroke(annotation.style.strokeColor, lineWidth: annotation.style.strokeWidth)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)

        case .circle:
            Ellipse()
                .stroke(annotation.style.strokeColor, lineWidth: annotation.style.strokeWidth)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)

        case .text:
            let scaledFontSize = annotation.style.fontSize * scale
            Text(annotation.text)
                .font(.system(size: scaledFontSize, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, scaledFontSize * 0.55)
                .padding(.vertical, scaledFontSize * 0.25)
                .background(
                    Capsule()
                        .fill(annotation.style.textBubbleBackground)
                )
                .fixedSize()
                .position(x: start.x, y: start.y)

        case .select, .crop:
            EmptyView()
        }
    }

    // MARK: - Selection Handles

    @ViewBuilder
    private var selectionHandles: some View {
        let start = scaled(annotation.startPoint)
        let end = scaled(annotation.endPoint)

        switch annotation.tool {
        case .arrow, .line:
            HandleDot(center: start)
            HandleDot(center: end)

        case .rectangle, .circle:
            let rect = scaledBoundingRect
            HandleDot(center: CGPoint(x: rect.minX, y: rect.minY))
            HandleDot(center: CGPoint(x: rect.maxX, y: rect.minY))
            HandleDot(center: CGPoint(x: rect.minX, y: rect.maxY))
            HandleDot(center: CGPoint(x: rect.maxX, y: rect.maxY))

        case .text:
            // Show a single handle at the text anchor
            HandleDot(center: start)

        case .select, .crop:
            EmptyView()
        }
    }

    // MARK: - Coordinate Helpers

    private func scaled(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * scale, y: point.y * scale)
    }

    private var scaledBoundingRect: CGRect {
        let rect = annotation.boundingRect
        return CGRect(
            x: rect.origin.x * scale,
            y: rect.origin.y * scale,
            width: rect.width * scale,
            height: rect.height * scale
        )
    }
}

// MARK: - Arrow helpers

/// Arrowhead geometry for a given stroke width.
/// - `headLen`: distance from tip to each base corner
/// - `arrowAngle`: half-angle of the arrowhead (30°)
/// - `baseOffset`: distance from tip to the base midpoint along the shaft
private let arrowHalfAngle: CGFloat = .pi / 6  // 30°

private func arrowHeadLen(for lineWidth: CGFloat) -> CGFloat {
    max(lineWidth * 5, 12)
}

// MARK: - Arrow Shape (line shortened to stop at the arrowhead base)

struct ArrowShape: Shape {
    let start: CGPoint
    let end: CGPoint
    let lineWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLen = arrowHeadLen(for: lineWidth)
        // The triangle base sits at headLen·cos(30°) from the tip.
        // Subtract a small overlap (1pt) so the line tucks under the filled triangle.
        let baseOffset = headLen * cos(arrowHalfAngle) - 1
        let shortenedEnd = CGPoint(
            x: end.x - baseOffset * cos(angle),
            y: end.y - baseOffset * sin(angle)
        )
        return Path { p in
            p.move(to: start)
            p.addLine(to: shortenedEnd)
        }
    }
}

// MARK: - Arrowhead Shape (filled triangle with tip at end point)

struct ArrowHeadShape: Shape {
    let start: CGPoint
    let end: CGPoint
    let lineWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLen = arrowHeadLen(for: lineWidth)

        let p1 = CGPoint(
            x: end.x - headLen * cos(angle - arrowHalfAngle),
            y: end.y - headLen * sin(angle - arrowHalfAngle)
        )
        let p2 = CGPoint(
            x: end.x - headLen * cos(angle + arrowHalfAngle),
            y: end.y - headLen * sin(angle + arrowHalfAngle)
        )

        return Path { p in
            p.move(to: end)
            p.addLine(to: p1)
            p.addLine(to: p2)
            p.closeSubpath()
        }
    }
}

// MARK: - Resize Handle Dot

struct HandleDot: View {
    let center: CGPoint
    let size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(Color.white)
            .overlay(Circle().stroke(Color.accentColor, lineWidth: 1.5))
            .frame(width: size, height: size)
            .position(center)
    }
}
