import SwiftUI

/// Floating vertical thumbnail strip shown on the right edge of the editor
/// canvas when multiple images are loaded.
struct ThumbnailStripView: View {
    let sessions: [ImageSession]
    let activeID: UUID?
    var onSelect: (UUID) -> Void
    var onRemove: (UUID) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 8) {
                    ForEach(sessions) { session in
                        ThumbnailItem(
                            session: session,
                            isSelected: session.id == activeID,
                            onSelect: { onSelect(session.id) },
                            onRemove: { onRemove(session.id) }
                        )
                        .id(session.id)
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

/// One row in the strip. Owns its own `@ObservedObject` so async thumbnail
/// generation triggers a re-render without invalidating the whole strip.
private struct ThumbnailItem: View {
    @ObservedObject var session: ImageSession
    let isSelected: Bool
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

                if let pageIndex = session.pdfPageSource?.pageIndex {
                    Text("\(pageIndex + 1)")
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
                ? "Page \((session.pdfPageSource?.pageIndex ?? 0) + 1)"
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
