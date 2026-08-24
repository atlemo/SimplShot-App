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
    /// Disabled while the crop tool is live: crop mode owns the sidebar and, with
    /// a template, an expanded canvas, so switching modes underneath it would
    /// strand both. Apply or Cancel first.
    var isDisabled: Bool = false

    @AppStorage("debugSimulateSonomaAppearance") private var simulateSonoma = false

    /// Keyboard-focus tracking for the segments. Clicking a plain button doesn't
    /// move macOS keyboard focus on its own, so the blue focus ring would stay
    /// stuck on whichever segment was focused first (e.g. Annotate) while the
    /// selected-capsule highlight moved elsewhere. Driving focus from the tap
    /// keeps the ring on the segment you actually clicked.
    @FocusState private var focusedMode: EditorMode?

    private var availableModes: [EditorMode] {
        isPDFSession ? EditorMode.allCases.filter { $0 != .edit } : EditorMode.allCases
    }

    private var useGlass: Bool {
        guard #available(macOS 26, *) else { return false }
        return !simulateSonoma
    }

    var body: some View {
        let pill = HStack(spacing: 0) {
            ForEach(availableModes) { mode in
                segment(mode)
            }
        }
        .padding(3)
        .pillBackground(useGlass: useGlass)
        .opacity(isDisabled ? 0.45 : 1)
        .disabled(isDisabled)
        .animation(.easeInOut(duration: 0.15), value: isDisabled)

        // The tooltip is applied in a branch rather than with a ternary: a
        // ternary mixing literals types as String and would not be extracted
        // into the string catalog.
        if isDisabled {
            pill.help("Finish or cancel the crop to switch modes")
        } else {
            pill
        }
    }

    @ViewBuilder
    private func segment(_ mode: EditorMode) -> some View {
        let isSelected = editorMode == mode
        Button {
            editorMode = mode
            focusedMode = mode
        } label: {
            Text(mode.displayName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .padding(.horizontal, 16)
                .frame(height: 28)
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
        .focused($focusedMode, equals: mode)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
