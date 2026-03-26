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
        // Sandboxed: fall back to the app container until the user picks a
        // folder via NSOpenPanel (which grants user-selected.read-write access).
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("SimplShot/Screenshots")
#else
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/SimplShot Screenshots")
#endif
    }()

    /// The URL shown in the NSOpenPanel when prompting the user to choose a
    /// save folder for the first time (App Store build only).
    static let suggestedScreenshotURL: URL = {
        let base = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        return base.appendingPathComponent("SimplShot Screenshots")
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
        static let editorShowProSidebar = "editorShowProSidebar"
        static let hasShownPermissionOnboarding = "hasShownPermissionOnboarding"
        static let screenshotSaveBookmark = "screenshotSaveBookmark"
        static let customBackgroundImages = "customBackgroundImages"
        static let annotationSaveCount = "annotationSaveCount"
    }
}
