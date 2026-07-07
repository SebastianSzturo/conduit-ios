import SwiftUI

/// Drag-to-reveal trailing "Archive" action for rows living in a `ScrollView`
/// (SwiftUI's `.swipeActions` is `List`-only). Swipe left to reveal the button;
/// a long full swipe triggers the action directly. Horizontal drags only —
/// vertical movement is left to the scroll view.
struct SwipeToArchiveRow<Content: View>: View {
    let onArchive: () -> Void
    @ViewBuilder let content: Content

    /// Current visual offset of the row content.
    @State private var offset: CGFloat = 0
    /// Offset the row rests at when the action is revealed.
    private let revealWidth: CGFloat = 88
    /// Dragging past this commits the archive directly (full swipe).
    private let fullSwipeThreshold: CGFloat = 220

    var body: some View {
        content
            .offset(x: offset)
            .background(alignment: .trailing) {
                if offset < 0 {
                    archiveAction
                }
            }
            .contentShape(Rectangle())
            // High priority so a horizontal drag preempts the row's tap Button
            // (which otherwise fires on touch-up even after a sideways drag).
            // Vertical scrolls still win: the ScrollView's pan claims the touch
            // well before this gesture's 30pt minimum distance.
            .highPriorityGesture(dragGesture)
            .animation(.spring(duration: 0.25), value: offset == 0)
    }

    private var archiveAction: some View {
        Button {
            close()
            onArchive()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "archivebox.fill")
                    .font(.system(size: 16, weight: .semibold))
                Text("Archive")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.white)
            .frame(width: revealWidth)
            .frame(maxHeight: .infinity)
            .background(Theme.deletions)
        }
        .buttonStyle(.plain)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 30)
            .onChanged { value in
                // Only track drags that are clearly horizontal; let the scroll
                // view own everything else.
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                let base: CGFloat = offset == -revealWidth ? -revealWidth : 0
                offset = min(0, base + value.translation.width)
            }
            .onEnded { value in
                if offset <= -fullSwipeThreshold {
                    close()
                    onArchive()
                } else if offset <= -revealWidth * 0.6 {
                    withAnimation(.spring(duration: 0.25)) { offset = -revealWidth }
                } else {
                    close()
                }
            }
    }

    private func close() {
        withAnimation(.spring(duration: 0.25)) { offset = 0 }
    }
}
