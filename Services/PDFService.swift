import PDFKit

struct PDFPageSource {
    let document: PDFDocument
    let pageIndex: Int
    let sourceURL: URL

    func renderPage(backingScale: CGFloat = 2.0) -> CGImage? {
        guard let page = document.page(at: pageIndex) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        let width = Int(bounds.width * backingScale)
        let height = Int(bounds.height * backingScale)
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
