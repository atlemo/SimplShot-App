import SwiftUI

struct TemplateSettingsView: View {
    @Bindable var appSettings: AppSettings

    private let labelWidth: CGFloat = 140

    var body: some View {
        VStack(spacing: 0) {
            // --- Preview ---
            settingsRow("Preview:") {
                TemplatePreviewView(
                    template: appSettings.screenshotTemplate,
                    aspectRatio: appSettings.selectedAspectRatio?.ratio ?? (16.0 / 9.0)
                )
                .frame(height: 140)
            }

            Divider().padding(.horizontal)

            // --- Enable toggle ---
            settingsRow("Background:") {
                Toggle("Apply background to screenshots", isOn: $appSettings.screenshotTemplate.isEnabled)
                    .toggleStyle(.checkbox)
            }

            Divider().padding(.horizontal)

            // --- Wallpaper picker ---
            settingsRow("Wallpaper:") {
                VStack(alignment: .leading, spacing: 8) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(BuiltInGradient.allCases) { gradient in
                                GradientSwatchView(gradient: gradient, isSelected: isGradientSelected(gradient))
                                    .onTapGesture {
                                        appSettings.screenshotTemplate.wallpaperSource = .builtInGradient(gradient)
                                    }
                            }
                        }
                        .padding(.vertical, 3)
                        .padding(.horizontal, 4)
                    }

                    HStack(spacing: 8) {
                        Button("Custom Image…") {
                            pickCustomImage()
                        }
                        .controlSize(.small)

                        if case .customImage(let path) = appSettings.screenshotTemplate.wallpaperSource {
                            Text(URL(fileURLWithPath: path).lastPathComponent)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .disabled(!appSettings.screenshotTemplate.isEnabled)
            .opacity(appSettings.screenshotTemplate.isEnabled ? 1 : 0.5)

            Divider().padding(.horizontal)

            // --- Padding ---
            settingsRow("Padding:") {
                HStack {
                    Slider(value: paddingBinding, in: 20...200, step: 10)
                        .frame(width: 200)
                    Text("\(appSettings.screenshotTemplate.padding)px")
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 50, alignment: .trailing)
                }
            }
            .disabled(!appSettings.screenshotTemplate.isEnabled)
            .opacity(appSettings.screenshotTemplate.isEnabled ? 1 : 0.5)

            Divider().padding(.horizontal)

            // --- Corner Radius ---
            settingsRow("Corner Radius:") {
                HStack {
                    Slider(value: cornerRadiusBinding, in: 0...50, step: 1)
                        .frame(width: 200)
                    Text("\(appSettings.screenshotTemplate.cornerRadius)px")
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 50, alignment: .trailing)
                }
            }
            .disabled(!appSettings.screenshotTemplate.isEnabled)
            .opacity(appSettings.screenshotTemplate.isEnabled ? 1 : 0.5)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
    }

    // MARK: - Reusable row layout (matches GeneralSettingsView)

    private func settingsRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .multilineTextAlignment(.trailing)
                .frame(width: labelWidth, alignment: .trailing)
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 12)
    }

    // MARK: - Helpers

    private var paddingBinding: Binding<Double> {
        Binding(
            get: { Double(appSettings.screenshotTemplate.padding) },
            set: { appSettings.screenshotTemplate.padding = Int($0) }
        )
    }

    private var cornerRadiusBinding: Binding<Double> {
        Binding(
            get: { Double(appSettings.screenshotTemplate.cornerRadius) },
            set: { appSettings.screenshotTemplate.cornerRadius = Int($0) }
        )
    }

    private func isGradientSelected(_ gradient: BuiltInGradient) -> Bool {
        if case .builtInGradient(let current) = appSettings.screenshotTemplate.wallpaperSource {
            return current == gradient
        }
        return false
    }

    private func pickCustomImage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK, let url = panel.url {
            appSettings.screenshotTemplate.wallpaperSource = .customImage(path: url.path)
        }
    }
}

// MARK: - Template preview

struct TemplatePreviewView: View {
    let template: ScreenshotTemplate
    let aspectRatio: Double // width / height (e.g. 16/9 = 1.77)

