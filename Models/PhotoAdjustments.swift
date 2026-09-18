import CoreImage
import CoreGraphics

// MARK: - EditorMode

/// The active top-level mode of the editor.
enum EditorMode: String, Codable, CaseIterable, Identifiable {
    case annotate = "Annotate"
    case edit     = "Edit"
    case view     = "View"

    var id: String { rawValue }

    /// Localized label for the mode switch. Kept separate from `rawValue`,
    /// which is persisted via `Codable` and must stay English.
    var displayName: String {
        switch self {
        case .annotate: return String(localized: "Annotate")
        case .edit:     return String(localized: "Edit")
        case .view:     return String(localized: "View")
        }
    }

    var systemImage: String {
        switch self {
        case .annotate: return "pencil.tip"
        case .edit:     return "slider.horizontal.3"
        case .view:     return "eye"
        }
    }
}

// MARK: - DefaultEditorModeSetting

/// The user's choice for which mode to start in when opening images.
/// `lastUsed` falls back to whichever mode the user last left the editor in.
enum DefaultEditorModeSetting: String, Codable, CaseIterable, Identifiable {
    case annotate
    case edit
    case view
    case lastUsed

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .annotate: return String(localized: "Annotate")
        case .edit:     return String(localized: "Edit")
        case .view:     return String(localized: "View")
        case .lastUsed: return String(localized: "Last Used")
        }
    }

    /// Resolve this setting to a concrete `EditorMode` using `lastUsed` as a fallback source.
    func resolve(lastUsed: EditorMode) -> EditorMode {
        switch self {
        case .annotate: return .annotate
        case .edit:     return .edit
        case .view:     return .view
        case .lastUsed: return lastUsed
        }
    }
}

// MARK: - PhotoAdjustments

/// Non-destructive photo adjustments applied via Core Image filters in the display pipeline.
/// All values at their defaults produce no change (identity transform).
struct PhotoAdjustments: Equatable, Codable {
    /// CIExposureAdjust `inputEV`. Range: -2…+2 EV. Default: 0 (no change).
    var exposure: Float = 0.0
    /// CIColorControls `inputBrightness`. Range: -1…+1. Default: 0 (no change).
    var brightness: Float = 0.0
    /// CIColorControls `inputContrast`. Range: 0.25…4.0. Default: 1.0 (no change).
    var contrast: Float = 1.0
    /// CIColorControls `inputSaturation`. Range: 0…2. Default: 1.0 (no change).
    var saturation: Float = 1.0
    /// CIHighlightShadowAdjust `inputHighlightAmount`. Range: 0…2. Default: 1.0 (no change).
    var highlights: Float = 1.0
    /// CIHighlightShadowAdjust `inputShadowAmount`. Range: 0…1. Default: 0 (no change).
    var shadows: Float = 0.0
    /// CITemperatureAndTint neutral colour temperature in Kelvin. Range: 2000…10000 K. Default: 6500 (no change).
    var temperature: Float = 6500
    /// CITemperatureAndTint green↔magenta tint (the neutral vector's y component). Range: -100…100. Default: 0 (no change).
    var tint: Float = 0.0
    /// CISharpenLuminance `inputSharpness`. Range: 0…2. Default: 0 (no sharpening).
    var sharpness: Float = 0.0
    /// Grain / film-noise amount blended over the image. Range: 0…1. Default: 0 (none).
    /// A grey CIRandomGenerator layer blended in **overlay** mode, with this
    /// value as the grain's contrast about mid-grey (see `apply(to:)`).
    var noise: Float = 0.0

    /// True when all values are at their defaults — the filter chain can be skipped entirely.
    var isDefault: Bool {
        exposure   == 0    &&
        brightness == 0    &&
        contrast   == 1    &&
        saturation == 1    &&
        highlights == 1    &&
        shadows    == 0    &&
        temperature == 6500 &&
        tint       == 0    &&
        sharpness  == 0    &&
        noise      == 0
    }

    static let `default` = PhotoAdjustments()

    // MARK: - Core Image application

