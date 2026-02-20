import SwiftUI

/// Bottom toolbar for the editor with image adjustment sliders and file action buttons.
struct EditorBottomToolbarView: View {
    @Binding var padding: Int
    @Binding var cornerRadius: Int
    var useTemplateBackground: Bool

    var onTrash: () -> Void
    var onCopy: () -> Void
    var onSave: () -> Void
    var onSaveAs: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                // Sliders pill (left) — only when template background is active
                if useTemplateBackground {
                    sliders
                        .glassEffect(in: Capsule())
                }

                Spacer()

                // Action buttons pill (right)
                actionButtons
                    .glassEffect(in: Capsule())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.clear)
    }

    // MARK: - Sliders

    private var sliders: some View {
        HStack(spacing: 12) {
            // Padding slider
            HStack(spacing: 6) {
                Image(systemName: "inset.filled.center.rectangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .help("Padding")
                Slider(value: paddingBinding, in: 20...200, step: 10)
                    .frame(width: 100)
                Text("\(padding)px")
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 42, alignment: .trailing)
            }

            Divider().frame(height: 16)

            // Corner radius slider
            HStack(spacing: 6) {
                Image(systemName: "rectangle.roundedtop")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .help("Corner Radius")
                Slider(value: cornerRadiusBinding, in: 0...50, step: 1)
                    .frame(width: 100)
                Text("\(cornerRadius)px")
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 42, alignment: .trailing)
            }
        }
        .frame(height: 34)
        .padding(.horizontal, 12)
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 4) {
            Button(action: onTrash) {
                Image(systemName: "trash")
                    .frame(width: 28, height: 26)
            }
            .help("Delete Screenshot")
            .focusable(false)

            Divider()
                .frame(height: 16)
                .padding(.horizontal, 2)

            Button(action: onCopy) {
                Image(systemName: "document.on.document")
                    .frame(width: 28, height: 26)
            }
            .help("Copy to Clipboard")
            .focusable(false)

            Divider()
                .frame(height: 16)
                .padding(.horizontal, 2)

            Button("Save", action: onSave)
                .keyboardShortcut("s", modifiers: .command)
                .focusable(false)

            Divider()
                .frame(height: 16)
                .padding(.horizontal, 2)

            Button("Save As\u{2026}", action: onSaveAs)
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .focusable(false)
        }
        .buttonStyle(.plain)
        .frame(height: 34)
        .padding(.horizontal, 8)
    }

    // MARK: - Bindings

    private var paddingBinding: Binding<Double> {
        Binding(
            get: { Double(padding) },
            set: { padding = Int($0) }
        )
    }

    private var cornerRadiusBinding: Binding<Double> {
        Binding(
            get: { Double(cornerRadius) },
            set: { cornerRadius = Int($0) }
        )
    }
}
