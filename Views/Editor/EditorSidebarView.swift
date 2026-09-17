import SwiftUI
import UniformTypeIdentifiers

/// The sidebar panel that adapts its content to the current `EditorMode`.
/// • Annotate — full annotation tools, template, background, shadows, watermark.
/// • Edit      — photo adjustment sliders + crop shortcut via `PhotoEditSidebarSection`.
/// • View      — hidden at the parent level; this view is never instantiated.
struct EditorSidebarView: View {

    // MARK: - Bindings from EditorView

    /// The active editor mode. Controls which sidebar content is shown.
    @Binding var editorMode: EditorMode
    /// Photo adjustments used in Edit mode.
    @Binding var photoAdjustments: PhotoAdjustments
    var imageMetadata: ImageMetadata?

    @Binding var showProSidebar: Bool
    @Binding var currentTool: AnnotationTool
    @Binding var currentStyle: AnnotationStyle
    /// Emoji stamped by the sticker tool. Kept out of `AnnotationStyle` on
    /// purpose — `applyStyleToSelection` replaces a selection's whole style, so
    /// a style-resident emoji would be rewritten by the next colour or size
    /// tweak (the trap documented on `Annotation.textWidth`).
    @Binding var currentStickerEmoji: String
    @Binding var selectedAnnotationID: UUID?
    @Binding var annotations: [Annotation]
    @Binding var isCropping: Bool
    @Binding var cropAspectPreset: CropAspectPreset
    @Binding var cropAspectPortrait: Bool
    @Binding var straightenDialAngle: Double
    @Binding var isAdjustingCrop: Bool
    /// True for PDF sessions — straighten is offered for raster images only.
    var isPDFSession: Bool = false

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
    var customGradients: [CustomGradient]
    var onAddCustomGradient: (CustomGradient) -> Void
    var onUpdateCustomGradient: (CustomGradient) -> Void
    var onRemoveCustomGradient: (UUID) -> Void
    var onOverwriteTemplate: () -> Void
    var onSaveAsNewTemplate: () -> Void
    var canUndo: Bool
    var onApplyCrop: () -> Void
    var onCancelCrop: () -> Void
    /// Called in Edit mode when the user taps the Crop button — enters crop mode.
    var onEnterCrop: () -> Void = {}
    /// Called from the crop panel to mirror the image left↔right / top↔bottom.
    var onFlipHorizontal: () -> Void = {}
    var onFlipVertical: () -> Void = {}
    /// Called in Edit mode when the user taps rotate-left (90° CCW).
    var onRotateLeft: () -> Void = {}
    /// Called in Edit mode when the user taps rotate-right (90° CW).
    var onRotateRight: () -> Void = {}
    var onUndo: () -> Void
    var onDone: () -> Void

    @Binding var watermarkSettings: WatermarkSettings
    var onPickWatermarkImage: () -> Void

    var imagePixelSize: CGSize
    var onResizeImage: (Int, Int) -> Void

    /// Whether to offer the "apply to all images" toggle — true when more than
    /// one raster image is open (PDF pages take no background, so don't count).
    var applyToAllImagesAvailable: Bool = false
    /// When on, the active image's background + effects are mirrored onto every
    /// other open image. The binding routes a "would overwrite edits" case
    /// through a confirmation in `EditorView`.
    @Binding var applyTemplateToAllImages: Bool

    @State private var colorPopoverVisible = false
    @State private var fillColorPopoverVisible = false
    @State private var sizePopoverVisible = false
    @State private var pixelatePopoverVisible = false
    @State private var arrowStylePopoverVisible = false
    @State private var shapesPopoverVisible = false
    @State private var spotlightPopoverVisible = false
    @State private var stickerPopoverVisible = false
    @State private var hoveredTool: AnnotationTool? = nil
    @State private var hoveredSection: SidebarSection? = nil
    /// Keyboard focus follows the active tool so the focus ring sits on it,
    /// rather than getting stuck on the first button (Select).
    @FocusState private var focusedTool: AnnotationTool?
    @AppStorage(Constants.UserDefaultsKeys.editorSidebarCollapsedSections)
    private var collapsedSectionsStorage: String = ""
    @AppStorage(Constants.UserDefaultsKeys.editorSidebarBackgroundType)
    private var backgroundTypeRawValue: String = BackgroundType.gradients.rawValue
    /// Non-nil while the gradient editor sheet is up.
    @State private var gradientEditorRequest: GradientEditorRequest?

    private enum SidebarSection: String, Hashable {
        case templates
        case tools
        case backgrounds
        case shadowCorners
        case alignmentRatio
        case watermark
    }

    enum BackgroundType: String, CaseIterable, Identifiable {
        case gradients = "Gradients"
        case solidColors = "Solid Colors"
        case customBackgrounds = "Custom Backgrounds"
        var id: String { rawValue }

        /// Localized label for the picker. Kept separate from `rawValue`, which is
        /// persisted in @AppStorage and must stay English.
        var displayName: String {
            switch self {
            case .gradients:         return String(localized: "Gradients")
            case .solidColors:       return String(localized: "Solid Colors")
            case .customBackgrounds: return String(localized: "Custom Backgrounds")
            }
        }

        /// Which built-in swatches this category lists ahead of the user's own.
        var builtInItems: [BuiltInGradient] {
            switch self {
            case .gradients:         return BuiltInGradient.gradients
            case .solidColors:       return BuiltInGradient.solidColors
            case .customBackgrounds: return []
            }
        }

        var gridMode: BackgroundGridView.Mode {
            switch self {
            case .gradients:         return .gradients
            case .solidColors:       return .solidColors
            case .customBackgrounds: return .customImages
            }
        }
    }

    private var backgroundType: BackgroundType {
        BackgroundType(rawValue: backgroundTypeRawValue) ?? .gradients
    }

    private let presetColors: [Color] = [
        .red, .orange, .yellow, .green, .blue, .purple, .white, .black
    ]

    // .rectangle acts as the shapes-group representative (circle/triangle/star are in the shapes picker).
    // For PDF sessions (hasTemplate == false), pixelate is omitted (PDFs export as
    // vector; pixelate would force rasterization) and crop is omitted too: the live
    // vector page view and the PDF export both draw the full page, so a crop would
    // distort the on-screen page and be silently dropped from the saved PDF.
    private var drawingTools: [AnnotationTool] {
        let base: [AnnotationTool] = [
            .select, .freeDraw, .arrow, .rectangle, .line, .text, .numberedStep, .sticker,
            .measurement, .angle, .pixelate, .spotlight, .crop
        ]
        guard !hasTemplate else { return base }
        // PDF sessions: pixelate/crop don't apply (vector export draws the full
        // page); add a text-selection tool so the page's text can be selected and
        // copied without leaving the markup mode.
        return [.select, .textSelect] + base.filter { $0 != .select && $0 != .pixelate && $0 != .crop }
    }

    private let stylingTools: [AnnotationTool] = [
        .arrow, .freeDraw, .measurement, .angle, .rectangle, .circle, .triangle, .star, .line, .text, .numberedStep
    ]

    private var showStyleControls: Bool {
        if stylingTools.contains(currentTool) { return true }
        if let id = selectedAnnotationID,
           let ann = annotations.first(where: { $0.id == id }),
           stylingTools.contains(ann.tool) { return true }
        return false
    }

