import AppKit
import PDFKit
import CoreGraphics

enum PDFExportError: LocalizedError {
    case noPDFSource
    case cannotCreateContext
    case cannotRenderPage

    var errorDescription: String? {
        switch self {
        case .noPDFSource:         return String(localized: "No PDF source found for export")
        case .cannotCreateContext:  return String(localized: "Failed to create PDF graphics context")
        case .cannotRenderPage:    return String(localized: "Failed to render PDF page")
        }
    }
}

enum PDFExportService {

    /// Writes `sessions` (one PDF group, in strip order) as a single PDF.
    ///
    /// Two paths, because burning annotations into page content necessarily
    /// re-encodes the document and drops everything that isn't drawn:
    ///
    /// - **Nothing to burn in** (pages only added / deleted / reordered):
    ///   `PDFDocument.dataRepresentation()`. Completely lossless — the outline,
    ///   links, form fields, embedded files and metadata all survive untouched.
    /// - **Annotations or a watermark**: flatten into a new document, then
    ///   transplant the metadata, outline and links back onto it.
    ///
    /// Annotations are deliberately NOT written as `PDFAnnotation`s. A
    /// `PDFAnnotation` subclass's `draw(with:in:)` is a runtime hook that
    /// `write(to:)` does not serialize (the saved file gets a Stamp with no
    /// appearance stream — blank in every reader), and PDFKit exposes no public
    /// way to attach an appearance stream: every `setValue(_:forAnnotationKey:
    /// .appearanceDictionary)` form is rejected. The standard annotation
    /// subtypes also can't express curved/sketch arrows, pixelate, spotlight,
    /// numbered steps, angle or measurement. Burning in is what keeps a saved
    /// PDF looking the same in every reader.
    static func exportPDF(
        sessions: [ImageSession],
        backingScale: CGFloat,
        to url: URL
    ) throws {
        guard let document = sessions.first?.pdfPageSource?.document else {
            throw PDFExportError.noPDFSource
        }
        let data = try losslessData(sessions: sessions, document: document)
            ?? flattenedData(sessions: sessions, backingScale: backingScale, source: document)
        try write(data, to: url)
    }

    /// Writes `sessions` — a window of plain images, in strip order — as one
    /// PDF, a page per image.
    ///
    /// This is "Save As → PDF" from a window that isn't a PDF document. There is
    /// no source document to preserve here, so it is always the flattening path:
    /// each image's composited bitmap becomes a page sized at that image's own
    /// DPI. A PDF page that happens to be open in the same window (a document
    /// dropped onto a window of screenshots) still contributes its vector
    /// content, so nothing is rasterized that doesn't have to be.
    static func exportImagesAsPDF(
        sessions: [ImageSession],
        backingScale: CGFloat,
        to url: URL
    ) throws {
        let data = try flattenedData(sessions: sessions, backingScale: backingScale, source: nil)
        try write(data, to: url)
    }

    // MARK: - Lossless path

    /// The document's own bytes, when there is nothing to composite over it and
    /// `sessions` really are its pages in the same order. Returns nil when the
    /// flattening path is required.
    private static func losslessData(sessions: [ImageSession], document: PDFDocument) -> Data? {
        guard !sessions.contains(where: { hasOverlay($0) }) else { return nil }
        // Guard the assumption rather than trusting it: writing the document
        // when it doesn't match the strip would save pages the user removed.
        guard sessions.count == document.pageCount else { return nil }
        for (index, session) in sessions.enumerated() {
            guard let page = session.pdfPageSource?.page,
                  document.index(for: page) == index else { return nil }
        }
        return document.dataRepresentation()
    }

    private static func hasOverlay(_ session: ImageSession) -> Bool {
        !session.annotations.isEmpty || session.watermarkSettings.isEnabled
    }

    // MARK: - Flattening path

