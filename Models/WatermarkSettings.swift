import Foundation
import AppKit

/// Caches watermark image *bytes* loaded from disk so the file isn't re-read on
/// every access. The disk read is the expensive part — it can block for seconds
/// when the path lives on a removed/disconnected volume — and the live preview
/// used to read it inside the SwiftUI body, which re-evaluates constantly.
///
/// `image(atPath:)` decodes a **fresh** `NSImage` from the cached bytes on every
/// call, so the result is never shared across threads (safe to draw from a
/// background render queue such as capture-time template compositing) and vector
/// formats (SVG) still rasterize at draw time. Bytes are keyed by path +
/// modification date, so replacing the file at the same path refreshes the entry;
/// misses are cached too, so a deleted/unreadable path isn't re-read (or
/// re-blocked) on every call.
enum WatermarkImageCache {
    private static var cache: [String: Data?] = [:]
    private static let lock = NSLock()

    static func image(atPath path: String) -> NSImage? {
        guard let data = data(atPath: path) else { return nil }
        let image = NSImage(data: data)
        return (image?.isValid == true) ? image : nil
    }

    /// Native aspect ratio (width / height) of the watermark image, or nil when
    /// it can't be loaded. Falls back to 1 for a degenerate (zero-height) image,
    /// matching the renderers' previous inline computation.
    static func aspect(atPath path: String) -> CGFloat? {
        guard let image = image(atPath: path) else { return nil }
        let size = image.size
        return size.height > 0 ? size.width / size.height : 1.0
    }

    // Rasterized watermark cache. Unlike `image(atPath:)` — which hands out a
    // fresh NSImage each call precisely so nothing is shared across threads —
    // a CGImage is immutable and safe to share, so the expensive rasterization
    // (a full CGContext draw, and for SVG a vector render) is done once per
    // path+size instead of on every template render. A padding-slider drag
    // re-composites the canvas every frame and used to redo this each time.
    private static var rasterCache: [String: CGImage] = [:]
    private static let rasterLock = NSLock()

    /// Renders the watermark at `path` into a CGImage of exactly `size` pixels,
    /// reusing the previous result when the path, file mtime, and size all match.
    /// Only the most recent size per path is retained (a width-slider drag
    /// replaces rather than accumulates).
    static func rasterized(atPath path: String, size: CGSize) -> CGImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        let key = "\(cacheKey(forPath: path))|\(Int(size.width.rounded()))x\(Int(size.height.rounded()))"

        rasterLock.lock()
        if let cached = rasterCache[key] {
            rasterLock.unlock()
            return cached
        }
        rasterLock.unlock()

        // Rasterize outside the lock — a concurrent miss may duplicate the work,
        // which is harmless, but holding a lock across an NSImage draw is not.
        guard let image = image(atPath: path),
              let rendered = rasterize(image, size: size) else { return nil }

        rasterLock.lock()
        // Drop any other size/mtime for this path so the cache stays bounded.
        let stalePrefix = "\(path)|"
        for staleKey in rasterCache.keys where staleKey.hasPrefix(stalePrefix) && staleKey != key {
            rasterCache.removeValue(forKey: staleKey)
        }
        rasterCache[key] = rendered
        rasterLock.unlock()
        return rendered
    }

    /// Renders an NSImage (SVG, PNG, JPG) into a CGImage at exactly `size` pixels.
    /// Going through NSGraphicsContext ensures vector sources rasterize at the
    /// target resolution rather than their intrinsic one.
    private static func rasterize(_ nsImage: NSImage, size: CGSize) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        nsImage.draw(in: NSRect(origin: .zero, size: size),
                     from: .zero,
                     operation: .copy,
                     fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    /// Path + modification date, so replacing the file invalidates its entries.
    private static func cacheKey(forPath path: String) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(path)|\(mtime)"
    }

    private static func data(atPath path: String) -> Data? {
        let key = cacheKey(forPath: path)

        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let loaded = try? Data(contentsOf: URL(fileURLWithPath: path))

        lock.lock()
        // Evict entries for older mtimes of the same path — without this,
        // replacing the watermark file accumulates stale image bytes forever.
        let stalePrefix = "\(path)|"
        for staleKey in cache.keys where staleKey.hasPrefix(stalePrefix) && staleKey != key {
            cache.removeValue(forKey: staleKey)
        }
        cache[key] = loaded
        lock.unlock()
        return loaded
    }
}

enum WatermarkPosition: String, CaseIterable, Codable, Identifiable {
    var id: String { rawValue }
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    var label: String {
        switch self {
        case .topLeft:     return String(localized: "Top Left")
        case .topRight:    return String(localized: "Top Right")
        case .bottomLeft:  return String(localized: "Bottom Left")
        case .bottomRight: return String(localized: "Bottom Right")
        }
    }

    var systemImage: String {
        switch self {
        case .topLeft:     return "arrow.up.left"
        case .topRight:    return "arrow.up.right"
        case .bottomLeft:  return "arrow.down.left"
        case .bottomRight: return "arrow.down.right"
        }
    }
}

struct WatermarkSettings: Codable, Equatable {
    var isEnabled: Bool = false
    /// Absolute path to the watermark image file (SVG, PNG, or JPG).
    var imagePath: String? = nil
    var position: WatermarkPosition = .bottomRight
    /// Opacity from 0.0 (transparent) to 1.0 (opaque).
    var opacity: Double = 0.5
    /// Target watermark width in the exported image (pixels). Range: 15–300.
    /// Height is derived from the watermark's aspect ratio.
    var widthPx: Double = 150
    /// Horizontal distance from the left/right edge in exported 1× pixels. Range: 0–100.
    var edgeOffset: Double = 20
    /// Vertical distance from the top/bottom edge in exported 1× pixels. Range: 0–100.
    var bottomOffset: Double = 20
}
