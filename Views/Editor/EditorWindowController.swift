import AppKit
import ImageIO
import PDFKit
import SwiftUI

extension Notification.Name {
    static let editorModeCommand = Notification.Name("SimplShotEditorModeCommand")
    /// A menu command (Find, Document Info, page nav, zoom…) targeted at a
    /// specific editor window (posted with that `NSWindow` as the object).
    static let editorActionCommand = Notification.Name("SimplShotEditorActionCommand")
}

/// Manages the standalone editor window.
/// Retains itself while the window is open so callers don't need to hold a reference.
class EditorWindowController: NSWindowController, NSWindowDelegate {
    private var currentEditorMode: EditorMode = .annotate
    private var allowsEditMode: Bool = true
    private var setEditorMode: ((EditorMode) -> Void)?

    /// The default positions of the three window-control buttons, captured once
    /// before we inset them. macOS resets the buttons to these positions on every
    /// titlebar relayout (resize, focus change, fullscreen exit), so we always
    /// re-offset from this baseline rather than from their current frame.
    private var trafficLightBaseline: [CGPoint] = []
    /// How far to nudge the window controls in from the top-left corner so they
    /// line up with the in-content top action bar instead of hugging the corner.
    /// Titlebar coords are y-up, so a downward nudge is negative y.
    private let trafficLightInset = CGPoint(x: 8, y: -8)

    static var currentModeForKeyWindow: EditorMode? {
        keyEditorController?.currentEditorMode
    }

    static func canSetMode(_ mode: EditorMode) -> Bool {
        guard let controller = keyEditorController else { return true }
        return mode != .edit || controller.allowsEditMode
    }

    static func setModeForKeyWindow(_ mode: EditorMode) {
        guard canSetMode(mode) else { return }
        keyEditorController?.setEditorMode?(mode)
    }

    /// Posts a menu action to the key editor window (Find, Document Info, etc.).
    static func sendActionToKeyWindow(_ action: String) {
        guard let window = keyEditorController?.window else { return }
        NotificationCenter.default.post(
            name: .editorActionCommand,
            object: window,
            userInfo: ["action": action]
        )
    }

    private static var keyEditorController: EditorWindowController? {
        NSApp.keyWindow?.windowController as? EditorWindowController
    }

    /// All currently open editor windows. Each controller retains itself here
    /// while its window is open and removes itself on close.
    private static var openEditors: Set<EditorWindowController> = []

    /// Open the editor for a single captured screenshot.
    /// Pass `initialMode` to override the user's default-mode-on-open setting.
    static func openEditor(
        imageURL: URL,
        template: ScreenshotTemplate? = nil,
        appSettings: AppSettings? = nil,
        preferOriginalAspectRatio: Bool = false,
        initialMode: EditorMode? = nil
    ) {
        openEditor(
            imageURLs: [imageURL],
            template: template,
            appSettings: appSettings,
            preferOriginalAspectRatio: preferOriginalAspectRatio,
            initialMode: initialMode
        )
    }

    /// Open the editor with one or more images.
    /// Pass `initialMode` to override the user's default-mode-on-open setting.
    static func openEditor(
        imageURLs: [URL],
        template: ScreenshotTemplate? = nil,
        appSettings: AppSettings? = nil,
        preferOriginalAspectRatio: Bool = false,
        initialMode: EditorMode? = nil
    ) {
        guard !imageURLs.isEmpty else { return }
        let open = {
            for url in imageURLs {
                CaptureHistoryService.shared.recordCapture(fileURL: url)
            }
            let controller = EditorWindowController(
                imageURLs: imageURLs,
                template: template,
                appSettings: appSettings,
                preferOriginalAspectRatio: preferOriginalAspectRatio,
                initialMode: initialMode
            )
            openEditors.insert(controller)
            updateDockIconVisibility()
            controller.showWindow(nil)
            controller.bringToFront()
        }

        if Thread.isMainThread {
            open()
        } else {
            DispatchQueue.main.async(execute: open)
        }
    }