    /// - Parameter source: the document the pages came from, whose structure is
    ///   transplanted onto the result. Nil when the sessions are plain images
    ///   with no document behind them (`exportImagesAsPDF`) — there is then
    ///   nothing to transplant.
    private static func flattenedData(
        sessions: [ImageSession],
        backingScale: CGFloat,
        source: PDFDocument?
    ) throws -> Data {
        // Rendered in memory rather than straight to the destination: the
        // destination is usually the very file `source` is still reading its
        // pages from.
        let buffer = NSMutableData()
        // Only seeds the context — every page sets its own (rotation-aware)
        // media box in `beginPage` below, so this value never reaches the file.
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: buffer as CFMutableData),
              let pdfContext = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw PDFExportError.cannotCreateContext
        }

        let renderer = AnnotationRenderer()
        // Tracked as we go so a skipped session can't desync the source→output
        // page mapping the structure transplant relies on. An image session
        // holds a nil: it contributes a page like any other, but has no source
        // page for a destination to be remapped against.
        var writtenPages: [PDFPage?] = []

        // Drawing pages is serialized with every other access to this document's
        // page tree (background thumbnail rendering, structural edits) — see
        // PDFService.documentQueue. Saving is modal, so blocking here is free.
        try PDFService.documentQueue.sync {
        for session in sessions {
            guard let page = session.pdfPageSource?.page else {
                if try drawImagePage(session, renderer: renderer, into: pdfContext) {
                    writtenPages.append(nil)
                }
                continue
            }

            // Rotation-aware page size: draw(with:) bakes the page's `/Rotate`
            // into the content, so the new page's media box must match the
            // rotated (visible) dimensions, and annotations — stored in that
            // same visible pixel space — map against it.
            let pageSize = page.rotatedMediaBoxSize
            var pageMediaBox = CGRect(origin: .zero, size: pageSize)

            pdfContext.beginPage(mediaBox: &pageMediaBox)

            // Always draw the original PDF page as vector content first.
            page.draw(with: .mediaBox, to: pdfContext)

            // Draw annotations + watermark directly into the PDF context as vectors.
            // Pixelate is unavailable for PDF sessions (disabled in the UI), so
            // every annotation type we encounter here is vector-renderable.
            if hasOverlay(session) {
                // Set even though 1 is the default: a preceding image page
                // leaves its own density behind on the shared renderer.
                renderer.styleScale = 1
                renderer.drawAnnotationsVector(
                    annotations: session.annotations,
                    into: pdfContext,
                    contextSize: pageSize,
                    backingScale: backingScale,
                    watermark: session.watermarkSettings
                )
            }

            pdfContext.endPage()
            writtenPages.append(page)
        }
        }

        guard !writtenPages.isEmpty else { throw PDFExportError.noPDFSource }

        pdfContext.closePDF()

        guard let rendered = PDFDocument(data: buffer as Data) else {
            throw PDFExportError.cannotRenderPage
        }

        // ⚠️ The flattened pages are re-wrapped in a FRESH document before the
        // transplant, and that is load-bearing: as of macOS 27, PDFKit does not
        // serialize an `outlineRoot` assigned to a document that came from
        // `PDFDocument(data:)`. Setting it succeeds, `numberOfChildren` reads
        // back correctly right up to the write, and the outline is then silently
        // absent from the file — so every annotated save lost its table of
        // contents while links and metadata (page objects and the attributes
        // dict, which do serialize) came through fine, which is what made it
        // look like a narrow bug. `write(to:)` in place of
        // `dataRepresentation()` does not help; the document's origin is what
        // matters. A document built with `PDFDocument()` still serializes an
        // assigned outline, so copying the pages across is the whole fix
        // (measured: identical page content, ~1 KB larger).
        //
        // A failed copy throws rather than skipping the page: `writtenPages` is
        // positional, so dropping one here would shift every later page and
        // hand the transplant the wrong destinations — the same desync
        // `writtenPages` exists to prevent above.
        let output = PDFDocument()
        for index in 0..<rendered.pageCount {
            guard let page = rendered.page(at: index)?.copy() as? PDFPage else {
                throw PDFExportError.cannotRenderPage
            }
            output.insert(page, at: output.pageCount)
        }

        if let source {
            transplantStructure(from: source, to: output, sourcePageOrder: writtenPages)
        }
        guard let data = output.dataRepresentation() else {
            throw PDFExportError.cannotRenderPage
        }
        return data
    }

    /// Draws one plain-image session as a page — its composited bitmap with
    /// annotations and watermark already burned in. Returns false when the
    /// session has no decodable pixels (nothing to make a page out of).
    ///
    /// Deliberately NOT `drawAnnotationsVector` like the PDF branch above:
    /// that one skips `.pixelate`, which is unavailable on a PDF page but an
    /// ordinary tool on a screenshot. Sharper annotation text is not worth
    /// silently dropping a redaction from an exported file.
    private static func drawImagePage(
        _ session: ImageSession,
        renderer: AnnotationRenderer,
        into context: CGContext
    ) throws -> Bool {
        // The display bitmap is what the user sees — crop, template and photo
        // adjustments are already in it. The file is the last resort: every
        // session is decoded in the background when the window opens
        // (`preloadThumbnails`), but a save issued before that finished would
        // otherwise drop the page entirely.
        let base = session.currentDisplayCGImage
            ?? session.image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            ?? NSImage(contentsOf: session.imageURL)?
                .cgImage(forProposedRect: nil, context: nil, hints: nil)
        guard let base else { return false }

        renderer.styleScale = session.dpiScaleFactor
        // Crop is applied destructively upstream, so the display bitmap is
        // already the cropped region — no crop rect here (matches EditorView's
        // raster export).
        let composited = try renderer.render(
            image: base,
            annotations: session.annotations,
            cropRect: nil,
            watermark: session.watermarkSettings
        )

        // The page is sized in POINTS, not pixels: a 2× (144-DPI) screenshot
        // gets a page half its pixel count on a side, with every pixel still
        // embedded. Same rule `PDFService.page(from:)` follows for an image
        // dropped into a document, so a screenshot lands at the same size
        // whichever way it becomes a page.
        let density = max(session.dpiScaleFactor, 1)
        var mediaBox = CGRect(
            origin: .zero,
            size: CGSize(width: CGFloat(composited.width) / density,
                         height: CGFloat(composited.height) / density)
        )
        guard mediaBox.width >= 1, mediaBox.height >= 1 else { return false }

        context.beginPage(mediaBox: &mediaBox)
        context.draw(composited, in: mediaBox)
        context.endPage()
        return true
    }

    // MARK: - Structure transplant

    /// Copies the document-level structure that drawing page content cannot
    /// carry — metadata, the outline, and link annotations — from `source` onto
    /// the freshly flattened `output`.
    ///
    /// `sourcePageOrder[i]` is the source page that produced output page `i`,
    /// which is how destinations are remapped: pages may have been reordered,
    /// removed, or added since the document was opened. An outline entry whose
    /// page is gone keeps its label but loses its destination.
    ///
    /// Only `/Link` annotations are copied. PDFKit serializes those correctly
    /// (they carry behaviour, not an appearance stream), and every other
    /// annotation on the source page has already been rasterized into the page
    /// content by `page.draw(with:to:)` — copying those too would double them.
    private static func transplantStructure(
        from source: PDFDocument,
        to output: PDFDocument,
        sourcePageOrder: [PDFPage?]
    ) {
        if let attributes = source.documentAttributes {
            output.documentAttributes = attributes
        }

        var outputIndex: [ObjectIdentifier: Int] = [:]
        for (index, page) in sourcePageOrder.enumerated() {
            guard let page else { continue }
            outputIndex[ObjectIdentifier(page)] = index
        }

        func remap(_ destination: PDFDestination?) -> PDFDestination? {
            guard let destination,
                  let page = destination.page,
                  let index = outputIndex[ObjectIdentifier(page)],
                  let newPage = output.page(at: index) else { return nil }
            return PDFDestination(page: newPage, at: destination.point)
        }

        for (index, sourcePage) in sourcePageOrder.enumerated() {
            guard let sourcePage, let outputPage = output.page(at: index) else { continue }
            for annotation in sourcePage.annotations where annotation.type == "Link" {
                let link = PDFAnnotation(bounds: annotation.bounds, forType: .link, withProperties: nil)
                // Assign exactly one of the two, and only when it resolves:
                // writing `destination = nil` installs an empty GoTo action that
                // clobbers an external `url`, and the link then serializes as
                // inert (caught by PDFExportTests).
                if let url = annotation.url {
                    link.url = url
                } else if let destination = remap(
                    annotation.destination ?? (annotation.action as? PDFActionGoTo)?.destination
                ) {
                    link.destination = destination
                } else {
                    continue
                }
                outputPage.addAnnotation(link)
            }
        }

        if let root = source.outlineRoot {
            let newRoot = PDFOutline()
            for i in 0..<root.numberOfChildren {
                guard let child = root.child(at: i),
                      let rebuilt = rebuiltOutline(child, remap: remap) else { continue }
                newRoot.insertChild(rebuilt, at: newRoot.numberOfChildren)
            }
            // Leave the outline unset rather than empty when nothing resolved.
            if newRoot.numberOfChildren > 0 { output.outlineRoot = newRoot }
        }
    }

    /// Rebuilds one outline entry against the output document, or nil when
    /// neither it nor anything beneath it survives.
    ///
    /// An entry MUST NOT be kept without a destination: PDFKit serializes a nil
    /// destination as page 0, so a deleted page's entry would silently start
    /// navigating to the front of the document (caught by PDFExportTests). A
    /// section header whose own page is gone but whose children survive inherits
    /// its first child's destination instead.
    private static func rebuiltOutline(
        _ node: PDFOutline,
        remap: (PDFDestination?) -> PDFDestination?
    ) -> PDFOutline? {
        let children = (0..<node.numberOfChildren)
            .compactMap { node.child(at: $0) }
            .compactMap { rebuiltOutline($0, remap: remap) }
        let own = remap(node.destination ?? (node.action as? PDFActionGoTo)?.destination)
        guard let destination = own ?? children.first?.destination else { return nil }

        let copy = PDFOutline()
        copy.label = node.label
        copy.destination = destination
        for child in children { copy.insertChild(child, at: copy.numberOfChildren) }
        return copy
    }

    // MARK: - Writing

    /// Atomic where possible: the destination is typically the file the document
    /// was read from, so a partial write would destroy the original. Falls back
    /// to a direct write if the sandbox refuses the sibling temp file an atomic
    /// write needs.
    private static func write(_ data: Data, to url: URL) throws {
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            try data.write(to: url)
        }
    }
}
