import AppKit
import Combine
import ImageIO

struct ImageMetadata: Equatable {
    let fileName: String
    let timestamp: String?
    let cameraBrand: String?
    let lens: String?
    let shutter: String?
    let fStop: String?
    let iso: String?
    let fileSize: String?

    var rows: [(label: String, value: String)] {
        [
            ("File", fileName),
            Self.optionalRow("Date", timestamp),
            Self.optionalRow("Camera", cameraBrand),
            Self.optionalRow("Lens", lens),
            Self.optionalRow("Shutter", shutter),
            Self.optionalRow("F-stop", fStop),
            Self.optionalRow("ISO", iso),
            Self.optionalRow("Size", fileSize)
        ].compactMap { $0 }
    }

    static func load(from url: URL) -> ImageMetadata {
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        let properties = source.flatMap {
            CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any]
        } ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]

        let resourceValues = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey, .fileSizeKey])
        let timestamp = stringValue(exif[kCGImagePropertyExifDateTimeOriginal])
            ?? stringValue(tiff[kCGImagePropertyTIFFDateTime])
            ?? formatDate(resourceValues?.creationDate ?? resourceValues?.contentModificationDate)

        return ImageMetadata(
            fileName: url.lastPathComponent,
            timestamp: timestamp,
            cameraBrand: stringValue(tiff[kCGImagePropertyTIFFMake]),
            lens: stringValue(exif[kCGImagePropertyExifLensModel]),
            shutter: shutterString(from: exif[kCGImagePropertyExifExposureTime]),
            fStop: fStopString(from: exif[kCGImagePropertyExifFNumber]),
            iso: isoString(from: exif[kCGImagePropertyExifISOSpeedRatings]),
            fileSize: fileSizeString(from: resourceValues?.fileSize)
        )
    }

    private static func optionalRow(_ label: String, _ value: String?) -> (label: String, value: String)? {
        guard let value, !value.isEmpty else { return nil }
        return (label, value)
    }

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let value as String:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let value as NSNumber:
            return value.stringValue
        default:
            return nil
        }
    }

    private static func shutterString(from value: Any?) -> String? {
        guard let seconds = numberValue(value), seconds > 0 else { return nil }
        if seconds < 1 {
            let denominator = Int((1 / seconds).rounded())
            return "1/\(denominator)s"
        }
        return String(format: "%.1fs", seconds)
    }

    private static func fStopString(from value: Any?) -> String? {
        guard let fNumber = numberValue(value), fNumber > 0 else { return nil }
        return String(format: "f/%.1f", fNumber)
    }

    private static func isoString(from value: Any?) -> String? {
        if let values = value as? [Any], let first = values.first {
            return isoString(from: first)
        }
        guard let iso = numberValue(value), iso > 0 else { return nil }
        return String(Int(iso.rounded()))
    }

    private static func numberValue(_ value: Any?) -> Double? {
        switch value {
        case let value as NSNumber:
            return value.doubleValue
        case let value as Double:
            return value
        case let value as Float:
            return Double(value)
        case let value as Int:
            return Double(value)
        default:
            return nil
        }
    }

    private static func formatDate(_ date: Date?) -> String? {
        guard let date else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private static func fileSizeString(from bytes: Int?) -> String? {
        guard let bytes else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// Encapsulates all per-image editing state so multiple images can coexist
/// in a single editor window, each retaining its own annotations, crop,
/// undo stack, and template settings.
class ImageSession: Identifiable, ObservableObject {
    let id = UUID()
    let imageURL: URL

    // PDF source — non-nil when this session represents a PDF page
    var pdfPageSource: PDFPageSource?
    var pdfGroupID: UUID?
    var isPDF: Bool { pdfPageSource != nil }

    // Image state
    var image: NSImage?
    var rawImage: NSImage?
    var currentDisplayCGImage: CGImage?
    var imagePixelSize: CGSize = .zero
    var screenshotCropRect: CGRect = .zero
    var metadata: ImageMetadata?

    // Annotations
    var annotations: [Annotation] = []
    var selectedAnnotationID: UUID?

    // Crop
    var isCropping: Bool = false
    var cropRect: CGRect = .zero
    var preCropScreenshotCropRect: CGRect = .zero
    var preCropSnapshot: EditorSnapshot?

    // Zoom
    var zoomLevel: CGFloat = 1.0
    var fitScale: CGFloat = 0.5

    // Template
    var selectedWallpaper: WallpaperSource?
    var editorAspectRatioID: UUID?
    var editorPadding: Int = 80
    var editorCornerRadius: Int = 24
    var shadowIntensity: Double = 1.0
    var screenshotAlignment: CanvasAlignment = .middleCenter
    var watermarkSettings: WatermarkSettings = WatermarkSettings()

    // Photo adjustments (Edit mode — non-destructive CI filter chain)
    var photoAdjustments: PhotoAdjustments = .default

    // Undo
    var undoStack: [EditorSnapshot] = []

    // Per-session renderer so flattenNativeCorners cache is isolated
    var templateRenderer = TemplateRenderer()

    /// Published so the thumbnail strip refreshes when a thumbnail is generated
    /// off the main thread.
    @Published var thumbnail: NSImage?

    init(imageURL: URL) {
        self.imageURL = imageURL
    }

    init(pdfPageSource: PDFPageSource, pdfGroupID: UUID) {
        self.imageURL = pdfPageSource.sourceURL
        self.pdfPageSource = pdfPageSource
        self.pdfGroupID = pdfGroupID
    }

    /// Generate a downscaled thumbnail. Safe to call off the main thread —
    /// uses CGContext rather than NSImage.lockFocus (which requires AppKit/main).
    /// Pass `from:` to avoid re-loading the NSImage; otherwise falls back to `image`.
    func generateThumbnail(from source: NSImage? = nil) {
        let src = source ?? image
        guard let cgSource = src?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let pixelW = CGFloat(cgSource.width)
        let pixelH = CGFloat(cgSource.height)
        guard pixelW > 0, pixelH > 0 else { return }

        let maxDim: CGFloat = 148
        let scale = min(maxDim / pixelW, maxDim / pixelH, 1.0)
        // Render at 2× target points for crisp display on Retina.
        let renderW = max(Int((pixelW * scale * 2).rounded()), 1)
        let renderH = max(Int((pixelH * scale * 2).rounded()), 1)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: renderW,
            height: renderH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        ctx.interpolationQuality = .high
        ctx.draw(cgSource, in: CGRect(x: 0, y: 0, width: renderW, height: renderH))
        guard let cgThumb = ctx.makeImage() else { return }

        let pointSize = NSSize(width: pixelW * scale, height: pixelH * scale)
        let thumb = NSImage(cgImage: cgThumb, size: pointSize)
        if Thread.isMainThread {
            thumbnail = thumb
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.thumbnail = thumb
            }
        }
    }
}
