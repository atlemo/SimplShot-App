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

    func applyTemplate(
        _ template: ScreenshotTemplate,
        to screenshot: CGImage,
        backingScale: CGFloat = 2.0,
        targetAspectRatio: Double? = nil,
        shadowIntensity: Double = 1.0,
        alignment: CanvasAlignment = .middleCenter
    ) throws -> CGImage {
        let screenshotWidth = screenshot.width
        let screenshotHeight = screenshot.height

        // Captured images are at native backing scale,
        // so scale the logical-point values to match.
        let padding = Int(CGFloat(template.padding) * backingScale)

        let baseCanvasWidth = screenshotWidth + padding * 2
        let baseCanvasHeight = screenshotHeight + padding * 2
        let (canvasWidth, canvasHeight) = canvasSize(
            baseWidth: baseCanvasWidth,
            baseHeight: baseCanvasHeight,
            targetAspectRatio: targetAspectRatio
        )

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

        // 2. Screenshot placement rect — position within canvas using alignment.
        //    The full remaining space is distributed by the alignment fraction:
        //    at an edge the screenshot sits flush (zero margin on that side);
        //    at center it gets equal margins; fraction handles the continuum.
        let totalSpaceX = CGFloat(canvasWidth) - CGFloat(screenshotWidth)
        let totalSpaceY = CGFloat(canvasHeight) - CGFloat(screenshotHeight)
        let screenshotRect = CGRect(
            x: totalSpaceX * alignment.horizontalFraction,
            y: totalSpaceY * (1 - alignment.verticalFraction), // CG y=0 is bottom
            width: CGFloat(screenshotWidth),
            height: CGFloat(screenshotHeight)
        )

        // Corner radius scaled to match the screenshot's pixel density
        let cornerRadius = CGFloat(template.cornerRadius) * backingScale

        // Corners that sit flush against a canvas edge get zero radius.
        let isFlushLeft   = alignment.horizontalFraction == 0
        let isFlushRight  = alignment.horizontalFraction == 1
        let isFlushTop    = alignment.verticalFraction == 0
        let isFlushBottom = alignment.verticalFraction == 1
        let rTL = (isFlushLeft || isFlushTop)    ? 0 : cornerRadius
        let rTR = (isFlushRight || isFlushTop)   ? 0 : cornerRadius
        let rBL = (isFlushLeft || isFlushBottom)  ? 0 : cornerRadius
        let rBR = (isFlushRight || isFlushBottom) ? 0 : cornerRadius
        let anyRounded = rTL > 0 || rTR > 0 || rBL > 0 || rBR > 0

        // 3. Drop shadow behind the screenshot.
        //    When corner radius is applied, the shadow follows the rounded rect.
        //    Otherwise, ScreenCaptureKit's transparent corners give a natural shape.
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -5),
            blur: 25,
            color: CGColor(gray: 0, alpha: 0.2 * shadowIntensity)
        )
        if anyRounded {
            // Fill a squircle to generate the shadow shape
            let roundedPath = squirclePath(in: screenshotRect, topLeft: rTL, topRight: rTR, bottomLeft: rBL, bottomRight: rBR)
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
        if anyRounded {
            // Pre-process: eliminate native macOS rounded-corner transparency
            // by sampling edge colors and filling the corner regions before
            // compositing. This makes the image fully opaque so the squircle
            // clip produces perfectly clean corners.
            let opaqueScreenshot = flattenNativeCorners(screenshot, backingScale: backingScale)

            context.saveGState()
            let clipPath = squirclePath(in: screenshotRect, topLeft: rTL, topRight: rTR, bottomLeft: rBL, bottomRight: rBR)
            context.addPath(clipPath)
            context.clip()
            context.draw(opaqueScreenshot, in: screenshotRect)
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

    private func canvasSize(baseWidth: Int, baseHeight: Int, targetAspectRatio: Double?) -> (Int, Int) {
        guard let ratio = targetAspectRatio, ratio > 0 else {
            return (baseWidth, baseHeight)
        }

        let w = CGFloat(baseWidth)
        let h = CGFloat(baseHeight)
        let current = w / h

        if current < CGFloat(ratio) {
            // Too tall for target ratio -> widen canvas
            return (Int(ceil(h * CGFloat(ratio))), baseHeight)
        } else if current > CGFloat(ratio) {
            // Too wide for target ratio -> increase height
            return (baseWidth, Int(ceil(w / CGFloat(ratio))))
        }
        return (baseWidth, baseHeight)
    }

    // MARK: - Private

    /// Builds a squircle (continuous-corner / superellipse) path with per-corner radii.
    ///
    /// Uses Apple's smooth-corner Bézier approximation. Corner names are in screen space
    /// (y=0 at top); CG coordinates are handled internally.
    /// Pass 0 for a corner to make it a sharp right angle (flush edge).
    private func squirclePath(
        in rect: CGRect,
        topLeft rTL: CGFloat,
        topRight rTR: CGFloat,
        bottomLeft rBL: CGFloat,
        bottomRight rBR: CGFloat
    ) -> CGPath {
        let maxR = min(rect.width, rect.height) / 2
        let rTL = min(rTL, maxR), rTR = min(rTR, maxR)
        let rBL = min(rBL, maxR), rBR = min(rBR, maxR)

        let c: CGFloat = 0.4477  // continuous-corner Bézier handle ratio

        let minX = rect.minX, minY = rect.minY
        let maxX = rect.maxX, maxY = rect.maxY

        let path = CGMutablePath()

        // The path traverses clockwise starting from the bottom edge (minY in CG = screen bottom).
        // CG y=0 is at screen bottom, so maxY = screen top.

        // Start: bottom edge near bottom-left
        path.move(to: CGPoint(x: minX + rBL, y: minY))

        // Bottom edge → bottom-right corner (screen)
        path.addLine(to: CGPoint(x: maxX - rBR, y: minY))
        if rBR > 0 {
            path.addCurve(
                to: CGPoint(x: maxX, y: minY + rBR),
                control1: CGPoint(x: maxX - rBR * c, y: minY),
                control2: CGPoint(x: maxX, y: minY + rBR * c)
            )
        }

        // Right edge → top-right corner (screen)
        path.addLine(to: CGPoint(x: maxX, y: maxY - rTR))
        if rTR > 0 {
            path.addCurve(
                to: CGPoint(x: maxX - rTR, y: maxY),
                control1: CGPoint(x: maxX, y: maxY - rTR * c),
                control2: CGPoint(x: maxX - rTR * c, y: maxY)
            )
        }

        // Top edge → top-left corner (screen)
        path.addLine(to: CGPoint(x: minX + rTL, y: maxY))
        if rTL > 0 {
            path.addCurve(
                to: CGPoint(x: minX, y: maxY - rTL),
                control1: CGPoint(x: minX + rTL * c, y: maxY),
                control2: CGPoint(x: minX, y: maxY - rTL * c)
            )
        }

        // Left edge → bottom-left corner (screen)
        path.addLine(to: CGPoint(x: minX, y: minY + rBL))
        if rBL > 0 {
            path.addCurve(
                to: CGPoint(x: minX + rBL, y: minY),
                control1: CGPoint(x: minX, y: minY + rBL * c),
                control2: CGPoint(x: minX + rBL * c, y: minY)
            )
        }

        path.closeSubpath()
        return path
    }

    /// Convenience: uniform radius on all four corners.
    private func squirclePath(in rect: CGRect, cornerRadius r: CGFloat) -> CGPath {
        squirclePath(in: rect, topLeft: r, topRight: r, bottomLeft: r, bottomRight: r)
    }

    /// Makes the screenshot fully opaque by sampling edge colors near each corner
    /// and filling the native macOS rounded-corner transparent area with those colors.
    /// The screenshot is then composited on top, so the semi-transparent corner pixels
    /// blend against a matching color instead of showing black/transparent artifacts.
    private func flattenNativeCorners(_ image: CGImage, backingScale: CGFloat) -> CGImage {
        let width = image.width
        let height = image.height
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()

        // 1. Draw into a premultiplied context so we can sample pixel colors.
        guard let sampleCtx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }

        let imageRect = CGRect(x: 0, y: 0, width: width, height: height)
        sampleCtx.draw(image, in: imageRect)

        guard let data = sampleCtx.data else { return image }
        let bytesPerRow = sampleCtx.bytesPerRow

        let nativeRadius = Int(ceil(20.0 * backingScale))
        let edgeInset = nativeRadius + 2

        func sampleColor(x: Int, y: Int) -> (CGFloat, CGFloat, CGFloat) {
            let cx = max(0, min(x, width - 1))
            let cy = max(0, min(y, height - 1))
            let offset = cy * bytesPerRow + cx * 4
            let ptr = data.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
            let a = CGFloat(ptr[3]) / 255.0
            guard a > 0 else { return (0, 0, 0) }
            return (CGFloat(ptr[0]) / 255.0 / a,
                    CGFloat(ptr[1]) / 255.0 / a,
                    CGFloat(ptr[2]) / 255.0 / a)
        }

        // Sample 1px from each edge, past the transparent corner arc.
        let topLeft     = sampleColor(x: 1, y: edgeInset)
        let topRight    = sampleColor(x: width - 2, y: edgeInset)
        let bottomLeft  = sampleColor(x: 1, y: height - 1 - edgeInset)
        let bottomRight = sampleColor(x: width - 2, y: height - 1 - edgeInset)

        // 2. Create an OPAQUE context (noneSkipLast = no alpha channel).
        //    Drawing the semi-transparent image into this context automatically
        //    composites against the background fills — no per-pixel loop needed.
        guard let opaqueCtx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            return image
        }

        // Fill full-width edge strips so the entire perimeter has the
        // correct color behind any native-corner transparency.
        let nr = CGFloat(nativeRadius)
        let w = CGFloat(width)
        let h = CGFloat(height)
        let halfW = w / 2

        // Top strip — left half uses topLeft color, right half uses topRight
        // (CG coordinates: high y = screen top)
        opaqueCtx.setFillColor(red: topLeft.0, green: topLeft.1, blue: topLeft.2, alpha: 1.0)
        opaqueCtx.fill(CGRect(x: 0, y: h - nr, width: halfW, height: nr))
        opaqueCtx.setFillColor(red: topRight.0, green: topRight.1, blue: topRight.2, alpha: 1.0)
        opaqueCtx.fill(CGRect(x: halfW, y: h - nr, width: halfW, height: nr))

        // Bottom strip
        opaqueCtx.setFillColor(red: bottomLeft.0, green: bottomLeft.1, blue: bottomLeft.2, alpha: 1.0)
        opaqueCtx.fill(CGRect(x: 0, y: 0, width: halfW, height: nr))
        opaqueCtx.setFillColor(red: bottomRight.0, green: bottomRight.1, blue: bottomRight.2, alpha: 1.0)
        opaqueCtx.fill(CGRect(x: halfW, y: 0, width: halfW, height: nr))

        // Left strip (between top and bottom strips)
        opaqueCtx.setFillColor(red: topLeft.0, green: topLeft.1, blue: topLeft.2, alpha: 1.0)
        opaqueCtx.fill(CGRect(x: 0, y: nr, width: nr, height: h - nr * 2))

        // Right strip
        opaqueCtx.setFillColor(red: topRight.0, green: topRight.1, blue: topRight.2, alpha: 1.0)
        opaqueCtx.fill(CGRect(x: w - nr, y: nr, width: nr, height: h - nr * 2))

        // Draw the screenshot — CG composites semi-transparent corner pixels
        // against our fills, producing a fully opaque result with no pixel loop.
        opaqueCtx.draw(image, in: imageRect)

        return opaqueCtx.makeImage() ?? image
    }

    private func drawGradient(
        _ definition: GradientDefinition,
        in context: CGContext,
        rect: CGRect
    ) {
        let cgColors = definition.colors.map { $0.cgColor }

        // Single-color definition → solid fill (CGGradient requires ≥2 colors)
        if cgColors.count == 1, let color = cgColors.first {
            context.setFillColor(color)
            context.fill(rect)
            return
        }

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
