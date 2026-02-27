#if !APPSTORE
import AppKit
import ApplicationServices

struct AppTarget: Identifiable {
    let id: pid_t
    let name: String
    let bundleIdentifier: String?
    let icon: NSImage?
    let axApplication: AXUIElement

    /// Brings all of the app's windows to the front.
    func activate() {
        if let runningApp = NSRunningApplication(processIdentifier: id) {
            runningApp.activate()
        }
    }
}
#endif