    private var showFillColorControl: Bool {
        if currentTool.isShapeTool { return true }
        if let id = selectedAnnotationID,
           let ann = annotations.first(where: { $0.id == id }),
           ann.tool.isShapeTool { return true }
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
        // ZStack with directional transitions produces a cross-slide between modes:
        // the outgoing panel slides out one side while the incoming panel slides in
        // from the other, so there's no empty gap in the layout during the swap.
        // .clipped() prevents the in-flight views from drawing outside the sidebar bounds.
        ZStack {
            if isCropping {
                // Crop replaces the entire sidebar in BOTH modes — one panel with
                // every crop control, rather than a section bolted onto each mode.
                CropSidebarPanel(
                    aspectPreset: $cropAspectPreset,
                    aspectPortrait: $cropAspectPortrait,
                    straightenAngle: $straightenDialAngle,
                    isAdjustingCrop: $isAdjustingCrop,
                    straightenAvailable: selectedWallpaper == nil && !isPDFSession,
                    flipAvailable: !isPDFSession,
                    onFlipHorizontal: onFlipHorizontal,
                    onFlipVertical: onFlipVertical,
                    onRotateLeft: onRotateLeft,
                    onRotateRight: onRotateRight,
                    onApply: onApplyCrop,
                    onCancel: onCancelCrop
                )
                .transition(.opacity)
            } else if editorMode == .edit {
                // Photo adjustment sliders + crop shortcut
                PhotoEditSidebarSection(
                    adjustments: $photoAdjustments,
                    metadata: imageMetadata,
                    imagePixelSize: imagePixelSize,
                    resizeDisabled: selectedWallpaper != nil,
                    onEnterCrop: onEnterCrop,
                    onResizeImage: onResizeImage,
                    onRotateLeft: onRotateLeft,
                    onRotateRight: onRotateRight,
                    onFlipHorizontal: onFlipHorizontal,
                    onFlipVertical: onFlipVertical
                )
                // Edit slides in from / out to the right edge.
                .transition(.move(edge: .trailing))
            } else {
                // Annotate mode (View mode is hidden at the EditorView level — this is a
                // safe fallback). Annotate slides in from / out to the left edge.
                annotateContent
                    .transition(.move(edge: .leading))
            }
        }
        .clipped()
        .animation(.easeInOut(duration: 0.25), value: editorMode)
        .animation(.easeInOut(duration: 0.18), value: isCropping)
    }

    /// The annotation-mode sidebar content (full tool palette + template controls).
    private var annotateContent: some View {
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
                        if hasTemplate {
                            backgroundsSection
                            sectionDivider
                            paddingShadowCornersSection
                            sectionDivider
                            if applyToAllImagesAvailable {
                                applyToAllImagesRow
                                sectionDivider
                            }
                            alignmentRatioSection
                            sectionDivider
                        }
                        watermarkSection
                        sectionDivider
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
                    selection: $selectedEditorTemplateID,
                    noTemplateApplied: noTemplateApplied,
                    onSelectNone: clearTemplate
                )
                .frame(maxWidth: .infinity, minHeight: 28)

