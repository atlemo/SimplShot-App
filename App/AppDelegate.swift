import AppKit
import CoreSpotlight
import KeyboardShortcuts
#if !APPSTORE
import Sparkle
import TelemetryDeck
#endif
import SwiftUI
@preconcurrency import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    let appSettings = AppSettings()
    private var menuBuilder: MenuBuilder!
    private let screenshotService = ScreenshotService()
#if !APPSTORE
    private let windowManager = WindowManager()
    private let runningAppsService = RunningAppsService()
    private var batchCaptureService: BatchCaptureService!
#endif
    private let hotkeyService = HotkeyService()
    private let menuState = MenuState()
    private var colorPickerService: ColorPickerService?
    private var onboardingWindowController: PermissionOnboardingWindowController?
#if !APPSTORE
    private var updaterController: SPUStandardUpdaterController?
#endif

    /// Closure provided by SwiftUI to open the Settings scene properly.
    var openSettingsAction: (() -> Void)?

    @MainActor
    func openFile() {
        menuBuilder.openFileAction()
    }

    @MainActor
    func openScreenshotsFolder() {
        menuBuilder.openScreenshotsFolderAction()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let imageTypes: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "tif", "gif", "bmp", "webp"]
        let imageURLs = urls.filter { imageTypes.contains($0.pathExtension.lowercased()) }
        let pdfURLs = urls.filter { $0.pathExtension.lowercased() == "pdf" }

        if !imageURLs.isEmpty {
            let initialMode = appSettings.defaultEditorModeOnOpen.resolve(
                lastUsed: appSettings.lastUsedEditorMode
            )
            EditorWindowController.openEditor(
                imageURLs: imageURLs,
                appSettings: appSettings,
                initialMode: initialMode
            )
        }

        for pdfURL in pdfURLs {
            let sessions = PDFService.loadPages(from: pdfURL)
            guard !sessions.isEmpty else { continue }
            EditorWindowController.openEditor(sessions: sessions, appSettings: appSettings)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
#if !APPSTORE
        // Set up batch capture service
        batchCaptureService = BatchCaptureService(
            windowManager: windowManager,
            screenshotService: screenshotService
        )

        // Analytics
        let telemetryConfig = TelemetryDeck.Config(appID: "2ED195C4-F469-4588-B647-97B5A5A36CB2")
        TelemetryDeck.initialize(config: telemetryConfig)
#endif

        // Set up menu builder
#if !APPSTORE
        menuBuilder = MenuBuilder(
            menuState: menuState,
            appSettings: appSettings,
            screenshotService: screenshotService,
            runningAppsService: runningAppsService,
            windowManager: windowManager,
            batchCaptureService: batchCaptureService
        )
#else
        menuBuilder = MenuBuilder(
            menuState: menuState,
            appSettings: appSettings,
            screenshotService: screenshotService
        )
#endif
        colorPickerService = ColorPickerService()
        menuBuilder.onColorPicker = { [weak self] in
            self?.colorPickerService?.startPicking()
        }
        menuBuilder.onOpenSettings = { [weak self] in
            NSApp.setActivationPolicy(.regular)
            if let action = self?.openSettingsAction {
                action()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NSApp.activate(ignoringOtherApps: true)
                for window in NSApp.windows where window.title.contains("Settings") || window.identifier?.rawValue.contains("settings") == true {
                    window.makeKeyAndOrderFront(nil)
                    window.orderFrontRegardless()
                }
            }
        }

        // Set up status item.
        // We use statusItem.view (deprecated API) intentionally: adding a drag-destination
        // subview to NSStatusBarButton causes "Reentrant message: kDragIPCCompleted,
        // current message: kDragIPCLeaveApplication" errors because the drag system treats
        // the status-bar window as outside the app boundary. statusItem.view bypasses that
        // IPC mechanism entirely and is the only reliable way to accept file drops here.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let thickness = NSStatusBar.system.thickness
        let dragView = StatusItemDragView(
            frame: NSRect(x: 0, y: 0, width: thickness, height: thickness)
        )
        dragView.toolTip = "SimplShot"
        dragView.onFilesDropped = { [weak self] urls in
            self?.application(NSApp, open: urls)
        }
        // Suppress "deprecated" warning: intentional, see comment above.
        statusItem.perform(NSSelectorFromString("setView:"), with: dragView)
        dragView.statusItem = statusItem      // needed for menu open on click
        statusItem.menu = menuBuilder.menu
        menuBuilder.statusItem = statusItem

        // Register global hotkeys
#if !APPSTORE
        hotkeyService.register(
            onResizeAndCapture: { [weak self] in
                self?.menuBuilder.resizeAndCaptureAction()
            },
            onBatchCapture: { [weak self] in
                self?.menuBuilder.batchCaptureAction()
            },
            onFreeSizeCapture: { [weak self] in
                self?.menuBuilder.freeSizeCaptureAction()
            },
            onCaptureTextOCR: { [weak self] in
                self?.menuBuilder.captureTextOCRAction()
            },
            onColorPicker: { [weak self] in
                self?.menuBuilder.openColorPickerAction()
            },
            onOpenScreenshotsFolder: { [weak self] in
                self?.menuBuilder.openScreenshotsFolderAction()
            }
        )
#else
        hotkeyService.register(
            onFreeSizeCapture: { [weak self] in
                self?.menuBuilder.freeSizeCaptureAction()
            },
            onCaptureWindow: { [weak self] in
                self?.menuBuilder.captureWindowAction()
            },
            onCaptureTextOCR: { [weak self] in
                self?.menuBuilder.captureTextOCRAction()
            },
            onColorPicker: { [weak self] in
                self?.menuBuilder.openColorPickerAction()
            },
            onOpenScreenshotsFolder: { [weak self] in
                self?.menuBuilder.openScreenshotsFolderAction()
            }
        )
#endif

#if !APPSTORE
        setupUpdaterIfPossible()
        if updaterController != nil {
            menuBuilder.onCheckForUpdates = { [weak self] in
                self?.checkForUpdates()
            }
        }
#endif
        // Register the app in System Settings → Screen Recording and check initial state.
        ScreenRecordingPermissionManager.shared.requestPermission()
        showPermissionOnboardingIfNeeded()

#if APPSTORE
        promptForSaveFolderIfNeeded()
#endif

        // Handle notification clicks to open the editor
        UNUserNotificationCenter.current().delegate = self

        donateSpotlightItem()
        cleanupStrandedTempFiles()
    }

    /// Removes stranded safe-save temp files (`.sb-XXXXXXXX-XXXXXX` suffix) that
    /// `CGImageDestinationFinalize` leaves behind when the app crashes mid-write.
    private func cleanupStrandedTempFiles() {
        let saveDir = appSettings.screenshotSaveURL
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: saveDir, includingPropertiesForKeys: nil
        ) else { return }
        for url in items where url.lastPathComponent.contains(".sb-") {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func donateSpotlightItem() {
        let attrs = CSSearchableItemAttributeSet(contentType: .application)
        attrs.title = "SimplShot"
        attrs.contentDescription = "Screenshot tool and editor for macOS"
        attrs.keywords = [
            "screenshot", "screen", "capture", "screen capture",
            "screen recording", "annotation", "editor", "image editor"
        ]
        let item = CSSearchableItem(
            uniqueIdentifier: "com.simplshot.app.spotlight",
            domainIdentifier: "app",
            attributeSet: attrs
        )
        CSSearchableIndex.default().indexSearchableItems([item]) { _ in }
    }

#if !APPSTORE
    private func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }
