import SwiftUI
import PDFKit
import UniformTypeIdentifiers

// MARK: - Outline Model

/// A lightweight, value-type snapshot of a `PDFOutline` node, parsed once when a
/// document loads so SwiftUI `ForEach` has stable identities (re-reading PDFKit
/// each render would churn ids and reset disclosure state).
struct PDFOutlineNode: Identifiable {
    let id = UUID()
    let title: String
    let page: PDFPage?
    let point: CGPoint?
    let children: [PDFOutlineNode]

    /// Builds the top-level nodes from a document's outline root (nil → empty).
    static func tree(from root: PDFOutline?) -> [PDFOutlineNode] {
        guard let root else { return [] }
        return (0..<root.numberOfChildren).compactMap { i in
            root.child(at: i).map(node(from:))
        }
    }

    private static func node(from outline: PDFOutline) -> PDFOutlineNode {
        let dest = outline.destination ?? (outline.action as? PDFActionGoTo)?.destination
        let pt = dest?.point
        let unspecified = pt.map {
            $0.x == kPDFDestinationUnspecifiedValue || $0.y == kPDFDestinationUnspecifiedValue
        } ?? true
        let children = (0..<outline.numberOfChildren)
            .compactMap { outline.child(at: $0) }
            .map(node(from:))
        return PDFOutlineNode(
            title: outline.label ?? "",
            page: dest?.page,
            point: unspecified ? nil : pt,
            children: children
        )
    }
}

// MARK: - Navigator (Thumbnails + Outline)

/// Floating vertical navigator shown on the right edge of the editor canvas when
/// multiple images/pages are loaded. For PDFs with an embedded outline it adds a
/// second tab so you can jump to named sections, not just page thumbnails.
struct ThumbnailStripView: View {
    let sessions: [ImageSession]
    let activeID: UUID?
    var onSelect: (UUID) -> Void
    var onRemove: (UUID) -> Void
    /// False when only one item is left — the last page can't be deleted.
    var canRemove: Bool = true
    var onMove: ((Int, Int) -> Void)? = nil
    /// Insert the pages of these files at the given strip index (nil disables
    /// file drops and the add button — only PDFs can take new pages).
    var onInsert: (([URL], Int) -> Void)? = nil
    var onAddPages: (() -> Void)? = nil
    /// Parsed document outline (empty → the Outline tab is hidden).
    var outline: [PDFOutlineNode] = []
    /// Page index of the active page, used to highlight the current section.
    var activePageIndex: Int? = nil
    var onSelectOutline: ((PDFOutlineNode) -> Void)? = nil

    @State private var draggedID: UUID?
    @State private var tab: NavTab = .thumbnails
    /// Strip index a dragged-in file would be inserted at (`sessions.count` =
    /// append). Drives the insertion caret.
    @State private var fileDropIndex: Int?

    private enum NavTab { case thumbnails, outline }
    private var hasOutline: Bool { !outline.isEmpty }

    /// The strip's fixed width — wider when the outline tab is available. Exposed
    /// so callers (e.g. the continuous PDF view) can reserve matching space.
    static func width(hasOutline: Bool) -> CGFloat { hasOutline ? 190 : 90 }

    var body: some View {
        VStack(spacing: 6) {
            if hasOutline {
                Picker("", selection: $tab) {
                    Image(systemName: "square.grid.2x2").tag(NavTab.thumbnails)
                    Image(systemName: "list.bullet.indent").tag(NavTab.outline)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 6)
                .padding(.top, 6)
            }

            if hasOutline && tab == .outline {
                outlineList
            } else {
                thumbnailList
            }
        }
        .frame(width: Self.width(hasOutline: hasOutline))
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Thumbnails

    private var thumbnailList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 8) {
                    ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                        VStack(spacing: 8) {
                            insertionCaret(at: index)
                            ThumbnailItem(
                                session: session,
                                displayLabel: pageLabel(for: session, index: index),
                                isSelected: session.id == activeID,
                                canRemove: canRemove,
                                isDragTarget: false,
                                onSelect: { onSelect(session.id) },
                                onRemove: { onRemove(session.id) }
                            )
                        }
                        .id(session.id)
                        .opacity(draggedID == session.id ? 0.4 : 1)
                        .onDrag {
                            draggedID = session.id
                            return NSItemProvider(object: session.id.uuidString as NSString)
                        }
                        // One delegate for both drag kinds. A reorder drag
                        // carries `.text` (the session id) and a dragged-in file
                        // carries `.fileURL`; stacking two `onDrop` modifiers
                        // instead would put the reorder drop behind a second
                        // destination for the same view.
                        .onDrop(of: [.text, .fileURL], delegate: ThumbnailDropDelegate(
                            targetID: session.id,
                            insertIndex: index,
                            sessions: sessions,
                            draggedID: $draggedID,
                            fileDropIndex: $fileDropIndex,
                            onMove: onMove,
                            onInsert: onInsert
                        ))
                    }

