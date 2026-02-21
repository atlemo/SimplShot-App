import AppKit
import ApplicationServices
import KeyboardShortcuts
import UniformTypeIdentifiers

@MainActor
class MenuBuilder: NSObject, NSMenuDelegate {
    let menu = NSMenu()
    let menuState: MenuState
    let appSettings: AppSettings
    let runningAppsService: RunningAppsService
    let windowManager: WindowManager
    let screenshotService: ScreenshotService
    let batchCaptureService: BatchCaptureService

    var onOpenSettings: (() -> Void)?

    /// Set by AppDelegate so the menu can re-show itself after selection changes.
    weak var statusItem: NSStatusItem?

    /// When true, `menuWillOpen` skips the app-list refresh (used during reopen).
    private var skipNextRefresh = false

    init(
        menuState: MenuState,
        appSettings: AppSettings,
        runningAppsService: RunningAppsService,
        windowManager: WindowManager,
        screenshotService: ScreenshotService,
        batchCaptureService: BatchCaptureService
    ) {
        self.menuState = menuState
        self.appSettings = appSettings
        self.runningAppsService = runningAppsService
        self.windowManager = windowManager
        self.screenshotService = screenshotService
        self.batchCaptureService = batchCaptureService
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        if skipNextRefresh {
            skipNextRefresh = false
            return
        }

        menuState.availableApps = runningAppsService.applicationsWithWindows()

        // If selected app is no longer running, clear selection
        if let selected = menuState.selectedApp,
           !menuState.availableApps.contains(where: { $0.id == selected.id }) {
            menuState.selectedApp = nil
        }

        // Restore last-used app if nothing is selected
        if menuState.selectedApp == nil,
           let lastBundleID = menuState.lastSelectedBundleID {
            menuState.selectedApp = menuState.availableApps.first {
                $0.bundleIdentifier == lastBundleID
            }
        }

        rebuildMenu()
    }

    // MARK: - Build menu