    private init(
        imageURLs: [URL],
        template: ScreenshotTemplate? = nil,
        appSettings: AppSettings? = nil,
        preferOriginalAspectRatio: Bool = false,
        initialMode: EditorMode? = nil
    ) {
        let windowSize = Self.savedWindowSize() ?? Self.windowSize(for: imageURLs[0])

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            // fullSizeContentView lets SwiftUI fill the entire window including
            // behind the title bar — backgrounds extend edge-to-edge while
            // content respects the safe area automatically.
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let title = imageURLs.count > 1
            ? String(localized: "Edit & Annotate — \(imageURLs.count) images")
            : String(localized: "Edit & Annotate — \(imageURLs[0].lastPathComponent)")
        window.title = title
        window.minSize = NSSize(width: 600, height: 500)
        window.isReleasedWhenClosed = false

        // Tahoe-style window chrome: transparent title bar with hidden title text.
        // Content flows behind the title bar; window controls float over the top-left.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden

        // No NSToolbar: the top controls (mode toggle, Undo, Save…) live in the
        // content as EditorView's top action bar, so they sit over the canvas —
        // right of the sidebar — and slide with it, exactly like the bottom
        // toolbar. A window toolbar spans the full window width, which floats its
        // items above the sidebar and can't follow the content inset.

        // Allow the sidebar to blend with whatever is behind the window.
        window.isOpaque = false
        window.backgroundColor = .clear

        // Clear any stale autosaved frame from earlier versions, then
        // don't autosave — each editor session uses the user's persisted size.
        NSWindow.removeFrame(usingName: "EditorWindow")
        // Cascade from the last editor's position so multiple windows don't stack exactly.
        if let lastWindow = Self.openEditors.compactMap({ $0.window }).last {
            let cascaded = window.cascadeTopLeft(from: NSPoint(
                x: lastWindow.frame.minX,
                y: lastWindow.frame.maxY
            ))
            window.cascadeTopLeft(from: cascaded)
        } else {
            window.center()
        }

        super.init(window: window)
        window.delegate = self

        // SwiftUI content — prevent the hosting view from shrinking the
        // window to its intrinsic content size.
        setEditorMode = { [weak window] mode in
            NotificationCenter.default.post(
                name: .editorModeCommand,
                object: window,
                userInfo: ["mode": mode.rawValue]
            )
        }

        let editorView = EditorView(
            imageURLs: imageURLs,
            template: template,
            appSettings: appSettings,
            preferOriginalAspectRatio: preferOriginalAspectRatio,
            initialMode: initialMode,
            onDismiss: { [weak self] in
                self?.close()
            },
            onModeChange: { [weak self] mode in
                self?.currentEditorMode = mode
            },
            onEditModeAvailabilityChange: { [weak self] allowsEditMode in
                self?.allowsEditMode = allowsEditMode
            }
        )
        let hostingView = NSHostingView(rootView: editorView)
        hostingView.sizingOptions = []  // don't let SwiftUI dictate the window size
        window.contentView = hostingView
    }

    /// Open the editor with pre-built sessions (used for PDF pages).
    static func openEditor(
        sessions: [ImageSession],
        appSettings: AppSettings? = nil
    ) {
        guard !sessions.isEmpty else { return }
        let open = {
            var seenURLs = Set<URL>()
            for session in sessions where seenURLs.insert(session.imageURL).inserted {
                CaptureHistoryService.shared.recordCapture(fileURL: session.imageURL)
            }
            let controller = EditorWindowController(
                sessions: sessions,
                appSettings: appSettings
            )
            openEditors.insert(controller)
            updateDockIconVisibility()
            controller.showWindow(nil)
            controller.bringToFront()
        }

        if Thread.isMainThread {
            open()
        } else {
            DispatchQueue.main.async(execute: open)
        }
    }

