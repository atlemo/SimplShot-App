import AppKit
import CoreImage
import ScreenCaptureKit
import SwiftUI

// MARK: - Color Format

enum ColorFormat: String, CaseIterable {
    case hex = "HEX"
    case rgba = "RGBA"
    case hsl = "HSL"

    func format(_ color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else { return "—" }
        let r = rgb.redComponent
        let g = rgb.greenComponent
        let b = rgb.blueComponent
        switch self {
        case .hex:
            return String(format: "#%02X%02X%02X",
                Int((r * 255).rounded()),
                Int((g * 255).rounded()),
                Int((b * 255).rounded()))
        case .rgba:
            return "rgba(\(Int((r*255).rounded())), \(Int((g*255).rounded())), \(Int((b*255).rounded())), 1)"
        case .hsl:
            let maxC = max(r, g, b)
            let minC = min(r, g, b)
            let l = (maxC + minC) / 2
            var h: CGFloat = 0
            var s: CGFloat = 0
            if maxC != minC {
                let d = maxC - minC
                s = l > 0.5 ? d / (2 - maxC - minC) : d / (maxC + minC)
                switch maxC {
                case r: h = ((g - b) / d).truncatingRemainder(dividingBy: 6)
                case g: h = (b - r) / d + 2
                default: h = (r - g) / d + 4
                }
                h /= 6
                if h < 0 { h += 1 }
            }
            return "hsl(\(Int((h*360).rounded())), \(Int((s*100).rounded()))%, \(Int((l*100).rounded()))%)"
        }
    }
}

// MARK: - HUD State

@Observable
final class ColorPickerHUDState {
    var currentColor: NSColor = .gray
    var format: ColorFormat = .hex

    var formattedValue: String { format.format(currentColor) }
    var swatchColor: Color { Color(nsColor: currentColor) }
}

// MARK: - HUD View

struct ColorPickerHUDView: View {
    var state: ColorPickerHUDState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Format tabs
            HStack(spacing: 2) {
                ForEach(ColorFormat.allCases, id: \.rawValue) { fmt in
                    Button {
                        state.format = fmt
                    } label: {
                        Text(fmt.rawValue)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(state.format == fmt ? .primary : .secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                state.format == fmt
                                    ? Color.primary.opacity(0.1)
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: 5)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 2)

            // Color value + swatch
            HStack(spacing: 10) {
                Text(state.formattedValue)
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)

                Spacer(minLength: 6)

                Circle()
                    .fill(state.swatchColor)
                    .frame(width: 30, height: 30)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .frame(width: 220)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Magnifier View

/// Custom NSView that renders a circular magnifier loupe.
/// The caller is responsible for keeping `magnifiedContent` up to date.
final class MagnifierView: NSView {
    /// CGImage captured from the screen area below the cursor.
    var magnifiedContent: CGImage? { didSet { needsDisplay = true } }

    private let borderWidth: CGFloat = 1.5
    private let squareSize: CGFloat  = 5

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let b = bounds
        let inset = borderWidth / 2
        let circleRect = b.insetBy(dx: inset, dy: inset)

        // --- Clip to circle and draw magnified content ---
        ctx.saveGState()
        ctx.addEllipse(in: circleRect)
        ctx.clip()

        // Fill with fallback grey first so any residual transparent pixels in
        // the captured image don't show through to the panel's clear background.
        ctx.setFillColor(NSColor(white: 0.88, alpha: 1).cgColor)
        ctx.fill(b)

        if let image = magnifiedContent {
            // AppKit's CGContext already has a y-flip in its CTM, which corrects
            // the CGImage's y-down orientation. Draw directly — no extra flip needed.
            ctx.draw(image, in: b)
        }
        ctx.restoreGState()

        // --- Circle border ---
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.75).cgColor)
        ctx.setLineWidth(borderWidth)
        ctx.addEllipse(in: circleRect)
        ctx.strokePath()

        // --- Center square (indicates the exact sampled pixel) ---
        let sq = CGRect(
            x: b.midX - squareSize / 2,
            y: b.midY - squareSize / 2,
            width: squareSize,
            height: squareSize
        )
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        ctx.fill(sq)
        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(sq)
    }
}

// MARK: - Overlay NSView

