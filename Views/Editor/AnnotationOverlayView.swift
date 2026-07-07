import SwiftUI

/// Renders a single annotation shape in view coordinates.
/// The parent is responsible for mapping image-pixel coords → view coords via `scale`.
struct AnnotationOverlayView: View {
    let annotation: Annotation
    let scale: CGFloat         // view points per image pixel
    let displayBackingScale: CGFloat // monitor backing scale (e.g. 2.0 on Retina)
    /// Image pixel-density multiplier (1 for 72-DPI, 2 for 144-DPI Retina, …).
    /// Applied to style dimensions so strokes/fonts stay proportional to the
    /// denser pixels — NOT to positions. Mirrors AnnotationRenderer.styleScale.
    var dpiScaleFactor: CGFloat = 1

    /// View points per image-pixel for *dimensions* (stroke width, font size,
    /// corner radii, feather). Positions use `scale`; dimensions use this so a
    /// 2× image renders thicker strokes, matching the export.
    private var dimScale: CGFloat { scale * dpiScaleFactor }
    let isSelected: Bool
    var suppressSpotlightShape: Bool = false
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

    /// Stroke width in view points, scaled by the zoom level.
    /// At true size (scale = 1.0), annotation strokes appear at their logical size.
    private var displayStrokeWidth: CGFloat {
        annotation.style.strokeWidth * dimScale
    }

    @ViewBuilder
    private var annotationShape: some View {
        let start = scaled(annotation.startPoint)
        let end = scaled(annotation.endPoint)
        let rect = scaledBoundingRect

        switch annotation.tool {
        case .arrow:
            let sw   = displayStrokeWidth
            let col  = annotation.style.strokeColor
            let ss   = StrokeStyle(lineWidth: sw, lineCap: .round, lineJoin: .round)
            if annotation.style.arrowStyle.supportsCurvature {
                // Curved/double: build the single fill path in IMAGE space with
                // the image-space line width, then scale to view points — the
                // exact path the export renderer fills, so parity is structural.
                let imagePath = ArrowGeometry.fillPath(
                    start: annotation.startPoint,
                    end: annotation.endPoint,
                    curvature: annotation.arrowCurvature,
                    doubleEnded: annotation.style.arrowStyle == .double,
                    lineWidth: annotation.style.strokeWidth * dpiScaleFactor
                )
                Path(imagePath)
                    .applying(CGAffineTransform(scaleX: scale, y: scale))
                    .fill(col)
            } else if annotation.style.arrowStyle == .sketch {
                // Gritty ink ribbon — same image-space path as the export.
                let imagePath = ArrowGeometry.sketchPath(
                    start: annotation.startPoint,
                    end: annotation.endPoint,
                    lineWidth: annotation.style.strokeWidth * dpiScaleFactor,
                    seed: annotation.sketchSeed
                )
                Path(imagePath)
                    .applying(CGAffineTransform(scaleX: scale, y: scale))
                    .fill(col)
            } else if annotation.style.arrowStyle == .triangle {
                // Shaft ends at the triangle's base center: tip − headLen·cos(halfAngle)·direction
                let angle = atan2(end.y - start.y, end.x - start.x)
                let headLen = arrowHeadLen(for: sw)
                let depth = headLen * cos(CGFloat.pi / 4)   // ≈ 0.707 × headLen
                let base = CGPoint(x: end.x - depth * cos(angle),
                                   y: end.y - depth * sin(angle))
                ArrowShape(start: start, end: base, lineWidth: sw).stroke(col, style: ss)
                ArrowFilledTriangleHead(start: start, end: end, lineWidth: sw).fill(col)
            } else {
                // .chevron (default)
                ArrowShape(start: start, end: end, lineWidth: sw).stroke(col, style: ss)
                ArrowHeadShape(start: start, end: end, lineWidth: sw).stroke(col, style: ss)
            }

        case .measurement:
            MeasurementLineShape(start: start, end: end, lineWidth: displayStrokeWidth)
            .stroke(
                annotation.style.strokeColor,
                style: StrokeStyle(
                    lineWidth: displayStrokeWidth,
                    lineCap: .butt,
                    lineJoin: .round,
                    dash: [displayStrokeWidth * 3, displayStrokeWidth * 2]
                )
            )
            MeasurementHeadShape(baseCenter: end, toward: start, lineWidth: displayStrokeWidth)
                .fill(annotation.style.strokeColor)
            MeasurementHeadShape(baseCenter: start, toward: end, lineWidth: displayStrokeWidth)
                .fill(annotation.style.strokeColor)
            measurementLabel(start: start, end: end)

        case .angle:
            // Protractor: geometry built in image space via AngleGeometry (the
            // same paths the export fills/strokes), scaled to view points.
            let a = annotation.startPoint
            let v = annotation.angleVertex
            let b = annotation.endPoint
            let lwImage = annotation.style.strokeWidth * dpiScaleFactor
            let tf = CGAffineTransform(scaleX: scale, y: scale)
            let col = annotation.style.strokeColor
            let radius = AngleGeometry.arcRadius(a: a, vertex: v, b: b, lineWidth: lwImage)
            Path(AngleGeometry.raysPath(a: a, vertex: v, b: b))
                .applying(tf)
                .stroke(col, style: StrokeStyle(lineWidth: displayStrokeWidth, lineCap: .round, lineJoin: .round))
            Path(AngleGeometry.arcPath(a: a, vertex: v, b: b, radius: radius))
                .applying(tf)
                .stroke(col, style: StrokeStyle(
                    lineWidth: displayStrokeWidth * 0.7,
                    lineCap: .butt,
                    lineJoin: .round,
                    // Must match the export's setLineDash([lw*2, lw*1.6]) —
                    // displayStrokeWidth is the image-space lineWidth × scale.
                    dash: [displayStrokeWidth * 2, displayStrokeWidth * 1.6]
                ))
            Path(AngleGeometry.dotsPath(a: a, vertex: v, b: b, lineWidth: lwImage))
                .applying(tf)
                .fill(col)
            angleLabel(a: a, vertex: v, b: b, radius: radius)

        case .freeDraw:
            FreeDrawShape(points: annotation.points.map(scaled))
                .stroke(
                    annotation.style.strokeColor,
                    style: StrokeStyle(
                        lineWidth: displayStrokeWidth,
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
                    lineWidth: displayStrokeWidth,
                    lineCap: .round,
                    lineJoin: .round
                )
            )

        case .rectangle:
            // Corner radius scales with zoom and image DPI (matches export's
            // `6 * styleScale`).
            let rectCorner = 6 * dimScale
            RoundedRectangle(cornerRadius: rectCorner)
                .fill(annotation.style.fillColor ?? Color.clear)
                .overlay(RoundedRectangle(cornerRadius: rectCorner).stroke(annotation.style.strokeColor, lineWidth: displayStrokeWidth))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)

        case .circle:
            Ellipse()
                .fill(annotation.style.fillColor ?? Color.clear)
                .overlay(Ellipse().stroke(annotation.style.strokeColor, lineWidth: displayStrokeWidth))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)

