import SwiftUI

// MARK: - Tool Types

enum AnnotationTool: String, CaseIterable, Identifiable {
    case select
    case arrow
    case rectangle
    case circle
    case line
    case text
    case pixelate
    case crop

    var id: String { rawValue }

    var label: String {
        switch self {
        case .select:    return "Select"
        case .arrow:     return "Arrow"
        case .rectangle: return "Rectangle"
        case .circle:    return "Circle"
        case .line:      return "Line"
        case .text:      return "Text"
        case .pixelate:  return "Pixelate"
        case .crop:      return "Crop"
        }
    }

    var systemImage: String {
        switch self {
        case .select:    return "cursorarrow"
        case .arrow:     return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .circle:    return "circle"
        case .line:      return "line.diagonal"
        case .text:      return "textformat"
        case .pixelate:  return ""      // uses customImageName instead
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

// MARK: - Annotation Style

struct AnnotationStyle {
    var strokeColor: Color = .red
    var strokeWidth: CGFloat = 3
    var fontSize: CGFloat = 48

    /// CGColor for use in Core Graphics rendering.
    var cgStrokeColor: CGColor {
        NSColor(strokeColor).cgColor
    }

    /// Whether the stroke color is perceptually white.
    var isWhite: Bool {
        let ns = NSColor(strokeColor).usingColorSpace(.deviceRGB)
        guard let ns else { return false }
        return ns.redComponent > 0.95 && ns.greenComponent > 0.95 && ns.blueComponent > 0.95
    }

    /// Background color for text pills: black when the stroke is white, otherwise the stroke color.
    var textBubbleBackground: Color {
        isWhite ? .black : strokeColor
    }

    var cgTextBubbleBackground: CGColor {
        NSColor(textBubbleBackground).cgColor
    }
}

// MARK: - Annotation

/// A single annotation on the canvas.
/// Points are stored in **image-pixel coordinates** (matching the CGImage dimensions)
/// so they remain accurate regardless of view zoom or window size.
struct Annotation: Identifiable {
    let id: UUID
    var tool: AnnotationTool
    var startPoint: CGPoint    // image-pixel coordinates
    var endPoint: CGPoint      // image-pixel coordinates
    var style: AnnotationStyle
    var text: String           // only meaningful for .text tool

    init(
        id: UUID = UUID(),
        tool: AnnotationTool,
        startPoint: CGPoint,
        endPoint: CGPoint,
        style: AnnotationStyle = AnnotationStyle(),
        text: String = ""
    ) {
        self.id = id
        self.tool = tool
        self.startPoint = startPoint
        self.endPoint = endPoint
        self.style = style
        self.text = text
    }

    /// The bounding rect of this annotation in image-pixel coordinates.
    var boundingRect: CGRect {
        CGRect(
            x: min(startPoint.x, endPoint.x),
            y: min(startPoint.y, endPoint.y),
            width: abs(endPoint.x - startPoint.x),
            height: abs(endPoint.y - startPoint.y)
        )
    }
}

// MARK: - Undo Support

/// Snapshot of the editor state for undo/redo.
/// Captures both annotations and the current image (since crop is applied destructively).
struct EditorSnapshot {
    let annotations: [Annotation]
    let image: NSImage?
    let imagePixelSize: CGSize
    let cropRect: CGRect?

    init(
        annotations: [Annotation],
        image: NSImage? = nil,
        imagePixelSize: CGSize = .zero,
        cropRect: CGRect? = nil
    ) {
        self.annotations = annotations
        self.image = image
        self.imagePixelSize = imagePixelSize
        self.cropRect = cropRect
    }
}
