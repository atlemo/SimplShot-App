import AppKit
import KeyboardShortcuts
#if !APPSTORE
import Sparkle
#endif
import SwiftUI

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
    private var onboardingWindowController: PermissionOnboardingWindowController?
#if !APPSTORE
    private var updaterController: SPUStandardUpdaterController?
#endif

    /// Closure provided by SwiftUI to open the Settings scene properly.
    var openSettingsAction: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
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

        #if !APPSTORE
            setupUpdaterIfPossible()
            if updaterController != nil {
                menuBuilder.onCheckForUpdates = { [weak self] in
                    self?.checkForUpdates()
                }
            }
        #endif
        // Always run the SCK registration query so this app stays visible in
        // System Settings → Screen Recording, even after a rebuild resets the entry.
        ScreenshotService.ensurePermission()
        showPermissionOnboardingIfNeeded()
    }

    #if !APPSTORE
    private func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }
    #endif

    private func showPermissionOnboardingIfNeeded() {
        let missingPermissions = !AccessibilityService.isTrusted || !AccessibilityService.hasScreenRecordingPermission
        #if DEBUG
        // In debug builds always show the onboarding when a permission is missing,
        // so the developer doesn't get stuck after a bundle-ID change or TCC reset.
        guard missingPermissions else { return }
        #else
        let hasShown = UserDefaults.standard.bool(forKey: Constants.UserDefaultsKeys.hasShownPermissionOnboarding)
        guard !hasShown, missingPermissions else { return }
        UserDefaults.standard.set(true, forKey: Constants.UserDefaultsKeys.hasShownPermissionOnboarding)
        #endif

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

    @State private var hasAccessibility = AccessibilityService.isTrusted
    @State private var hasScreenRecording = AccessibilityService.hasScreenRecordingPermission
    @State private var screenRecordingRequestedOnce = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Permissions Setup")
                .font(.title2.weight(.semibold))

            Text("SimplShot needs a couple of macOS permissions. Granting them now avoids failed captures later.")
                .foregroundStyle(.secondary)

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

            screenRecordingCard

            Spacer()

            HStack {
                Button("Refresh Status", action: refreshStatus)
                Spacer()
                Button(hasAccessibility && hasScreenRecording ? "Done" : "Continue Later", action: onDone)
                    .keyboardShortcut(.defaultAction)
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
        // After the user has gone through the grant flow, macOS only applies the
        // permission after a restart — show a clear nudge instead of leaving the
        // status stuck on "Missing".
        let awaitingRestart = screenRecordingRequestedOnce && !hasScreenRecording

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Screen Recording")
                    .font(.headline)
                Spacer()
                if awaitingRestart {
                    Text("Restart Required")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.blue)
                } else {
                    Text(hasScreenRecording ? "Granted" : "Missing")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(hasScreenRecording ? .green : .orange)
                }
            }
            Text("Needed to capture screenshots.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack {
                if hasScreenRecording {
                    Text("Ready")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.green)
                } else if awaitingRestart {
                    Button("Restart Now") { relaunch() }
                    Button("Open Settings") { AccessibilityService.openScreenRecordingSettings() }
                } else {
                    Button("Enable Screen Recording") {
                        ScreenshotService.ensurePermission()
                        screenRecordingRequestedOnce = true
                        refreshSoon()
                    }
                    Button("Open Settings") { AccessibilityService.openScreenRecordingSettings() }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private func relaunch() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
        NSApp.terminate(nil)
    }

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

    private func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            refreshStatus()
        }
    }

    private func refreshStatus() {
        hasAccessibility = AccessibilityService.isTrusted
        hasScreenRecording = AccessibilityService.hasScreenRecordingPermission
    }
}
