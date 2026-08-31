import AppKit
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
    /// The page itself, not an index. Page membership and order are mutable (see
    /// `PDFService.remove/move/insert`), so an index captured at load time goes
    /// stale the moment a page is deleted or reordered. Holding the `PDFPage`
    /// and resolving `pageIndex` through `document.index(for:)` makes every
    /// call site follow structural edits with zero bookkeeping.
    let page: PDFPage
    let sourceURL: URL

    /// Live index of `page` within `document`; `-1` once the page has been
    /// removed from it (an out-of-range index every lookup already rejects,
    /// unlike `NSNotFound`, which is a huge positive number).
    var pageIndex: Int {
        let idx = document.index(for: page)
        return idx == NSNotFound ? -1 : idx
    }

    /// Serializes all background page rasterization. PDFKit page drawing is not
    /// thread-safe across pages of the same document, and renders are reached
    /// from the concurrent `imageLoadQueue` by two independent tasks (the active
    /// page's `loadImage` and the `preloadThumbnails` loop), which can otherwise
    /// draw two pages of one `PDFDocument` simultaneously.
    private static let renderQueue = DispatchQueue(label: "com.simplshot.pdfRender", qos: .userInitiated)

    func renderPage(backingScale: CGFloat = 2.0) -> CGImage? {
        Self.renderQueue.sync {
            renderPageSerialized(backingScale: backingScale)
        }
    }

    private func renderPageSerialized(backingScale: CGFloat) -> CGImage? {
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
    /// Loads one `ImageSession` per page. If the document is password protected,
    /// presents a modal password dialog (retrying on a wrong password) and
    /// returns `[]` if the user cancels. Must be called on the main thread.
    ///
    /// Unlocking mutates the in-memory `PDFDocument`, which every page's
    /// `PDFPageSource` (and thus `PDFExportService`) shares — so unlocking once
    /// here covers display, raster export, and vector PDF re-export.
    static func loadPages(from url: URL) -> [ImageSession] {
        guard let document = PDFDocument(url: url) else { return [] }
        if document.isLocked,
           !unlockInteractively(document, filename: url.lastPathComponent) {
            return []
        }
        let pageCount = document.pageCount
        guard pageCount > 0 else { return [] }

        let groupID = UUID()
        return (0..<pageCount).compactMap { index -> ImageSession? in
            guard let page = document.page(at: index) else { return nil }
            let source = PDFPageSource(document: document, page: page, sourceURL: url)
            return ImageSession(pdfPageSource: source, pdfGroupID: groupID)
        }
    }

    /// Pages to splice into an already-open document from a file the user
    /// dropped or picked: every page of a PDF, or a single page wrapping an
    /// image file. Returns `[]` for anything unreadable or a locked PDF the
    /// user declined to unlock.
    ///
    /// PDF pages are **copied** so they detach from their source document —
    /// inserting a page still owned by another `PDFDocument` leaves the two
    /// documents sharing a page object, and the donor deallocating takes the
    /// page's content with it.
    static func importablePages(from url: URL) -> [PDFPage] {
        if url.pathExtension.lowercased() == "pdf" {
            guard let document = PDFDocument(url: url) else { return [] }
            if document.isLocked,
               !unlockInteractively(document, filename: url.lastPathComponent) {
                return []
            }
            return (0..<document.pageCount).compactMap {
                document.page(at: $0)?.copy() as? PDFPage
            }
        }
        // Rasterize before handing the image to PDFKit: `PDFPage(image:)` raises
        // an uncatchable ObjC exception ("image must not be NULL") for an
        // NSImage with no drawable representation, which `NSImage(contentsOf:)`
        // happily returns for a corrupt or unsupported file.
        guard let image = NSImage(contentsOf: url),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              cg.width > 0, cg.height > 0 else { return [] }

        // `PDFPage(image:)` takes the media box from the NSImage's POINT size and
        // embeds the representation's full pixel data. Sizing the page from
        // `image.size` (which honours the file's DPI) therefore gives a 2× Retina
        // screenshot a sane half-size page while keeping every pixel — sizing it
        // from the pixel count instead would produce a 40-inch-wide page.
        let points = image.size.width > 0 && image.size.height > 0
            ? image.size
            : NSSize(width: cg.width, height: cg.height)
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = points
        let bitmap = NSImage(size: points)
        bitmap.addRepresentation(rep)
        guard let page = PDFPage(image: bitmap) else { return [] }
        return [page]
    }

    /// Removes `page` from its document. No-op if it isn't in one, or if it is
    /// the document's only page (a zero-page PDF isn't a document).
    @discardableResult
    static func removePage(_ page: PDFPage, from document: PDFDocument) -> Bool {
        let idx = document.index(for: page)
        guard idx != NSNotFound, document.pageCount > 1 else { return false }
        document.removePage(at: idx)
        return true
    }

    /// Reorders `document` so its pages match `pages`, in place.
    ///
    /// Used to mirror a thumbnail-strip drag onto the document itself.
    /// Selection-sort by remove-then-reinsert, which touches only the pages that
    /// actually moved. Deliberately NOT `exchangePage(at:withPageAt:)`: that
    /// method throws `NSInvalidArgumentException` ("object cannot be nil") from
    /// inside PDFKit on macOS 26 and takes the app down with it — verified
    /// against a document built page by page.
    static func reorder(_ document: PDFDocument, toMatch pages: [PDFPage]) {
        guard pages.count == document.pageCount else { return }
        for target in 0..<pages.count {
            let page = pages[target]
            let current = document.index(for: page)
            guard current != NSNotFound, current != target else { continue }
            document.removePage(at: current)
            document.insert(page, at: target)
        }
    }

    /// Prompts for the document password until it unlocks or the user cancels.
    private static func unlockInteractively(_ document: PDFDocument, filename: String) -> Bool {
        var lastAttemptFailed = false
        while true {
            guard let password = promptForPassword(filename: filename, retry: lastAttemptFailed) else {
                return false
            }
            if document.unlock(withPassword: password) { return true }
            lastAttemptFailed = true
        }
    }

    private static func promptForPassword(filename: String, retry: Bool) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = retry ? String(localized: "Incorrect Password") : String(localized: "Password Required")
        alert.informativeText = retry
            ? String(localized: "The password for “\(filename)” was incorrect. Please try again.")
            : String(localized: "“\(filename)” is password protected. Enter the password to open it.")
        alert.alertStyle = .informational
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = String(localized: "Password")
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Unlock"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }
}