private final class ColorPickerOverlayView: NSView {
    var onMouseMoved: ((NSPoint) -> Void)?
    var onMouseClicked: (() -> Void)?
    var onEscPressed: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        onMouseMoved?(NSEvent.mouseLocation)
    }

    override func mouseDown(with event: NSEvent) {
        onMouseClicked?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC
            onEscPressed?()
        } else {
            super.keyDown(with: event)
        }
    }
}

// MARK: - Color Picker Service

@MainActor
final class ColorPickerService {
    private var overlayWindow: NSPanel?
    private var magnifierPanel: NSPanel?
    private var magnifierView: MagnifierView?
    private var hudPanel: NSPanel?
    private var hudState = ColorPickerHUDState()
    private var isActive = false
    private var previousApp: NSRunningApplication?
    private var isCursorHidden = false

    private var captureStream: SCStream?
    private var streamOutput: ColorPickerStreamOutput?
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var latestCIImage: CIImage?
    private var excludedWindowNumbers: Set<Int> = []

    // Capture 25pt × 25pt of real content; drawn into the 100pt magnifier → 4× zoom.
    private let captureSize: CGFloat = 25
    private let magnifierSize: CGFloat = 100

    func startPicking() {
        guard !isActive else { return }
        isActive = true
        previousApp = NSWorkspace.shared.frontmostApplication

        setupOverlay()
        setupMagnifier()
        setupHUD()

        NSApp.activate(ignoringOtherApps: true)
        overlayWindow?.makeKeyAndOrderFront(nil)

        // Collect window numbers of our own panels so the stream can exclude them.
        excludedWindowNumbers = [
            overlayWindow?.windowNumber,
            magnifierPanel?.windowNumber,
            hudPanel?.windowNumber
        ].compactMap { $0 }.filter { $0 != 0 }.reduce(into: Set()) { $0.insert($1) }

        Task { await startCaptureStream() }

        hideCursor()
    }