#endif

#if APPSTORE
    private func promptForSaveFolderIfNeeded() {
        guard appSettings.needsSaveFolderSelection else { return }
        // Delay slightly so the status bar item and onboarding can appear first
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.appSettings.needsSaveFolderSelection else { return }
            if let url = AppSettings.promptForSaveFolder() {
                self.appSettings.screenshotSaveURL = url
            }
        }
    }
#endif

    private func showPermissionOnboardingIfNeeded() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let manager = ScreenRecordingPermissionManager.shared
            let state = await manager.checkPermission()

            switch state {
            case .granted:
                return
            case .grantedStale:
                showRestartRequiredDialog()
#if !APPSTORE
            case .denied, .notDetermined, .unknown:
                if !AccessibilityService.isTrusted || state != .granted {
                    showPermissionOnboardingWindow()
                }
#else
            case .denied, .notDetermined, .unknown:
                showPermissionOnboardingWindow()
#endif
            }
        }
    }

    private func showRestartRequiredDialog() {
        guard onboardingWindowController == nil else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Restart Required"
        alert.informativeText = "Screen Recording permission was recently changed. SimplShot needs to restart for it to take effect."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Restart Now")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            MenuBuilder.relaunchApp()
        }
    }

    private func showPermissionOnboardingWindow() {
        guard onboardingWindowController == nil else { return }
        let controller = PermissionOnboardingWindowController { [weak self] in
            self?.onboardingWindowController = nil
        }
        onboardingWindowController = controller
        controller.showWindow(nil)
    }