    var body: some View {
        GeometryReader { geo in
            // Scale padding proportionally: map the real padding (20-200)
            // into a visual range that looks good in the preview
            let paddingFraction = CGFloat(template.padding) / 200.0
            let maxPreviewPadding: CGFloat = 24
            let minPreviewPadding: CGFloat = 6
            let previewPadding = minPreviewPadding + paddingFraction * (maxPreviewPadding - minPreviewPadding)

            // Scale the corner radius proportionally for the preview.
            // Map the real radius (0-50) into a visual range for the preview.
            let radiusFraction = CGFloat(template.cornerRadius) / 50.0
            let windowCornerRadius: CGFloat = 6 + radiusFraction * 14

            // The container itself should also respect the aspect ratio.
            // Compute a container ratio that accounts for padding around the window.
            // We use a reference size to derive the proportional container ratio.
            let refWindowWidth: CGFloat = 200
            let refWindowHeight = refWindowWidth / aspectRatio
            // Use max padding for the container ratio so the outer background
            // stays a fixed size while the slider only changes the inner inset.
            let containerWidth = refWindowWidth + maxPreviewPadding * 2
            let containerHeight = refWindowHeight + maxPreviewPadding * 2
            let containerRatio = containerWidth / containerHeight

            // Compute the actual fitted container size so the background
            // image gets the correct dimensions (not the full geo size).
            let fittedSize = Self.fittedSize(in: geo.size, ratio: containerRatio)

            ZStack {
                // Background: gradient, custom image, or checkerboard
                if template.isEnabled {
                    backgroundView(in: fittedSize)
                } else {
                    CheckerboardView()
                }

                // Window mockup sized by user's aspect ratio
                RoundedRectangle(cornerRadius: windowCornerRadius)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
                    .aspectRatio(aspectRatio, contentMode: .fit)
                    .padding(previewPadding)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .aspectRatio(containerRatio, contentMode: .fit)
            .frame(maxWidth: geo.size.width, maxHeight: geo.size.height)
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    @ViewBuilder
    private func backgroundView(in size: CGSize) -> some View {
        switch template.wallpaperSource {
        case .builtInGradient(let gradient):
            let def = gradient.gradientDefinition
            let colors = def.colors.map { Color(cgColor: $0.cgColor) }
            LinearGradient(
                colors: colors,
                startPoint: GradientSwatchView.startPoint(angle: def.angle),
                endPoint: GradientSwatchView.endPoint(angle: def.angle)
            )
        case .customImage(let path):
            if let nsImage = NSImage(contentsOfFile: path) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height)
            } else {
                Color.gray
            }
        }
    }

    /// Compute the size that fits a given aspect ratio within a bounding size.
    private static func fittedSize(in bounds: CGSize, ratio: CGFloat) -> CGSize {
        if bounds.width / bounds.height > ratio {
            let h = bounds.height
            return CGSize(width: h * ratio, height: h)
        } else {
            let w = bounds.width
            return CGSize(width: w, height: w / ratio)
        }
    }
}

// MARK: - Checkerboard pattern for disabled state

struct CheckerboardView: View {
    let squareSize: CGFloat = 8
    let color1: Color = Color(white: 0.85)
    let color2: Color = Color(white: 0.95)

    var body: some View {
        Canvas { context, size in
            let cols = Int(ceil(size.width / squareSize))
            let rows = Int(ceil(size.height / squareSize))
            for row in 0..<rows {
                for col in 0..<cols {
                    let isLight = (row + col).isMultiple(of: 2)
                    let rect = CGRect(
                        x: CGFloat(col) * squareSize,
                        y: CGFloat(row) * squareSize,
                        width: squareSize,
                        height: squareSize
                    )
                    context.fill(Path(rect), with: .color(isLight ? color1 : color2))
                }
            }
        }
    }
}

// MARK: - Gradient swatch thumbnail

struct GradientSwatchView: View {
    let gradient: BuiltInGradient
    let isSelected: Bool

    var body: some View {
        let def = gradient.gradientDefinition
        let swiftUIColors = def.colors.map { Color(cgColor: $0.cgColor) }

        RoundedRectangle(cornerRadius: 6)
            .fill(
                LinearGradient(
                    colors: swiftUIColors,
                    startPoint: Self.startPoint(angle: def.angle),
                    endPoint: Self.endPoint(angle: def.angle)
                )
            )
            .frame(width: 48, height: 32)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
    }

    static func startPoint(angle: Double) -> UnitPoint {
        let radians = angle * .pi / 180
        return UnitPoint(x: 0.5 - cos(radians) * 0.5, y: 0.5 + sin(radians) * 0.5)
    }

    static func endPoint(angle: Double) -> UnitPoint {
        let radians = angle * .pi / 180
        return UnitPoint(x: 0.5 + cos(radians) * 0.5, y: 0.5 - sin(radians) * 0.5)
    }
}
