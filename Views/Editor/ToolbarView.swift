import SwiftUI
import UniformTypeIdentifiers

/// The annotation toolbar displayed at the top of the editor.
struct EditorToolbarView: View {
    private let toolPillHeight: CGFloat = 36

    var showProSidebar: Bool
    @Binding var currentTool: AnnotationTool
    @Binding var currentStyle: AnnotationStyle
    @Binding var isCropping: Bool
    @Binding var selectedAnnotationID: UUID?
    @Binding var annotations: [Annotation]

    var hasTemplate: Bool
    @Binding var selectedWallpaper: WallpaperSource?
    var customBackgroundImages: [String]
    var onAddCustomImage: () -> Void
    var onRemoveCustomImage: (String) -> Void
    var onApplyCrop: () -> Void
    var onCancelCrop: () -> Void

    /// The drawing tools available in the toolbar (excludes .select and .crop which are handled separately).
    private let drawingTools: [AnnotationTool] = [.freeDraw, .arrow, .rectangle, .circle, .line, .text, .measurement, .pixelate, .spotlight]

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
        Group {
            if !showProSidebar {
                // Tool controls shown only in simple mode (pro mode uses sidebar).
                // No outer GlassEffectContainer — the NSToolbar is the outer glass layer.
                // Each pill renders its own glass via .glassEffect(in: Capsule()).
                HStack(spacing: 6) {
                    // Tool picker
                    toolPicker

                    // Crop controls (shown while cropping)
                    if isCropping {
                        cropControls
                    }

                    // Style controls
                    if showStyleControls {
                        styleControls
                    }

                    // Background label + gradient picker
                    if hasTemplate {
                        Button {
                            gradientPopoverVisible.toggle()
                        } label: {
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
                        .popover(isPresented: $gradientPopoverVisible, arrowEdge: .bottom) {
                            gradientPopoverContent
                        }
                    }
                }
            }
        }
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
            if tool == .rectangle, currentTool == .rectangle {
                rectStylePopoverVisible.toggle()
                return
            }
            if tool == .circle, currentTool == .circle {
                circleStylePopoverVisible.toggle()
                return
            }
            pixelatePopoverVisible = false
            arrowStylePopoverVisible = false
            rectStylePopoverVisible = false
            circleStylePopoverVisible = false
            spotlightPopoverVisible = false
            selectTool(tool)
        } label: {
            Group {
                if let assetName = tool.customImageName {
                    Image(assetName)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 14, height: 14)
                } else if tool == .arrow {
                    ArrowStylePreview(
                        style: currentStyle.arrowStyle,
                        isSelected: currentTool == tool,
                        previewSize: CGSize(width: 26, height: 18)
                    )
                } else if tool == .rectangle || tool == .circle {
                    let isFilled = tool == .circle ? currentStyle.fillCircle : currentStyle.fillRect
                    let fillIcon = tool == .circle ? "circle.fill" : "rectangle.fill"
                    Image(systemName: isFilled ? fillIcon : tool.systemImage)
                        .font(.system(size: 14))
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
            .overlay(alignment: .bottom) {
                if currentTool == tool && hasSecondaryOptions(tool) {
                    Image(systemName: "chevron.compact.down")
                        .font(.system(size: 7, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .help(currentTool == tool && hasSecondaryOptions(tool) ? "Click again to change style" : tool.label)

        if tool == .spotlight {
            button
                .popover(isPresented: $spotlightPopoverVisible, arrowEdge: .bottom) {
                    spotlightPopoverContent
                }
        } else if tool == .pixelate {
            button
                .popover(isPresented: $pixelatePopoverVisible, arrowEdge: .bottom) {
                    pixelatePopoverContent
                }
        } else if tool == .arrow {
            button
                .popover(isPresented: $arrowStylePopoverVisible, arrowEdge: .bottom) {
                    arrowStylePopoverContent
                }
        } else if tool == .rectangle {
            button
                .popover(isPresented: $rectStylePopoverVisible, arrowEdge: .bottom) {
                    shapeStylePopoverContent
                }
        } else if tool == .circle {
            button
                .popover(isPresented: $circleStylePopoverVisible, arrowEdge: .bottom) {
                    shapeStylePopoverContent
                }
        } else {
            button
        }
    }

    // MARK: - Style Controls

    /// Whether the active context uses font size instead of stroke width.
    private var usesFontSizeContext: Bool {
        if currentTool == .text || currentTool == .numberedStep { return true }
        if let id = selectedAnnotationID,
           let ann = annotations.first(where: { $0.id == id }),
           (ann.tool == .text || ann.tool == .numberedStep) { return true }
        return false
    }

    @State private var colorPopoverVisible = false
    @State private var sizePopoverVisible = false
    @State private var gradientPopoverVisible = false
    @State private var pixelatePopoverVisible = false
    @State private var arrowStylePopoverVisible = false
    @State private var rectStylePopoverVisible = false
    @State private var circleStylePopoverVisible = false
    @State private var spotlightPopoverVisible = false

    private var styleControls: some View {
        HStack(spacing: 0) {
            colorPicker
            Divider().frame(height: 16)
            sizePicker
        }
        .frame(height: toolPillHeight)
        .padding(.horizontal, 4)
    }

    private var strokeColorBinding: Binding<Color> {
        Binding(
            get: { currentStyle.strokeColor },
            set: { newColor in
                currentStyle.strokeColor = newColor
                applyStyleToSelection()
            }
        )
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
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $colorPopoverVisible, arrowEdge: .bottom) {
            HStack(spacing: 6) {
                ForEach(presetColors, id: \.self) { color in
                    Button {
                        currentStyle.strokeColor = color
                        applyStyleToSelection()
                        colorPopoverVisible = false
                    } label: {
                        Circle()
                            .fill(color)
                            .overlay(
                                Circle().stroke(
                                    currentStyle.strokeColor == color ? Color.accentColor : Color.primary.opacity(0.15),
                                    lineWidth: currentStyle.strokeColor == color ? 2 : 0.5
                                )
                            )
                            .frame(width: 20, height: 20)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
                Rectangle()
                    .fill(Color.primary.opacity(0.15))
                    .frame(width: 1, height: 20)
                    .padding(.horizontal, 2)
                RainbowColorPickerButton(color: strokeColorBinding)
            }
            .padding(10)
        }
    }

    private var sizePicker: some View {
        Button {
            sizePopoverVisible.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: usesFontSizeContext ? "textformat.size" : "lineweight")
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                Text(usesFontSizeContext
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
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $sizePopoverVisible, arrowEdge: .bottom) {
            if usesFontSizeContext {
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
            if let wallpaper = selectedWallpaper {
                wallpaperIndicatorCircle(wallpaper, size: 14)
            } else {
                noneCircle(size: 14)
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(width: 40, height: toolPillHeight)
    }

    @ViewBuilder
    private func wallpaperIndicatorCircle(_ wallpaper: WallpaperSource, size: CGFloat) -> some View {
        switch wallpaper {
        case .builtInGradient(let gradient):
            Circle()
                .fill(gradient.swiftUIGradient)
                .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
                .frame(width: size, height: size)
        case .customImage(let path):
            if let nsImage = NSImage(contentsOfFile: path) {
                Color.clear
                    .frame(width: size, height: size)
                    .overlay(
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    )
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
            } else {
                Circle()
                    .fill(Color.gray)
                    .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
                    .frame(width: size, height: size)
            }
        case .customColor(let color):
            Circle()
                .fill(Color(red: color.red, green: color.green, blue: color.blue, opacity: color.alpha))
                .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
                .frame(width: size, height: size)
        }
    }

    private func isGradientSelected(_ gradient: BuiltInGradient) -> Bool {
        if case .builtInGradient(let current) = selectedWallpaper {
            return current == gradient
        }
        return false
    }

    /// Contents of the gradient popover.
    private var gradientPopoverContent: some View {
        let circleSize: CGFloat = 20
        let spacing: CGFloat = 6
        let columns = Array(repeating: GridItem(.fixed(circleSize), spacing: spacing), count: 7)

        return LazyVGrid(columns: columns, spacing: spacing) {
            Button {
                selectedWallpaper = nil
            } label: {
                noneCircle(size: circleSize, isSelected: selectedWallpaper == nil)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("No Background")

            ForEach(BuiltInGradient.allCases) { gradient in
                Button {
                    selectedWallpaper = .builtInGradient(gradient)
                } label: {
                    Circle()
                        .fill(gradient.swiftUIGradient)
                        .overlay(
                            Circle().stroke(
                                isGradientSelected(gradient) ? Color.accentColor : Color.primary.opacity(0.15),
                                lineWidth: isGradientSelected(gradient) ? 2 : 0.5
                            )
                        )
                        .frame(width: circleSize, height: circleSize)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(gradient.displayName)
            }

            ForEach(customBackgroundImages, id: \.self) { path in
                customImageCircle(path: path, size: circleSize)
            }

            Button {
                onAddCustomImage()
            } label: {
                Circle()
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(
                        Image(systemName: "plus")
                            .font(.system(size: circleSize * 0.5))
                            .foregroundStyle(.primary)
                    )
                    .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
                    .frame(width: circleSize, height: circleSize)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Add Custom Image")
        }
        .padding(10)
    }

    private func isCustomImageSelected(_ path: String) -> Bool {
        if case .customImage(let current) = selectedWallpaper {
            return current == path
        }
        return false
    }

    @ViewBuilder
    private func customImageCircle(path: String, size: CGFloat) -> some View {
        let isSelected = isCustomImageSelected(path)
        Button {
            selectedWallpaper = .customImage(path: path)
        } label: {
            if let nsImage = NSImage(contentsOfFile: path) {
                Color.clear
                    .frame(width: size, height: size)
                    .overlay(
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    )
                    .clipShape(Circle())
                    .overlay(
                        Circle().stroke(
                            isSelected ? Color.accentColor : Color.primary.opacity(0.15),
                            lineWidth: isSelected ? 2 : 0.5
                        )
                    )
                    .contentShape(Circle())
            } else {
                Circle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: size, height: size)
                    .contentShape(Circle())
            }
        }
        .buttonStyle(.plain)
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
                        .contentShape(RoundedRectangle(cornerRadius: 5))
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
                    .contentShape(RoundedRectangle(cornerRadius: 6))
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
                applySpotlightOpacityToAll()
            }
        )
    }

    private func applySpotlightOpacityToAll() {
        for idx in annotations.indices where annotations[idx].tool == .spotlight {
            annotations[idx].style.spotlightOpacity = currentStyle.spotlightOpacity
        }
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
        let currentFill = currentTool == .circle ? currentStyle.fillCircle : currentStyle.fillRect
        let isSelected = currentFill == filled
        return Button {
            if currentTool == .circle {
                currentStyle.fillCircle = filled
            } else {
                currentStyle.fillRect = filled
            }
            applyStyleToSelection()
            rectStylePopoverVisible = false
            circleStylePopoverVisible = false
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
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
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

    // MARK: - Helpers

    private func hasSecondaryOptions(_ tool: AnnotationTool) -> Bool {
        tool == .arrow || tool == .rectangle || tool == .circle || tool == .pixelate
    }

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

struct ArrowStylePreview: View {
    let style: ArrowStyle
    let isSelected: Bool
    var previewSize: CGSize = CGSize(width: 44, height: 26)

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
        .frame(width: previewSize.width, height: previewSize.height)
    }
}

// MARK: - Scroll Wheel Modifier

/// Captures NSEvent scrollWheel events on a view and calls a handler with the direction (-1 or +1).
private struct ScrollWheelModifier: ViewModifier {
    let handler: (_ direction: Int) -> Void

    func body(content: Content) -> some View {
        content.overlay(ScrollWheelReceiver(handler: handler))
    }
}

private struct ScrollWheelReceiver: NSViewRepresentable {
    let handler: (_ direction: Int) -> Void

    func makeNSView(context: Context) -> ScrollWheelNSView {
        let view = ScrollWheelNSView()
        view.handler = handler
        return view
    }

    func updateNSView(_ nsView: ScrollWheelNSView, context: Context) {
        nsView.handler = handler
    }
}

private class ScrollWheelNSView: NSView {
    var handler: ((_ direction: Int) -> Void)?
    private var accumulated: CGFloat = 0
    private var resetTask: DispatchWorkItem?

    override var acceptsFirstResponder: Bool { true }

    override func scrollWheel(with event: NSEvent) {
        let dx: CGFloat
        let dy: CGFloat

        if event.hasPreciseScrollingDeltas {
            // Trackpad: pixel-level deltas, accumulate before firing
            dx = event.scrollingDeltaX
            dy = event.scrollingDeltaY
        } else {
            // Discrete mouse wheel: small integer values (typically ±1),
            // multiply to reach threshold quickly
            dx = event.scrollingDeltaX * 20
            dy = event.scrollingDeltaY * 20
        }

        let scroll = abs(dx) > abs(dy) ? dx : dy
        accumulated += scroll

        // Reset accumulation after a pause
        resetTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            self?.accumulated = 0
        }
        resetTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: task)

        let threshold: CGFloat = 15
        if abs(accumulated) >= threshold {
            handler?(accumulated > 0 ? -1 : 1)
            accumulated = 0
        }
    }
}

private extension View {
    func onScrollWheel(_ handler: @escaping (_ direction: Int) -> Void) -> some View {
        modifier(ScrollWheelModifier(handler: handler))
    }
}

// MARK: - Rainbow Color Picker Button

/// A circular color-wheel button that opens NSColorPanel.
/// Use `color` binding to read/write the selected color.
struct RainbowColorPickerButton: View {
    @Binding var color: Color

    private static let wheelColors: [Color] = [
        .red, Color(hue: 0.08, saturation: 1, brightness: 1),
        .yellow, Color(hue: 0.25, saturation: 1, brightness: 1),
        .green, Color(hue: 0.5, saturation: 1, brightness: 1),
        .cyan, .blue,
        Color(hue: 0.75, saturation: 1, brightness: 1),
        .purple, .pink, .red
    ]

    var body: some View {
        Button {
            let panel = NSColorPanel.shared
            panel.color = NSColor(color)
            panel.isContinuous = true
            panel.orderFront(nil)
        } label: {
            Circle()
                .fill(AngularGradient(colors: Self.wheelColors, center: .center))
                .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
                .frame(width: 20, height: 20)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Custom Color")
        .onReceive(NotificationCenter.default.publisher(for: NSColorPanel.colorDidChangeNotification)) { _ in
            guard NSColorPanel.shared.isVisible else { return }
            color = Color(nsColor: NSColorPanel.shared.color)
        }
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
