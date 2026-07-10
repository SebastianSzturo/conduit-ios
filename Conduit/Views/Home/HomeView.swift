import SwiftUI

/// Row filter applied via the filter menu button.
private enum HomeFilter: String, CaseIterable {
    case all = "All"
    case working = "Working"
    case idle = "Idle"
    case archived = "Archived"
}

/// The "All Repos" home screen: recents + per-project sections, search sheet
/// & filter, pull-to-refresh, and the floating composer.
struct HomeView: View {
    let store: HomeStore
    let settings: AppSettings
    var onOpenWorkspace: (HomeStore.WorkspaceItem) -> Void
    var onSubmitNewSession: (
        NewSessionRequest,
        @escaping (Result<Void, Error>) -> Void
    ) -> Void

    @State private var composer: ComposerState
    @State private var showSearch = false
    @State private var filter: HomeFilter = .all
    @State private var isComposerExpanded = false
    @State private var showSettings = false

    // Rename / archive
    @State private var renameTarget: HomeStore.WorkspaceItem?
    @State private var renameText = ""
    @State private var archiveTarget: HomeStore.WorkspaceItem?

    /// Workspace currently having its session lazily fetched before opening.
    @State private var openingWorkspaceID: String?

    init(
        store: HomeStore,
        settings: AppSettings,
        onOpenWorkspace: @escaping (HomeStore.WorkspaceItem) -> Void,
        onSubmitNewSession: @escaping (
            NewSessionRequest,
            @escaping (Result<Void, Error>) -> Void
        ) -> Void
    ) {
        self.store = store
        self.settings = settings
        self.onOpenWorkspace = onOpenWorkspace
        self.onSubmitNewSession = onSubmitNewSession
        _composer = State(initialValue: ComposerState(store: store, settings: settings))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.background.ignoresSafeArea()

            content

            if !isComposerExpanded && settings.hasAPIKey {
                ComposerPill { expandComposer() }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .navigationBarTitleDisplayMode(.large)
        .navigationTitle("All Repos")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showSearch = true
                } label: {
                    Image(systemName: "magnifyingglass")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Filter", selection: $filter) {
                        ForEach(HomeFilter.allCases, id: \.self) { f in
                            Text(f.rawValue).tag(f)
                        }
                    }
                    Divider()
                    Button {
                        showSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                }
            }
        }
        .task {
            await settings.refreshModelCapabilities(using: store.api)
            await store.refresh()
            store.startPolling()
        }
        .onDisappear { store.stopPolling() }
        .sheet(isPresented: $showSettings) {
            SettingsSheet(settings: settings, api: store.api) {
                await settings.refreshModelCapabilities(using: store.api)
                await store.refresh()
            }
        }
        .sheet(isPresented: $showSearch) {
            SearchSheet(store: store) { item in
                showSearch = false
                onOpenWorkspace(item)
            }
        }
        .overlay {
            if isComposerExpanded {
                composerOverlay
            }
        }
        .alert("Rename Session", isPresented: renameBinding) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Save") {
                if let target = renameTarget {
                    let name = renameText.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty {
                        Task { await store.renameSession(target, to: name) }
                    }
                }
                renameTarget = nil
            }
        }
        .alert("Archive Workspace", isPresented: archiveBinding) {
            Button("Cancel", role: .cancel) { archiveTarget = nil }
            Button("Archive", role: .destructive) {
                if let target = archiveTarget {
                    Task { await store.archiveWorkspace(target) }
                }
                archiveTarget = nil
            }
        } message: {
            Text("This workspace will be archived.")
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if !settings.hasAPIKey {
            missingKeyState
        } else if store.projects.isEmpty && store.items.isEmpty {
            if store.isLoading {
                ProgressView()
                    .controlSize(.large)
                    .tint(Theme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                refreshableEmptyState
            }
        } else {
            list
        }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let error = store.lastError {
                    staleBanner(error)
                        .padding(.top, 8)
                }
                if filter == .archived {
                    let archived = store.archivedItems
                    if !archived.isEmpty {
                        sectionHeader("Archived")
                        ForEach(archived) { item in
                            row(item, showsRepo: true)
                        }
                    } else {
                        Text("No archived workspaces")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                    }
                } else {
                    let recents = filteredRecents
                    if !recents.isEmpty {
                        sectionHeader("Recents")
                        ForEach(recents) { item in
                            row(item, showsRepo: true)
                        }
                    }

                    ForEach(orderedProjects) { project in
                        let items = filtered(store.items(for: project))
                        if !items.isEmpty {
                            projectSectionHeader(project)
                            ForEach(items) { item in
                                row(item, showsRepo: false)
                            }
                        }
                    }
                }

                if filter != .archived && isEverythingFilteredOut {
                    Text("No matching sessions")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 100)
        }
        .scrollDismissesKeyboard(.interactively)
        .refreshable { await store.refresh() }
    }

    private func staleBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
                .foregroundStyle(Theme.error)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Retry") { Task { await store.refresh() } }
                .font(.system(size: 13, weight: .semibold))
                .buttonStyle(.plain)
        }
        .padding(12)
        .background(Theme.error.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.cornerMedium))
    }

    @ViewBuilder
    private func row(_ item: HomeStore.WorkspaceItem, showsRepo: Bool) -> some View {
        let base = WorkspaceRow(
            item: item,
            showsRepoInSubtitle: showsRepo,
            onTap: { open(item) },
            onRename: {
                renameText = item.title
                renameTarget = item
            },
            onArchive: { archiveTarget = item }
        )
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.separator).frame(height: 1)
        }
        .overlay(alignment: .trailing) {
            if openingWorkspaceID == item.id {
                ProgressView()
                    .controlSize(.small)
                    .tint(Theme.textSecondary)
                    .padding(.trailing, 4)
            }
        }

        if item.workspaceStatus == .archived {
            base
        } else {
            SwipeToArchiveRow(onArchive: { archiveTarget = item }) {
                base
            }
        }
    }

    /// Opens a row. Archived items have no session loaded; fetch it lazily
    /// (brief spinner) before navigating. Rows with no sessions do nothing.
    private func open(_ item: HomeStore.WorkspaceItem) {
        if item.session != nil {
            onOpenWorkspace(item)
            return
        }
        guard openingWorkspaceID == nil else { return }
        openingWorkspaceID = item.id
        Task {
            defer { openingWorkspaceID = nil }
            guard let session = await store.primarySession(for: item) else { return }
            var filled = item
            filled.session = session
            onOpenWorkspace(filled)
        }
    }

    /// Projects ordered with pinned ones first, then the rest in their loaded order.
    private var orderedProjects: [Project] {
        let pinned = store.pinnedProjects
        let pinnedIDs = Set(pinned.map(\.id))
        return pinned + store.projects.filter { !pinnedIDs.contains($0.id) }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.footnote)
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.top, 22)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Section header for a project row group. Shows a pin glyph when pinned and
    /// a context menu to toggle the pin.
    private func projectSectionHeader(_ project: Project) -> some View {
        let pinned = store.isPinned(project)
        return HStack(spacing: 5) {
            if pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
            }
            Text(project.repoSlug)
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.top, 22)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                store.togglePinned(project)
            } label: {
                Label(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin")
            }
        }
    }

    // MARK: Filtering

    private func filtered(_ items: [HomeStore.WorkspaceItem]) -> [HomeStore.WorkspaceItem] {
        items.filter { matchesFilter($0) }
    }

    private var filteredRecents: [HomeStore.WorkspaceItem] {
        filtered(store.recents)
    }

    private func matchesFilter(_ item: HomeStore.WorkspaceItem) -> Bool {
        switch filter {
        case .all: return true
        case .working: return item.isWorking
        case .idle: return !item.isWorking
        case .archived: return false // Archived mode renders its own section.
        }
    }

    private var isEverythingFilteredOut: Bool {
        guard !store.items.isEmpty else { return false }
        if !filteredRecents.isEmpty { return false }
        for project in store.projects where !filtered(store.items(for: project)).isEmpty {
            return false
        }
        return true
    }

    // MARK: Empty / missing-key states

    private var refreshableEmptyState: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 12) {
                    if let error = store.lastError { staleBanner(error) }
                    emptyState
                }
                .padding(.horizontal, 16)
                .frame(minHeight: geometry.size.height)
            }
            .refreshable { await store.refresh() }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 44))
                .foregroundStyle(Theme.textTertiary)
            Text("No repos yet")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("Start a session with the composer below.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var missingKeyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "key.horizontal")
                .font(.system(size: 44))
                .foregroundStyle(Theme.textTertiary)
            Text("No API key")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("Add your Conductor API key to load your repos.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                showSettings = true
            } label: {
                Text("Open Settings")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.background)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .background(Theme.textPrimary, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Composer overlay

    private var composerOverlay: some View {
        ZStack(alignment: .bottom) {
            Color.primary.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { collapseComposer() }

            ExpandedComposer(
                store: store,
                composer: composer,
                onSubmit: onSubmitNewSession,
                onDismiss: collapseComposer
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func expandComposer() {
        composer.syncDefaultProjectIfNeeded()
        withAnimation(.easeOut(duration: 0.25)) { isComposerExpanded = true }
    }

    private func collapseComposer() {
        withAnimation(.easeInOut(duration: 0.2)) { isComposerExpanded = false }
    }

    // MARK: Alert bindings

    private var renameBinding: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }

    private var archiveBinding: Binding<Bool> {
        Binding(get: { archiveTarget != nil }, set: { if !$0 { archiveTarget = nil } })
    }
}

private func homeViewPreview() -> some View {
    NavigationStack {
        HomeView(
            store: HomeStore(api: MockConductorAPI()),
            settings: AppSettings(),
            onOpenWorkspace: { _ in },
            onSubmitNewSession: { _, completion in completion(.success(())) }
        )
    }
}

#Preview("Dark") {
    homeViewPreview()
        .preferredColorScheme(.dark)
}

#Preview("Light") {
    homeViewPreview()
        .preferredColorScheme(.light)
}
