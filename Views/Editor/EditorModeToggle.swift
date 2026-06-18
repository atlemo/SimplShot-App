import SwiftUI

/// A pill-shaped, glass-backed mode switch (Annotate · Edit · View).
///
/// The native `.segmented` picker only renders the floating white-capsule look
/// inside a window toolbar — in plain content it falls back to a flat grey
/// rectangle. Since the editor's top action bar lives in the content (so it can
/// follow the sidebar), this draws the capsule look explicitly: a glass pill
/// with a raised highlight on the selected segment, matching the top/bottom
/// action-bar material.
struct EditorModeToggle: View {
    @Binding var editorMode: EditorMode
    /// When true, the "Edit" mode is hidden — photo adjustments don't apply to PDFs.
    var isPDFSession: Bool = false

    @AppStorage("debugSimulateSonomaAppearance") private var simulateSonoma = false

    private var availableModes: [EditorMode] {
        isPDFSession ? EditorMode.allCases.filter { $0 != .edit } : EditorMode.allCases
    }

    private var useGlass: Bool {
        guard #available(macOS 26, *) else { return false }
        return !simulateSonoma
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(availableModes) { mode in
                segment(mode)
            }
        }
        .padding(3)
        .pillBackground(useGlass: useGlass)
    }

    @ViewBuilder
    private func segment(_ mode: EditorMode) -> some View {
        let isSelected = editorMode == mode
        Button {
            editorMode = mode
        } label: {
            Text(mode.rawValue)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .padding(.horizontal, 16)
                .frame(height: 26)
                .background {
                    if isSelected {
                        Capsule(style: .continuous)
                            .fill(Color.gray.opacity(0.16))
                            .shadow(color: .black.opacity(0.05), radius: 1, y: 0.5)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
