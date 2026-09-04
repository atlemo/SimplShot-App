import SwiftUI

struct SettingsView: View {
    let appSettings: AppSettings

    /// Sized for the tallest tab (General). The non-App-Store build is taller
    /// because it shows an extra caption and the Accessibility permission row.
    ///
    /// Includes headroom for localization: the caption under a row wraps to a
    /// second line in languages whose text runs longer than English (Russian
    /// especially), so the pane needs slack beyond what the English layout uses.
    ///
    /// The "Default app" row costs ~90pt: a button plus the pane's longest
    /// caption, which wraps to two lines in English and three in Russian.
    private var settingsHeight: CGFloat {
#if APPSTORE
        580
#else
        600
#endif
    }

    var body: some View {
        TabView {
            GeneralSettingsView(appSettings: appSettings)
                .tabItem { Label("General", systemImage: "gear") }
#if !APPSTORE
            PresetsSettingsView(appSettings: appSettings)
                .tabItem { Label("Sizes", systemImage: "ruler") }
#endif
            TemplateSettingsView(appSettings: appSettings)
                .tabItem { Label("Template", systemImage: "photo") }
            ShortcutsSettingsView()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 500, height: settingsHeight)
    }
}
