import SwiftUI

struct SettingsView: View {
    let appSettings: AppSettings

    private var settingsHeight: CGFloat {
#if APPSTORE
        400
#else
        480
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
            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 500, height: settingsHeight)
    }
}
