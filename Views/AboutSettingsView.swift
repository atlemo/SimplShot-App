import SwiftUI

struct AboutSettingsView: View {
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)

            Text("SimplShot")
                .font(.title2)
                .fontWeight(.semibold)

            Text("[www.simplshot.com](https://www.simplshot.com)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .tint(.primary)

            Text("Version \(appVersion)")
                .font(.callout)
                .foregroundStyle(.secondary)

            Text("Made by [Atle Mo](https://atle.co)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .tint(.primary)

            Spacer()

            Divider()
                .padding(.horizontal, 40)

            VStack(spacing: 4) {
                Text("Acknowledgments")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                Text("[KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) by Sindre Sorhus")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .tint(.secondary)
                Text("[Sparkle](https://sparkle-project.org) by the Sparkle Project")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .tint(.secondary)
            }
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