    private init(
        sessions: [ImageSession],
        appSettings: AppSettings? = nil
    ) {
        let windowSize = Self.savedWindowSize() ?? NSSize(width: 900, height: 700)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let fileName = sessions.first?.imageURL.deletingPathExtension().lastPathComponent ?? "PDF"
        let pageCount = sessions.count
        if sessions.first?.isPDF == true {
            window.title = pageCount > 1
                ? String(localized: "Annotate — \(fileName).pdf (\(pageCount) pages)")
                : String(localized: "Annotate — \(fileName).pdf")
        } else {
            // Raster sessions restored from Capture History.
            window.title = pageCount > 1
                ? String(localized: "Edit & Annotate — \(pageCount) images")
                : String(localized: "Edit & Annotate — \(sessions[0].imageURL.lastPathComponent)")
        }
        window.minSize = NSSize(width: 600, height: 500)
        window.isReleasedWhenClosed = false

        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden

        // No NSToolbar — the top controls live in the content (see the multi-image
        // openEditor above) so they follow the sidebar like the bottom toolbar.

        window.isOpaque = false
        window.backgroundColor = .clear

        NSWindow.removeFrame(usingName: "EditorWindow")
        if let lastWindow = Self.openEditors.compactMap({ $0.window }).last {
            let cascaded = window.cascadeTopLeft(from: NSPoint(
                x: lastWindow.frame.minX,
                y: lastWindow.frame.maxY
            ))
            window.cascadeTopLeft(from: cascaded)
        } else {
            window.center()
        }

        super.init(window: window)
        window.delegate = self

        setEditorMode = { [weak window] mode in
            NotificationCenter.default.post(
                name: .editorModeCommand,
                object: window,
                userInfo: ["mode": mode.rawValue]
            )
        }

        let editorView = EditorView(
            sessions: sessions,
            appSettings: appSettings,
            onDismiss: { [weak self] in
                self?.close()
            },
            onModeChange: { [weak self] mode in
                self?.currentEditorMode = mode
            },
            onEditModeAvailabilityChange: { [weak self] allowsEditMode in
                self?.allowsEditMode = allowsEditMode
            }
        )
        let hostingView = NSHostingView(rootView: editorView)
        hostingView.sizingOptions = []
        window.contentView = hostingView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        bringToFront()
        positionTrafficLights()
    }

    /// Inset the window controls (traffic lights) down + right from the default
    /// top-left corner so they align with the in-content top action bar. There's
    /// no `NSToolbar` to push them down (the top controls live in the SwiftUI
    /// content), so we offset the standard buttons by hand and re-apply on every
    /// titlebar relayout — macOS keeps resetting them to the corner otherwise.
    private func positionTrafficLights() {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
        guard buttons.count == 3 else { return }

        if trafficLightBaseline.count != 3 {
            // Capture the system's default layout once it's real, then offset from it.
            guard buttons.allSatisfy({ $0.frame.width > 0 }) else { return }
            trafficLightBaseline = buttons.map { $0.frame.origin }
        }
        for (button, base) in zip(buttons, trafficLightBaseline) {
            button.setFrameOrigin(CGPoint(x: base.x + trafficLightInset.x,
                                          y: base.y + trafficLightInset.y))
        }
    }

    /// Force the editor to the front, even when another app was just active
    /// during capture and focus handoff.
    private func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()

        // Re-assert after a short delay so macOS has time to finish the
        // accessory → regular activation-policy transition.
        for delay in [0.05, 0.2, 0.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let window = self?.window, window.isVisible else { return }
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    // MARK: - NSWindowDelegate

    // macOS resets the window controls to the top-left corner whenever the
    // titlebar relays out; re-apply our inset after each of those moments.
    func windowDidResize(_ notification: Notification) { positionTrafficLights() }
    func windowDidBecomeKey(_ notification: Notification) { positionTrafficLights() }
    func windowDidExitFullScreen(_ notification: Notification) { positionTrafficLights() }

    func windowWillClose(_ notification: Notification) {
        // Persist the current window size for next time
        if let size = window?.frame.size {
            Self.saveWindowSize(size)
        }
        Self.openEditors.remove(self)
        Self.updateDockIconVisibility()
    }

    /// Show Dock icon while at least one editor is open; hide it again when all are closed.
    private static func updateDockIconVisibility() {
        if openEditors.isEmpty {
            NSApp.setActivationPolicy(.accessory)
        } else {
            NSApp.setActivationPolicy(.regular)
        }
    }

    // MARK: - Window Sizing

    private static func saveWindowSize(_ size: NSSize) {
        let dict: [String: CGFloat] = ["width": size.width, "height": size.height]
        UserDefaults.standard.set(dict, forKey: Constants.UserDefaultsKeys.editorWindowSize)
    }

    private static func savedWindowSize() -> NSSize? {
        guard let dict = UserDefaults.standard.dictionary(forKey: Constants.UserDefaultsKeys.editorWindowSize),
              let w = dict["width"] as? CGFloat,
              let h = dict["height"] as? CGFloat
        else { return nil }
        return NSSize(width: w, height: h)
    }

    // MARK: - Hashable (identity-based for Set storage)

    override var hash: Int { ObjectIdentifier(self).hashValue }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? EditorWindowController else { return false }
        return self === other
    }