#if !APPSTORE
    private func setupUpdaterIfPossible() {
        guard updaterController == nil else { return }

        // Sparkle requires a valid appcast feed URL and ed25519 public key in Info.plist.
        guard
            let feedURL = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            !feedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
            !publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return
        }

        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }
#endif
}

// MARK: - Notification Click → Open Editor

extension AppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let path = response.notification.request.content.userInfo["imageURL"] as? String {
            let url = URL(fileURLWithPath: path)
            EditorWindowController.openEditor(imageURL: url, appSettings: appSettings)
        }
        completionHandler()
    }
}

private final class PermissionOnboardingWindowController: NSWindowController {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Set Up SimplShot"
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)

        let root = PermissionOnboardingView {
            self.close()
        }
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        window.contentView = hosting
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    override func close() {
        super.close()
        if NSApp.windows.isEmpty {
            NSApp.setActivationPolicy(.accessory)
        }
        onClose()
    }
}

private struct PermissionOnboardingView: View {
    var onDone: () -> Void

    @StateObject private var permissionManager = ScreenRecordingPermissionManager.shared
#if !APPSTORE
    @State private var hasAccessibility = AccessibilityService.isTrusted
#endif

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Permissions Setup")
                .font(.title2.weight(.semibold))

            Text("SimplShot needs a macOS permission to capture screenshots. Granting it now avoids failed captures later.")
                .foregroundStyle(.secondary)

#if !APPSTORE
            permissionCard(
                title: "Accessibility",
                granted: hasAccessibility,
                description: "Needed to resize and focus app windows for consistent captures.",
                primaryActionTitle: "Grant Accessibility"
            ) {
                AccessibilityService.promptIfNeeded()
                refreshSoon()
            } secondaryAction: {
                AccessibilityService.openAccessibilitySettings()
            }
#endif

            screenRecordingCard

            Spacer()