                HStack(spacing: 8) {
                    // Also disabled while the picker reads "None": Save writes
                    // into `selectedEditorTemplateID`, and with no template
                    // applied that target is a template the UI is no longer
                    // naming — the user could not tell what they were saving
                    // into. "Save as new" stays available for exactly that case.
                    Button("Save", action: onOverwriteTemplate)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(selectedEditorTemplateID == nil || noTemplateApplied || !hasUnsavedTemplateChanges)

                    Button("Save as new", action: onSaveAsNewTemplate)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// True when no template is in effect on this image — see
    /// `EditorTemplatePreset.noTemplateApplied`, which owns the rule (and the
    /// reason it is not simply "no wallpaper").
    private var noTemplateApplied: Bool {
        EditorTemplatePreset.noTemplateApplied(
            wallpaper: selectedWallpaper,
            selected: editorTemplates.first { $0.id == selectedEditorTemplateID }
        )
    }

    /// "None": strip the template look off this image — background and
    /// watermark, the two parts of a template that actually render.
    ///
    /// Padding, corners, shadow, aspect ratio and alignment are deliberately
    /// left alone: none of them draw anything without a background (see
    /// `EditorTemplatePreset.noTemplateApplied`), so clearing them would
    /// silently discard the user's settings for no visible gain, and picking a
    /// template again overwrites all of them anyway.
    ///
    /// Clearing the wallpaper through the binding runs `EditorView`'s own
    /// `onChange(of: selectedWallpaper)`, which shifts the annotations to
    /// follow the canvas — the same path the Background section's None cell
    /// uses. Don't reimplement that shift here.
    private func clearTemplate() {
        selectedWallpaper = nil
        watermarkSettings.isEnabled = false
        // Deselect the template too, or a template that carries no background
        // of its own still counts as applied and the picker snaps back to it.
        selectedEditorTemplateID = nil
    }

    private func templateDisplayName(for template: EditorTemplatePreset) -> String {
        // With nothing applied there is no baseline to have diverged from, so
        // the "modified" marker would be noise next to a "None" selection.
        if !noTemplateApplied, template.id == selectedEditorTemplateID, hasUnsavedTemplateChanges {
            return "\(template.name) *"
        }
        return template.name
    }

    /// Toggle shown when several images are open: mirror the current image's
    /// background + effects onto all the others as they're edited.
    private var applyToAllImagesRow: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Apply to all images")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text("Use this background & effects for every open image")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $applyTemplateToAllImages)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
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
                .onAppear { focusedTool = activeToolFocusKey }
                .onChange(of: currentTool) { _, _ in focusedTool = activeToolFocusKey }
                if showStyleControls {
                    HStack(spacing: 8) {
                        if showFillColorControl {
                            fillColorButton
                        }
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

    private var backgroundsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            groupHeader("Background", section: .backgrounds)
            if !isCollapsed(.backgrounds) {
                StringPopupPicker(
                    items: BackgroundType.allCases.map(\.rawValue),
                    titles: BackgroundType.allCases.map(\.displayName),
                    selection: $backgroundTypeRawValue
                )
                .frame(maxWidth: .infinity)

                let type = backgroundType
                BackgroundGridView(
                    gradientItems: type.builtInItems,
                    selectedWallpaper: selectedWallpaper,
                    customBackgroundImages: customBackgroundImages,
                    customColors: customColors,
                    customGradients: customGradients,
                    mode: type.gridMode,
                    onSelectWallpaper: { selectedWallpaper = $0 },
                    onRemoveCustomImage: onRemoveCustomImage,
                    onAddCustomImage: onAddCustomImage,
                    onAddCustomColor: onAddCustomColor,
                    onRemoveCustomColor: onRemoveCustomColor,
                    onCreateCustomGradient: { gradientEditorRequest = .new() },
                    onEditCustomGradient: { gradientEditorRequest = .edit($0) },
                    onRemoveCustomGradient: onRemoveCustomGradient
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .sheet(item: $gradientEditorRequest) { request in
            GradientEditorSheet(
                gradient: request.gradient,
                isNew: request.isNew
            ) { saved in
                if request.isNew {
                    onAddCustomGradient(saved)
                    selectedWallpaper = .customGradient(saved.definition)
                } else {
                    onUpdateCustomGradient(saved)
                    // Only take over the canvas when the gradient being edited
                    // is the one on screen — editing an unselected swatch
                    // shouldn't silently change the image's background.
                    if selectedWallpaper == .customGradient(request.gradient.definition) {
                        selectedWallpaper = .customGradient(saved.definition)
                    }
                }
            }
        }
    }

    private var paddingShadowCornersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            groupHeader("Background Effects", section: .shadowCorners)
            if !isCollapsed(.shadowCorners) {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 8) {
                        sectionLabel("Padding")
                        HStack(spacing: 8) {
                            Slider(value: paddingBinding, in: 20...200)
                            Text("\(padding)px")
                                .font(.system(size: 11, design: .monospaced))
                                .frame(width: 40, alignment: .trailing)
                                .foregroundStyle(.secondary)
                        }
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
                .disabled(selectedWallpaper == nil)
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
                .disabled(selectedWallpaper == nil)
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
        let filename = watermarkSettings.imagePath.map { ($0 as NSString).lastPathComponent } ?? String(localized: "No image selected")
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

    /// True when `tool` is the shapes-group representative and the current tool is any shape.
    private var isShapeGroupActive: Bool { currentTool.isShapeTool }

    /// The tool button that should hold keyboard focus for the active tool.
    /// Shapes collapse onto the `.rectangle` group representative button.
    private var activeToolFocusKey: AnnotationTool {
        currentTool.isShapeTool ? .rectangle : currentTool
    }

    @ViewBuilder
    private func sidebarToolButton(_ tool: AnnotationTool) -> some View {
        // For the shapes group button (.rectangle is the representative), show a
        // combined icon + chevron right. First click activates the shapes group
        // (defaulting to rectangle); clicking again — once a shape is active —
        // opens the picker to switch shape.
        if tool == .rectangle {
            let isActive = isShapeGroupActive
            let button = Button {
                if currentTool.isShapeTool {
                    // Already active — clicking again opens the shape picker.
                    shapesPopoverVisible.toggle()
                    return
                }
                pixelatePopoverVisible = false
                arrowStylePopoverVisible = false
                spotlightPopoverVisible = false
                selectTool(.rectangle)
            } label: {
                HStack(spacing: 3) {
                    shapesGroupIcon
                    Image(systemName: "chevron.right")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isActive ? Color.primary.opacity(0.12) : hoveredTool == tool ? Color.primary.opacity(0.06) : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help("Shapes")
            .onHover { isHovering in hoveredTool = isHovering ? tool : nil }
            .focused($focusedTool, equals: tool)
            .popover(isPresented: $shapesPopoverVisible, arrowEdge: .trailing) {
                shapesPickerContent
            }
            button
        } else {
            let isActive = currentTool == tool
            let hasOptions = hasSecondaryOptions(tool)
            let button = Button {
                if tool == .sticker {
                    // Unlike the other option-bearing tools, the picker opens on
                    // the FIRST click too: a sticker tool with no emoji chosen
                    // has nothing to stamp.
                    pixelatePopoverVisible = false
                    arrowStylePopoverVisible = false
                    shapesPopoverVisible = false
                    spotlightPopoverVisible = false
                    selectTool(.sticker)
                    stickerPopoverVisible = true
                    return
                }
                if tool == .spotlight, currentTool == .spotlight {
                    spotlightPopoverVisible.toggle()
                    return
                }
                if tool == .pixelate, currentTool == .pixelate {
                    pixelatePopoverVisible.toggle()
                    return
                }
                if tool == .arrow, currentTool == .arrow {
                    // Already active — clicking again opens the style picker.
                    // (First selection just activates the tool, no popover.)
                    arrowStylePopoverVisible.toggle()
                    return
                }
                pixelatePopoverVisible = false
                arrowStylePopoverVisible = false
                shapesPopoverVisible = false
                spotlightPopoverVisible = false
                stickerPopoverVisible = false
                selectTool(tool)
            } label: {
                HStack(spacing: 3) {
                    Group {
                        if tool == .sticker {
                            Text(currentStickerEmoji.isEmpty ? StickerGeometry.defaultEmoji : currentStickerEmoji)
                                .font(.system(size: 14))
                        } else if let assetName = tool.customImageName {
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
                        } else {
                            Image(systemName: tool.systemImage)
                                .font(.system(size: 14))
                        }
                    }
                    if tool == .arrow || tool == .sticker || (isActive && hasOptions) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 7, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isActive ? Color.primary.opacity(0.12) : hoveredTool == tool ? Color.primary.opacity(0.06) : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help(tool == .sticker
                  ? tool.label
                  : (isActive && hasOptions ? String(localized: "Click again to change style") : tool.label))
            .onHover { isHovering in hoveredTool = isHovering ? tool : nil }
            .focused($focusedTool, equals: tool)

            if tool == .sticker {
                button.popover(isPresented: $stickerPopoverVisible, arrowEdge: .trailing) {
                    EmojiPickerView(selected: currentStickerEmoji) { emoji in
                        currentStickerEmoji = emoji
                        applyStickerToSelection()
                        stickerPopoverVisible = false
                    }
                }
            } else if tool == .spotlight {
                button.popover(isPresented: $spotlightPopoverVisible, arrowEdge: .trailing) {
                    spotlightPopoverContent
                }
            } else if tool == .pixelate {
                button.popover(isPresented: $pixelatePopoverVisible, arrowEdge: .trailing) {
                    pixelatePopoverContent
                }
            } else if tool == .arrow {
                button.popover(isPresented: $arrowStylePopoverVisible, arrowEdge: .trailing) {
                    arrowStylePopoverContent
                }
            } else {
                button
            }
        }
    }

    /// Icon shown on the shapes group button: active shape icon, or combined rect+circle mark.
    @ViewBuilder
    private var shapesGroupIcon: some View {
        if currentTool.isShapeTool {
            Image(systemName: currentTool.systemImage)
                .font(.system(size: 14))
        } else {
            Canvas { ctx, size in
                let c = GraphicsContext.Shading.color(.secondary)
                let lw: CGFloat = 1.5
                // Rounded rect (upper-left area)
                ctx.stroke(
                    Path(roundedRect: CGRect(x: 1, y: 2, width: size.width * 0.62, height: size.height * 0.58), cornerRadius: 2),
                    with: c, lineWidth: lw
                )
                // Circle (lower-right, overlapping)
                ctx.stroke(
                    Path(ellipseIn: CGRect(x: size.width * 0.38, y: size.height * 0.38,
                                          width: size.width * 0.58, height: size.height * 0.58)),
                    with: c, lineWidth: lw
                )
            }
            .frame(width: 16, height: 16)
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

    private var fillColorBinding: Binding<Color> {
        Binding(
            get: { currentStyle.fillColor ?? .clear },
            set: { newColor in
                currentStyle.fillColor = newColor
                applyStyleToSelection()
            }
        )
    }

    private var colorButton: some View {
        Button { colorPopoverVisible.toggle() } label: {
            HStack(spacing: 4) {
                ZStack {
                    if showFillColorControl && currentStyle.strokeColor == .clear {
                        Circle()
                            .fill(Color.primary.opacity(0.06))
                            .overlay(Circle().stroke(Color.primary.opacity(0.2), lineWidth: 0.5))
                        Path { path in
                            let s: CGFloat = 16
                            let inset = s * 0.22
                            path.move(to: CGPoint(x: inset, y: s - inset))
                            path.addLine(to: CGPoint(x: s - inset, y: inset))
                        }
                        .stroke(Color.red, lineWidth: 1.5)
                        .clipShape(Circle())
                    } else {
                        Circle()
                            .strokeBorder(currentStyle.strokeColor, lineWidth: 2.5)
                    }
                }
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
                if showFillColorControl {
                    Button {
                        currentStyle.strokeColor = .clear
                        applyStyleToSelection()
                        colorPopoverVisible = false
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Color.primary.opacity(0.06))
                                .overlay(Circle().stroke(
                                    currentStyle.strokeColor == .clear ? Color.accentColor : Color.primary.opacity(0.2),
                                    lineWidth: currentStyle.strokeColor == .clear ? 2 : 0.5
                                ))
                            Path { path in
                                let s: CGFloat = 20
                                let inset = s * 0.22
                                path.move(to: CGPoint(x: inset, y: s - inset))
                                path.addLine(to: CGPoint(x: s - inset, y: inset))
                            }
                            .stroke(
                                currentStyle.strokeColor == .clear ? Color.accentColor : Color.red,
                                lineWidth: 1.5
                            )
                            .clipShape(Circle())
                        }
                        .frame(width: 20, height: 20)
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("No Border")
                    Rectangle()
                        .fill(Color.primary.opacity(0.15))
                        .frame(width: 1, height: 20)
                        .padding(.horizontal, 2)
                }
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

    private var fillColorButton: some View {
        Button { fillColorPopoverVisible.toggle() } label: {
            HStack(spacing: 4) {
                ZStack {
                    if let fill = currentStyle.fillColor {
                        Circle()
                            .fill(fill)
                            .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
                    } else {
                        Circle()
                            .fill(Color.primary.opacity(0.06))
                            .overlay(Circle().stroke(Color.primary.opacity(0.2), lineWidth: 0.5))
                        Path { path in
                            let s: CGFloat = 16
                            let inset = s * 0.22
                            path.move(to: CGPoint(x: inset, y: s - inset))
                            path.addLine(to: CGPoint(x: s - inset, y: inset))
                        }
                        .stroke(Color.red, lineWidth: 1.5)
                        .clipShape(Circle())
                    }
                }
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
        .help("Fill Color")
        .popover(isPresented: $fillColorPopoverVisible, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Fill")
                    .font(.system(size: 12, weight: .medium))
                HStack(spacing: 6) {
                    // No-fill option
                    Button {
                        currentStyle.fillColor = nil
                        applyStyleToSelection()
                        fillColorPopoverVisible = false
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Color.primary.opacity(0.06))
                                .overlay(Circle().stroke(
                                    currentStyle.fillColor == nil ? Color.accentColor : Color.primary.opacity(0.2),
                                    lineWidth: currentStyle.fillColor == nil ? 2 : 0.5
                                ))
                            Path { path in
                                let s: CGFloat = 20
                                let inset = s * 0.22
                                path.move(to: CGPoint(x: inset, y: s - inset))
                                path.addLine(to: CGPoint(x: s - inset, y: inset))
                            }
                            .stroke(
                                currentStyle.fillColor == nil ? Color.accentColor : Color.red,
                                lineWidth: 1.5
                            )
                            .clipShape(Circle())
                        }
                        .frame(width: 20, height: 20)
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("No Fill")
                    Rectangle()
                        .fill(Color.primary.opacity(0.15))
                        .frame(width: 1, height: 20)
                        .padding(.horizontal, 2)
                    ForEach(presetColors, id: \.self) { color in
                        Button {
                            currentStyle.fillColor = color
                            applyStyleToSelection()
                            fillColorPopoverVisible = false
                        } label: {
                            Circle()
                                .fill(color)
                                .overlay(
                                    Circle().stroke(
                                        currentStyle.fillColor == color ? Color.accentColor : Color.primary.opacity(0.15),
                                        lineWidth: currentStyle.fillColor == color ? 2 : 0.5
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
                    RainbowColorPickerButton(color: fillColorBinding)
                }
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
                // Never add .focusable(false) to a Slider — on macOS 26 it
                // suppresses the knob entirely (track and fill still draw), so
                // the control looks like it has no drag handle until you click it.
                Slider(value: strokeWidthBinding, in: 1...15)
                    .tint(.accentColor)
                    .frame(width: 180)
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
                // No .focusable(false) — see strokeWidthSliderContent.
                Slider(value: fontSizeBinding, in: 12...120)
                    .tint(.accentColor)
                    .frame(width: 180)
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

    /// Re-stamp the selected sticker when the user picks a different emoji —
    /// so changing your mind doesn't mean delete-and-place-again.
    private func applyStickerToSelection() {
        guard let id = selectedAnnotationID,
              let idx = annotations.firstIndex(where: { $0.id == id }),
              annotations[idx].tool == .sticker
        else { return }
        annotations[idx].text = currentStickerEmoji
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
                // No .focusable(false) — see strokeWidthSliderContent.
                Slider(value: pixelationScaleBinding, in: 2...60)
                    .tint(.accentColor)
                    .frame(width: 180)
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

    // MARK: - Spotlight Popover

    private var spotlightPopoverContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Dim Opacity")
                .font(.system(size: 12, weight: .medium))
            HStack(spacing: 8) {
                // No .focusable(false) — see strokeWidthSliderContent.
                Slider(value: spotlightOpacityBinding, in: 0.1...0.9)
                    .tint(.accentColor)
                    .frame(width: 180)
                    .focusEffectDisabled()
                Text("\(Int(currentStyle.spotlightOpacity * 100))%")
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 36, alignment: .trailing)
            }

            Divider()

            Text("Feather")
                .font(.system(size: 12, weight: .medium))
            HStack(spacing: 8) {
                // No .focusable(false) — see strokeWidthSliderContent.
                Slider(value: spotlightFeatherBinding, in: 0...200)
                    .tint(.accentColor)
                    .frame(width: 180)
                    .focusEffectDisabled()
                Text("\(Int(currentStyle.spotlightFeather))px")
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 36, alignment: .trailing)
            }
        }
        .padding(12)
    }

    private var spotlightOpacityBinding: Binding<Double> {
        Binding(
            get: { Double(currentStyle.spotlightOpacity) },
            set: { newValue in
                currentStyle.spotlightOpacity = CGFloat(newValue)
                applySpotlightStyleToAll()
            }
        )
    }

    private var spotlightFeatherBinding: Binding<Double> {
        Binding(
            get: { Double(currentStyle.spotlightFeather) },
            set: { newValue in
                currentStyle.spotlightFeather = CGFloat(newValue.rounded())
                applySpotlightStyleToAll()
            }
        )
    }

    private func applySpotlightStyleToAll() {
        for idx in annotations.indices where annotations[idx].tool == .spotlight {
            annotations[idx].style.spotlightOpacity = currentStyle.spotlightOpacity
            annotations[idx].style.spotlightFeather = currentStyle.spotlightFeather
        }
    }

    // MARK: - Shapes Picker Popover

    private var shapesPickerContent: some View {
        let shapeTools: [AnnotationTool] = [.rectangle, .circle, .triangle, .star]
        return HStack(spacing: 2) {
            ForEach(shapeTools) { tool in
                let isSelected = currentTool == tool
                Button {
                    selectTool(tool)
                    shapesPopoverVisible = false
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tool.systemImage)
                            .font(.system(size: 20))
                            .foregroundStyle(isSelected ? Color.accentColor : .primary)
                            .frame(width: 44, height: 28)
                        Text(tool.label)
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

    // Gradient cells moved to BackgroundGridView (Equatable) below.

    // MARK: - Helpers

    private func hasSecondaryOptions(_ tool: AnnotationTool) -> Bool {
        tool == .arrow || tool == .pixelate || tool == .spotlight || tool == .sticker
    }

    private func sectionLabel(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.leading, 5)
    }

    private func groupHeader(_ text: LocalizedStringKey, section: SidebarSection) -> some View {
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
        .focusable(false)
        .onHover { isHovering in
            hoveredSection = isHovering ? section : (hoveredSection == section ? nil : hoveredSection)
        }
        .help(isCollapsed(section) ? "Expand section" : "Collapse section")
    }

    private func groupHeaderLabel(_ text: LocalizedStringKey, isHovered: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(isHovered ? .primary : .secondary)
            .textCase(.uppercase)
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
    /// Shows the permanent "None" row as the selection instead of a template.
    ///
    /// The row is always in the menu, never only while it applies: a pop-up
    /// whose *options* appear and disappear reads as a glitch, and you cannot
    /// tell a missing row from a bug.
    var noTemplateApplied: Bool = false
    /// Invoked when the user picks "None" — strips the template look off the
    /// image. Distinct from `selection`, which only ever carries a real
    /// template's id.
    var onSelectNone: () -> Void = {}

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.controlSize = .regular
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionChanged(_:))
        context.coordinator.update(button: button, items: items, selection: selection, noTemplateApplied: noTemplateApplied)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(button: button, items: items, selection: selection, noTemplateApplied: noTemplateApplied)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject {
        var parent: TemplatePopupPicker

        init(parent: TemplatePopupPicker) {
            self.parent = parent
        }

        /// Title of the "no template applied" row.
        private static var noneTitle: String { String(localized: "None") }
        /// Marks the None row. A sentinel rather than "no representedObject",
        /// so picking None is told apart from a click that resolved to no item
        /// at all — the first clears the template, the second must do nothing.
        private static let noneMarker = "none"


        func update(button: NSPopUpButton, items: [(UUID, String)], selection: UUID?, noTemplateApplied: Bool) {
            // Separators have an empty title, so comparing titles positionally
            // covers the None row and the separator as well as the templates.
            let existingTitles = button.itemArray.map { $0.isSeparatorItem ? "" : $0.title }
            let newTitles = [Self.noneTitle, ""] + items.map(\.1)

            if existingTitles != newTitles {
                button.removeAllItems()
                // Manual enablement, or AppKit re-enables the None row for us.
                button.menu?.autoenablesItems = false
                let none = NSMenuItem(title: Self.noneTitle, action: nil, keyEquivalent: "")
                none.representedObject = Self.noneMarker
                button.menu?.addItem(none)
                button.menu?.addItem(.separator())
                for (id, title) in items {
                    // Explicit items rather than `addItem(withTitle:)`, which
                    // REMOVES an existing item of the same title — two templates
                    // sharing a name would silently collapse into one row.
                    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                    item.representedObject = id.uuidString
                    button.menu?.addItem(item)
                }
            }

            // "None" wins whenever nothing is applied: the selected template's
            // name would claim a look this image does not have — the whole point.
            if noTemplateApplied {
                button.selectItem(at: 0)
            } else if let selection,
                      let item = button.itemArray.first(where: { ($0.representedObject as? String) == selection.uuidString }) {
                button.select(item)
            } else if button.numberOfItems > 0 {
                button.selectItem(at: 0)
            }
        }

        @objc func selectionChanged(_ sender: NSPopUpButton) {
            guard let marker = sender.selectedItem?.representedObject as? String else { return }
            if marker == Self.noneMarker {
                parent.onSelectNone()
                return
            }
            guard let id = UUID(uuidString: marker) else { return }
            parent.selection = id
        }
    }
}

private struct StringPopupPicker: NSViewRepresentable {
    /// Persisted values, used for the selection binding.
    let items: [String]
    /// Localized display titles, parallel to `items`. Defaults to the raw values.
    var titles: [String]? = nil
    @Binding var selection: String

    private var displayTitles: [String] { titles ?? items }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.controlSize = .regular
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionChanged(_:))
        context.coordinator.update(button: button, items: items, titles: displayTitles, selection: selection)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(button: button, items: items, titles: displayTitles, selection: selection)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject {
        var parent: StringPopupPicker

        init(parent: StringPopupPicker) {
            self.parent = parent
        }

        func update(button: NSPopUpButton, items: [String], titles: [String], selection: String) {
            let existingTitles = button.itemArray.map(\.title)
            let needsReload = existingTitles != titles || button.numberOfItems != items.count

            if needsReload {
                button.removeAllItems()
                for (item, title) in zip(items, titles) {
                    button.addItem(withTitle: title)
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
    /// Which family of swatches the grid is showing. Each one lists the user's
    /// own entries after the built-ins, then its own "+" cell.
    enum Mode: Equatable {
        case gradients
        case solidColors
        case customImages
    }

    let gradientItems: [BuiltInGradient]
    let selectedWallpaper: WallpaperSource?
    let customBackgroundImages: [String]
    var customColors: [CodableColor] = []
    var customGradients: [CustomGradient] = []
    var mode: Mode = .gradients
    // Closures — excluded from Equatable comparison (they always change identity)
    var onSelectWallpaper: (WallpaperSource?) -> Void
    var onRemoveCustomImage: (String) -> Void
    var onAddCustomImage: () -> Void
    var onAddCustomColor: (CodableColor) -> Void = { _ in }
    var onRemoveCustomColor: (CodableColor) -> Void = { _ in }
    var onCreateCustomGradient: () -> Void = {}
    var onEditCustomGradient: (CustomGradient) -> Void = { _ in }
    var onRemoveCustomGradient: (UUID) -> Void = { _ in }

    @State private var isPickingColor: Bool = false
    @State private var liveColor: Color = Color(red: 0.5, green: 0.5, blue: 1.0)

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.gradientItems == rhs.gradientItems
        && lhs.selectedWallpaper == rhs.selectedWallpaper
        && lhs.customBackgroundImages == rhs.customBackgroundImages
        && lhs.customColors == rhs.customColors
        && lhs.customGradients == rhs.customGradients
        && lhs.mode == rhs.mode
    }

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)
        LazyVGrid(columns: columns, spacing: 6) {
            noneCell
            ForEach(gradientItems) { gradient in
                gradientCell(gradient)
            }
            switch mode {
            case .gradients:
                ForEach(customGradients) { gradient in
                    customGradientCell(gradient)
                }
                plusCell(help: "Create Gradient", action: onCreateCustomGradient)
            case .solidColors:
                ForEach(customColors, id: \.self) { color in
                    customColorCell(color: color)
                }
                if isPickingColor {
                    liveColorCell
                }
                colorPickerButton
            case .customImages:
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

    /// The trailing "+" cell. Every category has one; only the action and the
    /// tooltip differ.
    private func plusCell(help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
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
        .help(help)
    }

    private var customImagePickerButton: some View {
        plusCell(help: "Add Custom Image", action: onAddCustomImage)
    }

    private func isCustomGradientSelected(_ gradient: CustomGradient) -> Bool {
        if case .customGradient(let current) = selectedWallpaper {
            return current == gradient.definition
        }
        return false
    }

    private func customGradientCell(_ gradient: CustomGradient) -> some View {
        let isSelected = isCustomGradientSelected(gradient)
        return Button {
            onSelectWallpaper(.customGradient(gradient.definition))
        } label: {
            Color.clear
                .frame(height: 44)
                .overlay(gradient.definition.swiftUIFill)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8).stroke(
                        isSelected ? Color.accentColor : Color.primary.opacity(0.15),
                        lineWidth: isSelected ? 2 : 0.5
                    )
                )
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help("Custom Gradient")
        .contextMenu {
            Button("Edit Gradient…") { onEditCustomGradient(gradient) }
            Button(role: .destructive) {
                if isSelected {
                    onSelectWallpaper(nil)
                }
                onRemoveCustomGradient(gradient.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
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
        plusCell(help: "Add Custom Color") {
            guard !isPickingColor else { return }
            isPickingColor = true
            let panel = NSColorPanel.shared
            panel.color = NSColor(liveColor)
            panel.isContinuous = true
            panel.orderFront(nil)
        }
    }
}

// Note: BuiltInGradient.swiftUIGradient is defined in ToolbarView.swift (shared extension).


// MARK: - Emoji Picker (Sticker Tool)

/// One page of the sticker picker.
private struct EmojiCategory: Identifiable {
    let id: String
    /// SF Symbol for the tab strip. The tabs are icon-only, so only the
    /// tooltip needs translating.
    let symbol: String
    let title: LocalizedStringKey
    let emoji: [String]
}

/// Emoji offered by the sticker tool: a hand-picked set aimed at marking up
/// screenshots, not the whole Unicode catalogue. There is no public API that
/// enumerates the emoji the running system can actually draw, and deriving the
/// list from Unicode ranges yields plenty of glyphs that render as tofu — so
/// this list is deliberately curated and deliberately finite.
private let emojiCategories: [EmojiCategory] = [
        EmojiCategory(
            id: "smileys",
            symbol: "face.smiling",
            title: "Smileys",
            emoji: [
            "😀", "😃", "😄", "😁", "😆", "😅", "🤣", "😂", "🙂", "🙃",
            "😉", "😊", "😇", "🥰", "😍", "🤩", "😘", "😋", "😜", "🤪",
            "🤗", "🤭", "🤫", "🤔", "🤐", "🤨", "😐", "😑", "😶", "😏",
            "😒", "🙄", "😬", "😌", "😔", "😴", "🤒", "🤕", "🤢", "🥵",
            "🥶", "😵", "🤯", "🤠", "🥳", "😎", "🤓", "🧐", "😕", "😟",
            "🙁", "😮", "😯", "😲", "😳", "🥺", "😨", "😰", "😢", "😭",
            "😱", "😖", "😞", "😤", "😡", "🤬", "😈", "💀", "💩", "🤡",
            "👻", "👽", "🤖", "🙈", "🙉", "🙊"
            ]
        ),
        EmojiCategory(
            id: "gestures",
            symbol: "hand.raised",
            title: "Gestures",
            emoji: [
            "👍", "👎", "👌", "🤌", "🤏", "✌️", "🤞", "🤟", "🤘", "🤙",
            "👈", "👉", "👆", "👇", "☝️", "✋", "🤚", "🖐️", "🖖", "👋",
            "🤝", "🙏", "✍️", "💪", "🦾", "👀", "👁️", "🧠", "👂", "👃",
            "👏", "🙌", "👐", "💁", "🙋", "🤷", "🤦", "🕵️", "🧑‍💻", "👩‍💻",
            "👨‍💻"
            ]
        ),
        EmojiCategory(
            id: "marks",
            symbol: "checkmark.circle",
            title: "Marks",
            emoji: [
            "✅", "☑️", "✔️", "❌", "❎", "⭕️", "🚫", "⛔️", "❗️", "❕",
            "❓", "❔", "‼️", "⁉️", "⚠️", "🔺", "🔻", "🔶", "🔷", "🔴",
            "🟠", "🟡", "🟢", "🔵", "🟣", "⚫️", "⚪️", "🟤", "⭐️", "🌟",
            "✨", "⚡️", "🔥", "💥", "💫", "💯", "💢", "💬", "💭", "🗯️",
            "🔔", "🔕", "♻️", "🆕", "🆗", "🆙", "🆒", "🆓", "🔝", "➕",
            "➖", "✖️", "➗", "〰️"
            ]
        ),
        EmojiCategory(
            id: "arrows",
            symbol: "arrow.right",
            title: "Arrows",
            emoji: [
            "➡️", "⬅️", "⬆️", "⬇️", "↗️", "↘️", "↙️", "↖️", "↕️", "↔️",
            "↩️", "↪️", "⤴️", "⤵️", "🔃", "🔄", "🔁", "🔂", "🔀", "▶️",
            "⏸️", "⏹️", "⏺️", "⏭️", "⏮️", "⏩", "⏪", "🔼", "🔽", "⏫",
            "⏬", "🔚", "🔙", "🔛", "🔜", "🔝"
            ]
        ),
        EmojiCategory(
            id: "objects",
            symbol: "desktopcomputer",
            title: "Objects",
            emoji: [
            "💻", "🖥️", "📱", "⌨️", "🖱️", "🖨️", "💾", "💿", "🔌", "🔋",
            "📷", "📸", "🎥", "🎬", "🎙️", "🎧", "📺", "📻", "⏰", "⏱️",
            "⌛️", "⏳", "📅", "📆", "📌", "📍", "📎", "🖇️", "🔗", "📁",
            "📂", "🗂️", "📄", "📋", "📊", "📈", "📉", "🗒️", "📝", "✏️",
            "🖊️", "🖍️", "🗑️", "🔒", "🔓", "🔑", "🗝️", "🔨", "🛠️", "⚙️",
            "🧰", "🔧", "🧲", "🔍", "🔎", "💡", "🔦", "🧪", "🧬", "📦",
            "✉️", "📢", "📣", "🔊", "🔇", "💰", "💳", "🎁", "🏆", "🥇",
            "🎯", "🎲", "🕹️", "🎮", "🧩", "🔮"
            ]
        ),
        EmojiCategory(
            id: "nature",
            symbol: "leaf",
            title: "Nature",
            emoji: [
            "🌈", "☀️", "🌤️", "⛅️", "☁️", "🌧️", "⛈️", "🌩️", "❄️", "☃️",
            "💧", "🌊", "🌸", "🌺", "🌻", "🌷", "🌹", "🌼", "🍀", "🌱",
            "🌿", "🌳", "🌲", "🍁", "🍂", "🌙", "🌞", "🌍", "🐶", "🐱",
            "🐭", "🐹", "🐰", "🦊", "🐻", "🐼", "🐨", "🐯", "🦁", "🐮",
            "🐷", "🐸", "🐵", "🐔", "🐧", "🐦", "🦄", "🐝", "🐞", "🦋",
            "🐢", "🐙", "🐬", "🐳"
            ]
        ),
        EmojiCategory(
            id: "food",
            symbol: "cup.and.saucer",
            title: "Food",
            emoji: [
            "☕️", "🍵", "🧋", "🥤", "🍺", "🍻", "🥂", "🍷", "🍾", "🍕",
            "🍔", "🍟", "🌭", "🥪", "🌮", "🌯", "🥗", "🍿", "🧀", "🥐",
            "🍞", "🥨", "🍳", "🥞", "🍜", "🍣", "🍱", "🍩", "🍪", "🎂",
            "🍰", "🧁", "🍫", "🍬", "🍭", "🍎", "🍌", "🍇", "🍓", "🍒",
            "🍑", "🥑", "🥕", "🌶️", "🍄"
            ]
        ),
        EmojiCategory(
            id: "travel",
            symbol: "car",
            title: "Travel",
            emoji: [
            "🚗", "🚕", "🚙", "🚌", "🚓", "🚑", "🚒", "🚚", "🏎️", "🏍️",
            "🛵", "🚲", "🛴", "🛹", "✈️", "🚀", "🛸", "🚁", "⛵️", "🚢",
            "🚂", "🚆", "🗺️", "🧭", "🏠", "🏡", "🏢", "🏥", "🏦", "🏫",
            "🏭", "🏰", "🗽", "🗼", "🎡", "🎢", "⛰️", "🏖️", "🏕️", "🚦",
            "🚧", "🏁", "🚩"
            ]
        ),
]

/// Grid of emoji shown from the sticker tool's sidebar button.
private struct EmojiPickerView: View {
    /// The currently stamped emoji, highlighted in the grid.
    let selected: String
    let onPick: (String) -> Void

    @AppStorage(Constants.UserDefaultsKeys.stickerRecentEmoji)
    private var recentStorage: String = ""
    @State private var activeCategoryID: String?

    private static let columns = 9
    private static let cellSize: CGFloat = 30
    private static let maximumRecents = 9

    /// Height of the grid: the rows this category needs, capped so a long
    /// category scrolls instead of growing the popover past the screen.
    private var gridHeight: CGFloat {
        let rows = (activeCategory.emoji.count + Self.columns - 1) / Self.columns
        let spacing: CGFloat = 2
        let needed = CGFloat(rows) * (Self.cellSize + spacing)
        return min(max(needed, Self.cellSize + spacing), 7 * (Self.cellSize + spacing))
    }

    /// Most recent first. Newline-separated so multi-scalar emoji survive.
    private var recents: [String] {
        recentStorage.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    private var categories: [EmojiCategory] {
        let recent = recents
        guard !recent.isEmpty else { return emojiCategories }
        return [EmojiCategory(id: "recent", symbol: "clock", title: "Recent", emoji: recent)]
            + emojiCategories
    }

    private var activeCategory: EmojiCategory {
        categories.first { $0.id == activeCategoryID } ?? categories[0]
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 2) {
                ForEach(categories) { category in
                    let isActive = category.id == activeCategory.id
                    Button {
                        activeCategoryID = category.id
                    } label: {
                        Image(systemName: category.symbol)
                            .font(.system(size: 13))
                            .foregroundStyle(isActive ? Color.accentColor : .secondary)
                            .frame(width: 26, height: 22)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(isActive ? Color.accentColor.opacity(0.12) : Color.clear)
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .help(category.title)
                }
            }

            Divider()

            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(Self.cellSize), spacing: 2),
                                   count: Self.columns),
                    spacing: 2
                ) {
                    // Emoji repeat across categories (and in Recent), so the
                    // character alone is not a unique id.
                    ForEach(Array(activeCategory.emoji.enumerated()), id: \.offset) { _, emoji in
                        Button {
                            remember(emoji)
                            onPick(emoji)
                        } label: {
                            Text(emoji)
                                .font(.system(size: 19))
                                .frame(width: Self.cellSize, height: Self.cellSize)
                                .background(
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(emoji == selected ? Color.accentColor.opacity(0.18) : Color.clear)
                                )
                                .contentShape(RoundedRectangle(cornerRadius: 5))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 2)
            }
            // Fit the rows, up to a scrollable maximum — a Recent tab holding
            // one row shouldn't open a popover of mostly empty space.
            .frame(height: gridHeight)
        }
        .padding(10)
        .frame(width: CGFloat(Self.columns) * (Self.cellSize + 2) + 20)
        .onAppear {
            // Land on Recent when there is one, so the emoji you actually use
            // are one click away.
            if activeCategoryID == nil { activeCategoryID = categories[0].id }
        }
    }

    private func remember(_ emoji: String) {
        var updated = recents.filter { $0 != emoji }
        updated.insert(emoji, at: 0)
        recentStorage = updated.prefix(Self.maximumRecents).joined(separator: "\n")
    }
}

// MARK: - Gradient Editor

/// What the gradient editor sheet was opened for. `.sheet(item:)` keys on `id`,
/// and a "new" request carries the id its `CustomGradient` will keep once
/// saved, so re-opening the editor for the same swatch reuses the sheet.
struct GradientEditorRequest: Identifiable {
    let id: UUID
    let gradient: CustomGradient
    let isNew: Bool

    /// The gradient a fresh "+" starts from. Fixed, rather than a copy of
    /// whatever swatch happened to be selected, so what the editor opens with
    /// is predictable.
    static func new() -> GradientEditorRequest {
        let gradient = CustomGradient(
            definition: GradientDefinition(
                // Written as exact 255ths: rounded decimals land a channel or
                // two off, and the stop rows show these as hex.
                colors: [
                    CodableColor(red: 1, green: 166 / 255, blue: 0),           // #FFA600
                    CodableColor(red: 1, green: 99 / 255, blue: 97 / 255),     // #FF6361
                    CodableColor(red: 0, green: 63 / 255, blue: 92 / 255),     // #003F5C
                ],
                angle: 35,
                locations: [0, 0.5, 1],
                kind: .linear
            )
        )
        return GradientEditorRequest(id: gradient.id, gradient: gradient, isNew: true)
    }

    static func edit(_ gradient: CustomGradient) -> GradientEditorRequest {
        GradientEditorRequest(id: gradient.id, gradient: gradient, isNew: false)
    }
}

/// One stop while it is being edited. Carries its own identity so a row keeps
/// its text-field state when the list re-sorts under a dragged handle —
/// positions in `GradientDefinition` are a parallel array with no identity of
/// their own.
struct EditableGradientStop: Identifiable, Equatable {
    let id = UUID()
    var color: CodableColor
    var location: Double
}

/// Builds a `CustomGradient`: type, angle, and any number of colour stops that
/// can be dragged on the ramp or typed exactly.
struct GradientEditorSheet: View {
    let gradient: CustomGradient
    let isNew: Bool
    let onSave: (CustomGradient) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var stops: [EditableGradientStop] = []
    @State private var kind: GradientKind = .linear
    @State private var angle: Double = 0
    @State private var selectedStopID: UUID?
    /// The stop currently under the pointer, resolved once at mouse-down and
    /// held for the whole drag — re-resolving per event would hand the drag to
    /// a neighbour the moment the pin passed over it.
    @State private var activeStopDrag: StopDrag?

    struct StopDrag: Equatable {
        let id: UUID
        /// Tip position minus grab position, so the pin keeps its grip.
        let grabOffset: CGFloat
    }

    private static let maximumStops = 12
    private static let barCoordinateSpace = "gradientStopBar"
    private static let rampHeight: CGFloat = 26
    /// Pin geometry: a square body, a tail below it, and the amount the tip
    /// sinks into the ramp so the two read as connected.
    private static let pinWidth = GradientStopBarGeometry.pinWidth
    private static let pinTailHeight: CGFloat = 8
    private static let pinSwatchSide: CGFloat = 14
    private static let pinOverlap: CGFloat = 2
    private static var pinHeight: CGFloat { pinWidth + pinTailHeight }

    /// The gradient as currently edited — the single source the preview, the
    /// ramp and the saved value all read, so they cannot drift apart.
    private var definition: GradientDefinition {
        let sorted = stops.sorted { $0.location < $1.location }
        return GradientDefinition(
            colors: sorted.map(\.color),
            angle: angle,
            locations: sorted.map(\.location),
            kind: kind
        )
    }

    private var sortedStops: [EditableGradientStop] {
        stops.sorted { $0.location < $1.location }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "New Gradient" : "Edit Gradient")
                .font(.headline)

            preview
            typeRow
            if kind == .linear {
                angleRow
            }
            stopBar
            stopsList

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add Gradient" : "Save") {
                    onSave(CustomGradient(id: gradient.id, definition: definition))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(stops.count < 2)
            }
        }
        .padding(18)
        .frame(width: 440)
        .onAppear(perform: loadGradient)
    }

    private func loadGradient() {
        guard stops.isEmpty else { return }
        let definition = gradient.definition
        let locations = definition.resolvedLocations
        stops = zip(definition.colors, locations).map {
            EditableGradientStop(color: $0, location: Double($1))
        }
        kind = definition.kind
        angle = definition.angle
        selectedStopID = stops.first?.id
    }

    // MARK: Preview

    private var preview: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(.clear)
            .frame(height: 120)
            .overlay(CheckerboardView())
            .overlay(definition.swiftUIFill)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.primary.opacity(0.15), lineWidth: 0.5)
            )
    }

    // MARK: Type / angle

    private var typeRow: some View {
        HStack(spacing: 8) {
            Text("Gradient Type")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Picker("", selection: $kind) {
                ForEach(GradientKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .labelsHidden()
            .frame(width: 130)

            Spacer()

            Button(action: reverseStops) {
                Image(systemName: "arrow.left.arrow.right")
            }
            .help("Reverse Stops")

            Button {
                angle = (angle + 90).truncatingRemainder(dividingBy: 360)
            } label: {
                Image(systemName: "rotate.right")
            }
            .help("Rotate 90°")
            .disabled(kind != .linear)
        }
    }

    /// The same control the Edit panel's Light/Color/Detail and Straighten rows
    /// use. `zeroPoint` is 0° — the fill grows from the left as the angle
    /// increases, and a double-click resets to the left → right direction the
    /// stop ramp itself is drawn in.
    private var angleRow: some View {
        AdjustmentSlider(
            label: "Angle",
            value: Binding(
                get: { Float(angle) },
                set: { angle = Double($0) }
            ),
            range: 0...360,
            zeroPoint: 0,
            step: 1,
            display: { "\(Int($0.rounded()))°" }
        )
    }

    private func reverseStops() {
        for index in stops.indices {
            stops[index].location = 1 - stops[index].location
        }
    }

    // MARK: Stop ramp

    /// The ramp is always drawn left → right, whatever `kind` and `angle` are:
    /// it is the axis the stops are positioned along, not a preview of the
    /// finished gradient (that is what `preview` above is for).
    ///
    /// The stops sit **above** the ramp on pins that point down at it, so the
    /// gradient itself is never covered by its own handles.
    private var stopBar: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .topLeading) {
                ramp(width: width)
                    .offset(y: Self.pinHeight - Self.pinOverlap)
                ForEach(sortedStops) { stop in
                    pin(for: stop, barWidth: width)
                        // The stop being worked on draws over its neighbours,
                        // so the one you are aiming at is the one on top.
                        .zIndex(selectedStopID == stop.id ? 1 : 0)
                }
                // One hit layer over the whole pin band. Pins overlap as soon
                // as two stops are close, and per-pin hit rects then fight
                // over the click — whichever happened to be drawn last won,
                // which is not the one being aimed at.
                Color.clear
                    .frame(width: width, height: Self.pinHeight)
                    .contentShape(Rectangle())
                    .gesture(pinDrag(barWidth: width))
                    .zIndex(2)
            }
        }
        .frame(height: Self.pinHeight - Self.pinOverlap + Self.rampHeight)
        .coordinateSpace(name: Self.barCoordinateSpace)
    }

    private func ramp(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(.clear)
            .overlay(CheckerboardView())
            .overlay(
                LinearGradient(
                    stops: definition.swiftUIStops,
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.primary.opacity(0.15), lineWidth: 0.5)
            )
            .frame(width: width, height: Self.rampHeight)
            .contentShape(Rectangle())
            .onTapGesture { location in
                addStop(at: location.x / max(width, 1))
            }
    }

    /// A stop handle: a swatch on a pin whose tip marks the exact position.
    ///
    /// The **body is clamped to the ramp** while the **tip is not** — at 0% and
    /// 100% the body stays fully on screen and the tail slides into the
    /// corner nearest the edge, so the tip still points precisely at the stop
    /// instead of the handle drifting off the end or hanging over it.
    private func pin(for stop: EditableGradientStop, barWidth: CGFloat) -> some View {
        let isSelected = selectedStopID == stop.id
        let stopX = CGFloat(stop.location) * barWidth
        let bodyLeft = GradientStopBarGeometry.bodyLeft(tipX: stopX, barWidth: barWidth)
        let shape = GradientStopPin(tipX: stopX - bodyLeft, tailHeight: Self.pinTailHeight, cornerRadius: 7)
        return shape
            .fill(isSelected ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
            .overlay(shape.stroke(Color.primary.opacity(isSelected ? 0 : 0.18), lineWidth: 0.5))
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(stop.color.swiftUIColor)
                    .frame(width: Self.pinSwatchSide, height: Self.pinSwatchSide)
                    .padding(.top, (Self.pinWidth - Self.pinSwatchSide) / 2)
            }
            .shadow(color: .black.opacity(0.22), radius: 2, y: 1)
            .frame(width: Self.pinWidth, height: Self.pinHeight)
            .offset(x: bodyLeft)
            // Purely visual — the shared hit layer above owns every click.
            .allowsHitTesting(false)
    }

    private func stopID(grabbedAt x: CGFloat, barWidth: CGFloat) -> UUID? {
        guard let index = GradientStopBarGeometry.grabbedStop(
            at: x, locations: stops.map(\.location), barWidth: barWidth)
        else { return nil }
        return stops[index].id
    }

    /// Drags a stop, keeping the grab point fixed relative to the tip — so
    /// grabbing a pin by its body doesn't teleport the tip under the cursor,
    /// and a click that doesn't move only selects.
    private func pinDrag(barWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.barCoordinateSpace))
            .onChanged { value in
                let drag: StopDrag
                if let activeStopDrag {
                    drag = activeStopDrag
                } else {
                    guard let id = stopID(grabbedAt: value.startLocation.x, barWidth: barWidth),
                          let stop = stops.first(where: { $0.id == id })
                    else { return }
                    drag = StopDrag(
                        id: id,
                        grabOffset: CGFloat(stop.location) * barWidth - value.startLocation.x
                    )
                    activeStopDrag = drag
                    selectedStopID = id
                }
                guard let index = stops.firstIndex(where: { $0.id == drag.id }) else { return }
                let tipX = value.location.x + drag.grabOffset
                stops[index].location = min(max(Double(tipX / max(barWidth, 1)), 0), 1)
            }
            .onEnded { _ in activeStopDrag = nil }
    }

    /// Inserts a stop at `fraction`, taking the colour the gradient already has
    /// there so the ramp does not jump when a stop is added.
    private func addStop(at fraction: Double) {
        guard stops.count < Self.maximumStops else { return }
        let clamped = min(max(fraction, 0), 1)
        let new = EditableGradientStop(color: color(at: clamped), location: clamped)
        stops.append(new)
        selectedStopID = new.id
    }

    /// Samples the current ramp, interpolating between the two stops that
    /// straddle `fraction`.
    private func color(at fraction: Double) -> CodableColor {
        let ordered = sortedStops
        guard let first = ordered.first, let last = ordered.last else {
            return CodableColor(red: 0.5, green: 0.5, blue: 0.5)
        }
        if fraction <= first.location { return first.color }
        if fraction >= last.location { return last.color }
        for (lower, upper) in zip(ordered, ordered.dropFirst()) {
            guard fraction >= lower.location, fraction <= upper.location else { continue }
            let span = upper.location - lower.location
            let t = span > 0 ? (fraction - lower.location) / span : 0
            let mix = { (a: CGFloat, b: CGFloat) in a + (b - a) * CGFloat(t) }
            return CodableColor(
                red: mix(lower.color.red, upper.color.red),
                green: mix(lower.color.green, upper.color.green),
                blue: mix(lower.color.blue, upper.color.blue),
                alpha: mix(lower.color.alpha, upper.color.alpha)
            )
        }
        return last.color
    }

    // MARK: Stops list

    private var stopsList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Stops")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    addStop(at: nextStopFraction())
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Add Stop")
                .disabled(stops.count >= Self.maximumStops)
            }

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(sortedStops) { stop in
                        GradientStopRow(
                            stop: binding(for: stop.id),
                            isSelected: selectedStopID == stop.id,
                            canRemove: stops.count > 2,
                            onSelect: { selectedStopID = stop.id },
                            onRemove: {
                                stops.removeAll { $0.id == stop.id }
                                if selectedStopID == stop.id { selectedStopID = stops.first?.id }
                            }
                        )
                    }
                }
            }
            .frame(maxHeight: 148)
        }
    }

    /// Where the "+" button drops a new stop: the middle of the widest gap, so
    /// repeated clicks spread out instead of stacking on one spot.
    private func nextStopFraction() -> Double {
        let ordered = sortedStops
        guard ordered.count > 1 else { return 0.5 }
        var best = (gap: -1.0, middle: 0.5)
        for (lower, upper) in zip(ordered, ordered.dropFirst()) {
            let gap = upper.location - lower.location
            if gap > best.gap { best = (gap, lower.location + gap / 2) }
        }
        return best.middle
    }

    private func binding(for id: UUID) -> Binding<EditableGradientStop> {
        Binding(
            get: {
                stops.first { $0.id == id }
                    ?? EditableGradientStop(color: CodableColor(red: 0, green: 0, blue: 0), location: 0)
            },
            set: { updated in
                guard let index = stops.firstIndex(where: { $0.id == id }) else { return }
                stops[index] = updated
            }
        )
    }
}

/// A rounded-square badge with a tail hanging off its bottom edge, ending in a
/// point at `tipX`. The tail is clamped inside the badge, so a tip at either
/// end turns it into a pulled-out corner rather than pushing the point past
/// the body.
///
/// Body and tail are `union`ed rather than filled as overlapping subpaths: a
/// non-zero fill of two subpaths only unions cleanly when both wind the same
/// way, and `CGPath(roundedRect:)`'s winding is not something to depend on.
private struct GradientStopPin: Shape {
    /// Where the point sits, in the pin's own coordinates — not necessarily
    /// the centre, because the caller clamps the body to the ramp.
    var tipX: CGFloat
    var tailHeight: CGFloat
    var cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let bodyHeight = max(rect.height - tailHeight, 1)
        let body = CGPath(
            roundedRect: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: bodyHeight),
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )

        let apex = min(max(tipX, rect.minX), rect.maxX)
        // Wider than it is tall: a 45° point reads as a spike rather than
        // the stubby speech-bubble tail this is meant to be.
        let halfBase = max(tailHeight * 1.3, 5)
        let left = min(max(apex - halfBase, rect.minX), rect.maxX)
        let right = min(max(apex + halfBase, rect.minX), rect.maxX)
        // The base starts a corner radius up inside the body, so the tail
        // still meets solid edge when it is sitting over a rounded corner.
        let baseY = max(bodyHeight - cornerRadius, rect.minY)
        let tail = CGMutablePath()
        tail.move(to: CGPoint(x: left, y: baseY))
        tail.addLine(to: CGPoint(x: apex, y: rect.maxY))
        tail.addLine(to: CGPoint(x: right, y: baseY))
        tail.closeSubpath()

        return Path(body.union(tail))
    }
}

/// One row of the gradient editor's stop list: position, colour well, hex and
/// opacity — the same four fields Figma's gradient panel offers.
private struct GradientStopRow: View {
    @Binding var stop: EditableGradientStop
    let isSelected: Bool
    let canRemove: Bool
    let onSelect: () -> Void
    let onRemove: () -> Void

    /// The hex field needs its own text so a half-typed value isn't parsed
    /// away mid-keystroke; it is re-synced whenever the stop's colour changes
    /// from somewhere else (the colour well, a drag on the ramp).
    @State private var hexText: String = ""

    private var percentBinding: Binding<Int> {
        Binding(
            get: { Int((stop.location * 100).rounded()) },
            set: { stop.location = min(max(Double($0) / 100, 0), 1) }
        )
    }

    private var opacityBinding: Binding<Int> {
        Binding(
            get: { Int((stop.color.alpha * 100).rounded()) },
            set: {
                let alpha = min(max(CGFloat($0) / 100, 0), 1)
                stop.color = CodableColor(
                    red: stop.color.red,
                    green: stop.color.green,
                    blue: stop.color.blue,
                    alpha: alpha
                )
            }
        )
    }

    /// The colour well edits RGB only — opacity has its own field, and two
    /// controls writing one value fight each other.
    private var colorBinding: Binding<Color> {
        Binding(
            get: { Color(red: stop.color.red, green: stop.color.green, blue: stop.color.blue) },
            set: { newValue in
                let resolved = CodableColor(newValue)
                stop.color = CodableColor(
                    red: resolved.red,
                    green: resolved.green,
                    blue: resolved.blue,
                    alpha: stop.color.alpha
                )
            }
        )
    }

    var body: some View {
        HStack(spacing: 6) {
            TextField("", value: percentBinding, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 46)
            Text("%")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            ColorPicker("", selection: colorBinding, supportsOpacity: false)
                .labelsHidden()

            TextField("", text: $hexText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 78)
                .onSubmit(commitHex)

            TextField("", value: opacityBinding, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 42)
            Text("%")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            Button(action: onRemove) {
                Image(systemName: "minus")
            }
            .buttonStyle(.borderless)
            .disabled(!canRemove)
            .help("Remove Stop")
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onAppear { hexText = stop.color.hexString }
        .onChange(of: stop.color) { _, newValue in
            guard newValue.hexString != hexText.trimmingCharacters(in: .whitespaces).uppercased() else { return }
            hexText = newValue.hexString
        }
    }

    private func commitHex() {
        guard let parsed = CodableColor.fromHex(hexText, alpha: stop.color.alpha) else {
            hexText = stop.color.hexString
            return
        }
        stop.color = parsed
        hexText = parsed.hexString
    }
}
