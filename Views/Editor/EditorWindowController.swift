import AppKit
import SwiftUI

/// Manages the standalone editor window.
/// Retains itself while the window is open so callers don't need to hold a reference.
class EditorWindowController: NSWindowController, NSWindowDelegate {

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
            ? "Edit & Annotate — \(imageURLs.count) images"
            : "Edit & Annotate — \(imageURLs[0].lastPathComponent)"
        window.title = title
        window.minSize = NSSize(width: 600, height: 500)
        window.isReleasedWhenClosed = false

        // Tahoe-style window chrome: transparent title bar with hidden title text.
        // Content flows behind the title bar; window controls float over the top-left.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden

        // An NSToolbar triggers the larger corner radius macOS Tahoe uses for
        // windows with toolbars (our actual toolbar is the SwiftUI glass pills).
        let toolbar = NSToolbar(identifier: "EditorToolbar")
        // showsBaselineSeparator removed in macOS 15+
        window.toolbar = toolbar
        window.toolbarStyle = .unified

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
        let editorView = EditorView(
            imageURLs: imageURLs,
            template: template,
            appSettings: appSettings,
            preferOriginalAspectRatio: preferOriginalAspectRatio,
            initialMode: initialMode
        ) { [weak self] in
            self?.close()
        }
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
        window.title = pageCount > 1
            ? "Annotate — \(fileName).pdf (\(pageCount) pages)"
            : "Annotate — \(fileName).pdf"
        window.minSize = NSSize(width: 600, height: 500)
        window.isReleasedWhenClosed = false

        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden

        let toolbar = NSToolbar(identifier: "EditorToolbar")
        window.toolbar = toolbar
        window.toolbarStyle = .unified

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

        let editorView = EditorView(
            sessions: sessions,
            appSettings: appSettings
        ) { [weak self] in
            self?.close()
        }
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