    /// Applies the full filter chain to `image` and returns the adjusted CGImage.
    /// Returns the original image unchanged when `isDefault` is true.
    func apply(to image: CGImage, ciContext: CIContext) -> CGImage {
        guard !isDefault else { return image }

        var ci = CIImage(cgImage: image)

        // Exposure
        if exposure != 0 {
            ci = ci.applyingFilter("CIExposureAdjust", parameters: ["inputEV": exposure])
        }

        // Brightness / Contrast / Saturation (one filter handles all three)
        if brightness != 0 || contrast != 1 || saturation != 1 {
            ci = ci.applyingFilter("CIColorControls", parameters: [
                "inputBrightness": brightness,
                "inputContrast":   contrast,
                "inputSaturation": saturation
            ])
        }

        // Highlights / Shadows
        if highlights != 1 || shadows != 0 {
            ci = ci.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": highlights,
                "inputShadowAmount": shadows
            ])
        }

        // Temperature + Tint (CITemperatureAndTint expects a CIVector for neutral/targetNeutral:
        // x = colour temperature in Kelvin, y = green↔magenta tint).
        if temperature != 6500 || tint != 0 {
            ci = ci.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral":       CIVector(x: CGFloat(temperature), y: CGFloat(tint)),
                "inputTargetNeutral": CIVector(x: 6500, y: 0)
            ])
        }

        // Sharpness
        if sharpness != 0 {
            ci = ci.applyingFilter("CISharpenLuminance", parameters: ["inputSharpness": sharpness])
        }

        // Noise — film grain, blended in OVERLAY mode.
        //
        // ⚠️ NOT source-over. Core Image composites premultiplied, so a grain
        // layer whose alpha is scaled while its RGB stays at full strength is
        // *added* rather than blended: `CISourceOverCompositing` computes
        // `src + dst·(1 − src_a)`, which lifts the image instead of texturing
        // it. Measured on flat patches, the old chain took a grey-40 shadow to
        // 74 at slider 0.10 while producing almost no visible grain.
        //
        // Overlay is the identity at mid-grey, so the strength knob is the
        // grain's **contrast about the midpoint** — `inputContrast` pivots
        // there, 0 is exactly a no-op, and the grain fades in symmetrically.
        // Measured on flat patches, the mean now holds to 0.1/255 in shadows,
        // midtones and highlights alike, with the grain strongest in the
        // midtones the way film is.
        if noise > 0 {
            let extent = ci.extent
            // CIRandomGenerator is infinite — crop it to the source extent
            // first. It is deterministic, so the preview and the export get
            // the same grain.
            //
            // ⚠️ The grain is taken from the generator's **alpha** channel, not
            // its RGB. The generator emits premultiplied RGBA with a random
            // alpha, and `CIColorMatrix` unpremultiplies before it multiplies
            // — so reading RGB divides each pixel by its own small random
            // alpha and blows ~10% of them to pure white. That is bright salt,
            // not grain, and no amount of contrast scaling pulls it back
            // because the values are already clipped. The alpha channel is
            // untouched by that divide: uniform over 0…1 and independent of
            // RGB. Building grey from it also makes the layer monochrome by
            // construction, with no desaturation step.
            let grain = CIFilter(name: "CIRandomGenerator")?
                .outputImage?
                .cropped(to: extent)
                .applyingFilter("CIColorMatrix", parameters: [
                    // grey = input alpha, alpha = 1
                    "inputRVector":    CIVector(x: 0, y: 0, z: 0, w: 1),
                    "inputGVector":    CIVector(x: 0, y: 0, z: 0, w: 1),
                    "inputBVector":    CIVector(x: 0, y: 0, z: 0, w: 1),
                    "inputAVector":    CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)
                ])
                .applyingFilter("CIColorControls", parameters: [
                    // Strength: compress the grain toward overlay's identity point.
                    "inputSaturation": 1,
                    "inputBrightness": 0,
                    "inputContrast":   noise
                ])
            if let grain {
                ci = grain.applyingFilter("CIOverlayBlendMode", parameters: [
                    "inputBackgroundImage": ci
                ])
                // Blending with a generated layer can extend the extent; clamp back.
                ci = ci.cropped(to: extent)
            }
        }

        return ciContext.createCGImage(ci, from: ci.extent) ?? image
    }
}
