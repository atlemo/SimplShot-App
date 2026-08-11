import SwiftUI
import PDFKit

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
    var onMove: ((Int, Int) -> Void)? = nil
    /// Parsed document outline (empty → the Outline tab is hidden).
    var outline: [PDFOutlineNode] = []
    /// Page index of the active page, used to highlight the current section.
    var activePageIndex: Int? = nil
    var onSelectOutline: ((PDFOutlineNode) -> Void)? = nil

    @State private var draggedID: UUID?
    @State private var tab: NavTab = .thumbnails

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
                        ThumbnailItem(
                            session: session,
                            displayLabel: pageLabel(for: session, index: index),
                            isSelected: session.id == activeID,
                            isDragTarget: false,
                            onSelect: { onSelect(session.id) },
                            onRemove: { onRemove(session.id) }
                        )
                        .id(session.id)
                        .opacity(draggedID == session.id ? 0.4 : 1)
                        .onDrag {
                            draggedID = session.id
                            return NSItemProvider(object: session.id.uuidString as NSString)
                        }
                        .onDrop(of: [.text], delegate: ThumbnailDropDelegate(
                            targetID: session.id,
                            sessions: sessions,
                            draggedID: $draggedID,
                            onMove: onMove
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

    /// The page badge label: the PDF page's own label (e.g. roman numerals) when
    /// present, else the 1-based index; nil for non-PDF images.
    private func pageLabel(for session: ImageSession, index: Int) -> String? {
        guard session.isPDF else { return nil }
        if let src = session.pdfPageSource,
           let label = src.document.page(at: src.pageIndex)?.label,
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

private struct ThumbnailDropDelegate: DropDelegate {
    let targetID: UUID
    let sessions: [ImageSession]
    @Binding var draggedID: UUID?
    var onMove: ((Int, Int) -> Void)?

    func dropEntered(info: DropInfo) {
        guard let draggedID,
              draggedID != targetID,
              let from = sessions.firstIndex(where: { $0.id == draggedID }),
              let to = sessions.firstIndex(where: { $0.id == targetID })
        else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            onMove?(from, to)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedID = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

// MARK: - Thumbnail Item

/// One row in the strip. Owns its own `@ObservedObject` so async thumbnail
/// generation triggers a re-render without invalidating the whole strip.
private struct ThumbnailItem: View {
    @ObservedObject var session: ImageSession
    let displayLabel: String?
    let isSelected: Bool
    let isDragTarget: Bool
    var onSelect: () -> Void
    var onRemove: () -> Void

    @State private var isHovered = false

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
            .opacity(isHovered || isSelected ? 1 : 0)
            .animation(.easeInOut(duration: 0.15), value: isHovered)
            .accessibilityLabel("Remove \(session.imageURL.lastPathComponent)")
        }
        .onHover { isHovered = $0 }
    }
}
