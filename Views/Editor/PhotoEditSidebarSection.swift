import SwiftUI

/// The sidebar content shown when the editor is in Edit mode.
/// Provides sliders for non-destructive Core Image photo adjustments
/// and a crop shortcut that delegates to the existing crop flow.
struct PhotoEditSidebarSection: View {
    @Binding var adjustments: PhotoAdjustments
    var metadata: ImageMetadata?
    var isCropping: Bool
    @Binding var cropAspectPreset: CropAspectPreset
    var imagePixelSize: CGSize
    var onEnterCrop: () -> Void
    var onApplyCrop: () -> Void
    var onCancelCrop: () -> Void
    var onResizeImage: (Int, Int) -> Void
    var onRotateLeft: () -> Void = {}
    var onRotateRight: () -> Void = {}

    // Resize state
    @State private var resizeWidthStr: String = ""
    @State private var resizeHeightStr: String = ""
    @State private var resizeAspectRatio: Double = 1.0
    @State private var lockAspectRatio: Bool = true

    private enum ResizeFocus: Hashable { case width, height }
    @FocusState private var resizeFocused: ResizeFocus?

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 12)
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    if isCropping {
                        // While cropping, the canvas is in interactive crop mode —
                        // the adjustment sliders are hidden and replaced with Apply/Cancel.
                        activeCropSection
                    } else {
                        adjustmentsSection
                        transformSection
                        cropSection
                        resizeSection
                        metadataSection
                    }
                }
                .padding(.bottom, 16)
            }
        }
        .onAppear { initResizeFields() }
        .onChange(of: imagePixelSize) { _, _ in initResizeFields() }
    }

    // MARK: - Active crop section (Apply / Cancel)

    private var activeCropSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Crop")
            Text("Drag the handles to resize, or drag inside to reposition.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                Text("Aspect ratio")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Picker("", selection: $cropAspectPreset) {
                    ForEach(CropAspectPreset.allCases) { preset in
                        Text(preset.rawValue).tag(preset)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 8) {
                Button(action: onApplyCrop) {
                    Label("Apply", systemImage: "checkmark")
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut(.return, modifiers: [])

                Button(action: onCancelCrop) {
                    Label("Cancel", systemImage: "xmark")
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Adjustments section

    private var adjustmentsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Adjustments")

            adjustmentRow(
                label: "Exposure",
                systemImage: "sun.max",
                value: $adjustments.exposure,
                range: -2...2,
                zeroPoint: 0,
                format: "%.2f EV"
            )
            adjustmentRow(
                label: "Brightness",
                systemImage: "brightness",
                value: $adjustments.brightness,
                range: -1...1,
                zeroPoint: 0,
                format: "%.2f"
            )
            adjustmentRow(
                label: "Contrast",
                systemImage: "circle.lefthalf.filled",
                value: $adjustments.contrast,
                range: 0.25...4.0,
                zeroPoint: 1,
                format: "%.2f"
            )
            adjustmentRow(
                label: "Saturation",
                systemImage: "drop.halffull",
                value: $adjustments.saturation,
                range: 0...2,
                zeroPoint: 1,
                format: "%.2f"
            )
            adjustmentRow(
                label: "Highlights",
                systemImage: "sun.max.fill",
                value: $adjustments.highlights,
                range: 0...2,
                zeroPoint: 1,
                format: "%.2f"
            )
            adjustmentRow(
                label: "Shadows",
                systemImage: "circle.bottomhalf.filled",
                value: $adjustments.shadows,
                range: 0...1,
                zeroPoint: 0,
                format: "%.2f"
            )
            temperatureRow
            adjustmentRow(
                label: "Sharpness",
                systemImage: "triangle",
                value: $adjustments.sharpness,
                range: 0...2,
                zeroPoint: 0,
                format: "%.2f"
            )
            adjustmentRow(
                label: "Noise",
                systemImage: "waveform.path.ecg",
                value: $adjustments.noise,
                range: 0...1,
                zeroPoint: 0,
                format: "%.2f"
            )

            Button(action: { adjustments = .default }) {
                Label("Reset All", systemImage: "arrow.counterclockwise")
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(adjustments.isDefault)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Transform section

    private var transformSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Transform")
            HStack(spacing: 8) {
                Button(action: onRotateLeft) {
                    Label("Left", systemImage: "rotate.left")
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Rotate 90° counter-clockwise")

                Button(action: onRotateRight) {
                    Label("Right", systemImage: "rotate.right")
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Rotate 90° clockwise")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Crop section

    private var cropSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Crop")
            Button(action: onEnterCrop) {
                Label("Crop Image", systemImage: "crop")
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Resize section

    private var resizeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Resize")

            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("W")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 14, alignment: .trailing)
                        TextField("", text: $resizeWidthStr)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 64)
                            .focused($resizeFocused, equals: .width)
                            .onChange(of: resizeWidthStr) { _, _ in
                                guard resizeFocused == .width, lockAspectRatio else { return }
                                if let w = Int(resizeWidthStr), w > 0, resizeAspectRatio > 0 {
                                    resizeHeightStr = "\(max(1, Int((Double(w) / resizeAspectRatio).rounded())))"
                                }
                            }
                            .onSubmit { commitResize() }
                        Text("px")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    HStack(spacing: 6) {
                        Text("H")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 14, alignment: .trailing)
                        TextField("", text: $resizeHeightStr)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 64)
                            .focused($resizeFocused, equals: .height)
                            .onChange(of: resizeHeightStr) { _, _ in
                                guard resizeFocused == .height, lockAspectRatio else { return }
                                if let h = Int(resizeHeightStr), h > 0, resizeAspectRatio > 0 {
                                    resizeWidthStr = "\(max(1, Int((Double(h) * resizeAspectRatio).rounded())))"
                                }
                            }
                            .onSubmit { commitResize() }
                        Text("px")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
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
                        .foregroundStyle(lockAspectRatio ? Color.accentColor : .secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(lockAspectRatio ? "Unlock aspect ratio" : "Lock aspect ratio")
            }

            Button("Resize", action: commitResize)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled({
                    guard let w = Int(resizeWidthStr), let h = Int(resizeHeightStr), w > 0, h > 0 else { return true }
                    return w == Int(imagePixelSize.width) && h == Int(imagePixelSize.height)
                }())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
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
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Metadata")
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
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Helpers

    /// Generic labelled slider row with a reset dot.
    private func adjustmentRow(
        label: String,
        systemImage: String,
        value: Binding<Float>,
        range: ClosedRange<Float>,
        zeroPoint: Float,
        format: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: systemImage)
                    .font(.system(size: 11))
                    .frame(width: 16)
                    .foregroundStyle(.secondary)
                Text(label)
                    .font(.system(size: 12))
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .trailing)
                // Reset dot — visible only when value differs from default
                Button {
                    value.wrappedValue = zeroPoint
                } label: {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                }
                .buttonStyle(.plain)
                .opacity(value.wrappedValue == zeroPoint ? 0 : 1)
                .animation(.easeInOut(duration: 0.15), value: value.wrappedValue == zeroPoint)
                .help("Reset \(label)")
            }
            Slider(value: value, in: range)
        }
    }

    /// Temperature slider with a warm-to-cool colour gradient track label.
    private var temperatureRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "thermometer.medium")
                    .font(.system(size: 11))
                    .frame(width: 16)
                    .foregroundStyle(.secondary)
                Text("Temperature")
                    .font(.system(size: 12))
                Spacer()
                Text("\(Int(adjustments.temperature)) K")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .trailing)
                Button {
                    adjustments.temperature = 6500
                } label: {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                }
                .buttonStyle(.plain)
                .opacity(adjustments.temperature == 6500 ? 0 : 1)
                .animation(.easeInOut(duration: 0.15), value: adjustments.temperature == 6500)
                .help("Reset Temperature")
            }
            Slider(value: $adjustments.temperature, in: 2000...10000, step: 100)
        }
    }

    private var sectionDivider: some View {
        Divider()
            .padding(.horizontal, 0)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }
}
