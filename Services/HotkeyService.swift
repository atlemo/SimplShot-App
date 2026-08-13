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
    /// Deliberately NOT registered in `HotkeyService.register` — the moment a
    /// handler is attached, KeyboardShortcuts installs a *global* Carbon hotkey
    /// and ⌘C would be swallowed system-wide. `EditorView`'s local key monitor
    /// matches the recorded shortcut itself, so it only fires in an editor
    /// window and only when no text field has focus.
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

#if !APPSTORE
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
