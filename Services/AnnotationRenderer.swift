import AppKit
import CoreGraphics
import CoreText

/// Renders annotations onto a CGImage for export.
/// All annotation coordinates are in image-pixel space, matching the CGImage dimensions.
class AnnotationRenderer {

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
    /// - Returns: The composited CGImage.
    func render(
        image: CGImage,
        annotations: [Annotation],
        backingScale: CGFloat,
        cropRect: CGRect?
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

        // 2. Now flip the coordinate system for annotation drawing.
        //    Our annotation coordinates use a top-left origin (matching SwiftUI),
        //    so flip so (0,0) is top-left for all annotation operations.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)

        // 3. Draw each annotation
        for annotation in annotations {
            drawAnnotation(annotation, backingScale: backingScale, in: context)
        }

        // 4. Extract full image
        guard let fullImage = context.makeImage() else {
            throw RenderError.cannotCreateOutputImage
        }

        // 5. Crop if needed
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
            drawArrow(from: annotation.startPoint, to: annotation.endPoint, color: color, lineWidth: lineWidth, in: context)
        case .line:
            drawLine(from: annotation.startPoint, to: annotation.endPoint, in: context)
        case .rectangle:
            drawRectangle(annotation.boundingRect, in: context)
        case .circle:
            drawEllipse(in: annotation.boundingRect, in: context)
        case .text:
            drawText(annotation.text, at: annotation.startPoint, style: annotation.style, backingScale: backingScale, in: context)
        case .select, .crop:
            break // Not drawn
        }

        context.restoreGState()
    }

    private func drawArrow(from start: CGPoint, to end: CGPoint, color: CGColor, lineWidth: CGFloat, in context: CGContext) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLength: CGFloat = max(lineWidth * 5, 16)
        let arrowHalfAngle: CGFloat = .pi / 6  // 30 degrees

        // Shorten the line to the arrowhead base (with 1pt overlap to avoid gaps)
        let baseOffset = headLength * cos(arrowHalfAngle) - 1
        let shortenedEnd = CGPoint(
            x: end.x - baseOffset * cos(angle),
            y: end.y - baseOffset * sin(angle)
        )
        context.move(to: start)
        context.addLine(to: shortenedEnd)
        context.strokePath()

        // Draw arrowhead triangle (filled, on top)
        let p1 = CGPoint(
            x: end.x - headLength * cos(angle - arrowHalfAngle),
            y: end.y - headLength * sin(angle - arrowHalfAngle)
        )
        let p2 = CGPoint(
            x: end.x - headLength * cos(angle + arrowHalfAngle),
            y: end.y - headLength * sin(angle + arrowHalfAngle)
        )

        context.setFillColor(color)
        context.move(to: end)
        context.addLine(to: p1)
        context.addLine(to: p2)
        context.closePath()
        context.fillPath()
    }

    private func drawLine(from start: CGPoint, to end: CGPoint, in context: CGContext) {
        context.move(to: start)
        context.addLine(to: end)
        context.strokePath()
    }

    private func drawRectangle(_ rect: CGRect, in context: CGContext) {
        context.stroke(rect)
    }

    private func drawEllipse(in rect: CGRect, in context: CGContext) {
        context.strokeEllipse(in: rect)
    }

    private func drawText(_ text: String, at point: CGPoint, style: AnnotationStyle, backingScale: CGFloat, in context: CGContext) {
        guard !text.isEmpty else { return }

        let fontSize = style.fontSize * backingScale
        let font = CTFontCreateWithName("Helvetica Neue Medium" as CFString, fontSize, nil)
        let bgColor = style.cgTextBubbleBackground

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
        ]

        let attrString = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attrString)
        let textBounds = CTLineGetBoundsWithOptions(line, [])

        let hPad = fontSize * 0.55
        let vPad = fontSize * 0.25
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let textHeight = ascent + descent

        let bgWidth = textBounds.width + hPad * 2
        let bgHeight = textHeight + vPad * 2
        let cornerRadius = bgHeight / 2

        // point is the center of the pill (matching the SwiftUI .position behavior)
        let bgRect = CGRect(
            x: point.x - bgWidth / 2,
            y: point.y - bgHeight / 2,
            width: bgWidth,
            height: bgHeight
        )

        // Draw background pill
        context.saveGState()
        context.setFillColor(bgColor)
        let pillPath = CGPath(roundedRect: bgRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        context.addPath(pillPath)
        context.fillPath()
        context.restoreGState()

        // Draw white text centered in the pill.
        // The context is flipped (top-left origin); un-flip locally for text rendering.
        context.saveGState()
        let textX = bgRect.minX + hPad
        let textY = bgRect.minY + vPad + ascent
        context.translateBy(x: textX, y: textY)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
