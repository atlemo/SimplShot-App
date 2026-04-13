import SwiftUI
import KeyboardShortcuts

struct ShortcutsSettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Keyboard Shortcuts")
                .font(.headline)

            VStack(spacing: 0) {
#if !APPSTORE
                shortcutRow("Capture", shortcut: .resizeAndCapture)
                Divider().padding(.leading, 16)
                shortcutRow("Capture all widths", shortcut: .batchCapture)
                Divider().padding(.leading, 16)
#endif
                shortcutRow("Capture Area", shortcut: .freeSizeCapture)
                Divider().padding(.leading, 16)
                shortcutRow("Capture OCR", shortcut: .captureTextOCR)
                Divider().padding(.leading, 16)
                shortcutRow("Color Picker", shortcut: .colorPicker)
                Divider().padding(.leading, 16)
                shortcutRow("Open Screenshots Folder", shortcut: .openScreenshotsFolder)
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 0.5)
            )
        }
        .padding()
    }

    private func shortcutRow(_ label: String, shortcut: KeyboardShortcuts.Name) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
            KeyboardShortcuts.Recorder("", name: shortcut)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
