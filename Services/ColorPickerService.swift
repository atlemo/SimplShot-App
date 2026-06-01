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

    /// Serial capture loop driving live magnifier/color updates. Only ever one
    /// capture is in flight, so rapid mouse moves can't flood the subsystem.
    private var captureTask: Task<Void, Never>?
    /// Shareable content fetched once per session — but only AFTER our panels
    /// (esp. the magnifier) are registered with the window server, so they can be
    /// reliably excluded. Re-fetching this per frame is what made the live update
    /// sluggish; fetching it too early is what let the loupe capture itself.
    private var cachedShareableContent: SCShareableContent?
    /// Latest cursor location; the capture loop always samples the newest point.
    private var lastMousePoint: NSPoint = .zero
    /// When the cursor is over the HUD the loupe is hidden — skip capturing.
    private var cursorOverHUD = false

    // The loupe shows a 25pt × 25pt window of real content, drawn into the 100pt
    // magnifier → 4× zoom.
    private let captureSize: CGFloat = 25
    private let magnifierSize: CGFloat = 100

    // Performance: rather than capturing the screen on every mouse move, we
    // capture a larger region around the cursor occasionally and crop the 25pt
    // loupe window out of it locally (microseconds) on each move. This keeps the
    // magnified content perfectly in sync with the cursor (no jitter) while the
    // actual SCKit captures happen only when the cursor leaves the cached region
    // or the liveness interval elapses.
    private let regionSize: CGFloat = 220
    /// Last captured region image (native pixels, top-left origin).
    private var regionImage: CGImage?
    /// The NS-screen rect (bottom-left origin, points) that `regionImage` covers.
    private var regionRect: CGRect = .zero
    /// Backing scale of the captured region.
    private var regionScale: CGFloat = 2
    /// The cursor point the region was captured around (for the recapture trigger).
    private var regionCapturePoint: NSPoint = .zero
    /// Timestamp of the last region capture, for liveness refresh.
    private var lastCaptureTime: TimeInterval = 0

    func startPicking() {
        guard !isActive else { return }
        isActive = true
        previousApp = NSWorkspace.shared.frontmostApplication

        setupOverlay()
        setupMagnifier()
        setupHUD()

        NSApp.activate(ignoringOtherApps: true)
        overlayWindow?.makeKeyAndOrderFront(nil)

        lastMousePoint = NSEvent.mouseLocation

        // Build the capture filter/config once (now that our panels are on screen
        // so they can be excluded), then start the live capture loop.
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.prepareCapture()
            self.startCaptureLoop()
        }

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
        lastMousePoint = point
        let overHUD = hudPanel.map { $0.frame.contains(point) } ?? false
        cursorOverHUD = overHUD

        if overHUD {
            unhideCursor()
            magnifierPanel?.orderOut(nil)
        } else {
            hideCursor()
            magnifierPanel?.orderFront(nil)

            let half = magnifierSize / 2
            magnifierPanel?.setFrameOrigin(NSPoint(x: point.x - half, y: point.y - half))

            // Update the loupe content + color synchronously from the cached
            // region, so the magnified image tracks the cursor with zero lag.
            updateLoupeContent(at: point)
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
        var value = hudState.format.format(hudState.currentColor)
        // Strip the # prefix for HEX — users just want the hex digits on the clipboard.
        if hudState.format == .hex {
            value = value.replacingOccurrences(of: "#", with: "")
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        cleanup()
    }

    private func cancelPicking() {
        cleanup()
    }

    private func cleanup() {
        isActive = false
        captureTask?.cancel()
        captureTask = nil
        cachedShareableContent = nil
        regionImage = nil
        regionRect = .zero
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

    /// Fetches and caches shareable content for the session, but waits until our
    /// magnifier panel is actually registered in the window list first. The
    /// magnifier sits directly over the sampled point, so if it isn't in the
    /// exclusion list the loupe captures itself → recursive video feedback that
    /// renders as a black-and-white grid. A freshly-shown panel can be absent
    /// from `content.windows` for a few frames, so we poll until it appears.
    private func prepareCapture() async {
        for _ in 0..<20 {
            if !isActive || Task.isCancelled { return }
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else {
                try? await Task.sleep(for: .milliseconds(50))
                continue
            }
            let windowIDs = Set(content.windows.map { Int($0.windowID) })
            if let magNum = magnifierPanel?.windowNumber, windowIDs.contains(magNum) {
                cachedShareableContent = content
                return
            }
            // Magnifier not registered yet — keep the latest content as a
            // fallback but wait for the panel to appear.
            cachedShareableContent = content
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Refreshes the cached screen region only when needed: when the cursor has
    /// moved far enough that the loupe window would run off the cached region, or
    /// when the liveness interval elapses (so changing screen content updates).
    /// The per-move loupe rendering happens in `updateLoupeContent`, decoupled
    /// from these (comparatively rare) captures.
    private func startCaptureLoop() {
        captureTask?.cancel()
        captureTask = Task { @MainActor [weak self] in
            while true {
                guard let self, self.isActive, !Task.isCancelled else { return }

                if self.cursorOverHUD || self.cachedShareableContent == nil {
                    try? await Task.sleep(for: .milliseconds(40))
                    continue
                }

                let point = self.lastMousePoint
                if self.needsRegionRefresh(for: point) {
                    if let img = await self.captureRegion(around: point) {
                        if Task.isCancelled { return }
                        self.regionImage = img.image
                        self.regionRect = img.rect
                        self.regionScale = img.scale
                        self.regionCapturePoint = point
                        self.lastCaptureTime = Date().timeIntervalSinceReferenceDate
                        self.updateLoupeContent(at: self.lastMousePoint)
                    }
                }

                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    /// True when the cached region can no longer serve the loupe window for
    /// `point`, or it's time for a liveness refresh.
    private func needsRegionRefresh(for point: NSPoint) -> Bool {
        guard regionImage != nil else { return true }
        if Date().timeIntervalSinceReferenceDate - lastCaptureTime > 0.2 { return true }
        // Allowed travel from the capture point before the loupe window reaches
        // the region edge.
        let slack = regionSize / 2 - captureSize
        return abs(point.x - regionCapturePoint.x) > slack
            || abs(point.y - regionCapturePoint.y) > slack
    }

    /// Crops the 25pt loupe window out of the cached region image (and reads the
    /// exact cursor pixel for the color) — all local, no screen capture.
    private func updateLoupeContent(at point: NSPoint) {
        guard let img = regionImage, regionRect.width > 0 else { return }
        let scale = regionScale

        // Cursor position in the region image's pixel space (top-left origin).
        let px = (point.x - regionRect.minX) * scale
        let py = (regionRect.maxY - point.y) * scale   // NS y-up → CG y-down

        let imgW = CGFloat(img.width)
        let imgH = CGFloat(img.height)
        let win = (captureSize * scale).rounded()

        // Loupe window, clamped to stay inside the region image.
        var ox = (px - win / 2).rounded()
        var oy = (py - win / 2).rounded()
        ox = min(max(0, ox), max(0, imgW - win))
        oy = min(max(0, oy), max(0, imgH - win))
        let cropRect = CGRect(x: ox, y: oy, width: min(win, imgW), height: min(win, imgH))

        if let crop = img.cropping(to: cropRect) {
            magnifierView?.magnifiedContent = crop
        }

        // Color at the exact cursor pixel.
        let cx = min(max(0, Int(px)), img.width - 1)
        let cy = min(max(0, Int(py)), img.height - 1)
        if let color = color(atX: cx, y: cy, in: img) {
            hudState.currentColor = color
        }
    }

    private struct RegionCapture {
        let image: CGImage
        let rect: CGRect   // NS-screen rect (bottom-left origin)
        let scale: CGFloat
    }

    /// Captures `regionSize` × `regionSize` points around `point`, clamped to the
    /// main screen, excluding our own windows.
    private func captureRegion(around point: NSPoint) async -> RegionCapture? {
        guard let screen = NSScreen.main else { return nil }
        let full = screen.frame
        let half = regionSize / 2
        var rect = CGRect(x: point.x - half, y: point.y - half, width: regionSize, height: regionSize)
        // Clamp to the screen so SCKit's sourceRect stays in bounds.
        rect.origin.x = min(max(rect.origin.x, full.minX), full.maxX - rect.width)
        rect.origin.y = min(max(rect.origin.y, full.minY), full.maxY - rect.height)

        guard let img = await captureScreen(in: rect) else { return nil }
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        return RegionCapture(image: img, rect: rect, scale: scale)
    }

    /// Captures a rect given in NSScreen coordinates (origin bottom-left, y up).
    /// Builds a fresh filter + config from the cached shareable content each call
    /// (both are cheap; the expensive `SCShareableContent` fetch is cached). Our
    /// overlay/magnifier/HUD panels are excluded by matching window number so the
    /// loupe never captures itself.
    private func captureScreen(in nsRect: CGRect) async -> CGImage? {
        // SCKit uses CG screen coordinates: origin top-left, y down.
        let screenHeight = CGDisplayBounds(CGMainDisplayID()).height
        let cgRect = CGRect(
            x: nsRect.minX,
            y: screenHeight - nsRect.maxY,
            width: nsRect.width,
            height: nsRect.height
        )

        guard let content = cachedShareableContent,
              let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
        else { return nil }

        // Exclude our panels (by window number) AND, defensively, every window
        // owned by our process — so the magnifier can never feed back even if its
        // window number lookup misses.
        let myPID = getpid()
        let ourWindowNumbers = Set([overlayWindow, magnifierPanel, hudPanel]
            .compactMap { $0?.windowNumber }
            .filter { $0 > 0 })
        let excludedWindows = content.windows.filter {
            ourWindowNumbers.contains(Int($0.windowID)) || $0.owningApplication?.processID == myPID
        }

        let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)

        let config = SCStreamConfiguration()
        config.sourceRect = cgRect
        // Request native-resolution output so the magnifier looks sharp.
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        config.width = max(1, Int(nsRect.width * scale))
        config.height = max(1, Int(nsRect.height * scale))
        config.scalesToFit = false
        config.showsCursor = false

        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// Reads the sRGB color of a single pixel (`x`, `y` in the image's top-left
    /// pixel space) by drawing it into a 1×1 context.
    private func color(atX x: Int, y: Int, in image: CGImage) -> NSColor? {
        guard let pixel = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return nil }

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
