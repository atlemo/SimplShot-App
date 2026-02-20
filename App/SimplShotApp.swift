import SwiftUI

@main
struct SimplShotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.openSettings) private var openSettings

    var body: some Scene {
        let _ = installOpenSettings()
        Settings {
            SettingsView(appSettings: appDelegate.appSettings)
        }
    }

    /// Pass the SwiftUI `openSettings` environment action to the AppKit side
    /// so the NSMenu "Settings…" item can open the Settings scene properly.
    private func installOpenSettings() {
        appDelegate.openSettingsAction = { [openSettings] in
            openSettings()
        }
    }
}
