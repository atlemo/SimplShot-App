#if !APPSTORE
import AppKit
import ApplicationServices

class WindowManager {

    struct WindowState {
        let position: CGPoint
        let size: CGSize
    }

    // MARK: - Get window info

    func frontmostWindow(of app: AppTarget) -> AXUIElement? {
        var value: AnyObject?

        // Try focused window first
        let focusedResult = AXUIElementCopyAttributeValue(
            app.axApplication,
            kAXFocusedWindowAttribute as CFString,
            &value
        )
        if focusedResult == .success {
            return (value as! AXUIElement)
        }

        // Fall back to first window in list
        let windowsResult = AXUIElementCopyAttributeValue(
            app.axApplication,
            kAXWindowsAttribute as CFString,
            &value
        )
        if windowsResult == .success, let windows = value as? [AXUIElement], let first = windows.first {
            return first
        }

        return nil
    }

    func allWindows(of app: AppTarget) -> [AXUIElement] {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            app.axApplication,
            kAXWindowsAttribute as CFString,
            &value
        )
        guard result == .success, let windows = value as? [AXUIElement] else {
            return []
        }
        return windows
    }

    func getWindowState(_ window: AXUIElement) -> WindowState? {
        guard let position = getPosition(of: window),
              let size = getSize(of: window) else { return nil }
        return WindowState(position: position, size: size)
    }

    // MARK: - Resize

    func resize(_ window: AXUIElement, to targetSize: CGSize) -> Bool {
        guard let currentState = getWindowState(window) else { return false }

        // Set size first
        _ = setSize(of: window, to: targetSize)

        // Find which screen the window is on
        let windowRect = CGRect(origin: currentState.position, size: targetSize)
        let screen = NSScreen.screenContaining(axRect: windowRect) ?? NSScreen.main!
        let screenFrame = screen.frameInAXCoordinates

        // Nudge position to keep window on screen
        let nudgedOrigin = nudgeOntoScreen(
            windowOrigin: currentState.position,
            windowSize: targetSize,
            screenFrame: screenFrame
        )
        _ = setPosition(of: window, to: nudgedOrigin)

        // Set size again (macOS sometimes constrains on first attempt)
        _ = setSize(of: window, to: targetSize)

        return true
    }

    /// Centers a window on the screen it currently occupies.
    func centerOnScreen(_ window: AXUIElement) {
        guard let state = getWindowState(window) else { return }
        let windowRect = CGRect(origin: state.position, size: state.size)
        let screen = NSScreen.screenContaining(axRect: windowRect) ?? NSScreen.main!
        let screenFrame = screen.frameInAXCoordinates

        let centeredOrigin = CGPoint(
            x: screenFrame.midX - state.size.width / 2,
            y: screenFrame.midY - state.size.height / 2
        )
        _ = setPosition(of: window, to: centeredOrigin)
    }

    func restore(_ window: AXUIElement, to state: WindowState) -> Bool {
        let posOk = setPosition(of: window, to: state.position)
        let sizeOk = setSize(of: window, to: state.size)
        return posOk && sizeOk
    }

    // MARK: - Focus

    /// Raises a window and makes it the main/focused window so it renders
    /// with an active (non-dimmed) title bar.
    func focusWindow(_ window: AXUIElement) {
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    // MARK: - CGWindowID

    /// Returns the CGWindowID for an AX window element by cross-referencing
    /// the window's PID and on-screen bounds against the public CGWindowList API.
    /// Retrying is handled by the async `windowIDWithRetry(for:)` wrapper.
    func windowID(for window: AXUIElement) -> CGWindowID? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success,
              let position = getPosition(of: window),
              let size = getSize(of: window) else { return nil }
        return Self.cgWindowID(pid: pid, position: position, size: size)
    }

    /// Looks up a CGWindowID by matching PID and bounds in the CGWindowList.
    /// Uses a 2-point tolerance to accommodate float/int rounding between AX
    /// coordinates and the integer-pixel CGWindowList bounds.
    private static func cgWindowID(pid: pid_t, position: CGPoint, size: CGSize) -> CGWindowID? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[CFString: AnyObject]] else { return nil }

        for entry in list {
            guard let entryPID = entry[kCGWindowOwnerPID] as? pid_t, entryPID == pid,
                  let boundsRef = entry[kCGWindowBounds] as CFTypeRef?,
                  let wid = entry[kCGWindowNumber] as? CGWindowID, wid != 0
            else { continue }

            var bounds = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(boundsRef as! CFDictionary, &bounds) else { continue }

            if abs(bounds.origin.x - position.x) <= 2 &&
               abs(bounds.origin.y - position.y) <= 2 &&
               abs(bounds.size.width - size.width) <= 2 &&
               abs(bounds.size.height - size.height) <= 2 {
                return wid
            }
        }
        return nil
    }

    /// Async variant that retries up to `maxAttempts` times with a short sleep
    /// between each try.  Use this from async capture tasks instead of the
    /// synchronous version to avoid the "could not get ID" error after resize.
    func windowIDWithRetry(
        for window: AXUIElement,
        maxAttempts: Int = 5,
        delayMs: UInt64 = 80
    ) async -> CGWindowID? {
        for _ in 0 ..< maxAttempts {
            if let wid = windowID(for: window) { return wid }
            try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
        }
        return nil
    }

    // MARK: - Window filtering

    /// Returns only capturable windows — filters out:
    ///  • Sheets, drawers, and panels (non-standard subrole)
    ///  • Finder's persistent desktop window and other pseudo-windows
    ///    that report a standard subrole but have no valid CGWindowID
    ///  • Minimised windows (ScreenCaptureKit can't capture them)
    func standardWindows(of app: AppTarget) -> [AXUIElement] {
        allWindows(of: app).filter { isCapturableWindow($0) }
    }

    private func isCapturableWindow(_ window: AXUIElement) -> Bool {
        // 1. Must have standard window subrole (rules out sheets, drawers, panels)
        var value: AnyObject?
        if AXUIElementCopyAttributeValue(
            window,
            kAXSubroleAttribute as CFString,
            &value
        ) == .success, let subrole = value as? String {
            guard subrole == kAXStandardWindowSubrole as String else { return false }
        }
        // If subrole can't be read at all, continue — don't reject on that alone.

        // 2. Must not be minimised (minimised windows have no on-screen framebuffer)
        var minimisedValue: AnyObject?
        if AXUIElementCopyAttributeValue(
            window,
            kAXMinimizedAttribute as CFString,
            &minimisedValue
        ) == .success, let isMinimised = minimisedValue as? Bool, isMinimised {
            return false
        }

        // 3. Must have a valid CGWindowID right now.
        //    Finder's desktop window (and similar pseudo-windows in other apps)
        //    passes the subrole check but never appears in CGWindowList with
        //    excludeDesktopElements, so this gate naturally rejects them.
        //    If we can't match a window ID here, ScreenCaptureKit can't capture it.
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success,
              let position = getPosition(of: window),
              let size = getSize(of: window),
              Self.cgWindowID(pid: pid, position: position, size: size) != nil else {
            return false
        }

        return true
    }

    // MARK: - Private AX helpers

    private func getPosition(of element: AXUIElement) -> CGPoint? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value) == .success else {
            return nil
        }
        var point = CGPoint.zero
        AXValueGetValue(value as! AXValue, .cgPoint, &point)
        return point
    }

    private func setPosition(of element: AXUIElement, to point: CGPoint) -> Bool {
        var mutablePoint = point
        guard let value = AXValueCreate(.cgPoint, &mutablePoint) else { return false }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) == .success
    }

    private func getSize(of element: AXUIElement) -> CGSize? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value) == .success else {
            return nil
        }
        var size = CGSize.zero
        AXValueGetValue(value as! AXValue, .cgSize, &size)
        return size
    }

    private func setSize(of element: AXUIElement, to size: CGSize) -> Bool {
        var mutableSize = size
        guard let value = AXValueCreate(.cgSize, &mutableSize) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value) == .success
    }
}
#endif

