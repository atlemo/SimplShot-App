import Foundation
import CoreGraphics

// MARK: - Canvas Alignment

/// The position of the screenshot within the gradient canvas.
/// Used when an aspect ratio is applied and the canvas is larger than the screenshot.
/// Cases are intentionally distinct from SwiftUI.Alignment names to avoid inference conflicts.
enum CanvasAlignment: String, CaseIterable, Codable {
    case topLeft, topCenter, topRight
    case middleLeft, middleCenter, middleRight
    case bottomLeft, bottomCenter, bottomRight

    var horizontalFraction: CGFloat {
        switch self {
        case .topLeft, .middleLeft, .bottomLeft:       return 0
        case .topCenter, .middleCenter, .bottomCenter: return 0.5
        case .topRight, .middleRight, .bottomRight:    return 1
        }
    }

    var verticalFraction: CGFloat {
        switch self {
        case .topLeft, .topCenter, .topRight:          return 0
        case .middleLeft, .middleCenter, .middleRight: return 0.5
        case .bottomLeft, .bottomCenter, .bottomRight: return 1
        }
    }
}

struct CodableColor: Codable, Equatable, Hashable {
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

/// How a `GradientDefinition` is painted. Linear follows `angle`; radial
/// grows from the centre outwards and ignores it.
enum GradientKind: String, Codable, Equatable, Hashable, CaseIterable, Identifiable {
    case linear
    case radial

    var id: String { rawValue }

    /// Localized label for pickers. Kept separate from `rawValue`, which is
    /// persisted and must stay English.
    var displayName: String {
        switch self {
        case .linear: return String(localized: "Linear")
        case .radial: return String(localized: "Radial")
        }
    }
}

struct GradientDefinition: Codable, Equatable, Hashable {
    let colors: [CodableColor]
    let angle: Double
    /// Stop positions in 0...1, one per colour. `nil` — every built-in
    /// gradient — means evenly spaced, which is what `CGGradient` and
    /// SwiftUI's `Gradient` both do for a bare colour list.
    let locations: [Double]?
    let kind: GradientKind

    init(
        colors: [CodableColor],
        angle: Double,
        locations: [Double]? = nil,
        kind: GradientKind = .linear
    ) {
        self.colors = colors
        self.angle = angle
        self.locations = locations
        self.kind = kind
    }

    /// `locations` / `kind` were added with custom gradients — anything encoded
    /// before that is an evenly-spaced linear gradient.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        colors = try container.decode([CodableColor].self, forKey: .colors)
        angle = try container.decode(Double.self, forKey: .angle)
        locations = try container.decodeIfPresent([Double].self, forKey: .locations)
        kind = try container.decodeIfPresent(GradientKind.self, forKey: .kind) ?? .linear
    }

    /// One position per colour, always — the stored array is used only when it
    /// matches the colours it is meant to describe, so a truncated or stale
    /// `locations` can never desync the paint from the swatch.
    var resolvedLocations: [CGFloat] {
        if let locations, locations.count == colors.count {
            // CGGradient wants ascending locations; a running max keeps each
            // position paired with its own colour while guaranteeing that.
            var running: CGFloat = 0
            return locations.map { raw in
                running = max(running, CGFloat(min(max(raw, 0), 1)))
                return running
            }
        }
        guard colors.count > 1 else { return colors.isEmpty ? [] : [0] }
        let last = CGFloat(colors.count - 1)
        return (0..<colors.count).map { CGFloat($0) / last }
    }

    /// Identity for the renderer's tile / background caches. Covers everything
    /// that changes a pixel.
    var cacheKey: String {
        let stops = zip(colors, resolvedLocations)
            .map { "\($0.red),\($0.green),\($0.blue),\($0.alpha)@\($1)" }
            .joined(separator: ";")
        return "\(kind.rawValue)|\(angle)|\(stops)"
    }
}

