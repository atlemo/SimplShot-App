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

// MARK: - Cross-Window Drag

/// Hand-off for a thumbnail drag that leaves its own editor window.
///
/// Every editor window lives in the same process, so the drag can carry the
/// `ImageSession` objects themselves and the pasteboard item only has to say
/// "this is a SimplShot thumbnail". Encoding the payload instead would mean
/// putting every field of a session through `Codable` — and it still could not
/// carry the live `PDFPage` that a page drag is fundamentally about.
///
/// Main-thread only: `.onDrag` and every `DropDelegate` callback run there.
enum ThumbnailDragBroker {
    struct Drag {
        /// The strip the pages were picked up from, so a drop back into the
        /// same window is a reorder rather than an insert.
        let windowID: UUID
        let sessions: [ImageSession]
        /// Removes those pages from the source window — the ⌥ half of a move.
        /// Run by the destination's drop delegate once the pages have landed.
        let remove: ([UUID]) -> Void
    }

    /// The drag in flight, if any.
    ///
    /// Overwritten by the next drag rather than cleared on cancel: SwiftUI's
    /// `.onDrag` has no "drag ended" callback, so a cancelled drag would
    /// otherwise leave this set forever. A leftover entry is inert — nothing
    /// reads it until a drag actually carrying `UTType.simplShotThumbnail` is
    /// over a strip, and only this app can produce one.
    private(set) static var active: Drag?

    static func begin(_ drag: Drag) { active = drag }
    static func finish() { active = nil }

    /// ⌥ at drop time turns a cross-window copy into a move. `DropInfo` carries
    /// no modifier state, so read the live one.
    static var isMoveRequested: Bool {
        NSEvent.modifierFlags.contains(.option)
    }
}

extension UTType {
    /// The drag type a thumbnail advertises. A private type — rather than
    /// `.text` carrying the session id — so a thumbnail dragged onto another
    /// app is refused instead of pasting a raw UUID, and so text dragged in
    /// from another app can never be mistaken for a page.
    ///
    /// Declared in `Resources/Info.plist` under `UTExportedTypeDeclarations`.
    /// `UTType(exportedAs:)` resolves against the bundle's exported types, and
    /// an undeclared identifier stops the drag from starting at all.
    static let simplShotThumbnail = UTType(exportedAs: "com.simplshot.editor-thumbnail")
}

/// The file half of a strip or canvas drop, shared by both delegates.
enum DroppedFiles {
    /// What the editor can take in: another PDF, or any image it opens.
    static let insertableExtensions: Set<String> = [
        "pdf", "png", "jpg", "jpeg", "heic", "heif", "tiff", "tif",
        "gif", "bmp", "webp", "avif", "jxl", "jp2", "psd"
    ]

    /// Resolves item providers to file URLs. Loading a URL from a provider is
    /// async, so results are keyed by position and collected on the main queue
    /// once every provider has reported back — what lands then keeps the order
    /// the user dragged it in, whichever provider finishes first.
    static func resolve(_ providers: [NSItemProvider], then handle: (([URL]) -> Void)?) {
        guard let handle else { return }
        let group = DispatchGroup()
        let lock = NSLock()
        var urls = [Int: URL]()
        for (offset, provider) in providers.enumerated() {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, insertableExtensions.contains(url.pathExtension.lowercased()) {
                    lock.lock()
                    urls[offset] = url
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let ordered = urls.sorted { $0.key < $1.key }.map(\.value)
            guard !ordered.isEmpty else { return }
            handle(ordered)
        }
    }
}

/// Drop target for the editor canvas: pages dragged in from ANOTHER editor
/// window, and files dragged in from outside.
///
/// The thumbnail strip is the precise target — it shows exactly where things
/// will land — but it is hidden in a window showing a single image, which would
/// otherwise leave that window impossible to drop into at all. What lands here
/// is appended.
struct EditorCanvasPageDropDelegate: DropDelegate {
    let windowID: UUID
    @Binding var isTargeted: Bool
    var onAcceptSessions: ([ImageSession]) -> Void
    var onAcceptFiles: ([URL]) -> Void

    private enum Kind {
        case files
        case foreign(sessions: [ImageSession])
    }

