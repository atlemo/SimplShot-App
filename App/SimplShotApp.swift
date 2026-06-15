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
                Button("Open File(s)…") {
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

            // Find — in the Edit menu. No-ops on non-PDF / non-editor windows.
            CommandGroup(after: .textEditing) {
                Divider()
                Button("Find…") {
                    EditorWindowController.sendActionToKeyWindow("find")
                }
                .keyboardShortcut("f", modifiers: .command)
                Button("Find Next") {
                    EditorWindowController.sendActionToKeyWindow("findNext")
                }
                .keyboardShortcut("g", modifiers: .command)
                Button("Find Previous") {
                    EditorWindowController.sendActionToKeyWindow("findPrevious")
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            }

            // Go — page navigation, document info, and zoom presets.
            CommandMenu("Go") {
                Button("Next Page") {
                    EditorWindowController.sendActionToKeyWindow("nextPage")
                }
                .keyboardShortcut(.downArrow, modifiers: .command)
                Button("Previous Page") {
                    EditorWindowController.sendActionToKeyWindow("previousPage")
                }
                .keyboardShortcut(.upArrow, modifiers: .command)

                Divider()
                Button("Rotate Left") {
                    EditorWindowController.sendActionToKeyWindow("rotateLeft")
                }
                .keyboardShortcut("l", modifiers: .command)
                Button("Rotate Right") {
                    EditorWindowController.sendActionToKeyWindow("rotateRight")
                }
                .keyboardShortcut("r", modifiers: .command)

                Divider()
                Button("Document Info") {
                    EditorWindowController.sendActionToKeyWindow("documentInfo")
                }
                .keyboardShortcut("i", modifiers: .command)

                Divider()
                Button("Actual Size") {
                    EditorWindowController.sendActionToKeyWindow("actualSize")
                }
                .keyboardShortcut("0", modifiers: .command)
                Button("Fit Width") {
                    EditorWindowController.sendActionToKeyWindow("fitWidth")
                }
                Button("Fit Page") {
                    EditorWindowController.sendActionToKeyWindow("fitPage")
                }
                .keyboardShortcut("9", modifiers: .command)
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
