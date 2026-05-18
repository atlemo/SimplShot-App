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
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open File…") {
                    appDelegate.openFile()
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("Open Screenshots Folder") {
                    appDelegate.openScreenshotsFolder()
                }
            }

            CommandGroup(after: .toolbar) {
                Divider()
                editorModeToggle(.annotate, shortcut: "1")
                editorModeToggle(.edit, shortcut: "2")
                    .disabled(!EditorWindowController.canSetMode(.edit))
                editorModeToggle(.view, shortcut: "3")
            }
        }
    }

    private func editorModeToggle(_ mode: EditorMode, shortcut: KeyEquivalent) -> some View {
        Toggle(
            mode.rawValue,
            isOn: Binding(
                get: { EditorWindowController.currentModeForKeyWindow == mode },
                set: { isSelected in
                    guard isSelected else { return }
                    EditorWindowController.setModeForKeyWindow(mode)
                }
            )
        )
        .keyboardShortcut(shortcut, modifiers: .command)
    }

    /// Pass the SwiftUI `openSettings` environment action to the AppKit side
    /// so the NSMenu "Settings…" item can open the Settings scene properly.
    private func installOpenSettings() {
        appDelegate.openSettingsAction = { [openSettings] in
            openSettings()
        }
    }
}
