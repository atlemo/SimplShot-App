import Foundation
import ServiceManagement

enum ScreenshotFormat: String, Codable, CaseIterable {
    case png
    case jpeg
    case heic
    #if !APPSTORE
    case webp
    #endif

    var fileExtension: String {
        switch self {
        case .png:  return "png"
        case .jpeg: return "jpeg"
        case .heic: return "heic"
        #if !APPSTORE
        case .webp: return "webp"
        #endif
        }
    }
    /// Uses rawValue.uppercased() for all cases except WebP which needs mixed case.
    var displayName: String {
        rawValue == "webp" ? "WebP" : rawValue.uppercased()
    }
    /// Type flag for the `screencapture` CLI. WebP is not supported by
    /// screencapture — area captures use PNG and convert afterwards.
    var screencaptureType: String {
        switch self {
        case .png:  return "png"
        case .jpeg: return "jpg"
        case .heic: return "heic"
        #if !APPSTORE
        case .webp: return "png"
        #endif
        }
    }
}

@Observable
class AppSettings {
#if !APPSTORE
    var widthPresets: [WidthPreset] {
        didSet { savePresets() }
    }
    var aspectRatios: [AspectRatio] {
        didSet { saveRatios() }
    }
    var selectedWidthID: UUID? {
        didSet {
            if let id = selectedWidthID {
                UserDefaults.standard.set(id.uuidString, forKey: Constants.UserDefaultsKeys.selectedWidthID)
            }
        }
    }
    var selectedRatioID: UUID? {
        didSet {
            if let id = selectedRatioID {
                UserDefaults.standard.set(id.uuidString, forKey: Constants.UserDefaultsKeys.selectedRatioID)
            }
        }
    }
    var selectedWidthPreset: WidthPreset? {
        widthPresets.first { $0.id == selectedWidthID }
    }
    var selectedAspectRatio: AspectRatio? {
        aspectRatios.first { $0.id == selectedRatioID }
    }
    var enabledWidthPresets: [WidthPreset] {
        widthPresets.filter(\.isEnabled)
    }
    var enabledAspectRatios: [AspectRatio] {
        aspectRatios.filter(\.isEnabled)
    }
#endif

    var screenshotFormat: ScreenshotFormat {
        didSet { UserDefaults.standard.set(screenshotFormat.rawValue, forKey: Constants.UserDefaultsKeys.screenshotFormat) }
    }
    var screenshotSaveURL: URL {
        didSet { UserDefaults.standard.set(screenshotSaveURL.path, forKey: Constants.UserDefaultsKeys.screenshotSaveURL) }
    }
    var screenshotTemplate: ScreenshotTemplate {
        didSet { saveTemplate() }
    }

    var openEditorAfterCapture: Bool {
        didSet { UserDefaults.standard.set(openEditorAfterCapture, forKey: Constants.UserDefaultsKeys.openEditorAfterCapture) }
    }

    var editorUseTemplateBackground: Bool {
        didSet { UserDefaults.standard.set(editorUseTemplateBackground, forKey: Constants.UserDefaultsKeys.editorUseTemplateBackground) }
    }

    var editorShowProSidebar: Bool {
        didSet { UserDefaults.standard.set(editorShowProSidebar, forKey: Constants.UserDefaultsKeys.editorShowProSidebar) }
    }

    /// Paths to user-added custom background images, stored in Application Support.
    var customBackgroundImages: [String] {
        didSet { saveCustomBackgroundImages() }
    }

