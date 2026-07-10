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
        let pathBinding = $path

        return NavigationStack(path: pathBinding) {
            HomeView(
                store: homeStore,
                settings: settings,
                onOpenWorkspace: { item in
                    openWorkspace(item)
                },
                onSubmitNewSession: { [api, homeStore, pathBinding] request, completion in
                    Self.submitWorkspace(
                        for: request,
                        api: api,
                        homeStore: homeStore,
                        path: pathBinding,
                        completion: completion
                    )
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
        homeStore.selectSession(session, workspaceID: item.workspace.id)
        let store = SessionStore(
            api: api,
            workspaceID: item.workspace.id,
            session: session,
            onSessionUpdate: handleSessionUpdate
        )
        path.append(SessionRoute(store: store))
    }

    /// Unpacks the request synchronously before starting async work. Passing
    /// `NewSessionRequest` itself through an async function-valued SwiftUI
    /// callback triggers a bad guaranteed-argument lifetime on iOS 26.
    private static func submitWorkspace(
        for request: NewSessionRequest,
        api: ConductorAPI,
        homeStore: HomeStore,
        path: Binding<[SessionRoute]>,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let project = request.project
        let branch = request.branch
        let prompt = promptText(for: request)
        let sessionName = SessionStore.derivedTitle(from: request.prompt)
        let model = request.model

        Task { @MainActor in
            do {
                try await createWorkspace(
                    project: project,
                    branch: branch,
                    prompt: prompt,
                    sessionName: sessionName,
                    model: model,
                    api: api,
                    homeStore: homeStore,
                    path: path
                )
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private static func createWorkspace(
        project: Project,
        branch: String?,
        prompt: String,
        sessionName: String?,
        model: ModelOption,
        api: ConductorAPI,
        homeStore: HomeStore,
        path: Binding<[SessionRoute]>
    ) async throws {
        let created = try await api.createWorkspace(
            projectID: project.id,
            name: nil,
            sessionName: sessionName,
            branch: branch,
            agent: model.agent,
            model: model.modelID
        )
        let store = SessionStore(
            api: api,
            created: created,
            project: project,
            initialPrompt: prompt,
            sessionName: sessionName,
            model: model,
            onSessionUpdate: { workspaceID, session in
                homeStore.selectSession(session, workspaceID: workspaceID)
            }
        )
        path.wrappedValue.append(SessionRoute(store: store))
        await homeStore.refresh()
        if let sessionName {
            // The session-list endpoint can lag workspace creation. Seed the
            // row from the creation response so it never flashes the branch.
            homeStore.selectSession(
                Session(
                    id: created.sessionId,
                    deepLink: created.deepLink,
                    name: sessionName,
                    model: model.modelID
                ),
                workspaceID: created.workspaceId
            )
        }
    }

    private func handleSessionUpdate(workspaceID: String, session: Session) {
        homeStore.selectSession(session, workspaceID: workspaceID)
    }

    private static func promptText(for request: NewSessionRequest) -> String {
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
