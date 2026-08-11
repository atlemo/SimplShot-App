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

    static func exportPDF(
        sessions: [ImageSession],
        backingScale: CGFloat,
        to url: URL
    ) throws {
        guard let firstSource = sessions.first?.pdfPageSource,
              let firstPage = firstSource.document.page(at: firstSource.pageIndex)
        else { throw PDFExportError.noPDFSource }

        // Use the rotation-aware size so 90°/270° pages aren't clipped (see
        // PDFPage.rotatedMediaBoxSize). The first page only seeds the context's
        // initial media box; each page sets its own below.
        var mediaBox = CGRect(origin: .zero, size: firstPage.rotatedMediaBoxSize)

        guard let pdfContext = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw PDFExportError.cannotCreateContext
        }

        let renderer = AnnotationRenderer()

        for session in sessions {
            guard let source = session.pdfPageSource,
                  let page = source.document.page(at: source.pageIndex)
            else { continue }

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
            if !session.annotations.isEmpty || session.watermarkSettings.isEnabled {
                renderer.drawAnnotationsVector(
                    annotations: session.annotations,
                    into: pdfContext,
                    contextSize: pageSize,
                    backingScale: backingScale,
                    watermark: session.watermarkSettings
                )
            }

            pdfContext.endPage()
        }

        pdfContext.closePDF()
    }
}