    var startAtLogin: Bool {
        didSet {
            do {
                if startAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                print("Failed to update login item: \(error)")
                // Revert to actual state on failure
                startAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }

    init() {
        // Load login item state from system
        self.startAtLogin = SMAppService.mainApp.status == .enabled

        // Load editor-after-capture preference (defaults to true)
        if UserDefaults.standard.object(forKey: Constants.UserDefaultsKeys.openEditorAfterCapture) != nil {
            self.openEditorAfterCapture = UserDefaults.standard.bool(forKey: Constants.UserDefaultsKeys.openEditorAfterCapture)
        } else {
            self.openEditorAfterCapture = true
        }

        // Load template background preference (defaults to false)
        self.editorUseTemplateBackground = UserDefaults.standard.bool(forKey: Constants.UserDefaultsKeys.editorUseTemplateBackground)

        // Load pro sidebar preference (defaults to false)
        self.editorShowProSidebar = UserDefaults.standard.bool(forKey: Constants.UserDefaultsKeys.editorShowProSidebar)

        // Load custom background images
        self.customBackgroundImages = UserDefaults.standard.stringArray(forKey: Constants.UserDefaultsKeys.customBackgroundImages) ?? []

#if !APPSTORE
        // Load width presets
        if let data = UserDefaults.standard.data(forKey: Constants.UserDefaultsKeys.widthPresets),
           let presets = try? JSONDecoder().decode([WidthPreset].self, from: data) {
            self.widthPresets = presets
        } else {
            self.widthPresets = Constants.defaultWidthPresets
        }

        // Load aspect ratios
        if let data = UserDefaults.standard.data(forKey: Constants.UserDefaultsKeys.aspectRatios),
           let ratios = try? JSONDecoder().decode([AspectRatio].self, from: data) {
            self.aspectRatios = ratios
        } else {
            self.aspectRatios = Constants.defaultAspectRatios
        }
#endif

        // Load screenshot format
        if let raw = UserDefaults.standard.string(forKey: Constants.UserDefaultsKeys.screenshotFormat),
           let format = ScreenshotFormat(rawValue: raw) {
            self.screenshotFormat = format
        } else {
            self.screenshotFormat = .png
        }

        // Load save URL
        if let path = UserDefaults.standard.string(forKey: Constants.UserDefaultsKeys.screenshotSaveURL) {
            self.screenshotSaveURL = URL(fileURLWithPath: path)
        } else {
            self.screenshotSaveURL = Constants.defaultScreenshotURL
        }

        // Load screenshot template
        if let data = UserDefaults.standard.data(forKey: Constants.UserDefaultsKeys.screenshotTemplate),
           let template = try? JSONDecoder().decode(ScreenshotTemplate.self, from: data) {
            self.screenshotTemplate = template
        } else {
            self.screenshotTemplate = .default
        }

#if !APPSTORE
        // Load persisted selections
        if let str = UserDefaults.standard.string(forKey: Constants.UserDefaultsKeys.selectedWidthID) {
            self.selectedWidthID = UUID(uuidString: str)
        }
        if let str = UserDefaults.standard.string(forKey: Constants.UserDefaultsKeys.selectedRatioID) {
            self.selectedRatioID = UUID(uuidString: str)
        }

        // Default selections to first items if nothing persisted
        if selectedWidthID == nil || selectedWidthPreset == nil {
            selectedWidthID = widthPresets.first?.id
        }
        if selectedRatioID == nil || selectedAspectRatio == nil {
            selectedRatioID = aspectRatios.first?.id
        }
#endif
    }

#if !APPSTORE
    private func savePresets() {
        if let data = try? JSONEncoder().encode(widthPresets) {
            UserDefaults.standard.set(data, forKey: Constants.UserDefaultsKeys.widthPresets)
        }
    }

    private func saveRatios() {
        if let data = try? JSONEncoder().encode(aspectRatios) {
            UserDefaults.standard.set(data, forKey: Constants.UserDefaultsKeys.aspectRatios)
        }
    }
#endif

    private func saveTemplate() {
        if let data = try? JSONEncoder().encode(screenshotTemplate) {
            UserDefaults.standard.set(data, forKey: Constants.UserDefaultsKeys.screenshotTemplate)
        }
    }

    private func saveCustomBackgroundImages() {
        UserDefaults.standard.set(customBackgroundImages, forKey: Constants.UserDefaultsKeys.customBackgroundImages)
    }

    /// Copies the image at `sourceURL` into the app's Application Support directory and
    /// adds the new path to `customBackgroundImages`. Returns the stored path.
    @discardableResult
    func addCustomBackgroundImage(from sourceURL: URL) -> String? {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let bgDir = appSupport.appendingPathComponent("SimplShot/CustomBackgrounds")
        try? fm.createDirectory(at: bgDir, withIntermediateDirectories: true)

        let fileName = UUID().uuidString + "." + sourceURL.pathExtension
        let destURL = bgDir.appendingPathComponent(fileName)
        do {
            try fm.copyItem(at: sourceURL, to: destURL)
            let path = destURL.path
            customBackgroundImages.append(path)
            return path
        } catch {
            print("Failed to copy custom background image: \(error)")
            return nil
        }
    }

    /// Removes a custom background image from the list and deletes the file.
    func removeCustomBackgroundImage(at path: String) {
        customBackgroundImages.removeAll { $0 == path }
        try? FileManager.default.removeItem(atPath: path)
    }
}
