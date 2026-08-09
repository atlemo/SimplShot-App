import SwiftUI

struct WhatsNewEntry {
    let version: String
    let items: [String]
}

/// Hardcoded changelog — add new entries at the top before each release.
let whatsNewEntries: [WhatsNewEntry] = [
    WhatsNewEntry(version: "1.7.1", items: [
        "New print options — the print dialog now has Rotation and Scale controls. Rotation can turn the page 90° clockwise or counterclockwise, and “Auto (fit page)” rotates only when that fills the paper better, so a landscape screenshot prints large on a portrait page without any fiddling. Scale offers 25 % to 200 %, with 100 % meaning fit to page. The preview updates as you change either.",
        "Crop now reaches every edge — with an aspect ratio locked, dragging a handle no longer stalls just short of the right or bottom edge. Every handle now reaches its edge, whichever side you drag from.",
        "Flip any crop ratio between landscape and portrait — pick 3:2 and click the new orientation button to get 2:3, and the same for 4:3 and 16:9. The selection keeps its size as you flip, so you can switch back and forth freely. The separate 3:4 and 9:16 presets are gone; the button covers them for every ratio.",
        "Large images no longer look like they failed to open — while a big file is being decoded the editor shows a loading indicator instead of briefly flashing “Unable to load image”.",
        "Applying a saved template no longer nudges your annotations out of place — they keep their position relative to the screenshot when the padding, background, aspect ratio and alignment all change at once.",
        "Fixed missing drag handles on the Stroke, Font Size, Pixelation and Spotlight sliders — the knob now appears right away instead of only showing up once you'd clicked and dragged.",
        "The focus ring on the Annotate · Edit · View switch now follows the segment you actually clicked, instead of staying stuck on whichever one had it first.",
    ]),
    WhatsNewEntry(version: "1.7.0", items: [
        "Bendable arrows — select a Curved arrow and drag the new dot in the middle to shape the curve exactly how you want it.",
        "New Double arrow style — arrowheads at both ends, straight by default and bendable via the same middle dot.",
        "Sketch arrows got real character — they now render as a gritty, variable-width ink stroke that looks genuinely hand-drawn. Every arrow gets its own unique texture.",
        "New Angle tool — measure angles like a protractor. Drag between two points, then pull the middle handle to the corner; SimplShot shows the angle in degrees with a neat arc.",
        "More image formats — SimplShot can now open AVIF, HEIF, JPEG XL, JPEG 2000 and Photoshop (PSD) files, alongside the formats it already supported.",
        "Saving back to one of these formats just works: SimplShot keeps the original format where it can, and offers Save As when a format can only be opened, not written.",
    ]),
    WhatsNewEntry(version: "1.6.9", items: [
        "Straighten tool — while cropping, drag the new Straighten slider to level a tilted screenshot in 1° steps. The crop tightens automatically so you never get blank corners, and an alignment grid appears while you adjust to help you line things up.",
        "Redesigned Edit mode — photo adjustments are now organised into tidy, collapsible Light, Color and Detail sections (inspired by Apple Photos), so the panel is much easier to scan.",
        "New Tint control under Color, alongside Temperature, for finer colour correction.",
        "Crop, Rotate and Resize now sit together in Edit mode for a clearer, more consistent editing workflow.",
    ]),
    WhatsNewEntry(version: "1.6.8", items: [
        "Apply one look to every open image at once — switch on “Apply to all images” in the editor sidebar to share the same background, padding, corner radius, shadow and alignment across all your open screenshots. If some images are already styled differently, SimplShot asks before replacing them.",
        "PDFs now open zoomed to fit the window — the page fills the available space instead of opening small, and the Fit button scales it up to fit, not just down.",
        "Screenshots without a background again show with subtle rounded corners and a soft drop shadow, matching the look used for PDF pages.",
        "Thumbnails in the open-images strip now update live as you restyle an image, so they always match what you see.",
    ]),
    WhatsNewEntry(version: "1.6.7", items: [
        "You can now open password-protected PDFs — SimplShot asks for the password and unlocks the document",
        "Much smoother editing: adjusting padding, background, alignment or aspect ratio no longer makes annotations wobble, and the preview keeps up with fast slider drags",
        "Smoother pinch-zoom in the editor — the view stays anchored under your cursor instead of jittering",
        "Annotations in the editor now match the exported image exactly, at any zoom level",
        "Resizing a rotated image now scales annotations and text correctly",
        "Many smaller fixes from a full code review — deleting a multi-page PDF trashes the right file, text annotations undo cleanly, and more",
    ]),
    WhatsNewEntry(version: "1.6.6", items: [
        "Fixed the Crop tool on screenshots without a background — the crop selection now covers the whole image from the start instead of appearing shifted down and to the right",
    ]),
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
