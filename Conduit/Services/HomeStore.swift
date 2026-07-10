import Foundation
import Observation

/// Codable snapshot entry for the cached home list. Statuses are live-only and
/// never cached.
nonisolated struct HomeSnapshotEntry: Codable, Sendable {
    let workspace: Workspace
    let project: Project
    let session: Session?
}

/// Per-workspace outcome of the refresh() status-first fetch.
private nonisolated enum RefreshResult: Sendable {
    case active(Workspace, Project, SessionRefreshResult, WorkspaceStatusKind?)
    case archived(Workspace, Project)
}

/// Keeps a failed session-list request distinct from a successful empty list.
/// Collapsing both to `nil` makes a refresh erase a previously loaded title.
private nonisolated enum SessionRefreshResult: Sendable {
    case loaded(Session?)
    case failed
}

/// Root store backing the "All Repos" home screen: projects, their workspaces,
/// primary sessions, and live status polling.
///
/// CONTRACT SKELETON — the public surface below is fixed (views bind to it);
/// the foundation agent owns and fills in the implementation.
@Observable
final class HomeStore {
    struct WorkspaceItem: Identifiable, Hashable {
        let workspace: Workspace
        let project: Project
        /// Primary (most recent) session of the workspace, when loaded.
        var session: Session?
        var sessionStatus: SessionStatusKind?
        /// Short explanation carried from the session status poll when
        /// `sessionStatus == .error`, so the row can hint at what went wrong
        /// instead of showing a bare "Error". Cleared when no longer errored.
        var sessionLastError: String? = nil
        var workspaceStatus: WorkspaceStatusKind?
        /// Time of the most recent message across the workspace's sessions.
        /// Seeded from the server's `Workspace.lastActivityAt` on refresh, then
        /// bumped forward in-memory while a poll observes a working session.
        var lastActivityAt: Date? = nil
        /// When the user last opened this workspace (persisted).
        var lastSeenAt: Date? = nil

        var id: String { workspace.id }

        var title: String {
            guard let name = session?.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { return workspace.name }
            return name
        }

        /// Row subtitle status label, e.g. "Working", "Idle", "Setting up…".
        var statusLabel: String {
            if let workspaceStatus, workspaceStatus != .ready {
                switch workspaceStatus {
                case .initializing, .updating: return "Setting up…"
                case .archived: return "Archived"
                case .sleeping: return "Idle"
                default: break
                }
            }
            switch sessionStatus {
            case .working: return "Working"
            case .error:
                if let hint = Self.errorHint(sessionLastError) { return "Error — \(hint)" }
                return "Error"
            default: return "Idle"
            }
        }

        /// Condenses a raw error message into a single short line suitable for the
        /// one-line row subtitle: first non-empty line, trimmed and truncated.
        private static func errorHint(_ raw: String?) -> String? {
            guard let raw else { return nil }
            let firstLine = raw
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first(where: { !$0.isEmpty }) ?? ""
            guard !firstLine.isEmpty else { return nil }
            let limit = 48
            guard firstLine.count > limit else { return firstLine }
            return String(firstLine.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
        }

        var isWorking: Bool { sessionStatus == .working }

        /// Activity since the user last opened this workspace. Working sessions
        /// have their own indicator, so they never show as unread.
        var isUnread: Bool {
            guard workspaceStatus != .archived, workspaceStatus != .deleted else { return false }
            guard !isWorking, let activity = lastActivityAt else { return false }
            guard let seen = lastSeenAt else { return true }
            return activity > seen
        }

        /// Recency key: last session activity when known, else creation time.
        var lastUpdatedAt: Date {
            lastActivityAt ?? workspace.createdAtDate ?? .distantPast
        }
    }

    private(set) var projects: [Project] = []
    private(set) var items: [WorkspaceItem] = []
    /// Known-archived workspaces (lightweight items, session nil). Shown only
    /// under the "Archived" filter; never polled or session-fetched on refresh.
    private(set) var archivedItems: [WorkspaceItem] = []
    private(set) var isLoading = false
    private(set) var lastError: String?

    /// Most recent workspaces across all projects (home "Recents" section).
    /// Ordered strictly by workspace activity. Workspaces with no server
    /// activity timestamp are omitted instead of falling back to creation time.
    var recents: [WorkspaceItem] {
        return Array(
            items
                .compactMap { item -> (item: WorkspaceItem, activity: Date)? in
                    guard let activity = item.lastActivityAt else { return nil }
                    return (item, activity)
                }
                .sorted { $0.activity > $1.activity }
                .map(\.item)
                .prefix(5)
        )
    }

