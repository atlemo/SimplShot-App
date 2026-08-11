import AppKit
import CoreGraphics

enum TemplateRenderError: LocalizedError {
    case cannotCreateContext
    case cannotLoadCustomImage(path: String)
    case cannotCreateOutputImage

    var errorDescription: String? {
        switch self {
        case .cannotCreateContext:
            return String(localized: "Failed to create graphics context for template rendering")
        case .cannotLoadCustomImage(let path):
            return String(localized: "Failed to load custom wallpaper image at: \(path)")
        case .cannotCreateOutputImage:
            return String(localized: "Failed to create output image from template rendering")
        }
    }
}

class TemplateRenderer {
    private enum ShadowStyle {
        static let maxOpacity: CGFloat = 0.5
        static let maxBlur: CGFloat = 60
        static let maxYOffset: CGFloat = 28
    }

    // Cache for flattenNativeCorners — keyed by source image identity.
    // The result depends only on the source image pixels, not on corner radius,
    // so we can reuse it across rapid slider changes. Holding a strong reference
    // to the source (rather than a raw pointer string) means the identity check
    // can never alias a new image allocated at a freed image's address.
    private var cachedFlattenedImage: CGImage?
    private var cachedFlattenSource: CGImage?
    private var cachedFlattenScale: CGFloat = 0

    private func cachedFlattenNativeCorners(_ image: CGImage, backingScale: CGFloat) -> CGImage {
        if image === cachedFlattenSource, backingScale == cachedFlattenScale,
           let cached = cachedFlattenedImage {
            return cached
        }
        let result = flattenNativeCorners(image, backingScale: backingScale)
        cachedFlattenedImage = result
        cachedFlattenSource = image
        cachedFlattenScale = backingScale
        return result
    }

    // Cache for the rendered background (gradient or custom image).
    // The background only changes when the wallpaper source or canvas dimensions change —
    // NOT when corner radius or shadow intensity changes. Caching it avoids the expensive
    // full-canvas gradient fill on every slider tick.
    private var cachedBackgroundImage: CGImage?
    private var cachedBackgroundKey: String = ""

    // Cache for the pre-blurred drop-shadow sprite. Keyed by shape size, corner
    // radii, and shadow parameters; canvas size and position don't matter, so
    // padding/alignment/aspect drags hit this cache on every frame.
    private var cachedShadowSprite: CGImage?
    private var cachedShadowSpriteKey: String = ""
    private var cachedShadowSpriteMargin: CGFloat = 0