    private func kind(_ info: DropInfo) -> Kind? {
        if info.hasItemsConforming(to: [.fileURL]) { return .files }
        guard info.hasItemsConforming(to: [.simplShotThumbnail]),
              let drag = ThumbnailDragBroker.active,
              // A window's own pages are reordered in the strip, not dropped
              // back onto its canvas.
              drag.windowID != windowID else { return nil }
        return .foreign(sessions: drag.sessions)
    }

    func validateDrop(info: DropInfo) -> Bool { kind(info) != nil }

    func dropEntered(info: DropInfo) {
        guard kind(info) != nil else { return }
        withAnimation(.easeInOut(duration: 0.12)) { isTargeted = true }
    }

    func dropExited(info: DropInfo) {
        withAnimation(.easeInOut(duration: 0.12)) { isTargeted = false }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        switch kind(info) {
        case .files:
            return DropProposal(operation: .copy)
        case .foreign:
            return DropProposal(operation: ThumbnailDragBroker.isMoveRequested ? .move : .copy)
        case .none:
            return DropProposal(operation: .cancel)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        let dropped = kind(info)
        isTargeted = false
        guard let dropped else { return false }
        switch dropped {
        case .files:
            DroppedFiles.resolve(info.itemProviders(for: [.fileURL]), then: onAcceptFiles)
        case .foreign(let dragged):
            onAcceptSessions(dragged)
            if ThumbnailDragBroker.isMoveRequested {
                ThumbnailDragBroker.active?.remove(dragged.map(\.id))
            }
            ThumbnailDragBroker.finish()
        }
        return true
    }
}

// MARK: - Navigator (Thumbnails + Outline)

/// Floating vertical navigator shown on the right edge of the editor canvas when
/// multiple images/pages are loaded. For PDFs with an embedded outline it adds a
/// second tab so you can jump to named sections, not just page thumbnails.
struct ThumbnailStripView: View {
    let sessions: [ImageSession]
    let activeID: UUID?
    /// Pages picked out for a multi-page drag or delete. Owned by the editor so
    /// it survives the strip being rebuilt and can be pruned when pages are
    /// added, removed or undone. Always contains `activeID`.
    @Binding var selection: Set<UUID>
    /// Identity of this strip's editor window. Matched against the drag broker's
    /// to tell a reorder from a drop coming from another window.
    let windowID: UUID
    var onSelect: (UUID) -> Void
    /// Removes pages from this window. Takes a set: the × on a multi-selection
    /// removes all of it, and a cross-window move removes what it handed over.
    var onRemove: ([UUID]) -> Void
    /// False when only one item is left — the last page can't be deleted.
    var canRemove: Bool = true
    var onMove: ((Int, Int) -> Void)? = nil
    /// Called once when a reorder drag starts, so the caller can collapse the
    /// whole drag into a single undo entry (`onMove` fires on every hover step).
    var onMoveBegan: (() -> Void)? = nil
    /// Moves a whole selection to one strip index in a single step. The live
    /// `onMove` swaps one neighbour per hover step and can't express a set, so a
    /// multi-page reorder shows an insertion caret and commits here, on drop.
    var onMoveSelection: (([UUID], Int) -> Void)? = nil
    /// Insert the pages of these files at the given strip index (nil disables
    /// file drops and the add button — only PDFs can take new pages).
    var onInsert: (([URL], Int) -> Void)? = nil
    var onAddPages: (() -> Void)? = nil
    /// Called on the SOURCE window as a drag starts, so edits still sitting in
    /// the editor's @State are written back onto the sessions before another
    /// window reads them.
    var onPrepareDrag: (() -> Void)? = nil
    /// Takes pages dragged in from another editor window, at a strip index.
    var onAcceptSessions: (([ImageSession], Int) -> Void)? = nil
    /// Parsed document outline (empty → the Outline tab is hidden).
    var outline: [PDFOutlineNode] = []
    /// Page index of the active page, used to highlight the current section.
    var activePageIndex: Int? = nil
    var onSelectOutline: ((PDFOutlineNode) -> Void)? = nil

