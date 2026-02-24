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

    var errorDescription: String? {
        switch self {
        case .captureFailed:
            return "Failed to capture window image. Make sure Screen Recording permission is granted, then restart SimplShot."
        case .noWindowID:
            return "Could not get window ID for screenshot"
        case .saveFailed:
            return "Failed to save screenshot to disk"
        case .windowNotFound:
            return "Could not find window for capture. It may have closed."
        }
    }
}

class ScreenshotService {
    /// Request screen recording permission.
    /// `CGRequestScreenCaptureAccess()` shows the system prompt but doesn't
    /// always register the app in System Settings. Performing a tiny test
    /// capture forces macOS to add SimplShot to the Screen Recording list
    /// so the user can find and enable it.
    static func ensurePermission() {
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
        // Trigger a ScreenCaptureKit query so macOS registers this app in
        // the Screen Recording privacy list even if permission is denied.
        _Concurrency.Task {
            try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }
    }

    /// Confirms Screen Recording access using both TCC preflight and a
    /// ScreenCaptureKit query. This avoids false negatives from preflight alone.
    static func confirmScreenRecordingPermission() async -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            return true
        } catch {
            return false
        }
    }

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

        // Write using CGImageDestination — this writes the raw pixel data
        // at 72 DPI (matching macOS native screenshot behaviour) so the
        // reported image dimensions equal the actual pixel count.
        #if !APPSTORE
        // WebP encoding requires the swift-webp library; CGImageDestination
        // does not support WebP encoding on macOS.
        if format == .webp {
            let data = try WebPEncoder().encode(finalImage, config: .preset(.photo, quality: 80))
            try data.write(to: filePath)
            return filePath
        }
        #endif

        let utType: CFString
        var properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: 72.0,
            kCGImagePropertyDPIHeight: 72.0,
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
        // shouldBeOpaque defaults to false. This gives us proper alpha
        // in the rounded corner pixels (unlike CGWindowListCreateImage
        // which produced opaque black corners).

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
        let data = try WebPEncoder().encode(cgImage, config: .preset(.photo, quality: 80))
        try data.write(to: destinationURL)
    }
    #endif

    private static func timestampString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: Date())
    }
}
