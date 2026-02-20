import AppKit
import CoreGraphics

enum TemplateRenderError: LocalizedError {
    case cannotCreateContext
    case cannotLoadCustomImage(path: String)
    case cannotCreateOutputImage

    var errorDescription: String? {
        switch self {
        case .cannotCreateContext:
            return "Failed to create graphics context for template rendering"
        case .cannotLoadCustomImage(let path):
            return "Failed to load custom wallpaper image at: \(path)"
        case .cannotCreateOutputImage:
            return "Failed to create output image from template rendering"
        }
    }
}

class TemplateRenderer {

    func applyTemplate(_ template: ScreenshotTemplate, to screenshot: CGImage, backingScale: CGFloat = 2.0) throws -> CGImage {
        let screenshotWidth = screenshot.width
        let screenshotHeight = screenshot.height

        // Captured images are at native backing scale,
        // so scale the logical-point values to match.
        let padding = Int(CGFloat(template.padding) * backingScale)

        let canvasWidth = screenshotWidth + padding * 2
        let canvasHeight = screenshotHeight + padding * 2

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: canvasWidth,
            height: canvasHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw TemplateRenderError.cannotCreateContext
        }

        let canvasRect = CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight)

        // 1. Draw background
        switch template.wallpaperSource {
        case .builtInGradient(let gradient):
            drawGradient(gradient.gradientDefinition, in: context, rect: canvasRect)
        case .customImage(let path):
            try drawCustomImage(path: path, in: context, rect: canvasRect)
        }

        // 2. Screenshot placement rect
        let screenshotRect = CGRect(
            x: padding,
            y: padding,
            width: screenshotWidth,
            height: screenshotHeight
        )

        // Corner radius scaled to match the screenshot's pixel density
        let cornerRadius = CGFloat(template.cornerRadius) * backingScale

        // 3. Drop shadow behind the screenshot.
        //    When corner radius is applied, the shadow follows the rounded rect.
        //    Otherwise, ScreenCaptureKit's transparent corners give a natural shape.
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -5),
            blur: 25,
            color: CGColor(gray: 0, alpha: 0.2)
        )
        if cornerRadius > 0 {
            // Fill a squircle to generate the shadow shape
            let roundedPath = squirclePath(in: screenshotRect, cornerRadius: cornerRadius)
            context.addPath(roundedPath)
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fillPath()
        } else {
            // Draw the screenshot once with shadow enabled — Core Graphics
            // uses the image's alpha channel to compute the shadow shape.
            context.draw(screenshot, in: screenshotRect)
        }
        context.restoreGState()

        // 4. Draw the screenshot clipped to a rounded rect (if needed).
        if cornerRadius > 0 {
            context.saveGState()
            let clipPath = squirclePath(in: screenshotRect, cornerRadius: cornerRadius)
            context.addPath(clipPath)
            context.clip()
            context.draw(screenshot, in: screenshotRect)
            context.restoreGState()
        } else {
            // No corner radius — draw clean on top of shadow pass.
            context.draw(screenshot, in: screenshotRect)
        }

        // 5. Extract final image
        guard let outputImage = context.makeImage() else {
            throw TemplateRenderError.cannotCreateOutputImage
        }
        return outputImage
    }

    // MARK: - Private

    /// Builds a squircle (continuous-corner / superellipse) path for the given rect.
    ///
    /// Uses Apple's smooth-corner Bézier approximation: the curve starts at
    /// ~60 % of the radius away from the corner midpoint, and the control-point
    /// handle extends ~55 % further.  This matches the shape used in iOS app icons
    /// and macOS rounded-rect variants.
    private func squirclePath(in rect: CGRect, cornerRadius r: CGFloat) -> CGPath {
        // Clamp the radius so it never exceeds half the shortest side.
        let r = min(r, min(rect.width, rect.height) / 2)

        // Magic ratios derived from Apple's continuous-corner specification.
        // `c` is how far along the straight edge the curve begins;
        // `k` is the Bézier handle fraction (relative to r).
        let c: CGFloat = 0.4477  // ≈ 1 - (√2 / 2)  — where the arc departs from the straight side
        let k: CGFloat = 0.5522  // classic circular-approximation handle fraction

        let minX = rect.minX, minY = rect.minY
        let maxX = rect.maxX, maxY = rect.maxY

        let path = CGMutablePath()

        // Top edge — start just right of the top-left corner arc
        path.move(to: CGPoint(x: minX + r, y: minY))

        // Top-right corner
        path.addLine(to: CGPoint(x: maxX - r, y: minY))
        path.addCurve(
            to: CGPoint(x: maxX, y: minY + r),
            control1: CGPoint(x: maxX - r * c, y: minY),
            control2: CGPoint(x: maxX, y: minY + r * c)
        )

        // Right edge
        path.addLine(to: CGPoint(x: maxX, y: maxY - r))

        // Bottom-right corner
        path.addCurve(
            to: CGPoint(x: maxX - r, y: maxY),
            control1: CGPoint(x: maxX, y: maxY - r * c),
            control2: CGPoint(x: maxX - r * c, y: maxY)
        )

        // Bottom edge
        path.addLine(to: CGPoint(x: minX + r, y: maxY))

        // Bottom-left corner
        path.addCurve(
            to: CGPoint(x: minX, y: maxY - r),
            control1: CGPoint(x: minX + r * c, y: maxY),
            control2: CGPoint(x: minX, y: maxY - r * c)
        )

        // Left edge
        path.addLine(to: CGPoint(x: minX, y: minY + r))

        // Top-left corner
        path.addCurve(
            to: CGPoint(x: minX + r, y: minY),
            control1: CGPoint(x: minX, y: minY + r * c),
            control2: CGPoint(x: minX + r * c, y: minY)
        )

        path.closeSubpath()
        return path
    }

    private func drawGradient(
        _ definition: GradientDefinition,
        in context: CGContext,
        rect: CGRect
    ) {
        let cgColors = definition.colors.map { $0.cgColor }
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: cgColors as CFArray,
            locations: nil
        ) else { return }

        let (startPoint, endPoint) = gradientPoints(for: definition.angle, in: rect)
        context.drawLinearGradient(
            gradient,
            start: startPoint,
            end: endPoint,
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
    }

    private func drawCustomImage(
        path: String,
        in context: CGContext,
        rect: CGRect
    ) throws {
        guard let nsImage = NSImage(contentsOfFile: path),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            throw TemplateRenderError.cannotLoadCustomImage(path: path)
        }

        // Aspect-fill: scale the image so it covers the entire rect,
        // then center-crop to the rect.
        let imageWidth = CGFloat(cgImage.width)
        let imageHeight = CGFloat(cgImage.height)
        let imageAspect = imageWidth / imageHeight
        let rectAspect = rect.width / rect.height

        let drawRect: CGRect
        if imageAspect > rectAspect {
            // Image is wider — match height, crop sides
            let scaledWidth = rect.height * imageAspect
            let xOffset = (rect.width - scaledWidth) / 2
            drawRect = CGRect(x: rect.origin.x + xOffset, y: rect.origin.y, width: scaledWidth, height: rect.height)
        } else {
            // Image is taller — match width, crop top/bottom
            let scaledHeight = rect.width / imageAspect
            let yOffset = (rect.height - scaledHeight) / 2
            drawRect = CGRect(x: rect.origin.x, y: rect.origin.y + yOffset, width: rect.width, height: scaledHeight)
        }

        context.saveGState()
        context.clip(to: rect)
        context.draw(cgImage, in: drawRect)
        context.restoreGState()
    }

    private func gradientPoints(
        for angleDegrees: Double,
        in rect: CGRect
    ) -> (CGPoint, CGPoint) {
        let angleRadians = angleDegrees * .pi / 180.0
        let centerX = rect.midX
        let centerY = rect.midY
        let halfWidth = rect.width / 2
        let halfHeight = rect.height / 2

        let dx = cos(angleRadians) * halfWidth
        let dy = sin(angleRadians) * halfHeight

        let start = CGPoint(x: centerX - dx, y: centerY - dy)
        let end   = CGPoint(x: centerX + dx, y: centerY + dy)
        return (start, end)
    }
}
