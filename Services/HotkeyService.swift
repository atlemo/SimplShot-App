import KeyboardShortcuts

extension KeyboardShortcuts.Name {
#if !APPSTORE
    static let resizeAndCapture = Self("resizeAndCapture")
    static let batchCapture = Self("batchCapture")
#endif
    static let freeSizeCapture = Self("freeSizeCapture")
    static let captureWindow = Self("captureWindow")
    static let captureTextOCR = Self("captureTextOCR")
    static let colorPicker = Self("colorPicker")
    static let openScreenshotsFolder = Self("openScreenshotsFolder")

    /// Editor-window shortcut for the Save & Copy action (⌘C by default).
    ///
    /// ⚠️ This name must NEVER hold a live global hotkey. `EditorView`'s local
    /// key monitor matches the recorded shortcut itself, so the action only
    /// fires in an editor window and only when no text field has focus.
    ///
    /// Attaching a `KeyboardShortcuts.onKeyDown` handler is not the only way to
    /// get one: the library registers a **global Carbon hotkey inside
    /// `setShortcut`**, whether or not any handler exists. Both
    /// `Name(_:default:)` (on the first launch, when UserDefaults has no value
    /// yet) and every recorder/reset write therefore install a system-wide ⌘C
    /// that swallows Copy in *every* app for the rest of the process lifetime.
    ///
    /// `HotkeyService.unregisterEditorOnlyShortcuts()` undoes that, and must be
    /// called after launch and after every write. See `ShortcutsSettingsView`.
    static let copyToClipboard = Self("copyToClipboard", default: .init(.c, modifiers: .command))
}

class HotkeyService {
#if !APPSTORE
    private var onResizeAndCapture: (() -> Void)?
    private var onBatchCapture: (() -> Void)?
#endif
    private var onFreeSizeCapture: (() -> Void)?
    private var onCaptureWindow: (() -> Void)?
    private var onCaptureTextOCR: (() -> Void)?
    private var onColorPicker: (() -> Void)?
    private var onOpenScreenshotsFolder: (() -> Void)?

    init() {}

    /// Tears down any global hotkey the library installed for editor-only
    /// shortcut names (see `.copyToClipboard`). Referencing the name forces its
    /// lazy `Name` initialization first, so the default-shortcut write on a
    /// fresh install is registered and unregistered within this call rather
    /// than leaking a system-wide ⌘C.
    ///
    /// Safe to call repeatedly; `disable` is a no-op when nothing is registered.
    @MainActor
    static func unregisterEditorOnlyShortcuts() {
        KeyboardShortcuts.disable(.copyToClipboard)
    }

#if !APPSTORE
    @MainActor
    func register(
        onResizeAndCapture: @escaping () -> Void,
        onBatchCapture: @escaping () -> Void,
        onFreeSizeCapture: @escaping () -> Void,
        onCaptureTextOCR: @escaping () -> Void,
        onColorPicker: @escaping () -> Void,
        onOpenScreenshotsFolder: @escaping () -> Void
    ) {
        self.onResizeAndCapture = onResizeAndCapture
        self.onBatchCapture = onBatchCapture
        self.onFreeSizeCapture = onFreeSizeCapture
        self.onCaptureTextOCR = onCaptureTextOCR
        self.onColorPicker = onColorPicker
        self.onOpenScreenshotsFolder = onOpenScreenshotsFolder

        KeyboardShortcuts.onKeyDown(for: .resizeAndCapture) { [weak self] in
            self?.onResizeAndCapture?()
        }
        KeyboardShortcuts.onKeyDown(for: .batchCapture) { [weak self] in
            self?.onBatchCapture?()
        }
        KeyboardShortcuts.onKeyDown(for: .freeSizeCapture) { [weak self] in
            self?.onFreeSizeCapture?()
        }
        KeyboardShortcuts.onKeyDown(for: .captureTextOCR) { [weak self] in
            self?.onCaptureTextOCR?()
        }
        KeyboardShortcuts.onKeyDown(for: .colorPicker) { [weak self] in
            self?.onColorPicker?()
        }
        KeyboardShortcuts.onKeyDown(for: .openScreenshotsFolder) { [weak self] in
            self?.onOpenScreenshotsFolder?()
        }
    }
#else
    @MainActor
    func register(
        onFreeSizeCapture: @escaping () -> Void,
        onCaptureWindow: @escaping () -> Void,
        onCaptureTextOCR: @escaping () -> Void,
        onColorPicker: @escaping () -> Void,
        onOpenScreenshotsFolder: @escaping () -> Void
    ) {
        self.onFreeSizeCapture = onFreeSizeCapture
        self.onCaptureWindow = onCaptureWindow
        self.onCaptureTextOCR = onCaptureTextOCR
        self.onColorPicker = onColorPicker
        self.onOpenScreenshotsFolder = onOpenScreenshotsFolder

        KeyboardShortcuts.onKeyDown(for: .freeSizeCapture) { [weak self] in
            self?.onFreeSizeCapture?()
        }
        KeyboardShortcuts.onKeyDown(for: .captureWindow) { [weak self] in
            self?.onCaptureWindow?()
        }
        KeyboardShortcuts.onKeyDown(for: .captureTextOCR) { [weak self] in
            self?.onCaptureTextOCR?()
        }
        KeyboardShortcuts.onKeyDown(for: .colorPicker) { [weak self] in
            self?.onColorPicker?()
        }
        KeyboardShortcuts.onKeyDown(for: .openScreenshotsFolder) { [weak self] in
            self?.onOpenScreenshotsFolder?()
        }
    }
#endif
}
