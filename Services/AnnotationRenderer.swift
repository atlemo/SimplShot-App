import AppKit
import CoreGraphics
import CoreImage
import CoreText
import PDFKit

/// Renders annotations onto a CGImage for export.
/// All annotation coordinates are in image-pixel space, matching the CGImage dimensions.
class AnnotationRenderer {

    private lazy var ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Multiplier applied to annotation *style* dimensions (stroke width, font
    /// size, corner radii, spotlight feather) so they stay proportional to the
    /// image's pixel density. For a 2× (144-DPI) screenshot the editor sets this
    /// to 2 so a 3pt stroke renders as 6 image pixels — matching how it looks on
    /// a 1× image of the same logical content. Positions are NOT affected (they
    /// live in image-pixel space already). Defaults to 1 (no change).
    /// Set before calling `render`/`drawAnnotationsVector`; never mutated mid-render.
    var styleScale: CGFloat = 1.0

    /// Shared measurement-label font multiplier so the live preview
    /// (AnnotationOverlayView) and the exported bitmap size the pill identically.
    /// Grows gently with stroke width: a default 2pt stroke gives 1.0 (11pt base),
    /// and each extra stroke point adds 15% — so thick measurements get a slightly
    /// larger label rather than the font ballooning.
    static func measurementFontScale(strokeWidth: CGFloat) -> CGFloat {
        1.0 + max(0, strokeWidth - 2) * 0.15
    }

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

        // 3. Pixelate renders before spotlight so it appears as image content being dimmed.
        for annotation in annotations where annotation.tool == .pixelate {
            drawAnnotation(annotation, backingScale: backingScale, drawingHeight: CGFloat(height), in: context)
        }

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

        // 4. Draw remaining annotations on top of the spotlight dim.
        for annotation in annotations {
            if annotation.tool == .spotlight || annotation.tool == .pixelate { continue }
            drawAnnotation(annotation, backingScale: backingScale, drawingHeight: CGFloat(height), in: context)
        }

        // 4. Draw watermark on top of all annotations.
        //    Context is in flipped/top-left space, so CGImage drawing needs a local unflip.
        if watermark.isEnabled, let path = watermark.imagePath,
           let nsImage = WatermarkImageCache.image(atPath: path) {
            // Offsets and width are image-pixel units (matching the canvas
            // preview's `* scale`); the context is image-pixel space already, so
            // no backing-scale multiplier — same convention as strokeWidth/fontSize.
            let marginH = CGFloat(watermark.edgeOffset)
            let marginV = CGFloat(watermark.bottomOffset)
            let targetW = max(1, CGFloat(watermark.widthPx))
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

    /// Draws annotations and watermark directly into an existing CGContext (e.g. a
    /// PDF context) without rasterizing. Used for vector PDF export.
    ///
    /// Coordinate system: annotations are stored in image-pixel space (the dimensions
    /// of the PDF page rendered at `backingScale`). The context is expected to be in
    /// its native bottom-left orientation with units matching `contextSize` (typically
    /// PDF points). This method applies the same coordinate flip used by `render()`
    /// and then scales by `1/backingScale` so pixel-space drawing maps to point-space
    /// output, keeping `strokeWidth`/`fontSize` correctly sized.
    ///
    /// Pixelate annotations are skipped — they fundamentally require a raster source.
    func drawAnnotationsVector(
        annotations: [Annotation],
        into context: CGContext,
        contextSize: CGSize,
        backingScale: CGFloat,
        watermark: WatermarkSettings = WatermarkSettings()
    ) {
        let widthPx = Int((contextSize.width * backingScale).rounded())
        let heightPx = Int((contextSize.height * backingScale).rounded())

        context.saveGState()
        // Flip to top-left origin to match the annotation coordinate convention.
        context.translateBy(x: 0, y: contextSize.height)
        context.scaleBy(x: 1, y: -1)
        // Map pixel-space coordinates into point-space output.
        context.scaleBy(x: 1.0 / backingScale, y: 1.0 / backingScale)

        let spotlightAnnotations = annotations.filter { $0.tool == .spotlight }
        if !spotlightAnnotations.isEmpty {
            drawSpotlights(
                spotlightAnnotations,
                imageWidth: widthPx,
                imageHeight: heightPx,
                backingScale: backingScale,
                in: context
            )
        }

        for annotation in annotations {
            if annotation.tool == .spotlight { continue }
            if annotation.tool == .pixelate { continue }  // unsupported in vector mode
            drawAnnotation(annotation, backingScale: backingScale, drawingHeight: CGFloat(heightPx), in: context)
        }

        if watermark.isEnabled, let path = watermark.imagePath,
           let nsImage = WatermarkImageCache.image(atPath: path) {
            // Image-pixel units, matching the raster path and canvas preview.
            // The vector context is pre-scaled to image-pixel space (see the
            // `1/backingScale` above), so no backing-scale multiplier here either.
            let marginH = CGFloat(watermark.edgeOffset)
            let marginV = CGFloat(watermark.bottomOffset)
            let targetW = max(1, CGFloat(watermark.widthPx))
            let rawSize = nsImage.size
            let aspect = rawSize.height > 0 ? rawSize.width / rawSize.height : 1.0
            let targetH = max(1, targetW / aspect)

            if let wmCG = rasterize(nsImage, size: CGSize(width: targetW, height: targetH)) {
                let x: CGFloat
                let y: CGFloat
                switch watermark.position {
                case .topLeft:     x = marginH;                              y = marginV
                case .topRight:    x = CGFloat(widthPx) - targetW - marginH; y = marginV
                case .bottomLeft:  x = marginH;                              y = CGFloat(heightPx) - targetH - marginV
                case .bottomRight: x = CGFloat(widthPx) - targetW - marginH; y = CGFloat(heightPx) - targetH - marginV
                }
                context.saveGState()
                context.setAlpha(CGFloat(watermark.opacity))
                context.translateBy(x: x, y: y + targetH)
                context.scaleBy(x: 1, y: -1)
                context.draw(wmCG, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))
                context.restoreGState()
            }
        }

        context.restoreGState()
    }

    /// Composite a PDF page and its annotations into a raster at the page's
    /// native bitmap resolution. Used for copy-to-clipboard / PNG export of a
    /// PDF session so a high-DPI scan isn't downsampled to the page's point size
    /// × backing scale (the resolution the on-screen editor uses).
    ///
    /// The context is scaled so one unit equals one PDF point but pixels are
    /// allocated at `page.rasterScale`, letting both `page.draw` and the shared
    /// `drawAnnotationsVector` work in their natural point space while rendering
    /// at full resolution. Annotations are stored in `displayBackingScale` pixel
    /// space (matching the editor's `imagePixelSize`); `drawAnnotationsVector`
    /// maps them into point space. Pixelate is unavailable for PDF sessions.
    func renderPDFPageNative(
        page: PDFPage,
        annotations: [Annotation],
        displayBackingScale: CGFloat,
        watermark: WatermarkSettings = WatermarkSettings()
    ) -> CGImage? {
        let pointSize = page.rotatedMediaBoxSize
        guard pointSize.width > 0, pointSize.height > 0 else { return nil }

        let nativeScale = page.rasterScale(minimumScale: displayBackingScale)
        let width = Int((pointSize.width * nativeScale).rounded())
        let height = Int((pointSize.height * nativeScale).rounded())
        guard width > 0, height > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Work in point space at native pixel density (1 context unit = 1 point).
        context.scaleBy(x: nativeScale, y: nativeScale)

        // White page background, then the page content (rotation baked in by draw).
        context.setFillColor(CGColor.white)
        context.fill(CGRect(origin: .zero, size: pointSize))
        page.draw(with: .mediaBox, to: context)

        // Annotations + watermark, mapped from pixel space into the point context.
        drawAnnotationsVector(
            annotations: annotations,
            into: context,
            contextSize: pointSize,
            backingScale: displayBackingScale,
            watermark: watermark
        )

        return context.makeImage()
    }

    // MARK: - Individual Annotation Drawing

    /// `drawingHeight` is the canvas height in the context's current drawing-space
    /// units (annotation pixel space). It must be passed in rather than read from
    /// `context.height`: that property is the *bitmap* pixel height, which differs
    /// from drawing space when the context is scaled (native-resolution PDF raster)
    /// and is 0 for non-bitmap contexts (vector PDF export).
    private func drawAnnotation(_ annotation: Annotation, backingScale: CGFloat, drawingHeight: CGFloat, in context: CGContext) {
        let color = annotation.style.cgStrokeColor
        // Style values (strokeWidth, fontSize) are interpreted in image-pixel
        // units and multiplied by `styleScale` for high-DPI images. The live
        // preview converts the same values to points via `× scale × dpiScaleFactor`,
        // so preview and export stay in lockstep at any zoom or DPI.
        let lineWidth = annotation.style.strokeWidth * styleScale

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
                strokeWidth: annotation.style.strokeWidth,
                lineWidth: lineWidth,
                in: context
            )
        case .freeDraw:
            drawFreeDraw(points: annotation.points, in: context)
        case .line:
            drawLine(from: annotation.startPoint, to: annotation.endPoint, in: context)
        case .rectangle:
            drawRectangle(annotation.boundingRect, fillColor: annotation.style.cgFillColor, color: color, backingScale: backingScale, in: context)
        case .circle:
            drawEllipse(in: annotation.boundingRect, fillColor: annotation.style.cgFillColor, color: color, in: context)
        case .triangle:
            drawTriangle(annotation.boundingRect, fillColor: annotation.style.cgFillColor, color: color, in: context)
        case .star:
            drawStar(annotation.boundingRect, fillColor: annotation.style.cgFillColor, color: color, in: context)
        case .text:
            drawText(annotation.text, at: annotation.startPoint, style: annotation.style, backingScale: backingScale, drawingHeight: drawingHeight, in: context)
        case .spotlight:
            break
        case .numberedStep:
            drawNumberedStep(annotation.stepNumber, at: annotation.startPoint, style: annotation.style, backingScale: backingScale, in: context)
        case .select, .textSelect, .crop, .pixelate:
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

    private func drawMeasurement(from start: CGPoint, to end: CGPoint, color: CGColor, strokeIsLight: Bool, strokeWidth: CGFloat, lineWidth: CGFloat, in context: CGContext) {
        drawMeasurementLineWithHeads(from: start, to: end, color: color, lineWidth: lineWidth, in: context)

        let pixelDistance = hypot(end.x - start.x, end.y - start.y)
        let label = "\(Int(pixelDistance.rounded())) px"

        // Font grows gently with stroke width (so a thick measurement gets a
        // slightly larger label, not a huge one), then ×styleScale for high-DPI.
        // Must match AnnotationOverlayView.measurementLabel exactly.
        let fontScale = Self.measurementFontScale(strokeWidth: strokeWidth)
        let labelFontSize = 11 * fontScale * styleScale
        // System monospaced font: matches the live preview and never falls back
        // to Helvetica the way a hardcoded "SFMono-*" PostScript name can.
        let font = NSFont.monospacedSystemFont(ofSize: labelFontSize, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: strokeIsLight ? NSColor.black : NSColor.white
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: attrs))
        let bounds = CTLineGetBoundsWithOptions(line, [])

        let hPad = 7 * fontScale * styleScale
        let vPad = 4 * fontScale * styleScale
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
        let ascent = font.ascender
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

        // Dashed (not dotted) line — must match AnnotationOverlayView's
        // `dash: [sw*3, sw*2]`. Butt caps keep the dashes crisp rectangles; the
        // surrounding drawAnnotation set .round, so restore it after for the heads.
        context.setLineCap(.butt)
        context.setLineDash(phase: 0, lengths: [lineWidth * 3, lineWidth * 2])
        drawLine(from: trimmedStart, to: trimmedEnd, in: context)
        context.setLineDash(phase: 0, lengths: [])
        context.setLineCap(.round)
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

    private func drawRectangle(_ rect: CGRect, fillColor: CGColor?, color: CGColor, backingScale: CGFloat, in context: CGContext) {
        // Corner radius in image-pixel units × styleScale (matching the preview's
        // `6 * scale * dpiScaleFactor`) — same convention as strokeWidth/fontSize.
        let cornerRadius: CGFloat = 6 * styleScale
        let path = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        if let fill = fillColor {
            context.setFillColor(fill)
            context.addPath(path)
            context.fillPath()
        }
        if color.alpha > 0 {
            context.addPath(path)
            context.strokePath()
        }
    }

    private func drawEllipse(in rect: CGRect, fillColor: CGColor?, color: CGColor, in context: CGContext) {
        if let fill = fillColor {
            context.setFillColor(fill)
            context.fillEllipse(in: rect)
        }
        if color.alpha > 0 {
            context.strokeEllipse(in: rect)
        }
    }

    private func drawTriangle(_ rect: CGRect, fillColor: CGColor?, color: CGColor, in context: CGContext) {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        if let fill = fillColor {
            context.setFillColor(fill)
            context.addPath(path)
            context.fillPath()
        }
        if color.alpha > 0 {
            context.addPath(path)
            context.strokePath()
        }
    }

    private func drawStar(_ rect: CGRect, fillColor: CGColor?, color: CGColor, in context: CGContext) {
        let path = starPath(in: rect)
        if let fill = fillColor {
            context.setFillColor(fill)
            context.addPath(path)
            context.fillPath()
        }
        if color.alpha > 0 {
            context.addPath(path)
            context.strokePath()
        }
    }

    /// Builds a 5-point star CGPath inscribed in `rect`.
    private func starPath(in rect: CGRect) -> CGPath {
        let cx = rect.midX
        let cy = rect.midY
        let outerR = min(rect.width, rect.height) / 2
        let innerR = outerR * 0.4
        let points = 5
        let path = CGMutablePath()
        for i in 0..<(points * 2) {
            let angle = CGFloat(i) * .pi / CGFloat(points) - .pi / 2
            let r = i.isMultiple(of: 2) ? outerR : innerR
            let pt = CGPoint(x: cx + r * cos(angle), y: cy + r * sin(angle))
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        path.closeSubpath()
        return path
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
        // Corner radius and feather in image-pixel units × styleScale (matching
        // the preview's `6 * scale * dpiScaleFactor` / `feather * scale * dpiScaleFactor`).
        let cornerRadius: CGFloat = 6 * styleScale
        let feather = annotations.map(\.style.spotlightFeather).max() ?? 0
        let featherPx = feather * styleScale

        if featherPx < 1 {
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
            return
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let overlayCtx = CGContext(
            data: nil,
            width: imageWidth,
            height: imageHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }

        overlayCtx.translateBy(x: 0, y: CGFloat(imageHeight))
        overlayCtx.scaleBy(x: 1, y: -1)

        let path = CGMutablePath()
        path.addRect(fullRect)
        for annotation in annotations {
            path.addRoundedRect(
                in: annotation.boundingRect,
                cornerWidth: cornerRadius,
                cornerHeight: cornerRadius
            )
        }
        overlayCtx.addPath(path)
        overlayCtx.setFillColor(overlayColor)
        overlayCtx.fillPath(using: .evenOdd)

        guard let overlayImage = overlayCtx.makeImage() else { return }

        let ciImage = CIImage(cgImage: overlayImage)
        let blurred = ciImage.clampedToExtent()
            .applyingGaussianBlur(sigma: Double(featherPx))
            .cropped(to: ciImage.extent)

        // Reuse the renderer's context — creating a CIContext per call is expensive.
        guard let blurredCG = ciContext.createCGImage(blurred, from: blurred.extent) else { return }

        context.saveGState()
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: 0, y: -CGFloat(imageHeight))
        context.draw(blurredCG, in: fullRect)
        context.restoreGState()
    }

    private func drawText(_ text: String, at point: CGPoint, style: AnnotationStyle, backingScale: CGFloat, drawingHeight: CGFloat, in context: CGContext) {
        guard !text.isEmpty else { return }

        // Text bubbles are NOT scaled by styleScale: their box geometry and the
        // interactive resize handles live in stored image-pixel space, so the
        // font size stays in image-pixel units (matching the preview's
        // `fontSize * scale`). Users size text directly via the font control.
        let fontSize = style.fontSize
        // System font, matching the live overlay/editor (AnnotationOverlayView,
        // GrowingTextField) so the exported bubble wraps and sizes identically.
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let bgColor = style.cgTextBubbleBackground
        let fgColor = style.cgTextBubbleForeground

        let hPad = fontSize * 0.55
        let vPad = fontSize * 0.25
        let ascent = font.ascender
        let descent = abs(font.descender)
        let lineHeight = ascent + descent
        let lineSpacing = fontSize * 0.22
        let cornerRadius = fontSize * 0.45

        if let fixedBubbleWidth = style.textWidth {
            // Fixed-width mode: use CTFramesetter to wrap text into the available inner width.
            let innerWidth = fixedBubbleWidth - hPad * 2

            let paraStyle = NSMutableParagraphStyle()
            paraStyle.alignment = .center
            paraStyle.lineSpacing = lineSpacing - (lineHeight - fontSize)  // approximate to match SwiftUI

            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: fgColor,
                .paragraphStyle: paraStyle,
            ]
            let attrStr = NSAttributedString(string: text, attributes: attributes)
            let framesetter = CTFramesetterCreateWithAttributedString(attrStr)

            // Measure how tall the wrapped text will be.
            let fitSize = CTFramesetterSuggestFrameSizeWithConstraints(
                framesetter,
                CFRange(location: 0, length: 0),
                nil,
                CGSize(width: innerWidth, height: CGFloat.greatestFiniteMagnitude),
                nil
            )

            let bgWidth = fixedBubbleWidth
            let bgHeight = fitSize.height + vPad * 2
            let bgRect = CGRect(
                x: point.x - bgWidth / 2,
                y: point.y - bgHeight / 2,
                width: bgWidth,
                height: bgHeight
            )

            context.saveGState()
            context.setFillColor(bgColor)
            let pillPath = CGPath(roundedRect: bgRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
            context.addPath(pillPath)
            context.fillPath()
            context.restoreGState()

            // Draw the framed text. CT uses bottom-left origin so un-flip for the frame rect.
            let textRect = CGRect(
                x: bgRect.minX + hPad,
                y: bgRect.minY + vPad,
                width: innerWidth,
                height: fitSize.height
            )
            // Un-flip to CG bottom-left space for CTFrame drawing. Use the
            // drawing-space height — NOT context.height (bitmap pixels), which
            // is wrong for scaled contexts and 0 for PDF contexts.
            let cgTextRect = CGRect(
                x: textRect.minX,
                y: drawingHeight - textRect.maxY,  // context is flipped: top-left origin
                width: textRect.width,
                height: textRect.height
            )
            let framePath = CGPath(rect: cgTextRect, transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), framePath, nil)
            context.saveGState()
            context.scaleBy(x: 1, y: -1)
            context.translateBy(x: 0, y: -drawingHeight)
            CTFrameDraw(frame, context)
            context.restoreGState()
        } else {
            // Natural-width mode: split on newlines, no wrapping.
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: fgColor,
            ]
            let lineStrings = text.components(separatedBy: "\n")
            let ctLines = lineStrings.map { CTLineCreateWithAttributedString(NSAttributedString(string: $0, attributes: attributes)) }

            let maxLineWidth = ctLines.map { CTLineGetBoundsWithOptions($0, []).width }.max() ?? 0
            let lineCount = CGFloat(lineStrings.count)

            let bgWidth = maxLineWidth + hPad * 2
            let bgHeight = lineCount * lineHeight + max(0, lineCount - 1) * lineSpacing + vPad * 2

            let bgRect = CGRect(
                x: point.x - bgWidth / 2,
                y: point.y - bgHeight / 2,
                width: bgWidth,
                height: bgHeight
            )

            context.saveGState()
            context.setFillColor(bgColor)
            let pillPath = CGPath(roundedRect: bgRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
            context.addPath(pillPath)
            context.fillPath()
            context.restoreGState()

            for (i, ctLine) in ctLines.enumerated() {
                let lineWidth = CTLineGetBoundsWithOptions(ctLine, []).width
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
        // Not scaled by styleScale (see drawText) — geometry is font-derived and
        // the badge is sized directly via the font control.
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

        // Draw number text centered in the circle.
        // Rounded-design system font: matches the preview's
        // `.system(... design: .rounded)` and doesn't depend on SF Pro being
        // installed (the old "SFProRounded-Bold" name silently fell back to
        // Helvetica on machines without it).
        let labelFontSize = fontSize * 0.75
        let baseFont = NSFont.systemFont(ofSize: labelFontSize, weight: .bold)
        let font = baseFont.fontDescriptor.withDesign(.rounded)
            .flatMap { NSFont(descriptor: $0, size: labelFontSize) } ?? baseFont
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: style.cgTextBubbleForeground,
        ]
        let label = "\(number)"
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: attrs))
        let bounds = CTLineGetBoundsWithOptions(line, [])
        let ascent = font.ascender
        let descent = abs(font.descender)

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
