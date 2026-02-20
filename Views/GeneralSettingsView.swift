import SwiftUI
import Combine
import KeyboardShortcuts

struct GeneralSettingsView: View {
    @Bindable var appSettings: AppSettings
    @State private var accessibilityGranted = AccessibilityService.isTrusted
    @State private var screenRecordingGranted = AccessibilityService.hasScreenRecordingPermission

    private let labelWidth: CGFloat = 140

    var body: some View {
        VStack(spacing: 0) {
            // --- Start at Login ---
            settingsRow("Startup:") {
                Toggle("Launch at login", isOn: $appSettings.startAtLogin)
                    .toggleStyle(.checkbox)
            }

            Divider().padding(.horizontal)

            // --- Open Editor After Capture ---
            settingsRow("After capture:") {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Open Editor automatically", isOn: $appSettings.openEditorAfterCapture)
                        .toggleStyle(.checkbox)
                    Text("Only applies to single image captures")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 20)
                }
            }

            Divider().padding(.horizontal)

            // --- Screenshot Save Location ---
            settingsRow("Screenshot location:") {
                PathControlPicker(url: $appSettings.screenshotSaveURL)
                    .frame(maxWidth: 260, minHeight: 24, alignment: .leading)
            }

            Divider().padding(.horizontal)

            // --- Screenshot Format ---
            settingsRow("File format:") {
                Picker("", selection: $appSettings.screenshotFormat) {
                    ForEach(ScreenshotFormat.allCases, id: \.self) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 160)
            }

            Divider().padding(.horizontal)

            // --- Keyboard Shortcuts ---
            settingsRow("Keyboard shortcuts:") {
                VStack(alignment: .leading, spacing: 12) {
                    shortcutRow("Capture", shortcut: .resizeAndCapture)
                    shortcutRow("Capture all widths", shortcut: .batchCapture)
                    shortcutRow("Free size capture", shortcut: .freeSizeCapture)
                }
            }

            Divider().padding(.horizontal)

            // --- Permissions ---
            settingsRow("Permissions:") {
                VStack(alignment: .leading, spacing: 10) {
                    permissionRow(
                        label: "Accessibility",
                        granted: accessibilityGranted,
                        action: { AccessibilityService.openAccessibilitySettings() }
                    )
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

    private func settingsRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
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

    // MARK: - Shortcut row

    private func shortcutRow(_ label: String, shortcut: KeyboardShortcuts.Name) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .frame(width: 130, alignment: .leading)
            KeyboardShortcuts.Recorder("", name: shortcut)
        }
    }

    // MARK: - Permission row

    private func permissionRow(label: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(granted ? .green : .red)
                .font(.system(size: 13))
            Text(label)
                .font(.system(size: 13))
            if !granted {
                Button("Grant…", action: action)
                    .controlSize(.small)
                    .font(.system(size: 11))
            }
        }
    }

    // MARK: - Helpers

    private func refreshPermissions() {
        accessibilityGranted = AccessibilityService.isTrusted
        screenRecordingGranted = AccessibilityService.hasScreenRecordingPermission
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
            button.addItem(withTitle: "Choose…")
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
                }
            }
        }
    }
}