    private func startCaptureStream() async {
        guard let screen = NSScreen.main,
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { return }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else { return }

            let windowsToExclude = content.windows.filter { excludedWindowNumbers.contains(Int($0.windowID)) }
            let filter = SCContentFilter(display: display, excludingWindows: windowsToExclude)

            let scale = Float(screen.backingScaleFactor)
            let config = SCStreamConfiguration()
            config.width = Int(screen.frame.width * CGFloat(scale))
            config.height = Int(screen.frame.height * CGFloat(scale))
            config.showsCursor = false
            config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            config.pixelFormat = kCVPixelFormatType_32BGRA

            let output = ColorPickerStreamOutput { [weak self] ciImage in
                Task { @MainActor [weak self] in self?.latestCIImage = ciImage }
            }
            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))
            try await stream.startCapture()
            captureStream = stream
            streamOutput = output
        } catch {
            // Permission not yet granted or unavailable — captureScreen returns nil gracefully.
        }
    }

    // MARK: - Window Setup

    private func setupOverlay() {
        guard let screen = NSScreen.main else { return }

        let panel = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovable = false
        panel.acceptsMouseMovedEvents = true

        let view = ColorPickerOverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.onMouseMoved = { [weak self] point in
            self?.handleMouseMove(at: point)
        }
        view.onMouseClicked = { [weak self] in
            self?.finishPicking()
        }
        view.onEscPressed = { [weak self] in
            self?.cancelPicking()
        }
        panel.contentView = view

        overlayWindow = panel
    }

    private func setupMagnifier() {
        let size = magnifierSize
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: size, height: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = MagnifierView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        panel.contentView = view
        panel.orderFront(nil)

        let mouse = NSEvent.mouseLocation
        let half = magnifierSize / 2
        panel.setFrameOrigin(NSPoint(x: mouse.x - half, y: mouse.y - half))

        magnifierPanel = panel
        magnifierView = view
    }

    private func setupHUD() {
        guard let screen = NSScreen.main else { return }

        let hudWidth: CGFloat = 220
        let hudHeight: CGFloat = 74
        let margin: CGFloat = 12
        let visibleFrame = screen.visibleFrame
        let origin = NSPoint(
            x: visibleFrame.maxX - hudWidth - margin,
            y: visibleFrame.maxY - hudHeight - margin
        )

        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: CGSize(width: hudWidth, height: hudHeight)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = false
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let hosting = NSHostingView(rootView: ColorPickerHUDView(state: hudState))
        hosting.frame = NSRect(x: 0, y: 0, width: hudWidth, height: hudHeight)
        panel.contentView = hosting
        panel.orderFront(nil)

        hudPanel = panel
    }

    // MARK: - Mouse Handling

    private func handleMouseMove(at point: NSPoint) {
        let overHUD = hudPanel.map { $0.frame.contains(point) } ?? false

        if overHUD {
            unhideCursor()
            magnifierPanel?.orderOut(nil)
        } else {
            hideCursor()
            magnifierPanel?.orderFront(nil)

            let half = magnifierSize / 2
            magnifierPanel?.setFrameOrigin(NSPoint(x: point.x - half, y: point.y - half))

            let result = captureArea(around: point)
            magnifierView?.magnifiedContent = result.image
            if let color = result.color {
                hudState.currentColor = color
            }
        }
    }

    private func hideCursor() {
        guard !isCursorHidden else { return }
        NSCursor.hide()
        isCursorHidden = true
    }

    private func unhideCursor() {
        guard isCursorHidden else { return }
        NSCursor.unhide()
        isCursorHidden = false
    }

    // MARK: - Pick / Cancel

    private func finishPicking() {
        let value = hudState.format.format(hudState.currentColor)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        cleanup()
    }

    private func cancelPicking() {
        cleanup()
    }

    private func cleanup() {
        isActive = false
        excludedWindowNumbers = []
        latestCIImage = nil
        let stream = captureStream
        captureStream = nil
        streamOutput = nil
        Task { try? await stream?.stopCapture() }
        unhideCursor()
        overlayWindow?.orderOut(nil)
        overlayWindow = nil
        magnifierPanel?.orderOut(nil)
        magnifierPanel = nil
        magnifierView = nil
        hudPanel?.orderOut(nil)
        hudPanel = nil
        if NSApp.windows.isEmpty {
            NSApp.setActivationPolicy(.accessory)
        }
        previousApp?.activate()
        previousApp = nil
    }

    // MARK: - Screen Capture

    private struct CaptureResult {
        let image: CGImage?
        let color: NSColor?
    }

    private func captureArea(around point: NSPoint) -> CaptureResult {
        let captureRect = CGRect(
            x: floor(point.x - captureSize / 2),
            y: floor(point.y - captureSize / 2),
            width: captureSize,
            height: captureSize
        )
        guard let img = captureScreen(in: captureRect) else {
            return CaptureResult(image: nil, color: nil)
        }
        return CaptureResult(image: img, color: extractCenterColor(from: img))
    }

    /// Captures a rect given in NSScreen coordinates (origin bottom-left, y up).
    /// Crops from the latest SCStream frame, which excludes our overlay/magnifier/HUD panels.
    private func captureScreen(in nsRect: CGRect) -> CGImage? {
        guard let ciImage = latestCIImage else { return nil }
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        // CIImage (from SCStream) uses bottom-left origin — same as NSScreen — so no Y-flip needed.
        let pixelRect = CGRect(
            x: nsRect.minX * scale,
            y: nsRect.minY * scale,
            width: nsRect.width * scale,
            height: nsRect.height * scale
        )
        let cropped = ciImage.cropped(to: pixelRect)
        // Glass/vibrancy windows can produce alpha < 1.0 in the SCKit frame.
        // Composite over opaque black to flatten alpha before sampling or display.
        let background = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)).cropped(to: cropped.extent)
        let flattened = cropped.composited(over: background)
        return ciContext.createCGImage(flattened, from: flattened.extent)
    }

    private func extractCenterColor(from image: CGImage) -> NSColor? {
        let cx = image.width / 2
        let cy = image.height / 2

        guard let pixel = image.cropping(to: CGRect(x: cx, y: cy, width: 1, height: 1)) else { return nil }

        guard let ctx = CGContext(
            data: nil,
            width: 1, height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))

        guard let data = ctx.data else { return nil }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        let components: [CGFloat] = [
            CGFloat(bytes[0]) / 255.0,
            CGFloat(bytes[1]) / 255.0,
            CGFloat(bytes[2]) / 255.0,
            1.0
        ]
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let cgColor = CGColor(colorSpace: colorSpace, components: components) else { return nil }
        return NSColor(cgColor: cgColor)
    }
}

// MARK: - SCStream output handler

private final class ColorPickerStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    private let onFrame: (CIImage) -> Void

    init(onFrame: @escaping (CIImage) -> Void) {
        self.onFrame = onFrame
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let imageBuffer = buffer.imageBuffer else { return }
        onFrame(CIImage(cvImageBuffer: imageBuffer))
    }
}