    /// Recently-used projects for the repo picker "Recents" section.
    private(set) var recentProjectIDs: [String] = []

    /// Projects the user pinned to the top of the home list (persisted).
    private(set) var pinnedProjectIDs: [String] = []

    let api: ConductorAPI

    private var pollingTask: Task<Void, Never>?
    private static let recentProjectsKey = "recentProjectIDs"
    private static let recentProjectsCap = 5
    private static let pinnedProjectsKey = "pinnedProjectIDs"
    private static let snapshotCacheKey = "home-snapshot"
    private static let lastSeenKey = "lastSeenByWorkspace"
    private static let archivedIDsKey = "archivedWorkspaceIDs"

    /// One-way registry of workspace IDs known to be archived (persisted).
    /// Entries are never removed; archiving has no undo in the API.
    private var archivedWorkspaceIDs: Set<String> = []

    /// Per-workspace "last opened" timestamps (persisted).
    private var lastSeenByWorkspace: [String: Date] = [:]

    init(api: ConductorAPI) {
        self.api = api
        self.recentProjectIDs = UserDefaults.standard.stringArray(forKey: Self.recentProjectsKey) ?? []
        self.pinnedProjectIDs = UserDefaults.standard.stringArray(forKey: Self.pinnedProjectsKey) ?? []
        if let stored = UserDefaults.standard.dictionary(forKey: Self.lastSeenKey) as? [String: Double] {
            lastSeenByWorkspace = stored.mapValues { Date(timeIntervalSince1970: $0) }
        }
        self.archivedWorkspaceIDs = Set(
            UserDefaults.standard.stringArray(forKey: Self.archivedIDsKey) ?? []
        )
        hydrateFromCache()
    }

    // MARK: - Archived registry

    /// Records a workspace as archived (persisted, one-way).
    private func recordArchived(_ workspaceID: String) {
        guard !archivedWorkspaceIDs.contains(workspaceID) else { return }
        archivedWorkspaceIDs.insert(workspaceID)
        UserDefaults.standard.set(Array(archivedWorkspaceIDs), forKey: Self.archivedIDsKey)
    }

    // MARK: - Seen / unread

    /// Records "the user viewed this workspace now" and clears its unread dot.
    func markSeen(_ item: WorkspaceItem) {
        markSeen(workspaceID: item.workspace.id)
    }

    func markSeen(workspaceID: String) {
        let now = Date()
        lastSeenByWorkspace[workspaceID] = now
        UserDefaults.standard.set(
            lastSeenByWorkspace.mapValues { $0.timeIntervalSince1970 },
            forKey: Self.lastSeenKey
        )
        if let idx = items.firstIndex(where: { $0.id == workspaceID }) {
            items[idx].lastSeenAt = now
        }
    }

    // MARK: - Home snapshot cache

    /// Populates `projects`/`items` from the cached snapshot (if any) so the
    /// home list renders instantly while a network refresh revalidates.
    private func hydrateFromCache() {
        guard let entries = ResponseCache.load([HomeSnapshotEntry].self, key: Self.snapshotCacheKey),
              !entries.isEmpty else { return }
        var seenProjects: [String: Project] = [:]
        var orderedProjects: [Project] = []
        for entry in entries where seenProjects[entry.project.id] == nil {
            seenProjects[entry.project.id] = entry.project
            orderedProjects.append(entry.project)
        }
        projects = orderedProjects
        // Old snapshots may predate the archived registry; drop known-archived.
        items = entries.filter { !archivedWorkspaceIDs.contains($0.workspace.id) }.map {
            WorkspaceItem(
                workspace: $0.workspace,
                project: $0.project,
                session: $0.session,
                sessionStatus: nil,
                workspaceStatus: nil,
                lastActivityAt: $0.workspace.lastActivityAtDate,
                lastSeenAt: lastSeenByWorkspace[$0.workspace.id]
            )
        }
    }

    /// Rewrites the snapshot from current state, excluding archived workspaces.
    private func saveSnapshot() {
        let entries = items
            .filter { $0.workspaceStatus != .archived }
            .map { HomeSnapshotEntry(workspace: $0.workspace, project: $0.project, session: $0.session) }
        ResponseCache.save(entries, key: Self.snapshotCacheKey)
    }

    func items(for project: Project) -> [WorkspaceItem] {
        items.filter { $0.project.id == project.id }
    }

    // MARK: - Pinning

    func isPinned(_ project: Project) -> Bool {
        pinnedProjectIDs.contains(project.id)
    }

