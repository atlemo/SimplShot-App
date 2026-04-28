import Foundation

enum WatermarkPosition: String, CaseIterable, Codable, Identifiable {
    var id: String { rawValue }
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    var label: String {
        switch self {
        case .topLeft:     return "Top Left"
        case .topRight:    return "Top Right"
        case .bottomLeft:  return "Bottom Left"
        case .bottomRight: return "Bottom Right"
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
