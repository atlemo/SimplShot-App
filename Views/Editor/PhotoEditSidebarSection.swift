import SwiftUI

/// The sidebar content shown when the editor is in Edit mode.
/// Provides sliders for non-destructive Core Image photo adjustments
/// and a crop shortcut that delegates to the existing crop flow.
///
/// Layout is modelled on Apple Photos' adjustment inspector: collapsible
/// sections (Light / Color / Detail / …) of `AdjustmentSlider` rows — a
/// full-width bar with the label and value inset, a centre-origin fill and a
/// thin thumb. All colours are semantic so the panel tracks light/dark mode.
struct PhotoEditSidebarSection: View {
    @Binding var adjustments: PhotoAdjustments
    var metadata: ImageMetadata?
    var imagePixelSize: CGSize
    /// True while a background template is active. Resize works on the raw
    /// screenshot, but the W/H fields show the templated canvas (screenshot +
    /// constant-pixel padding), so the result could never match the requested
    /// size and annotations would drift — disable instead of producing both.
    var resizeDisabled: Bool = false
    var onEnterCrop: () -> Void
    var onResizeImage: (Int, Int) -> Void
    var onRotateLeft: () -> Void = {}
    var onRotateRight: () -> Void = {}
    var onFlipHorizontal: () -> Void = {}
    var onFlipVertical: () -> Void = {}

    // Resize state
    @State private var resizeWidthStr: String = ""
    @State private var resizeHeightStr: String = ""
    @State private var resizeAspectRatio: Double = 1.0
    @State private var lockAspectRatio: Bool = true

    private enum ResizeFocus: Hashable { case width, height }
    @FocusState private var resizeFocused: ResizeFocus?

