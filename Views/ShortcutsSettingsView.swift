import SwiftUI
import KeyboardShortcuts

struct ShortcutsSettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Keyboard Shortcuts")
                    .font(.headline)

                shortcutGroup {
#if !APPSTORE
                    shortcutRow("Capture", shortcut: .resizeAndCapture)
                    Divider().padding(.leading, 16)
                    shortcutRow("Capture all widths", shortcut: .batchCapture)
                    Divider().padding(.leading, 16)
#endif
                    shortcutRow("Capture Area", shortcut: .freeSizeCapture)
                    Divider().padding(.leading, 16)
                    shortcutRow("Capture Window", shortcut: .captureWindow)
                    Divider().padding(.leading, 16)
                    shortcutRow("Capture OCR", shortcut: .captureTextOCR)
                    Divider().padding(.leading, 16)
                    shortcutRow("Color Picker", shortcut: .colorPicker)
                    Divider().padding(.leading, 16)
                    shortcutRow("Open Screenshots Folder", shortcut: .openScreenshotsFolder)
                }
            }

            // Editor-only shortcuts: these are matched by the editor window's own
            // key monitor rather than registered as global hotkeys, so they only
            // fire while an editor window is focused.
            VStack(alignment: .leading, spacing: 8) {
                Text("Editor")
                    .font(.headline)

                shortcutGroup {
                    shortcutRow("Save & Copy", shortcut: .copyToClipboard)
                }

                Text("Works only while an editor window is open, and never while you are editing text.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    private func shortcutGroup<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 0.5)
            )
    }

    private func shortcutRow(_ label: LocalizedStringKey, shortcut: KeyboardShortcuts.Name) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
            // The recorder refuses any combination already claimed by a main-menu
            // item — including ⌘C (Edit ▸ Copy). Names that ship a default are
            // therefore given a reset button, so a user who rebinds them can
            // always get the default back.
            if shortcut.defaultShortcut != nil {
                ResetShortcutButton(name: shortcut)
            }
            KeyboardShortcuts.Recorder("", name: shortcut)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// Restores a shortcut to the default its `Name` was declared with. Hidden while
/// the shortcut already *is* the default, so it only appears when it can do
/// something.
private struct ResetShortcutButton: View {
    let name: KeyboardShortcuts.Name
    @State private var current: KeyboardShortcuts.Shortcut?

    var body: some View {
        Button {
            KeyboardShortcuts.reset(name)
            current = name.shortcut
        } label: {
            Image(systemName: "arrow.uturn.backward")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .help("Restore the default shortcut")
        .opacity(current == name.defaultShortcut ? 0 : 1)
        .disabled(current == name.defaultShortcut)
        .onAppear { current = name.shortcut }
        // The recorder writes straight to UserDefaults, so poll the stored value
        // rather than trying to observe the recorder itself.
        .onReceive(
            NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
        ) { _ in
            current = name.shortcut
        }
    }
}
