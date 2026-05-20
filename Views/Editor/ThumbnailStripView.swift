import SwiftUI

/// Floating vertical thumbnail strip shown on the right edge of the editor
/// canvas when multiple images are loaded.
struct ThumbnailStripView: View {
    let sessions: [ImageSession]
    let activeID: UUID?
    var onSelect: (UUID) -> Void
    var onRemove: (UUID) -> Void
    var onMove: ((Int, Int) -> Void)? = nil

    @State private var draggedID: UUID?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 8) {
                    ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                        ThumbnailItem(
                            session: session,
                            displayIndex: session.isPDF ? index + 1 : nil,
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
        .frame(width: 90)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
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

/// One row in the strip. Owns its own `@ObservedObject` so async thumbnail
/// generation triggers a re-render without invalidating the whole strip.
private struct ThumbnailItem: View {
    @ObservedObject var session: ImageSession
    let displayIndex: Int?
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

                if let displayIndex {
                    Text("\(displayIndex)")
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
                ? "Page \(displayIndex ?? 1)"
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