    func rebuildMenu() {
        menu.removeAllItems()

        // --- Application picker ---
        let appTitle = menuState.selectedApp?.name ?? "Select Application..."
        let appItem = NSMenuItem(title: appTitle, action: nil, keyEquivalent: "")
        if let icon = menuState.selectedApp?.icon {
            appItem.image = icon.resized(to: NSSize(width: 16, height: 16))
        }
        let appSubmenu = NSMenu()
        for app in menuState.availableApps {
            let item = NSMenuItem(title: app.name, action: #selector(selectApp(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = app.id  // store pid_t
            item.image = app.icon?.resized(to: NSSize(width: 16, height: 16))
            if app.id == menuState.selectedApp?.id {
                item.state = .on
            }
            appSubmenu.addItem(item)
        }
        if menuState.availableApps.isEmpty {
            let emptyItem = NSMenuItem(title: "No applications with windows", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            appSubmenu.addItem(emptyItem)
        }
        appItem.submenu = appSubmenu
        menu.addItem(appItem)

        menu.addItem(.separator())

        // --- Width presets ---
        let widthHeader = NSMenuItem(title: "Width", action: nil, keyEquivalent: "")
        widthHeader.isEnabled = false
        menu.addItem(widthHeader)

        for preset in appSettings.widthPresets {
            let hasCustomName = preset.label != "\(preset.width)px"
            let title = hasCustomName ? "\(preset.label) — \(preset.width)px" : preset.label
            let item = NSMenuItem(title: title, action: #selector(selectWidth(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preset.id  // store UUID
            item.indentationLevel = 1
            if preset.id == appSettings.selectedWidthID {
                item.state = .on
            }
            menu.addItem(item)
        }

        menu.addItem(.separator())

        // --- Aspect ratios ---
        let ratioHeader = NSMenuItem(title: "Aspect Ratio", action: nil, keyEquivalent: "")
        ratioHeader.isEnabled = false
        menu.addItem(ratioHeader)

        for ratio in appSettings.aspectRatios {
            let item = NSMenuItem(title: ratio.label, action: #selector(selectRatio(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ratio.id  // store UUID
            item.indentationLevel = 1
            if ratio.id == appSettings.selectedRatioID {
                item.state = .on
            }
            menu.addItem(item)
        }

        menu.addItem(.separator())

        // --- Dimensions display ---
        let dimText: String
        if let wp = appSettings.selectedWidthPreset, let ar = appSettings.selectedAspectRatio {
            let h = ar.height(forWidth: wp.width)
            dimText = "Dimensions: \(wp.width) × \(h)"
        } else {
            dimText = "Dimensions: —"
        }
        let dimItem = NSMenuItem(title: dimText, action: nil, keyEquivalent: "")
        dimItem.isEnabled = false
        menu.addItem(dimItem)

        menu.addItem(.separator())

        // --- Actions ---
        let canCapture = menuState.canResize && appSettings.selectedWidthPreset != nil && appSettings.selectedAspectRatio != nil

        let appName = menuState.selectedApp?.name
        let captureTitle = appName.map { "Capture \($0)" } ?? "Capture"
        let captureItem = NSMenuItem(title: captureTitle, action: #selector(resizeAndCaptureAction), keyEquivalent: "")
        captureItem.target = self
        captureItem.isEnabled = canCapture
        applyShortcut(.resizeAndCapture, to: captureItem)
        captureItem.image = NSImage(systemSymbolName: "camera", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        menu.addItem(captureItem)

        let batchTitle = appName.map { "Capture \($0) in All Sizes" } ?? "Capture All Widths"
        let batchItem = NSMenuItem(title: batchTitle, action: #selector(batchCaptureAction), keyEquivalent: "")
        batchItem.target = self
        batchItem.isEnabled = menuState.canResize && appSettings.selectedAspectRatio != nil
        applyShortcut(.batchCapture, to: batchItem)
        batchItem.image = NSImage(systemSymbolName: "camera.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        menu.addItem(batchItem)

        let freeSizeItem = NSMenuItem(title: "Capture Area", action: #selector(freeSizeCaptureAction), keyEquivalent: "")
        freeSizeItem.target = self
        freeSizeItem.isEnabled = true
        applyShortcut(.freeSizeCapture, to: freeSizeItem)
        freeSizeItem.image = NSImage(systemSymbolName: "camera.metering.center.weighted.average", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        menu.addItem(freeSizeItem)

        menu.addItem(.separator())

        // --- Open existing image ---
        let clipboardItem = NSMenuItem(title: "Open from Clipboard", action: #selector(openFromClipboardAction), keyEquivalent: "")
        clipboardItem.target = self
        clipboardItem.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        menu.addItem(clipboardItem)

        let openFileItem = NSMenuItem(title: "Open File…", action: #selector(openFileAction), keyEquivalent: "")
        openFileItem.target = self
        openFileItem.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        menu.addItem(openFileItem)

        menu.addItem(.separator())

        // --- Settings & Quit ---
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(title: "Quit SimplShot", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    // MARK: - Actions

    @objc private func selectApp(_ sender: NSMenuItem) {
        guard let pid = sender.representedObject as? pid_t else { return }
        menuState.selectedApp = menuState.availableApps.first { $0.id == pid }
        reopenMenu()
    }

    @objc private func selectWidth(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        appSettings.selectedWidthID = id
        autoResizeIfReady()
        reopenMenu()
    }

    @objc private func selectRatio(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        appSettings.selectedRatioID = id
        autoResizeIfReady()
        reopenMenu()
    }

    @objc func resizeAndCaptureAction() {
        guard ensureScreenRecordingPermission(for: "capture screenshots")
        else { return }

        guard let app = menuState.selectedApp else {
            showAlert("No application selected. Please select an application first.")
            return
        }
        guard let widthPreset = appSettings.selectedWidthPreset,
              let aspectRatio = appSettings.selectedAspectRatio else { return }

        // performResize already resizes all windows
        guard performResize() != nil else { return }

        // Bring the app to the front so windows are fully visible for capture
        app.activate()

        let allWindows = windowManager.standardWindows(of: app)
        let height = aspectRatio.height(forWidth: widthPreset.width)
        let appName = app.name

        // Capture each window, focusing it first so it has an active title bar
        let format = appSettings.screenshotFormat
        let saveURL = appSettings.screenshotSaveURL
        let presetWidth = widthPreset.width
        let windowCount = allWindows.count
        let template = appSettings.screenshotTemplate
        let willOpenEditor = appSettings.openEditorAfterCapture && windowCount == 1

        Task { [windowManager, screenshotService] in
            // Initial delay for app activation to settle
            try? await Task.sleep(for: .milliseconds(300))

            var results: [Result<URL, Error>] = []

            for (index, window) in allWindows.enumerated() {
                guard let windowID = await windowManager.windowIDWithRetry(for: window) else {
                    results.append(.failure(CaptureError.noWindowID(index: index + 1)))
                    continue
                }

                // Focus this window so it renders with an active title bar
                await MainActor.run {
                    windowManager.focusWindow(window)
                }
                try? await Task.sleep(for: .milliseconds(200))

                do {
                    let url = try await screenshotService.capture(
                        windowID: windowID,
                        appName: appName,
                        width: presetWidth,
                        height: height,
                        format: format,
                        saveURL: saveURL,
                        windowIndex: windowCount > 1 ? index : nil,
                        template: willOpenEditor ? nil : template
                    )
                    results.append(.success(url))
                } catch {
                    results.append(.failure(error))
                }
            }

            let capturedFiles = results.compactMap { try? $0.get() }
            let errors: [String] = results.enumerated().compactMap { index, result in
                if case .failure(let error) = result {
                    return "Window \(index + 1): \(error.localizedDescription)"
                }
                return nil
            }

            await MainActor.run { [self] in
                if !capturedFiles.isEmpty {
                    if capturedFiles.count == 1, appSettings.openEditorAfterCapture {
                        EditorWindowController.openEditor(imageURL: capturedFiles[0], template: template, appSettings: appSettings)
                    } else {
                        let body = capturedFiles.count == 1
                            ? capturedFiles[0].lastPathComponent
                            : "\(capturedFiles.count) screenshots saved"
                        let editableFile = capturedFiles.count == 1 ? capturedFiles[0] : nil
                        showNotification(title: "Screenshot Saved", body: body, editableFileURL: editableFile)
                    }
                }
                if !errors.isEmpty {
                    showAlert("Some captures failed:\n" + errors.joined(separator: "\n"))
                }
            }
        }
    }

    @objc func freeSizeCaptureAction() {
        guard ensureScreenRecordingPermission(for: "capture an area screenshot") else { return }

        // Close the menu before entering interactive capture mode
        menu.cancelTracking()

        let format = appSettings.screenshotFormat
        let saveURL = appSettings.screenshotSaveURL
        let template = appSettings.screenshotTemplate

        Task {
            // Brief pause so the menu fully dismisses before the crosshair appears
            try? await Task.sleep(for: .milliseconds(200))

            // Build a temp file path for screencapture output
            let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
                .replacingOccurrences(of: ":", with: "-")
                .replacingOccurrences(of: " ", with: "_")
            let ext = format.fileExtension
            let filename = "FreeCapture_\(timestamp).\(ext)"

            try? FileManager.default.createDirectory(at: saveURL, withIntermediateDirectories: true)
            let outputURL = saveURL.appendingPathComponent(filename)

            // -i = interactive crosshair selection, -t = type, -x = no sound
            let typeFlag: String
            switch format {
            case .png:  typeFlag = "png"
            case .jpeg: typeFlag = "jpg"
            case .heic: typeFlag = "heic"
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            // -o = omit window shadow when capturing a window via Spacebar
            process.arguments = ["-i", "-o", "-x", "-t", typeFlag, outputURL.path]

            do {
                try process.run()
                // Wait for user to finish drawing the region
                process.waitUntilExit()
            } catch {
                await MainActor.run {
                    self.showAlert("Free capture failed: \(error.localizedDescription)")
                }
                return
            }

            // If the user pressed Escape, screencapture exits without writing the file
            guard FileManager.default.fileExists(atPath: outputURL.path) else { return }

            await MainActor.run { [self] in
                EditorWindowController.openEditor(
                    imageURL: outputURL,
                    template: template,
                    appSettings: appSettings
                )
            }
        }
    }

    @objc func openFromClipboardAction() {
        let pasteboard = NSPasteboard.general
        guard let image = NSImage(pasteboard: pasteboard) else {
            showAlert("No image found on the clipboard. Copy an image first, then try again.")
            return
        }

        let saveURL = appSettings.screenshotSaveURL
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = formatter.string(from: Date())
        let filename = "Clipboard_\(timestamp).png"

        try? FileManager.default.createDirectory(at: saveURL, withIntermediateDirectories: true)
        let fileURL = saveURL.appendingPathComponent(filename)

        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:])
        else {
            showAlert("Failed to prepare the clipboard image for editing.")
            return
        }

        do {
            try pngData.write(to: fileURL)
        } catch {
            showAlert("Failed to save clipboard image: \(error.localizedDescription)")
            return
        }

        EditorWindowController.openEditor(
            imageURL: fileURL,
            template: appSettings.screenshotTemplate,
            appSettings: appSettings
        )
    }

    @objc func openFileAction() {
        let panel = NSOpenPanel()
        panel.title = "Open Image"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .gif, .bmp]

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        EditorWindowController.openEditor(
            imageURL: url,
            template: appSettings.screenshotTemplate,
            appSettings: appSettings
        )
    }

    @objc func batchCaptureAction() {
        guard ensureAccessibilityPermission(for: "batch capture app windows"),
              ensureScreenRecordingPermission(for: "capture screenshots")
        else { return }

        guard let app = menuState.selectedApp else {
            showAlert("No application selected. Please select an application first.")
            return
        }
        guard let aspectRatio = appSettings.selectedAspectRatio else { return }

        let allWindows = windowManager.standardWindows(of: app)
        guard !allWindows.isEmpty else {
            showAlert("Cannot access \(app.name)'s windows. Make sure Accessibility permission is granted.")
            return
        }

        // Bring the app to the front so windows are fully visible for capture
        app.activate()

        let presets = appSettings.widthPresets
        let format = appSettings.screenshotFormat
        let saveURL = appSettings.screenshotSaveURL
        let appName = app.name
        let template = appSettings.screenshotTemplate

        Task {
            // Initial delay for app activation to settle
            try? await Task.sleep(for: .milliseconds(300))

            do {
                let urls = try await batchCaptureService.batchCapture(
                    windows: allWindows,
                    appName: appName,
                    presets: presets,
                    aspectRatio: aspectRatio,
                    format: format,
                    saveURL: saveURL,
                    template: template
                )
                await MainActor.run {
                    showNotification(
                        title: "Batch Capture Complete",
                        body: "\(urls.count) screenshots saved"
                    )
                }
            } catch {
                await MainActor.run {
                    showAlert("Batch capture failed: \(error.localizedDescription)")
                }
            }
        }
    }

    @discardableResult
    func performResize() -> (AXUIElement, WindowManager.WindowState)? {
        guard ensureAccessibilityPermission(for: "resize app windows") else { return nil }

        guard let app = menuState.selectedApp else {
            showAlert("No application selected. Please select an application first.")
            return nil
        }
        guard let widthPreset = appSettings.selectedWidthPreset,
              let aspectRatio = appSettings.selectedAspectRatio else { return nil }

        let allWindows = windowManager.standardWindows(of: app)
        guard !allWindows.isEmpty else {
            showAlert("Cannot access \(app.name)'s windows. Make sure Accessibility permission is granted.")
            return nil
        }

        let height = aspectRatio.height(forWidth: widthPreset.width)
        let targetSize = CGSize(width: CGFloat(widthPreset.width), height: CGFloat(height))

        // Store the first window's original state for return value (used by screenshot)
        let firstWindow = allWindows[0]
        let originalState = windowManager.getWindowState(firstWindow)

        // Resize all windows
        var anySuccess = false
        for window in allWindows {
            let success = windowManager.resize(window, to: targetSize)
            if success { anySuccess = true }
        }

        if !anySuccess {
            showAlert("Failed to resize \(app.name)'s windows.")
            return nil
        }

        if let state = originalState {
            return (firstWindow, state)
        }
        return (firstWindow, WindowManager.WindowState(position: .zero, size: targetSize))
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Auto-resize

    /// Automatically resize when both a width and aspect ratio are selected.
    private func autoResizeIfReady() {
        guard menuState.selectedApp != nil,
              appSettings.selectedWidthPreset != nil,
              appSettings.selectedAspectRatio != nil else { return }
        performResize()
    }

    // MARK: - Keep menu open

    /// Re-opens the status-bar menu on the next run-loop tick so that
    /// selection changes (app, width, ratio) don't dismiss the menu.
    private func reopenMenu() {
        guard let button = statusItem?.button else { return }
        DispatchQueue.main.async { [self] in
            skipNextRefresh = true
            rebuildMenu()
            button.performClick(nil)
        }
    }

    // MARK: - Helpers

    private func showAlert(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "SimplShot"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func showNotification(title: String, body: String, editableFileURL: URL? = nil) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Show in Finder")
        if editableFileURL != nil {
            alert.addButton(withTitle: "Edit & Annotate")
        }
        alert.addButton(withTitle: "OK")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(appSettings.screenshotSaveURL)
        } else if response == .alertSecondButtonReturn, let url = editableFileURL {
            EditorWindowController.openEditor(imageURL: url, appSettings: appSettings)
        }
    }

    private func ensureAccessibilityPermission(for feature: String) -> Bool {
        if AccessibilityService.isTrusted { return true }
        AccessibilityService.promptIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            if !AccessibilityService.isTrusted {
                self.showPermissionAlert(
                    title: "Accessibility Permission Required",
                    message: "SimplShot needs Accessibility permission to \(feature).",
                    openSettings: AccessibilityService.openAccessibilitySettings
                )
            }
        }
        return AccessibilityService.isTrusted
    }

    private func ensureScreenRecordingPermission(for feature: String) -> Bool {
        if AccessibilityService.hasScreenRecordingPermission { return true }
        ScreenshotService.ensurePermission()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            if !AccessibilityService.hasScreenRecordingPermission {
                self.showPermissionAlert(
                    title: "Screen Recording Permission Required",
                    message: "SimplShot needs Screen Recording permission to \(feature).",
                    openSettings: AccessibilityService.openScreenRecordingSettings
                )
            }
        }
        return AccessibilityService.hasScreenRecordingPermission
    }

    private func showPermissionAlert(title: String, message: String, openSettings: () -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            openSettings()
        }
    }

    /// Apply a KeyboardShortcuts shortcut to a menu item without requiring @MainActor isolation.
    private func applyShortcut(_ name: KeyboardShortcuts.Name, to item: NSMenuItem) {
        guard let shortcut = KeyboardShortcuts.getShortcut(for: name) else { return }
        item.keyEquivalentModifierMask = shortcut.modifiers
        if let key = shortcut.nsMenuItemKeyEquivalent {
            item.keyEquivalent = key
        }
    }

    // MARK: - Errors

    private enum CaptureError: LocalizedError {
        case noWindowID(index: Int)

        var errorDescription: String? {
            switch self {
            case .noWindowID(let index):
                return "Window \(index): could not get ID"
            }
        }
    }
}