/// The gradient editor's stop ramp: where a stop's pin is drawn, and which
/// stop a click on the ramp grabs.
///
/// One source for both, because they must agree — a hit test computed
/// separately from the drawing is exactly how a handle ends up unclickable, or
/// clickable somewhere it isn't drawn.
enum GradientStopBarGeometry {
    /// Width of a pin's square body. The tail hangs below it.
    static let pinWidth: CGFloat = 24
    /// How far outside a pin a click still grabs it.
    static let grabSlack: CGFloat = 10

    /// The pin **body** is clamped to the ramp; the **tip** is not. At 0% and
    /// 100% the body stays fully on the ramp and the tail slides into the
    /// nearest corner, so the tip still marks the exact position.
    static func bodyLeft(tipX: CGFloat, barWidth: CGFloat, pinWidth: CGFloat = pinWidth) -> CGFloat {
        min(max(tipX - pinWidth / 2, 0), max(barWidth - pinWidth, 0))
    }

    /// Index into `locations` of the stop a click at `x` grabs, or nil when the
    /// click is nowhere near one.
    ///
    /// Among the pins under the cursor the nearest **tip** wins. Pins overlap
    /// as soon as two stops are close, and picking by body — or by draw order —
    /// then hands the click to whichever pin happens to be on top rather than
    /// the one being aimed at. Tips stay distinct where bodies do not, so two
    /// stops a few points apart remain separately grabbable.
    static func grabbedStop(
        at x: CGFloat,
        locations: [Double],
        barWidth: CGFloat,
        pinWidth: CGFloat = pinWidth,
        slack: CGFloat = grabSlack
    ) -> Int? {
        var underCursor: [(index: Int, tipDistance: CGFloat)] = []
        var nearest: (index: Int, distance: CGFloat)?
        for (index, location) in locations.enumerated() {
            let tipX = CGFloat(location) * barWidth
            let left = bodyLeft(tipX: tipX, barWidth: barWidth, pinWidth: pinWidth)
            let distance = max(max(left - x, x - (left + pinWidth)), 0)
            if distance == 0 { underCursor.append((index, abs(tipX - x))) }
            if nearest == nil || distance < nearest!.distance {
                nearest = (index, distance)
            }
        }
        if let best = underCursor.min(by: { $0.tipDistance < $1.tipDistance }) { return best.index }
        if let nearest, nearest.distance <= slack { return nearest.index }
        return nil
    }
}

/// A gradient the user built in the gradient editor. The `id` exists so the
/// swatch grid can list and edit them; `WallpaperSource` still stores the
/// **definition** inline, so deleting a preset never breaks a saved template
/// or an image that is already using it.
struct CustomGradient: Codable, Equatable, Hashable, Identifiable {
    let id: UUID
    var definition: GradientDefinition

    init(id: UUID = UUID(), definition: GradientDefinition) {
        self.id = id
        self.definition = definition
    }
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

    // Solid colors
    case solidWhite
    case solidBlack
    case solidGray
    case solidRed
    case solidOrange
    case solidYellow
    case solidGreen
    case solidBlue
    case solidPurple
    case solidPink

    var id: String { rawValue }

    var isSolidColor: Bool {
        switch self {
        case .solidWhite, .solidBlack, .solidGray, .solidRed, .solidOrange,
             .solidYellow, .solidGreen, .solidBlue, .solidPurple, .solidPink:
            return true
        default:
            return false
        }
    }

    /// Whether this swatch needs a visible border to stand out against a light background.
    var needsBorder: Bool {
        self == .solidWhite
    }

    static var gradients: [BuiltInGradient] {
        allCases.filter { !$0.isSolidColor }
    }

    static var solidColors: [BuiltInGradient] {
        allCases.filter { $0.isSolidColor }
    }