    /// Adds or removes a project from the pinned set (persisted).
    func togglePinned(_ project: Project) {
        if let idx = pinnedProjectIDs.firstIndex(of: project.id) {
            pinnedProjectIDs.remove(at: idx)
        } else {
            pinnedProjectIDs.append(project.id)
        }
        UserDefaults.standard.set(pinnedProjectIDs, forKey: Self.pinnedProjectsKey)
    }

    /// Projects that are currently pinned, in the order stored, filtered to
    /// projects that still exist.
    var pinnedProjects: [Project] {
        pinnedProjectIDs.compactMap { id in projects.first { $0.id == id } }
    }

    /// Loads projects, workspaces and primary sessions. Safe to call repeatedly.
    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        let previousItems = items
        let previousArchivedItems = archivedItems

        let loadedProjects: [Project]
        do {
            loadedProjects = try await api.projects()
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return
        }
        projects = loadedProjects

        // Fetch workspaces for all projects concurrently.
        let api = self.api
        let projectResults: [(Project, [Workspace]?)] = await withTaskGroup(
            of: (Project, [Workspace]?).self
        ) { group in
            for project in loadedProjects {
                group.addTask {
                    (project, try? await api.workspaces(projectID: project.id))
                }
            }
            var out: [(Project, [Workspace]?)] = []
            for await result in group {
                out.append(result)
            }
            return out
        }
        let failedProjectIDs = Set(projectResults.compactMap { project, workspaces in
            workspaces == nil ? project.id : nil
        })
        let pairs = projectResults.compactMap { project, workspaces in
            workspaces.map { (project, $0) }
        }

        // Flatten to workspace+project pairs, then fetch each workspace's primary
        // session concurrently with a bounded concurrency of ~8.
        struct WSRef: Sendable { let workspace: Workspace; let project: Project }
        let refs: [WSRef] = pairs.flatMap { project, workspaces in
            workspaces.map { WSRef(workspace: $0, project: project) }
        }

        // Known-archived workspaces cost zero network calls: build lightweight
        // items straight from the list payload.
        let knownArchivedIDs = archivedWorkspaceIDs
        var archivedBuilt: [WorkspaceItem] = refs
            .filter { knownArchivedIDs.contains($0.workspace.id) }
            .map { archivedItem(workspace: $0.workspace, project: $0.project) }

        // For the rest: check workspace status first (1 call). Archived/deleted
        // ones are recorded and skipped; active ones fetch sessions (1 more call).
        let activeRefs = refs.filter { !knownArchivedIDs.contains($0.workspace.id) }
        let previous = Dictionary(
            items.map { ($0.id, $0) },
            uniquingKeysWith: { a, _ in a }
        )

        let results: [RefreshResult] = await Self.mapBounded(activeRefs, concurrency: 8) { ref in
            let status = try? await api.workspaceStatus(workspaceID: ref.workspace.id)
            if let kind = status?.kind, kind == .archived || kind == .deleted {
                return .archived(ref.workspace, ref.project)
            }
            let sessionResult: SessionRefreshResult
            do {
                let sessions = try await api.sessions(workspaceID: ref.workspace.id)
                sessionResult = .loaded(await Self.primarySession(in: sessions, api: api))
            } catch {
                sessionResult = .failed
            }
            return .active(ref.workspace, ref.project, sessionResult, status?.kind)
        }

        // An open SessionStore may have published a rename while the network
        // calls above were suspended. Prefer that newest in-memory value over
        // the snapshot captured at refresh start.
        let latest = Dictionary(
            items.map { ($0.id, $0) },
            uniquingKeysWith: { a, _ in a }
        )

        // Start failed projects with their complete last-known-good rows. A
        // partial refresh must never look like the server deleted them.
        var built: [WorkspaceItem] = previousItems.filter { failedProjectIDs.contains($0.project.id) }
        archivedBuilt.append(contentsOf: previousArchivedItems.filter {
            failedProjectIDs.contains($0.project.id)
        })
        var hadSessionFailure = false
        for result in results {
            switch result {
            case .archived(let workspace, let project):
                recordArchived(workspace.id)
                archivedBuilt.append(archivedItem(workspace: workspace, project: project))
            case .active(let workspace, let project, let sessionResult, let statusKind):
                let initialSession = previous[workspace.id]?.session
                let latestSession = latest[workspace.id]?.session
                let priorSession = latestSession ?? initialSession
                let changedWhileRefreshing = latestSession != initialSession
                let session: Session?
                switch sessionResult {
                case .loaded(let fresh?):
                    session = changedWhileRefreshing
                        ? latestSession
                        : Self.mergingKnownName(from: priorSession, into: fresh)
                case .loaded(nil):
                    // Workspace creation always creates an initial session, so
                    // an empty list for a previously populated active workspace
                    // is an eventual-consistency response, not a deletion signal.
                    session = priorSession
                case .failed:
                    hadSessionFailure = true
                    session = priorSession
                }
                built.append(WorkspaceItem(
                    workspace: workspace,
                    project: project,
                    session: session,
                    sessionStatus: nil,
                    workspaceStatus: statusKind,
                    lastActivityAt: workspace.lastActivityAtDate,
                    lastSeenAt: nil
                ))
            }
        }

