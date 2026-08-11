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
    var onFitWidth: () -> Void = {}
    var onActualSize: () -> Void = {}

    @AppStorage("debugSimulateSonomaAppearance") private var simulateSonoma = false
    /// Global toggle (View ▸ Display pixel dimensions). Off by default, so neither
    /// screenshots nor PDFs show the px readout until the user opts in.
    @AppStorage(Constants.UserDefaultsKeys.displayPixelDimensions) private var displayPixelDimensions = false

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
                    } else if displayPixelDimensions && imagePixelSize != .zero {
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
                    .foregroundStyle(.red)
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
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Zoom + Annotation Bar

    private var zoomBar: some View {
        HStack(spacing: 6) {
            Text("\(annotationsCount) annotations")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Divider().frame(height: 14)

            Button(action: onZoomOut) {
                Image(systemName: "minus.magnifyingglass")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .help("Zoom Out")

            Menu {
                Button("Fit Page", action: onZoomReset)
                Button("Fit Width", action: onFitWidth)
                Button("Actual Size", action: onActualSize)
            } label: {
                Text("\(displayZoomPercent)%")
                    .font(.system(size: 11, design: .monospaced))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 46, alignment: .center)
            .help("Zoom presets")

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

/// Icon/text toolbar button whose hover highlight hugs the label (via the
/// label's own frame + contentShape) instead of the oversized default toolbar
/// button background. Shared by the bottom bar and the PDF page navigator.
struct ToolbarHoverButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isHovered || configuration.isPressed ? .primary : .secondary)
            .background(
                // Pill highlight inset vertically so it stays inside the
                // container's top/bottom edges, matching the top mode toggle's
                // selected segment. No horizontal inset — the capsule's rounded
                // ends would otherwise read as a larger gap on the sides.
                Capsule(style: .continuous)
                    .fill(isHovered ? .white.opacity(0.1) : .clear)
                    .padding(.vertical, 3)
            )
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .onHover { isHovered = $0 }
    }
}

// MARK: - Pill background helper

extension View {
    @ViewBuilder
    func pillBackground(useGlass: Bool) -> some View {
        if #available(macOS 26, *), useGlass {
            self.glassEffect(in: Capsule())
        } else {
            self.background(.ultraThinMaterial, in: Capsule())
        }
    }
}