    var displayName: String {
        switch self {
        case .sunsetBlaze: return String(localized: "Sunset Blaze")
        case .oceanDreams: return String(localized: "Ocean Dreams")
        case .purpleHaze:  return String(localized: "Purple Haze")
        case .forestMist:  return String(localized: "Forest Mist")
        case .coralReef:   return String(localized: "Coral Reef")
        case .mintFresh:   return String(localized: "Mint Fresh")
        case .goldenHour:  return String(localized: "Golden Hour")
        case .midnightSky: return String(localized: "Midnight Sky")
        case .darkEmber:   return String(localized: "Dark Ember")
        case .carbonSteel: return String(localized: "Carbon Steel")
        case .solidWhite:  return String(localized: "White")
        case .solidBlack:  return String(localized: "Black")
        case .solidGray:   return String(localized: "Gray")
        case .solidRed:    return String(localized: "Red")
        case .solidOrange: return String(localized: "Orange")
        case .solidYellow: return String(localized: "Yellow")
        case .solidGreen:  return String(localized: "Green")
        case .solidBlue:   return String(localized: "Blue")
        case .solidPurple: return String(localized: "Purple")
        case .solidPink:   return String(localized: "Pink")
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
        case .solidWhite:
            return GradientDefinition(colors: [CodableColor(red: 1.00, green: 1.00, blue: 1.00)], angle: 0)
        case .solidBlack:
            return GradientDefinition(colors: [CodableColor(red: 0.10, green: 0.10, blue: 0.10)], angle: 0)
        case .solidGray:
            return GradientDefinition(colors: [CodableColor(red: 0.55, green: 0.55, blue: 0.58)], angle: 0)
        case .solidRed:
            return GradientDefinition(colors: [CodableColor(red: 0.92, green: 0.26, blue: 0.24)], angle: 0)
        case .solidOrange:
            return GradientDefinition(colors: [CodableColor(red: 1.00, green: 0.58, blue: 0.00)], angle: 0)
        case .solidYellow:
            return GradientDefinition(colors: [CodableColor(red: 1.00, green: 0.84, blue: 0.04)], angle: 0)
        case .solidGreen:
            return GradientDefinition(colors: [CodableColor(red: 0.20, green: 0.78, blue: 0.35)], angle: 0)
        case .solidBlue:
            return GradientDefinition(colors: [CodableColor(red: 0.00, green: 0.48, blue: 1.00)], angle: 0)
        case .solidPurple:
            return GradientDefinition(colors: [CodableColor(red: 0.57, green: 0.32, blue: 0.87)], angle: 0)
        case .solidPink:
            return GradientDefinition(colors: [CodableColor(red: 1.00, green: 0.38, blue: 0.58)], angle: 0)
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
    case customColor(CodableColor)
    /// A user-built gradient, stored by value — see `CustomGradient`.
    case customGradient(GradientDefinition)
}

struct ScreenshotTemplate: Codable {
    var isEnabled: Bool
    var wallpaperSource: WallpaperSource
    var padding: Int
    var cornerRadius: Int
    var watermarkSettings: WatermarkSettings

    static let `default` = ScreenshotTemplate(
        isEnabled: false,
        wallpaperSource: .builtInGradient(.oceanDreams),
        padding: 80,
        cornerRadius: 24,
        watermarkSettings: WatermarkSettings()
    )

    /// Backwards-compatible decoding: older saved templates won't have `cornerRadius`
    /// or `watermarkSettings`.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        wallpaperSource = try container.decode(WallpaperSource.self, forKey: .wallpaperSource)
        padding = try container.decode(Int.self, forKey: .padding)
        cornerRadius = try container.decodeIfPresent(Int.self, forKey: .cornerRadius) ?? 24
        watermarkSettings = try container.decodeIfPresent(WatermarkSettings.self, forKey: .watermarkSettings) ?? WatermarkSettings()
    }

    init(
        isEnabled: Bool,
        wallpaperSource: WallpaperSource,
        padding: Int,
        cornerRadius: Int = 0,
        watermarkSettings: WatermarkSettings = WatermarkSettings()
    ) {
        self.isEnabled = isEnabled
        self.wallpaperSource = wallpaperSource
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.watermarkSettings = watermarkSettings
    }
}

struct EditorTemplatePreset: Codable, Identifiable {
    let id: UUID
    var name: String
    var wallpaperSource: WallpaperSource?
    var padding: Int
    var cornerRadius: Int
    var shadowIntensity: Double
    var aspectRatioID: UUID?
    var alignment: CanvasAlignment
    var watermarkSettings: WatermarkSettings

