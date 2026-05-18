import SwiftUI
import UniformTypeIdentifiers

// MARK: - Arrow style mini-preview (used in sidebar)

struct ArrowStylePreview: View {
    let style: ArrowStyle
    let isSelected: Bool
    var previewSize: CGSize = CGSize(width: 44, height: 26)

    var body: some View {
        Canvas { ctx, size in
            let s = CGPoint(x: 6, y: size.height * 0.62)
            let e = CGPoint(x: size.width - 6, y: size.height * 0.38)
            let color = isSelected ? Color.accentColor : Color.primary
            let lw: CGFloat = 1.5

            switch style {
            case .chevron:
                var path = Path(); path.move(to: s); path.addLine(to: e)
                ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: lw, lineCap: .round))
                let ang = atan2(e.y - s.y, e.x - s.x), hl: CGFloat = 8, ha = CGFloat.pi / 4
                let p1 = CGPoint(x: e.x - hl * cos(ang - ha), y: e.y - hl * sin(ang - ha))
                let p2 = CGPoint(x: e.x - hl * cos(ang + ha), y: e.y - hl * sin(ang + ha))
                var head = Path()
                head.move(to: e); head.addLine(to: p1)
                head.move(to: e); head.addLine(to: p2)
                ctx.stroke(head, with: .color(color), style: StrokeStyle(lineWidth: lw, lineCap: .round))

            case .triangle:
                let ang = atan2(e.y - s.y, e.x - s.x), hl: CGFloat = 7, ha = CGFloat.pi / 4
                let depth = hl * cos(ha)
                let base = CGPoint(x: e.x - depth * cos(ang), y: e.y - depth * sin(ang))
                var shaft = Path(); shaft.move(to: s); shaft.addLine(to: base)
                ctx.stroke(shaft, with: .color(color), style: StrokeStyle(lineWidth: lw, lineCap: .round))
                let p1 = CGPoint(x: e.x - hl * cos(ang - ha), y: e.y - hl * sin(ang - ha))
                let p2 = CGPoint(x: e.x - hl * cos(ang + ha), y: e.y - hl * sin(ang + ha))
                var tri = Path(); tri.move(to: e); tri.addLine(to: p1); tri.addLine(to: p2); tri.closeSubpath()
                ctx.fill(tri, with: .color(color))

            case .curved:
                let dx = e.x - s.x, dy = e.y - s.y
                let cp = CGPoint(x: (s.x + e.x) / 2 + dy * 0.3, y: (s.y + e.y) / 2 - dx * 0.3)
                var shaft = Path(); shaft.move(to: s); shaft.addQuadCurve(to: e, control: cp)
                ctx.stroke(shaft, with: .color(color), style: StrokeStyle(lineWidth: lw, lineCap: .round))
                let ang = atan2(e.y - cp.y, e.x - cp.x), hl: CGFloat = 7, ha = CGFloat.pi / 5
                let p1 = CGPoint(x: e.x - hl * cos(ang - ha), y: e.y - hl * sin(ang - ha))
                let p2 = CGPoint(x: e.x - hl * cos(ang + ha), y: e.y - hl * sin(ang + ha))
                var tri = Path(); tri.move(to: e); tri.addLine(to: p1); tri.addLine(to: p2); tri.closeSubpath()
                ctx.fill(tri, with: .color(color))

            case .sketch:
                let ang = atan2(e.y - s.y, e.x - s.x)
                let len = hypot(e.x - s.x, e.y - s.y)
                let ca = cos(ang), sa = sin(ang)
                let cp1 = CGPoint(x: s.x + ca*len*0.3 + (-sa)*len*0.07,
                                  y: s.y + sa*len*0.3 + ca*len*0.07)
                let cp2 = CGPoint(x: s.x + ca*len*0.7 - (-sa)*len*0.05,
                                  y: s.y + sa*len*0.7 - ca*len*0.05)
                var shaft = Path(); shaft.move(to: s); shaft.addCurve(to: e, control1: cp1, control2: cp2)
                ctx.stroke(shaft, with: .color(color), style: StrokeStyle(lineWidth: lw, lineCap: .round))
                let hl: CGFloat = 10, ha = CGFloat.pi / 5
                let p1 = CGPoint(x: e.x - hl * cos(ang - ha), y: e.y - hl * sin(ang - ha))
                let p2 = CGPoint(x: e.x - hl * cos(ang + ha), y: e.y - hl * sin(ang + ha))
                var head = Path()
                head.move(to: e); head.addLine(to: p1)
                head.move(to: e); head.addLine(to: p2)
                ctx.stroke(head, with: .color(color), style: StrokeStyle(lineWidth: lw, lineCap: .round))
            }
        }
        .frame(width: previewSize.width, height: previewSize.height)
    }
}

