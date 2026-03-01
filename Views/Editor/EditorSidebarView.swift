import SwiftUI

/// The pro-mode sidebar panel shown when the user toggles the sidebar button.
/// Replaces the compact floating toolbar with grouped, labeled sections.
struct EditorSidebarView: View {

    // MARK: - Bindings from EditorView

    @Binding var showProSidebar: Bool
    @Binding var currentTool: AnnotationTool
    @Binding var currentStyle: AnnotationStyle
    @Binding var selectedAnnotationID: UUID?
    @Binding var annotations: [Annotation]
    @Binding var isCropping: Bool

    @Binding var selectedGradient: BuiltInGradient?
    @Binding var padding: Int
    @Binding var cornerRadius: Int
    @Binding var shadowIntensity: Double
    @Binding var screenshotAlignment: CanvasAlignment

    let aspectRatios: [AspectRatio]
    @Binding var selectedAspectRatioID: UUID?

    var hasTemplate: Bool
    var canUndo: Bool
    var onApplyCrop: () -> Void
    var onCancelCrop: () -> Void
    var onUndo: () -> Void
    var onDone: () -> Void

    // MARK: - Local state

    @State private var colorPopoverVisible = false
    @State private var sizePopoverVisible = false
    @State private var pixelatePopoverVisible = false
    @State private var arrowStylePopoverVisible = false

    private let presetColors: [Color] = [
        .red, .orange, .yellow, .green, .blue, .purple, .white, .black
    ]

    private let drawingTools: [AnnotationTool] = [
        .select, .freeDraw, .arrow, .rectangle, .circle, .line, .text, .measurement, .pixelate, .crop
    ]

    private let stylingTools: [AnnotationTool] = [
        .arrow, .freeDraw, .measurement, .rectangle, .circle, .line, .text
    ]

    private var showStyleControls: Bool {
        if stylingTools.contains(currentTool) { return true }
        if let id = selectedAnnotationID,
           let ann = annotations.first(where: { $0.id == id }),
           stylingTools.contains(ann.tool) { return true }
        return false
    }

