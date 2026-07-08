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
    case active(Workspace, Project, Session?, WorkspaceStatusKind?)
    case archived(Workspace, Project)
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

        var title: String { session?.name ?? workspace.name }

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
    /// Ordered: working first, then unread, then by recency.
    var recents: [WorkspaceItem] {
        func rank(_ item: WorkspaceItem) -> Int {
            if item.isWorking { return 0 }
            if item.isUnread { return 1 }
            return 2
        }
        return Array(
            items
                .sorted {
                    let ra = rank($0), rb = rank($1)
                    if ra != rb { return ra < rb }
                    return $0.lastUpdatedAt > $1.lastUpdatedAt
                }
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
        let pairs: [(Project, [Workspace])] = await withTaskGroup(
            of: (Project, [Workspace])?.self
        ) { group in
            for project in loadedProjects {
                group.addTask {
                    guard let workspaces = try? await api.workspaces(projectID: project.id) else { return nil }
                    return (project, workspaces)
                }
            }
            var out: [(Project, [Workspace])] = []
            for await result in group {
                if let result { out.append(result) }
            }
            return out
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

        let results: [RefreshResult] = await Self.mapBounded(activeRefs, concurrency: 8) { ref in
            let status = try? await api.workspaceStatus(workspaceID: ref.workspace.id)
            if let kind = status?.kind, kind == .archived || kind == .deleted {
                return .archived(ref.workspace, ref.project)
            }
            let session = try? await api.sessions(workspaceID: ref.workspace.id).first
            return .active(ref.workspace, ref.project, session, status?.kind)
        }

        var built: [WorkspaceItem] = []
        for result in results {
            switch result {
            case .archived(let workspace, let project):
                recordArchived(workspace.id)
                archivedBuilt.append(archivedItem(workspace: workspace, project: project))
            case .active(let workspace, let project, let session, let statusKind):
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
        let previous = Dictionary(
            items.map { ($0.id, $0) },
            uniquingKeysWith: { a, _ in a }
        )
        var merged = built
        for i in merged.indices {
            if let prior = previous[merged[i].id] {
                merged[i].sessionStatus = prior.sessionStatus
                merged[i].sessionLastError = prior.sessionLastError
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
        // Total success clears the error banner.
        lastError = nil
        // Revalidated: rewrite the cached snapshot from fresh data.
        saveSnapshot()
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
        return try? await api.sessions(workspaceID: item.workspace.id).first
    }

    /// Starts periodic status polling for visible working items.
    func startPolling() {
        stopPolling()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollStatuses()
                try? await Task.sleep(for: .seconds(5))
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
            let workspaceStatus: WorkspaceStatusKind?
        }

        let updates: [StatusUpdate] = await withTaskGroup(of: StatusUpdate?.self) { group in
            for item in targets {
                let wsID = item.workspace.id
                let sessID = item.session?.id
                group.addTask {
                    async let ws = try? await api.workspaceStatus(workspaceID: wsID)
                    let wsKind = (await ws)?.kind
                    var sessKind: SessionStatusKind?
                    var sessErr: String?
                    if let sessID, let status = try? await api.sessionStatus(sessionID: sessID) {
                        sessKind = status.kind
                        if status.kind == .error { sessErr = status.resolvedErrorMessage }
                    }
                    return StatusUpdate(
                        id: wsID,
                        sessionStatus: sessKind,
                        sessionLastError: sessErr,
                        workspaceStatus: wsKind
                    )
                }
            }
            var out: [StatusUpdate] = []
            for await u in group where u != nil { out.append(u!) }
            return out
        }

        let byID = Dictionary(updates.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var newlyArchivedIDs: Set<String> = []
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
                if let w = u.workspaceStatus {
                    if w == .archived || w == .deleted { newlyArchivedIDs.insert(items[i].id) }
                    items[i].workspaceStatus = w
                }
            }
        }
        // Move newly-archived workspaces into the registry + archived list and
        // drop them from the cached snapshot right away.
        if !newlyArchivedIDs.isEmpty {
            for item in items where newlyArchivedIDs.contains(item.id) {
                recordArchived(item.id)
                if !archivedItems.contains(where: { $0.id == item.id }) {
                    archivedItems.append(archivedItem(workspace: item.workspace, project: item.project))
                }
            }
            archivedItems.sort {
                ($0.workspace.createdAtDate ?? .distantPast) > ($1.workspace.createdAtDate ?? .distantPast)
            }
            items.removeAll { newlyArchivedIDs.contains($0.id) }
            saveSnapshot()
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

    func renameWorkspace(_ item: WorkspaceItem, to name: String) async {
        do {
            let updated = try await api.renameWorkspace(workspaceID: item.workspace.id, name: name)
            if let idx = items.firstIndex(where: { $0.id == item.id }) {
                items[idx] = WorkspaceItem(
                    workspace: updated,
                    project: item.project,
                    session: items[idx].session,
                    sessionStatus: items[idx].sessionStatus,
                    workspaceStatus: items[idx].workspaceStatus,
                    lastActivityAt: items[idx].lastActivityAt,
                    lastSeenAt: items[idx].lastSeenAt
                )
            }
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
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