        // Preserve any already-known session statuses across refreshes; workspace
        // status and last activity are freshly fetched (built already carries the
        // server's lastActivityAt).
        var merged = built
        for i in merged.indices {
            if let prior = latest[merged[i].id] ?? previous[merged[i].id] {
                // A status belongs to a session, not its workspace. Preserve it
                // only while the representative session remains the same.
                if merged[i].session?.id == prior.session?.id {
                    merged[i].sessionStatus = prior.sessionStatus
                    merged[i].sessionLastError = prior.sessionLastError
                }
                // Monotonic: never regress the server value below an in-flight
                // working bump made since the previous refresh.
                merged[i].lastActivityAt = maxDate(merged[i].lastActivityAt, prior.lastActivityAt)
            }
            merged[i].lastSeenAt = lastSeenByWorkspace[merged[i].id]
        }

        items = merged.sorted { $0.lastUpdatedAt > $1.lastUpdatedAt }
        archivedItems = archivedBuilt.sorted {
            ($0.workspace.createdAtDate ?? .distantPast) > ($1.workspace.createdAtDate ?? .distantPast)
        }
        if failedProjectIDs.isEmpty && !hadSessionFailure {
            lastError = nil
            saveSnapshot()
        } else {
            lastError = "Some data may be out of date. Showing the last successful refresh."
        }
    }

    /// Lightweight item for a known-archived workspace (no network data).
    private func archivedItem(workspace: Workspace, project: Project) -> WorkspaceItem {
        WorkspaceItem(
            workspace: workspace,
            project: project,
            session: nil,
            sessionStatus: nil,
            workspaceStatus: .archived,
            lastActivityAt: workspace.lastActivityAtDate,
            lastSeenAt: lastSeenByWorkspace[workspace.id]
        )
    }

    /// Fetches the primary session for an item on demand (used when opening an
    /// archived workspace, whose sessions are never fetched during refresh).
    func primarySession(for item: WorkspaceItem) async -> Session? {
        if let session = item.session { return session }
        guard let sessions = try? await api.sessions(workspaceID: item.workspace.id) else { return nil }
        return await Self.primarySession(in: sessions, api: api)
    }

    /// Uses the API's first session. Sorting by individually fetching every
    /// session status caused an unbounded refresh fan-out; the planned mobile
    /// summary endpoint should provide an explicit primary session server-side.
    private static func primarySession(
        in sessions: [Session],
        api: ConductorAPI
    ) async -> Session? {
        sessions.first
    }