    @State private var draggedID: UUID?
    @State private var tab: NavTab = .thumbnails
    /// Strip index the insertion caret is showing at (`sessions.count` =
    /// append). Serves every drag that commits on drop rather than live: file
    /// drops, multi-page reorders and pages from another window.
    @State private var dropIndex: Int?

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
                                isActive: session.id == activeID,
                                isSelected: isSelected(session.id),
                                canRemove: canRemove,
                                removesMultiple: dragGroup(for: session.id).count > 1,
                                onSelect: { handleClick(on: session.id) },
                                onRemove: { onRemove(dragGroup(for: session.id)) }
                            )
                        }
                        .id(session.id)
                        .opacity(draggedID == session.id ? 0.4 : 1)
                        .onDrag {
                            beginDrag(from: session.id)
                        } preview: {
                            dragPreview(for: session)
                        }
                        // One delegate for every drag kind the strip takes. A
                        // dragged-in file carries `.fileURL` and a thumbnail
                        // carries our own private type; stacking two `onDrop`
                        // modifiers instead would put one drop behind a second
                        // destination for the same view.
                        .onDrop(of: [.simplShotThumbnail, .fileURL], delegate: dropDelegate(
                            targetID: session.id,
                            insertIndex: index
                        ))
                    }

                    if onInsert != nil || onAddPages != nil || onAcceptSessions != nil {
                        VStack(spacing: 8) {
                            insertionCaret(at: sessions.count)
                            if onAddPages != nil {
                                addPagesButton
                            } else {
                                // An image window has nothing to click here, but
                                // the strip still needs a tail target so a page
                                // can be dropped after the last thumbnail.
                                Color.clear.frame(width: 74, height: 24)
                            }
                        }
                        .contentShape(Rectangle())
                        .onDrop(of: [.simplShotThumbnail, .fileURL], delegate: dropDelegate(
                            targetID: nil,
                            insertIndex: sessions.count
                        ))
                    }
                }
                .padding(6)
            }
            .onChange(of: activeID) { _, newID in
                guard let newID else { return }
                // The page on screen is always part of the selection — a
                // selection without it would make the × ambiguous.
                if !selection.contains(newID) { selection = [newID] }
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(newID, anchor: .center)
                }
            }
            .onChange(of: sessions.map(\.id)) { _, ids in
                // Pages can vanish under the selection — deleted, moved to
                // another window, or undone.
                var pruned = selection.intersection(ids)
                if let activeID, ids.contains(activeID) { pruned.insert(activeID) }
                if pruned != selection { selection = pruned }
            }
            .onAppear {
                if selection.isEmpty, let activeID { selection = [activeID] }
            }
        }
    }

    // MARK: Selection

    /// Drawn as selected: the page on screen counts even before the first
    /// click has seeded the set.
    private func isSelected(_ id: UUID) -> Bool {
        id == activeID || selection.contains(id)
    }

    /// The pages an action starting on `id` applies to: the whole selection
    /// when the grabbed thumbnail is part of it, otherwise just that one.
    /// Returned in strip order.
    private func dragGroup(for id: UUID) -> [UUID] {
        guard selection.contains(id), selection.count > 1 else { return [id] }
        return sessions.map(\.id).filter(selection.contains)
    }

    /// Click-to-select with the usual macOS modifiers: ⌘ toggles one page in or
    /// out, ⇧ extends from the page on screen, a plain click selects just that
    /// page and shows it.
    ///
    /// Reads `NSEvent.modifierFlags` rather than using `TapGesture().modifiers(_:)`:
    /// a plain `TapGesture` fires with ⌘ held too, so the modified variants would
    /// each need their own recogniser stacked ahead of it.
    private func handleClick(on id: UUID) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            // The page on screen can't be deselected.
            guard id != activeID else { return }
            var next = selection
            if next.contains(id) {
                next.remove(id)
            } else {
                next.insert(id)
            }
            if let activeID { next.insert(activeID) }
            selection = next
        } else if flags.contains(.shift),
                  let anchor = activeID,
                  let from = sessions.firstIndex(where: { $0.id == anchor }),
                  let to = sessions.firstIndex(where: { $0.id == id }) {
            selection = Set((from <= to ? from...to : to...from).map { sessions[$0].id })
        } else {
            selection = [id]
            onSelect(id)
        }
    }

    // MARK: Dragging

    /// Starts a thumbnail drag: publishes the pages to the broker for whichever
    /// window takes the drop, and returns the item that marks the drag as ours.
    private func beginDrag(from id: UUID) -> NSItemProvider {
        let ids = dragGroup(for: id)
        // A single-page drag reorders live under the cursor (`draggedID` +
        // `onMove`); a multi-page one shows a caret and commits on drop.
        draggedID = ids.count == 1 ? id : nil
        onMoveBegan?()
        // Whoever takes the drop reads these session objects directly, so any
        // edit still sitting in this editor's @State has to land on them first.
        onPrepareDrag?()
        ThumbnailDragBroker.begin(ThumbnailDragBroker.Drag(
            windowID: windowID,
            sessions: sessions.filter { ids.contains($0.id) },
            remove: onRemove
        ))

        let provider = NSItemProvider()
        // `.ownProcess` because that is exactly the reach of the payload: the
        // sessions live in this process's memory and nothing outside it could
        // do anything with the token.
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.simplShotThumbnail.identifier,
            visibility: .ownProcess
        ) { completion in
            completion(Data(windowID.uuidString.utf8), nil)
            return nil
        }
        return provider
    }

    /// Drag image: the grabbed thumbnail, badged with a count when a whole
    /// selection is coming along. SwiftUI's `.onDrag` carries a single item, so
    /// the badge is the only cue that the drag is more than one page.
    @ViewBuilder
    private func dragPreview(for session: ImageSession) -> some View {
        let count = dragGroup(for: session.id).count
        ZStack(alignment: .topTrailing) {
            Group {
                if let thumb = session.thumbnail {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Rectangle().fill(Color.secondary.opacity(0.3))
                }
            }
            .frame(width: 74, height: 74)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            if count > 1 {
                Text("\(count)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor))
                    .offset(x: 6, y: -6)
            }
        }
    }

    private func dropDelegate(targetID: UUID?, insertIndex: Int) -> ThumbnailDropDelegate {
        ThumbnailDropDelegate(
            targetID: targetID,
            insertIndex: insertIndex,
            sessions: sessions,
            windowID: windowID,
            draggedID: $draggedID,
            dropIndex: $dropIndex,
            onMove: onMove,
            onMoveSelection: onMoveSelection,
            onInsert: onInsert,
            onAcceptSessions: onAcceptSessions
        )
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

    /// Horizontal caret marking where the dragged pages or files will land.
    @ViewBuilder
    private func insertionCaret(at index: Int) -> some View {
        if dropIndex == index {
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

/// Handles every drag the strip accepts: reordering this window's own
/// thumbnails, taking pages handed over by another editor window, and adding
/// pages from files dragged in from outside. One delegate rather than several
/// `onDrop` modifiers — a view can only have one drop destination, and a second
/// would shadow the first even for types it doesn't accept.
private struct ThumbnailDropDelegate: DropDelegate {
    /// The thumbnail this delegate is attached to; nil for the trailing
    /// add/append zone.
    let targetID: UUID?
    /// Strip position a dropped page lands at (before this thumbnail, or
    /// `sessions.count` for the append zone).
    let insertIndex: Int
    let sessions: [ImageSession]
    /// This strip's window, matched against the broker's to tell a reorder from
    /// pages arriving from another editor window.
    let windowID: UUID
    @Binding var draggedID: UUID?
    @Binding var dropIndex: Int?
    var onMove: ((Int, Int) -> Void)?
    var onMoveSelection: (([UUID], Int) -> Void)?
    var onInsert: (([URL], Int) -> Void)?
    var onAcceptSessions: (([ImageSession], Int) -> Void)?

    /// What the drag currently over this view is, or nil if the strip can't
    /// take it.
    private enum Kind {
        /// Files from outside the app, to be spliced in as pages.
        case files
        /// This window's own thumbnails being reordered.
        case reorder(ids: [UUID])
        /// Pages handed over by another editor window.
        case foreign(sessions: [ImageSession])
    }

    // Deliberately independent of `draggedID`: gating the reorder branch on it
    // would make a mistimed drag fail validation and never reach `dropEntered`.
    private func kind(_ info: DropInfo) -> Kind? {
        if info.hasItemsConforming(to: [.fileURL]) {
            return onInsert != nil ? .files : nil
        }
        guard info.hasItemsConforming(to: [.simplShotThumbnail]),
              let drag = ThumbnailDragBroker.active else { return nil }
        if drag.windowID == windowID {
            return onMove != nil || onMoveSelection != nil ? .reorder(ids: drag.sessions.map(\.id)) : nil
        }
        return onAcceptSessions != nil ? .foreign(sessions: drag.sessions) : nil
    }

    /// True for the one case that reorders live under the cursor: a single page
    /// dropped onto another thumbnail. Everything else — a multi-page
    /// selection, or the append zone, which has no neighbour to swap with —
    /// shows a caret and commits once, on drop.
    private func isLiveReorder(_ ids: [UUID]) -> Bool {
        ids.count == 1 && targetID != nil && onMove != nil
    }

    func validateDrop(info: DropInfo) -> Bool {
        kind(info) != nil
    }

    func dropEntered(info: DropInfo) {
        guard let dragged = kind(info) else { return }
        if case .reorder(let ids) = dragged, isLiveReorder(ids) {
            guard let draggedID, let targetID,
                  draggedID != targetID,
                  let from = sessions.firstIndex(where: { $0.id == draggedID }),
                  let to = sessions.firstIndex(where: { $0.id == targetID })
            else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                onMove?(from, to)
            }
            return
        }
        withAnimation(.easeInOut(duration: 0.12)) { dropIndex = insertIndex }
    }

    func dropExited(info: DropInfo) {
        guard dropIndex == insertIndex else { return }
        withAnimation(.easeInOut(duration: 0.12)) { dropIndex = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        let dropped = kind(info)
        dropIndex = nil
        draggedID = nil
        guard let dropped else { return false }
        switch dropped {
        case .files:
            DroppedFiles.resolve(info.itemProviders(for: [.fileURL])) { urls in
                onInsert?(urls, insertIndex)
            }
        case .reorder(let ids):
            if !isLiveReorder(ids) { onMoveSelection?(ids, insertIndex) }
            ThumbnailDragBroker.finish()
        case .foreign(let dragged):
            // The destination adopts the pages first, so the source still holds
            // everything they were read from while that happens.
            onAcceptSessions?(dragged, insertIndex)
            if ThumbnailDragBroker.isMoveRequested {
                ThumbnailDragBroker.active?.remove(dragged.map(\.id))
            }
            ThumbnailDragBroker.finish()
        }
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard let dragged = kind(info) else { return DropProposal(operation: .cancel) }
        switch dragged {
        case .files:
            return DropProposal(operation: .copy)
        case .reorder:
            return DropProposal(operation: .move)
        case .foreign:
            // Copy by default so an accidental drag can't quietly gut the other
            // document; ⌥ asks for the move.
            return DropProposal(operation: ThumbnailDragBroker.isMoveRequested ? .move : .copy)
        }
    }

}

// MARK: - Thumbnail Item

/// One row in the strip. Owns its own `@ObservedObject` so async thumbnail
/// generation triggers a re-render without invalidating the whole strip.
private struct ThumbnailItem: View {
    @ObservedObject var session: ImageSession
    let displayLabel: String?
    /// The page currently on the canvas — drawn with the heavier border.
    let isActive: Bool
    /// Part of the multi-page selection (always true for the active page).
    let isSelected: Bool
    let canRemove: Bool
    /// True when the × would take the whole multi-page selection, not just
    /// this one page — the tooltip has to say so before a destructive click.
    let removesMultiple: Bool
    var onSelect: () -> Void
    var onRemove: () -> Void

    @State private var isHovered = false

    /// Tooltip and accessibility label for the × — a PDF page is deleted from
    /// the document, any other thumbnail is just closed in the editor.
    /// Typed `LocalizedStringKey` so every branch stays extractable: a ternary
    /// that mixed a literal with a `String` would type the whole expression as
    /// `String` and silently drop the literal from the catalog.
    /// Deliberately says "Pages" rather than a count: a number here would need
    /// plural variations in every language (Russian distinguishes few from many
    /// even above one) to buy nothing the selection highlight doesn't show.
    private var removeLabel: LocalizedStringKey {
        if removesMultiple {
            return session.isPDF ? "Delete Pages" : "Remove Images"
        }
        return session.isPDF ? "Delete Page" : "Remove \(session.imageURL.lastPathComponent)"
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
                // Active page: full-weight accent border. Also-selected pages:
                // a lighter accent so a multi-page selection reads as one group
                // without competing with "this is the page you're looking at".
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isSelected ? Color.accentColor.opacity(isActive ? 1 : 0.55)
                                           : Color.white.opacity(0.3),
                                lineWidth: isActive ? 3 : (isSelected ? 2 : 1))
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
