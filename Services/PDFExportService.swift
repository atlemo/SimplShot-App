import PDFKit
import CoreGraphics

enum PDFExportError: LocalizedError {
    case noPDFSource
    case cannotCreateContext
    case cannotRenderPage

    var errorDescription: String? {
        switch self {
        case .noPDFSource:         return "No PDF source found for export"
        case .cannotCreateContext:  return "Failed to create PDF graphics context"
        case .cannotRenderPage:    return "Failed to render PDF page"
        }
    }
}

enum PDFExportService {

    static func exportPDF(
        sessions: [ImageSession],
        backingScale: CGFloat,
        to url: URL
    ) throws {
        let sorted = sessions.sorted {
            ($0.pdfPageSource?.pageIndex ?? 0) < ($1.pdfPageSource?.pageIndex ?? 0)
        }

        guard let firstSource = sorted.first?.pdfPageSource,
              let firstPage = firstSource.document.page(at: firstSource.pageIndex)
        else { throw PDFExportError.noPDFSource }

        let firstBox = firstPage.bounds(for: .mediaBox)
        var mediaBox = CGRect(origin: .zero, size: firstBox.size)

        guard let pdfContext = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw PDFExportError.cannotCreateContext
        }

        let renderer = AnnotationRenderer()

        for session in sorted {
            guard let source = session.pdfPageSource,
                  let page = source.document.page(at: source.pageIndex)
            else { continue }

            let pageBox = page.bounds(for: .mediaBox)
            var pageMediaBox = CGRect(origin: .zero, size: pageBox.size)

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
                    contextSize: pageBox.size,
                    backingScale: backingScale,
                    watermark: session.watermarkSettings
                )
            }

            pdfContext.endPage()
        }

        pdfContext.closePDF()
    }
}
