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

    static let defaultScreenshotURL: URL = {
#if APPSTORE
        // App Sandbox does not allow writing to ~/Desktop without a TCC prompt.
        // The Downloads folder is always accessible via the
        // com.apple.security.files.downloads.read-write entitlement.
        let base = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        return base.appendingPathComponent("SimplShot Screenshots")
#else
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/SimplShot Screenshots")
#endif
    }()

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
