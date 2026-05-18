import SwiftUI

/// A 3-state segmented toggle displayed in the top-centre toolbar.
/// Switching the mode changes the sidebar content and canvas interaction behaviour.
struct EditorModeToggle: View {
    @Binding var editorMode: EditorMode

    var body: some View {
        Picker("Mode", selection: $editorMode) {
            ForEach(EditorMode.allCases) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 220)
        .labelsHidden()
    }
}
