import PDFKit

extension PDFPage {
    /// The page's media-box size in points, adjusted for its `/Rotate` value.
    ///
    /// `bounds(for:)` returns the *unrotated* media box, but `draw(with:to:)`
    /// applies the page rotation. Sizing a canvas from the raw bounds therefore
    /// clips 90°/270°-rotated pages — common in multi-page scanned/bitmap PDFs
    /// where the first page is upright but later pages carry `/Rotate 90`.
    /// Swapping width and height for odd quarter-turns yields the true rendered
    /// size so the rotated content fits the canvas exactly.
    var rotatedMediaBoxSize: CGSize {
        let box = bounds(for: .mediaBox)
        return rotation % 180 == 0
            ? box.size
            : CGSize(width: box.height, height: box.width)
    }

    /// Pixel dimensions of the largest bitmap image embedded directly in the
    /// page's `/XObject` resources, or nil for a pure-vector page.
    ///
    /// Only inspects the page's own resources — it does not recurse into nested
    /// form XObjects — which covers the common "one full-page image per page"
    /// scanned/bitmap PDF. Used to pick a raster scale that preserves a scan's
    /// native resolution instead of downsampling it to the media-box point size.
    var maxEmbeddedImagePixelSize: CGSize? {
        guard let dict = pageRef?.dictionary else { return nil }
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dict, "Resources", &resources),
              let resources else { return nil }
        var xobjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects),
              let xobjects else { return nil }

        var maxSize = CGSize.zero
        withUnsafeMutablePointer(to: &maxSize) { sizePtr in
            CGPDFDictionaryApplyFunction(xobjects, { _, object, info in
                guard let info else { return }
                var stream: CGPDFStreamRef?
                guard CGPDFObjectGetValue(object, .stream, &stream),
                      let stream,
                      let streamDict = CGPDFStreamGetDictionary(stream) else { return }
                var subtype: UnsafePointer<Int8>?
                guard CGPDFDictionaryGetName(streamDict, "Subtype", &subtype),
                      let subtype, String(cString: subtype) == "Image" else { return }
                var w: CGPDFInteger = 0, h: CGPDFInteger = 0
                CGPDFDictionaryGetInteger(streamDict, "Width", &w)
                CGPDFDictionaryGetInteger(streamDict, "Height", &h)
                let p = info.assumingMemoryBound(to: CGSize.self)
                if CGFloat(w) * CGFloat(h) > p.pointee.width * p.pointee.height {
                    p.pointee = CGSize(width: CGFloat(w), height: CGFloat(h))
                }
            }, sizePtr)
        }
        return (maxSize.width > 0 && maxSize.height > 0) ? maxSize : nil
    }

    /// The scale at which to rasterize this page.
    ///
    /// At least `minimumScale` (so vector pages stay crisp at the display's
    /// backing scale), but raised to preserve the native resolution of an
    /// embedded bitmap — otherwise a 300 DPI scan, whose media box is small in
    /// points, would be downsampled. Capped so a pathological input can't
    /// allocate an enormous raster.
    func rasterScale(minimumScale: CGFloat) -> CGFloat {
        let box = bounds(for: .mediaBox)
        guard box.width > 0, box.height > 0 else { return minimumScale }
        var scale = minimumScale
        if let image = maxEmbeddedImagePixelSize {
            scale = max(scale, max(image.width / box.width, image.height / box.height))
        }
        // Cap the longest rendered edge (≈ a 600 DPI Letter page) to bound memory.
        let maxEdge: CGFloat = 8192
        return min(scale, maxEdge / max(box.width, box.height))
    }
}

struct PDFPageSource {
    let document: PDFDocument
    let pageIndex: Int
    let sourceURL: URL

    func renderPage(backingScale: CGFloat = 2.0) -> CGImage? {
        guard let page = document.page(at: pageIndex) else { return nil }
        let pointSize = page.rotatedMediaBoxSize
        let width = Int((pointSize.width * backingScale).rounded())
        let height = Int((pointSize.height * backingScale).rounded())
        guard width > 0, height > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.setFillColor(CGColor.white)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.scaleBy(x: backingScale, y: backingScale)
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()
    }
}

enum PDFService {
    static func loadPages(from url: URL) -> [ImageSession] {
        guard let document = PDFDocument(url: url) else { return [] }
        let pageCount = document.pageCount
        guard pageCount > 0 else { return [] }

        let groupID = UUID()
        return (0..<pageCount).compactMap { index in
            let source = PDFPageSource(document: document, pageIndex: index, sourceURL: url)
            return ImageSession(pdfPageSource: source, pdfGroupID: groupID)
        }
    }
}
