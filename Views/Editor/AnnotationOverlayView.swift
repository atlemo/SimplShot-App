import SwiftUI

/// Renders a single annotation shape in view coordinates.
/// The parent is responsible for mapping image-pixel coords → view coords via `scale`.
struct AnnotationOverlayView: View {
    let annotation: Annotation
    let scale: CGFloat         // view points per image pixel
    let displayBackingScale: CGFloat // monitor backing scale (e.g. 2.0 on Retina)
    let isSelected: Bool
    /// Source image for pixelate preview (image-pixel space). Optional; falls back to a mosaic pattern.
    var sourceImage: NSImage? = nil
    var imagePixelSize: CGSize = .zero

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
                .stroke(
                    annotation.style.strokeColor,
                    style: StrokeStyle(
                        lineWidth: annotation.style.strokeWidth,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
            ArrowHeadShape(start: start, end: end, lineWidth: annotation.style.strokeWidth)
                .stroke(
                    annotation.style.strokeColor,
                    style: StrokeStyle(
                        lineWidth: annotation.style.strokeWidth,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )

        case .measurement:
            MeasurementLineShape(start: start, end: end, lineWidth: annotation.style.strokeWidth)
            .stroke(
                annotation.style.strokeColor,
                style: StrokeStyle(
                    lineWidth: annotation.style.strokeWidth,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
            MeasurementHeadShape(baseCenter: end, toward: start, lineWidth: annotation.style.strokeWidth)
                .fill(annotation.style.strokeColor)
            MeasurementHeadShape(baseCenter: start, toward: end, lineWidth: annotation.style.strokeWidth)
                .fill(annotation.style.strokeColor)
            measurementLabel(start: start, end: end)

        case .freeDraw:
            FreeDrawShape(points: annotation.points.map(scaled))
                .stroke(
                    annotation.style.strokeColor,
                    style: StrokeStyle(
                        lineWidth: annotation.style.strokeWidth,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )

        case .line:
            Path { path in
                path.move(to: start)
                path.addLine(to: end)
            }
            .stroke(
                annotation.style.strokeColor,
                style: StrokeStyle(
                    lineWidth: annotation.style.strokeWidth,
                    lineCap: .round,
                    lineJoin: .round
                )
            )

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
            let cornerRadius = scaledFontSize * 0.45
            let borderWidth = max(2, 2 * scale)
            let textLines = annotation.text.components(separatedBy: "\n")
            VStack(alignment: .center, spacing: scaledFontSize * 0.22) {
                ForEach(textLines.indices, id: \.self) { i in
                    Text(textLines[i].isEmpty ? " " : textLines[i])
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .font(.system(size: scaledFontSize, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, scaledFontSize * 0.55)
            .padding(.vertical, scaledFontSize * 0.25)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(annotation.style.textBubbleBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(isSelected ? Color.white : Color.clear, lineWidth: borderWidth)
            )
            .padding(isSelected ? borderWidth : 0)
            .overlay(
                RoundedRectangle(cornerRadius: isSelected ? cornerRadius + borderWidth : cornerRadius, style: .continuous)
                    .stroke(isSelected ? annotation.style.textBubbleBackground : Color.clear, lineWidth: borderWidth)
            )
            .fixedSize()
            .position(x: start.x, y: start.y)

        case .pixelate:
            PixelatePreviewView(
                sourceImage: sourceImage,
                imagePixelSize: imagePixelSize,
                pixelRect: annotation.boundingRect,
                pixelationScale: annotation.style.pixelationScale,
                viewSize: CGSize(width: rect.width, height: rect.height)
            )
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)

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
        case .arrow, .line, .measurement:
            HandleDot(center: start)
            HandleDot(center: end)

        case .rectangle, .circle, .pixelate:
            let rect = scaledBoundingRect
            HandleDot(center: CGPoint(x: rect.minX, y: rect.minY))
            HandleDot(center: CGPoint(x: rect.maxX, y: rect.minY))
            HandleDot(center: CGPoint(x: rect.minX, y: rect.maxY))
            HandleDot(center: CGPoint(x: rect.maxX, y: rect.maxY))

        case .freeDraw, .text:
            EmptyView()

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

    @ViewBuilder
    private func measurementLabel(start: CGPoint, end: CGPoint) -> some View {
        let pixelDistance = hypot(annotation.endPoint.x - annotation.startPoint.x, annotation.endPoint.y - annotation.startPoint.y)
        let true1xDistance = max(0, pixelDistance / max(displayBackingScale, 1))
        let label = "\(Int(true1xDistance.rounded())) px"
        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        Text(label)
            .font(.system(size: max(10, 11 * scale), weight: .medium, design: .monospaced))
            .foregroundStyle(annotation.style.isWhite ? .black : .white)
            .padding(.horizontal, max(6, 7 * scale))
            .padding(.vertical, max(3, 4 * scale))
            .background(annotation.style.strokeColor, in: Capsule())
            .position(mid)
    }
}

// MARK: - Arrow helpers

/// Arrowhead geometry for a given stroke width.
private let arrowChevronHalfAngle: CGFloat = .pi / 4  // 45° => 90° tip
private let measurementHalfAngle: CGFloat = .pi / 6   // keep measurement heads as-is

private func arrowHeadLen(for lineWidth: CGFloat) -> CGFloat {
    max(lineWidth * 5, 12)
}

// MARK: - Arrow Shape (shaft to tip)

struct ArrowShape: Shape {
    let start: CGPoint
    let end: CGPoint
    let lineWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        return Path { p in
            p.move(to: start)
            p.addLine(to: end)
        }
    }
}

// MARK: - Arrowhead Shape (open chevron with tip at end point)

struct ArrowHeadShape: Shape {
    let start: CGPoint
    let end: CGPoint
    let lineWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLen = arrowHeadLen(for: lineWidth)

        let p1 = CGPoint(
            x: end.x - headLen * cos(angle - arrowChevronHalfAngle),
            y: end.y - headLen * sin(angle - arrowChevronHalfAngle)
        )
        let p2 = CGPoint(
            x: end.x - headLen * cos(angle + arrowChevronHalfAngle),
            y: end.y - headLen * sin(angle + arrowChevronHalfAngle)
        )

        return Path { p in
            p.move(to: end)
            p.addLine(to: p1)
            p.move(to: end)
            p.addLine(to: p2)
        }
    }
}

// MARK: - Measurement Line Shape (shortened on both ends for double heads)

struct MeasurementLineShape: Shape {
    let start: CGPoint
    let end: CGPoint
    let lineWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLen = arrowHeadLen(for: lineWidth)
        let baseOffset = headLen * cos(measurementHalfAngle) - 1

        let trimmedStart = CGPoint(
            x: start.x + baseOffset * cos(angle),
            y: start.y + baseOffset * sin(angle)
        )
        let trimmedEnd = CGPoint(
            x: end.x - baseOffset * cos(angle),
            y: end.y - baseOffset * sin(angle)
        )

        return Path { p in
            p.move(to: trimmedStart)
            p.addLine(to: trimmedEnd)
        }
    }
}

struct MeasurementHeadShape: Shape {
    let baseCenter: CGPoint
    let toward: CGPoint
    let lineWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        let angle = atan2(toward.y - baseCenter.y, toward.x - baseCenter.x)
        let headLen = arrowHeadLen(for: lineWidth)
        let tipOffset = headLen * cos(measurementHalfAngle)
        let halfBase = headLen * sin(measurementHalfAngle)

        let tip = CGPoint(
            x: baseCenter.x + tipOffset * cos(angle),
            y: baseCenter.y + tipOffset * sin(angle)
        )
        let perp = angle + .pi / 2
        let b1 = CGPoint(
            x: baseCenter.x + halfBase * cos(perp),
            y: baseCenter.y + halfBase * sin(perp)
        )
        let b2 = CGPoint(
            x: baseCenter.x - halfBase * cos(perp),
            y: baseCenter.y - halfBase * sin(perp)
        )

        return Path { p in
            p.move(to: b1)
            p.addLine(to: b2)
            p.addLine(to: tip)
            p.closeSubpath()
        }
    }
}

// MARK: - Free Draw Shape

struct FreeDrawShape: Shape {
    let points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        let processed = smooth(points: points)
        return Path { p in
            guard let first = processed.first else { return }
            guard processed.count > 1 else {
                p.move(to: first)
                p.addLine(to: first)
                return
            }

            p.move(to: first)
            if processed.count == 2 {
                p.addLine(to: processed[1])
                return
            }

            for i in 1..<(processed.count - 1) {
                let current = processed[i]
                let next = processed[i + 1]
                let mid = CGPoint(x: (current.x + next.x) / 2, y: (current.y + next.y) / 2)
                p.addQuadCurve(to: mid, control: current)
            }
            if let last = processed.last {
                p.addQuadCurve(to: last, control: processed[processed.count - 2])
            }
        }
    }

    /// Lightweight moving-average smoothing for freer, less jagged strokes.
    private func smooth(points: [CGPoint]) -> [CGPoint] {
        guard points.count >= 3 else { return points }
        var out = points
        let passCount = 2

        for _ in 0..<passCount {
            var next = out
            for i in 1..<(out.count - 1) {
                let a = out[i - 1]
                let b = out[i]
                let c = out[i + 1]
                next[i] = CGPoint(
                    x: (a.x + b.x * 2 + c.x) / 4,
                    y: (a.y + b.y * 2 + c.y) / 4
                )
            }
            out = next
        }
        return out
    }
}

// MARK: - Pixelate Preview

/// Renders a pixelated (mosaic) preview of a region of the source image.
/// Downscales the crop to a tiny bitmap, then SwiftUI scales it back up with
/// `.interpolation(.none)` to produce sharp pixel blocks.
/// Falls back to a checkerboard placeholder when no source image is available.
private struct PixelatePreviewView: View {
    let sourceImage: NSImage?
    let imagePixelSize: CGSize       // CGImage pixel dimensions
    let pixelRect: CGRect            // annotation bounds in image-pixel space (top-left origin)
    let pixelationScale: CGFloat
    let viewSize: CGSize             // display size in view points

    var body: some View {
        if let small = makePixelated() {
            Image(nsImage: small)
                .interpolation(.none)
                .resizable()
                .frame(width: viewSize.width, height: viewSize.height)
        } else {
            // Fallback: deterministic checkerboard pattern
            Canvas { ctx, size in
                let bs = max(4.0, min(size.width, size.height) / 14.0)
                var col = 0; var x = 0.0
                while x < size.width {
                    var row = 0; var y = 0.0
                    while y < size.height {
                        let b: CGFloat = (row + col) % 2 == 0 ? 0.55 : 0.38
                        ctx.fill(
                            Path(CGRect(x: x, y: y,
                                        width: min(bs, size.width - x),
                                        height: min(bs, size.height - y))),
                            with: .color(.init(white: b, opacity: 0.75))
                        )
                        row += 1; y += bs
                    }
                    col += 1; x += bs
                }
            }
        }
    }

    /// Crops the source image to `pixelRect` and downscales to blockSize-sized mosaic blocks.
    /// Returns a tiny NSImage; SwiftUI's `.interpolation(.none)` makes it appear blocky.
    private func makePixelated() -> NSImage? {
        guard let img = sourceImage, imagePixelSize.width > 0, imagePixelSize.height > 0 else { return nil }

        // Scale factors from image-pixel space to NSImage point space.
        // NSImage uses bottom-left origin; annotation uses top-left.
        let sx = img.size.width  / imagePixelSize.width
        let sy = img.size.height / imagePixelSize.height

        let fromRect = NSRect(
            x: pixelRect.minX * sx,
            y: img.size.height - pixelRect.maxY * sy,   // flip Y to bottom-left
            width:  pixelRect.width  * sx,
            height: pixelRect.height * sy
        )
        guard fromRect.width > 0, fromRect.height > 0 else { return nil }

        // Destination: one pixel per mosaic block
        let blockSize = max(2, pixelationScale)
        let smallW = max(1, Int(pixelRect.width  / blockSize))
        let smallH = max(1, Int(pixelRect.height / blockSize))

        let small = NSImage(size: NSSize(width: CGFloat(smallW), height: CGFloat(smallH)))
        small.lockFocus()
        img.draw(in: NSRect(x: 0, y: 0, width: CGFloat(smallW), height: CGFloat(smallH)),
                 from: fromRect,
                 operation: .copy,
                 fraction: 1.0)
        small.unlockFocus()
        return small
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
