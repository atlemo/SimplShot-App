import Foundation

enum Constants {
    static let defaultWidthPresets: [WidthPreset] = [
        WidthPreset(width: 960, isBuiltIn: true),
        WidthPreset(width: 1280, isBuiltIn: true),
        WidthPreset(width: 1920, isBuiltIn: true),
    ]

    static let defaultAspectRatios: [AspectRatio] = [
        AspectRatio(widthComponent: 16, heightComponent: 9, isBuiltIn: true),
        AspectRatio(widthComponent: 4, heightComponent: 3, isBuiltIn: true),
        AspectRatio(widthComponent: 3, heightComponent: 2, isBuiltIn: true),
        AspectRatio(widthComponent: 1, heightComponent: 1, isBuiltIn: true),
    ]

    static let defaultScreenshotURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Desktop/SimplShot Screenshots")

    enum UserDefaultsKeys {
        static let widthPresets = "widthPresets"
        static let aspectRatios = "aspectRatios"
        static let screenshotFormat = "screenshotFormat"
        static let screenshotSaveURL = "screenshotSaveURL"
        static let selectedWidthID = "selectedWidthID"
        static let selectedRatioID = "selectedRatioID"
        static let selectedAppBundleID = "selectedAppBundleID"
        static let screenshotTemplate = "screenshotTemplate"
        static let openEditorAfterCapture = "openEditorAfterCapture"
        static let editorWindowSize = "editorWindowSize"
        static let editorUseTemplateBackground = "editorUseTemplateBackground"
        static let hasShownPermissionOnboarding = "hasShownPermissionOnboarding"
    }
}