    /// Compute a window size that fits the image on screen while preserving
    /// the screenshot's aspect ratio as closely as possible.
    private static func windowSize(for imageURL: URL) -> NSSize {
        let defaultSize = NSSize(width: 900, height: 700)

        guard let nsImage = NSImage(contentsOf: imageURL),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            return defaultSize
        }

        let imageWidth = CGFloat(cgImage.width)
        let imageHeight = CGFloat(cgImage.height)

        guard let screen = NSScreen.main else { return defaultSize }
        let screenFrame = screen.visibleFrame

        // Chrome: toolbar (~50pt) + status bar (~30pt) + canvas padding (40pt)
        let chromeHeight: CGFloat = 120
        let chromePadding: CGFloat = 40

        let maxWidth = screenFrame.width * 0.5
        let maxHeight = screenFrame.height * 0.5

        // Scale the image to fit within the available area minus chrome
        let scaleX = (maxWidth - chromePadding) / imageWidth
        let scaleY = (maxHeight - chromeHeight) / imageHeight
        let scale = min(scaleX, scaleY)

        let contentWidth = imageWidth * scale + chromePadding
        let contentHeight = imageHeight * scale + chromeHeight

        return NSSize(
            width: max(min(contentWidth, maxWidth), 600),
            height: max(min(contentHeight, maxHeight), 500)
        )
    }
}

// MARK: - Capture History

/// Keeps the last `maxEntries` captured screenshots / edited files for the
/// "Capture History" film strip. Entries recorded when an editor window closes
/// carry the live `ImageSession` objects, so restoring reopens the editor with
/// every annotation, crop and template setting still editable. Entries recorded
/// at capture/open time (or reloaded from a previous launch) are URL-only and
/// restore by reopening the file from disk.
@MainActor
final class CaptureHistoryService {
    static let shared = CaptureHistoryService()

    struct Entry: Identifiable {
        let id = UUID()
        var fileURL: URL
        var date: Date
        var isPDF: Bool
        /// Live editable editor state (in-memory only — annotations aren't
        /// persisted to disk, so this is lost on quit).
        var sessions: [ImageSession]?
        var thumbnail: NSImage?
    }

    /// Newest first, capped at `maxEntries`.
    private(set) var entries: [Entry] = []
    private let maxEntries = 10
    private static let defaultsKey = "captureHistoryPaths"

    var isEmpty: Bool { entries.isEmpty }

    private init() {
        loadPersisted()
    }

    /// Record a captured or opened file. Dedupes by path: an existing entry is
    /// bumped to the front, keeping any live sessions it already carries.
    func recordCapture(fileURL: URL) {
        let path = fileURL.standardizedFileURL.path
        var entry: Entry
        if let idx = entries.firstIndex(where: { $0.fileURL.standardizedFileURL.path == path }) {
            entry = entries.remove(at: idx)
            entry.date = Date()
        } else {
            entry = Entry(
                fileURL: fileURL,
                date: Date(),
                isPDF: fileURL.pathExtension.lowercased() == "pdf",
                sessions: nil,
                thumbnail: nil
            )
        }
        entries.insert(entry, at: 0)
        trimAndPersist()
    }

    /// Record the full session state of a closing editor. PDF pages sharing a
    /// `pdfGroupID` collapse into one entry (the whole document restores
    /// together); every other session becomes its own entry.
    func recordSessions(_ sessions: [ImageSession]) {
        var handledGroups: Set<UUID> = []
        for session in sessions {
            if let groupID = session.pdfGroupID {
                guard handledGroups.insert(groupID).inserted else { continue }
                let pages = sessions.filter { $0.pdfGroupID == groupID }
                insertSessionEntry(fileURL: session.imageURL, sessions: pages, isPDF: true)
            } else if session.image != nil {
                insertSessionEntry(fileURL: session.imageURL, sessions: [session], isPDF: false)
            } else {
                // Never activated in the editor — no state worth keeping.
                recordCapture(fileURL: session.imageURL)
            }
        }
    }

    private func insertSessionEntry(fileURL: URL, sessions: [ImageSession], isPDF: Bool) {
        for session in sessions { Self.trimForHistory(session) }
        let path = fileURL.standardizedFileURL.path
        entries.removeAll { $0.fileURL.standardizedFileURL.path == path }
        // Note: deliberately NOT seeding from `sessions.first?.thumbnail` — the
        // editor regenerates that asynchronously, so at window-close time it can
        // still show a pre-edit state. `loadThumbnail` renders from the composed
        // display image instead, which always reflects the latest edits.
        let entry = Entry(fileURL: fileURL, date: Date(), isPDF: isPDF, sessions: sessions, thumbnail: nil)
        entries.insert(entry, at: 0)
        trimAndPersist()
    }

