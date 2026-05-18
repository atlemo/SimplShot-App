import SwiftUI

/// The sidebar content shown when the editor is in Edit mode.
/// Provides sliders for non-destructive Core Image photo adjustments
/// and a crop shortcut that delegates to the existing crop flow.
struct PhotoEditSidebarSection: View {
    @Binding var adjustments: PhotoAdjustments
    var isCropping: Bool
    var onEnterCrop: () -> Void
    var onApplyCrop: () -> Void
    var onCancelCrop: () -> Void

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
                        sectionDivider
                    } else {
                        adjustmentsSection
                        sectionDivider
                        cropSection
                        sectionDivider
                    }
                }
                .padding(.bottom, 16)
            }
        }
    }

    // MARK: - Active crop section (Apply / Cancel)

    private var activeCropSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Crop")
            Text("Drag the handles on the image to set the crop area.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
