import SwiftUI

/// The annotation toolbar displayed at the top of the editor.
struct EditorToolbarView: View {
    private let toolPillHeight: CGFloat = 36

    @Binding var currentTool: AnnotationTool
    @Binding var currentStyle: AnnotationStyle
    @Binding var isCropping: Bool
    @Binding var selectedAnnotationID: UUID?
    @Binding var annotations: [Annotation]

    var canUndo: Bool
    var hasTemplate: Bool
    @Binding var selectedGradient: BuiltInGradient?
    var onApplyCrop: () -> Void
    var onCancelCrop: () -> Void
    var onUndo: () -> Void
    var onDone: () -> Void

    /// The drawing tools available in the toolbar (excludes .select and .crop which are handled separately).
    private let drawingTools: [AnnotationTool] = [.freeDraw, .arrow, .rectangle, .circle, .line, .text, .measurement, .pixelate]

    /// Tools that use color/size style controls.
    private let stylingTools: [AnnotationTool] = [.arrow, .freeDraw, .measurement, .rectangle, .circle, .line, .text]

    /// Preset colors for the color picker.
    private let presetColors: [Color] = [
        .red, .orange, .yellow, .green, .blue, .purple, .white, .black
    ]

    /// Whether style controls should be visible: when using a styling tool or when a styled annotation is selected.
    private var showStyleControls: Bool {
        if stylingTools.contains(currentTool) { return true }
        if let id = selectedAnnotationID,
           let ann = annotations.first(where: { $0.id == id }),
           stylingTools.contains(ann.tool) { return true }
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

                // Background label + gradient picker (entire pill is the click target)
                if hasTemplate {
                    Button { gradientPopoverVisible.toggle() } label: {
                        HStack(spacing: 0) {
                            Text("Background")
                                .font(.system(size: 12))
                                .padding(.leading, 10)
                                .padding(.trailing, 6)
                            Divider().frame(height: 16)
                            gradientIndicator
                        }
                        .frame(height: toolPillHeight)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .glassEffect(in: Capsule())
                    .popover(isPresented: $gradientPopoverVisible, arrowEdge: .bottom) {
                        gradientPopoverContent
                    }
                }

                Spacer()

                // Undo button pill
                undoButton
                    .glassEffect(in: Capsule())

                // Done button
                doneButton
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
        .frame(height: toolPillHeight)
    }

    @ViewBuilder
    private func toolButton(_ tool: AnnotationTool) -> some View {
        let button = Button {
            if tool == .pixelate, currentTool == .pixelate {
                pixelatePopoverVisible.toggle()
                return
            }
            if tool == .arrow, currentTool == .arrow {
                arrowStylePopoverVisible.toggle()
                return
            }
            pixelatePopoverVisible = false
            arrowStylePopoverVisible = false
            selectTool(tool)
        } label: {
            Group {
                if let assetName = tool.customImageName {
                    Image(assetName)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: tool.systemImage)
                        .font(.system(size: 14))
                }
            }
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

        if tool == .pixelate {
            button
                .popover(isPresented: $pixelatePopoverVisible, arrowEdge: .bottom) {
                    pixelatePopoverContent
                }
        } else if tool == .arrow {
            button
                .popover(isPresented: $arrowStylePopoverVisible, arrowEdge: .bottom) {
                    arrowStylePopoverContent
                }
        } else {
            button
        }
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
    @State private var gradientPopoverVisible = false
    @State private var pixelatePopoverVisible = false
    @State private var arrowStylePopoverVisible = false

    private var styleControls: some View {
        HStack(spacing: 0) {
            colorPicker
            Divider().frame(height: 16)
            sizePicker
        }
        .frame(height: toolPillHeight)
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
            .frame(width: 40, height: toolPillHeight)
            .contentShape(Rectangle())
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
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .frame(width: 36, alignment: .trailing)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(height: toolPillHeight)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .popover(isPresented: $sizePopoverVisible, arrowEdge: .bottom) {
            if isTextContext {
                fontSizeSliderContent
            } else {
                strokeWidthSliderContent
            }
        }
    }

    private var fontSizeSliderContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Font Size")
                .font(.system(size: 12, weight: .medium))
            HStack(spacing: 8) {
                Slider(value: fontSizeBinding, in: 14...74)
                    .frame(width: 180)
                    .focusable(false)
                    .focusEffectDisabled()
                Text("\(Int(currentStyle.fontSize))pt")
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 36, alignment: .trailing)
            }
            .padding(.vertical, 2)
        }
        .padding(12)
    }

    private var fontSizeBinding: Binding<Double> {
        Binding(
            get: { Double(currentStyle.fontSize) },
            set: { newValue in
                currentStyle.fontSize = CGFloat(newValue.rounded())
                applyStyleToSelection()
            }
        )
    }

    private var strokeWidthSliderContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Stroke")
                .font(.system(size: 12, weight: .medium))
            HStack(spacing: 8) {
                Slider(value: strokeWidthBinding, in: 1...15)
                    .frame(width: 180)
                    .focusable(false)
                    .focusEffectDisabled()
                Text("\(Int(currentStyle.strokeWidth))px")
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 36, alignment: .trailing)
            }
            .padding(.vertical, 2)
        }
        .padding(12)
    }

    private var strokeWidthBinding: Binding<Double> {
        Binding(
            get: { Double(currentStyle.strokeWidth) },
            set: { newValue in
                currentStyle.strokeWidth = CGFloat(newValue.rounded())
                applyStyleToSelection()
            }
        )
    }

    // MARK: - Gradient Picker

    /// Circle + chevron shown inside the pill label.
    private var gradientIndicator: some View {
        HStack(spacing: 4) {
            if let gradient = selectedGradient {
                Circle()
                    .fill(gradient.swiftUIGradient)
                    .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
                    .frame(width: 14, height: 14)
            } else {
                noneCircle(size: 14)
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(width: 40, height: toolPillHeight)
    }

    /// Contents of the gradient popover.
    private var gradientPopoverContent: some View {
        HStack(spacing: 6) {
            // None / transparent option
            noneCircle(size: 20, isSelected: selectedGradient == nil)
                .help("No Background")
                .onTapGesture { selectedGradient = nil }

            // Built-in gradient options
            ForEach(BuiltInGradient.allCases) { gradient in
                Circle()
                    .fill(gradient.swiftUIGradient)
                    .overlay(
                        Circle().stroke(
                            selectedGradient == gradient ? Color.accentColor : Color.primary.opacity(0.15),
                            lineWidth: selectedGradient == gradient ? 2 : 0.5
                        )
                    )
                    .frame(width: 20, height: 20)
                    .help(gradient.displayName)
                    .onTapGesture { selectedGradient = gradient }
            }
        }
        .padding(10)
    }

    @ViewBuilder
    private func noneCircle(size: CGFloat, isSelected: Bool = false) -> some View {
        ZStack {
            Circle()
                .fill(.white)
                .overlay(
                    Circle().stroke(
                        isSelected ? Color.accentColor : Color.primary.opacity(0.2),
                        lineWidth: isSelected ? 2 : 0.5
                    )
                )
            Path { path in
                let inset = size * 0.2
                path.move(to: CGPoint(x: inset, y: size - inset))
                path.addLine(to: CGPoint(x: size - inset, y: inset))
            }
            .stroke(Color.red, lineWidth: max(1.0, size * 0.08))
            .clipShape(Circle())
        }
        .frame(width: size, height: size)
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

    // MARK: - Arrow Style Picker

    private var arrowStylePopoverContent: some View {
        HStack(spacing: 2) {
            ForEach(ArrowStyle.allCases, id: \.self) { style in
                let isSelected = currentStyle.arrowStyle == style
                Button {
                    currentStyle.arrowStyle = style
                    applyArrowStyleToSelection()
                    arrowStylePopoverVisible = false
                } label: {
                    VStack(spacing: 4) {
                        ArrowStylePreview(style: style, isSelected: isSelected)
                        Text(style.label)
                            .font(.system(size: 10))
                            .foregroundStyle(isSelected ? Color.accentColor : .primary)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
    }

    private func applyArrowStyleToSelection() {
        guard let id = selectedAnnotationID,
              let idx = annotations.firstIndex(where: { $0.id == id }),
              annotations[idx].tool == .arrow
        else { return }
        annotations[idx].style.arrowStyle = currentStyle.arrowStyle
    }

    private var pixelatePopoverContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pixelation")
                .font(.system(size: 12, weight: .medium))
            HStack(spacing: 8) {
                Slider(value: pixelationScaleBinding, in: 2...60)
                    .frame(width: 180)
                    .focusable(false)
                    .focusEffectDisabled()
                Text("\(Int(currentStyle.pixelationScale))")
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 28, alignment: .trailing)
            }
            .padding(.vertical, 2)
        }
        .padding(12)
    }

    private var pixelationScaleBinding: Binding<Double> {
        Binding(
            get: { Double(currentStyle.pixelationScale) },
            set: { newValue in
                currentStyle.pixelationScale = CGFloat(newValue.rounded())
                applyPixelationToSelection()
            }
        )
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
        .frame(height: toolPillHeight)
        .padding(.horizontal, 8)
    }

    // MARK: - Undo / Done Buttons

    private var doneButton: some View {
        Button(action: onDone) {
            Text("Done")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .frame(height: 34)
                .padding(.horizontal, 14)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("s", modifiers: .command)
        .focusable(false)
        .background(Color.accentColor, in: Capsule())
    }

    private var undoButton: some View {
        Button(action: onUndo) {
            Image(systemName: "arrow.uturn.backward")
                .frame(width: 28, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Undo")
        .keyboardShortcut("z", modifiers: .command)
        .disabled(!canUndo)
        .focusable(false)
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

    private func applyPixelationToSelection() {
        guard let id = selectedAnnotationID,
              let idx = annotations.firstIndex(where: { $0.id == id }),
              annotations[idx].tool == .pixelate
        else { return }
        annotations[idx].style.pixelationScale = currentStyle.pixelationScale
    }
}

// MARK: - Arrow style mini-preview (used inside the popover)

private struct ArrowStylePreview: View {
    let style: ArrowStyle
    let isSelected: Bool

    var body: some View {
        Canvas { ctx, size in
            let s = CGPoint(x: 6, y: size.height * 0.62)
            let e = CGPoint(x: size.width - 6, y: size.height * 0.38)
            let color = isSelected ? Color.accentColor : Color.primary
            let lw: CGFloat = 1.5

            switch style {
            case .chevron:
                var path = Path(); path.move(to: s); path.addLine(to: e)
                ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: lw, lineCap: .round))
                let ang = atan2(e.y - s.y, e.x - s.x), hl: CGFloat = 8, ha = CGFloat.pi / 4
                let p1 = CGPoint(x: e.x - hl * cos(ang - ha), y: e.y - hl * sin(ang - ha))
                let p2 = CGPoint(x: e.x - hl * cos(ang + ha), y: e.y - hl * sin(ang + ha))
                var head = Path()
                head.move(to: e); head.addLine(to: p1)
                head.move(to: e); head.addLine(to: p2)
                ctx.stroke(head, with: .color(color), style: StrokeStyle(lineWidth: lw, lineCap: .round))

            case .triangle:
                let ang = atan2(e.y - s.y, e.x - s.x), hl: CGFloat = 7, ha = CGFloat.pi / 4
                let depth = hl * cos(ha)
                let base = CGPoint(x: e.x - depth * cos(ang), y: e.y - depth * sin(ang))
                var shaft = Path(); shaft.move(to: s); shaft.addLine(to: base)
                ctx.stroke(shaft, with: .color(color), style: StrokeStyle(lineWidth: lw, lineCap: .round))
                let p1 = CGPoint(x: e.x - hl * cos(ang - ha), y: e.y - hl * sin(ang - ha))
                let p2 = CGPoint(x: e.x - hl * cos(ang + ha), y: e.y - hl * sin(ang + ha))
                var tri = Path(); tri.move(to: e); tri.addLine(to: p1); tri.addLine(to: p2); tri.closeSubpath()
                ctx.fill(tri, with: .color(color))

            case .curved:
                let dx = e.x - s.x, dy = e.y - s.y
                let cp = CGPoint(x: (s.x + e.x) / 2 + dy * 0.3, y: (s.y + e.y) / 2 - dx * 0.3)
                var shaft = Path(); shaft.move(to: s); shaft.addQuadCurve(to: e, control: cp)
                ctx.stroke(shaft, with: .color(color), style: StrokeStyle(lineWidth: lw, lineCap: .round))
                let ang = atan2(e.y - cp.y, e.x - cp.x), hl: CGFloat = 7, ha = CGFloat.pi / 5
                let p1 = CGPoint(x: e.x - hl * cos(ang - ha), y: e.y - hl * sin(ang - ha))
                let p2 = CGPoint(x: e.x - hl * cos(ang + ha), y: e.y - hl * sin(ang + ha))
                var tri = Path(); tri.move(to: e); tri.addLine(to: p1); tri.addLine(to: p2); tri.closeSubpath()
                ctx.fill(tri, with: .color(color))

            case .sketch:
                let ang = atan2(e.y - s.y, e.x - s.x)
                let len = hypot(e.x - s.x, e.y - s.y)
                let ca = cos(ang), sa = sin(ang)
                let cp1 = CGPoint(x: s.x + ca*len*0.3 + (-sa)*len*0.07,
                                  y: s.y + sa*len*0.3 + ca*len*0.07)
                let cp2 = CGPoint(x: s.x + ca*len*0.7 - (-sa)*len*0.05,
                                  y: s.y + sa*len*0.7 - ca*len*0.05)
                var shaft = Path(); shaft.move(to: s); shaft.addCurve(to: e, control1: cp1, control2: cp2)
                ctx.stroke(shaft, with: .color(color), style: StrokeStyle(lineWidth: lw, lineCap: .round))
                let hl: CGFloat = 10, ha = CGFloat.pi / 5
                let p1 = CGPoint(x: e.x - hl * cos(ang - ha), y: e.y - hl * sin(ang - ha))
                let p2 = CGPoint(x: e.x - hl * cos(ang + ha), y: e.y - hl * sin(ang + ha))
                var head = Path()
                head.move(to: e); head.addLine(to: p1)
                head.move(to: e); head.addLine(to: p2)
                ctx.stroke(head, with: .color(color), style: StrokeStyle(lineWidth: lw, lineCap: .round))
            }
        }
        .frame(width: 44, height: 26)
    }
}

// MARK: - BuiltInGradient SwiftUI helpers

private extension BuiltInGradient {
    /// A top-leading → bottom-trailing linear gradient for preview circles.
    var swiftUIGradient: LinearGradient {
        let def = gradientDefinition
        let colors = def.colors.map {
            Color(red: $0.red, green: $0.green, blue: $0.blue, opacity: $0.alpha)
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
