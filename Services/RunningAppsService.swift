import AppKit
import ApplicationServices

class RunningAppsService {

    /// Returns all regular-activation-policy apps that currently have at least
    /// one on-screen window according to the CGWindow API. This avoids the
    /// flaky Accessibility API for discovery (AX can time-out or fail
    /// intermittently) while still providing the AXUIElement reference needed
    /// for resize operations later.
    func applicationsWithWindows() -> [AppTarget] {
        // Get the set of PIDs that own at least one on-screen window via the
        // fast, permission-free CGWindowList API.
        let pidsWithWindows = windowOwnerPIDs()

        let runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated }

        return runningApps.compactMap { app -> AppTarget? in
            guard pidsWithWindows.contains(app.processIdentifier) else { return nil }

            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            return AppTarget(
                id: app.processIdentifier,
                name: app.localizedName ?? "Unknown",
                bundleIdentifier: app.bundleIdentifier,
                icon: app.icon,
                axApplication: axApp
            )
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Private

    /// Uses the CGWindowList API (no Accessibility permission required) to find
    /// which PIDs currently own at least one on-screen, normal-level window.
    private func windowOwnerPIDs() -> Set<pid_t> {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[CFString: Any]] else {
            return []
        }

        var pids = Set<pid_t>()
        for entry in windowList {
            // Only count normal-level windows (skip menu bar, dock, overlays)
            if let layer = entry[kCGWindowLayer] as? Int, layer == 0,
               let pid = entry[kCGWindowOwnerPID] as? pid_t {
                pids.insert(pid)
            }
        }
        return pids
    }
}
