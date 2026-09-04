import SwiftUI
import Combine
import UniformTypeIdentifiers

struct GeneralSettingsView: View {
    @Bindable var appSettings: AppSettings
#if !APPSTORE
    @State private var accessibilityGranted = AccessibilityService.isTrusted
#endif
    @State private var screenRecordingGranted = false
    @State private var language = AppLanguage.current
    @State private var isDefaultForAllTypes = false
    @State private var isSettingDefaultApp = false

    private let labelWidth: CGFloat = 140

    var body: some View {
        VStack(spacing: 0) {
            // --- UI language ---
            settingsRow("Language:") {
                VStack(alignment: .leading, spacing: 5) {
                    Picker("", selection: $language) {
                        ForEach(AppLanguage.allCases) { lang in
                            Text(lang.displayName).tag(lang)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .onChange(of: language) { _, newValue in
                        newValue.apply()
                        promptRestartForLanguageChange()
                    }
                    Text("Takes effect after restarting SimplShot")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // --- Start at Login ---
            settingsRow("Startup:") {
                Toggle("Launch at login", isOn: $appSettings.startAtLogin)
                    .toggleStyle(.checkbox)
            }

            // --- Menu bar icon ---
            settingsRow("Menu bar:") {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Hide menu bar icon", isOn: $appSettings.hideMenuBarIcon)
                        .toggleStyle(.checkbox)
                        .onChange(of: appSettings.hideMenuBarIcon) { _, isHidden in
                            if isHidden { showHideMenuBarIconNoticeIfNeeded() }
                        }
                    Text("Open SimplShot from Spotlight to show the menu")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 20)
                }
            }

            // --- Open Editor After Capture ---
            settingsRow("After capture:") {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Open Editor automatically", isOn: $appSettings.openEditorAfterCapture)
                        .toggleStyle(.checkbox)
#if !APPSTORE
                    Text("Only applies to single image captures")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 20)
#endif
                }
            }

            // --- Screenshot Save Location ---
            settingsRow("Screenshot location:") {
                PathControlPicker(url: $appSettings.screenshotSaveURL)
                    .frame(maxWidth: 260, minHeight: 24, alignment: .leading)
            }

            // --- Screenshot Format ---
            settingsRow("Screenshot format:") {
                Picker("", selection: $appSettings.screenshotFormat) {
                    ForEach(ScreenshotFormat.allCases, id: \.self) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 210)
            }

            // --- Default mode when opening images ---
            settingsRow("Open images in:") {
                VStack(alignment: .leading, spacing: 5) {
                    Picker("", selection: $appSettings.defaultEditorModeOnOpen) {
                        ForEach(DefaultEditorModeSetting.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()  // size to content so the chevron sits next to the label, not the row edge
                    Text("Applies when opening files from Finder or other apps")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // --- Default app for the file types we declare in Info.plist ---
            settingsRow("Default app:") {
                VStack(alignment: .leading, spacing: 4) {
                    if isDefaultForAllTypes {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.system(size: 13))
                            Text("SimplShot opens images and PDFs by default")
                                .font(.system(size: 13))
                        }
                    } else {
                        Button("Make SimplShot Default ❤️") {
                            makeDefaultAppForSupportedTypes()
                        }
                        .disabled(isSettingDefaultApp)
                        Text("Opens PNG, JPEG, HEIC, PDF and other supported files in SimplShot. macOS shows one confirmation dialog per format.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            // Without this the caption is handed a single-line
                            // height and truncates with an ellipsis instead of
                            // wrapping — it is the longest caption in the pane.
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            // --- Permissions ---
            settingsRow("Permissions:") {
                VStack(alignment: .leading, spacing: 10) {
#if !APPSTORE
                    permissionRow(
                        label: "Accessibility",
                        granted: accessibilityGranted,
                        action: { AccessibilityService.openAccessibilitySettings() }
                    )
#endif
                    permissionRow(
                        label: "Screen Recording",
                        granted: screenRecordingGranted,
                        action: { AccessibilityService.openScreenRecordingSettings() }
                    )
                }
            }

        }
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .onAppear {
            refreshPermissions()
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            refreshPermissions()
        }
    }

    // MARK: - Reusable row layout

    private func settingsRow<Content: View>(_ label: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .multilineTextAlignment(.trailing)
                .frame(width: labelWidth, alignment: .trailing)
                .foregroundStyle(.secondary)

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 12)
    }

    // MARK: - Permission row

    private func permissionRow(label: LocalizedStringKey, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(granted ? .green : .red)
                .font(.system(size: 13))
            Text(label)
                .font(.system(size: 13))
            Spacer()
            if !granted {
                Button("Grant…", action: action)
                    .controlSize(.small)
                    .font(.system(size: 11))
            }
        }
    }

    // MARK: - Helpers

    /// The bundle resolves its localization once at launch, so a language change
    /// only shows up after a relaunch.
    private func promptRestartForLanguageChange() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Restart Required")
        alert.informativeText = String(localized: "SimplShot needs to restart to change the language.")
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "Restart Now"))
        alert.addButton(withTitle: String(localized: "Later"))
        if alert.runModal() == .alertFirstButtonReturn {
            MenuBuilder.relaunchApp()
        }
    }

    /// Explains the way back in, once, the first time the icon is hidden: with no
    /// icon and no window there is nothing on screen to click, and the app is
    /// still running.
    private func showHideMenuBarIconNoticeIfNeeded() {
        let key = Constants.UserDefaultsKeys.hasShownHideMenuBarIconNotice
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)

        let alert = NSAlert()
        alert.messageText = String(localized: "Menu Bar Icon Hidden")
        alert.informativeText = String(localized: "SimplShot keeps running in the background. Open it from Spotlight to show the menu again — the icon stays hidden.")
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }

