import SwiftUI

struct SettingsView: View {
    let appSettings: AppSettings

    var body: some View {
        TabView {
            GeneralSettingsView(appSettings: appSettings)
                .tabItem { Label("General", systemImage: "gear") }
#if !APPSTORE
            PresetsSettingsView(appSettings: appSettings)
                .tabItem { Label("Sizes", systemImage: "ruler") }
#endif
            TemplateSettingsView(appSettings: appSettings)
                .tabItem { Label("Background", systemImage: "photo") }
            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 500, height: 480)
    }
}