// MARK: - Scroll Wheel Modifier (used in EditorCanvasView)

/// Captures NSEvent scrollWheel events on a view and calls a handler with the direction (-1 or +1).
struct ScrollWheelModifier: ViewModifier {
    let handler: (_ direction: Int) -> Void

    func body(content: Content) -> some View {
        content.overlay(ScrollWheelReceiver(handler: handler))
    }
}

struct ScrollWheelReceiver: NSViewRepresentable {
    let handler: (_ direction: Int) -> Void

    func makeNSView(context: Context) -> ScrollWheelNSView {
        let view = ScrollWheelNSView()
        view.handler = handler
        return view
    }

    func updateNSView(_ nsView: ScrollWheelNSView, context: Context) {
        nsView.handler = handler
    }
}

class ScrollWheelNSView: NSView {
    var handler: ((_ direction: Int) -> Void)?
    private var accumulated: CGFloat = 0
    private var resetTask: DispatchWorkItem?

    override var acceptsFirstResponder: Bool { true }

    override func scrollWheel(with event: NSEvent) {
        let dx: CGFloat
        let dy: CGFloat

        if event.hasPreciseScrollingDeltas {
            dx = event.scrollingDeltaX
            dy = event.scrollingDeltaY
        } else {
            dx = event.scrollingDeltaX * 20
            dy = event.scrollingDeltaY * 20
        }

        let scroll = abs(dx) > abs(dy) ? dx : dy
        accumulated += scroll

        resetTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            self?.accumulated = 0
        }
        resetTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: task)

        let threshold: CGFloat = 15
        if abs(accumulated) >= threshold {
            handler?(accumulated > 0 ? -1 : 1)
            accumulated = 0
        }
    }
}

extension View {
    func onScrollWheel(_ handler: @escaping (_ direction: Int) -> Void) -> some View {
        modifier(ScrollWheelModifier(handler: handler))
    }
}

// MARK: - Rainbow Color Picker Button

/// A circular color-wheel button that opens NSColorPanel.
/// Use `color` binding to read/write the selected color.
struct RainbowColorPickerButton: View {
    @Binding var color: Color

    private static let wheelColors: [Color] = [
        .red, Color(hue: 0.08, saturation: 1, brightness: 1),
        .yellow, Color(hue: 0.25, saturation: 1, brightness: 1),
        .green, Color(hue: 0.5, saturation: 1, brightness: 1),
        .cyan, .blue,
        Color(hue: 0.75, saturation: 1, brightness: 1),
        .purple, .pink, .red
    ]

    var body: some View {
        Button {
            let panel = NSColorPanel.shared
            panel.color = NSColor(color)
            panel.isContinuous = true
            panel.orderFront(nil)
        } label: {
            Circle()
                .fill(AngularGradient(colors: Self.wheelColors, center: .center))
                .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
                .frame(width: 20, height: 20)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Custom Color")
        .onReceive(NotificationCenter.default.publisher(for: NSColorPanel.colorDidChangeNotification)) { _ in
            guard NSColorPanel.shared.isVisible else { return }
            color = Color(nsColor: NSColorPanel.shared.color)
        }
    }
}

// MARK: - BuiltInGradient SwiftUI helpers

extension BuiltInGradient {
    /// A top-leading → bottom-trailing linear gradient for preview circles.
    var swiftUIGradient: LinearGradient {
        let def = gradientDefinition
        let colors = def.colors.map {
            Color(red: $0.red, green: $0.green, blue: $0.blue, opacity: $0.alpha)
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