    private func refreshPermissions() {
#if !APPSTORE
        accessibilityGranted = AccessibilityService.isTrusted
#endif
        isDefaultForAllTypes = DefaultAppService.isDefaultForAllSupportedTypes()
        Task {
            let state = await ScreenRecordingPermissionManager.shared.checkPermission()
            await MainActor.run {
                screenRecordingGranted = state == .granted
            }
        }
    }

    /// Claims every file type SimplShot declares, then re-reads the real state —
    /// the button never asserts success it hasn't verified.
    private func makeDefaultAppForSupportedTypes() {
        isSettingDefaultApp = true
        Task {
            let failed = await DefaultAppService.makeDefaultForAllSupportedTypes()
            await MainActor.run {
                isSettingDefaultApp = false
                isDefaultForAllTypes = DefaultAppService.isDefaultForAllSupportedTypes()
                if !failed.isEmpty { showDefaultAppFailureAlert() }
            }
        }
    }

    private func showDefaultAppFailureAlert() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Some File Types Weren't Changed")
        alert.informativeText = String(localized: "macOS didn't let SimplShot become the default app for every supported file type. You can set the rest by hand: select a file in Finder, choose File › Get Info, pick SimplShot under “Open with” and click “Change All…”.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }
}

// MARK: - Default app registration

/// Makes SimplShot the default handler for every type it declares in
/// `CFBundleDocumentTypes`.
///
/// The type list is read back out of our own Info.plist rather than hardcoded,
/// so it can never drift from what the app actually claims to open — adding a
/// format to the plist is enough.
enum DefaultAppService {

    /// Declared types we deliberately do NOT claim.
    ///
    /// Photoshop owns `.psd` wherever it is installed, and taking that away is
    /// hostile for a screenshot editor. We stay an `Alternate` handler for it,
    /// so SimplShot still shows up under "Open With" — it just never becomes
    /// the default.
    private static let unclaimedIdentifiers: Set<String> = ["com.adobe.photoshop-image"]

