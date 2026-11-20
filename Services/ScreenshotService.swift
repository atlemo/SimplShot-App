import AppKit
import CoreGraphics
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
#if !APPSTORE
import WebP
#endif

enum ScreenshotError: LocalizedError {
    case captureFailed
    case noWindowID
    case saveFailed
    case windowNotFound
    case permissionDenied
    case permissionNeedsRestart

    var errorDescription: String? {
        switch self {
        case .captureFailed:
            return String(localized: "Failed to capture window image. Make sure Screen Recording permission is granted, then restart SimplShot.")
        case .noWindowID:
            return String(localized: "Could not get window ID for screenshot")
        case .saveFailed:
            return String(localized: "Failed to save screenshot to disk")
        case .windowNotFound:
            return String(localized: "Could not find window for capture. It may have closed.")
        case .permissionDenied:
            return String(localized: "Screen Recording permission is not granted. Enable it in System Settings › Privacy & Security › Screen Recording, then restart SimplShot.")
        case .permissionNeedsRestart:
            return String(localized: "Screen Recording permission was recently changed. Please restart SimplShot for it to take effect.")
        }
    }
}

class ScreenshotService {

    func capture(
        windowID: CGWindowID,
        appName: String,
        width: Int,
        height: Int,
        format: ScreenshotFormat,
        saveURL: URL,
        windowIndex: Int? = nil,
        template: ScreenshotTemplate? = nil
    ) async throws -> URL {
        // Ensure save directory exists
        try FileManager.default.createDirectory(at: saveURL, withIntermediateDirectories: true)

        // Use ScreenCaptureKit for proper alpha-composited capture
        // (transparent corners, no opaque black corner artifacts).
        let (cgImage, backingScale) = try await captureWithScreenCaptureKit(windowID: windowID)

        // Apply template if enabled
        var finalImage = cgImage
        if let template, template.isEnabled {
            let renderer = TemplateRenderer()
            finalImage = try renderer.applyTemplate(template, to: cgImage, backingScale: CGFloat(backingScale))
        }

        let timestamp = Self.timestampString()
        let sanitizedName = appName.replacingOccurrences(of: "/", with: "-")
        let indexSuffix = windowIndex.map { "_\($0 + 1)" } ?? ""
        let filename = "\(sanitizedName)_\(width)x\(height)_\(timestamp)\(indexSuffix).\(format.fileExtension)"
        let filePath = saveURL.appendingPathComponent(filename)

        // Tag the file with the capture's true DPI: 72 × backingScale (so 144 on
        // a 2× Retina display, 216 on 3×) — exactly what macOS's own screenshot
        // tool writes. Pixel dimensions are unchanged; this lets the editor detect
        // the capture as Retina and open it at natural size instead of 2×/3×.
        let captureDPI = 72.0 * Double(backingScale)
        #if !APPSTORE
        // WebP encoding requires the swift-webp library; CGImageDestination
        // does not support WebP encoding on macOS.
        if format == .webp {
            let data = try Self.webPData(from: finalImage)
            try data.write(to: filePath)
            return filePath
        }
        #endif

        let utType: CFString
        var properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: captureDPI,
            kCGImagePropertyDPIHeight: captureDPI,
        ]

        switch format {
        case .png:
            utType = UTType.png.identifier as CFString
        case .jpeg:
            utType = UTType.jpeg.identifier as CFString
            properties[kCGImageDestinationLossyCompressionQuality] = 0.9
        case .heic:
            utType = UTType.heic.identifier as CFString
            properties[kCGImageDestinationLossyCompressionQuality] = 0.9
        #if !APPSTORE
        case .webp:
            // WebP is handled by the early return above; this is unreachable.
            utType = UTType.png.identifier as CFString
        #endif
        }

        guard let destination = CGImageDestinationCreateWithURL(
            filePath as CFURL, utType, 1, nil
        ) else {
            throw ScreenshotError.saveFailed
        }

        CGImageDestinationAddImage(destination, finalImage, properties as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw ScreenshotError.saveFailed
        }

        return filePath
    }

    // MARK: - ScreenCaptureKit capture

    private func captureWithScreenCaptureKit(windowID: CGWindowID) async throws -> (CGImage, Float) {
        // 1. Find the SCWindow matching our CGWindowID
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let scWindow = content.windows.first(where: { $0.windowID == windowID }) else {
            throw ScreenshotError.windowNotFound
        }

        // 2. Create a filter for this single window
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)

        // 3. Configure capture settings
        let config = SCStreamConfiguration()

        // Match the window's native pixel dimensions (Retina-aware)
        let scale = filter.pointPixelScale
        config.width = Int(filter.contentRect.width * CGFloat(scale))
        config.height = Int(filter.contentRect.height * CGFloat(scale))

        // No cursor in the screenshot
        config.showsCursor = false

        // Strip the window drop shadow (just the window content)
        config.ignoreShadowsSingleWindow = true

        // Keep transparent corners — backgroundColor defaults to clear,
        // shouldBeOpaque defaults to false. Native rounded-corner alpha is
        // neutralised in TemplateRenderer by filling the squircle with opaque
        // white before drawing the screenshot, so no artifacts leak through.

        // 4. Capture and return (image + backing scale)
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )
        return (image, scale)
    }

    #if !APPSTORE
    /// Re-encodes an image file at `sourceURL` as WebP and writes it to `destinationURL`.
    /// Used when `screencapture` writes PNG for area captures and we need WebP output.
    static func convertToWebP(sourceURL: URL, destinationURL: URL) throws {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ScreenshotError.saveFailed
        }
        let data = try webPData(from: cgImage)
        try data.write(to: destinationURL)
    }

    /// Encodes `image` as WebP.
    ///
    /// ⚠️ Never hand a `CGImage` straight to `WebPEncoder.encode(_:config:)`. It
    /// reads the image's raw bytes **assuming straight-alpha RGBA** and ignores
    /// the image's real layout. ScreenCaptureKit delivers BGRA (premultiplied,
    /// little-endian), so red and blue came out swapped. The encoder also embeds
    /// no ICC profile, so the pixels have to be sRGB to be read correctly.
    ///
    /// So the image is first redrawn into a known 8-bit sRGB RGBA bitmap, then
    /// un-premultiplied (libwebp expects straight alpha; translucent window
    /// corners would otherwise darken).
    static func webPData(from image: CGImage, quality: Float = 80) throws -> Data {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                      | CGBitmapInfo.byteOrder32Big.rawValue
              ),
              let base = context.data
        else {
            throw ScreenshotError.saveFailed
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let stride = context.bytesPerRow
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            let row = bytes + y * stride
            for x in 0..<width {
                let px = row + x * 4
                let a = Int(px[3])
                guard a != 0, a != 255 else { continue }
                px[0] = UInt8(min(255, (Int(px[0]) * 255 + a / 2) / a))
                px[1] = UInt8(min(255, (Int(px[1]) * 255 + a / 2) / a))
                px[2] = UInt8(min(255, (Int(px[2]) * 255 + a / 2) / a))
            }
        }

        return try WebPEncoder().encode(
            UnsafeBufferPointer(start: bytes, count: stride * height),
            format: .rgba,
            config: .preset(.photo, quality: quality),
            originWidth: width,
            originHeight: height,
            stride: stride
        )
    }
    #endif

    private static func timestampString() -> String {
        let formatter = DateFormatter()
        // Fixed locale so filenames are stable regardless of the user's
        // calendar/numbering system.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: Date())
    }
}