    /// Starts periodic status polling for visible working items.
    func startPolling() {
        stopPolling()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollStatuses()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func pollStatuses() async {
        let targets = Array(items.prefix(15))
        guard !targets.isEmpty else { return }
        let api = self.api

        struct StatusUpdate: Sendable {
            let id: String
            let sessionStatus: SessionStatusKind?
            let sessionLastError: String?
        }

        let updates: [StatusUpdate] = await withTaskGroup(of: StatusUpdate?.self) { group in
            for item in targets {
                let sessID = item.session?.id
                group.addTask {
                    var sessKind: SessionStatusKind?
                    var sessErr: String?
                    if let sessID, let status = try? await api.sessionStatus(sessionID: sessID) {
                        sessKind = status.kind
                        if status.kind == .error { sessErr = status.resolvedErrorMessage }
                    }
                    return StatusUpdate(
                        id: item.workspace.id,
                        sessionStatus: sessKind,
                        sessionLastError: sessErr
                    )
                }
            }
            var out: [StatusUpdate] = []
            for await u in group where u != nil { out.append(u!) }
            return out
        }

        let byID = Dictionary(updates.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for i in items.indices {
            if let u = byID[items[i].id] {
                if let s = u.sessionStatus {
                    items[i].sessionStatus = s
                    // Keep the error hint only while errored; clear it otherwise
                    // so a recovered session doesn't show a stale message.
                    items[i].sessionLastError = (s == .error) ? u.sessionLastError : nil
                    // Polls only fetch statuses, not workspace objects, so keep an
                    // actively-working item rising in recency between full refreshes
                    // by bumping its in-memory activity forward (never backward).
                    if s == .working {
                        items[i].lastActivityAt = maxDate(items[i].lastActivityAt, Date())
                    }
                }
            }
        }
    }

    /// Records a project as recently used (persisted in UserDefaults).
    func markProjectUsed(_ project: Project) {
        var ids = recentProjectIDs.filter { $0 != project.id }
        ids.insert(project.id, at: 0)
        if ids.count > Self.recentProjectsCap { ids = Array(ids.prefix(Self.recentProjectsCap)) }
        recentProjectIDs = ids
        UserDefaults.standard.set(ids, forKey: Self.recentProjectsKey)
    }

    func archiveWorkspace(_ item: WorkspaceItem) async {
        do {
            try await api.archiveWorkspace(workspaceID: item.workspace.id)
            recordArchived(item.workspace.id)
            items.removeAll { $0.id == item.id }
            if !archivedItems.contains(where: { $0.id == item.id }) {
                archivedItems.append(archivedItem(workspace: item.workspace, project: item.project))
                archivedItems.sort {
                    ($0.workspace.createdAtDate ?? .distantPast) > ($1.workspace.createdAtDate ?? .distantPast)
                }
            }
            saveSnapshot()
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Renames the session whose name is displayed by the home row.
    func renameSession(_ item: WorkspaceItem, to name: String) async {
        do {
            let session: Session
            if let loaded = item.session {
                session = loaded
            } else if let loaded = await primarySession(for: item) {
                session = loaded
            } else {
                return
            }
            let updated = try await api.renameSession(sessionID: session.id, name: name)
            let returnedName = updated.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let effective = Session(
                id: updated.id,
                deepLink: updated.deepLink,
                name: (returnedName?.isEmpty == false) ? updated.name : name,
                model: updated.model ?? session.model
            )
            updateSession(effective, workspaceID: item.workspace.id)
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Applies a session mutation from a live SessionStore immediately, keeping
    /// the all-repos list and its disk snapshot in sync without a network race.
    func updateSession(_ session: Session, workspaceID: String) {
        if let idx = items.firstIndex(where: { $0.id == workspaceID }) {
            let priorID = items[idx].session?.id
            items[idx].session = Self.mergingKnownName(from: items[idx].session, into: session)
            if priorID != session.id {
                items[idx].sessionStatus = nil
                items[idx].sessionLastError = nil
            }
            saveSnapshot()
        }
        if let idx = archivedItems.firstIndex(where: { $0.id == workspaceID }) {
            archivedItems[idx].session = Self.mergingKnownName(
                from: archivedItems[idx].session,
                into: session
            )
        }
    }

    /// Session list responses can briefly omit a name immediately after a
    /// rename. Do not let that partial representation regress a known title.
    private static func mergingKnownName(from previous: Session?, into fresh: Session) -> Session {
        let freshName = fresh.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (freshName == nil || freshName?.isEmpty == true),
              previous?.id == fresh.id,
              let previousName = previous?.name,
              !previousName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return fresh }
        return Session(
            id: fresh.id,
            deepLink: fresh.deepLink,
            name: previousName,
            model: fresh.model ?? previous?.model
        )
    }

    /// Later of two optional dates, treating `nil` as "no value". Used to keep
    /// `lastActivityAt` monotonic when merging a fresh server value with an
    /// in-flight working bump.
    private func maxDate(_ a: Date?, _ b: Date?) -> Date? {
        switch (a, b) {
        case let (a?, b?): return max(a, b)
        case let (a?, nil): return a
        case let (nil, b?): return b
        case (nil, nil): return nil
        }
    }

    /// Maps `inputs` through an async transform with bounded concurrency,
    /// preserving input order in the output.
    private static func mapBounded<In: Sendable, Out: Sendable>(
        _ inputs: [In],
        concurrency: Int,
        _ transform: @escaping @Sendable (In) async -> Out
    ) async -> [Out] {
        guard !inputs.isEmpty else { return [] }
        let limit = max(1, concurrency)
        var results = [Out?](repeating: nil, count: inputs.count)
        await withTaskGroup(of: (Int, Out).self) { group in
            var next = 0
            // Prime the pool.
            while next < inputs.count, next < limit {
                let idx = next
                let value = inputs[idx]
                group.addTask { (idx, await transform(value)) }
                next += 1
            }
            while let (idx, out) = await group.next() {
                results[idx] = out
                if next < inputs.count {
                    let i = next
                    let value = inputs[i]
                    group.addTask { (i, await transform(value)) }
                    next += 1
                }
            }
        }
        return results.compactMap { $0 }
    }
}
