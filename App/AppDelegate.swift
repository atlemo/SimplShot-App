import AppKit
import KeyboardShortcuts

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    let appSettings = AppSettings()
    private var menuBuilder: MenuBuilder!
    private let windowManager = WindowManager()
    private let screenshotService = ScreenshotService()
    private let runningAppsService = RunningAppsService()
    private var batchCaptureService: BatchCaptureService!
    private let hotkeyService = HotkeyService()
    private let menuState = MenuState()

    /// Closure provided by SwiftUI to open the Settings scene properly.
    var openSettingsAction: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Check accessibility permission
        AccessibilityService.promptIfNeeded()

        // Pre-flight screen recording permission (triggers system prompt if not granted)
        ScreenshotService.ensurePermission()

        // Set up batch capture service
        batchCaptureService = BatchCaptureService(
            windowManager: windowManager,
            screenshotService: screenshotService
        )

        // Set up menu builder
        menuBuilder = MenuBuilder(
            menuState: menuState,
            appSettings: appSettings,
            runningAppsService: runningAppsService,
            windowManager: windowManager,
            screenshotService: screenshotService,
            batchCaptureService: batchCaptureService
        )
        menuBuilder.onOpenSettings = { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            if let action = self?.openSettingsAction {
                action()
            }
            // Ensure the Settings window comes to front
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                for window in NSApp.windows where window.title.contains("Settings") || window.identifier?.rawValue.contains("settings") == true {
                    window.makeKeyAndOrderFront(nil)
                    window.orderFrontRegardless()
                }
            }
        }

        // Set up status item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = NSImage(named: "StatusBarIcon")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "SimplShot"
        }
        statusItem.menu = menuBuilder.menu
        menuBuilder.statusItem = statusItem

        // Register global hotkeys
        hotkeyService.register(
            onResizeAndCapture: { [weak self] in
                self?.menuBuilder.resizeAndCaptureAction()
            },
            onBatchCapture: { [weak self] in
                self?.menuBuilder.batchCaptureAction()
            },
            onFreeSizeCapture: { [weak self] in
                self?.menuBuilder.freeSizeCaptureAction()
            }
        )
    }
}
