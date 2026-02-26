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
        targetAspectRatio: Double? = nil
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

        // 2. Screenshot placement rect
        let screenshotRect = CGRect(
            x: (CGFloat(canvasWidth) - CGFloat(screenshotWidth)) / 2,
            y: (CGFloat(canvasHeight) - CGFloat(screenshotHeight)) / 2,
            width: CGFloat(screenshotWidth),
            height: CGFloat(screenshotHeight)
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
            // Pre-process: eliminate native macOS rounded-corner transparency
            // by sampling edge colors and filling the corner regions before
            // compositing. This makes the image fully opaque so the squircle
            // clip produces perfectly clean corners.
            let opaqueScreenshot = flattenNativeCorners(screenshot, backingScale: backingScale)

            context.saveGState()
            let clipPath = squirclePath(in: screenshotRect, cornerRadius: cornerRadius)
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
        let c: CGFloat = 0.4477  // ≈ 1 - (√2 / 2)  — where the arc departs from the straight side

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

    /// Makes the screenshot fully opaque by sampling edge colors near each corner
    /// and filling the native macOS rounded-corner transparent area with those colors.
    /// The screenshot is then composited on top, so the semi-transparent corner pixels
    /// blend against a matching color instead of showing black/transparent artifacts.
    private func flattenNativeCorners(_ image: CGImage, backingScale: CGFloat) -> CGImage {
        let width = image.width
        let height = image.height

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }

        let imageRect = CGRect(x: 0, y: 0, width: width, height: height)

        // macOS native window corner radius is ~10pt; use a generous 20pt
        // fill region so the sampled color fully covers any transparent fringe.
        let nativeRadius = Int(ceil(20.0 * backingScale))

        // Sample at 1px from each edge to get the true edge color,
        // avoiding window controls (close/minimize/zoom) that sit further in.
        let sampleOffset = 1

        // Draw the image so we can read pixel data.
        context.draw(image, in: imageRect)

        guard let data = context.data else { return image }
        let bytesPerRow = context.bytesPerRow

        // Read an RGBA pixel from the data buffer.
        // In the data buffer, row 0 = visual top of the image.
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

        // Sample from each edge, just 1px in from the corner along the
        // straight edge (past the transparent corner arc).
        // Data buffer: row 0 (low y) = screen top, high y = screen bottom.
        // We sample along the edge at the nativeRadius offset so we're
        // past the curved transparent region but still on the edge color.
        let edgeInset = nativeRadius + 2
        let topLeft     = sampleColor(x: sampleOffset, y: edgeInset)
        let topRight    = sampleColor(x: width - 1 - sampleOffset, y: edgeInset)
        let bottomLeft  = sampleColor(x: sampleOffset, y: height - 1 - edgeInset)
        let bottomRight = sampleColor(x: width - 1 - sampleOffset, y: height - 1 - edgeInset)

        // Clear the context and fill corner regions with the sampled colors.
        context.clear(imageRect)

        let nr = CGFloat(nativeRadius)
        let corners: [(CGRect, (CGFloat, CGFloat, CGFloat))] = [
            // CG fill: high y = screen top, low y = screen bottom
            (CGRect(x: 0, y: CGFloat(height) - nr, width: nr, height: nr), topLeft),
            (CGRect(x: CGFloat(width) - nr, y: CGFloat(height) - nr, width: nr, height: nr), topRight),
            (CGRect(x: 0, y: 0, width: nr, height: nr), bottomLeft),
            (CGRect(x: CGFloat(width) - nr, y: 0, width: nr, height: nr), bottomRight),
        ]
        for (rect, color) in corners {
            context.setFillColor(red: color.0, green: color.1, blue: color.2, alpha: 1.0)
            context.fill(rect)
        }

        // Redraw the screenshot on top — semi-transparent corner pixels now
        // composite against the matching sampled colors.
        context.draw(image, in: imageRect)

        // Force full opacity on corner regions so no residual transparency
        // leaks through and causes black fringing under the squircle clip.
        let rawPtr = data.assumingMemoryBound(to: UInt8.self)
        for (rect, _) in corners {
            // Convert CG fill rect back to data-buffer rows (inverted y).
            let dataMinY = height - Int(rect.maxY)
            let dataMaxY = height - Int(rect.minY)
            let dataMinX = Int(rect.minX)
            let dataMaxX = Int(rect.maxX)
            for row in max(0, dataMinY)..<min(height, dataMaxY) {
                for col in max(0, dataMinX)..<min(width, dataMaxX) {
                    let pixelOffset = row * bytesPerRow + col * 4
                    let a = rawPtr[pixelOffset + 3]
                    if a < 255 {
                        // Un-premultiply, then write as fully opaque
                        let af = CGFloat(a) / 255.0
                        if af > 0 {
                            rawPtr[pixelOffset + 0] = UInt8(min(255, CGFloat(rawPtr[pixelOffset + 0]) / af))
                            rawPtr[pixelOffset + 1] = UInt8(min(255, CGFloat(rawPtr[pixelOffset + 1]) / af))
                            rawPtr[pixelOffset + 2] = UInt8(min(255, CGFloat(rawPtr[pixelOffset + 2]) / af))
                        }
                        rawPtr[pixelOffset + 3] = 255
                    }
                }
            }
        }

        return context.makeImage() ?? image
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
