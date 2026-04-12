import SwiftUI

// MARK: - Tool Types

enum AnnotationTool: String, CaseIterable, Identifiable {
    case select
    case arrow
    case freeDraw
    case measurement
    case rectangle
    case circle
    case line
    case text
    case pixelate
    case spotlight
    case numberedStep
    case crop

    var id: String { rawValue }

    var label: String {
        switch self {
        case .select:    return "Select"
        case .arrow:     return "Arrow"
        case .freeDraw:  return "Free Drawing"
        case .measurement: return "Measurement"
        case .rectangle: return "Rectangle"
        case .circle:    return "Circle"
        case .line:      return "Line"
        case .text:      return "Text"
        case .pixelate:  return "Pixelate"
        case .spotlight: return "Spotlight"
        case .numberedStep: return "Steps"
        case .crop:      return "Crop"
        }
    }

    var systemImage: String {
        switch self {
        case .select:    return "cursorarrow"
        case .arrow:     return "arrow.up.right"
        case .freeDraw:  return "pencil.and.scribble"
        case .measurement: return "ruler"
        case .rectangle: return "rectangle"
        case .circle:    return "circle"
        case .line:      return "line.diagonal"
        case .text:      return "textformat"
        case .pixelate:  return ""      // uses customImageName instead
        case .spotlight: return "light.overhead.left"
        case .numberedStep: return "1.circle.fill"
        case .crop:      return "crop"
        }
    }

    /// Asset catalog image name for tools that use a custom icon instead of an SF Symbol.
    var customImageName: String? {
        switch self {
        case .pixelate: return "PixelateIcon"
        default:        return nil
        }
    }
}

// MARK: - Arrow Style

enum ArrowStyle: String, CaseIterable {
    case chevron   // open V arrowhead (default)
    case triangle  // filled solid triangle tip
    case curved    // arc shaft with filled triangle tip
    case sketch    // hand-drawn: S-curve shaft with wide chevron

    var label: String {
        switch self {
        case .chevron:  return "Arrow"
        case .triangle: return "Filled"
        case .curved:   return "Curved"
        case .sketch:   return "Sketch"
        }
    }
}

// MARK: - Annotation Style

struct AnnotationStyle: Equatable {
    var strokeColor: Color = .red
    var strokeWidth: CGFloat = 3
    var fontSize: CGFloat = 48
    var pixelationScale: CGFloat = 20
    var arrowStyle: ArrowStyle = .chevron
    var fillRect: Bool = false
    var fillCircle: Bool = false
    var spotlightOpacity: CGFloat = 0.5

    /// CGColor for use in Core Graphics rendering.
    var cgStrokeColor: CGColor {
        NSColor(strokeColor).cgColor
    }

    /// Whether the stroke color is perceptually light (luminance > 0.4).
    /// Used to decide whether to place dark or light text on top.
    var isLight: Bool {
        guard let ns = NSColor(strokeColor).usingColorSpace(.deviceRGB) else { return false }
        // sRGB relative luminance (WCAG formula)
        func linearize(_ c: CGFloat) -> CGFloat {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let r = linearize(ns.redComponent)
        let g = linearize(ns.greenComponent)
        let b = linearize(ns.blueComponent)
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return luminance > 0.4
    }

    /// Foreground color for text labels placed on top of the stroke color.
    /// Light-colored bubbles (white, yellow, etc.) use dark text; dark bubbles use white text.
    var textBubbleForeground: Color {
        isLight ? .black : .white
    }

    var cgTextBubbleForeground: CGColor {
        NSColor(textBubbleForeground).cgColor
    }

    /// Background color for text pills and step badges.
    var textBubbleBackground: Color {
        strokeColor
    }

    var cgTextBubbleBackground: CGColor {
        NSColor(textBubbleBackground).cgColor
    }
}

// MARK: - Annotation

/// A single annotation on the canvas.
/// Points are stored in **image-pixel coordinates** (matching the CGImage dimensions)
/// so they remain accurate regardless of view zoom or window size.
struct Annotation: Identifiable, Equatable {
    let id: UUID
    var tool: AnnotationTool
    var startPoint: CGPoint    // image-pixel coordinates
    var endPoint: CGPoint      // image-pixel coordinates
    var points: [CGPoint]      // used by free-draw tool
    var style: AnnotationStyle
    var text: String           // only meaningful for .text tool
    var stepNumber: Int        // only meaningful for .numberedStep tool

    init(
        id: UUID = UUID(),
        tool: AnnotationTool,
        startPoint: CGPoint,
        endPoint: CGPoint,
        points: [CGPoint] = [],
        style: AnnotationStyle = AnnotationStyle(),
        text: String = "",
        stepNumber: Int = 0
    ) {
        self.id = id
        self.tool = tool
        self.startPoint = startPoint
        self.endPoint = endPoint
        self.points = points
        self.style = style
        self.text = text
        self.stepNumber = stepNumber
    }

    /// The bounding rect of this annotation in image-pixel coordinates.
    var boundingRect: CGRect {
        if tool == .freeDraw, !points.isEmpty {
            let xs = points.map(\.x)
            let ys = points.map(\.y)
            if let minX = xs.min(), let maxX = xs.max(),
               let minY = ys.min(), let maxY = ys.max() {
                return CGRect(
                    x: minX,
                    y: minY,
                    width: max(maxX - minX, 1),
                    height: max(maxY - minY, 1)
                )
            }
        }
        return CGRect(
            x: min(startPoint.x, endPoint.x),
            y: min(startPoint.y, endPoint.y),
            width: abs(endPoint.x - startPoint.x),
            height: abs(endPoint.y - startPoint.y)
        )
    }
}

// MARK: - Undo Support

/// Snapshot of the editor state for undo/redo.
/// Captures annotations, the rendered display image, and the non-destructive crop rect.
struct EditorSnapshot {
    let annotations: [Annotation]
    let image: NSImage?
    let rawImage: NSImage?
    let selectedWallpaper: WallpaperSource?
    let imagePixelSize: CGSize
    let cropRect: CGRect?
    /// The current crop in raw screenshot pixel space (non-destructive crop state).
    let screenshotCropRect: CGRect?

    init(
        annotations: [Annotation],
        image: NSImage? = nil,
        rawImage: NSImage? = nil,
        selectedWallpaper: WallpaperSource? = nil,
        imagePixelSize: CGSize = .zero,
        cropRect: CGRect? = nil,
        screenshotCropRect: CGRect? = nil
    ) {
        self.annotations = annotations
        self.image = image
        self.rawImage = rawImage
        self.selectedWallpaper = selectedWallpaper
        self.imagePixelSize = imagePixelSize
        self.cropRect = cropRect
        self.screenshotCropRect = screenshotCropRect
    }
}
