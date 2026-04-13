import KeyboardShortcuts

extension KeyboardShortcuts.Name {
#if !APPSTORE
    static let resizeAndCapture = Self("resizeAndCapture")
    static let batchCapture = Self("batchCapture")
#endif
    static let freeSizeCapture = Self("freeSizeCapture")
    static let captureTextOCR = Self("captureTextOCR")
    static let colorPicker = Self("colorPicker")
    static let openScreenshotsFolder = Self("openScreenshotsFolder")
}

class HotkeyService {
#if !APPSTORE
    private var onResizeAndCapture: (() -> Void)?
    private var onBatchCapture: (() -> Void)?
#endif
    private var onFreeSizeCapture: (() -> Void)?
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
        onCaptureTextOCR: @escaping () -> Void,
        onColorPicker: @escaping () -> Void,
        onOpenScreenshotsFolder: @escaping () -> Void
    ) {
        self.onFreeSizeCapture = onFreeSizeCapture
        self.onCaptureTextOCR = onCaptureTextOCR
        self.onColorPicker = onColorPicker
        self.onOpenScreenshotsFolder = onOpenScreenshotsFolder

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
#endif
}
