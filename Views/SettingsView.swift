import SwiftUI

struct SettingsView: View {
    let appSettings: AppSettings

    private var settingsHeight: CGFloat {
#if APPSTORE
        300
#else
        380
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