    /// Renders (or returns cached) the blurred squircle drop shadow as a
    /// standalone sprite. The shape is drawn far outside the sprite with a
    /// compensating shadow offset, so only the shadow lands inside it.
    /// `margin` is the sprite's padding around the nominal shape rect.
    private func shadowSprite(
        shapeSize: CGSize,
        radii: (tl: CGFloat, tr: CGFloat, bl: CGFloat, br: CGFloat),
        blur: CGFloat,
        offsetY: CGFloat,
        alpha: CGFloat
    ) -> (sprite: CGImage, margin: CGFloat)? {
        guard shapeSize.width > 0, shapeSize.height > 0 else { return nil }
        let margin = ceil(blur * 2 + abs(offsetY))
        let key = "\(shapeSize.width)x\(shapeSize.height)_\(radii.tl)_\(radii.tr)_\(radii.bl)_\(radii.br)_\(blur)_\(offsetY)_\(alpha)"
        if key == cachedShadowSpriteKey, let cached = cachedShadowSprite {
            return (cached, cachedShadowSpriteMargin)
        }

        let spriteW = Int(shapeSize.width + margin * 2)
        let spriteH = Int(shapeSize.height + margin * 2)
        guard let ctx = CGContext(
            data: nil,
            width: spriteW,
            height: spriteH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Draw the shape shifted entirely out of view; the compensating shadow
        // offset puts only its shadow back inside the sprite.
        let outOfView = CGFloat(spriteW) + blur * 4
        ctx.setShadow(
            offset: CGSize(width: outOfView, height: offsetY),
            blur: blur,
            color: CGColor(gray: 0, alpha: alpha)
        )
        let shapeRect = CGRect(x: margin - outOfView, y: margin,
                               width: shapeSize.width, height: shapeSize.height)
        ctx.addPath(squirclePath(in: shapeRect, topLeft: radii.tl, topRight: radii.tr,
                                 bottomLeft: radii.bl, bottomRight: radii.br))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fillPath()

        guard let sprite = ctx.makeImage() else { return nil }
        cachedShadowSprite = sprite
        cachedShadowSpriteKey = key
        cachedShadowSpriteMargin = margin
        return (sprite, margin)
    }

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

        // 1. Draw background — use cached version when available.
        //    The background key covers wallpaper source + canvas dimensions.
        //    Corner radius and shadow changes reuse the cached background.
        let bgKey: String
        switch template.wallpaperSource {
        case .builtInGradient(let gradient):
            bgKey = "grad_\(gradient.id)_\(canvasWidth)x\(canvasHeight)"
        case .customImage(let path):
            bgKey = "img_\(path)_\(canvasWidth)x\(canvasHeight)"
        case .customColor(let color):
            bgKey = "color_\(color.red)_\(color.green)_\(color.blue)_\(canvasWidth)x\(canvasHeight)"
        }

        if bgKey == cachedBackgroundKey, let cachedBG = cachedBackgroundImage {
            // Fast path: draw the cached background image (single blit, no gradient math)
            context.draw(cachedBG, in: canvasRect)
        } else {
            // Slow path: render the background and cache it
            switch template.wallpaperSource {
            case .builtInGradient(let gradient):
                drawGradient(gradient.gradientDefinition, in: context, rect: canvasRect)
            case .customImage(let path):
                try drawCustomImage(path: path, in: context, rect: canvasRect)
            case .customColor(let color):
                context.setFillColor(color.cgColor)
                context.fill(canvasRect)
            }
            cachedBackgroundImage = context.makeImage()
            cachedBackgroundKey = bgKey
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

        // 3 & 4. Shadow + clipped screenshot.
        //
        // Problem with the naive approach (fill black squircle → draw screenshot on top):
        // the squircle clip's anti-aliased edge pixels partially expose the solid black fill,
        // producing a thin dark pixelated border at the corners.
        //
        // Fix: build an intermediate canvas-sized image that contains the screenshot already
        // clipped to the squircle (transparent outside it, anti-aliased at the edge).
        // Drawing that intermediate image with setShadow active casts the shadow from the
        // squircle's alpha edge — no black fill underneath, no border artifact.
        let clampedShadowIntensity = CGFloat(max(0, min(1, shadowIntensity)))

        if anyRounded {
            // Pre-process: eliminate native macOS rounded-corner transparency.
            let opaqueScreenshot = cachedFlattenNativeCorners(screenshot, backingScale: backingScale)

            let clipPath = squirclePath(in: screenshotRect, topLeft: rTL, topRight: rTR, bottomLeft: rBL, bottomRight: rBR)

            // Shadow first, as a pre-blurred sprite blitted at the screenshot's
            // position. The blurred shape depends only on the screenshot size,
            // corner radii, and shadow parameters — NOT on canvas size or
            // position — so dragging the padding/alignment sliders reuses the
            // cached sprite instead of re-running the (very expensive) CG
            // shadow blur over the whole canvas on every frame.
            if clampedShadowIntensity > 0,
               let shadow = shadowSprite(
                   shapeSize: screenshotRect.size,
                   radii: (rTL, rTR, rBL, rBR),
                   blur: ShadowStyle.maxBlur * backingScale * clampedShadowIntensity,
                   offsetY: -ShadowStyle.maxYOffset * backingScale * clampedShadowIntensity,
                   alpha: ShadowStyle.maxOpacity * clampedShadowIntensity
               ) {
                context.draw(shadow.sprite, in: CGRect(
                    x: screenshotRect.minX - shadow.margin,
                    y: screenshotRect.minY - shadow.margin,
                    width: CGFloat(shadow.sprite.width),
                    height: CGFloat(shadow.sprite.height)
                ))
            }

            // Then the screenshot clipped to the squircle. The clip's
            // anti-aliased edge composites against background + blurred shadow
            // — the same layering the previous draw-with-setShadow pass
            // produced — never against an opaque fill, so no dark fringe.
            context.saveGState()
            context.addPath(clipPath)
            context.clip()
            context.draw(opaqueScreenshot, in: screenshotRect)
            context.restoreGState()
        } else {
            // No corner radius — draw with shadow; CG uses the image's alpha for shadow shape.
            context.saveGState()
            context.setShadow(
                offset: CGSize(width: 0, height: -ShadowStyle.maxYOffset * backingScale * clampedShadowIntensity),
                blur: ShadowStyle.maxBlur * backingScale * clampedShadowIntensity,
                color: CGColor(gray: 0, alpha: ShadowStyle.maxOpacity * clampedShadowIntensity)
            )
            context.draw(screenshot, in: screenshotRect)
            context.restoreGState()
        }

        // 5. Extract final image
        drawWatermark(template.watermarkSettings, in: context, canvasSize: canvasRect.size, backingScale: backingScale)

        // 6. Extract final image
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

    // Cache for a small gradient tile. The gradient endpoints scale affinely
    // with the rect (see gradientPoints), so a gradient rendered once into a
    // square tile and stretch-blitted reproduces the full-size render exactly.
    // Padding drags change the canvas size every frame — missing the full-size
    // background cache above — and this keeps them from re-shading millions of
    // pixels each time.
    private var cachedGradientTile: CGImage?
    private var cachedGradientTileKey: String = ""

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

        let key = definition.colors
            .map { "\($0.red),\($0.green),\($0.blue),\($0.alpha)" }
            .joined(separator: ";") + "@\(definition.angle)"
        if key != cachedGradientTileKey || cachedGradientTile == nil {
            cachedGradientTile = renderGradientTile(definition, colors: cgColors)
            cachedGradientTileKey = key
        }

        if let tile = cachedGradientTile {
            context.saveGState()
            context.interpolationQuality = .high
            context.draw(tile, in: rect)
            context.restoreGState()
            return
        }

        // Fallback: direct render if the tile couldn't be created.
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

    private func renderGradientTile(_ definition: GradientDefinition, colors: [CGColor]) -> CGImage? {
        let tileSize = 1024
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors as CFArray,
            locations: nil
        ), let ctx = CGContext(
            data: nil,
            width: tileSize,
            height: tileSize,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let tileRect = CGRect(x: 0, y: 0, width: tileSize, height: tileSize)
        let (start, end) = gradientPoints(for: definition.angle, in: tileRect)
        ctx.drawLinearGradient(
            gradient,
            start: start,
            end: end,
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
        return ctx.makeImage()
    }

    // Cache for the decoded custom wallpaper bitmap. Single entry keyed by
    // path: a renderer draws one wallpaper at a time, and the background cache
    // above misses whenever the canvas size changes (every padding-slider
    // tick) — without this, each of those misses re-read and re-decoded the
    // wallpaper file from disk.
    private var cachedCustomImage: CGImage?
    private var cachedCustomImagePath: String?

    private func drawCustomImage(
        path: String,
        in context: CGContext,
        rect: CGRect
    ) throws {
        let cgImage: CGImage
        if path == cachedCustomImagePath, let cached = cachedCustomImage {
            cgImage = cached
        } else {
            guard let nsImage = NSImage(contentsOfFile: path),
                  let decoded = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else {
                throw TemplateRenderError.cannotLoadCustomImage(path: path)
            }
            cachedCustomImage = decoded
            cachedCustomImagePath = path
            cgImage = decoded
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

    private func drawWatermark(
        _ watermark: WatermarkSettings,
        in context: CGContext,
        canvasSize: CGSize,
        backingScale: CGFloat
    ) {
        guard watermark.isEnabled,
              let path = watermark.imagePath,
              // Cached bytes → fresh NSImage per call (safe to draw off-main, e.g.
              // capture-time template compositing), avoids re-reading from disk.
              let nsImage = WatermarkImageCache.image(atPath: path)
        else { return }

        // Watermark dimensions are image-pixel units, consistent with the editor
        // preview (EditorCanvasView `* scale`) and AnnotationRenderer export, so
        // a given widthPx renders at the same relative size in every path.
        let marginH = CGFloat(watermark.edgeOffset)
        let marginV = CGFloat(watermark.bottomOffset)
        let targetW = max(1, CGFloat(watermark.widthPx))
        let rawSize = nsImage.size
        let aspect = rawSize.height > 0 ? rawSize.width / rawSize.height : 1.0
        let targetH = max(1, targetW / aspect)

        guard let wmCG = rasterize(nsImage, size: CGSize(width: targetW, height: targetH)) else {
            return
        }

        let x: CGFloat
        let y: CGFloat
        switch watermark.position {
        case .topLeft:
            x = marginH
            y = canvasSize.height - targetH - marginV
        case .topRight:
            x = canvasSize.width - targetW - marginH
            y = canvasSize.height - targetH - marginV
        case .bottomLeft:
            x = marginH
            y = marginV
        case .bottomRight:
            x = canvasSize.width - targetW - marginH
            y = marginV
        }

        context.saveGState()
        context.setAlpha(CGFloat(watermark.opacity))
        context.draw(wmCG, in: CGRect(x: x, y: y, width: targetW, height: targetH))
        context.restoreGState()
    }

    /// Renders an NSImage (SVG, PNG, JPG) into a CGImage at exactly `size` pixels.
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
}