        case .triangle:
            TriangleShape()
                .fill(annotation.style.fillColor ?? Color.clear)
                .overlay(TriangleShape().stroke(annotation.style.strokeColor,
                    style: StrokeStyle(lineWidth: displayStrokeWidth, lineJoin: .round)))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)

        case .star:
            StarShape()
                .fill(annotation.style.fillColor ?? Color.clear)
                .overlay(StarShape().stroke(annotation.style.strokeColor,
                    style: StrokeStyle(lineWidth: displayStrokeWidth, lineJoin: .round)))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)

        case .text:
            let scaledFontSize = annotation.style.fontSize * scale
            let cornerRadius = scaledFontSize * 0.45
            let borderWidth = max(2, 2 * scale)
            let hPad = scaledFontSize * 0.55
            let hasFixedWidth = annotation.style.textWidth != nil
            let innerWidth: CGFloat? = annotation.style.textWidth.map { $0 * scale - hPad * 2 }
            Group {
                if let iw = innerWidth {
                    Text(annotation.text)
                        .multilineTextAlignment(.center)
                        .frame(width: max(iw, scaledFontSize))
                } else {
                    let textLines = annotation.text.components(separatedBy: "\n")
                    VStack(alignment: .center, spacing: scaledFontSize * 0.22) {
                        ForEach(textLines.indices, id: \.self) { i in
                            Text(textLines[i].isEmpty ? " " : textLines[i])
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                }
            }
            .font(.system(size: scaledFontSize, weight: .medium))
            .foregroundColor(annotation.style.textBubbleForeground)
            .padding(.horizontal, hPad)
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
            .fixedSize(horizontal: !hasFixedWidth, vertical: false)
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

        case .spotlight:
            if suppressSpotlightShape {
                EmptyView()
            } else {
                let fullW = imagePixelSize.width * scale
                let fullH = imagePixelSize.height * scale
                // Feather + corner are style dims → dimScale (matches export's
                // `feather * styleScale` / `6 * styleScale`); canvas size uses scale.
                let blurRadius = annotation.style.spotlightFeather * dimScale
                SpotlightOverlayShape(
                    cutouts: [rect],
                    canvasSize: CGSize(width: fullW, height: fullH),
                    cornerRadius: 6 * dimScale,
                    outsetForBlur: blurRadius * 3
                )
                .fill(Color.black.opacity(annotation.style.spotlightOpacity), style: FillStyle(eoFill: true))
                .blur(radius: blurRadius)
                .frame(width: fullW, height: fullH)
                .clipped()
                .position(x: fullW / 2, y: fullH / 2)
            }

        case .numberedStep:
            let scaledFontSize = annotation.style.fontSize * scale
            let radius = scaledFontSize * 0.7
            let diameter = radius * 2
            let borderWidth = max(2, 2 * scale)
            ZStack {
                Circle()
                    .fill(annotation.style.strokeColor)
                    .frame(width: diameter, height: diameter)
                    .overlay(
                        Circle()
                            .stroke(isSelected ? Color.white : Color.clear, lineWidth: borderWidth)
                    )
                    .padding(isSelected ? borderWidth : 0)
                    .overlay(
                        Circle()
                            .stroke(isSelected ? annotation.style.strokeColor : Color.clear, lineWidth: borderWidth)
                    )
                Text("\(annotation.stepNumber)")
                    .font(.system(size: scaledFontSize * 0.75, weight: .bold, design: .rounded))
                    .foregroundColor(annotation.style.textBubbleForeground)
            }
            .position(x: start.x, y: start.y)

        case .select, .textSelect, .crop:
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
            if annotation.tool == .arrow, annotation.style.arrowStyle.supportsCurvature {
                CurveHandleDot(center: scaled(annotation.arrowMidPoint))
            }

        case .angle:
            HandleDot(center: start)
            HandleDot(center: end)
            HandleDot(center: scaled(annotation.angleVertex))

        case .rectangle, .circle, .triangle, .star, .pixelate, .spotlight:
            let rect = scaledBoundingRect
            HandleDot(center: CGPoint(x: rect.minX, y: rect.minY))
            HandleDot(center: CGPoint(x: rect.maxX, y: rect.minY))
            HandleDot(center: CGPoint(x: rect.minX, y: rect.maxY))
            HandleDot(center: CGPoint(x: rect.maxX, y: rect.maxY))

        case .text:
            let fs = annotation.style.fontSize * scale
            let hPad = fs * 0.55
            let bubbleW: CGFloat = {
                if let fixedW = annotation.style.textWidth { return fixedW * scale }
                let lines = annotation.text.components(separatedBy: .newlines)
                let font = NSFont.systemFont(ofSize: fs, weight: .medium)
                let attrs: [NSAttributedString.Key: Any] = [.font: font]
                let maxLineW = lines.map { ($0.isEmpty ? " " : $0 as NSString).size(withAttributes: attrs).width }.max() ?? 0
                return maxLineW + hPad * 2
            }()
            let cx = annotation.startPoint.x * scale
            let cy = annotation.startPoint.y * scale
            HandleDot(center: CGPoint(x: cx - bubbleW / 2, y: cy))
            HandleDot(center: CGPoint(x: cx + bubbleW / 2, y: cy))

        case .freeDraw, .numberedStep:
            EmptyView()

        case .select, .textSelect, .crop:
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

    /// Degree pill centered ON the arc (bisector at arc radius), capping the
    /// dashed arc. Sizing mirrors measurementLabel / drawPillLabel.
    @ViewBuilder
    private func angleLabel(a: CGPoint, vertex: CGPoint, b: CGPoint, radius: CGFloat) -> some View {
        let f = dimScale * AnnotationRenderer.measurementFontScale(strokeWidth: annotation.style.strokeWidth)
        let center = AngleGeometry.labelCenter(a: a, vertex: vertex, b: b,
                                               radius: radius, labelDistance: 0)
        Text("\(AngleGeometry.degrees(a: a, vertex: vertex, b: b))°")
            .font(.system(size: 11 * f, weight: .medium, design: .monospaced))
            .foregroundStyle(annotation.style.isLight ? Color.black : Color.white)
            .padding(.horizontal, 7 * f)
            .padding(.vertical, 4 * f)
            .background(annotation.style.strokeColor, in: Capsule())
            .position(x: center.x * scale, y: center.y * scale)
    }

    @ViewBuilder
    private func measurementLabel(start: CGPoint, end: CGPoint) -> some View {
        let pixelDistance = hypot(annotation.endPoint.x - annotation.startPoint.x, annotation.endPoint.y - annotation.startPoint.y)
        let label = "\(Int(pixelDistance.rounded())) px"
        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        // Font/pad: gentle growth with stroke width (shared with export), then
        // × dimScale for zoom + image DPI. Must match AnnotationRenderer.drawMeasurement.
        let f = dimScale * AnnotationRenderer.measurementFontScale(strokeWidth: annotation.style.strokeWidth)
        Text(label)
            .font(.system(size: 11 * f, weight: .medium, design: .monospaced))
            .foregroundStyle(annotation.style.isLight ? Color.black : Color.white)
            .padding(.horizontal, 7 * f)
            .padding(.vertical, 4 * f)
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

// MARK: - Arrow style: filled triangle head (used by .triangle)

struct ArrowFilledTriangleHead: Shape {
    let start: CGPoint
    let end: CGPoint
    let lineWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLen = arrowHeadLen(for: lineWidth)
        let halfAngle: CGFloat = .pi / 4
        let p1 = CGPoint(x: end.x - headLen * cos(angle - halfAngle),
                         y: end.y - headLen * sin(angle - halfAngle))
        let p2 = CGPoint(x: end.x - headLen * cos(angle + halfAngle),
                         y: end.y - headLen * sin(angle + halfAngle))
        return Path { p in
            p.move(to: end)
            p.addLine(to: p1)
            p.addLine(to: p2)
            p.closeSubpath()
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

// MARK: - Triangle Shape

struct TriangleShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.midX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.closeSubpath()
        }
    }
}

// MARK: - Star Shape

struct StarShape: Shape {
    func path(in rect: CGRect) -> Path {
        let cx = rect.midX
        let cy = rect.midY
        let outerR = min(rect.width, rect.height) / 2
        let innerR = outerR * 0.4
        let points = 5
        return Path { p in
            for i in 0..<(points * 2) {
                let angle = CGFloat(i) * .pi / CGFloat(points) - .pi / 2
                let r = i.isMultiple(of: 2) ? outerR : innerR
                let pt = CGPoint(x: cx + r * cos(angle), y: cy + r * sin(angle))
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            p.closeSubpath()
        }
    }
}

// MARK: - Spotlight Overlay Shape

/// A shape that fills the entire canvas except for a rectangular cutout (even-odd fill).

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

    // Cache key: rounded pixelRect + pixelationScale to avoid re-rendering on sub-pixel drag jitter
    @State private var cachedImage: NSImage?
    @State private var cacheKey: String = ""

    var body: some View {
        let key = "\(Int(pixelRect.minX)),\(Int(pixelRect.minY)),\(Int(pixelRect.width)),\(Int(pixelRect.height)),\(Int(pixelationScale))"
        if let cached = cachedImage, cacheKey == key {
            Image(nsImage: cached)
                .interpolation(.none)
                .resizable()
                .frame(width: viewSize.width, height: viewSize.height)
        } else if let small = makePixelated() {
            Image(nsImage: small)
                .interpolation(.none)
                .resizable()
                .frame(width: viewSize.width, height: viewSize.height)
                .onAppear {
                    cachedImage = small
                    cacheKey = key
                }
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

// MARK: - Committed Annotations (Isolated Subview)

/// Displays all committed (non-dragging, non-editing) annotations.
/// Extracted into its own view so SwiftUI can skip re-evaluation during drag:
/// `draggingAnnotation` (which changes every frame) is NOT an input here —
/// only the stable `excludeDraggingID` (set once at drag start) is used.
struct CommittedAnnotationsView: Equatable, View {
    let annotations: [Annotation]
    let excludeEditingID: UUID?
    let excludeDraggingID: UUID?
    let selectedAnnotationID: UUID?
    let scale: CGFloat
    let displayBackingScale: CGFloat
    var dpiScaleFactor: CGFloat = 1
    let sourceImage: NSImage?
    let imagePixelSize: CGSize

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.annotations == rhs.annotations
        && lhs.excludeEditingID == rhs.excludeEditingID
        && lhs.excludeDraggingID == rhs.excludeDraggingID
        && lhs.selectedAnnotationID == rhs.selectedAnnotationID
        && lhs.scale == rhs.scale
        && lhs.displayBackingScale == rhs.displayBackingScale
        && lhs.dpiScaleFactor == rhs.dpiScaleFactor
        && lhs.sourceImage === rhs.sourceImage
        && lhs.imagePixelSize == rhs.imagePixelSize
    }

    var body: some View {
        let visibleAnnotations = annotations.filter { $0.id != excludeEditingID && $0.id != excludeDraggingID }
        let spotlightAnnotations = visibleAnnotations.filter { $0.tool == .spotlight }

        // Pixelate annotations render below the spotlight dim so they appear
        // as part of the image content being highlighted/dimmed.
        ForEach(visibleAnnotations.filter { $0.tool == .pixelate }) { annotation in
            AnnotationOverlayView(
                annotation: annotation,
                scale: scale,
                displayBackingScale: displayBackingScale,
                dpiScaleFactor: dpiScaleFactor,
                isSelected: annotation.id == selectedAnnotationID,
                suppressSpotlightShape: false,
                sourceImage: sourceImage,
                imagePixelSize: imagePixelSize
            )
            .allowsHitTesting(false)
        }

        if !spotlightAnnotations.isEmpty {
            SharedSpotlightOverlay(
                annotations: spotlightAnnotations,
                scale: scale,
                displayBackingScale: displayBackingScale,
                dpiScaleFactor: dpiScaleFactor,
                imagePixelSize: imagePixelSize
            )
            .allowsHitTesting(false)
        }

        ForEach(visibleAnnotations.filter { $0.tool != .pixelate }) { annotation in
            AnnotationOverlayView(
                annotation: annotation,
                scale: scale,
                displayBackingScale: displayBackingScale,
                dpiScaleFactor: dpiScaleFactor,
                isSelected: annotation.id == selectedAnnotationID,
                suppressSpotlightShape: annotation.tool == .spotlight,
                sourceImage: nil,
                imagePixelSize: imagePixelSize
            )
            .allowsHitTesting(false)
        }
    }
}

private struct SharedSpotlightOverlay: View {
    let annotations: [Annotation]
    let scale: CGFloat
    let displayBackingScale: CGFloat
    var dpiScaleFactor: CGFloat = 1
    let imagePixelSize: CGSize

    private var dimScale: CGFloat { scale * dpiScaleFactor }

    var body: some View {
        let fullW = imagePixelSize.width * scale
        let fullH = imagePixelSize.height * scale
        let cutouts = annotations.map { annotation in
            let rect = annotation.boundingRect
            return CGRect(
                x: rect.origin.x * scale,
                y: rect.origin.y * scale,
                width: rect.width * scale,
                height: rect.height * scale
            )
        }
        let feather = annotations.map(\.style.spotlightFeather).max() ?? 0
        // Feather + corner are style dims → dimScale (matches export's
        // `feather * styleScale` / `6 * styleScale`); cutouts/canvas use scale.
        let blurRadius = feather * dimScale

        SpotlightOverlayShape(
            cutouts: cutouts,
            canvasSize: CGSize(width: fullW, height: fullH),
            cornerRadius: 6 * dimScale,
            outsetForBlur: blurRadius * 3
        )
        .fill(
            Color.black.opacity(Double(annotations.map(\.style.spotlightOpacity).max() ?? 0.5)),
            style: FillStyle(eoFill: true)
        )
        .blur(radius: blurRadius)
        .frame(width: fullW, height: fullH)
        .clipped()
        .position(x: fullW / 2, y: fullH / 2)
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

/// Mid-curve handle for curved/double arrows — inverse colors of HandleDot so
/// it reads as "bend the arrow" rather than "move an endpoint".
struct CurveHandleDot: View {
    let center: CGPoint
    let size: CGFloat = 9

    var body: some View {
        Circle()
            .fill(Color.accentColor)
            .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
            .frame(width: size, height: size)
            .position(center)
    }
}

private struct SpotlightOverlayShape: Shape {
    let cutouts: [CGRect]
    let canvasSize: CGSize
    let cornerRadius: CGFloat
    var outsetForBlur: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let outerRect = CGRect(origin: .zero, size: canvasSize).insetBy(dx: -outsetForBlur, dy: -outsetForBlur)
        path.addRect(outerRect)
        for cutout in cutouts {
            path.addRoundedRect(
                in: cutout,
                cornerSize: CGSize(width: cornerRadius, height: cornerRadius)
            )
        }
        return path
    }
}
