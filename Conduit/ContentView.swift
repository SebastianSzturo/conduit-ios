import SwiftUI

/// Root navigation: Home (All Repos) → Session detail.
struct ContentView: View {
    @State private var settings: AppSettings
    @State private var homeStore: HomeStore
    @State private var path: [SessionRoute] = []

    private let api: ConductorAPI

    init() {
        let settings = AppSettings()
        let client = ConductorClient(baseURL: settings.baseURL) { [settings] in settings.apiKey }
        self.api = client
        self._settings = State(initialValue: settings)
        self._homeStore = State(initialValue: HomeStore(api: client))
    }

    var body: some View {
        NavigationStack(path: $path) {
            HomeView(
                store: homeStore,
                settings: settings,
                onOpenWorkspace: { item in
                    openWorkspace(item)
                },
                onSubmitNewSession: { request in
                    createWorkspace(for: request)
                }
            )
            .navigationDestination(for: SessionRoute.self) { route in
                SessionView(
                    store: route.store,
                    settings: settings,
                    onNewSession: { newStore in
                        path.append(SessionRoute(store: newStore))
                    }
                )
                // Popping back to home clears the unread dot for the
                // session the user just viewed.
                .onDisappear { homeStore.markSeen(workspaceID: route.store.workspaceID) }
            }
        }
        .tint(Theme.textPrimary)
    }

    private func openWorkspace(_ item: HomeStore.WorkspaceItem) {
        guard let session = item.session else { return }
        homeStore.markSeen(item)
        let store = SessionStore(api: api, workspaceID: item.workspace.id, session: session)
        path.append(SessionRoute(store: store))
    }

    private func createWorkspace(for request: NewSessionRequest) {
        Task {
            let prompt = promptText(for: request)
            let created = try await api.createWorkspace(
                projectID: request.project.id,
                name: nil,
                branch: request.branch,
                agent: request.model.agent,
                model: request.model.modelID
            )
            let store = SessionStore(
                api: api,
                created: created,
                project: request.project,
                initialPrompt: prompt,
                model: request.model
            )
            path.append(SessionRoute(store: store))
            await homeStore.refresh()
        }
    }

    private func promptText(for request: NewSessionRequest) -> String {
        switch request.mode {
        case .plan: "Plan only — do not write code yet.\n\n\(request.prompt)"
        case .draft: "Draft: \(request.prompt)"
        case .agent: request.prompt
        }
    }
}

/// Navigation payload holding a live per-session store.
struct SessionRoute: Hashable {
    let id = UUID()
    let store: SessionStore

    static func == (lhs: SessionRoute, rhs: SessionRoute) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

#Preview {
    ContentView()
}
