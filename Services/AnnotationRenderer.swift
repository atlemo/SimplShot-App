import AppKit
import CoreGraphics
import CoreImage
import CoreText
import Metal
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
        /// The source file's format can be decoded but not encoded by ImageIO
        /// (e.g. JPEG XL), so an in-place overwrite is impossible. Callers
        /// should fall back to "Save As".
        case unsupportedEncodeFormat

        var errorDescription: String? {
            switch self {
            case .cannotCreateContext:     return String(localized: "Failed to create graphics context for annotation rendering")
            case .cannotCreateOutputImage: return String(localized: "Failed to create output image")
            case .cannotCropImage:         return String(localized: "Failed to crop image")
            case .unsupportedEncodeFormat: return String(localized: "This image format can be opened but not written. Use “Save As…” to choose a format.")
            }
        }
    }

    /// Composite annotations onto the base image, optionally cropping.
    /// - Parameters:
    ///   - image: The base screenshot (at full pixel resolution).
    ///   - annotations: Annotations with coordinates in image-pixel space.
    ///     Style values (strokeWidth, fontSize) are scaled by `styleScale` —
    ///     set that before calling for high-DPI images.
    ///   - cropRect: Optional crop rect in image-pixel space. `nil` means no crop.
    ///   - watermark: Watermark settings. Applied on top of all annotations.
    /// - Returns: The composited CGImage.
    func render(
        image: CGImage,
        annotations: [Annotation],
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

        // 3. Highlighter ink, under everything else and multiplied into the
        //    page — see `drawHighlights`.
        drawHighlights(annotations, in: context)

        // 3b. Spotlight dim (pixelate was already drawn before the flip,
        //    so it appears as image content being dimmed).
        let spotlightAnnotations = annotations.filter { $0.tool == .spotlight }
        if !spotlightAnnotations.isEmpty {
            drawSpotlights(
                spotlightAnnotations,
                imageWidth: width,
                imageHeight: height,
                in: context
            )
        }

        // 4. Draw remaining annotations on top of the spotlight dim.
        for annotation in annotations {
            if annotation.tool == .spotlight || annotation.tool == .pixelate { continue }
            if annotation.tool == .magnifier {
                drawMagnifier(annotation, from: image, in: context)
                continue
            }
            drawAnnotation(annotation, drawingHeight: CGFloat(height), in: context)
        }

        // 4. Draw watermark on top of all annotations.
        //    Context is in flipped/top-left space, so CGImage drawing needs a local unflip.
        if watermark.isEnabled, let path = watermark.imagePath,
           let aspect = WatermarkImageCache.aspect(atPath: path) {
            // Offsets and width are image-pixel units (matching the canvas
            // preview's `* scale`); the context is image-pixel space already, so
            // no backing-scale multiplier — same convention as strokeWidth/fontSize.
            let marginH = CGFloat(watermark.edgeOffset)
            let marginV = CGFloat(watermark.bottomOffset)
            let targetW = max(1, CGFloat(watermark.widthPx))
            let targetH = max(1, targetW / aspect)

            if let wmCG = WatermarkImageCache.rasterized(
                atPath: path, size: CGSize(width: targetW, height: targetH)
            ) {
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

        drawHighlights(annotations, in: context)

        let spotlightAnnotations = annotations.filter { $0.tool == .spotlight }
        if !spotlightAnnotations.isEmpty {
            drawSpotlights(
                spotlightAnnotations,
                imageWidth: widthPx,
                imageHeight: heightPx,
                in: context
            )
        }

        for annotation in annotations {
            if annotation.tool == .spotlight { continue }
            if annotation.tool == .pixelate || annotation.tool == .magnifier { continue }  // unsupported in vector mode
            drawAnnotation(annotation, drawingHeight: CGFloat(heightPx), in: context)
        }

        if watermark.isEnabled, let path = watermark.imagePath,
           let aspect = WatermarkImageCache.aspect(atPath: path) {
            // Image-pixel units, matching the raster path and canvas preview.
            // The vector context is pre-scaled to image-pixel space (see the
            // `1/backingScale` above), so no backing-scale multiplier here either.
            let marginH = CGFloat(watermark.edgeOffset)
            let marginV = CGFloat(watermark.bottomOffset)
            let targetW = max(1, CGFloat(watermark.widthPx))
            let targetH = max(1, targetW / aspect)

            if let wmCG = WatermarkImageCache.rasterized(
                atPath: path, size: CGSize(width: targetW, height: targetH)
            ) {
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
    private func drawAnnotation(_ annotation: Annotation, drawingHeight: CGFloat, in context: CGContext) {
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
                      arrowStyle: annotation.style.arrowStyle, curvature: annotation.arrowCurvature,
                      sketchSeed: annotation.sketchSeed,
                      color: color, lineWidth: lineWidth, in: context)
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
        case .angle:
            drawAngle(annotation, color: color, lineWidth: lineWidth, in: context)
        case .freeDraw:
            drawFreeDraw(points: annotation.points, in: context)
        case .line:
            drawLine(from: annotation.startPoint, to: annotation.endPoint, in: context)
        case .rectangle:
            drawRectangle(annotation.boundingRect, fillColor: annotation.style.cgFillColor, color: color, in: context)
        case .circle:
            drawEllipse(in: annotation.boundingRect, fillColor: annotation.style.cgFillColor, color: color, in: context)
        case .triangle:
            drawTriangle(annotation.boundingRect, fillColor: annotation.style.cgFillColor, color: color, in: context)
        case .star:
            drawStar(annotation.boundingRect, fillColor: annotation.style.cgFillColor, color: color, in: context)
        case .text:
            drawText(annotation.text, at: annotation.startPoint, style: annotation.style, textWidth: annotation.textWidth, rotation: annotation.rotation, drawingHeight: drawingHeight, in: context)
        case .spotlight:
            break
        case .numberedStep:
            drawNumberedStep(annotation.stepNumber, at: annotation.startPoint, style: annotation.style, in: context)
        case .sticker:
            drawSticker(annotation.text, in: annotation.boundingRect, in: context)
        case .highlight:
            break // Drawn in its own multiplied pass (see drawHighlights)
        case .select, .textSelect, .crop, .pixelate:
            break // Not drawn here (.pixelate is handled before the coordinate flip)
        case .magnifier:
            break // Needs the source image — see drawMagnifier, called from render()
        }

        context.restoreGState()
    }

    /// Highlighter ink for every `.highlight`, in one pass beneath the other
    /// annotations and blended with **multiply**.
    ///
    /// Multiply is the whole point of the tool: black text stays black
    /// (0 × anything = 0) while the paper takes the ink colour. Compositing the
    /// same colour over the page lightens every glyph it covers toward the ink —
    /// the washed-out look source-over gives a highlighter, and the same
    /// mistake film grain made before it became an overlay blend.
    ///
    /// `HighlightInkLayer` paints the identical rects and radii in the live
    /// preview, at `× scale` instead of image space; the radius is a fixed
    /// fraction of a band's height, which is linear in scale, so the two agree
    /// at any zoom. Bands are image geometry and take no `styleScale`.
    ///
    /// The context is expected to be in flipped (top-left origin) image-pixel
    /// space, like the rest of the annotation drawing.
    private func drawHighlights(_ annotations: [Annotation], in context: CGContext) {
        let highlights = annotations.filter { $0.tool == .highlight }
        guard !highlights.isEmpty else { return }

        context.saveGState()
        for annotation in highlights {
            let bands = annotation.highlightRects
            guard !bands.isEmpty else { continue }

            func fill(_ color: CGColor, blend: CGBlendMode) {
                context.setBlendMode(blend)
                context.setFillColor(color)
                for band in bands {
                    let radius = HighlightGeometry.cornerRadius(for: band)
                    context.addPath(CGPath(roundedRect: band,
                                           cornerWidth: radius, cornerHeight: radius,
                                           transform: nil))
                    context.fillPath()
                }
            }

            if annotation.highlightKnocksOutText {
                // result = 1 − (1 − C)·S, in two standard blends: multiply the
                // page by the ink's complement, then invert what that produced.
                // White paper lands back on C (the band still shows the picked
                // colour) and black text lands on white.
                fill(NSColor(HighlightGeometry.complement(annotation.highlightColor)).cgColor,
                     blend: .multiply)
                fill(CGColor.white, blend: .difference)
            } else {
                fill(annotation.cgHighlightColor, blend: .multiply)
            }
        }
        context.restoreGState()
    }

    private func drawArrow(from start: CGPoint, to end: CGPoint, arrowStyle: ArrowStyle, curvature: CGVector, sketchSeed: UInt64, color: CGColor, lineWidth: CGFloat, in context: CGContext) {
        context.setLineCap(.round)
        context.setLineJoin(.round)
        switch arrowStyle {
        case .chevron:  drawArrowChevron(from: start, to: end, lineWidth: lineWidth, in: context)
        case .triangle: drawArrowTriangle(from: start, to: end, color: color, lineWidth: lineWidth, in: context)
        case .curved, .double:
            // Shaft outline + head triangle(s) as ONE path, painted with one
            // fill — no shaft/head seam, translucent colors don't double-darken,
            // and the live preview draws the identical ArrowGeometry path.
            let path = ArrowGeometry.fillPath(start: start, end: end, curvature: curvature,
                                              doubleEnded: arrowStyle == .double, lineWidth: lineWidth)
            context.setFillColor(color)
            context.addPath(path)
            context.fillPath(using: .winding)
        case .sketch:
            // Gritty ink ribbon — one fillable path, seeded per annotation so
            // the export texture matches the preview exactly.
            let path = ArrowGeometry.sketchPath(start: start, end: end,
                                                lineWidth: lineWidth, seed: sketchSeed)
            context.setFillColor(color)
            context.addPath(path)
            context.fillPath(using: .winding)
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
        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        drawPillLabel(label, centeredAt: mid, color: color, strokeIsLight: strokeIsLight,
                      strokeWidth: strokeWidth, in: context)
    }

    /// Protractor: two rays from the vertex, filled dots at the three points,
    /// an arc spanning the interior angle, and a degree pill on the bisector.
    /// All geometry comes from AngleGeometry — identical to the live preview.
    private func drawAngle(_ annotation: Annotation, color: CGColor, lineWidth: CGFloat, in context: CGContext) {
        let a = annotation.startPoint
        let v = annotation.angleVertex
        let b = annotation.endPoint

        context.addPath(AngleGeometry.raysPath(a: a, vertex: v, b: b))
        context.strokePath()

        let radius = AngleGeometry.arcRadius(a: a, vertex: v, b: b, lineWidth: lineWidth)
        context.saveGState()
        context.setLineWidth(lineWidth * 0.7)   // arc slightly lighter than the rays
        // Dashed, butt caps for crisp dashes — must match the overlay's
        // StrokeStyle(dash: [w*2, w*1.6]).
        context.setLineCap(.butt)
        context.setLineDash(phase: 0, lengths: [lineWidth * 2, lineWidth * 1.6])
        context.addPath(AngleGeometry.arcPath(a: a, vertex: v, b: b, radius: radius))
        context.strokePath()
        context.restoreGState()

        context.setFillColor(color)
        context.addPath(AngleGeometry.dotsPath(a: a, vertex: v, b: b, lineWidth: lineWidth))
        context.fillPath()

        // labelDistance 0: the pill centers ON the arc, capping it visually.
        let labelCenter = AngleGeometry.labelCenter(a: a, vertex: v, b: b,
                                                    radius: radius, labelDistance: 0)
        drawPillLabel("\(AngleGeometry.degrees(a: a, vertex: v, b: b))°",
                      centeredAt: labelCenter, color: color,
                      strokeIsLight: annotation.style.isLight,
                      strokeWidth: annotation.style.strokeWidth, in: context)
    }

    /// Capsule label used by the measurement and angle tools.
    /// Sizing must match the SwiftUI labels in AnnotationOverlayView exactly.
    private func drawPillLabel(_ label: String, centeredAt center: CGPoint, color: CGColor, strokeIsLight: Bool, strokeWidth: CGFloat, in context: CGContext) {
        // Font grows gently with stroke width (so a thick stroke gets a
        // slightly larger label, not a huge one), then ×styleScale for high-DPI.
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
        let bgRect = CGRect(x: center.x - bgWidth / 2, y: center.y - bgHeight / 2, width: bgWidth, height: bgHeight)

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

    private func drawRectangle(_ rect: CGRect, fillColor: CGColor?, color: CGColor, in context: CGContext) {
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

    /// Extracts a region of `sourceImage`, pixelates it, and draws it back.
    /// `annotationRect` is in top-left image-pixel coordinates (matching annotation storage).
    /// The context must be in its default native (bottom-left origin) CG space — call before flipping.
    ///
    /// Uses the same mosaic algorithm as the editor preview (`PixelatePreviewView`):
    /// box-average downscale to one pixel per block, then nearest-neighbor upscale,
    /// with the block grid anchored at the region's top-left corner. Do NOT swap
    /// this back to CIPixellate — that filter point-samples each cell (no averaging)
    /// and anchors its grid at `inputCenter`, so the exported blocks land in
    /// different places with different colors than the preview showed.
    private func drawPixelate(annotationRect: CGRect, scale: CGFloat, from sourceImage: CGImage, imageHeight: Int, in context: CGContext) {
        let pixelRect = PixelateMosaic.sampledRect(annotationRect, in: sourceImage)
        guard !pixelRect.isEmpty,
              let smallImage = PixelateMosaic.downsample(sourceImage, rect: pixelRect, blockScale: scale)
        else { return }

        // Scale back up with interpolation off so the blocks stay sharp.
        let destY = CGFloat(imageHeight) - pixelRect.maxY
        context.saveGState()
        context.interpolationQuality = .none
        context.draw(smallImage, in: CGRect(
            x: pixelRect.minX,
            y: destY,
            width: pixelRect.width,
            height: pixelRect.height
        ))
        context.restoreGState()
    }

    /// Draws a `.magnifier` lens (see `MagnifierLens`). The context is in the
    /// flipped, top-left-origin image-pixel space the annotations are drawn in.
    ///
    /// Magnifies `source` — the base image without other annotations, exactly
    /// what the preview samples. Needs raster pixels, so vector PDF export
    /// skips it like pixelate.
    private func drawMagnifier(_ annotation: Annotation, from source: CGImage, in context: CGContext) {
        MagnifierLens.draw(source: source, rect: annotation.boundingRect,
                           magnification: annotation.style.magnification, in: context)
    }

    /// Draws a single dimming overlay with one clear cutout per spotlight annotation.
    private func drawSpotlights(
        _ annotations: [Annotation],
        imageWidth: Int,
        imageHeight: Int,
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

    private func drawText(_ text: String, at point: CGPoint, style: AnnotationStyle, textWidth: CGFloat?, rotation: CGFloat = 0, drawingHeight: CGFloat, in context: CGContext) {
        guard !text.isEmpty else { return }

        // Turn the whole bubble about its centre. The drawing space is y-down
        // (flipped), where CG's rotation matrix is the same clockwise-positive one
        // as `TextBubbleGeometry.rotate` and SwiftUI's `rotationEffect`. The
        // CTFrame un-flip below composes with this exactly (it reflects, and the
        // rect it is given was reflected once already), so nothing in it changes.
        context.saveGState()
        defer { context.restoreGState() }
        if rotation != 0 {
            context.translateBy(x: point.x, y: point.y)
            context.rotate(by: rotation)
            context.translateBy(x: -point.x, y: -point.y)
        }

        // Text bubbles are NOT scaled by styleScale: their box geometry and the
        // interactive resize handles live in stored image-pixel space, so the
        // font size stays in image-pixel units (matching the preview's
        // `fontSize * scale`). Users size text directly via the font control.
        let fontSize = style.fontSize
        // Resolved by the same TextFont the live overlay/editor use
        // (AnnotationOverlayView, GrowingTextField), so the exported bubble
        // wraps and sizes identically.
        let font = style.textFont.nsFont(size: fontSize)
        let bgColor = style.cgTextPill
        // Ink is the stroke colour; the pill, when there is one, is the fill colour.
        let fgColor = style.cgTextInk
        let drawsPill = style.textHasBackground

        let hPad = fontSize * 0.55
        let vPad = fontSize * 0.25
        let ascent = font.ascender
        let descent = abs(font.descender)
        let lineHeight = ascent + descent
        let lineSpacing = fontSize * 0.22
        let cornerRadius = fontSize * 0.45

        if let fixedBubbleWidth = textWidth {
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

            if drawsPill {
                context.saveGState()
                context.setFillColor(bgColor)
                let pillPath = CGPath(roundedRect: bgRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
                context.addPath(pillPath)
                context.fillPath()
                context.restoreGState()
            }

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

            if drawsPill {
                context.saveGState()
                context.setFillColor(bgColor)
                let pillPath = CGPath(roundedRect: bgRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
                context.addPath(pillPath)
                context.fillPath()
                context.restoreGState()
            }

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

    private func drawNumberedStep(_ number: Int, at point: CGPoint, style: AnnotationStyle, in context: CGContext) {
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

    /// Emoji sticker, filling `rect` (image-pixel space).
    ///
    /// Not scaled by `styleScale` — the glyph's size IS the stored rect, which
    /// is already in image pixels. The point size comes from `StickerGeometry`,
    /// the same helper the live overlay uses, so preview and export agree.
    private func drawSticker(_ emoji: String, in rect: CGRect, in context: CGContext) {
        guard !emoji.isEmpty, rect.width > 0, rect.height > 0 else { return }

        // System font + Core Text's fallback resolves emoji to the colour
        // emoji face. Never name that font directly — a PostScript name that
        // isn't installed silently degrades to Helvetica.
        let font = NSFont.systemFont(ofSize: StickerGeometry.fontSize(forBox: rect.size))
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: emoji, attributes: [.font: font])
        )
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))

        // Centre the glyph's own layout box on the rect, matching the overlay's
        // centred `Text`.
        context.saveGState()
        context.translateBy(x: rect.midX - width / 2, y: rect.midY + (ascent - descent) / 2)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }
}


// MARK: - Pixelate Mosaic

/// The mosaic behind the pixelate tool, shared by the on-canvas preview
/// (`PixelatePreviewView`) and the export (`AnnotationRenderer.drawPixelate`).
///
/// One source, because the two have to agree block for block and the comment
/// claiming they did was wrong for years: the preview built its mosaic with
/// `NSImage.lockFocus()`, which renders at the *screen's* backing scale, so a
/// 10×6-block mosaic came back 20×12 pixels (measured) and every block arrived
/// as four unequal ones. It was also AppKit drawing, which pinned sampling to
/// the main thread; this is plain CoreGraphics and runs anywhere.
enum PixelateMosaic {

    /// The part of `annotationRect` that actually lies on the image. Empty when
    /// the annotation is entirely outside it.
    static func sampledRect(_ annotationRect: CGRect, in source: CGImage) -> CGRect {
        let bounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        return annotationRect.intersection(bounds)
    }

    /// Crops `source` to `rect` and downscales to one pixel per mosaic block.
    /// Draw the result back at `rect`'s size with `interpolationQuality = .none`
    /// (CoreGraphics) or `.interpolation(.none)` (SwiftUI) for sharp blocks.
    ///
    /// `rect` is in the image's own top-left-origin space — the same space
    /// annotations live in, so no flip is needed on either side.
    static func downsample(_ source: CGImage, rect: CGRect, blockScale: CGFloat) -> CGImage? {
        guard !rect.isEmpty, let cropped = source.cropping(to: rect) else { return nil }

        let blockSize = max(2, blockScale)
        let smallW = max(1, Int(rect.width / blockSize))
        let smallH = max(1, Int(rect.height / blockSize))
        guard let context = CGContext(
            data: nil,
            width: smallW,
            height: smallH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: smallW, height: smallH))
        return context.makeImage()
    }
}


// MARK: - Magnifier Lens

/// The glass magnifier behind `.magnifier`: the circle inscribed in the
/// annotation's (square) rect shows the picture beneath it enlarged
/// `magnification`×, with a smooth bend toward the rim and a frosted-glass finish.
///
/// ### One shader, on the GPU, for preview AND export
/// The whole lens — warp, shading, shadow — is one fragment shader
/// (`MagnifierGPU.source`). The live preview (`MagnifierMetalView`) draws it into
/// a transparent `MTKView` on every pointer event, so moving or resizing a lens
/// costs one quad however large it is; the export (`MagnifierLens.draw`) runs the
/// same shader into an offscreen texture and composites the result. Two
/// implementations of the look would drift; this cannot.
///
/// The shader is compiled **at runtime** from the source string
/// (`makeLibrary(source:)`), so there is no `.metal` file in the project — a
/// `.metal` file needs Xcode's separately-downloaded Metal Toolchain to build,
/// and would have to be registered in both app targets.
///
/// ### The optics
/// A lens is radially symmetric, so the warp is one function of the normalised
/// radius ρ = r / R (`sourceScale`): the source pixel under lens pixel `d` lies
/// at `d · g(ρ)`. `g` is `1 / zoom` (uniform zoom) in the middle; in a narrow
/// band at the rim the lookup radius peaks and **turns back toward the centre**,
/// so the edge shows a mirrored strip of the picture just inside it, folded in.
/// The lookup never leaves the lens's own circle.
///
/// The lens samples the canvas *without* other annotations — what the preview's
/// `sourceImage` and the export's base image both are.
enum MagnifierLens {

    static let defaultZoom: CGFloat = 2
    static let zoomRange: ClosedRange<CGFloat> = 1.25...6
    static let zoomStep: CGFloat = 0.25
    /// Smallest lens a drag may leave behind, in image pixels.
    static let minimumDiameter: CGFloat = 40

    /// Fraction of the radius where the rim fold begins.
    static let rimStart: Double = 0.90
    /// Where in the rim band (0 = start, 1 = edge) the lookup turns back toward
    /// the centre. Earlier = a deeper fold (more of the band is mirrored).
    static let foldAt: Double = 0.62
    /// Drop shadow, as fractions of the radius. Faint: it only lifts the glass.
    static let shadowOpacity: Double = 0.12
    static let shadowBlur: Double = 0.12
    static let shadowOffset: Double = 0.04

    static func clampedZoom(_ zoom: CGFloat) -> CGFloat {
        min(max(zoom, zoomRange.lowerBound), zoomRange.upperBound)
    }

    // MARK: Geometry

    /// The lens circle for an annotation rect (image-pixel space).
    static func circle(for rect: CGRect) -> (center: CGPoint, radius: CGFloat) {
        (CGPoint(x: rect.midX, y: rect.midY), max(min(rect.width, rect.height) / 2, 1))
    }

    /// Room around the lens for its shadow, in whole pixels (or points).
    static func shadowMargin(radius: CGFloat) -> CGFloat {
        (radius * 0.24).rounded(.up) + 1
    }

    /// Where the lens's bitmap goes in image space: a whole-pixel square
    /// holding the lens plus its shadow, centred on the annotation.
    static func frame(for rect: CGRect) -> CGRect {
        let (c, r) = circle(for: rect)
        let side = (r * 2).rounded(.up) + 2 * shadowMargin(radius: r)
        return CGRect(x: (c.x - side / 2).rounded(), y: (c.y - side / 2).rounded(),
                      width: side, height: side)
    }

    // MARK: Optics

    /// `g(ρ)`: how far from the lens centre, as a multiple of the lens pixel's
    /// own distance from it, the source pixel for normalised radius `rho` lies.
    /// The shader implements the same function.
    ///
    /// The lookup radius is `f(ρ) = ρ · g(ρ) = ρ/zoom − K·x³`, `x = max(ρ − rimStart, 0)`:
    /// uniform zoom, then a cubic that bends over, peaks at `foldAt` of the rim
    /// band and **turns back toward the centre**. The rim therefore shows a
    /// mirrored strip of what lies just inside it, folded in — never content from
    /// outside the lens — which is how the glass "breaks" at its edge. (An
    /// earlier version kept reading further OUT at the rim, compressing the
    /// picture from beyond the lens into the edge; that folds the wrong way.)
    /// The cubic has zero slope and zero curvature where it starts, so the zoom
    /// leaves its uniform value without a crease.
    static func sourceScale(rho: Double, zoom: Double) -> Double {
        let span = 1 - rimStart
        let k = 1 / (3 * zoom * foldAt * foldAt * span * span)
        let x = max(rho - rimStart, 0)
        return 1 / zoom - k * x * x * x / max(rho, 1e-6)
    }

    /// `g(1)`: the source radius under the very rim, in lens radii.
    static func rimReach(zoom: Double) -> Double {
        sourceScale(rho: 1, zoom: zoom)
    }

    /// Lookup radius `f(ρ) = ρ · g(ρ)`, in lens radii.
    static func lookupRadius(rho: Double, zoom: Double) -> Double {
        rho * sourceScale(rho: rho, zoom: zoom)
    }

    // MARK: Export

    /// Draws the lens into `context`, which is in the flipped, top-left-origin
    /// image-pixel space the annotations are drawn in. `source` is the base
    /// image, in that same space.
    static func draw(source: CGImage, rect: CGRect, magnification: CGFloat, in context: CGContext) {
        guard let gpu = MagnifierGPU.shared,
              let (lens, frame) = gpu.renderLens(source: source, rect: rect,
                                                 zoom: clampedZoom(magnification))
        else { return }
        context.saveGState()
        context.translateBy(x: frame.minX, y: frame.maxY)   // un-flip locally: the bitmap is upright
        context.scaleBy(x: 1, y: -1)
        context.draw(lens, in: CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
        context.restoreGState()
    }
}

// MARK: - Magnifier GPU

/// Metal pipeline shared by the preview and the export (see `MagnifierLens`).
final class MagnifierGPU: @unchecked Sendable {

    /// nil when there is no usable GPU; the lens then simply isn't drawn.
    static let shared = MagnifierGPU()

    /// Must match the MSL `Uniforms` struct field for field.
    struct Uniforms {
        var lensCenter: SIMD2<Float>   // lens centre in output pixels
        var srcCenter: SIMD2<Float>    // lens centre in source-image pixels
        var texSize: SIMD2<Float>
        var radius: Float              // lens radius in output pixels
        var srcPerOut: Float           // source pixels per output pixel
        var zoom: Float
        var pad: Float = 0
    }

    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let sampler: MTLSamplerState
    private let lock = NSLock()
    private var cachedImage: CGImage?
    private var cachedTexture: (MTLTexture, CGColorSpace)?

    static let pixelFormat = MTLPixelFormat.bgra8Unorm

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.source, options: nil),
              let vertex = library.makeFunction(name: "lensVertex"),
              let fragment = library.makeFunction(name: "lensFragment")
        else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = Self.pixelFormat
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.mipFilter = .linear
        // Outside the picture is transparent, not smeared edge pixels.
        samplerDescriptor.sAddressMode = .clampToZero
        samplerDescriptor.tAddressMode = .clampToZero
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor),
              let sampler = device.makeSamplerState(descriptor: samplerDescriptor)
        else { return nil }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        self.sampler = sampler
    }

    // MARK: Texture

    /// The image as a premultiplied BGRA texture in its own colour space, and
    /// that space. One entry is cached (the canvas the lens is over), by identity.
    func texture(for image: CGImage) -> (MTLTexture, CGColorSpace)? {
        lock.lock(); defer { lock.unlock() }
        if let cachedImage, cachedImage === image, let cachedTexture { return cachedTexture }
        let w = image.width, h = image.height
        guard w > 0, h > 0, w <= 16384, h <= 16384 else { return nil }
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        // Keep the picture's own RGB space, so colours are interpreted the way
        // the rest of the app interprets them (screenshots are Display P3).
        var space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        var context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                space: space, bitmapInfo: info)
        if context == nil {
            space = CGColorSpace(name: CGColorSpace.sRGB)!
            context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                space: space, bitmapInfo: info)
        }
        guard let context, let data = context.data else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: w, height: h))
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.pixelFormat, width: w, height: h, mipmapped: true)
        descriptor.usage = [.shaderRead, .renderTarget]   // render-target: needed to generate mipmaps
        descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                        withBytes: data, bytesPerRow: context.bytesPerRow)
        // Mipmaps, so the rim — where a lot of picture is squeezed into a narrow
        // band — is filtered instead of aliasing into zebra stripes. The middle
        // of the lens magnifies, so it still reads level 0 and stays sharp.
        if let commands = queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
            commands.commit()
            commands.waitUntilCompleted()
        }
        cachedImage = image
        cachedTexture = (texture, space)
        return (texture, space)
    }

    // MARK: Draw

    /// Encodes the lens into `encoder`, a pass over a texture/drawable.
    func encode(_ uniforms: Uniforms, texture: MTLTexture, into encoder: MTLRenderCommandEncoder) {
        var u = uniforms
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    /// The lens as an upright bitmap (lens + shadow) and where it goes in image
    /// space, one output pixel per image pixel. For the export.
    func renderLens(source: CGImage, rect: CGRect, zoom: CGFloat) -> (CGImage, CGRect)? {
        guard let (texture, space) = texture(for: source) else { return nil }
        let frame = MagnifierLens.frame(for: rect)
        let side = Int(frame.width)
        let (c, r) = MagnifierLens.circle(for: rect)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.pixelFormat, width: side, height: side, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
        guard let target = device.makeTexture(descriptor: descriptor),
              let commands = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encode(Uniforms(lensCenter: SIMD2(Float(c.x - frame.minX), Float(c.y - frame.minY)),
                        srcCenter: SIMD2(Float(c.x), Float(c.y)),
                        texSize: SIMD2(Float(texture.width), Float(texture.height)),
                        radius: Float(r), srcPerOut: 1, zoom: Float(zoom)),
               texture: texture, into: encoder)
        encoder.endEncoding()
        if !device.hasUnifiedMemory, let blit = commands.makeBlitCommandEncoder() {
            blit.synchronize(resource: target)
            blit.endEncoding()
        }
        commands.commit()
        commands.waitUntilCompleted()

        let bytesPerRow = side * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * side)
        target.getBytes(&bytes, bytesPerRow: bytesPerRow,
                        from: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: bytesPerRow, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                                           | CGBitmapInfo.byteOrder32Little.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent)
        else { return nil }
        return (image, frame)
    }

    // MARK: Shader

    /// The lens. Coordinates are output pixels, origin top-left (Metal's
    /// framebuffer convention, matching the image).
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float2 lensCenter;
        float2 srcCenter;
        float2 texSize;
        float radius;
        float srcPerOut;
        float zoom;
        float pad;
    };

    struct VOut { float4 position [[position]]; };

    vertex VOut lensVertex(uint vid [[vertex_id]]) {
        // One triangle covering the whole target.
        float2 p[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
        VOut o;
        o.position = float4(p[vid], 0.0, 1.0);
        return o;
    }

    constant float kRimStart = \(MagnifierLens.rimStart);
    constant float kFoldAt = \(MagnifierLens.foldAt);
    constant float kShadowOpacity = \(MagnifierLens.shadowOpacity);
    constant float kShadowBlur = \(MagnifierLens.shadowBlur);
    constant float kShadowOffset = \(MagnifierLens.shadowOffset);

    // g(rho) — keep in step with MagnifierLens.sourceScale.
    float sourceScale(float rho, float zoom) {
        float span = 1.0 - kRimStart;
        float k = 1.0 / (3.0 * zoom * kFoldAt * kFoldAt * span * span);
        float x = max(rho - kRimStart, 0.0);
        return 1.0 / zoom - k * x * x * x / max(rho, 1e-6);
    }

    fragment float4 lensFragment(VOut in [[stage_in]],
                                 constant Uniforms &u [[buffer(0)]],
                                 texture2d<float> tex [[texture(0)]],
                                 sampler smp [[sampler(0)]]) {
        float2 d = in.position.xy - u.lensCenter;
        float dist = length(d);
        float R = u.radius;
        float rho = dist / R;
        float coverage = clamp(R - dist + 0.5, 0.0, 1.0);

        float4 lens = float4(0.0);
        if (coverage > 0.0) {
            float k = sourceScale(min(rho, 1.0), u.zoom) * u.srcPerOut;
            float4 c = tex.sample(smp, (u.srcCenter + d * k) / u.texSize);

            // Frosted glass, neutral white: a broad fade toward the bottom, a
            // glow round the rim, a soft top-left highlight, a light edge ring.
            float nx = d.x / R, ny = d.y / R;
            float belly = smoothstep(0.15, 1.05, ny);
            float white = 0.72 * belly * belly;
            float fresnel = smoothstep(0.90, 1.0, rho);
            white += 0.30 * fresnel;
            float2 dir = d / max(dist, 1e-3);
            float band = smoothstep(0.80, 0.93, rho) * (1.0 - smoothstep(0.975, 1.0, rho));
            float key = max(0.0, dot(dir, float2(-0.62, -0.78)));
            float k2 = key * key;
            white += band * 0.40 * k2 * k2 * key;
            float2 q = float2(nx + 0.38, ny + 0.50);
            float along = (q.x - q.y) * 0.7071 / 0.28;
            float across = (q.x + q.y) * 0.7071 / 0.12;
            white += 0.28 * exp(-(along * along + across * across));
            float ring = (rho - 0.965) / 0.016;
            white += 0.22 * exp(-ring * ring);
            white = min(white, 0.85);

            c = float4(c.rgb * (1.0 - white) + white, c.a * (1.0 - white) + white);
            lens = c * coverage;
        }

        // Soft shadow: a blurred disc, offset downward.
        float shadowDist = length(d - float2(0.0, R * kShadowOffset));
        float blur = R * kShadowBlur;
        float shadow = kShadowOpacity * (1.0 - smoothstep(R - blur, R + blur, shadowDist));
        return lens + float4(0.0, 0.0, 0.0, shadow) * (1.0 - lens.a);
    }
    """
}