                    if onInsert != nil || onAddPages != nil {
                        VStack(spacing: 8) {
                            insertionCaret(at: sessions.count)
                            addPagesButton
                        }
                        .onDrop(of: [.fileURL], delegate: ThumbnailDropDelegate(
                            targetID: nil,
                            insertIndex: sessions.count,
                            sessions: sessions,
                            draggedID: $draggedID,
                            fileDropIndex: $fileDropIndex,
                            onMove: nil,
                            onInsert: onInsert
                        ))
                    }
                }
                .padding(6)
            }
            .onChange(of: activeID) { _, newID in
                guard let newID else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(newID, anchor: .center)
                }
            }
        }
    }

    /// Dashed "Add Pages" tile closing the thumbnail list. Doubles as the drop
    /// target for appending files after the last page.
    private var addPagesButton: some View {
        Button { onAddPages?() } label: {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(.secondary.opacity(0.6))
                .frame(width: 74, height: 40)
                .overlay(
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                )
                // `strokeBorder` paints only the outline, so without an explicit
                // content shape the tile's interior isn't hit-testable and the
                // button only responds on the 1pt dashed border itself.
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(onAddPages == nil)
        .help("Add pages from a PDF or image")
        .accessibilityLabel("Add Pages")
    }

    /// Horizontal caret marking where dragged-in files will land.
    @ViewBuilder
    private func insertionCaret(at index: Int) -> some View {
        if fileDropIndex == index {
            Capsule()
                .fill(Color.accentColor)
                .frame(width: 74, height: 3)
                .transition(.opacity)
        }
    }

    /// The page badge label: the PDF page's own label (e.g. roman numerals) when
    /// present, else the 1-based index; nil for non-PDF images.
    private func pageLabel(for session: ImageSession, index: Int) -> String? {
        guard session.isPDF else { return nil }
        if let src = session.pdfPageSource,
           let label = src.page.label,
           !label.isEmpty {
            return label
        }
        return "\(index + 1)"
    }

    // MARK: Outline

    private var outlineList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(outline) { node in
                    OutlineRow(
                        node: node,
                        depth: 0,
                        activePageIndex: activePageIndex,
                        onSelect: { onSelectOutline?($0) }
                    )
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 8)
        }
    }
}

// MARK: - Outline Row

private struct OutlineRow: View {
    let node: PDFOutlineNode
    let depth: Int
    let activePageIndex: Int?
    var onSelect: (PDFOutlineNode) -> Void

    @State private var expanded = true

    private var isActive: Bool {
        guard let activePageIndex, let page = node.page else { return false }
        return page.document?.index(for: page) == activePageIndex
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                if node.children.isEmpty {
                    Spacer().frame(width: 12)
                } else {
                    Button { expanded.toggle() } label: {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 12)
                    }
                    .buttonStyle(.plain)
                }

                Button { onSelect(node) } label: {
                    Text(node.title.isEmpty ? "Untitled" : node.title)
                        .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                        .foregroundStyle(isActive ? Color.accentColor : .primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(node.page == nil)
            }
            .padding(.leading, CGFloat(depth) * 10)
            .padding(.vertical, 3)

            if expanded {
                ForEach(node.children) { child in
                    OutlineRow(
                        node: child,
                        depth: depth + 1,
                        activePageIndex: activePageIndex,
                        onSelect: onSelect
                    )
                }
            }
        }
    }
}

// MARK: - Drop Delegate

/// Handles both drags the strip accepts: reordering an existing thumbnail
/// (`.text`, carrying the session id) and adding pages from files dragged in
/// from outside (`.fileURL`). One delegate rather than two `onDrop` modifiers —
/// a view can only have one drop destination, and the second would shadow the
/// first even for types it doesn't accept.
private struct ThumbnailDropDelegate: DropDelegate {
    /// The thumbnail this delegate is attached to; nil for the trailing
    /// add/append zone, which only takes files.
    let targetID: UUID?
    /// Strip position a dropped file is inserted at (before this thumbnail, or
    /// `sessions.count` for the append zone).
    let insertIndex: Int
    let sessions: [ImageSession]
    @Binding var draggedID: UUID?
    @Binding var fileDropIndex: Int?
    var onMove: ((Int, Int) -> Void)?
    var onInsert: (([URL], Int) -> Void)?

