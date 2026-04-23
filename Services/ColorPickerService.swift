import AppKit
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

        if let image = magnifiedContent {
            // AppKit's CGContext already has a y-flip in its CTM, which corrects
            // the CGImage's y-down orientation. Draw directly — no extra flip needed.
            ctx.draw(image, in: b)
        } else {
            ctx.setFillColor(NSColor(white: 0.88, alpha: 1).cgColor)
            ctx.fill(b)
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
        // White fill so the square reads on any background
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        ctx.fill(sq)
        // Black border
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

    /// Window ID of the overlay, used to exclude our panels from magnifier captures.
    private var overlayWindowID: CGWindowID = kCGNullWindowID
    private var captureDisplay: SCDisplay?
    private var excludedCaptureWindows: [SCWindow] = []

    // How many points of real content the magnifier shows (100pt circle ÷ 3× zoom).
    private let captureSize: CGFloat = 25   // magnifierSize / 4× zoom
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

        // Store window ID after the window is on screen so it's valid.
        overlayWindowID = CGWindowID(overlayWindow?.windowNumber ?? 0)
        configureScreenCaptureContext()

        hideCursor()
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
        panel.ignoresMouseEvents = true   // clicks fall through to the overlay
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = MagnifierView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        panel.contentView = view
        panel.orderFront(nil)

        // Position at the current cursor location immediately.
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
            // Show system cursor so the user can click the format tabs.
            unhideCursor()
            magnifierPanel?.orderOut(nil)
        } else {
            // Restore picker state: hide cursor, show magnifier.
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
        overlayWindowID = kCGNullWindowID
        captureDisplay = nil
        excludedCaptureWindows = []
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

    /// Captures `captureSize × captureSize` points around `point`, excluding our
    /// overlay and magnifier panels from the image (so they never appear in the loupe).
    private func captureArea(around point: NSPoint) -> CaptureResult {
        let captureRect = CGRect(
            x: floor(point.x - captureSize / 2),
            y: floor(point.y - captureSize / 2),
            width: captureSize,
            height: captureSize
        )

        let cgImage = captureImage(in: captureRect)

        guard let img = cgImage else { return CaptureResult(image: nil, color: nil) }

        // Extract the center pixel for the live color readout.
        let color = extractCenterColor(from: img)
        return CaptureResult(image: img, color: color)
    }

    private func configureScreenCaptureContext() {
        guard #available(macOS 14.0, *),
              let mainScreen = NSScreen.main,
              let screenNumber = mainScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return
        }

        let displayID = CGDirectDisplayID(screenNumber.uint32Value)
        let excludedWindowIDs = Set(
            [overlayWindow?.windowNumber, magnifierPanel?.windowNumber, hudPanel?.windowNumber]
                .compactMap { $0 }
                .map(CGWindowID.init)
        )
        let semaphore = DispatchSemaphore(value: 0)

        Task.detached(priority: .userInitiated) { [excludedWindowIDs] in
            let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

            await MainActor.run {
                self.captureDisplay = content?.displays.first(where: { $0.displayID == displayID })
                self.excludedCaptureWindows = content?.windows.filter { excludedWindowIDs.contains($0.windowID) } ?? []
            }

            semaphore.signal()
        }

        semaphore.wait()
    }

    private func captureImage(in captureRect: CGRect) -> CGImage? {
        if captureDisplay == nil {
            configureScreenCaptureContext()
        }

        guard let captureDisplay else { return nil }
        return captureImageWithScreenCaptureKit(in: captureRect, display: captureDisplay)
    }

    @available(macOS 14.0, *)
    private func captureImageWithScreenCaptureKit(in captureRect: CGRect, display: SCDisplay) -> CGImage? {
        let displayLocalRect = CGRect(
            x: captureRect.minX - display.frame.minX,
            y: captureRect.minY - display.frame.minY,
            width: captureRect.width,
            height: captureRect.height
        ).intersection(CGRect(origin: .zero, size: display.frame.size))

        guard !displayLocalRect.isNull, !displayLocalRect.isEmpty else { return nil }

        let filter = SCContentFilter(display: display, excludingWindows: excludedCaptureWindows)
        let config = SCStreamConfiguration()
        let scale = max(CGFloat(filter.pointPixelScale), 1)

        config.sourceRect = displayLocalRect
        config.width = max(Int(ceil(displayLocalRect.width * scale)), 1)
        config.height = max(Int(ceil(displayLocalRect.height * scale)), 1)
        config.showsCursor = false
        config.ignoreShadowsDisplay = true

        var image: CGImage?
        let semaphore = DispatchSemaphore(value: 0)

        SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { capturedImage, _ in
            image = capturedImage
            semaphore.signal()
        }

        semaphore.wait()
        return image
    }

    private func extractCenterColor(from image: CGImage) -> NSColor? {
        let cx = image.width / 2
        let cy = image.height / 2

        // Crop a 1×1 pixel region at the exact center of the captured image.
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