    /// Drop the heavyweight, restore-irrelevant parts of a session so ten
    /// history entries can't pin an unbounded amount of memory — every undo
    /// snapshot holds full-size bitmaps. The decoded images themselves are
    /// kept: reloading from disk would reset the crop rect (see `applyLoaded`).
    private static func trimForHistory(_ session: ImageSession) {
        session.undoStack = []
        session.preCropSnapshot = nil
        session.selectedAnnotationID = nil
        session.isCropping = false
    }

    /// Reopen an entry in the editor. Live sessions restore with all state; the
    /// entry is removed first so a second Restore can't open the same mutable
    /// session objects twice (the editor re-records them when it closes).
    func restore(_ entry: Entry, appSettings: AppSettings?) {
        if let sessions = entry.sessions, !sessions.isEmpty {
            entries.removeAll { $0.id == entry.id }
            trimAndPersist()
            EditorWindowController.openEditor(sessions: sessions, appSettings: appSettings)
        } else if entry.isPDF {
            let sessions = PDFService.loadPages(from: entry.fileURL)
            guard !sessions.isEmpty else { return }
            EditorWindowController.openEditor(sessions: sessions, appSettings: appSettings)
        } else {
            EditorWindowController.openEditor(imageURL: entry.fileURL, appSettings: appSettings)
        }
    }

    // MARK: Thumbnails

    /// Async thumbnail for a strip cell. Session entries render from the
    /// composed display image (so photo adjustments, crop and background are
    /// visible); URL-only entries decode a small preview from disk. Both run
    /// off the main thread and cache the result on the entry.
    func loadThumbnail(for entryID: UUID, completion: @escaping (NSImage?) -> Void) {
        guard let idx = entries.firstIndex(where: { $0.id == entryID }) else {
            completion(nil)
            return
        }
        if let cached = entries[idx].thumbnail {
            completion(cached)
            return
        }
        let displayImage = entries[idx].sessions?.first?.image
        let url = entries[idx].fileURL
        let isPDF = entries[idx].isPDF
        DispatchQueue.global(qos: .userInitiated).async {
            let thumb: NSImage?
            if let displayImage {
                thumb = Self.downscaledThumbnail(from: displayImage)
            } else {
                thumb = Self.diskThumbnail(for: url, isPDF: isPDF)
            }
            DispatchQueue.main.async {
                if let i = self.entries.firstIndex(where: { $0.id == entryID }) {
                    self.entries[i].thumbnail = thumb
                }
                completion(thumb)
            }
        }
    }

    /// Downscale a session's composed display image for the strip.
    private nonisolated static func downscaledThumbnail(from image: NSImage) -> NSImage? {
        guard let cgSource = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let pixelW = CGFloat(cgSource.width)
        let pixelH = CGFloat(cgSource.height)
        guard pixelW > 0, pixelH > 0 else { return nil }
        let scale = min(320 / pixelW, 320 / pixelH, 1.0)
        let renderW = max(Int((pixelW * scale).rounded()), 1)
        let renderH = max(Int((pixelH * scale).rounded()), 1)
        guard let ctx = CGContext(
            data: nil,
            width: renderW,
            height: renderH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cgSource, in: CGRect(x: 0, y: 0, width: renderW, height: renderH))
        guard let cgThumb = ctx.makeImage() else { return nil }
        return NSImage(cgImage: cgThumb, size: NSSize(width: renderW, height: renderH))
    }

    private nonisolated static func diskThumbnail(for url: URL, isPDF: Bool) -> NSImage? {
        if isPDF {
            guard let document = PDFDocument(url: url), let page = document.page(at: 0) else { return nil }
            let pageSize = page.rotatedMediaBoxSize
            guard pageSize.width > 0, pageSize.height > 0 else { return nil }
            let scale = 320 / max(pageSize.width, pageSize.height)
            return page.thumbnail(
                of: CGSize(width: pageSize.width * scale, height: pageSize.height * scale),
                for: .mediaBox
            )
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 320
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgThumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cgThumb, size: NSSize(width: cgThumb.width, height: cgThumb.height))
    }

    // MARK: Persistence (file paths only — sessions are in-memory)

    private struct PersistedEntry: Codable {
        let path: String
        let date: Date
    }

