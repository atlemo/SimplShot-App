import AppKit
import SwiftUI

/// Manages the standalone editor window.
/// Retains itself while the window is open so callers don't need to hold a reference.
class EditorWindowController: NSWindowController, NSWindowDelegate {

    /// All currently open editor windows. Each controller retains itself here
    /// while its window is open and removes itself on close.
    private static var openEditors: Set<EditorWindowController> = []

    /// Open the editor for a captured screenshot.
    /// Multiple editors can be open simultaneously.
    static func openEditor(imageURL: URL, template: ScreenshotTemplate? = nil, appSettings: AppSettings? = nil) {
        let controller = EditorWindowController(imageURL: imageURL, template: template, appSettings: appSettings)
        openEditors.insert(controller)
        controller.showWindow(nil)
    }

    private init(imageURL: URL, template: ScreenshotTemplate? = nil, appSettings: AppSettings? = nil) {
        // Use the user's last saved size, or compute one from the image
        let windowSize = Self.savedWindowSize() ?? Self.windowSize(for: imageURL)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Edit & Annotate — \(imageURL.lastPathComponent)"
        window.minSize = NSSize(width: 600, height: 500)
        window.isReleasedWhenClosed = false

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
        let editorView = EditorView(imageURL: imageURL, template: template, appSettings: appSettings) { [weak self] in
            self?.close()
        }
        let hostingView = NSHostingView(rootView: editorView)
        hostingView.sizingOptions = []  // don't let SwiftUI dictate the window size
        window.contentView = hostingView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Persist the current window size for next time
        if let size = window?.frame.size {
            Self.saveWindowSize(size)
        }
        Self.openEditors.remove(self)
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
