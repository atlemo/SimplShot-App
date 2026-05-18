import CoreImage
import CoreGraphics

// MARK: - EditorMode

/// The active top-level mode of the editor.
enum EditorMode: String, Codable, CaseIterable, Identifiable {
    case annotate = "Annotate"
    case edit     = "Edit"
    case view     = "View"

    var id: String { rawValue }

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
        case .annotate: return "Annotate"
        case .edit:     return "Edit"
        case .view:     return "View"
        case .lastUsed: return "Last Used"
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
    /// CISharpenLuminance `inputSharpness`. Range: 0…2. Default: 0 (no sharpening).
    var sharpness: Float = 0.0
    /// Grain / film-noise amount blended over the image. Range: 0…1. Default: 0 (none).
    /// Implemented as a grayscale CIRandomGenerator layer composited at this alpha.
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

        // Temperature (CITemperatureAndTint expects a CIVector for neutral/targetNeutral)
        if temperature != 6500 {
            ci = ci.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral":       CIVector(x: CGFloat(temperature), y: 0),
                "inputTargetNeutral": CIVector(x: 6500, y: 0)
            ])
        }

        // Sharpness
        if sharpness != 0 {
            ci = ci.applyingFilter("CISharpenLuminance", parameters: ["inputSharpness": sharpness])
        }

        // Noise — composite a grayscale random pattern over the image at `noise` alpha.
        if noise > 0 {
            let extent = ci.extent
            // CIRandomGenerator is infinite — crop it to the source extent first.
            let grayscaleNoise = CIFilter(name: "CIRandomGenerator")?
                .outputImage?
                .cropped(to: extent)
                .applyingFilter("CIColorControls", parameters: [
                    "inputSaturation": 0,                 // strip color → film-grain look
                    "inputBrightness": 0,
                    "inputContrast":   1
                ])
                .applyingFilter("CIColorMatrix", parameters: [
                    // Scale the alpha channel by `noise` so the noise layer is semi-transparent.
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(noise))
                ])
            if let noiseLayer = grayscaleNoise {
                ci = noiseLayer.applyingFilter("CISourceOverCompositing", parameters: [
                    "inputBackgroundImage": ci
                ])
                // Compositing with a random layer can extend the extent; clamp back.
                ci = ci.cropped(to: extent)
            }
        }

        return ciContext.createCGImage(ci, from: ci.extent) ?? image
    }
}