            HStack {
                Button("Refresh Status", action: refreshStatus)
                Spacer()
#if !APPSTORE
                let allGranted = hasAccessibility && permissionManager.state == .granted
                Button(allGranted ? "Done" : "Continue Later", action: onDone)
                    .keyboardShortcut(.defaultAction)
#else
                Button(permissionManager.state == .granted ? "Done" : "Continue Later", action: onDone)
                    .keyboardShortcut(.defaultAction)
#endif
            }
        }
        .padding(20)
        .onAppear(perform: refreshStatus)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshStatus()
        }
    }

    @ViewBuilder
    private var screenRecordingCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Screen Recording")
                    .font(.headline)
                Spacer()
                switch permissionManager.state {
                case .granted:
                    Text("Granted")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                case .grantedStale:
                    Text("Restart Required")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.blue)
                default:
                    Text("Missing")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }
            }
            Text("Needed to capture screenshots.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack {
                switch permissionManager.state {
                case .granted:
                    Text("Ready")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.green)
                case .grantedStale:
                    Button("Restart Now") { MenuBuilder.relaunchApp() }
                    Button("Open Settings") { permissionManager.openSettings() }
                case .notDetermined:
                    Button("Enable Screen Recording") {
                        permissionManager.requestPermission()
                        refreshSoon()
                    }
                    Button("Open Settings") { permissionManager.openSettings() }
                case .denied, .unknown:
                    Text("Toggle the switch for SimplShot in System Settings.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("Open Settings") { permissionManager.openSettings() }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

#if !APPSTORE
    private func permissionCard(
        title: String,
        granted: Bool,
        description: String,
        primaryActionTitle: String,
        primaryAction: @escaping () -> Void,
        secondaryAction: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Text(granted ? "Granted" : "Missing")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(granted ? .green : .orange)
            }
            Text(description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack {
                if !granted {
                    Button(primaryActionTitle, action: primaryAction)
                    Button("Open Settings", action: secondaryAction)
                } else {
                    Text("Ready")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.green)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
#endif

    private func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            refreshStatus()
        }
    }

    private func refreshStatus() {
#if !APPSTORE
        hasAccessibility = AccessibilityService.isTrusted
#endif
        Task {
            await permissionManager.checkPermission()
        }
    }
}

// MARK: - Status Item Drag View

/// Full replacement view for the status-bar item.
///
/// WHY statusItem.view (deprecated) instead of a button subview:
/// Registering a drag destination on a subview of NSStatusBarButton causes
/// "Reentrant message: kDragIPCCompleted, current message: kDragIPCLeaveApplication"
/// console errors and a broken drop. The macOS drag system treats the status-bar
/// window as outside the app boundary; when a drag enters it, kDragIPCLeaveApplication
/// fires for our app while the subview simultaneously tries to receive the drag —
/// producing the reentrancy. statusItem.view owns the entire view and bypasses
/// that IPC mechanism, so drags work correctly.
///
/// Note: statusItem.button is nil when statusItem.view is set.
/// MenuBuilder.reopenMenu() guards on button != nil and returns early,
/// so the menu closes after selection rather than staying open. Acceptable trade-off.
private final class StatusItemDragView: NSView {
    var onFilesDropped: (([URL]) -> Void)?
    weak var statusItem: NSStatusItem?

    private let validExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "tiff", "tif", "gif", "bmp", "webp", "pdf"
    ]
    private var isHighlighted = false

    // Spring-loading: because performDragOperation is never called (kDragIPC reentrancy),
    // we read URLs in draggingEntered and open them after a short hover delay instead.
    private var springLoadTimer: Timer?
    private var pendingURLs: [URL] = []

    private let imageView: NSImageView = {
        let iv = NSImageView()
        let img = NSImage(named: "StatusBarIcon")
        img?.isTemplate = true
        iv.image = img
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.unregisterDraggedTypes()          // prevent the image view absorbing drags
        return iv
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])

        let iconSize: CGFloat = 16
        imageView.frame = NSRect(
            x: (frame.width  - iconSize) / 2,
            y: (frame.height - iconSize) / 2,
            width: iconSize, height: iconSize
        )
        imageView.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        addSubview(imageView)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isHighlighted else { return }
        NSColor.selectedContentBackgroundColor.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4).fill()
    }

    // MARK: - Click → open menu

    override func mouseDown(with event: NSEvent) {
        guard let menu = statusItem?.menu else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    // MARK: - NSDraggingDestination

    private func canAccept(_ info: NSDraggingInfo) -> Bool {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = info.draggingPasteboard
            .readObjects(forClasses: [NSURL.self], options: opts) as? [URL] else { return false }
        return urls.contains { validExtensions.contains($0.pathExtension.lowercased()) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard canAccept(sender) else { return [] }

        // Read URLs now — draggingEntered IS called, but performDragOperation never fires
        // due to the kDragIPC reentrancy bug in the macOS status-bar drag system.
        // Spring-loading: open the files after the user hovers for ~0.7 s.
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let all = sender.draggingPasteboard
            .readObjects(forClasses: [NSURL.self], options: opts) as? [URL] ?? []
        pendingURLs = all.filter { validExtensions.contains($0.pathExtension.lowercased()) }

        if !pendingURLs.isEmpty {
            springLoadTimer?.invalidate()
            springLoadTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.onFilesDropped?(self.pendingURLs)
                self.cancelSpringLoad()
            }
        }

        isHighlighted = true
        needsDisplay = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        // kDragIPC reentrancy means a real drop arrives here as a "exited" event
        // instead of performDragOperation/draggingEnded. Distinguish drop from
        // leave by checking whether the mouse button is still pressed:
        //   - button released → user dropped over our icon → open immediately
        //   - button still pressed → user moved away → cancel
        let mouseReleased = NSEvent.pressedMouseButtons == 0
        if mouseReleased && !pendingURLs.isEmpty {
            onFilesDropped?(pendingURLs)
        }
        cancelSpringLoad()
        isHighlighted = false
        needsDisplay = true
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        // Forward-compatible: if a future macOS routes drops here, open immediately.
        if !pendingURLs.isEmpty {
            onFilesDropped?(pendingURLs)
        }
        cancelSpringLoad()
        isHighlighted = false
        needsDisplay = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        // Fast path: called only if kDragIPC reentrancy is ever resolved in a future OS.
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = sender.draggingPasteboard
            .readObjects(forClasses: [NSURL.self], options: opts) as? [URL] else { return false }
        let valid = urls.filter { validExtensions.contains($0.pathExtension.lowercased()) }
        guard !valid.isEmpty else { return false }
        onFilesDropped?(valid)
        cancelSpringLoad()
        return true
    }

    private func cancelSpringLoad() {
        springLoadTimer?.invalidate()
        springLoadTimer = nil
        pendingURLs = []
    }
}
