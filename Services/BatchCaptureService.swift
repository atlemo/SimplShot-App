import Foundation
import ApplicationServices

enum BatchCaptureError: LocalizedError {
    case cannotReadWindow
    case noWindowID
    case noWindows

    var errorDescription: String? {
        switch self {
        case .cannotReadWindow: return "Cannot read window state"
        case .noWindowID: return "Cannot get window ID for screenshot"
        case .noWindows: return "No windows found for the application"
        }
    }
}

class BatchCaptureService {
    let windowManager: WindowManager
    let screenshotService: ScreenshotService

    init(windowManager: WindowManager, screenshotService: ScreenshotService) {
        self.windowManager = windowManager
        self.screenshotService = screenshotService
    }

    /// Batch-capture ALL windows of an app across ALL width presets.
    /// For each preset, every window is resized, focused, and captured.
    func batchCapture(
        windows: [AXUIElement],
        appName: String,
        presets: [WidthPreset],
        aspectRatio: AspectRatio,
        format: ScreenshotFormat,
        saveURL: URL,
        template: ScreenshotTemplate? = nil
    ) async throws -> [URL] {
        guard !windows.isEmpty else {
            throw BatchCaptureError.noWindows
        }

        // Store original state for each window so we can restore later
        var originalStates: [(AXUIElement, WindowManager.WindowState)] = []
        for window in windows {
            if let state = windowManager.getWindowState(window) {
                originalStates.append((window, state))
            }
        }

        var capturedFiles: [URL] = []
        let multipleWindows = windows.count > 1

        for preset in presets {
            let height = aspectRatio.height(forWidth: preset.width)
            let targetSize = CGSize(width: CGFloat(preset.width), height: CGFloat(height))

            // Resize and center all windows to this preset
            for window in windows {
                _ = windowManager.resize(window, to: targetSize)
                windowManager.centerOnScreen(window)
            }

            // Wait for resize to settle
            try await Task.sleep(for: .milliseconds(300))

            // Now focus and capture each window individually
            for (index, window) in windows.enumerated() {
                guard let windowID = await windowManager.windowIDWithRetry(for: window) else {
                    continue
                }

                // Focus this window so it has an active title bar
                await MainActor.run {
                    windowManager.focusWindow(window)
                }
                try await Task.sleep(for: .milliseconds(300))

                let url = try await screenshotService.capture(
                    windowID: windowID,
                    appName: appName,
                    width: preset.width,
                    height: height,
                    format: format,
                    saveURL: saveURL,
                    windowIndex: multipleWindows ? index : nil,
                    template: template
                )
                capturedFiles.append(url)
            }
        }

        // Restore original states
        for (window, state) in originalStates {
            _ = windowManager.restore(window, to: state)
        }

        return capturedFiles
    }
}
