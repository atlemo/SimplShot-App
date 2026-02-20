import Foundation
import ApplicationServices

@Observable
class MenuState {
    var availableApps: [AppTarget] = []
    var selectedApp: AppTarget? {
        didSet {
            // Persist the selected app's bundle identifier
            UserDefaults.standard.set(
                selectedApp?.bundleIdentifier,
                forKey: Constants.UserDefaultsKeys.selectedAppBundleID
            )
        }
    }

    var canResize: Bool {
        selectedApp != nil
    }

    /// The bundle identifier of the last selected app (persisted across sessions).
    var lastSelectedBundleID: String? {
        UserDefaults.standard.string(forKey: Constants.UserDefaultsKeys.selectedAppBundleID)
    }
}
