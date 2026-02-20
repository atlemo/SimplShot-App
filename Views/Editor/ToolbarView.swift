import SwiftUI

/// The annotation toolbar displayed at the top of the editor.
struct EditorToolbarView: View {
    @Binding var currentTool: AnnotationTool
    @Binding var currentStyle: AnnotationStyle
    @Binding var isCropping: Bool
    @Binding var selectedAnnotationID: UUID?
    @Binding var annotations: [Annotation]

    var canUndo: Bool
    var hasTemplate: Bool
    @Binding var useTemplateBackground: Bool
    var onApplyCrop: () -> Void
    var onCancelCrop: () -> Void
    var onUndo: () -> Void

    /// The drawing tools available in the toolbar (excludes .select and .crop which are handled separately).
    private let drawingTools: [AnnotationTool] = [.arrow, .rectangle, .circle, .line, .text]

    /// Preset colors for the color picker.
    private let presetColors: [Color] = [
        .red, .orange, .yellow, .green, .blue, .purple, .white, .black
    ]

    /// Whether style controls should be visible: when drawing or when an annotation is selected.
    private var showStyleControls: Bool {
        if drawingTools.contains(currentTool) { return true }
        if selectedAnnotationID != nil { return true }
        return false
    }

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                // Tool picker pill
                toolPicker
                    .glassEffect(in: Capsule())

                // Crop controls pill (replaces tool picker when cropping)
                if isCropping {
                    cropControls
                        .glassEffect(in: Capsule())
                }

                // Style controls pill
                if showStyleControls {
                    styleControls
                        .glassEffect(in: Capsule())
                }

                // Template background toggle
                if hasTemplate {
                    Toggle("Show Background", isOn: $useTemplateBackground)
                        .toggleStyle(.switch)
                        .font(.system(size: 12))
                        .focusable(false)
                        .frame(height: 34)
                        .padding(.horizontal, 10)
                        .glassEffect(in: Capsule())
                }

                Spacer()

                // Undo button pill
                undoButton
                    .glassEffect(in: Capsule())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.clear)
    }

    // MARK: - Tool Picker

    private var toolPicker: some View {
        HStack(spacing: 0) {
            toolButton(.select)
            ForEach(drawingTools) { tool in
                toolButton(tool)
            }
            toolButton(.crop)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
    }

    private func toolButton(_ tool: AnnotationTool) -> some View {
        Button {
            selectTool(tool)
        } label: {
            Image(systemName: tool.systemImage)
                .font(.system(size: 14))
                .frame(width: 28, height: 28)
                .contentShape(Circle())
                .background(
                    Circle()
                        .fill(currentTool == tool ? Color.primary.opacity(0.12) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(tool.label)
    }

    // MARK: - Style Controls

    /// Whether the active context is a text tool/annotation.
    private var isTextContext: Bool {
        if currentTool == .text { return true }
        if let id = selectedAnnotationID,
           let ann = annotations.first(where: { $0.id == id }),
           ann.tool == .text { return true }
        return false
    }

    @State private var colorPopoverVisible = false
    @State private var sizePopoverVisible = false

    private var styleControls: some View {
        HStack(spacing: 0) {
            colorPicker
            Divider().frame(height: 16)
            sizePicker
        }
        .frame(height: 34)
        .padding(.horizontal, 4)
    }

    private var colorPicker: some View {
        Button {
            colorPopoverVisible.toggle()
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(currentStyle.strokeColor)
                    .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
                    .frame(width: 14, height: 14)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 40, height: 34)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .popover(isPresented: $colorPopoverVisible, arrowEdge: .bottom) {
            HStack(spacing: 6) {
                ForEach(presetColors, id: \.self) { color in
                    Circle()
                        .fill(color)
                        .overlay(
                            Circle().stroke(
                                currentStyle.strokeColor == color ? Color.accentColor : Color.primary.opacity(0.15),
                                lineWidth: currentStyle.strokeColor == color ? 2 : 0.5
                            )
                        )
                        .frame(width: 20, height: 20)
                        .onTapGesture {
                            currentStyle.strokeColor = color
                            applyStyleToSelection()
                            colorPopoverVisible = false
                        }
                }
            }
            .padding(10)
        }
    }

    private var sizePicker: some View {
        Button {
            sizePopoverVisible.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isTextContext ? "textformat.size" : "lineweight")
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                Text(isTextContext
                     ? "\(Int(currentStyle.fontSize))pt"
                     : "\(Int(currentStyle.strokeWidth))pt")
                    .font(.system(size: 12, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(height: 34)
            .padding(.horizontal, 8)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .popover(isPresented: $sizePopoverVisible, arrowEdge: .bottom) {
            if isTextContext {
                sizeOptions(
                    values: [14, 18, 24, 36, 48],
                    current: currentStyle.fontSize,
                    label: { "\($0)pt" }
                ) { value in
                    currentStyle.fontSize = value
                    applyStyleToSelection()
                    sizePopoverVisible = false
                }
            } else {
                sizeOptions(
                    values: [1, 2, 3, 5, 8],
                    current: currentStyle.strokeWidth,
                    label: { "\($0)pt" }
                ) { value in
                    currentStyle.strokeWidth = value
                    applyStyleToSelection()
                    sizePopoverVisible = false
                }
            }
        }
    }

    private func sizeOptions(
        values: [CGFloat],
        current: CGFloat,
        label: @escaping (Int) -> String,
        onSelect: @escaping (CGFloat) -> Void
    ) -> some View {
        HStack(spacing: 4) {
            ForEach(values, id: \.self) { value in
                let isSelected = current == value
                Button {
                    onSelect(value)
                } label: {
                    Text(label(Int(value)))
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .frame(minWidth: 32, minHeight: 24)
                        .padding(.horizontal, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
    }

    // MARK: - Crop Controls

    private var cropControls: some View {
        HStack(spacing: 4) {
            Button("Apply Crop", action: onApplyCrop)
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            Button("Cancel Crop", action: onCancelCrop)
                .controlSize(.small)
        }
        .frame(height: 34)
        .padding(.horizontal, 8)
    }

    // MARK: - Undo Button

    private var undoButton: some View {
        Button(action: onUndo) {
            Image(systemName: "arrow.uturn.backward")
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .help("Undo")
        .keyboardShortcut("z", modifiers: .command)
        .disabled(!canUndo)
        .focusable(false)
        .frame(height: 34)
        .padding(.horizontal, 4)
    }

    // MARK: - Helpers

    private func selectTool(_ tool: AnnotationTool) {
        if tool == .crop {
            isCropping = true
            currentTool = .crop
        } else {
            if isCropping {
                onCancelCrop()
            }
            currentTool = tool
        }
    }

    /// When user changes style while an annotation is selected, apply to that annotation.
    private func applyStyleToSelection() {
        guard let id = selectedAnnotationID,
              let idx = annotations.firstIndex(where: { $0.id == id })
        else { return }
        annotations[idx].style = currentStyle
    }
}
