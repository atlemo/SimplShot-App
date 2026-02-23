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
    case sunsetBlaze
    case oceanDreams
    case purpleHaze
    case forestMist
    case coralReef
    case mintFresh
    case goldenHour
    case midnightSky
    case darkEmber
    case carbonSteel

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sunsetBlaze: return "Sunset Blaze"
        case .oceanDreams: return "Ocean Dreams"
        case .purpleHaze:  return "Purple Haze"
        case .forestMist:  return "Forest Mist"
        case .coralReef:   return "Coral Reef"
        case .mintFresh:   return "Mint Fresh"
        case .goldenHour:  return "Golden Hour"
        case .midnightSky: return "Midnight Sky"
        case .darkEmber:   return "Dark Ember"
        case .carbonSteel: return "Carbon Steel"
        }
    }

    var gradientDefinition: GradientDefinition {
        switch self {
        case .sunsetBlaze:
            return GradientDefinition(colors: [
                CodableColor(red: 1.00, green: 0.42, blue: 0.42),
                CodableColor(red: 1.00, green: 0.90, blue: 0.43),
            ], angle: 135)
        case .oceanDreams:
            return GradientDefinition(colors: [
                CodableColor(red: 0.31, green: 0.67, blue: 1.00),
                CodableColor(red: 0.00, green: 0.95, blue: 1.00),
            ], angle: 135)
        case .purpleHaze:
            return GradientDefinition(colors: [
                CodableColor(red: 0.66, green: 0.93, blue: 0.92),
                CodableColor(red: 1.00, green: 0.84, blue: 0.89),
            ], angle: 135)
        case .forestMist:
            return GradientDefinition(colors: [
                CodableColor(red: 0.40, green: 0.49, blue: 0.92),
                CodableColor(red: 0.46, green: 0.29, blue: 0.64),
            ], angle: 135)
        case .coralReef:
            return GradientDefinition(colors: [
                CodableColor(red: 0.94, green: 0.58, blue: 0.98),
                CodableColor(red: 0.96, green: 0.34, blue: 0.42),
            ], angle: 135)
        case .mintFresh:
            return GradientDefinition(colors: [
                CodableColor(red: 0.31, green: 0.67, blue: 1.00),
                CodableColor(red: 0.26, green: 0.91, blue: 0.48),
            ], angle: 135)
        case .goldenHour:
            return GradientDefinition(colors: [
                CodableColor(red: 0.98, green: 0.55, blue: 1.00),
                CodableColor(red: 0.17, green: 0.82, blue: 1.00),
                CodableColor(red: 0.17, green: 1.00, blue: 0.53),
            ], angle: 135)
        case .midnightSky:
            return GradientDefinition(colors: [
                CodableColor(red: 0.10, green: 0.16, blue: 0.50),
                CodableColor(red: 0.15, green: 0.82, blue: 0.81),
            ], angle: 135)
        case .darkEmber:
            return GradientDefinition(colors: [
                CodableColor(red: 0.17, green: 0.11, blue: 0.24),
                CodableColor(red: 0.55, green: 0.26, blue: 0.40),
            ], angle: 135)
        case .carbonSteel:
            return GradientDefinition(colors: [
                CodableColor(red: 0.12, green: 0.16, blue: 0.22),
                CodableColor(red: 0.22, green: 0.25, blue: 0.32),
                CodableColor(red: 0.29, green: 0.33, blue: 0.39),
            ], angle: 135)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        if let mapped = BuiltInGradient(rawValue: raw) {
            self = mapped
            return
        }

        // Backward compatibility for previously saved gradient ids.
        switch raw {
        case "oceanBlue": self = .oceanDreams
        case "sunset": self = .sunsetBlaze
        case "aurora": self = .mintFresh
        case "lavender": self = .purpleHaze
        case "midnight": self = .midnightSky
        case "forest": self = .forestMist
        case "peach": self = .goldenHour
        case "slate": self = .carbonSteel
        case "berry": self = .coralReef
        case "sand": self = .darkEmber
        default:
            self = .oceanDreams
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
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
        wallpaperSource: .builtInGradient(.oceanDreams),
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
