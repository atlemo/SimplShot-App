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
    WhatsNewEntry(version: "1.7.7", items: [
        "New: Build your own gradients — the + in the Gradients list now opens a gradient editor instead of a file picker. Pick linear or radial, set the angle, and add as many colour stops as you like: drag them along the ramp, or type an exact position, hex value and opacity. Your gradients sit alongside the built-in ones and can be edited or deleted from their right-click menu.",
        "New: Emoji stickers — the Sticker tool stamps emoji onto a screenshot. Click it in the Tools list to choose one, then click anywhere on the image to place it. While the tool is active the pointer becomes a faded copy of the emoji at the size it will land, so you can see exactly what you are about to place. Drag a sticker to move it, drag a corner to resize it, and press Esc to put the tool away.",
        "New: Drag pages between windows — a thumbnail can be dragged out of one editor window and dropped into another. Dropping copies the page and leaves the original where it was; hold ⌥ while you drop to move it instead. ⌘-click and ⇧-click to bring several pages at once, and drop after the last thumbnail to move a page to the very end of a document.",
        "Your own background images have moved into a Custom Backgrounds category of their own, next to Gradients and Solid Colors, with its own + for adding more. Images you had already added are there waiting for you.",
        "New: Save a PDF page as an image — Save As on a PDF now offers PNG, JPEG, HEIC and the rest alongside PDF. Choosing PDF writes the whole document; choosing an image format writes the page you are editing, at the resolution of the bitmap embedded in it rather than its page size, so a 300 DPI scan exports at 300 DPI. The format popup tells you which of the two you are about to get.",
        "Fixed: saving a PDF you had annotated dropped its table of contents, while its links and document details came through fine. A change in macOS 27 was behind it, so it affected versions already released. Annotated PDFs now keep their contents entries, the same as unannotated ones always have.",
        "Fixed: with no background on an image, the Templates menu still showed a template name, as though that template were in effect. It now reads None whenever no template is applied, and choosing None strips the template back off — background and watermark removed, padding and corners kept.",
        "Fixed: editing the text in a bubble whose width you had set by dragging its handles let the line run out through the side of the pill instead of wrapping inside it. The editor now lays text out exactly as the finished bubble does, so what you type keeps the shape it will have when you click away.",
    ]),
    WhatsNewEntry(version: "1.7.6", items: [
        "New: Organise PDF pages — the page strip can now add, delete and reorder pages. Drag a PDF or an image onto the strip to insert its pages where you drop them, use the × on a thumbnail to delete a page, and drag thumbnails to reorder. Every page change can be undone with ⌘Z, and nothing touches your file until you save.",
        "Saving a PDF now keeps its table of contents, links and document details. Previously they were discarded whenever a PDF was saved; a document you have only reorganised is no longer re-encoded at all.",
        "New: Hide the menu bar icon — Settings › General can take SimplShot's icon out of your menu bar, leaving your keyboard shortcuts to do the work. The app keeps running: open it from Spotlight and the menu appears for as long as you need it, then hides itself again. Thanks to Matt Ormianek (@MattOrmianek on GitHub) for the idea.",
        "Check for Updates now also sits in Settings › About, so you can update SimplShot without bringing its menu bar icon back.",
        "Settings › Template now previews templates more accurately: Auto keeps even padding, ratio presets show the right canvas shape, and watermarks appear closer to their exported size.",
    ]),
    WhatsNewEntry(version: "1.7.5", items: [
        "Cropping now takes over the whole sidebar — Straighten, Flip, Rotate and every aspect ratio sit in one panel instead of behind a pop-up menu, in both Annotate and Edit mode. A locked ratio survives flipping and rotating too, so your selection keeps its shape.",
        "New: Flip — mirror a screenshot left to right or top to bottom from the crop panel. Like rotating and straightening, it is non-destructive: annotations stay glued to the image, and you can flip back at any time.",
    ]),
    WhatsNewEntry(version: "1.7.4", items: [
        "New: Capture History — open it from the menu bar to see your last 10 captures and edited files as a film strip. Hover a thumbnail and click Restore to reopen an image with every annotation still editable.",
        "Alignment now keeps padding even — aligning to an edge puts the screenshot flush against it while the other sides keep their exact padding, instead of doubling the gap on the opposite side.",
        "Pixelation now exports exactly as previewed — saved and copied images use the same soft mosaic blocks you see in the editor.",
        "SimplShot uses much less memory — closed editing sessions are kept compressed in the background, so the app stays fast even after a long day of captures.",
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