    // Collapsible-section state, persisted across launches as a comma list of
    // the *collapsed* sections (empty string ⇒ everything expanded).
    private enum EditSection: String, CaseIterable {
        case light, color, detail, transform, crop, resize, metadata
    }
    // Default-collapsed: Metadata (read-only, rarely needed mid-edit). Stored as
    // a comma list of the *collapsed* sections; user toggles persist over this.
    @AppStorage("simplshot.editPanel.collapsedSections") private var collapsedRaw: String = "metadata"

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 12)
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    // Note: while cropping this panel is not shown at all —
                    // `EditorSidebarView` swaps the whole sidebar for
                    // `CropSidebarPanel` in both Annotate and Edit mode.
                    lightSection
                    groupDivider
                    colorSection
                    groupDivider
                    detailSection
                    if !adjustments.isDefault {
                        resetAllRow
                    }
                    groupDivider
                    transformSection
                    groupDivider
                    cropSection
                    groupDivider
                    resizeSection
                    groupDivider
                    metadataSection
                }
                .padding(.bottom, 16)
            }
        }
        .onAppear { initResizeFields() }
        .onChange(of: imagePixelSize) { _, _ in initResizeFields() }
    }

    // MARK: - Adjustment sections

    private var lightSectionDefault: Bool {
        adjustments.exposure == 0 && adjustments.brightness == 0 &&
        adjustments.contrast == 1 && adjustments.highlights == 1 &&
        adjustments.shadows == 0
    }

    private var lightSection: some View {
        collapsibleSection(
            .light, title: "Light", icon: "sun.max.fill",
            trailingReset: lightSectionDefault ? nil : {
                adjustments.exposure = 0; adjustments.brightness = 0
                adjustments.contrast = 1; adjustments.highlights = 1
                adjustments.shadows = 0
            },
            resetHelp: "Reset Light"
        ) {
            VStack(spacing: 8) {
                AdjustmentSlider(label: "Exposure", value: $adjustments.exposure,
                                 range: -2...2, zeroPoint: 0) { String(format: "%.2f", $0) }
                AdjustmentSlider(label: "Brightness", value: $adjustments.brightness,
                                 range: -1...1, zeroPoint: 0) { String(format: "%.2f", $0) }
                AdjustmentSlider(label: "Contrast", value: $adjustments.contrast,
                                 range: 0.25...4, zeroPoint: 1) { String(format: "%.2f", $0 - 1) }
                AdjustmentSlider(label: "Highlights", value: $adjustments.highlights,
                                 range: 0...2, zeroPoint: 1) { String(format: "%.2f", $0 - 1) }
                AdjustmentSlider(label: "Shadows", value: $adjustments.shadows,
                                 range: 0...1, zeroPoint: 0) { String(format: "%.2f", $0) }
            }
        }
    }

    private var colorSectionDefault: Bool {
        adjustments.saturation == 1 && adjustments.temperature == 6500 && adjustments.tint == 0
    }

    private var colorSection: some View {
        collapsibleSection(
            .color, title: "Color", icon: "drop.fill",
            trailingReset: colorSectionDefault ? nil : {
                adjustments.saturation = 1; adjustments.temperature = 6500; adjustments.tint = 0
            },
            resetHelp: "Reset Color"
        ) {
            VStack(spacing: 8) {
                AdjustmentSlider(label: "Saturation", value: $adjustments.saturation,
                                 range: 0...2, zeroPoint: 1) { String(format: "%.2f", $0 - 1) }
                AdjustmentSlider(label: "Temperature", value: $adjustments.temperature,
                                 range: 2000...10000, zeroPoint: 6500, step: 100) { v in
                    let d = Int((v - 6500).rounded())
                    return d == 0 ? "0" : String(format: "%+d", d)
                }
                AdjustmentSlider(label: "Tint", value: $adjustments.tint,
                                 range: -100...100, zeroPoint: 0, step: 1) { v in
                    let d = Int(v.rounded())
                    return d == 0 ? "0" : String(format: "%+d", d)
                }
            }
        }
    }

    private var detailSectionDefault: Bool {
        adjustments.sharpness == 0 && adjustments.noise == 0
    }

    private var detailSection: some View {
        collapsibleSection(
            .detail, title: "Detail", icon: "wand.and.stars",
            trailingReset: detailSectionDefault ? nil : {
                adjustments.sharpness = 0; adjustments.noise = 0
            },
            resetHelp: "Reset Detail"
        ) {
            VStack(spacing: 8) {
                AdjustmentSlider(label: "Sharpness", value: $adjustments.sharpness,
                                 range: 0...2, zeroPoint: 0) { String(format: "%.2f", $0) }
                AdjustmentSlider(label: "Noise", value: $adjustments.noise,
                                 range: 0...1, zeroPoint: 0) { String(format: "%.2f", $0) }
            }
        }
    }

    private var resetAllRow: some View {
        Button(action: { adjustments = .default }) {
            Label("Reset All Adjustments", systemImage: "arrow.counterclockwise")
                .font(.system(size: 12))
                .sidebarButtonLabel()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    // MARK: - Transform section

    private var transformSection: some View {
        collapsibleSection(.transform, title: "Transform", icon: "crop.rotate") {
            HStack(spacing: 8) {
                Button(action: onRotateLeft) {
                    Label("Left", systemImage: "rotate.left")
                        .font(.system(size: 12))
                        .sidebarButtonLabel()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Rotate 90° counter-clockwise")

                Button(action: onRotateRight) {
                    Label("Right", systemImage: "rotate.right")
                        .font(.system(size: 12))
                        .sidebarButtonLabel()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Rotate 90° clockwise")
            }

            // Flip is also in the crop panel; it is repeated here so mirroring
            // an image doesn't require entering crop mode. Same actions, so the
            // two stay in step by construction.
            HStack(spacing: 8) {
                Button(action: onFlipHorizontal) {
                    Label("Horizontal",
                          systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                        .font(.system(size: 12))
                        .sidebarButtonLabel()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Flip horizontally")

                Button(action: onFlipVertical) {
                    Label("Vertical",
                          systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down")
                        .font(.system(size: 12))
                        .sidebarButtonLabel()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Flip vertically")
            }
        }
    }

    // MARK: - Crop section

    private var cropSection: some View {
        collapsibleSection(.crop, title: "Crop", icon: "crop") {
            Button(action: onEnterCrop) {
                Label("Crop Image", systemImage: "crop")
                    .font(.system(size: 12))
                    .sidebarButtonLabel()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    // MARK: - Resize section

    private var resizeSection: some View {
        collapsibleSection(.resize, title: "Resize", icon: "arrow.up.left.and.arrow.down.right") {
            VStack(alignment: .leading, spacing: 10) {
                if resizeDisabled {
                    Text("Remove the background to resize the image.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Text("W")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        TextField("", text: $resizeWidthStr)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: .infinity)
                            .focused($resizeFocused, equals: .width)
                            .onChange(of: resizeWidthStr) { _, _ in
                                guard resizeFocused == .width, lockAspectRatio else { return }
                                if let w = Int(resizeWidthStr), w > 0, resizeAspectRatio > 0 {
                                    resizeHeightStr = "\(max(1, Int((Double(w) / resizeAspectRatio).rounded())))"
                                }
                            }
                            .onSubmit { commitResize() }
                    }

                    Button {
                        lockAspectRatio.toggle()
                        if lockAspectRatio {
                            // Recalculate aspect ratio from current field values
                            if let w = Int(resizeWidthStr), let h = Int(resizeHeightStr), w > 0, h > 0 {
                                resizeAspectRatio = Double(w) / Double(h)
                            }
                        }
                    } label: {
                        Image(systemName: lockAspectRatio ? "lock.fill" : "lock.open")
                            .font(.system(size: 12))
                            .foregroundStyle(lockAspectRatio ? Color.simplShotOrange : .secondary)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(lockAspectRatio ? "Unlock aspect ratio" : "Lock aspect ratio")

                    HStack(spacing: 6) {
                        Text("H")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        TextField("", text: $resizeHeightStr)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: .infinity)
                            .focused($resizeFocused, equals: .height)
                            .onChange(of: resizeHeightStr) { _, _ in
                                guard resizeFocused == .height, lockAspectRatio else { return }
                                if let h = Int(resizeHeightStr), h > 0, resizeAspectRatio > 0 {
                                    resizeWidthStr = "\(max(1, Int((Double(h) * resizeAspectRatio).rounded())))"
                                }
                            }
                            .onSubmit { commitResize() }
                    }
                }

                Button(action: commitResize) {
                    Text("Resize")
                        .sidebarButtonLabel()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                    .disabled({
                        guard let w = Int(resizeWidthStr), let h = Int(resizeHeightStr), w > 0, h > 0 else { return true }
                        return w == Int(imagePixelSize.width) && h == Int(imagePixelSize.height)
                    }())
            }
            .disabled(resizeDisabled)
        }
    }

    private func initResizeFields() {
        guard imagePixelSize.width > 0, imagePixelSize.height > 0 else { return }
        resizeAspectRatio = imagePixelSize.width / imagePixelSize.height
        resizeWidthStr = "\(Int(imagePixelSize.width))"
        resizeHeightStr = "\(Int(imagePixelSize.height))"
    }

    private func commitResize() {
        guard let w = Int(resizeWidthStr), let h = Int(resizeHeightStr), w > 0, h > 0 else { return }
        guard w != Int(imagePixelSize.width) || h != Int(imagePixelSize.height) else { return }
        onResizeImage(w, h)
    }

    // MARK: - Metadata section

    private var metadataSection: some View {
        collapsibleSection(.metadata, title: "Metadata", icon: "info.circle") {
            if let metadata, !metadata.rows.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(metadata.rows, id: \.label) { row in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(row.label)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .frame(width: 52, alignment: .leading)
                            Text(row.value)
                                .font(.system(size: 11))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .textSelection(.enabled)
                            Spacer(minLength: 0)
                        }
                    }
                }
            } else {
                Text("No metadata available")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Collapsible section scaffolding

    private func isExpanded(_ section: EditSection) -> Bool {
        !collapsedSet.contains(section)
    }

    private var collapsedSet: Set<EditSection> {
        Set(collapsedRaw.split(separator: ",").compactMap { EditSection(rawValue: String($0)) })
    }

    private func toggle(_ section: EditSection) {
        var set = collapsedSet
        if set.contains(section) { set.remove(section) } else { set.insert(section) }
        withAnimation(.easeInOut(duration: 0.2)) {
            collapsedRaw = set.map(\.rawValue).sorted().joined(separator: ",")
        }
    }

    /// A section with an icon header that toggles a disclosure. `trailingReset`,
    /// when non-nil, shows a reset glyph on the right of the header.
    private func collapsibleSection<C: View>(
        _ section: EditSection,
        title: LocalizedStringKey,
        icon: String,
        trailingReset: (() -> Void)? = nil,
        resetHelp: LocalizedStringKey = "Reset",
        @ViewBuilder content: () -> C
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            groupHeader(section, title: title, icon: icon, trailingReset: trailingReset, resetHelp: resetHelp)
            if isExpanded(section) {
                content()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .animation(.easeInOut(duration: 0.15), value: trailingReset != nil)
    }

    private func groupHeader(
        _ section: EditSection,
        title: LocalizedStringKey,
        icon: String,
        trailingReset: (() -> Void)?,
        resetHelp: LocalizedStringKey = "Reset"
    ) -> some View {
        HStack(spacing: 0) {
            Button { toggle(section) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded(section) ? 90 : 0))
                        .frame(width: 10)
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.simplShotOrange)
                        .frame(width: 18)
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let trailingReset {
                Button(action: trailingReset) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(resetHelp)
                .transition(.opacity)
            }
        }
    }

    private var groupDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.07))
            .frame(height: 1)
            .padding(.horizontal, 14)
    }
}

// MARK: - Edit panel accent

private extension Color {
    /// SimplShot accent — #FF4800. Used across the Edit panel (section icons,
    /// slider fill/thumb, aspect-lock) so the whole panel shares one tint.
    static let simplShotOrange = Color(red: 1.0, green: 72.0 / 255.0, blue: 0.0)
}

// MARK: - AdjustmentSlider

/// A Photos-style adjustment control: a full-width rounded bar with the label
/// inset on the left and the formatted value on the right, a fill that grows
/// from `zeroPoint` toward the thumb, and a thin vertical thumb. Drag anywhere
/// on the bar to scrub; double-click to reset to `zeroPoint`.
private struct AdjustmentSlider: View {
    let label: LocalizedStringKey
    @Binding var value: Float
    let range: ClosedRange<Float>
    /// The value the fill originates from (centre for bipolar controls, an edge
    /// for unipolar ones). Double-click resets here.
    let zeroPoint: Float
    var step: Float? = nil
    let display: (Float) -> String
    /// Called with `true` when scrubbing begins and `false` when it ends.
    var onEditingChanged: (Bool) -> Void = { _ in }

    @State private var isDragging = false
    @State private var isHovering = false

    /// Slider accent — SimplShot orange (#FF4800), used for the fill and thumb.
    private static let tint = Color.simplShotOrange

    private let barHeight: CGFloat = 28
    private let corner: CGFloat = 7

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let thumbX = min(max(fraction(for: value) * w, 0), w)
            let zeroX = min(max(zeroFraction * w, 0), w)

            ZStack(alignment: .leading) {
                // Track
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(Color.primary.opacity(isHovering || isDragging ? 0.10 : 0.07))

                // Fill from the zero origin toward the thumb
                Rectangle()
                    .fill(Self.tint.opacity(0.28))
                    .frame(width: abs(thumbX - zeroX))
                    .offset(x: min(zeroX, thumbX))

                // Subtle ruler ticks while scrubbing
                if isDragging {
                    ticks(width: w)
                }

                // Label + value
                HStack(spacing: 8) {
                    Text(label)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        // Localized labels run longer than the English ones
                        // (Russian especially) — shrink slightly rather than
                        // truncate inside the fixed-width sidebar.
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 4)
                    Text(display(value))
                        .font(.system(size: 11.5))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .allowsHitTesting(false)

                // Thumb
                Capsule()
                    .fill(Self.tint)
                    .frame(width: 2.5, height: barHeight - 12)
                    .shadow(color: .black.opacity(0.22), radius: 0.5)
                    .offset(x: min(max(thumbX - 1.25, 1), w - 3.5))
                    .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if !isDragging { isDragging = true; onEditingChanged(true) }
                        setValue(atX: g.location.x, width: w)
                    }
                    .onEnded { _ in isDragging = false; onEditingChanged(false) }
            )
            .onTapGesture(count: 2) {
                withAnimation(.easeOut(duration: 0.12)) { value = zeroPoint }
            }
            .onHover { isHovering = $0 }
        }
        .frame(height: barHeight)
    }

    /// Where `zeroPoint` sits along the bar: centred (0.5) for bipolar controls,
    /// pinned to an edge when `zeroPoint` is the range's lower/upper bound.
    private var zeroFraction: CGFloat {
        if zeroPoint <= range.lowerBound { return 0 }
        if zeroPoint >= range.upperBound { return 1 }
        return 0.5
    }

    /// Maps a value to a bar fraction. Each side of `zeroPoint` is scaled
    /// independently so the default always lands at `zeroFraction` (centre for
    /// bipolar controls) regardless of how lopsided the numeric range is.
    private func fraction(for value: Float) -> CGFloat {
        let z = zeroFraction
        if value <= zeroPoint, zeroPoint > range.lowerBound {
            return z * CGFloat((value - range.lowerBound) / (zeroPoint - range.lowerBound))
        } else if value >= zeroPoint, zeroPoint < range.upperBound {
            return z + (1 - z) * CGFloat((value - zeroPoint) / (range.upperBound - zeroPoint))
        }
        return z
    }

    private func setValue(atX x: CGFloat, width: CGFloat) {
        let f = min(max(x / width, 0), 1)
        let z = zeroFraction
        var v: Float
        if f <= z, z > 0 {
            v = range.lowerBound + Float(f / z) * (zeroPoint - range.lowerBound)
        } else if f >= z, z < 1 {
            v = zeroPoint + Float((f - z) / (1 - z)) * (range.upperBound - zeroPoint)
        } else {
            v = zeroPoint
        }
        if let step, step > 0 { v = (v / step).rounded() * step }
        value = min(max(v, range.lowerBound), range.upperBound)
    }

    /// A row of faint tick marks along the top edge, echoing the ruler that
    /// Apple Photos shows on the focused slider.
    private func ticks(width w: CGFloat) -> some View {
        let count = max(Int(w / 8), 8)
        return Canvas { context, size in
            let gap = size.width / CGFloat(count)
            var path = Path()
            for i in 0...count {
                let x = CGFloat(i) * gap
                path.move(to: CGPoint(x: x, y: 4))
                path.addLine(to: CGPoint(x: x, y: 9))
            }
            context.stroke(path, with: .color(.primary.opacity(0.18)), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Crop panel

/// The sidebar while the crop tool is active.
///
/// Cropping takes over the **whole** sidebar in both Annotate and Edit mode
/// (`EditorSidebarView` swaps this in for the tool palette / adjustment sliders),
/// so every crop control lives in one place instead of being duplicated as a
/// section in each mode. Modelled on the Photos crop inspector: the same
/// `AdjustmentSlider` used by the Light/Color/Detail rows for Straighten, then
/// flip/rotate rows, then the aspect presets listed out rather than hidden
/// behind a pop-up, with Apply/Cancel pinned to the bottom.
struct CropSidebarPanel: View {
    @Binding var aspectPreset: CropAspectPreset
    @Binding var aspectPortrait: Bool
    /// Fine straighten angle (degrees) for the current crop session.
    @Binding var straightenAngle: Double
    /// True while a control that should show the guide grid is being dragged.
    @Binding var isAdjustingCrop: Bool
    /// Straighten is only offered for plain raster images (no background
    /// template, not a PDF) — see `EditorView`'s `straightenAvailable` gating.
    var straightenAvailable: Bool = true
    var flipAvailable: Bool = true
    var onFlipHorizontal: () -> Void = {}
    var onFlipVertical: () -> Void = {}
    var onRotateLeft: () -> Void = {}
    var onRotateRight: () -> Void = {}
    var onApply: () -> Void
    var onCancel: () -> Void

    @State private var hoveredPreset: CropAspectPreset?


    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 12)

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    divider
                    transformSection
                    divider
                    aspectSection
                }
                .padding(.bottom, 12)
            }

            footer
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Crop")
            Text("Drag the handles to resize, or drag inside to reposition.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    // MARK: Straighten / flip / rotate

    private var transformSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if straightenAvailable {
                AdjustmentSlider(
                    label: "Straighten",
                    value: Binding(
                        get: { Float(straightenAngle) },
                        set: { straightenAngle = Double($0) }
                    ),
                    range: -45...45,
                    zeroPoint: 0,
                    step: 1,
                    display: { "\(Int($0.rounded()))°" },
                    onEditingChanged: { isAdjustingCrop = $0 }
                )
            }

            if flipAvailable {
                controlRow("Flip") {
                    iconButton("arrow.left.and.right.righttriangle.left.righttriangle.right",
                               help: "Flip horizontally", action: onFlipHorizontal)
                    iconButton("arrow.up.and.down.righttriangle.up.righttriangle.down",
                               help: "Flip vertically", action: onFlipVertical)
                }
            }

            controlRow("Rotate") {
                iconButton("rotate.left", help: "Rotate 90° counter-clockwise", action: onRotateLeft)
                iconButton("rotate.right", help: "Rotate 90° clockwise", action: onRotateRight)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// A label on the left and a pair of icon buttons on the right, sized to sit
    /// on the same rhythm as an `AdjustmentSlider` row.
    private func controlRow<C: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder buttons: () -> C
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12.5))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 4)
            buttons()
        }
        .frame(height: 22)
    }

    private func iconButton(_ symbol: String, help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .frame(width: 22, height: sidebarButtonContentHeight)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(help)
        .accessibilityLabel(help)
    }

    // MARK: Aspect presets

    private var aspectSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Aspect ratio")

            VStack(spacing: 1) {
                ForEach(CropAspectPreset.allCases) { preset in
                    aspectRow(preset)
                }
            }
            .padding(.horizontal, -6)

            OrientationSegmentedControl(
                portrait: $aspectPortrait,
                isEnabled: aspectPreset.supportsOrientation
            )
            .padding(.top, 2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func aspectRow(_ preset: CropAspectPreset) -> some View {
        let isSelected = preset == aspectPreset
        return Button {
            aspectPreset = preset
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(isSelected ? Color.simplShotOrange : Color.clear)
                    .frame(width: 12)
                // `label(portrait:)` returns a plain String (a ratio like "3:2"),
                // which SwiftUI does not localize — Free is the one word in the
                // list, so it goes through a literal to stay translatable.
                if preset == .free {
                    Text("Free")
                        .font(.system(size: 12.5))
                        .foregroundStyle(isSelected ? .primary : .secondary)
                } else {
                    Text(preset.label(portrait: aspectPortrait))
                        .font(.system(size: 12.5))
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hoveredPreset == preset ? Color.primary.opacity(0.07) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hoveredPreset = preset }
            else if hoveredPreset == preset { hoveredPreset = nil }
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 1)
            HStack(spacing: 8) {
                Button(action: onApply) {
                    Label("Apply", systemImage: "checkmark")
                        .font(.system(size: 12))
                        .sidebarButtonLabel()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut(.return, modifiers: [])

                Button(action: onCancel) {
                    Label("Cancel", systemImage: "xmark")
                        .font(.system(size: 12))
                        .sidebarButtonLabel()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    // MARK: Shared bits

    private func sectionTitle(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .kerning(0.5)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.07))
            .frame(height: 1)
            .padding(.horizontal, 14)
    }
}

/// Landscape ⇄ Portrait switch for the crop panel.
///
/// Drawn explicitly rather than with `Picker(.segmented)`: as
/// `EditorModeToggle` notes, the native segmented style only renders its
/// floating-capsule look inside a window *toolbar* — in plain content (the
/// sidebar) it falls back to a flat grey slab that reads as a stray button pair.
/// This mirrors that toggle's approach at sidebar density, and sits on the same
/// track fill as `AdjustmentSlider` so the whole panel shares one surface.
private struct OrientationSegmentedControl: View {
    @Binding var portrait: Bool
    /// False for symmetric presets (Free, 1:1), where swapping does nothing.
    var isEnabled: Bool

    private let height: CGFloat = 24
    private let corner: CGFloat = 7

    var body: some View {
        HStack(spacing: 2) {
            segment("Landscape", symbol: "rectangle", isSelected: !portrait) { portrait = false }
            segment("Portrait", symbol: "rectangle.portrait", isSelected: portrait) { portrait = true }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(Color.primary.opacity(0.07))
        )
        .opacity(isEnabled ? 1 : 0.4)
        .disabled(!isEnabled)
        .animation(.easeOut(duration: 0.12), value: portrait)
    }

    private func segment(
        _ title: LocalizedStringKey,
        symbol: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 9))
                Text(title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: corner - 2, style: .continuous)
                        .fill(Color.gray.opacity(0.24))
                        .shadow(color: .black.opacity(0.05), radius: 1, y: 0.5)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

// MARK: - Sidebar button sizing

/// Content height that makes every bordered button in the editor sidebar paint
/// 24pt tall.
///
/// A `.controlSize(.small)` bordered button paints around its CONTENT, and
/// `.frame(height:)` on the *button* does not change that — it only centres the
/// control inside a taller slot, which is why the buttons stayed 21pt when that
/// was tried. Intrinsic content height also varies with the glyph (a
/// `rotate.left` label measures 22pt, a `checkmark` one 21pt), so a fixed
/// padding leaves them uneven. A minimum content height is what lines them all
/// up: 18pt measured 24pt painted for every button in this panel — text labels,
/// prominent buttons and icon-only buttons alike.
private let sidebarButtonContentHeight: CGFloat = 18

private extension View {
    /// Sizes a bordered button's label so the button paints at the shared height.
    /// Deliberately no `lineLimit(1)`: a longer translation should wrap and make
    /// the button taller rather than truncate.
    func sidebarButtonLabel() -> some View {
        frame(maxWidth: .infinity, minHeight: sidebarButtonContentHeight)
    }
}
