import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let resizeAndCapture = Self("resizeAndCapture")
    static let batchCapture = Self("batchCapture")
    static let freeSizeCapture = Self("freeSizeCapture")
}

class HotkeyService {
    private var onResizeAndCapture: (() -> Void)?
    private var onBatchCapture: (() -> Void)?
    private var onFreeSizeCapture: (() -> Void)?

    init() {}

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
}
