import SwiftUI

/// Bottom toolbar for the editor with image adjustment sliders and file action buttons.
struct EditorBottomToolbarView: View {
    private let pillHeight: CGFloat = 36

    let aspectRatios: [AspectRatio]
    @Binding var selectedAspectRatioID: UUID?
    @Binding var padding: Int
    @Binding var cornerRadius: Int
    var useTemplateBackground: Bool
    var hideSliders: Bool = false

    var onTrash: () -> Void
    var onSaveAs: () -> Void

    /// When true (DEBUG only), forces the pre-macOS 26 material fallback so you can
    /// preview the Sonoma-era appearance without leaving your Mac.
    @AppStorage("debugSimulateSonomaAppearance") private var simulateSonoma = false

    /// True when the actual glass rendering path should be used.
    private var useGlass: Bool {
        guard #available(macOS 26, *) else { return false }
        return !simulateSonoma
    }

    var body: some View {
        glassContainer {
            HStack(spacing: 8) {
                // Sliders pill (left) — only when template background is active and not in pro sidebar mode
                if useTemplateBackground && !hideSliders {
                    sliders
                        .pillBackground(useGlass: useGlass)
                }

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

    /// Wraps content in GlassEffectContainer on macOS 26+; plain passthrough on older OS.
    @ViewBuilder
    private func glassContainer<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if #available(macOS 26, *), !simulateSonoma {
            GlassEffectContainer(spacing: 8) { content() }
        } else {
            content()
        }
    }

    // MARK: - Sliders

    private var sliders: some View {
        HStack(spacing: 12) {
            // Aspect ratio selector
            HStack(spacing: 6) {
                Image(systemName: "aspectratio")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .help("Aspect Ratio")
                Picker("", selection: $selectedAspectRatioID) {
                    Text("Original")
                        .tag(Optional<UUID>.none)
                    ForEach(aspectRatios) { ratio in
                        Text(ratio.label)
                            .tag(Optional(ratio.id))
                    }
                }
                .labelsHidden()
                .frame(width: 96)
            }

            Divider().frame(height: 16)

            // Padding slider
            HStack(spacing: 6) {
                Image(systemName: "inset.filled.center.rectangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .help("Padding")
                Slider(value: paddingBinding, in: 20...200)
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
                Slider(value: cornerRadiusBinding, in: 0...50)
                    .frame(width: 100)
                Text("\(cornerRadius)px")
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 42, alignment: .trailing)
            }
        }
        .frame(height: pillHeight)
        .padding(.horizontal, 12)
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