    init(
        id: UUID = UUID(),
        name: String,
        wallpaperSource: WallpaperSource?,
        padding: Int,
        cornerRadius: Int,
        shadowIntensity: Double = 1.0,
        aspectRatioID: UUID? = nil,
        alignment: CanvasAlignment = .middleCenter,
        watermarkSettings: WatermarkSettings = WatermarkSettings()
    ) {
        self.id = id
        self.name = name
        self.wallpaperSource = wallpaperSource
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.shadowIntensity = shadowIntensity
        self.aspectRatioID = aspectRatioID
        self.alignment = alignment
        self.watermarkSettings = watermarkSettings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        wallpaperSource = try container.decodeIfPresent(WallpaperSource.self, forKey: .wallpaperSource)
        padding = try container.decodeIfPresent(Int.self, forKey: .padding) ?? 80
        cornerRadius = try container.decodeIfPresent(Int.self, forKey: .cornerRadius) ?? 24
        shadowIntensity = try container.decodeIfPresent(Double.self, forKey: .shadowIntensity) ?? 1.0
        aspectRatioID = try container.decodeIfPresent(UUID.self, forKey: .aspectRatioID)
        alignment = try container.decodeIfPresent(CanvasAlignment.self, forKey: .alignment) ?? .middleCenter
        watermarkSettings = try container.decodeIfPresent(WatermarkSettings.self, forKey: .watermarkSettings) ?? WatermarkSettings()
    }

    /// Whether the editor is showing no template look at all, given the image's
    /// current background and the template the picker has selected. Drives the
    /// picker's "None" row.
    ///
    /// The whole template composite — padding, corners, shadow, aspect ratio,
    /// alignment — is applied inside `if let wallpaper` in
    /// `EditorView.composeDisplayImage`, so with no wallpaper none of it
    /// renders and naming a template would be a fiction.
    ///
    /// ⚠️ **"No wallpaper" alone is NOT the test.** A template may legitimately
    /// carry no background of its own: `default(from:)` produces exactly that
    /// whenever the capture template is disabled, and "Save as new" preserves
    /// it. Such a template applies perfectly well — treating it as "no
    /// template" made the picker snap straight back to None the moment the user
    /// selected it.
    static func noTemplateApplied(wallpaper: WallpaperSource?,
                                  selected: EditorTemplatePreset?) -> Bool {
        // No template chosen at all — there is nothing to name, whatever the
        // image looks like. Picking "None" lands here, and so does adding a
        // background by hand afterwards: that background is the user's, not a
        // template's. This is checked FIRST; testing the wallpaper first made
        // a hand-picked background resurrect the deselected template's name.
        guard let selected else { return true }
        // A background means that template's look is rendering.
        guard wallpaper == nil else { return false }
        // Bare image + a template that would have given it a background = that
        // template is not in effect. Bare image + a bare template = it is.
        return selected.wallpaperSource != nil
    }

    static func `default`(from template: ScreenshotTemplate, aspectRatioID: UUID? = nil) -> EditorTemplatePreset {
        EditorTemplatePreset(
            name: String(localized: "My default"),
            wallpaperSource: template.isEnabled ? template.wallpaperSource : nil,
            padding: template.padding,
            cornerRadius: template.cornerRadius,
            shadowIntensity: 1.0,
            aspectRatioID: aspectRatioID,
            alignment: .middleCenter,
            watermarkSettings: template.watermarkSettings
        )
    }
}