    /// File types that can become PDF pages: another PDF, or any image the
    /// editor already opens (each becomes a single page).
    private static let insertableExtensions: Set<String> = [
        "pdf", "png", "jpg", "jpeg", "heic", "heif", "tiff", "tif",
        "gif", "bmp", "webp", "avif", "jxl", "jp2", "psd"
    ]

    private func isFileDrag(_ info: DropInfo) -> Bool {
        onInsert != nil && info.hasItemsConforming(to: [.fileURL])
    }

    // Deliberately independent of `draggedID`: gating the reorder branch on it
    // would make a mistimed drag fail validation and never reach `dropEntered`.
    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL]) ? onInsert != nil : onMove != nil
    }

    func dropEntered(info: DropInfo) {
        if isFileDrag(info) {
            withAnimation(.easeInOut(duration: 0.12)) { fileDropIndex = insertIndex }
            return
        }
        guard let draggedID, let targetID,
              draggedID != targetID,
              let from = sessions.firstIndex(where: { $0.id == draggedID }),
              let to = sessions.firstIndex(where: { $0.id == targetID })
        else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            onMove?(from, to)
        }
    }

    func dropExited(info: DropInfo) {
        guard fileDropIndex == insertIndex else { return }
        withAnimation(.easeInOut(duration: 0.12)) { fileDropIndex = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        if isFileDrag(info) {
            fileDropIndex = nil
            loadURLs(info.itemProviders(for: [.fileURL]), then: onInsert)
            return true
        }
        draggedID = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if info.hasItemsConforming(to: [.fileURL]) {
            return DropProposal(operation: onInsert != nil ? .copy : .cancel)
        }
        return DropProposal(operation: onMove != nil ? .move : .cancel)
    }

    /// Resolves item providers to file URLs. Loading a URL from a provider is
    /// async, so results are keyed by position and collected on the main queue
    /// once every provider has reported back — the inserted pages then keep the
    /// order the user dragged them in, whichever provider finishes first.
    private func loadURLs(_ providers: [NSItemProvider], then insert: (([URL], Int) -> Void)?) {
        guard let insert else { return }
        let group = DispatchGroup()
        let lock = NSLock()
        var urls = [Int: URL]()
        for (offset, provider) in providers.enumerated() {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, Self.insertableExtensions.contains(url.pathExtension.lowercased()) {
                    lock.lock()
                    urls[offset] = url
                    lock.unlock()
                }
                group.leave()
            }
        }
        let index = insertIndex
        group.notify(queue: .main) {
            let ordered = urls.sorted { $0.key < $1.key }.map(\.value)
            guard !ordered.isEmpty else { return }
            insert(ordered, index)
        }
    }
}

// MARK: - Thumbnail Item

/// One row in the strip. Owns its own `@ObservedObject` so async thumbnail
/// generation triggers a re-render without invalidating the whole strip.
private struct ThumbnailItem: View {
    @ObservedObject var session: ImageSession
    let displayLabel: String?
    let isSelected: Bool
    let canRemove: Bool
    let isDragTarget: Bool
    var onSelect: () -> Void
    var onRemove: () -> Void

    @State private var isHovered = false

    /// Tooltip and accessibility label for the × — a PDF page is deleted from
    /// the document, any other thumbnail is just closed in the editor.
    /// Typed `LocalizedStringKey` so both branches stay extractable: a ternary
    /// that mixed a literal with a `String` would type the whole expression as
    /// `String` and silently drop the literal from the catalog.
    private var removeLabel: LocalizedStringKey {
        session.isPDF ? "Delete Page" : "Remove \(session.imageURL.lastPathComponent)"
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let thumb = session.thumbnail {
                        Image(nsImage: thumb)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.2))
                    }
                }
                .frame(width: 74, height: 74)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isSelected ? Color.accentColor : Color.white.opacity(0.3),
                                lineWidth: isSelected ? 3 : 1)
                )
                .shadow(color: .black.opacity(0.1), radius: 2, y: 1)

                if let displayLabel {
                    Text(displayLabel)
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.black.opacity(0.6)))
                        .padding(3)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { onSelect() }
            .accessibilityLabel(session.isPDF
                ? String(localized: "Page \(displayLabel ?? "")")
                : session.imageURL.lastPathComponent)
            .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : [.isButton])

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.white, .black.opacity(0.6))
                    .frame(width: 22, height: 22)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .offset(x: 6, y: -6)
            .opacity(canRemove && (isHovered || isSelected) ? 1 : 0)
            .disabled(!canRemove)
            .animation(.easeInOut(duration: 0.15), value: isHovered)
            .help(removeLabel)
            .accessibilityLabel(removeLabel)
        }
        .onHover { isHovered = $0 }
    }
}
