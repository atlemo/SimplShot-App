import AppKit
import CoreGraphics
import CoreImage
import CoreText

/// Renders annotations onto a CGImage for export.
/// All annotation coordinates are in image-pixel space, matching the CGImage dimensions.
class AnnotationRenderer {

    private lazy var ciContext = CIContext(options: [.useSoftwareRenderer: false])

    enum RenderError: LocalizedError {
        case cannotCreateContext
        case cannotCreateOutputImage
        case cannotCropImage

        var errorDescription: String? {
            switch self {
            case .cannotCreateContext:     return "Failed to create graphics context for annotation rendering"
            case .cannotCreateOutputImage: return "Failed to create output image"
            case .cannotCropImage:         return "Failed to crop image"
            }
        }
    }

    /// Composite annotations onto the base image, optionally cropping.
    /// - Parameters:
    ///   - image: The base screenshot (at full pixel resolution).
    ///   - annotations: Annotations with coordinates in image-pixel space.
    ///   - backingScale: The display backing scale factor (e.g. 2.0 on Retina, 3.0 on 3×).
    ///     Annotation style values (strokeWidth, fontSize) are in logical points and get
    ///     multiplied by this factor to match the image's pixel density.
    ///   - cropRect: Optional crop rect in image-pixel space. `nil` means no crop.
    ///   - watermark: Watermark settings. Applied on top of all annotations.
    /// - Returns: The composited CGImage.
    func render(
        image: CGImage,
        annotations: [Annotation],
        backingScale: CGFloat,
        cropRect: CGRect?,
        watermark: WatermarkSettings = WatermarkSettings()
    ) throws -> CGImage {
        let width = image.width
        let height = image.height

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw RenderError.cannotCreateContext
        }

        // 1. Draw the base image in the default (bottom-left origin) CG space.
        //    CGContext.draw already handles the image orientation correctly here.
        let imageRect = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(image, in: imageRect)

        // 1b. Draw pixelated regions on top of the base image (native CG space, before flip).
        //     Pixelate annotations are rendered here because they need the source pixels.
        for annotation in annotations where annotation.tool == .pixelate {
            drawPixelate(
                annotationRect: annotation.boundingRect,
                scale: annotation.style.pixelationScale,
                from: image,
                imageHeight: height,
                in: context
            )
        }

        // 2. Now flip the coordinate system for annotation drawing.
        //    Our annotation coordinates use a top-left origin (matching SwiftUI),
        //    so flip so (0,0) is top-left for all annotation operations.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)

        let spotlightAnnotations = annotations.filter { $0.tool == .spotlight }
        if !spotlightAnnotations.isEmpty {
            drawSpotlights(
                spotlightAnnotations,
                imageWidth: width,
                imageHeight: height,
                backingScale: backingScale,
                in: context
            )
        }

        // 3. Draw each annotation
        for annotation in annotations {
            if annotation.tool == .spotlight { continue }
            drawAnnotation(annotation, backingScale: backingScale, in: context)
        }

