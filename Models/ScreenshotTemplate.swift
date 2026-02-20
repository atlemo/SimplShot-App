import Foundation
import CoreGraphics

struct CodableColor: Codable, Equatable {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let alpha: CGFloat

    init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(cgColor: CGColor) {
        let c = cgColor.converted(
            to: CGColorSpaceCreateDeviceRGB(),
            intent: .defaultIntent,
            options: nil
        ) ?? cgColor
        let comp = c.components ?? [0, 0, 0, 1]
        self.red   = comp.count > 0 ? comp[0] : 0
        self.green = comp.count > 1 ? comp[1] : 0
        self.blue  = comp.count > 2 ? comp[2] : 0
        self.alpha = comp.count > 3 ? comp[3] : 1
    }

    var cgColor: CGColor {
        CGColor(red: red, green: green, blue: blue, alpha: alpha)
    }
}

struct GradientDefinition: Codable {
    let colors: [CodableColor]
    let angle: Double
}

enum BuiltInGradient: String, Codable, CaseIterable, Identifiable {
    case oceanBlue
    case sunset
    case aurora
    case lavender
    case midnight
    case forest
    case peach
    case slate
    case berry
    case sand

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .oceanBlue: return "Ocean Blue"
        case .sunset:    return "Sunset"
        case .aurora:    return "Aurora"
        case .lavender:  return "Lavender"
        case .midnight:  return "Midnight"
        case .forest:    return "Forest"
        case .peach:     return "Peach"
        case .slate:     return "Slate"
        case .berry:     return "Berry"
        case .sand:      return "Sand"
        }
    }

    var gradientDefinition: GradientDefinition {
        switch self {
        case .oceanBlue:
            return GradientDefinition(colors: [
                CodableColor(red: 0.00, green: 0.47, blue: 0.84),
                CodableColor(red: 0.00, green: 0.78, blue: 0.85),
            ], angle: 45)
        case .sunset:
            return GradientDefinition(colors: [
                CodableColor(red: 1.00, green: 0.37, blue: 0.33),
                CodableColor(red: 1.00, green: 0.65, blue: 0.25),
            ], angle: 235)
        case .aurora:
            return GradientDefinition(colors: [
                CodableColor(red: 0.29, green: 0.84, blue: 0.63),
                CodableColor(red: 0.15, green: 0.45, blue: 0.82),
            ], angle: 260)
        case .lavender:
            return GradientDefinition(colors: [
                CodableColor(red: 0.69, green: 0.49, blue: 0.96),
                CodableColor(red: 0.94, green: 0.60, blue: 0.84),
            ], angle: 180)
        case .midnight:
            return GradientDefinition(colors: [
                CodableColor(red: 0.07, green: 0.07, blue: 0.20),
                CodableColor(red: 0.20, green: 0.11, blue: 0.38),
            ], angle: 270)
        case .forest:
            return GradientDefinition(colors: [
                CodableColor(red: 0.07, green: 0.30, blue: 0.20),
                CodableColor(red: 0.18, green: 0.55, blue: 0.34),
            ], angle: 180)
        case .peach:
            return GradientDefinition(colors: [
                CodableColor(red: 1.00, green: 0.70, blue: 0.55),
                CodableColor(red: 1.00, green: 0.85, blue: 0.70),
            ], angle: 235)
        case .slate:
            return GradientDefinition(colors: [
                CodableColor(red: 0.35, green: 0.40, blue: 0.50),
                CodableColor(red: 0.55, green: 0.60, blue: 0.68),
            ], angle: 180)
        case .berry:
            return GradientDefinition(colors: [
                CodableColor(red: 0.55, green: 0.10, blue: 0.40),
                CodableColor(red: 0.80, green: 0.30, blue: 0.55),
            ], angle: 235)
        case .sand:
            return GradientDefinition(colors: [
                CodableColor(red: 0.82, green: 0.72, blue: 0.55),
                CodableColor(red: 0.93, green: 0.87, blue: 0.75),
            ], angle: 290)
        }
    }
}

enum WallpaperSource: Codable, Equatable {
    case builtInGradient(BuiltInGradient)
    case customImage(path: String)
}

struct ScreenshotTemplate: Codable {
    var isEnabled: Bool
    var wallpaperSource: WallpaperSource
    var padding: Int
    var cornerRadius: Int

    static let `default` = ScreenshotTemplate(
        isEnabled: false,
        wallpaperSource: .builtInGradient(.oceanBlue),
        padding: 80,
        cornerRadius: 24
    )

    /// Backwards-compatible decoding: older saved templates won't have `cornerRadius`.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        wallpaperSource = try container.decode(WallpaperSource.self, forKey: .wallpaperSource)
        padding = try container.decode(Int.self, forKey: .padding)
        cornerRadius = try container.decodeIfPresent(Int.self, forKey: .cornerRadius) ?? 24
    }

    init(isEnabled: Bool, wallpaperSource: WallpaperSource, padding: Int, cornerRadius: Int = 0) {
        self.isEnabled = isEnabled
        self.wallpaperSource = wallpaperSource
        self.padding = padding
        self.cornerRadius = cornerRadius
    }
}
