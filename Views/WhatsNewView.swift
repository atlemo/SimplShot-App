import SwiftUI

struct WhatsNewEntry {
    let version: String
    /// Localized bullets. `LocalizedStringResource` (not `String`) so Xcode
    /// extracts each one into the string catalog and resolves it at display time.
    let items: [LocalizedStringResource]
}

/// Hardcoded changelog — add a new entry at the top before each release and
/// delete the oldest so the list stays at `maxWhatsNewEntries`.
///
/// The dialog only shows entries newer than the user's last-seen version
/// (`relevantEntries`), so this list is the backlog for users who skipped
/// releases. It is capped because every bullet has to be translated into
/// every supported language; someone more than `maxWhatsNewEntries` releases
/// behind simply sees the most recent ones.
let maxWhatsNewEntries = 4

let whatsNewEntries: [WhatsNewEntry] = [
    WhatsNewEntry(version: "1.7.4", items: [
        "New: Capture History — open it from the menu bar to see your last 10 captures and edited files as a film strip. Hover a thumbnail and click Restore to reopen an image with every annotation still editable.",
        "Alignment now keeps padding even — aligning to an edge puts the screenshot flush against it while the other sides keep their exact padding, instead of doubling the gap on the opposite side.",
        "Pixelation now exports exactly as previewed — saved and copied images use the same soft mosaic blocks you see in the editor.",
        "SimplShot uses much less memory — closed editing sessions are kept compressed in the background, so the app stays fast even after a long day of captures.",
    ]),
    WhatsNewEntry(version: "1.7.3", items: [
        "Fixed a serious problem introduced in the last update: SimplShot was reserving ⌘C across the whole system, so pressing Copy in any other app quietly did nothing while SimplShot was running. The Save & Copy shortcut now stays inside the editor window where it belongs, and Copy works normally everywhere else again.",
    ]),
    WhatsNewEntry(version: "1.7.2", items: [
        "Save & Copy now has a keyboard shortcut — press ⌘C in the editor to save your image, copy it to the clipboard and close the window, exactly like clicking the button. Prefer a different key? Settings › Shortcuts has a new Editor section where you can change it.",
        "SimplShot now speaks German — Deutsch joins English, French, Japanese, Russian and Simplified Chinese, so the whole interface, menus, alerts and these release notes are translated. Pick it in Settings › General, or let SimplShot follow your macOS language.",
    ]),
    WhatsNewEntry(version: "1.7.1", items: [
        "SimplShot now speaks your language — the whole interface is available in English, French, Japanese, Russian and Simplified Chinese, and it follows your macOS language automatically. Menus, the editor, alerts and even these release notes are translated.",
        "Want SimplShot in a different language than the rest of your Mac? Settings › General now opens with a Language picker. Each language is written in its own script, so you can always find your way back if you pick the wrong one by mistake. SimplShot restarts to apply the change.",
        "New print options — the print dialog now has Rotation and Scale controls. Rotation can turn the page 90° clockwise or counterclockwise, and “Auto (fit page)” rotates only when that fills the paper better, so a landscape screenshot prints large on a portrait page without any fiddling. Scale offers 25 % to 200 %, with 100 % meaning fit to page. The preview updates as you change either.",
        "Crop now reaches every edge — with an aspect ratio locked, dragging a handle no longer stalls just short of the right or bottom edge. Every handle now reaches its edge, whichever side you drag from.",
        "Flip any crop ratio between landscape and portrait — pick 3:2 and click the new orientation button to get 2:3, and the same for 4:3 and 16:9. The selection keeps its size as you flip, so you can switch back and forth freely. The separate 3:4 and 9:16 presets are gone; the button covers them for every ratio.",
        "Large images no longer look like they failed to open — while a big file is being decoded the editor shows a loading indicator instead of briefly flashing “Unable to load image”.",
        "Applying a saved template no longer nudges your annotations out of place — they keep their position relative to the screenshot when the padding, background, aspect ratio and alignment all change at once.",
        "Fixed missing drag handles on the Stroke, Font Size, Pixelation and Spotlight sliders — the knob now appears right away instead of only showing up once you'd clicked and dragged.",
        "The focus ring on the Annotate · Edit · View switch now follows the segment you actually clicked, instead of staying stuck on whichever one had it first.",
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
                            ForEach(Array(entry.items.enumerated()), id: \.offset) { _, item in
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

    /// Returns entries newer than the last seen version (or all if parsing fails),
    /// capped at `maxWhatsNewEntries` so a user returning after many releases sees
    /// the most recent ones rather than an unbounded wall of text.
    static func relevantEntries(since lastSeen: String? = nil) -> [WhatsNewEntry] {
        let previous = lastSeen ?? UserDefaults.standard.string(forKey: lastSeenVersionKey) ?? "0"
        return Array(
            whatsNewEntries
                .filter { compareVersions($0.version, isNewerThan: previous) }
                .prefix(maxWhatsNewEntries)
        )
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