        // 4. Draw watermark on top of all annotations.
        //    Context is in flipped/top-left space, so CGImage drawing needs a local unflip.
        if watermark.isEnabled, let path = watermark.imagePath,
           let nsImage = NSImage(contentsOfFile: path), nsImage.isValid {
            let marginH = CGFloat(width) * 0.02
            let marginV = CGFloat(height) * 0.02
            // widthPx is in logical points; scale to image pixels the same way
            // strokeWidth and fontSize are scaled elsewhere (× backingScale).
            let targetW = max(1, CGFloat(watermark.widthPx) * backingScale)
            let rawSize = nsImage.size
            let aspect = rawSize.height > 0 ? rawSize.width / rawSize.height : 1.0
            let targetH = max(1, targetW / aspect)

            if let wmCG = rasterize(nsImage, size: CGSize(width: targetW, height: targetH)) {
                let x: CGFloat
                let y: CGFloat
                switch watermark.position {
                case .topLeft:
                    x = marginH
                    y = marginV
                case .topRight:
                    x = CGFloat(width) - targetW - marginH
                    y = marginV
                case .bottomLeft:
                    x = marginH
                    y = CGFloat(height) - targetH - marginV
                case .bottomRight:
                    x = CGFloat(width) - targetW - marginH
                    y = CGFloat(height) - targetH - marginV
                }

                context.saveGState()
                context.setAlpha(CGFloat(watermark.opacity))
                // Undo the coordinate flip locally so the CGImage draws right-side up.
                context.translateBy(x: x, y: y + targetH)
                context.scaleBy(x: 1, y: -1)
                context.draw(wmCG, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))
                context.restoreGState()
            }
        }

        // 5. Extract full image
        guard let fullImage = context.makeImage() else {
            throw RenderError.cannotCreateOutputImage
        }

        // 6. Crop if needed
        if let crop = cropRect {
            // crop is in top-left-origin pixel coords.
            // CGImage.cropping(to:) uses top-left origin when the image
            // was produced from a flipped context, but we already flipped
            // during drawing so the image pixels match top-left convention.
            let clampedCrop = crop.intersection(CGRect(x: 0, y: 0, width: width, height: height))
            guard !clampedCrop.isEmpty,
                  let cropped = fullImage.cropping(to: clampedCrop)
            else {
                throw RenderError.cannotCropImage
            }
            return cropped
        }

        return fullImage
    }

    // MARK: - Individual Annotation Drawing

    private func drawAnnotation(_ annotation: Annotation, backingScale: CGFloat, in context: CGContext) {
        let color = annotation.style.cgStrokeColor
        // Style values (strokeWidth, fontSize) are in logical points;
        // multiply by the backing scale to convert to image pixels.
        let lineWidth = annotation.style.strokeWidth * backingScale

        context.saveGState()
        context.setStrokeColor(color)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        switch annotation.tool {
        case .arrow:
            drawArrow(from: annotation.startPoint, to: annotation.endPoint,
                      arrowStyle: annotation.style.arrowStyle, color: color, lineWidth: lineWidth, in: context)
        case .measurement:
            drawMeasurement(
                from: annotation.startPoint,
                to: annotation.endPoint,
                color: color,
                strokeIsLight: annotation.style.isLight,
                lineWidth: lineWidth,
                backingScale: backingScale,
                in: context
            )
        case .freeDraw:
            drawFreeDraw(points: annotation.points, in: context)
        case .line:
            drawLine(from: annotation.startPoint, to: annotation.endPoint, in: context)
        case .rectangle:
            drawRectangle(annotation.boundingRect, filled: annotation.style.fillRect, color: color, backingScale: backingScale, in: context)
        case .circle:
            drawEllipse(in: annotation.boundingRect, filled: annotation.style.fillCircle, color: color, in: context)
        case .text:
            drawText(annotation.text, at: annotation.startPoint, style: annotation.style, backingScale: backingScale, in: context)
        case .spotlight:
            break
        case .numberedStep:
            drawNumberedStep(annotation.stepNumber, at: annotation.startPoint, style: annotation.style, backingScale: backingScale, in: context)
        case .select, .crop, .pixelate:
            break // Not drawn here (.pixelate is handled before the coordinate flip)
        }

        context.restoreGState()
    }

    private func drawArrow(from start: CGPoint, to end: CGPoint, arrowStyle: ArrowStyle, color: CGColor, lineWidth: CGFloat, in context: CGContext) {
        context.setLineCap(.round)
        context.setLineJoin(.round)
        switch arrowStyle {
        case .chevron:  drawArrowChevron(from: start, to: end, lineWidth: lineWidth, in: context)
        case .triangle: drawArrowTriangle(from: start, to: end, color: color, lineWidth: lineWidth, in: context)
        case .curved:   drawArrowCurved(from: start, to: end, color: color, lineWidth: lineWidth, in: context)
        case .sketch:   drawArrowSketch(from: start, to: end, lineWidth: lineWidth, in: context)
        }
    }

    // Open V arrowhead (original style)
    private func drawArrowChevron(from start: CGPoint, to end: CGPoint, lineWidth: CGFloat, in context: CGContext) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLength: CGFloat = max(lineWidth * 5, 16)
        let halfAngle: CGFloat = .pi / 4

        context.move(to: start)
        context.addLine(to: end)
        context.strokePath()

        let p1 = CGPoint(x: end.x - headLength * cos(angle - halfAngle),
                         y: end.y - headLength * sin(angle - halfAngle))
        let p2 = CGPoint(x: end.x - headLength * cos(angle + halfAngle),
                         y: end.y - headLength * sin(angle + halfAngle))
        context.move(to: end); context.addLine(to: p1)
        context.move(to: end); context.addLine(to: p2)
        context.strokePath()
    }

    // Straight shaft + filled solid triangle tip
    private func drawArrowTriangle(from start: CGPoint, to end: CGPoint, color: CGColor, lineWidth: CGFloat, in context: CGContext) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLength: CGFloat = max(lineWidth * 5, 16)
        let halfAngle: CGFloat = .pi / 4

        let p1 = CGPoint(x: end.x - headLength * cos(angle - halfAngle),
                         y: end.y - headLength * sin(angle - halfAngle))
        let p2 = CGPoint(x: end.x - headLength * cos(angle + halfAngle),
                         y: end.y - headLength * sin(angle + halfAngle))
        // Shaft ends at the triangle's base center: tip − headLength·cos(45°)·direction
        let depth = headLength * cos(halfAngle)
        let baseCenter = CGPoint(x: end.x - depth * cos(angle),
                                 y: end.y - depth * sin(angle))
        context.move(to: start)
        context.addLine(to: baseCenter)
        context.strokePath()

        context.setFillColor(color)
        context.move(to: end)
        context.addLine(to: p1)
        context.addLine(to: p2)
        context.closePath()
        context.fillPath()
    }

    // Quadratic-bezier arc shaft + filled triangle aligned to tangent
    private func drawArrowCurved(from start: CGPoint, to end: CGPoint, color: CGColor, lineWidth: CGFloat, in context: CGContext) {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let control = CGPoint(x: (start.x + end.x) / 2 + dy * 0.3,
                              y: (start.y + end.y) / 2 - dx * 0.3)

        // Arrow direction = tangent at t=1 of the bezier = end − control
        let angle = atan2(end.y - control.y, end.x - control.x)
        let headLength: CGFloat = max(lineWidth * 5, 16)
        let halfAngle: CGFloat = .pi / 5   // 36° → 72° total, slightly narrower

        // Shaft ends at the triangle's base center: tip − headLength·cos(halfAngle)·direction
        let depth = headLength * cos(halfAngle)
        let shaftEnd = CGPoint(x: end.x - depth * cos(angle),
                               y: end.y - depth * sin(angle))
        context.move(to: start)
        context.addQuadCurve(to: shaftEnd, control: control)
        context.strokePath()

        let p1 = CGPoint(x: end.x - headLength * cos(angle - halfAngle),
                         y: end.y - headLength * sin(angle - halfAngle))
        let p2 = CGPoint(x: end.x - headLength * cos(angle + halfAngle),
                         y: end.y - headLength * sin(angle + halfAngle))
        context.setFillColor(color)
        context.move(to: end)
        context.addLine(to: p1)
        context.addLine(to: p2)
        context.closePath()
        context.fillPath()
    }

    // Subtle S-curve shaft + wide open chevron (hand-drawn feel)
    private func drawArrowSketch(from start: CGPoint, to end: CGPoint, lineWidth: CGFloat, in context: CGContext) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let len = hypot(end.x - start.x, end.y - start.y)
        let cp1 = CGPoint(x: start.x + cos(angle) * len * 0.3 + (-sin(angle)) * len * 0.07,
                          y: start.y + sin(angle) * len * 0.3 +   cos(angle)  * len * 0.07)
        let cp2 = CGPoint(x: start.x + cos(angle) * len * 0.7 - (-sin(angle)) * len * 0.05,
                          y: start.y + sin(angle) * len * 0.7 -   cos(angle)  * len * 0.05)
        context.move(to: start)
        context.addCurve(to: end, control1: cp1, control2: cp2)
        context.strokePath()

        let headLength: CGFloat = max(lineWidth * 7, 20)
        let halfAngle: CGFloat = .pi / 5   // wider for sketch look
        let p1 = CGPoint(x: end.x - headLength * cos(angle - halfAngle),
                         y: end.y - headLength * sin(angle - halfAngle))
        let p2 = CGPoint(x: end.x - headLength * cos(angle + halfAngle),
                         y: end.y - headLength * sin(angle + halfAngle))
        context.move(to: end); context.addLine(to: p1)
        context.move(to: end); context.addLine(to: p2)
        context.strokePath()
    }

    private func drawLine(from start: CGPoint, to end: CGPoint, in context: CGContext) {
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.move(to: start)
        context.addLine(to: end)
        context.strokePath()
    }

    private func drawMeasurement(from start: CGPoint, to end: CGPoint, color: CGColor, strokeIsLight: Bool, lineWidth: CGFloat, backingScale: CGFloat, in context: CGContext) {
        drawMeasurementLineWithHeads(from: start, to: end, color: color, lineWidth: lineWidth, in: context)

        let pixelDistance = hypot(end.x - start.x, end.y - start.y)
        let true1xDistance = max(0, pixelDistance / max(backingScale, 1))
        let label = "\(Int(true1xDistance.rounded())) px"

        let labelFontSize = max(11 * backingScale, 10)
        let font = CTFontCreateWithName("SFMono-Medium" as CFString, labelFontSize, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: strokeIsLight ? NSColor.black : NSColor.white
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: attrs))
        let bounds = CTLineGetBoundsWithOptions(line, [])

        let hPad = 7 * backingScale
        let vPad = 4 * backingScale
        let bgWidth = bounds.width + hPad * 2
        let bgHeight = bounds.height + vPad * 2
        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let bgRect = CGRect(x: mid.x - bgWidth / 2, y: mid.y - bgHeight / 2, width: bgWidth, height: bgHeight)

        context.saveGState()
        context.setFillColor(color)
        context.addPath(CGPath(roundedRect: bgRect, cornerWidth: bgHeight / 2, cornerHeight: bgHeight / 2, transform: nil))
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        let ascent = CTFontGetAscent(font)
        let textX = bgRect.minX + hPad
        let textY = bgRect.minY + vPad + ascent
        context.translateBy(x: textX, y: textY)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private func drawMeasurementLineWithHeads(from start: CGPoint, to end: CGPoint, color: CGColor, lineWidth: CGFloat, in context: CGContext) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLength: CGFloat = max(lineWidth * 5, 16)
        let arrowHalfAngle: CGFloat = .pi / 6
        let baseOffset = headLength * cos(arrowHalfAngle) - 1

        let trimmedStart = CGPoint(
            x: start.x + baseOffset * cos(angle),
            y: start.y + baseOffset * sin(angle)
        )
        let trimmedEnd = CGPoint(
            x: end.x - baseOffset * cos(angle),
            y: end.y - baseOffset * sin(angle)
        )

        context.setLineDash(phase: 0, lengths: [0, lineWidth * 4])
        drawLine(from: trimmedStart, to: trimmedEnd, in: context)
        context.setLineDash(phase: 0, lengths: [])
        drawMeasurementHead(
            baseCenter: end,
            toward: start,
            color: color,
            headLength: headLength,
            halfAngle: arrowHalfAngle,
            in: context
        )
        drawMeasurementHead(
            baseCenter: start,
            toward: end,
            color: color,
            headLength: headLength,
            halfAngle: arrowHalfAngle,
            in: context
        )
    }

    private func drawMeasurementHead(
        baseCenter: CGPoint,
        toward: CGPoint,
        color: CGColor,
        headLength: CGFloat,
        halfAngle: CGFloat,
        in context: CGContext
    ) {
        let angle = atan2(toward.y - baseCenter.y, toward.x - baseCenter.x)
        let tipOffset = headLength * cos(halfAngle)
        let halfBase = headLength * sin(halfAngle)
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

        context.saveGState()
        context.setFillColor(color)
        context.move(to: b1)
        context.addLine(to: b2)
        context.addLine(to: tip)
        context.closePath()
        context.fillPath()
        context.restoreGState()
    }

    private func drawFreeDraw(points: [CGPoint], in context: CGContext) {
        let processed = smooth(points: points)
        guard let first = processed.first else { return }
        context.setLineCap(.round)
        context.setLineJoin(.round)

        guard processed.count > 1 else {
            context.move(to: first)
            context.addLine(to: first)
            context.strokePath()
            return
        }

        context.move(to: first)
        if processed.count == 2 {
            context.addLine(to: processed[1])
            context.strokePath()
            return
        }

        for i in 1..<(processed.count - 1) {
            let current = processed[i]
            let next = processed[i + 1]
            let mid = CGPoint(x: (current.x + next.x) / 2, y: (current.y + next.y) / 2)
            context.addQuadCurve(to: mid, control: current)
        }
        if let last = processed.last {
            context.addQuadCurve(to: last, control: processed[processed.count - 2])
        }
        context.strokePath()
    }

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

    private func drawRectangle(_ rect: CGRect, filled: Bool, color: CGColor, backingScale: CGFloat, in context: CGContext) {
        let cornerRadius = 6 * backingScale
        let path = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        if filled {
            context.setFillColor(color)
            context.addPath(path)
            context.fillPath()
        }
        context.addPath(path)
        context.strokePath()
    }

    private func drawEllipse(in rect: CGRect, filled: Bool, color: CGColor, in context: CGContext) {
        if filled {
            context.setFillColor(color)
            context.fillEllipse(in: rect)
        }
        context.strokeEllipse(in: rect)
    }

    /// Extracts a region of `sourceImage`, pixelates it with CIPixellate, and draws it back.
    /// `annotationRect` is in top-left image-pixel coordinates (matching annotation storage).
    /// The context must be in its default native (bottom-left origin) CG space — call before flipping.
    private func drawPixelate(annotationRect: CGRect, scale: CGFloat, from sourceImage: CGImage, imageHeight: Int, in context: CGContext) {
        let imageBounds = CGRect(x: 0, y: 0, width: sourceImage.width, height: sourceImage.height)
        let pixelRect = annotationRect.intersection(imageBounds)
        guard !pixelRect.isEmpty else { return }

        // CIImage uses bottom-left origin; convert annotation rect from top-left coords.
        let ciY = CGFloat(imageHeight) - pixelRect.maxY
        let ciRect = CGRect(x: pixelRect.minX, y: ciY, width: pixelRect.width, height: pixelRect.height)

        guard let filter = CIFilter(name: "CIPixellate") else { return }
        let ciImage = CIImage(cgImage: sourceImage).cropped(to: ciRect)
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(CIVector(x: ciRect.midX, y: ciRect.midY), forKey: kCIInputCenterKey)
        filter.setValue(max(2.0, scale) as NSNumber, forKey: kCIInputScaleKey)

        guard let outputCI = filter.outputImage,
              let cgOut = ciContext.createCGImage(outputCI, from: ciRect)
        else { return }

        context.draw(cgOut, in: CGRect(x: pixelRect.minX, y: ciY, width: pixelRect.width, height: pixelRect.height))
    }

    /// Draws a single dimming overlay with one clear cutout per spotlight annotation.
    private func drawSpotlights(
        _ annotations: [Annotation],
        imageWidth: Int,
        imageHeight: Int,
        backingScale: CGFloat,
        in context: CGContext
    ) {
        guard let strongestOpacity = annotations.map(\.style.spotlightOpacity).max() else { return }
        let fullRect = CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight)
        let overlayColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: strongestOpacity)
        let cornerRadius = 6 * backingScale

        context.saveGState()
        let path = CGMutablePath()
        path.addRect(fullRect)
        for annotation in annotations {
            path.addRoundedRect(
                in: annotation.boundingRect,
                cornerWidth: cornerRadius,
                cornerHeight: cornerRadius
            )
        }
        context.addPath(path)
        context.setFillColor(overlayColor)
        context.fillPath(using: .evenOdd)
        context.restoreGState()
    }

    private func drawText(_ text: String, at point: CGPoint, style: AnnotationStyle, backingScale: CGFloat, in context: CGContext) {
        guard !text.isEmpty else { return }

        // fontSize is stored in image-pixel space (like annotation coordinates),
        // so no backingScale multiplication is needed here.
        let fontSize = style.fontSize
        let font = CTFontCreateWithName("Helvetica Neue Medium" as CFString, fontSize, nil)
        let bgColor = style.cgTextBubbleBackground
        let fgColor = style.cgTextBubbleForeground

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: fgColor,
        ]

        // Split on newlines to support multiline text bubbles.
        let lineStrings = text.components(separatedBy: "\n")
        let ctLines = lineStrings.map { CTLineCreateWithAttributedString(NSAttributedString(string: $0, attributes: attributes)) }

        let hPad = fontSize * 0.55
        let vPad = fontSize * 0.25
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let lineHeight = ascent + descent
        let lineSpacing = fontSize * 0.22  // matches EditorCanvasView hit-test estimate

        let maxLineWidth = ctLines.map { CTLineGetBoundsWithOptions($0, []).width }.max() ?? 0
        let lineCount = CGFloat(lineStrings.count)

        let bgWidth = maxLineWidth + hPad * 2
        let bgHeight = lineCount * lineHeight + max(0, lineCount - 1) * lineSpacing + vPad * 2
        let cornerRadius = fontSize * 0.45  // matches SwiftUI RoundedRectangle

        // point is the center of the bubble (matching the SwiftUI .position behavior)
        let bgRect = CGRect(
            x: point.x - bgWidth / 2,
            y: point.y - bgHeight / 2,
            width: bgWidth,
            height: bgHeight
        )

        // Draw background rounded rect
        context.saveGState()
        context.setFillColor(bgColor)
        let pillPath = CGPath(roundedRect: bgRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        context.addPath(pillPath)
        context.fillPath()
        context.restoreGState()

        // Draw each line of text centered horizontally.
        // The context is flipped (top-left origin); un-flip locally for text rendering.
        for (i, ctLine) in ctLines.enumerated() {
            let lineWidth = CTLineGetBoundsWithOptions(ctLine, []).width
            // Center each line within the bubble
            let textX = bgRect.minX + hPad + (maxLineWidth - lineWidth) / 2
            let textY = bgRect.minY + vPad + ascent + CGFloat(i) * (lineHeight + lineSpacing)
            context.saveGState()
            context.translateBy(x: textX, y: textY)
            context.scaleBy(x: 1, y: -1)
            context.textPosition = .zero
            CTLineDraw(ctLine, context)
            context.restoreGState()
        }
    }

    // MARK: - Watermark Helpers

    /// Renders an NSImage (SVG, PNG, JPG) into a CGImage at exactly `size` pixels.
    /// Using NSGraphicsContext ensures SVG is rasterized at the target resolution.
    private func rasterize(_ nsImage: NSImage, size: CGSize) -> CGImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        nsImage.draw(in: NSRect(origin: .zero, size: size),
                     from: .zero,
                     operation: .copy,
                     fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    private func drawNumberedStep(_ number: Int, at point: CGPoint, style: AnnotationStyle, backingScale: CGFloat, in context: CGContext) {
        let fontSize = style.fontSize
        let radius = fontSize * 0.7
        let color = style.cgStrokeColor

        // Draw filled circle
        let circleRect = CGRect(
            x: point.x - radius,
            y: point.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        context.saveGState()
        context.setFillColor(color)
        context.fillEllipse(in: circleRect)
        context.restoreGState()

        // Draw number text centered in the circle
        let labelFontSize = fontSize * 0.75
        let font = CTFontCreateWithName("SFProRounded-Bold" as CFString, labelFontSize, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: style.cgTextBubbleForeground,
        ]
        let label = "\(number)"
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: attrs))
        let bounds = CTLineGetBoundsWithOptions(line, [])
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)

        let textX = point.x - bounds.width / 2
        let textY = point.y + (ascent - descent) / 2

        context.saveGState()
        context.translateBy(x: textX, y: textY)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
