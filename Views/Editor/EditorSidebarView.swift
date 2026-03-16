import SwiftUI
import UniformTypeIdentifiers

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

    @Binding var selectedWallpaper: WallpaperSource?
    @Binding var padding: Int
    @Binding var cornerRadius: Int
    @Binding var shadowIntensity: Double
    @Binding var screenshotAlignment: CanvasAlignment

    let aspectRatios: [AspectRatio]
    @Binding var selectedAspectRatioID: UUID?

    var hasTemplate: Bool
    var customBackgroundImages: [String]
    var onAddCustomImage: () -> Void
    var onRemoveCustomImage: (String) -> Void
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
    @State private var shapeStylePopoverVisible = false
    @State private var spotlightPopoverVisible = false
    @State private var backgroundTypePopoverVisible = false
    @State private var backgroundType: BackgroundType = .gradients

    enum BackgroundType: String, CaseIterable, Identifiable {
        case gradients = "Gradients"
        case solidColors = "Solid Colors"
        var id: String { rawValue }
    }

    private let presetColors: [Color] = [
        .red, .orange, .yellow, .green, .blue, .purple, .white, .black
    ]

    private let drawingTools: [AnnotationTool] = [
        .select, .freeDraw, .arrow, .rectangle, .circle, .line, .text, .measurement, .pixelate, .spotlight, .crop
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
            sectionLabel("Tools")
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
            Button { backgroundTypePopoverVisible.toggle() } label: {
                HStack(spacing: 4) {
                    Text("Backgrounds")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .popover(isPresented: $backgroundTypePopoverVisible, arrowEdge: .bottom) {
                backgroundTypePopoverContent
            }

            let items = backgroundType == .gradients ? BuiltInGradient.gradients : BuiltInGradient.solidColors
            let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)
            LazyVGrid(columns: columns, spacing: 6) {
                noneCell
                ForEach(items) { gradient in
                    gradientCell(gradient)
                }
                ForEach(customBackgroundImages, id: \.self) { path in
                    customImageCell(path: path)
                }
                customImagePickerButton
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
                    let xRange = cellW - dotW
                    let yRange = cellH - dotH
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.4))
                        .frame(width: dotW, height: dotH)
                        .offset(
                            x: xRange * alignment.horizontalFraction,
                            y: yRange * alignment.verticalFraction
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
        let button = Button {
            if tool == .spotlight, currentTool == .spotlight {
                spotlightPopoverVisible.toggle()
                return
            }
            if tool == .pixelate, currentTool == .pixelate {
                pixelatePopoverVisible.toggle()
                return
            }
            if tool == .arrow, currentTool == .arrow {
                arrowStylePopoverVisible.toggle()
                return
            }
            if (tool == .rectangle || tool == .circle), currentTool == tool {
                shapeStylePopoverVisible.toggle()
                return
            }
            pixelatePopoverVisible = false
            arrowStylePopoverVisible = false
            shapeStylePopoverVisible = false
            spotlightPopoverVisible = false
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

        if tool == .spotlight {
            button
                .popover(isPresented: $spotlightPopoverVisible, arrowEdge: .trailing) {
                    spotlightPopoverContent
                }
        } else if tool == .pixelate {
            button
                .popover(isPresented: $pixelatePopoverVisible, arrowEdge: .trailing) {
                    pixelatePopoverContent
                }
        } else if tool == .arrow {
            button
                .popover(isPresented: $arrowStylePopoverVisible, arrowEdge: .trailing) {
                    arrowStylePopoverContent
                }
        } else if tool == .rectangle || tool == .circle {
            button
                .popover(isPresented: $shapeStylePopoverVisible, arrowEdge: .trailing) {
                    shapeStylePopoverContent
                }
        } else {
            button
        }
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

    // MARK: - Arrow Style Popover

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

    // MARK: - Pixelate Popover

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

    private func applyPixelationToSelection() {
        guard let id = selectedAnnotationID,
              let idx = annotations.firstIndex(where: { $0.id == id }),
              annotations[idx].tool == .pixelate
        else { return }
        annotations[idx].style.pixelationScale = currentStyle.pixelationScale
    }

    // MARK: - Spotlight Opacity Popover

    private var spotlightPopoverContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Dim Opacity")
                .font(.system(size: 12, weight: .medium))
            HStack(spacing: 8) {
                Slider(value: spotlightOpacityBinding, in: 0.1...0.9)
                    .frame(width: 180)
                    .focusable(false)
                    .focusEffectDisabled()
                Text("\(Int(currentStyle.spotlightOpacity * 100))%")
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 36, alignment: .trailing)
            }
            .padding(.vertical, 2)
        }
        .padding(12)
    }

    private var spotlightOpacityBinding: Binding<Double> {
        Binding(
            get: { Double(currentStyle.spotlightOpacity) },
            set: { newValue in
                currentStyle.spotlightOpacity = CGFloat(newValue)
                applySpotlightOpacityToSelection()
            }
        )
    }

    private func applySpotlightOpacityToSelection() {
        guard let id = selectedAnnotationID,
              let idx = annotations.firstIndex(where: { $0.id == id }),
              annotations[idx].tool == .spotlight
        else { return }
        annotations[idx].style.spotlightOpacity = currentStyle.spotlightOpacity
    }

    // MARK: - Shape Style Popover (Rectangle / Circle fill toggle)

    private var shapeStylePopoverContent: some View {
        HStack(spacing: 2) {
            shapeStyleOption(filled: false, label: "Outline", icon: currentTool == .circle ? "circle" : "rectangle")
            shapeStyleOption(filled: true, label: "Filled", icon: currentTool == .circle ? "circle.fill" : "rectangle.fill")
        }
        .padding(8)
    }

    private func shapeStyleOption(filled: Bool, label: String, icon: String) -> some View {
        let isSelected = currentStyle.fillShape == filled
        return Button {
            currentStyle.fillShape = filled
            applyStyleToSelection()
            shapeStylePopoverVisible = false
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? Color.accentColor : .primary)
                    .frame(width: 44, height: 26)
                Text(label)
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

    // MARK: - Background Type Popover

    private var backgroundTypePopoverContent: some View {
        VStack(spacing: 2) {
            backgroundTypeButton(.gradients)
            backgroundTypeButton(.solidColors)
        }
        .padding(6)
        .frame(width: 160)
    }

    private func backgroundTypeButton(_ type: BackgroundType) -> some View {
        let isSelected = backgroundType == type
        return Button {
            backgroundType = type
            backgroundTypePopoverVisible = false
        } label: {
            HStack {
                Text(type.rawValue)
                    .font(.system(size: 12))
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Gradient Cells

    private var noneCell: some View {
        Button {
            selectedWallpaper = nil
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.white)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8).stroke(
                            selectedWallpaper == nil ? Color.accentColor : Color.primary.opacity(0.2),
                            lineWidth: selectedWallpaper == nil ? 2 : 0.5
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

    private func isGradientSelected(_ gradient: BuiltInGradient) -> Bool {
        if case .builtInGradient(let current) = selectedWallpaper {
            return current == gradient
        }
        return false
    }

    private func gradientCell(_ gradient: BuiltInGradient) -> some View {
        let isSelected = isGradientSelected(gradient)
        return Button {
            selectedWallpaper = .builtInGradient(gradient)
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

    private func isCustomImageSelected(_ path: String) -> Bool {
        if case .customImage(let current) = selectedWallpaper {
            return current == path
        }
        return false
    }

    private func customImageCell(path: String) -> some View {
        let isSelected = isCustomImageSelected(path)
        return Button {
            selectedWallpaper = .customImage(path: path)
        } label: {
            if let nsImage = NSImage(contentsOfFile: path) {
                Color.clear
                    .frame(height: 44)
                    .overlay(
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8).stroke(
                            isSelected ? Color.accentColor : Color.primary.opacity(0.15),
                            lineWidth: isSelected ? 2 : 0.5
                        )
                    )
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.3))
                    .frame(height: 44)
            }
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help("Custom Image")
        .contextMenu {
            Button(role: .destructive) {
                if isSelected {
                    selectedWallpaper = nil
                }
                onRemoveCustomImage(path)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    /// Button to add a custom background image, shown inline in the grid.
    private var customImagePickerButton: some View {
        Button {
            onAddCustomImage()
        } label: {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    Image(systemName: "plus")
                        .font(.system(size: 17))
                        .foregroundStyle(.primary)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8).stroke(
                        Color.primary.opacity(0.15), lineWidth: 0.5
                    )
                )
                .frame(height: 44)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help("Add Custom Image")
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
