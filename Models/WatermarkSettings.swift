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

    private static func data(atPath path: String) -> Data? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(path)|\(mtime)"

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
