import SwiftUI

/// A 3-state segmented toggle displayed in the top-centre toolbar.
/// Switching the mode changes the sidebar content and canvas interaction behaviour.
struct EditorModeToggle: View {
    @Binding var editorMode: EditorMode
    /// When true, the "Edit" mode is hidden — photo adjustments don't apply to PDFs.
    var isPDFSession: Bool = false

    private var availableModes: [EditorMode] {
        isPDFSession ? EditorMode.allCases.filter { $0 != .edit } : EditorMode.allCases
    }

    var body: some View {
        Picker("Mode", selection: $editorMode) {
            ForEach(availableModes) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: isPDFSession ? 160 : 220)
        .labelsHidden()
    }
}
