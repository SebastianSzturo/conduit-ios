import SwiftUI

/// A single workspace/session row in the home list.
/// Layout: status indicator · title (white) / subtitle "status · model-or-repo"
/// with trailing relative time.
struct WorkspaceRow: View {
    let item: HomeStore.WorkspaceItem
    /// When true (repo sections) the repo name is redundant, so show model instead.
    var showsRepoInSubtitle: Bool = true
    var onTap: () -> Void
    var onRename: () -> Void
    var onArchive: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 12) {
                WorkspaceStatusIndicator(item: item)
                    .frame(width: 18, height: 18)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)

                    subtitle
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 8)

                Text(relativeTimeLabel(item.lastUpdatedAt))
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 1)
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                onRename()
            } label: {
                Label("Rename session", systemImage: "pencil")
            }
            Button(role: .destructive) {
                onArchive()
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
        }
    }

    private var subtitle: some View {
        HStack(spacing: 5) {
            Text(item.statusLabel)
                .foregroundStyle(item.isWorking ? Theme.textPrimary : Theme.textSecondary)
            if let trailing = trailingDetail {
                Text("·")
                    .foregroundStyle(Theme.textTertiary)
                Text(trailing)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .font(.system(size: 14))
    }

    private var trailingDetail: String? {
        if showsRepoInSubtitle {
            return item.project.repoSlug
        }
        if let model = item.session?.model {
            return ModelOption.displayName(for: model)
        }
        return nil
    }
}

/// Leading status glyph shared by workspace rows: animated asterisk while
/// working, accent dot when unread, dim dot otherwise.
struct WorkspaceStatusIndicator: View {
    let item: HomeStore.WorkspaceItem

    var body: some View {
        if item.isWorking {
            WorkingIndicator()
        } else if item.isUnread {
            Circle()
                .fill(Theme.accent)
                .frame(width: 8, height: 8)
                .padding(5)
        } else {
            Circle()
                .fill(Theme.textTertiary)
                .frame(width: 8, height: 8)
                .padding(5)
        }
    }
}

#Preview {
    let project = MockConductorAPI.sampleProjects[0]
    let working = HomeStore.WorkspaceItem(
        workspace: MockConductorAPI.sampleWorkspaces[0],
        project: project,
        session: MockConductorAPI.sampleSessions[0],
        sessionStatus: .working,
        workspaceStatus: .ready
    )
    let idle = HomeStore.WorkspaceItem(
        workspace: MockConductorAPI.sampleWorkspaces[1],
        project: project,
        session: MockConductorAPI.sampleSessions[1],
        sessionStatus: .idle,
        workspaceStatus: .ready
    )
    return ZStack {
        Theme.background.ignoresSafeArea()
        VStack(spacing: 0) {
            WorkspaceRow(item: working, onTap: {}, onRename: {}, onArchive: {})
            WorkspaceRow(item: idle, showsRepoInSubtitle: false, onTap: {}, onRename: {}, onArchive: {})
        }
        .padding(.horizontal, 16)
    }
    .preferredColorScheme(.dark)
}
