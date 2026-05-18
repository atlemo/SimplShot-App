import AppKit
import Combine

/// Encapsulates all per-image editing state so multiple images can coexist
/// in a single editor window, each retaining its own annotations, crop,
/// undo stack, and template settings.
class ImageSession: Identifiable, ObservableObject {
    let id = UUID()
    let imageURL: URL

    // Image state
    var image: NSImage?
    var rawImage: NSImage?
    var currentDisplayCGImage: CGImage?
    var imagePixelSize: CGSize = .zero
    var screenshotCropRect: CGRect = .zero

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