    private var isTextContext: Bool {
        if currentTool == .text { return true }
        if let id = selectedAnnotationID,
           let ann = annotations.first(where: { $0.id == id }),
           ann.tool == .text { return true }
        return false
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    toolsSection
                    sectionDivider
                    if showStyleControls {
                        styleSection
                        sectionDivider
                    }
                    if isCropping {
                        cropSection
                        sectionDivider
                    }
                    if hasTemplate {
                        backgroundsSection
                        sectionDivider
                        paddingSection
                        sectionDivider
                        shadowCornersSection
                        sectionDivider
                        alignmentRatioSection
                        sectionDivider
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 16)
            }
        }
    }

    // MARK: - Sections

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Shapes and lines")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 5), spacing: 4) {
                ForEach(drawingTools) { tool in
                    sidebarToolButton(tool)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var styleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Color and size")
            HStack(spacing: 8) {
                colorButton
                sizePicker
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var cropSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Crop")
            HStack(spacing: 8) {
                Button("Apply", action: onApplyCrop)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Cancel", action: onCancelCrop)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var backgroundsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Backgrounds")
            // Gradient grid — 4 columns of rounded-square thumbnails
            let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)
            LazyVGrid(columns: columns, spacing: 6) {
                // "None" cell
                noneCell
                // Gradient cells
                ForEach(BuiltInGradient.allCases) { gradient in
                    gradientCell(gradient)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var paddingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Padding")
            HStack(spacing: 8) {
                Slider(value: paddingBinding, in: 20...200)
                    .focusable(false)
                    .focusEffectDisabled()
                Text("\(padding)px")
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 40, alignment: .trailing)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var shadowCornersSection: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("Shadow")
                Slider(value: $shadowIntensity, in: 0...1)
                    .focusable(false)
                    .focusEffectDisabled()
            }
            .frame(maxWidth: .infinity)

            Divider()
                .padding(.horizontal, 10)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("Corners")
                Slider(value: cornerRadiusBinding, in: 0...50)
                    .focusable(false)
                    .focusEffectDisabled()
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var alignmentRatioSection: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("Alignment")
                alignmentGrid
            }
            .frame(maxWidth: .infinity)

            Divider()
                .padding(.horizontal, 10)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("Ratio")
                Picker("", selection: $selectedAspectRatioID) {
                    Text("Auto")
                        .tag(Optional<UUID>.none)
                    ForEach(aspectRatios) { ratio in
                        Text(ratio.label)
                            .tag(Optional(ratio.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Alignment Grid

    private var alignmentGrid: some View {
        let cells: [CanvasAlignment] = [
            .topLeft,    .topCenter,    .topRight,
            .middleLeft, .middleCenter, .middleRight,
            .bottomLeft, .bottomCenter, .bottomRight
        ]
        return VStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 2) {
                    ForEach(0..<3, id: \.self) { col in
                        let cell = cells[row * 3 + col]
                        alignmentCell(cell)
                    }
                }
            }
        }
    }

    private func alignmentCell(_ alignment: CanvasAlignment) -> some View {
        let isSelected = screenshotAlignment == alignment
        return Button {
            screenshotAlignment = alignment
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 3)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
                    )
                // Mini rectangle showing the screenshot position
                GeometryReader { geo in
                    let cellW = geo.size.width
                    let cellH = geo.size.height
                    let dotW = cellW * 0.55
                    let dotH = cellH * 0.45
                    let margin: CGFloat = 3
                    let xRange = cellW - dotW - margin * 2
                    let yRange = cellH - dotH - margin * 2
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.4))
                        .frame(width: dotW, height: dotH)
                        .offset(
                            x: margin + xRange * alignment.horizontalFraction,
                            y: margin + yRange * alignment.verticalFraction
                        )
                }
            }
            .frame(width: 26, height: 22)
        }
        .buttonStyle(.plain)
        .focusable(false)
    }

    // MARK: - Tool Button

    @ViewBuilder
    private func sidebarToolButton(_ tool: AnnotationTool) -> some View {
        let isActive = currentTool == tool
        Button {
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
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? Color.primary.opacity(0.12) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(tool.label)
    }

    // MARK: - Color Button

    private var colorButton: some View {
        Button { colorPopoverVisible.toggle() } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(currentStyle.strokeColor)
                    .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
                    .frame(width: 16, height: 16)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
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
        Button { sizePopoverVisible.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: isTextContext ? "textformat.size" : "lineweight")
                    .font(.system(size: 12))
                Text(isTextContext
                     ? "\(Int(currentStyle.fontSize))pt"
                     : "\(Int(currentStyle.strokeWidth))pt")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
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

    private var fontSizeSliderContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Font Size")
                .font(.system(size: 12, weight: .medium))
            HStack(spacing: 8) {
                Slider(value: fontSizeBinding, in: 12...120)
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

    // MARK: - Gradient Cells

    private var noneCell: some View {
        Button {
            selectedGradient = nil
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.white)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8).stroke(
                            selectedGradient == nil ? Color.accentColor : Color.primary.opacity(0.2),
                            lineWidth: selectedGradient == nil ? 2 : 0.5
                        )
                    )
                Path { path in
                    path.move(to: CGPoint(x: 8, y: 36))
                    path.addLine(to: CGPoint(x: 36, y: 8))
                }
                .stroke(Color.red, lineWidth: 1.5)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .frame(height: 44)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help("No Background")
    }

    private func gradientCell(_ gradient: BuiltInGradient) -> some View {
        let isSelected = selectedGradient == gradient
        return Button {
            selectedGradient = gradient
        } label: {
            RoundedRectangle(cornerRadius: 8)
                .fill(gradient.swiftUIGradient)
                .overlay(
                    RoundedRectangle(cornerRadius: 8).stroke(
                        isSelected ? Color.accentColor : Color.primary.opacity(0.15),
                        lineWidth: isSelected ? 2 : 0.5
                    )
                )
                .frame(height: 44)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(gradient.displayName)
    }

    // MARK: - Helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
    }

    private var sectionDivider: some View {
        Divider()
    }

    private func selectTool(_ tool: AnnotationTool) {
        if tool == .crop {
            isCropping = true
            currentTool = .crop
        } else {
            if isCropping { onCancelCrop() }
            currentTool = tool
        }
    }

    private func applyStyleToSelection() {
        guard let id = selectedAnnotationID,
              let idx = annotations.firstIndex(where: { $0.id == id })
        else { return }
        annotations[idx].style = currentStyle
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

    private var strokeWidthBinding: Binding<Double> {
        Binding(
            get: { Double(currentStyle.strokeWidth) },
            set: { newValue in
                currentStyle.strokeWidth = CGFloat(newValue.rounded())
                applyStyleToSelection()
            }
        )
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
}

// MARK: - BuiltInGradient SwiftUI helpers (sidebar)

private extension BuiltInGradient {
    var swiftUIGradient: LinearGradient {
        let def = gradientDefinition
        let colors = def.colors.map {
            Color(red: $0.red, green: $0.green, blue: $0.blue, opacity: $0.alpha)
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
