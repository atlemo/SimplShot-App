import SwiftUI

@main
struct SimplShotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.openSettings) private var openSettings
    @AppStorage(Constants.UserDefaultsKeys.displayPixelDimensions) private var displayPixelDimensions = false

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

            // Save As / Print — routed to the key editor window. No-ops when no
            // editor window is focused (like the Go and Find commands).
            CommandGroup(after: .saveItem) {
                Button("Save As…") {
                    EditorWindowController.sendActionToKeyWindow("saveAs")
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            }

            CommandGroup(after: .printItem) {
                Button("Print…") {
                    EditorWindowController.sendActionToKeyWindow("print")
                }
                .keyboardShortcut("p", modifiers: .command)
            }

            CommandGroup(after: .toolbar) {
                Divider()
                Button("Actual Size") {
                    EditorWindowController.sendActionToKeyWindow("actualSize")
                }
                .keyboardShortcut("0", modifiers: .command)
                Button("Zoom to Fit") {
                    EditorWindowController.sendActionToKeyWindow("fitPage")
                }
                .keyboardShortcut("9", modifiers: .command)
                Button("Zoom In") {
                    EditorWindowController.sendActionToKeyWindow("zoomIn")
                }
                .keyboardShortcut("+", modifiers: .command)
                Button("Zoom Out") {
                    EditorWindowController.sendActionToKeyWindow("zoomOut")
                }
                .keyboardShortcut("-", modifiers: .command)

                Divider()
                editorModeToggle(.annotate, shortcut: "1")
                editorModeToggle(.edit, shortcut: "2")
                    .disabled(!EditorWindowController.canSetMode(.edit))
                editorModeToggle(.view, shortcut: "3")

                Divider()
                Toggle("Display Pixel Dimensions", isOn: $displayPixelDimensions)
                // Trailing divider fences this item into its own section so it
                // isn't grouped with the icon-bearing system "Enter Full Screen"
                // item below it — otherwise macOS reserves an icon column for the
                // whole section and indents this checkmark-only item.
                Divider()
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

            // Go — page navigation and document info.
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
