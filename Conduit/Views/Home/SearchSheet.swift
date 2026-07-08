import SwiftUI

/// Full-height search sheet covering every workspace across all repos
/// (active and archived). Opens with the search field focused; rows open
/// their workspace, lazily fetching the session when one isn't loaded.
struct SearchSheet: View {
    let store: HomeStore
    var onOpen: (HomeStore.WorkspaceItem) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @FocusState private var searchFocused: Bool
    /// Workspace currently having its session lazily fetched before opening.
    @State private var openingWorkspaceID: String?

    private var allItems: [HomeStore.WorkspaceItem] {
        (store.items + store.archivedItems)
            .sorted { $0.lastUpdatedAt > $1.lastUpdatedAt }
    }

    private var results: [HomeStore.WorkspaceItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return allItems }
        return allItems.filter {
            $0.title.lowercased().contains(q)
                || $0.project.repoSlug.lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(results) { item in
                        SearchResultRow(
                            item: item,
                            isOpening: openingWorkspaceID == item.id,
                            onTap: { open(item) }
                        )
                    }

                    if results.isEmpty {
                        Text("No matching workspaces")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.background)
            .safeAreaInset(edge: .top, spacing: 0) { searchBar }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    CircleIconButton(systemName: "xmark") { dismiss() }
                }
            }
            .toolbarBackground(Theme.background, for: .navigationBar)
        }
        .onAppear { searchFocused = true }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.textSecondary)
                TextField("Search", text: $query)
                    .focused($searchFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .foregroundStyle(Theme.textPrimary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(Theme.inputField, in: Capsule())

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 40, height: 40)
                        .background(Theme.inputField, in: Circle())
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.15), value: query.isEmpty)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(Theme.background)
    }

    /// Opens a row. Archived items have no session loaded; fetch it lazily
    /// (brief spinner) before handing the item back. Rows whose session
    /// can't be fetched do nothing.
    private func open(_ item: HomeStore.WorkspaceItem) {
        if item.session != nil {
            onOpen(item)
            return
        }
        guard openingWorkspaceID == nil else { return }
        openingWorkspaceID = item.id
        Task {
            defer { openingWorkspaceID = nil }
            guard let session = await store.primarySession(for: item) else { return }
            var filled = item
            filled.session = session
            onOpen(filled)
        }
    }
}

/// Search result row: status indicator · title / "status · repo".
private struct SearchResultRow: View {
    let item: HomeStore.WorkspaceItem
    let isOpening: Bool
    let onTap: () -> Void

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

                    HStack(spacing: 5) {
                        Text(item.statusLabel)
                            .foregroundStyle(item.isWorking ? Theme.textPrimary : Theme.textSecondary)
                        Text("·")
                            .foregroundStyle(Theme.textTertiary)
                        Text(item.project.repoSlug)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .font(.system(size: 14))
                    .lineLimit(1)
                    .truncationMode(.tail)
                }

                Spacer(minLength: 8)

                if isOpening {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Theme.textSecondary)
                        .padding(.top, 2)
                }
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.separator).frame(height: 1)
        }
    }
}

#Preview {
    let store = HomeStore(api: MockConductorAPI())
    return SearchSheet(store: store, onOpen: { _ in })
        .task { await store.refresh() }
        .preferredColorScheme(.dark)
}
