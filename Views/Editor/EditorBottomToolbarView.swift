import SwiftUI

/// Bottom toolbar for the editor with file action buttons (Trash, Cancel, Save As).
/// Template sliders (aspect ratio, padding, corner radius) live in the sidebar now.
struct EditorBottomToolbarView: View {
    private let pillHeight: CGFloat = 36

    var onTrash: () -> Void
    /// Discards all unsaved edits and closes the editor without writing to disk.
    var onCancel: () -> Void
    var onSaveAs: () -> Void

    /// True when the macOS 26+ glass rendering path is available.
    private var useGlass: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    var body: some View {
        glassContainer {
            HStack(spacing: 8) {
                Spacer()

                // Action buttons pill (right)
                actionButtons
                    .pillBackground(useGlass: useGlass)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.clear)
    }

    /// Wraps content in GlassEffectContainer when glass is active; plain passthrough otherwise.
    @ViewBuilder
    private func glassContainer<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if #available(macOS 26, *), useGlass {
            GlassEffectContainer(spacing: 8) { content() }
        } else {
            content()
        }
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 4) {
            Button(action: onTrash) {
                Image(systemName: "trash")
                    .frame(width: 28, height: pillHeight)
                    .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .help("Delete Screenshot")

            Divider()
                .frame(height: 16)
                .padding(.horizontal, 2)

            Button(action: onCancel) {
                Text("Cancel")
                    .padding(.horizontal, 6)
                    .frame(height: pillHeight)
                    .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .help("Discard all edits and close")

            Divider()
                .frame(height: 16)
                .padding(.horizontal, 2)

            Button(action: onSaveAs) {
                Text("Save As\u{2026}")
                    .padding(.horizontal, 6)
                    .frame(height: pillHeight)
                    .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
        }
        .buttonStyle(.plain)
        .frame(height: pillHeight)
        .padding(.horizontal, 8)
    }
}

// MARK: - Pill background helper

private extension View {
    /// Applies `.glassEffect(in: Capsule())` on macOS 26+ when glass is active,
    /// or `.background(.ultraThinMaterial, in: Capsule())` as a Sonoma-era fallback.
    @ViewBuilder
    func pillBackground(useGlass: Bool) -> some View {
        if #available(macOS 26, *), useGlass {
            self.glassEffect(in: Capsule())
        } else {
            self.background(.ultraThinMaterial, in: Capsule())
        }
    }
}
