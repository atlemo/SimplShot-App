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

    func renderPage(backingScale: CGFloat = 2.0) -> CGImage? {
        PDFService.documentQueue.sync {
            renderPageSerialized(backingScale: backingScale)
        }
    }

    private func renderPageSerialized(backingScale: CGFloat) -> CGImage? {
        // A page deleted while a preload was already in flight is still held by
        // that loop's captured session list. Drawing it is what PDFKit logs as
        // "Drawing a PDFPage when its PDFDocument is nil is unsupported" — it
        // does still produce correct pixels today (measured), but it is
        // explicitly unsupported, and nothing needs the result: the session is
        // on its way out. Decline rather than rely on undefined behaviour.
        guard document.index(for: page) != NSNotFound else { return nil }
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
    /// Serializes everything that touches a `PDFDocument`'s page tree: page
    /// rasterization AND structural edits.
    ///
    /// Rasterization needs it because PDFKit page drawing is not thread-safe
    /// across pages of one document, and renders are reached from the concurrent
    /// `imageLoadQueue` by two independent tasks (the active page's `loadImage`
    /// and the `preloadThumbnails` loop).
    ///
    /// Structural edits need it because they mutate the page tree PDFKit may be
    /// walking. `reorder` also detaches a page between `removePage` and
    /// `insert`, so a render landing in that window draws a page whose
    /// `document` is nil — which PDFKit logs as unsupported.
    ///
    /// Mutations use `sync`, so a structural edit made while a render is in
    /// flight waits for that one page to finish. That stall is bounded and rare
    /// (preloading only runs just after a document opens) and is the price of
    /// not mutating a page tree PDFKit is walking.
    ///
    /// ⚠️ This serialization is defence against PDFKit's documented
    /// non-thread-safety; the suite does NOT reproduce a failure without it. A
    /// detached page still renders correct pixels today, so no output check can
    /// catch the window — only the log line marks it. What IS covered by
    /// `PDFStructureTests` is the deterministic half: rendering an
    /// already-detached page, which `renderPageSerialized` refuses. Don't drop
    /// the queue just because no test turns red.
    static let documentQueue = DispatchQueue(label: "com.simplshot.pdfDocument", qos: .userInitiated)

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
        documentQueue.sync {
            let idx = document.index(for: page)
            guard idx != NSNotFound, document.pageCount > 1 else { return false }
            document.removePage(at: idx)
            pruneDanglingOutlineEntries(in: document)
            return true
        }
    }

    /// Splices `pages` into `document` starting at `index`.
    static func insert(_ pages: [PDFPage], into document: PDFDocument, at index: Int) {
        documentQueue.sync {
            let start = min(max(index, 0), document.pageCount)
            for (offset, page) in pages.enumerated() {
                document.insert(page, at: min(start + offset, document.pageCount))
            }
        }
    }

    /// Drops outline entries whose destination page is no longer in `document`.
    ///
    /// PDFKit resolves a dangling destination to **page 0**, so leaving them
    /// behind silently turns a deleted chapter's entry into a link to the front
    /// of the document — in the editor's outline tab and in every saved copy,
    /// including the lossless `dataRepresentation()` save path. Pruning at
    /// deletion time (rather than at save time) keeps both save paths honest
    /// without either of them having to special-case it.
    private static func pruneDanglingOutlineEntries(in document: PDFDocument) {
        guard let root = document.outlineRoot else { return }
        for i in stride(from: root.numberOfChildren - 1, through: 0, by: -1) {
            guard let child = root.child(at: i) else { continue }
            _ = prune(child, in: document)
        }
    }

    /// Returns true when `node` survives the prune. Children are visited in
    /// reverse so removing one doesn't shift the indices still to be examined.
    private static func prune(_ node: PDFOutline, in document: PDFDocument) -> Bool {
        var survivor: PDFOutline?
        for i in stride(from: node.numberOfChildren - 1, through: 0, by: -1) {
            guard let child = node.child(at: i) else { continue }
            if prune(child, in: document) { survivor = child }
        }
        let destination = node.destination ?? (node.action as? PDFActionGoTo)?.destination
        let resolves = destination?.page.map { document.index(for: $0) != NSNotFound } ?? false
        if resolves { return true }
        guard let survivor else {
            node.removeFromParent()
            return false
        }
        // A section header whose own page is gone but whose children survive
        // adopts its first surviving child's destination rather than page 0.
        node.destination = survivor.destination
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
        documentQueue.sync { reorderLocked(document, toMatch: pages) }
    }

    /// `reorder`'s body, for callers already holding `documentQueue`.
    private static func reorderLocked(_ document: PDFDocument, toMatch pages: [PDFPage]) {
        guard pages.count == document.pageCount else { return }
        for target in 0..<pages.count {
            let page = pages[target]
            let current = document.index(for: page)
            guard current != NSNotFound, current != target else { continue }
            document.removePage(at: current)
            document.insert(page, at: target)
        }
    }

    // MARK: - Structural Undo

    /// A reversible snapshot of a document's structure: which pages it holds, in
    /// what order, and its outline.
    ///
    /// Holds the pages strongly, so a page deleted after the snapshot was taken
    /// is still alive to be put back. The outline is captured as a value tree
    /// because `removePage` prunes dangling entries destructively — without it,
    /// undoing a delete would restore the page but not its contents entry.
    struct PDFStructureSnapshot {
        let document: PDFDocument
        let pages: [PDFPage]
        fileprivate let outline: OutlineNode?
    }

    fileprivate struct OutlineNode {
        let label: String?
        let destination: PDFDestination?
        let children: [OutlineNode]
    }

    static func snapshotStructure(of document: PDFDocument) -> PDFStructureSnapshot {
        documentQueue.sync {
            PDFStructureSnapshot(
                document: document,
                pages: (0..<document.pageCount).compactMap { document.page(at: $0) },
                outline: document.outlineRoot.map(captureOutline)
            )
        }
    }

    /// Puts `document` back exactly as the snapshot found it — page membership,
    /// page order, and the outline.
    static func restore(_ snapshot: PDFStructureSnapshot) {
        documentQueue.sync {
            let document = snapshot.document
            let wanted = Set(snapshot.pages.map(ObjectIdentifier.init))
            for i in stride(from: document.pageCount - 1, through: 0, by: -1) {
                guard let page = document.page(at: i) else { continue }
                if !wanted.contains(ObjectIdentifier(page)) { document.removePage(at: i) }
            }
            for (index, page) in snapshot.pages.enumerated()
            where document.index(for: page) == NSNotFound {
                document.insert(page, at: min(index, document.pageCount))
            }
            reorderLocked(document, toMatch: snapshot.pages)
            document.outlineRoot = snapshot.outline.map(rebuildOutline)
        }
    }

    fileprivate static func captureOutline(_ node: PDFOutline) -> OutlineNode {
        OutlineNode(
            label: node.label,
            destination: node.destination ?? (node.action as? PDFActionGoTo)?.destination,
            children: (0..<node.numberOfChildren).compactMap { node.child(at: $0) }.map(captureOutline)
        )
    }

    fileprivate static func rebuildOutline(_ node: OutlineNode) -> PDFOutline {
        let outline = PDFOutline()
        outline.label = node.label
        if let destination = node.destination { outline.destination = destination }
        for child in node.children {
            outline.insertChild(rebuildOutline(child), at: outline.numberOfChildren)
        }
        return outline
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