    /// Declared types we are willing to claim, as they resolve on this system.
    /// `AVIF` and `JPEG XL` only exist on newer macOS versions, so unknown
    /// identifiers are dropped.
    static let claimableContentTypes: [UTType] = {
        let docTypes = Bundle.main.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]] ?? []
        let identifiers = docTypes.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] }
        var seen = Set<String>()
        return identifiers.compactMap { identifier in
            guard seen.insert(identifier).inserted,
                  !unclaimedIdentifiers.contains(identifier) else { return nil }
            return UTType(identifier)
        }
    }()

    static func isDefault(for contentType: UTType) -> Bool {
        guard let handler = NSWorkspace.shared.urlForApplication(toOpen: contentType) else { return false }
        return handler.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    static func isDefaultForAllSupportedTypes() -> Bool {
        !claimableContentTypes.isEmpty && claimableContentTypes.allSatisfy(isDefault(for:))
    }

    /// Claims every type we don't already own, stopping the moment the user
    /// dismisses one of macOS's confirmation prompts — there is one prompt per
    /// content type and no way to batch them, so carrying on after a cancel
    /// would march the user through a prompt for every remaining format.
    ///
    /// Returns the types that genuinely failed. A cancelled prompt is a choice,
    /// not a failure, so it is not reported as one.
    static func makeDefaultForAllSupportedTypes() async -> [UTType] {
        var failed: [UTType] = []
        for contentType in claimableContentTypes where !isDefault(for: contentType) {
            guard let error = await setDefault(for: contentType) else { continue }
            if isCancellation(error) { break }
            failed.append(contentType)
        }
        return failed
    }

    private static func setDefault(for contentType: UTType) async -> Error? {
        await withCheckedContinuation { continuation in
            NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: contentType) { error in
                continuation.resume(returning: error)
            }
        }
    }

    /// A dismissed confirmation prompt arrives as `userCanceledErr`, wrapped in a
    /// Cocoa "file couldn't be opened" error rather than surfacing directly.
    private static func isCancellation(_ error: Error) -> Bool {
        func isUserCancelled(_ error: NSError) -> Bool {
            error.domain == NSOSStatusErrorDomain && error.code == -128
        }
        let nsError = error as NSError
        if isUserCancelled(nsError) { return true }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isUserCancelled(underlying)
        }
        return false
    }
}

// MARK: - Folder popup picker (NSPopUpButton)

struct PathControlPicker: NSViewRepresentable {
    @Binding var url: URL

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.controlSize = .regular
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionChanged(_:))
        context.coordinator.updateMenu(for: button, url: url)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.updateMenu(for: button, url: url)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject {
        var parent: PathControlPicker
        private let chooseTag = -1

        init(_ parent: PathControlPicker) {
            self.parent = parent
        }

        func updateMenu(for button: NSPopUpButton, url: URL) {
            button.removeAllItems()

            // Current folder item with icon
            let folderName = url.lastPathComponent
            let icon = NSWorkspace.shared.icon(for: .folder)
            icon.size = NSSize(width: 16, height: 16)

            button.addItem(withTitle: folderName)
            button.lastItem?.image = icon
            button.lastItem?.tag = 0

            // Separator
            button.menu?.addItem(.separator())

            // "Choose..." option
            button.addItem(withTitle: String(localized: "Choose…"))
            button.lastItem?.tag = chooseTag

            // Select the folder item
            button.selectItem(withTag: 0)
        }

        @objc func selectionChanged(_ sender: NSPopUpButton) {
            guard let item = sender.selectedItem else { return }

            if item.tag == chooseTag {
                // Reset to current folder before opening panel
                sender.selectItem(withTag: 0)

                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = false
                panel.directoryURL = parent.url
                if panel.runModal() == .OK, let chosen = panel.url {
                    parent.url = chosen
#if APPSTORE
                    AppSettings.storeBookmark(for: chosen)
#endif
                }
            }
        }
    }
}
