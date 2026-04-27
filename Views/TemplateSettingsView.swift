import SwiftUI

struct TemplateSettingsView: View {
    @Bindable var appSettings: AppSettings

    private let labelWidth: CGFloat = 140

    var body: some View {
        VStack(spacing: 0) {
            settingsRow("Preview:") {
                TemplatePreviewView(
                    template: previewTemplate,
                    aspectRatio: previewAspectRatio,
                    alignment: appSettings.defaultCaptureTemplatePreset?.alignment ?? .middleCenter,
                    shadowIntensity: appSettings.defaultCaptureTemplatePreset?.shadowIntensity ?? 1.0
                )
                .frame(height: 140)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider().padding(.horizontal)

            settingsRow("Template:") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("", selection: $appSettings.defaultCaptureTemplateID) {
                        ForEach(appSettings.editorTemplates) { template in
                            Text(template.name)
                                .tag(Optional(template.id))
                        }
                    }
                    .labelsHidden()

                    Text("Choose a template to apply to your screenshots. Leave this off if you want screenshots saved as-is, without a background.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Toggle("Apply selected template to screenshots", isOn: $appSettings.screenshotTemplate.isEnabled)
                        .toggleStyle(.checkbox)
                }
            }
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

    /// A template for the preview that always shows the background if the selected preset has one,
    /// regardless of whether "Apply selected template" is currently enabled.
    private var previewTemplate: ScreenshotTemplate {
        let base = appSettings.defaultCaptureTemplate
        let hasWallpaper = appSettings.defaultCaptureTemplatePreset?.wallpaperSource != nil
        return ScreenshotTemplate(
            isEnabled: hasWallpaper,
            wallpaperSource: base.wallpaperSource,
            padding: base.padding,
            cornerRadius: base.cornerRadius,
            watermarkSettings: base.watermarkSettings
        )
    }

    private var previewAspectRatio: Double {
#if !APPSTORE
        if let templateRatioID = appSettings.defaultCaptureTemplatePreset?.aspectRatioID,
           let ratio = appSettings.aspectRatios.first(where: { $0.id == templateRatioID })?.ratio {
            return ratio
        }
        return appSettings.selectedAspectRatio?.ratio ?? (16.0 / 9.0)
#else
        16.0 / 9.0
#endif
    }

}

// MARK: - Template preview

struct TemplatePreviewView: View {
    let template: ScreenshotTemplate
    let aspectRatio: Double // width / height (e.g. 16/9 = 1.77)
    let alignment: CanvasAlignment
    let shadowIntensity: Double

    var body: some View {
        GeometryReader { geo in
            let layout = previewLayout(in: geo.size)
            let radiusFraction = CGFloat(template.cornerRadius) / 50.0
            let windowCornerRadius: CGFloat = 6 + radiusFraction * 14
            let previewCornerRadii = cornerRadii(
                for: layout.screenshotFrame,
                in: layout.canvasSize,
                radius: windowCornerRadius
            )
            let clampedShadowIntensity = CGFloat(max(0, min(1, shadowIntensity)))
            let shadowOpacity = 0.5 * clampedShadowIntensity
            let shadowRadius = 60 * clampedShadowIntensity
            let shadowYOffset = 28 * clampedShadowIntensity

            HStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    if template.isEnabled {
                        backgroundView(in: layout.canvasSize)
                    } else {
                        CheckerboardView()
                    }

                    UnevenRoundedRectangle(cornerRadii: previewCornerRadii, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor))
                        .shadow(color: .black.opacity(shadowOpacity), radius: shadowRadius, y: shadowYOffset)
                        .overlay {
                            PreviewWindowMock()
                                .clipShape(UnevenRoundedRectangle(cornerRadii: previewCornerRadii, style: .continuous))
                        }
                        .frame(width: layout.screenshotFrame.width, height: layout.screenshotFrame.height)
                        .offset(x: layout.screenshotFrame.minX, y: layout.screenshotFrame.minY)

                    watermarkPreview(in: layout)
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .frame(width: layout.canvasSize.width, height: layout.canvasSize.height, alignment: .leading)

                Spacer(minLength: 0)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
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
        case .customColor(let color):
            Color(red: color.red, green: color.green, blue: color.blue, opacity: color.alpha)
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

    private func previewLayout(in bounds: CGSize) -> (canvasSize: CGSize, screenshotFrame: CGRect) {
        let mockScreenshotSize = CGSize(width: 280, height: 176)
        let paddingFraction = CGFloat(template.padding) / 200.0
        let minPreviewPadding: CGFloat = 8
        let maxPreviewPadding: CGFloat = 44
        let previewPadding = minPreviewPadding + paddingFraction * (maxPreviewPadding - minPreviewPadding)

        let baseWidth = mockScreenshotSize.width + previewPadding * 2
        let baseHeight = mockScreenshotSize.height + previewPadding * 2
        let targetRatio = CGFloat(max(aspectRatio, 0.1))
        let baseRatio = baseWidth / baseHeight

        let canvasReferenceWidth: CGFloat
        let canvasReferenceHeight: CGFloat

        if baseRatio < targetRatio {
            canvasReferenceWidth = baseHeight * targetRatio
            canvasReferenceHeight = baseHeight
        } else if baseRatio > targetRatio {
            canvasReferenceWidth = baseWidth
            canvasReferenceHeight = baseWidth / targetRatio
        } else {
            canvasReferenceWidth = baseWidth
            canvasReferenceHeight = baseHeight
        }

        let fittedCanvasSize = Self.fittedSize(
            in: CGSize(width: max(bounds.width - 2, 1), height: max(bounds.height - 2, 1)),
            ratio: max(canvasReferenceWidth / canvasReferenceHeight, 0.1)
        )
        let previewScale = min(
            fittedCanvasSize.width / canvasReferenceWidth,
            fittedCanvasSize.height / canvasReferenceHeight
        )
        let screenshotOrigin = CGPoint(
            x: (canvasReferenceWidth - mockScreenshotSize.width) * alignment.horizontalFraction,
            y: (canvasReferenceHeight - mockScreenshotSize.height) * alignment.verticalFraction
        )

        return (
            canvasSize: fittedCanvasSize,
            screenshotFrame: CGRect(
                x: screenshotOrigin.x * previewScale,
                y: screenshotOrigin.y * previewScale,
                width: mockScreenshotSize.width * previewScale,
                height: mockScreenshotSize.height * previewScale
            )
        )
    }

    @ViewBuilder
    private func watermarkPreview(in layout: (canvasSize: CGSize, screenshotFrame: CGRect)) -> some View {
        if template.watermarkSettings.isEnabled,
           let path = template.watermarkSettings.imagePath,
           let nsImage = NSImage(contentsOfFile: path),
           nsImage.isValid {
            let previewScale = layout.screenshotFrame.width / CGFloat(280)
            let marginH = layout.canvasSize.width * 0.02
            let marginV = layout.canvasSize.height * 0.02
            let targetW = max(1, CGFloat(template.watermarkSettings.widthPx) * previewScale)
            let rawSize = nsImage.size
            let aspect = rawSize.height > 0 ? rawSize.width / rawSize.height : 1.0
            let targetH = max(1, targetW / aspect)
            let position = watermarkPosition(
                for: template.watermarkSettings.position,
                in: layout.canvasSize,
                targetW: targetW,
                targetH: targetH,
                marginH: marginH,
                marginV: marginV
            )

            Image(nsImage: nsImage)
                .resizable()
                .frame(width: targetW, height: targetH)
                .opacity(template.watermarkSettings.opacity)
                .position(x: position.x, y: position.y)
        }
    }

    private func watermarkPosition(
        for position: WatermarkPosition,
        in canvasSize: CGSize,
        targetW: CGFloat,
        targetH: CGFloat,
        marginH: CGFloat,
        marginV: CGFloat
    ) -> CGPoint {
        switch position {
        case .topLeft:
            return CGPoint(x: marginH + targetW / 2, y: marginV + targetH / 2)
        case .topRight:
            return CGPoint(x: canvasSize.width - marginH - targetW / 2, y: marginV + targetH / 2)
        case .bottomLeft:
            return CGPoint(x: marginH + targetW / 2, y: canvasSize.height - marginV - targetH / 2)
        case .bottomRight:
            return CGPoint(x: canvasSize.width - marginH - targetW / 2, y: canvasSize.height - marginV - targetH / 2)
        }
    }

    private func cornerRadii(for frame: CGRect, in canvasSize: CGSize, radius: CGFloat) -> RectangleCornerRadii {
        let edgeTolerance: CGFloat = 0.5
        let touchesLeft = frame.minX <= edgeTolerance
        let touchesTop = frame.minY <= edgeTolerance
        let touchesRight = abs(frame.maxX - canvasSize.width) <= edgeTolerance
        let touchesBottom = abs(frame.maxY - canvasSize.height) <= edgeTolerance

        return RectangleCornerRadii(
            topLeading: touchesTop || touchesLeft ? 0 : radius,
            bottomLeading: touchesBottom || touchesLeft ? 0 : radius,
            bottomTrailing: touchesBottom || touchesRight ? 0 : radius,
            topTrailing: touchesTop || touchesRight ? 0 : radius
        )
    }
}

private struct PreviewWindowMock: View {
    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height

            VStack(spacing: 0) {
                HStack(spacing: width * 0.025) {
                    Circle()
                        .fill(Color.gray.opacity(0.35))
                        .frame(width: width * 0.035, height: width * 0.035)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.12))
                        .frame(width: width * 0.28, height: height * 0.11)
                    Spacer()
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.08))
                        .frame(width: width * 0.22, height: height * 0.11)
                }
                .padding(.horizontal, width * 0.06)
                .padding(.top, height * 0.07)
                .padding(.bottom, height * 0.05)

                Divider()
                    .overlay(Color.black.opacity(0.05))

                HStack(alignment: .top, spacing: width * 0.04) {
                    VStack(alignment: .leading, spacing: height * 0.045) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.gray.opacity(0.11))
                            .frame(width: width * 0.16, height: height * 0.06)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.gray.opacity(0.08))
                            .frame(width: width * 0.14, height: height * 0.045)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.gray.opacity(0.08))
                            .frame(width: width * 0.12, height: height * 0.045)
                    }

                    VStack(alignment: .leading, spacing: height * 0.04) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.blue.opacity(0.12))
                            .frame(width: width * 0.26, height: height * 0.08)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.gray.opacity(0.1))
                            .frame(width: width * 0.4, height: height * 0.04)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.gray.opacity(0.08))
                            .frame(width: width * 0.32, height: height * 0.04)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.gray.opacity(0.08))
                            .frame(width: width * 0.36, height: height * 0.04)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, width * 0.06)
                .padding(.top, height * 0.08)

                Spacer(minLength: 0)
            }
            .background(Color.white)
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
                    .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(gradient.needsBorder ? 0.15 : 0),
                                  lineWidth: isSelected ? 2 : 0.5)
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
