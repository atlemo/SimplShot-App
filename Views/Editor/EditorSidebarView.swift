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
    let editorTemplates: [EditorTemplatePreset]
    @Binding var selectedEditorTemplateID: UUID?
    var hasUnsavedTemplateChanges: Bool

    var hasTemplate: Bool
    var customBackgroundImages: [String]
    var onAddCustomImage: () -> Void
    var onRemoveCustomImage: (String) -> Void
    var customColors: [CodableColor]
    var onAddCustomColor: (CodableColor) -> Void
    var onRemoveCustomColor: (CodableColor) -> Void
    var onOverwriteTemplate: () -> Void
    var onSaveAsNewTemplate: () -> Void
    var canUndo: Bool
    var onApplyCrop: () -> Void
    var onCancelCrop: () -> Void
    var onUndo: () -> Void
    var onDone: () -> Void

    @Binding var watermarkSettings: WatermarkSettings
    var onPickWatermarkImage: () -> Void

    // MARK: - Local state

    @State private var colorPopoverVisible = false
    @State private var sizePopoverVisible = false
    @State private var pixelatePopoverVisible = false
    @State private var arrowStylePopoverVisible = false
    @State private var rectStylePopoverVisible = false
    @State private var circleStylePopoverVisible = false
    @State private var spotlightPopoverVisible = false
    @State private var hoveredTool: AnnotationTool? = nil
    @State private var hoveredSection: SidebarSection? = nil
    @AppStorage(Constants.UserDefaultsKeys.editorSidebarCollapsedSections)
    private var collapsedSectionsStorage: String = ""
    @AppStorage(Constants.UserDefaultsKeys.editorSidebarBackgroundType)
    private var backgroundTypeRawValue: String = BackgroundType.gradients.rawValue

    private enum SidebarSection: String, Hashable {
        case templates
        case tools
        case crop
        case backgrounds
        case shadowCorners
        case alignmentRatio
        case watermark
    }

    enum BackgroundType: String, CaseIterable, Identifiable {
        case gradients = "Gradients"
        case solidColors = "Solid Colors"
        var id: String { rawValue }
    }

    private var backgroundType: BackgroundType {
        BackgroundType(rawValue: backgroundTypeRawValue) ?? .gradients
    }

    private let presetColors: [Color] = [
        .red, .orange, .yellow, .green, .blue, .purple, .white, .black
    ]

    private let drawingTools: [AnnotationTool] = [
        .select, .freeDraw, .arrow, .rectangle, .circle, .line, .text, .numberedStep, .measurement, .pixelate, .spotlight, .crop
    ]

    private let stylingTools: [AnnotationTool] = [
        .arrow, .freeDraw, .measurement, .rectangle, .circle, .line, .text, .numberedStep
    ]

    private var showStyleControls: Bool {
        if stylingTools.contains(currentTool) { return true }
        if let id = selectedAnnotationID,
           let ann = annotations.first(where: { $0.id == id }),
           stylingTools.contains(ann.tool) { return true }
        return false
    }

    private var usesFontSizeContext: Bool {
        if currentTool == .text || currentTool == .numberedStep { return true }
        if let id = selectedAnnotationID,
           let ann = annotations.first(where: { $0.id == id }),
           (ann.tool == .text || ann.tool == .numberedStep) { return true }
        return false
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                Color.clear
                    .frame(height: 12)

                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 0) {
                        if hasTemplate {
                            templatesSection
                            sectionDivider
                        }
                        toolsSection
                        sectionDivider
                        if isCropping {
                            cropSection
                            sectionDivider
                        }
                        if hasTemplate {
                            backgroundsSection
                            sectionDivider
                            paddingShadowCornersSection
                            sectionDivider
                            alignmentRatioSection
                            sectionDivider
                            watermarkSection
                            sectionDivider
                        }
                    }
                    .padding(.bottom, 16)
                }
            }
        }
    }

    // MARK: - Sections

    private var templatesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            groupHeader("Templates", section: .templates)
            if !isCollapsed(.templates) {
                TemplatePopupPicker(
                    items: editorTemplates.map { ($0.id, templateDisplayName(for: $0)) },
                    selection: $selectedEditorTemplateID
                )
                .frame(maxWidth: .infinity, minHeight: 28)

                HStack(spacing: 8) {
                    Button("Save", action: onOverwriteTemplate)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(selectedEditorTemplateID == nil || !hasUnsavedTemplateChanges)

                    Button("Save as new", action: onSaveAsNewTemplate)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func templateDisplayName(for template: EditorTemplatePreset) -> String {
        if template.id == selectedEditorTemplateID && hasUnsavedTemplateChanges {
            return "\(template.name) *"
        }
        return template.name
    }

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            groupHeader("Tools", section: .tools)
            if !isCollapsed(.tools) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 5), spacing: 4) {
                    ForEach(drawingTools) { tool in
                        sidebarToolButton(tool)
                    }
                }
                if showStyleControls {
                    HStack(spacing: 8) {
                        colorButton
                        sizePicker
                        Spacer()
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var cropSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            groupHeader("Crop", section: .crop)
            if !isCollapsed(.crop) {
                HStack(spacing: 8) {
                    Button("Apply", action: onApplyCrop)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button("Cancel", action: onCancelCrop)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var backgroundsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            groupHeader("Background", section: .backgrounds)
            if !isCollapsed(.backgrounds) {
                StringPopupPicker(
                    items: BackgroundType.allCases.map(\.rawValue),
                    selection: $backgroundTypeRawValue
                )
                .frame(maxWidth: .infinity)

                let isSolidColors = backgroundType == .solidColors
                let items = isSolidColors ? BuiltInGradient.solidColors : BuiltInGradient.gradients
                BackgroundGridView(
                    gradientItems: items,
                    selectedWallpaper: selectedWallpaper,
                    customBackgroundImages: isSolidColors ? [] : customBackgroundImages,
                    customColors: isSolidColors ? customColors : [],
                    showCustomColorPicker: isSolidColors,
                    onSelectWallpaper: { selectedWallpaper = $0 },
                    onRemoveCustomImage: onRemoveCustomImage,
                    onAddCustomImage: isSolidColors ? {} : onAddCustomImage,
                    onAddCustomColor: onAddCustomColor,
                    onRemoveCustomColor: onRemoveCustomColor
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var paddingShadowCornersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            groupHeader("Padding, shadows and corners", section: .shadowCorners)
            if !isCollapsed(.shadowCorners) {
                HStack(spacing: 8) {
                    Slider(value: paddingBinding, in: 20...200)
                    Text("\(padding)px")
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 40, alignment: .trailing)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 4)
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 8) {
                        sectionLabel("Shadow")
                        HStack(spacing: 8) {
                            Slider(value: $shadowIntensity, in: 0...1)
                            Text("\(shadowBlurPixels)px")
                                .font(.system(size: 11, design: .monospaced))
                                .frame(width: 40, alignment: .trailing)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)

                    Divider()
                        .padding(.horizontal, 10)
                        .padding(.top, 2)

                    VStack(alignment: .leading, spacing: 8) {
                        sectionLabel("Corners")
                        HStack(spacing: 8) {
                            Slider(value: cornerRadiusBinding, in: 0...50)
                            Text("\(cornerRadius)px")
                                .font(.system(size: 11, design: .monospaced))
                                .frame(width: 40, alignment: .trailing)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var alignmentRatioSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            groupHeader("Alignment and ratio", section: .alignmentRatio)
            if !isCollapsed(.alignmentRatio) {
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
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Watermark Section

    private var watermarkSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            watermarkHeader

            if watermarkSettings.isEnabled && !isCollapsed(.watermark) {
                // File picker row — styled like a popup/dropdown button
                watermarkFilePickerRow

                // Position
                VStack(alignment: .leading, spacing: 4) {
                    sectionLabel("Position")
                    Picker("", selection: $watermarkSettings.position) {
                        ForEach(WatermarkPosition.allCases) { pos in
                            Text(pos.label).tag(pos)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }

                // Bottom offset
                VStack(alignment: .leading, spacing: 4) {
                    sectionLabel("Bottom offset")
                    HStack(spacing: 8) {
                        Slider(value: $watermarkSettings.bottomOffset, in: 0...100)
                        Text("\(Int(watermarkSettings.bottomOffset))px")
                            .font(.system(size: 11, design: .monospaced))
                            .frame(width: 36, alignment: .trailing)
                            .foregroundStyle(.secondary)
                    }
                }

                // Edge offset
                VStack(alignment: .leading, spacing: 4) {
                    sectionLabel("Edge offset")
                    HStack(spacing: 8) {
                        Slider(value: $watermarkSettings.edgeOffset, in: 0...100)
                        Text("\(Int(watermarkSettings.edgeOffset))px")
                            .font(.system(size: 11, design: .monospaced))
                            .frame(width: 36, alignment: .trailing)
                            .foregroundStyle(.secondary)
                    }
                }

                // Opacity
                VStack(alignment: .leading, spacing: 4) {
                    sectionLabel("Opacity")
                    HStack(spacing: 8) {
                        Slider(value: $watermarkSettings.opacity, in: 0...1)
                        Text("\(Int(watermarkSettings.opacity * 100))%")
                            .font(.system(size: 11, design: .monospaced))
                            .frame(width: 36, alignment: .trailing)
                            .foregroundStyle(.secondary)
                    }
                }

                // Size — widthPx stores the direct export pixel width (15–300 px)
                VStack(alignment: .leading, spacing: 4) {
                    sectionLabel("Size")
                    HStack(spacing: 8) {
                        Slider(value: $watermarkSettings.widthPx, in: 15...300)
                        Text("\(Int(watermarkSettings.widthPx))px")
                            .font(.system(size: 11, design: .monospaced))
                            .frame(width: 42, alignment: .trailing)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var watermarkHeader: some View {
        HStack(spacing: 8) {
            groupHeaderLabel("Watermark", isHovered: hoveredSection == .watermark)
            Spacer()
            Toggle("", isOn: $watermarkSettings.isEnabled)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
            collapseIcon(for: .watermark, isHovered: hoveredSection == .watermark)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(hoveredSection == .watermark ? Color.primary.opacity(0.07) : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 5))
        .onTapGesture {
            toggleSection(.watermark)
        }
        .onHover { isHovering in
            hoveredSection = isHovering ? .watermark : (hoveredSection == .watermark ? nil : hoveredSection)
        }
    }

    private var watermarkFilePickerRow: some View {
        let filename = watermarkSettings.imagePath.map { ($0 as NSString).lastPathComponent } ?? "No image selected"
        return HStack(spacing: 6) {
            WatermarkFilePickerButton(title: filename, onPick: {})
                .frame(maxWidth: .infinity, minHeight: 28)
            Button("Add", action: onPickWatermarkImage)
                .buttonStyle(.bordered)
                .controlSize(.regular)
        }
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                        isSelected: false,
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
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? Color.primary.opacity(0.12) : hoveredTool == tool ? Color.primary.opacity(0.06) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .bottom) {
                if isActive && hasSecondaryOptions(tool) {
                    Image(systemName: "chevron.compact.down")
                        .font(.system(size: 7, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 2)
                }
            }
        }
        .buttonStyle(.plain)
        .help(isActive && hasSecondaryOptions(tool) ? "Click again to change style" : tool.label)
        .onHover { isHovering in hoveredTool = isHovering ? tool : nil }

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
        } else if tool == .rectangle {
            button
                .popover(isPresented: $rectStylePopoverVisible, arrowEdge: .trailing) {
                    shapeStylePopoverContent
                }
        } else if tool == .circle {
            button
                .popover(isPresented: $circleStylePopoverVisible, arrowEdge: .trailing) {
                    shapeStylePopoverContent
                }
        } else {
            button
        }
    }

    // MARK: - Color Button

    private var strokeColorBinding: Binding<Color> {
        Binding(
            get: { currentStyle.strokeColor },
            set: { newColor in
                currentStyle.strokeColor = newColor
                applyStyleToSelection()
            }
        )
    }

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
        Button { sizePopoverVisible.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: usesFontSizeContext ? "textformat.size" : "lineweight")
                    .font(.system(size: 12))
                Text(usesFontSizeContext
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

    // Gradient cells moved to BackgroundGridView (Equatable) below.

    // MARK: - Helpers

    private func hasSecondaryOptions(_ tool: AnnotationTool) -> Bool {
        tool == .arrow || tool == .rectangle || tool == .circle || tool == .pixelate
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.leading, 5)
    }

    private func groupHeader(_ text: String, section: SidebarSection) -> some View {
        Button {
            toggleSection(section)
        } label: {
            HStack(spacing: 8) {
                groupHeaderLabel(text, isHovered: hoveredSection == section)
                Spacer()
                collapseIcon(for: section, isHovered: hoveredSection == section)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(hoveredSection == section ? Color.primary.opacity(0.07) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            hoveredSection = isHovering ? section : (hoveredSection == section ? nil : hoveredSection)
        }
        .help(isCollapsed(section) ? "Expand section" : "Collapse section")
    }

    private func groupHeaderLabel(_ text: String, isHovered: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(isHovered ? .primary : .secondary)
    }

    private func collapseIcon(for section: SidebarSection, isHovered: Bool) -> some View {
        Image(systemName: isCollapsed(section) ? "chevron.right" : "chevron.down")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(isHovered ? .secondary : .tertiary)
            .frame(width: 18, height: 18)
    }

    private var sectionDivider: some View {
        EmptyView()
    }

    private func isCollapsed(_ section: SidebarSection) -> Bool {
        persistedCollapsedSections.contains(section)
    }

    private func toggleSection(_ section: SidebarSection) {
        var sections = persistedCollapsedSections
        if isCollapsed(section) {
            sections.remove(section)
        } else {
            sections.insert(section)
        }
        collapsedSectionsStorage = sections
            .map(\.rawValue)
            .sorted()
            .joined(separator: ",")
    }

    private var persistedCollapsedSections: Set<SidebarSection> {
        Set(
            collapsedSectionsStorage
                .split(separator: ",")
                .compactMap { SidebarSection(rawValue: String($0)) }
        )
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

    private var shadowBlurPixels: Int {
        Int((shadowIntensity * 60).rounded())
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

// MARK: - Watermark File Picker Button (native NSPopUpButton appearance)

/// A single-item NSPopUpButton that shows a filename and triggers a file-picker panel on click.
/// Matches the visual style of SwiftUI Picker (Ratio, Templates) exactly.
private struct WatermarkFilePickerButton: NSViewRepresentable {
    let title: String
    let onPick: () -> Void

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.controlSize = .regular
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addItem(withTitle: title)
        button.target = context.coordinator
        button.action = #selector(Coordinator.didClick(_:))
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        if button.itemArray.first?.title != title {
            button.removeAllItems()
            button.addItem(withTitle: title)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: WatermarkFilePickerButton
        init(_ parent: WatermarkFilePickerButton) { self.parent = parent }

        @objc func didClick(_ sender: NSPopUpButton) {
            // Reset displayed item immediately (we're not selecting from a list)
            DispatchQueue.main.async {
                sender.removeAllItems()
                sender.addItem(withTitle: self.parent.title)
                self.parent.onPick()
            }
        }
    }
}

private struct TemplatePopupPicker: NSViewRepresentable {
    let items: [(UUID, String)]
    @Binding var selection: UUID?

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.controlSize = .regular
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionChanged(_:))
        context.coordinator.update(button: button, items: items, selection: selection)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(button: button, items: items, selection: selection)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject {
        var parent: TemplatePopupPicker

        init(parent: TemplatePopupPicker) {
            self.parent = parent
        }

        func update(button: NSPopUpButton, items: [(UUID, String)], selection: UUID?) {
            let existingTitles = button.itemArray.map(\.title)
            let newTitles = items.map(\.1)
            let needsReload = existingTitles != newTitles || button.numberOfItems != items.count

            if needsReload {
                button.removeAllItems()
                for (id, title) in items {
                    button.addItem(withTitle: title)
                    button.lastItem?.representedObject = id.uuidString
                }
            }

            if let selection,
               let item = button.itemArray.first(where: { ($0.representedObject as? String) == selection.uuidString }) {
                button.select(item)
            } else if button.numberOfItems > 0 {
                button.selectItem(at: 0)
            }
        }

        @objc func selectionChanged(_ sender: NSPopUpButton) {
            guard let idString = sender.selectedItem?.representedObject as? String,
                  let id = UUID(uuidString: idString)
            else { return }
            parent.selection = id
        }
    }
}

private struct StringPopupPicker: NSViewRepresentable {
    let items: [String]
    @Binding var selection: String

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.controlSize = .regular
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionChanged(_:))
        context.coordinator.update(button: button, items: items, selection: selection)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(button: button, items: items, selection: selection)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject {
        var parent: StringPopupPicker

        init(parent: StringPopupPicker) {
            self.parent = parent
        }

        func update(button: NSPopUpButton, items: [String], selection: String) {
            let existingTitles = button.itemArray.map(\.title)
            let needsReload = existingTitles != items || button.numberOfItems != items.count

            if needsReload {
                button.removeAllItems()
                for item in items {
                    button.addItem(withTitle: item)
                    button.lastItem?.representedObject = item
                }
            }

            if let item = button.itemArray.first(where: { ($0.representedObject as? String) == selection }) {
                button.select(item)
            } else if button.numberOfItems > 0 {
                button.selectItem(at: 0)
            }
        }

        @objc func selectionChanged(_ sender: NSPopUpButton) {
            guard let value = sender.selectedItem?.representedObject as? String else { return }
            parent.selection = value
        }
    }
}

// MARK: - Background Grid (Equatable)

/// Isolated `Equatable` view for the gradient/background grid.
/// When the parent re-evaluates due to slider changes (corner radius, shadow, padding),
/// SwiftUI compares this view's value-type inputs and SKIPS its body if unchanged.
/// This avoids recreating 40+ gradient cells with LinearGradient fills on every slider tick.
struct BackgroundGridView: View, Equatable {
    let gradientItems: [BuiltInGradient]
    let selectedWallpaper: WallpaperSource?
    let customBackgroundImages: [String]
    var customColors: [CodableColor] = []
    var showCustomColorPicker: Bool = false
    // Closures — excluded from Equatable comparison (they always change identity)
    var onSelectWallpaper: (WallpaperSource?) -> Void
    var onRemoveCustomImage: (String) -> Void
    var onAddCustomImage: () -> Void
    var onAddCustomColor: (CodableColor) -> Void = { _ in }
    var onRemoveCustomColor: (CodableColor) -> Void = { _ in }

    @State private var isPickingColor: Bool = false
    @State private var liveColor: Color = Color(red: 0.5, green: 0.5, blue: 1.0)

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.gradientItems == rhs.gradientItems
        && lhs.selectedWallpaper == rhs.selectedWallpaper
        && lhs.customBackgroundImages == rhs.customBackgroundImages
        && lhs.customColors == rhs.customColors
        && lhs.showCustomColorPicker == rhs.showCustomColorPicker
    }

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)
        LazyVGrid(columns: columns, spacing: 6) {
            noneCell
            ForEach(gradientItems) { gradient in
                gradientCell(gradient)
            }
            if showCustomColorPicker {
                ForEach(customColors, id: \.self) { color in
                    customColorCell(color: color)
                }
                if isPickingColor {
                    liveColorCell
                }
                colorPickerButton
            } else {
                ForEach(customBackgroundImages, id: \.self) { path in
                    customImageCell(path: path)
                }
                customImagePickerButton
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSColorPanel.colorDidChangeNotification)) { _ in
            guard isPickingColor, NSColorPanel.shared.isVisible else { return }
            liveColor = Color(nsColor: NSColorPanel.shared.color)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            guard isPickingColor,
                  let w = notification.object as? NSWindow,
                  w === NSColorPanel.shared
            else { return }
            confirmLiveColor()
        }
    }

    private func confirmLiveColor() {
        guard isPickingColor else { return }
        isPickingColor = false
        let resolved = NSColor(liveColor).usingColorSpace(.deviceRGB) ?? NSColor(liveColor)
        let codable = CodableColor(
            red: resolved.redComponent,
            green: resolved.greenComponent,
            blue: resolved.blueComponent
        )
        onAddCustomColor(codable)
        onSelectWallpaper(.customColor(codable))
    }

    private var noneCell: some View {
        Button {
            onSelectWallpaper(nil)
        } label: {
            GeometryReader { geometry in
                let size = geometry.size
                let squareSide = min(size.width, size.height)
                let horizontalInset = (size.width - squareSide) / 2
                let slashInset = squareSide * 0.18

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
                        path.move(
                            to: CGPoint(
                                x: horizontalInset + slashInset,
                                y: size.height - slashInset
                            )
                        )
                        path.addLine(
                            to: CGPoint(
                                x: horizontalInset + squareSide - slashInset,
                                y: slashInset
                            )
                        )
                    }
                    .stroke(Color.red, lineWidth: 1.5)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .frame(height: 44)
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
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
            onSelectWallpaper(.builtInGradient(gradient))
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
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
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
            onSelectWallpaper(.customImage(path: path))
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
                    .contentShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.3))
                    .frame(height: 44)
                    .contentShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .buttonStyle(.plain)
        .help("Custom Image")
        .contextMenu {
            Button(role: .destructive) {
                if isSelected {
                    onSelectWallpaper(nil)
                }
                onRemoveCustomImage(path)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

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
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help("Add Custom Image")
    }

    private func isCustomColorSelected(_ color: CodableColor) -> Bool {
        if case .customColor(let current) = selectedWallpaper {
            return current == color
        }
        return false
    }

    private func customColorCell(color: CodableColor) -> some View {
        let isSelected = isCustomColorSelected(color)
        let swiftColor = Color(red: color.red, green: color.green, blue: color.blue, opacity: color.alpha)
        return Button {
            onSelectWallpaper(.customColor(color))
        } label: {
            RoundedRectangle(cornerRadius: 8)
                .fill(swiftColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 8).stroke(
                        isSelected ? Color.accentColor : Color.primary.opacity(0.15),
                        lineWidth: isSelected ? 2 : 0.5
                    )
                )
                .frame(height: 44)
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help("Custom Color")
        .contextMenu {
            Button(role: .destructive) {
                if isSelected {
                    onSelectWallpaper(nil)
                }
                onRemoveCustomColor(color)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var liveColorCell: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 8)
                .fill(liveColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 8).stroke(
                        Color.accentColor,
                        style: StrokeStyle(lineWidth: 2, dash: [4, 3])
                    )
                )
                .frame(height: 44)
                .contentShape(RoundedRectangle(cornerRadius: 8))
            Button {
                isPickingColor = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(color: .black.opacity(0.4), radius: 2)
            }
            .buttonStyle(.plain)
            .offset(x: 4, y: -4)
        }
    }

    private var colorPickerButton: some View {
        Button {
            guard !isPickingColor else { return }
            isPickingColor = true
            let panel = NSColorPanel.shared
            panel.color = NSColor(liveColor)
            panel.isContinuous = true
            panel.orderFront(nil)
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
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help("Add Custom Color")
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
