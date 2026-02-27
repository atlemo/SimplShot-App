import KeyboardShortcuts

extension KeyboardShortcuts.Name {
#if !APPSTORE
    static let resizeAndCapture = Self("resizeAndCapture")
    static let batchCapture = Self("batchCapture")
#endif
    static let freeSizeCapture = Self("freeSizeCapture")
}

class HotkeyService {
#if !APPSTORE
    private var onResizeAndCapture: (() -> Void)?
    private var onBatchCapture: (() -> Void)?
#endif
    private var onFreeSizeCapture: (() -> Void)?

    init() {}

#if !APPSTORE
    func register(
        onResizeAndCapture: @escaping () -> Void,
        onBatchCapture: @escaping () -> Void,
        onFreeSizeCapture: @escaping () -> Void
    ) {
        self.onResizeAndCapture = onResizeAndCapture
        self.onBatchCapture = onBatchCapture
        self.onFreeSizeCapture = onFreeSizeCapture

        KeyboardShortcuts.onKeyDown(for: .resizeAndCapture) { [weak self] in
            self?.onResizeAndCapture?()
        }
        KeyboardShortcuts.onKeyDown(for: .batchCapture) { [weak self] in
            self?.onBatchCapture?()
        }
        KeyboardShortcuts.onKeyDown(for: .freeSizeCapture) { [weak self] in
            self?.onFreeSizeCapture?()
        }
    }
#else
    func register(
        onFreeSizeCapture: @escaping () -> Void
    ) {
        self.onFreeSizeCapture = onFreeSizeCapture

        KeyboardShortcuts.onKeyDown(for: .freeSizeCapture) { [weak self] in
            self?.onFreeSizeCapture?()
        }
    }
#endif
}