    private func loadPersisted() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let stored = try? JSONDecoder().decode([PersistedEntry].self, from: data)
        else { return }
        entries = stored.compactMap { item in
            guard FileManager.default.fileExists(atPath: item.path) else { return nil }
            let url = URL(fileURLWithPath: item.path)
            return Entry(
                fileURL: url,
                date: item.date,
                isPDF: url.pathExtension.lowercased() == "pdf",
                sessions: nil,
                thumbnail: nil
            )
        }
    }

    private func trimAndPersist() {
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
        let stored = entries.map {
            PersistedEntry(path: $0.fileURL.standardizedFileURL.path, date: $0.date)
        }
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}

/// Borderless panel for the film strip: can become key so it receives ESC
/// (via `cancelOperation`) despite having no title bar.
private final class CaptureHistoryPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    // Some first responders swallow cancelOperation — catch raw ESC too.
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
            return
        }
        super.keyDown(with: event)
    }
}

/// Shows the Capture History film strip in a floating panel above all windows.
/// Dismissed by ESC, by clicking anywhere outside the strip, or by restoring
/// an entry.
@MainActor
final class CaptureHistoryPanelController {
    static let shared = CaptureHistoryPanelController()

    private var panel: CaptureHistoryPanel?
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?

    private init() {}

    func show(appSettings: AppSettings?) {
        dismiss()
        let entries = CaptureHistoryService.shared.entries
        guard !entries.isEmpty else { return }

        // The screen with the mouse — where the user opened the status-bar menu.
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouseLocation) }
            ?? NSScreen.main
        let visible = screen?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let strip = CaptureHistoryStripView(
            entries: entries,
            onRestore: { entry in
                // Open the editor BEFORE dismissing the panel: the panel is the
                // app's only key window, and ordering out the last window of an
                // active accessory app deactivates it — the freshly opened
                // editor would then land behind other apps' windows.
                CaptureHistoryService.shared.restore(entry, appSettings: appSettings)
                CaptureHistoryPanelController.shared.dismiss()
            }
        )
        let hosting = NSHostingView(rootView: strip)
        // Ten thumbnails outgrow a small laptop screen — clamp the panel and
        // let the strip's internal ScrollView take over.
        let fitting = hosting.fittingSize
        let size = NSSize(
            width: min(fitting.width, visible.width - 40),
            height: fitting.height
        )

        let panel = CaptureHistoryPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.onCancel = { [weak self] in self?.dismiss() }
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .transient]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false

        // Centered horizontally, just below the menu bar.
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.maxY - size.height - 10
        ))

        self.panel = panel
        // Activate so the panel actually receives key events (ESC) — as a menu
        // bar app we're usually not the active application when this opens.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        // Click inside any other window of ours → dismiss.
        localClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            if event.window !== self?.panel {
                self?.dismiss()
            }
            return event
        }
        // Click anywhere outside the app → dismiss.
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }
    }

    func dismiss() {
        if let monitor = localClickMonitor {
            NSEvent.removeMonitor(monitor)
            localClickMonitor = nil
        }
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
        panel?.orderOut(nil)
        panel = nil
    }
}

/// The film strip content: a horizontal row of thumbnails, newest first.
/// Hovering a thumbnail reveals a Restore button.
private struct CaptureHistoryStripView: View {
    let entries: [CaptureHistoryService.Entry]
    let onRestore: (CaptureHistoryService.Entry) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(entries) { entry in
                    CaptureHistoryThumbView(entry: entry) {
                        onRestore(entry)
                    }
                }
            }
            .padding(12)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.separator.opacity(0.5), lineWidth: 1)
        )
        .padding(2)
    }
}

private struct CaptureHistoryThumbView: View {
    let entry: CaptureHistoryService.Entry
    let onRestore: () -> Void

    @State private var isHovering = false
    @State private var thumbnail: NSImage?

    var body: some View {
        ZStack {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(.quaternary)
                Image(systemName: entry.isPDF ? "doc.richtext" : "photo")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 120, height: 84)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            if isHovering {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.black.opacity(0.35))
                Button(action: onRestore) {
                    Text("Restore")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.separator.opacity(0.6), lineWidth: 1)
        )
        .onHover { isHovering = $0 }
        .help(entry.fileURL.lastPathComponent)
        .onAppear {
            CaptureHistoryService.shared.loadThumbnail(for: entry.id) { image in
                thumbnail = image
            }
        }
    }
}
