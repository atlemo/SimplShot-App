import SwiftUI

struct WhatsNewEntry {
    let version: String
    let items: [String]
}

/// Hardcoded changelog — add new entries at the top before each release.
let whatsNewEntries: [WhatsNewEntry] = [
    WhatsNewEntry(version: "1.6.5", items: [
        "Multi-page PDFs now render correctly — pages after the first are no longer cropped or shrunk, and rotated (e.g. scanned) pages appear upright and full size",
        "Scanned and image-based PDFs now copy, save and print at full resolution instead of looking soft",
        "Selecting the Arrow or Shapes tool no longer pops open its style picker automatically — click the tool again to change its style",
        "The toolbar now shows the focus highlight on the active tool instead of the pointer",
        "Fixed a freeze when applying a template whose watermark image was missing or slow to load, and templates now apply faster",
    ]),
    WhatsNewEntry(version: "1.6.4", items: [
        "Crop tool: choose a preset aspect ratio (1:1, 4:3, 16:9 and more), and drag inside the selection to reposition it",
        "Save As now lets you choose the file format — PNG, JPEG, HEIC or WebP",
        "Color picker: fixed the black-and-white grid glitch and made the live magnifier much smoother",
        "Background panel: added a Padding label, renamed “Effects” to “Background Effects”, and the Alignment & Ratio controls now stay disabled until a background is applied",
    ]),
    WhatsNewEntry(version: "1.1", items: [
        "Print support — print open images and documents (Cmd+P)",
        "TelemetryDeck analytics for usage insights",
        "What's New dialog after updates",
    ]),
]

struct WhatsNewView: View {
    let entries: [WhatsNewEntry]
    var onDismiss: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                Text("What's New in SimplShot")
                    .font(.title2)
                    .fontWeight(.semibold)
            }
            .padding(.top, 24)
            .padding(.bottom, 16)

            // Changelog
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(entries, id: \.version) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Version \(entry.version)")
                                .font(.headline)
                            ForEach(entry.items, id: \.self) { item in
                                HStack(alignment: .top, spacing: 8) {
                                    Text("•")
                                        .foregroundStyle(.secondary)
                                    Text(item)
                                }
                                .font(.body)
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
            }
            .frame(maxHeight: 260)

            // Dismiss button
            Button("Continue") {
                onDismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .frame(width: 380)
    }
}

// MARK: - Version check logic

struct WhatsNewService {
    private static let lastSeenVersionKey = "WhatsNewLastSeenVersion"

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    static var shouldShow: Bool {
        let lastSeen = UserDefaults.standard.string(forKey: lastSeenVersionKey)
        // Don't show on fresh install (no previous version recorded)
        guard let lastSeen, !lastSeen.isEmpty else {
            markAsSeen()
            return false
        }
        return lastSeen != currentVersion && !whatsNewEntries.isEmpty
    }

    static func markAsSeen() {
        UserDefaults.standard.set(currentVersion, forKey: lastSeenVersionKey)
    }

    /// Returns entries newer than the last seen version (or all if parsing fails).
    static func relevantEntries(since lastSeen: String? = nil) -> [WhatsNewEntry] {
        let previous = lastSeen ?? UserDefaults.standard.string(forKey: lastSeenVersionKey) ?? "0"
        return whatsNewEntries.filter { compareVersions($0.version, isNewerThan: previous) }
    }

    private static func compareVersions(_ a: String, isNewerThan b: String) -> Bool {
        let aParts = a.split(separator: ".").compactMap { Int($0) }
        let bParts = b.split(separator: ".").compactMap { Int($0) }
        let count = max(aParts.count, bParts.count)
        for i in 0..<count {
            let av = i < aParts.count ? aParts[i] : 0
            let bv = i < bParts.count ? bParts[i] : 0
            if av > bv { return true }
            if av < bv { return false }
        }
        return false
    }
}
