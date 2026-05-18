import SwiftUI

/// Unified bottom toolbar: pixel dimensions on the left, action buttons in the center,
/// annotation count + zoom controls on the right. Fully transparent — no container background.
struct EditorBottomToolbarView: View {
    private let pillHeight: CGFloat = 32

    // Left — pixel dimensions or template sliders
    let imagePixelSize: CGSize
    let aspectRatios: [AspectRatio]
    @Binding var selectedAspectRatioID: UUID?
    @Binding var padding: Int
    @Binding var cornerRadius: Int
    var useTemplateBackground: Bool
    var hideSliders: Bool = false

    // Center — action buttons
    var onTrash: () -> Void
    var onCancel: () -> Void
    var onSaveAs: () -> Void

    // Right — annotations + zoom
    let annotationsCount: Int
    let displayZoomPercent: Int
    var onZoomOut: () -> Void
    var onZoomIn: () -> Void
    var onZoomReset: () -> Void

    @AppStorage("debugSimulateSonomaAppearance") private var simulateSonoma = false

    private var useGlass: Bool {
        guard #available(macOS 26, *) else { return false }
        return !simulateSonoma
    }

    var body: some View {
        glassContainer {
            HStack(alignment: .center, spacing: 0) {
                // Left zone
                Group {
                    if useTemplateBackground && !hideSliders {
                        sliders
                            .pillBackground(useGlass: useGlass)
                    } else if imagePixelSize != .zero {
                        Text("\(Int(imagePixelSize.width)) × \(Int(imagePixelSize.height)) px")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    } else {
                        EmptyView()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Center zone — action buttons
                actionButtons
                    .pillBackground(useGlass: useGlass)

                // Right zone — annotations + zoom
                zoomBar
                    .pillBackground(useGlass: useGlass)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(.clear)
    }

    @ViewBuilder
    private func glassContainer<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if #available(macOS 26, *), !simulateSonoma {
            GlassEffectContainer(spacing: 8) { content() }
        } else {
            content()
        }
    }

    // MARK: - Sliders (template controls)

    private var sliders: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "aspectratio")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .help("Aspect Ratio")
                Picker("", selection: $selectedAspectRatioID) {
                    Text("Original").tag(Optional<UUID>.none)
                    ForEach(aspectRatios) { ratio in
                        Text(ratio.label).tag(Optional(ratio.id))
                    }
                }
                .labelsHidden()
                .frame(width: 96)
            }

            Divider().frame(height: 16)

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
        HStack(spacing: 0) {
            Button(action: onTrash) {
                Label("Delete", systemImage: "trash")
                    .labelStyle(.iconOnly)
                    .frame(width: 36, height: pillHeight)
                    .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(ToolbarHoverButtonStyle())
            .help("Delete Screenshot")

            Divider().frame(height: 16).padding(.horizontal, 2)

            Button(action: onCancel) {
                Text("Cancel")
                    .padding(.horizontal, 10)
                    .frame(height: pillHeight)
                    .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(ToolbarHoverButtonStyle())
            .help("Close without saving")

            Divider().frame(height: 16).padding(.horizontal, 2)

            Button(action: onSaveAs) {
                Text("Save As\u{2026}")
                    .padding(.horizontal, 10)
                    .frame(height: pillHeight)
                    .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(ToolbarHoverButtonStyle())
            .help("Save a copy")
            .keyboardShortcut("s", modifiers: [.command, .shift])
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Zoom + Annotation Bar

    private var zoomBar: some View {
        HStack(spacing: 6) {
            Text("\(annotationsCount) annotation\(annotationsCount == 1 ? "" : "s")")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Divider().frame(height: 14)

            Button(action: onZoomOut) {
                Image(systemName: "minus.magnifyingglass")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .help("Zoom Out")

            Text("\(displayZoomPercent)%")
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 40, alignment: .center)

            Button(action: onZoomIn) {
                Image(systemName: "plus.magnifyingglass")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .help("Zoom In")

            Button(action: onZoomReset) {
                Text("Fit")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .help("Reset Zoom")
        }
        .frame(height: pillHeight)
        .padding(.horizontal, 10)
    }

    // MARK: - Bindings

    private var paddingBinding: Binding<Double> {
        Binding(get: { Double(padding) }, set: { padding = Int($0) })
    }

    private var cornerRadiusBinding: Binding<Double> {
        Binding(get: { Double(cornerRadius) }, set: { cornerRadius = Int($0) })
    }
}

// MARK: - Hover button style

private struct ToolbarHoverButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isHovered || configuration.isPressed ? .primary : .secondary)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovered ? .white.opacity(0.1) : .clear)
            )
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .onHover { isHovered = $0 }
    }
}

// MARK: - Pill background helper

private extension View {
    @ViewBuilder
    func pillBackground(useGlass: Bool) -> some View {
        if #available(macOS 26, *), useGlass {
            self.glassEffect(in: Capsule())
        } else {
            self.background(.ultraThinMaterial, in: Capsule())
        }
    }
}
