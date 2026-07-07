import SwiftUI

/// Full-height sheet for choosing a repo (project). Sections: Active (current
/// selection), Recents (store.recentProjectIDs), More (the rest).
struct RepoPickerSheet: View {
    let store: HomeStore
    @Bindable var composer: ComposerState
    @Environment(\.dismiss) private var dismiss

    @State private var query: String = ""
    @State private var editingBranch = false
    @State private var branchDraft = ""

    private var allProjects: [Project] { store.projects }

    private var filtered: [Project] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return allProjects }
        return allProjects.filter {
            $0.repoSlug.lowercased().contains(q) || $0.name.lowercased().contains(q)
        }
    }

    private var activeProject: Project? {
        guard let sel = composer.selectedProject else { return nil }
        return filtered.first { $0.id == sel.id }
    }

    private var pinnedProjects: [Project] {
        let activeID = composer.selectedProject?.id
        return store.pinnedProjects.compactMap { p in
            filtered.first { $0.id == p.id && $0.id != activeID }
        }
    }

    private var recentProjects: [Project] {
        let activeID = composer.selectedProject?.id
        let pinnedIDs = Set(store.pinnedProjectIDs)
        return store.recentProjectIDs.compactMap { id in
            filtered.first { $0.id == id && $0.id != activeID && !pinnedIDs.contains(id) }
        }
    }

    private var moreProjects: [Project] {
        let excluded = Set(
            [composer.selectedProject?.id].compactMap { $0 }
                + store.recentProjectIDs
                + store.pinnedProjectIDs
        )
        return filtered.filter { !excluded.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    searchField

                    if let active = activeProject {
                        section("Active") {
                            RepoRow(
                                project: active,
                                isActive: true,
                                isPinned: store.isPinned(active),
                                branch: composer.branch,
                                onEditBranch: {
                                    branchDraft = composer.branch
                                    editingBranch = true
                                },
                                onTogglePin: { store.togglePinned(active) },
                                onTap: { select(active) }
                            )
                        }
                    }

                    if !pinnedProjects.isEmpty {
                        section("Pinned") {
                            ForEach(pinnedProjects) { p in repoRow(p) }
                        }
                    }

                    if !recentProjects.isEmpty {
                        section("Recents") {
                            ForEach(recentProjects) { p in repoRow(p) }
                        }
                    }

                    if !moreProjects.isEmpty {
                        section("More") {
                            ForEach(moreProjects) { p in repoRow(p) }
                        }
                    }

                    if filtered.isEmpty {
                        Text("No repos found")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.top, 48)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
            .background(Theme.background)
            .navigationTitle("Repo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    CircleIconButton(systemName: "xmark") { dismiss() }
                }
            }
            .toolbarBackground(Theme.background, for: .navigationBar)
        }
        .alert("Branch", isPresented: $editingBranch) {
            TextField("Branch", text: $branchDraft)
                .textInputAutocapitalization(.never)
            Button("Cancel", role: .cancel) {}
            Button("Set") {
                let trimmed = branchDraft.trimmingCharacters(in: .whitespaces)
                composer.branch = trimmed.isEmpty ? "main" : trimmed
            }
        } message: {
            Text("Set the branch for this repo.")
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.textSecondary)
            TextField("Repo…", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(Theme.textPrimary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Theme.inputField, in: Capsule())
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 20)
                .padding(.bottom, 6)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func repoRow(_ project: Project) -> some View {
        RepoRow(
            project: project,
            isActive: false,
            isPinned: store.isPinned(project),
            branch: nil,
            onEditBranch: nil,
            onTogglePin: { store.togglePinned(project) },
            onTap: { select(project) }
        )
    }

    private func select(_ project: Project) {
        composer.selectProject(project)
        dismiss()
    }
}

private struct RepoRow: View {
    let project: Project
    let isActive: Bool
    var isPinned: Bool = false
    let branch: String?
    var onEditBranch: (() -> Void)?
    var onTogglePin: (() -> Void)?
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: "folder")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 22)

                HStack(spacing: 0) {
                    if let owner = project.owner {
                        Text(owner + "/")
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Text(repoName)
                        .foregroundStyle(Theme.textPrimary)
                }
                .font(.system(size: 16))
                .lineLimit(1)
                .truncationMode(.middle)

                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                }

                Spacer(minLength: 8)

                if isActive, let branch {
                    Button {
                        onEditBranch?()
                    } label: {
                        HStack(spacing: 4) {
                            Text(branch)
                                .foregroundStyle(Theme.textSecondary)
                                .font(.system(size: 14))
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.separator).frame(height: 1)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let onTogglePin {
                Button {
                    onTogglePin()
                } label: {
                    Label(isPinned ? "Unpin" : "Pin", systemImage: isPinned ? "pin.slash" : "pin")
                }
            }
        }
    }

    private var repoName: String {
        let slug = project.repoSlug
        if let slash = slug.lastIndex(of: "/") {
            return String(slug[slug.index(after: slash)...])
        }
        return slug
    }
}

#Preview {
    let store = HomeStore(api: MockConductorAPI())
    let settings = AppSettings()
    RepoPickerSheet(store: store, composer: ComposerState(store: store, settings: settings))
}
