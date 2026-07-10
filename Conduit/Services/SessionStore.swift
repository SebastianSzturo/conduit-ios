import Foundation
import Observation

/// Per-session chat store: transcript, live polling, sending, queueing, cancel.
///
/// CONTRACT SKELETON — the public surface below is fixed (views bind to it);
/// the foundation agent owns and fills in the implementation.
@Observable
final class SessionStore: Identifiable {
    typealias SessionUpdateHandler = (_ workspaceID: String, _ session: Session) -> Void

    /// Set while a freshly-created workspace is still provisioning.
    struct WorkspaceSetup: Hashable {
        var statusKind: WorkspaceStatusKind
        var stepLabel: String?
        /// The initial prompt waiting to be sent once the workspace is ready.
        var pendingPrompt: String
    }

    struct QueuedMessage: Identifiable, Hashable {
        let id: String        // client-generated messageId
        let text: String
    }

    // Identity
    let workspaceID: String
    private(set) var sessionID: String?
    /// Server-provided deep link for this session (e.g.
    /// `conductor://workspace?id=<workspace>&session=<session>`), used by the
    /// "Copy link" action. Nil until known (new-workspace flow before the
    /// session's own link is fetched).
    private(set) var deepLink: String?
    /// The model id this session runs (drives the agent/model used when
    /// spawning a sibling "new session" in the same workspace).
    private(set) var modelID: String?

    // Presentation state (views bind to these)
    private(set) var title: String
    private(set) var modelName: String?
    private(set) var items: [TranscriptItem] = []
    private(set) var status: SessionStatusKind = .idle
    private(set) var workspaceSetup: WorkspaceSetup?
    private(set) var queuedMessages: [QueuedMessage] = []
    /// Client message ids whose POST failed. Their optimistic bubbles remain in
    /// the transcript and expose an idempotent Retry action.
    private(set) var failedMessageIDs: Set<String> = []
    private(set) var isCancelling = false
    private(set) var isLoadingInitial = false
    private(set) var lastError: String?
    /// When the server-reported session error occurred, when known. Drives the
    /// relative-time hint on the inline error marker. Nil for local action
    /// errors (send/cancel/rename) and setup-phase errors, which have no
    /// server timestamp.
    private(set) var lastErrorAt: Date?
    /// All sessions in this workspace (drives the nav-title session switcher).
    private(set) var availableSessions: [Session] = []
    /// True while the agent is actively producing events (drives the stop button
    /// and "Working…" shimmer).
    var isWorking: Bool { status == .working }

    var id: String { sessionID ?? workspaceID }

    let api: ConductorAPI
    /// Bridges session-level name changes back to the all-repos store, which
    /// otherwise owns a separate cached copy of the session.
    private let onSessionUpdate: SessionUpdateHandler?

    /// True while `title` is a locally-derived placeholder (project name / "Session")
    /// rather than a real server-provided session name. A non-empty server name
    /// always wins over any local derivation.
    private var titleIsGenericFallback: Bool

    /// Opens an existing session.
    init(
        api: ConductorAPI,
        workspaceID: String,
        session: Session,
        onSessionUpdate: SessionUpdateHandler? = nil
    ) {
        self.api = api
        self.onSessionUpdate = onSessionUpdate
        self.workspaceID = workspaceID
        self.sessionID = session.id
        self.deepLink = session.deepLink
        self.modelID = session.model
        if let name = session.name, !name.isEmpty {
            self.title = name
            self.titleIsGenericFallback = false
        } else {
            self.title = "Session"
            self.titleIsGenericFallback = true
        }
        self.modelName = ModelOption.displayName(for: session.model)
    }

    /// Starts the new-workspace flow: workspace was just created, is provisioning,
    /// and `initialPrompt` must be sent once it becomes ready.
    init(
        api: ConductorAPI,
        created: WorkspaceCreateResponse,
        project: Project,
        initialPrompt: String,
        sessionName: String?,
        model: ModelOption,
        onSessionUpdate: SessionUpdateHandler? = nil
    ) {
        self.api = api
        self.onSessionUpdate = onSessionUpdate
        self.workspaceID = created.workspaceId
        self.sessionID = created.sessionId
        self.deepLink = created.deepLink
        self.modelID = model.modelID
        if let sessionName, !sessionName.isEmpty {
            self.title = sessionName
            self.titleIsGenericFallback = false
        } else {
            self.title = project.name
            self.titleIsGenericFallback = true
        }
        self.modelName = model.displayName
        self.workspaceSetup = WorkspaceSetup(statusKind: .initializing, stepLabel: nil, pendingPrompt: initialPrompt)
    }

    // MARK: - Private state

    /// Raw envelopes accumulated across polls (append-only). `items` is rebuilt
    /// from this on every change.
    private var rawMessages: [APIMessage] = []
    /// Cursor for the next messages fetch: the id of the last envelope held.
    /// Messages arrive in ascending `sessionIndex` order and `rawMessages` is
    /// append-only, so its last id is exactly the exclusive `after` cursor.
    /// Derived (never stored) so it cannot desync from the transcript — e.g.
    /// resetting `rawMessages = []` automatically resets the cursor to nil.
    private var messageCursor: String? { rawMessages.last?.id }
    private var loopTask: Task<Void, Never>?
    /// clientMessageIDs of optimistic user prompts we have appended locally,
    /// so we can dedupe when the real envelope arrives.
    private var optimisticPromptIDs: Set<String> = []
    /// Counts status refreshes so the workspace session list is re-fetched
    /// every Nth poll instead of every time.
    private var statusRefreshCount = 0
    /// True once the workspace is known to be archived/deleted: all cache reads
    /// and writes are skipped for the rest of this store's life.
    private var cacheDisabled = false

    // MARK: - Cache keys

    private var messagesCacheKey: String { "messages-\(sessionID ?? workspaceID)" }
    private var sessionsCacheKey: String { "sessions-\(workspaceID)" }

    // MARK: - Lifecycle

    /// Begins message + status polling (call from .task / onAppear).
    func start() async {
        stop()
        loopTask = Task { [weak self] in
            await self?.runLoop()
        }
        await loopTask?.value
    }

    /// Stops all polling (call from onDisappear).
    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    /// Switches this store to another session in the same workspace: stops the
    /// poll loop, resets all transcript state, adopts the session's identity,
    /// and restarts polling.
    func switchTo(_ session: Session) {
        guard session.id != sessionID else { return }
        stop()

        // Reset transcript state. Clearing `rawMessages` also resets the
        // message cursor, since it is derived from `rawMessages.last`.
        rawMessages = []
        items = []
        queuedMessages = []
        failedMessageIDs = []
        optimisticPromptIDs = []
        status = .idle
        lastError = nil
        lastErrorAt = nil
        statusRefreshCount = 0

        // Adopt the new session's identity.
        sessionID = session.id
        deepLink = session.deepLink
        modelID = session.model
        if let name = session.name, !name.isEmpty {
            title = name
            titleIsGenericFallback = false
        } else {
            title = "Session"
            titleIsGenericFallback = true
        }
        modelName = ModelOption.displayName(for: session.model)
        publishSessionUpdate(session)

        // Restart the run loop (stop() above guarantees no double loops).
        loopTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    /// Refreshes the workspace's session list in one request. Avoid per-session
    /// status fan-out; the server's mobile summary endpoint should eventually
    /// supply authoritative activity ordering in the same payload.
    private func refreshAvailableSessions() async {
        guard let sessions = try? await api.sessions(workspaceID: workspaceID) else { return }
        availableSessions = sessions
        if let sessionID,
           let current = sessions.first(where: { $0.id == sessionID }),
           let name = current.name, !name.isEmpty,
           titleIsGenericFallback || name != title {
            adoptNamedSession(current, fallbackName: name)
        }
        if !cacheDisabled {
            ResponseCache.save(sessions, key: sessionsCacheKey)
        }
    }

    private func runLoop() async {
        // Phase 0: hydrate transcript + switcher from disk BEFORE any network
        // touches, so a previously-opened session renders instantly.
        hydrateFromCache()

        // Phase 1: workspace provisioning, if applicable.
        if workspaceSetup != nil {
            await runSetupPhase()
        } else {
            // Existing workspace: one best-effort archived check, off the
            // critical path. Archived workspaces get their cache entries
            // deleted and caching disabled.
            Task { [weak self] in
                await self?.purgeCacheIfWorkspaceArchived()
            }
        }
        guard !Task.isCancelled else { return }

        // Phase 2: initial full fetch (resumes from the hydrated offset).
        await loadInitialMessages()

        // Phase 3: steady-state polling.
        while !Task.isCancelled {
            let interval: Duration = (status == .working || !queuedMessages.isEmpty)
                ? .seconds(2) : .seconds(6)
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { break }
            await pollOnce()
        }
    }

    // MARK: - Setup phase (new workspace provisioning)

    private func runSetupPhase() async {
        while !Task.isCancelled, workspaceSetup != nil {
            let ws = try? await api.workspaceStatus(workspaceID: workspaceID)
            if let ws {
                workspaceSetup?.statusKind = ws.kind
                workspaceSetup?.stepLabel = ws.step?.label
                if let err = ws.errorMessage { lastError = err }
                if ws.kind == .ready {
                    await sendPendingPrompt()
                    workspaceSetup = nil
                    return
                }
                if ws.kind == .archived || ws.kind == .deleted {
                    workspaceSetup = nil
                    return
                }
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func sendPendingPrompt() async {
        guard let prompt = workspaceSetup?.pendingPrompt, !prompt.isEmpty else { return }
        await sendInitialPrompt(prompt)
    }

    /// Sends the first prompt of a session the app just created: optimistic
    /// append + queue handling, then derives and persists a title when creation
    /// did not already provide one.
    private func sendInitialPrompt(_ prompt: String) async {
        guard let sessionID else { return }
        let clientID = UUID().uuidString
        appendOptimisticPrompt(text: prompt, clientID: clientID)
        do {
            let response = try await api.sendMessage(sessionID: sessionID, text: prompt, clientMessageID: clientID)
            if response.isQueued {
                queuedMessages.append(QueuedMessage(id: response.messageId, text: prompt))
                markPromptQueued(clientID: clientID, queued: true)
            }
            if titleIsGenericFallback, let derived = Self.derivedTitle(from: prompt) {
                title = derived
                publishLocalTitleIfPossible()
                await persistDerivedTitleIfNeeded()
            }
        } catch {
            failedMessageIDs.insert(clientID)
            lastError = errorText(error)
        }
    }

    /// Derives a session title from a prompt: first non-empty line, word-truncated
    /// to ≤40 chars, trailing punctuation stripped. Returns nil if nothing usable.
    static func derivedTitle(from prompt: String) -> String? {
        let firstLine = prompt
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }) ?? ""
        guard !firstLine.isEmpty else { return nil }

        var result: String
        if firstLine.count <= 40 {
            result = firstLine
        } else {
            // Word-truncate: accumulate whole words up to the 40-char budget.
            var words: [String] = []
            var length = 0
            for word in firstLine.split(separator: " ") {
                let addition = (words.isEmpty ? 0 : 1) + word.count
                if length + addition > 40 { break }
                words.append(String(word))
                length += addition
            }
            result = words.isEmpty ? String(firstLine.prefix(40)) : words.joined(separator: " ")
        }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: " .,:;!?-—…"))
        return result.isEmpty ? nil : result
    }

    /// For sessions the app did not create (opened existing, no server name),
    /// derive a title from the first user prompt once messages load. The async
    /// load path persists it afterward so home and future launches see it too.
    private func deriveTitleFromTranscriptIfNeeded() {
        guard titleIsGenericFallback else { return }
        let firstPrompt = items.first { item in
            if case .userPrompt = item.kind { return true }
            return false
        }
        guard case .userPrompt(let text, _, _)? = firstPrompt?.kind,
              let derived = Self.derivedTitle(from: text) else { return }
        let changed = derived != title
        title = derived
        if changed { publishLocalTitleIfPossible() }
        // Keep the flag set so a real server name can still override later.
    }

    // MARK: - Message fetching

    /// Reads the cached transcript + session list synchronously (disk only, no
    /// network). Called before anything else so reopened sessions render
    /// immediately; the network fetch then resumes from the cached transcript's
    /// last message id (`messageCursor`).
    private func hydrateFromCache() {
        guard !cacheDisabled else { return }
        if rawMessages.isEmpty,
           let cached = ResponseCache.load([APIMessage].self, key: messagesCacheKey),
           !cached.isEmpty {
            rawMessages = cached
            rebuildItems()
            deriveTitleFromTranscriptIfNeeded()
        }
        if availableSessions.isEmpty,
           let cachedSessions = ResponseCache.load([Session].self, key: sessionsCacheKey) {
            availableSessions = cachedSessions
        }
    }

    /// Best-effort archived check, run off the critical path.
    private func purgeCacheIfWorkspaceArchived() async {
        guard let ws = try? await api.workspaceStatus(workspaceID: workspaceID),
              ws.kind == .archived || ws.kind == .deleted else { return }
        cacheDisabled = true
        ResponseCache.remove(key: messagesCacheKey)
        ResponseCache.remove(key: sessionsCacheKey)
    }

    private func loadInitialMessages() async {
        guard let sessionID else { return }
        isLoadingInitial = true
        defer { isLoadingInitial = false }

        // Already hydrated from disk in phase 0; fetch only what was appended
        // since (messages are append-only), resuming from the cached
        // transcript's last message id.
        let hadCache = !rawMessages.isEmpty

        let ok = await fetchMessagePages(sessionID: sessionID, after: messageCursor)
        if !ok, hadCache {
            // The first page of the resumed fetch failed: distrust the cache and
            // do the full from-scratch fetch. This also covers a server that
            // 4xxes on an unknown/pruned cursor id (any error is a page failure).
            ResponseCache.remove(key: messagesCacheKey)
            rawMessages = []
            _ = await fetchMessagePages(sessionID: sessionID, after: nil)
        }
        rebuildItems()
        deriveTitleFromTranscriptIfNeeded()
        await persistDerivedTitleIfNeeded()
        saveMessagesToCache()
        await refreshAvailableSessions()
        await refreshStatus()
    }

    /// Fetches message pages starting after `after` (nil == from the beginning),
    /// appending into `rawMessages` and advancing the cursor to the last id of
    /// each page. Returns false if the first page fails.
    private func fetchMessagePages(sessionID: String, after: String?) async -> Bool {
        var after = after
        var isFirstPage = true
        while !Task.isCancelled {
            guard let page = try? await api.messages(sessionID: sessionID, after: after, limit: 100) else {
                if isFirstPage {
                    lastError = "Couldn't load messages — check your connection and try again."
                    return false
                }
                break
            }
            isFirstPage = false
            rawMessages.append(contentsOf: page.data)
            after = page.data.last?.id ?? after
            if !page.hasMore || page.data.isEmpty { break }
        }
        return true
    }

    /// Writes the raw envelopes back to disk (skipped for archived workspaces).
    private func saveMessagesToCache() {
        guard !cacheDisabled, sessionID != nil, !rawMessages.isEmpty else { return }
        ResponseCache.save(rawMessages, key: messagesCacheKey)
    }

    private func pollOnce() async {
        guard let sessionID else { return }
        // Fetch any new envelopes appended since the last known message id.
        // `messageCursor` is derived from `rawMessages.last`, so each append
        // advances it for the next iteration automatically.
        var appended = false
        while !Task.isCancelled {
            guard let page = try? await api.messages(sessionID: sessionID, after: messageCursor, limit: 100)
            else { break }
            if !page.data.isEmpty {
                rawMessages.append(contentsOf: page.data)
                appended = true
            }
            if !page.hasMore || page.data.isEmpty { break }
        }
        if appended {
            reconcileQueuedMessages()
            rebuildItems()
            deriveTitleFromTranscriptIfNeeded()
            await persistDerivedTitleIfNeeded()
            saveMessagesToCache()
        }
        await refreshStatus()
    }

    private func refreshStatus() async {
        guard let sessionID else { return }
        // Re-fetch the workspace's session list occasionally (every 5th poll).
        statusRefreshCount += 1
        if statusRefreshCount % 5 == 0 {
            await refreshAvailableSessions()
        }
        guard let status = try? await api.sessionStatus(sessionID: sessionID) else { return }
        self.status = status.kind
        if status.kind == .error {
            // The server put the session in `error` state, so always surface the
            // best explanation it can give — the transient detail, else the
            // persisted reason, else a generic line so the banner is never blank.
            lastError = status.resolvedErrorMessage ?? "The agent hit an error"
            lastErrorAt = status.lastErrorAtDate
        } else {
            // Not errored: a transient server `errorMessage` still shows if
            // present (preserving prior precedence), otherwise clear. Local
            // action errors are cleared by the next poll just as before.
            lastError = status.errorMessage
            lastErrorAt = nil
        }
    }

    // MARK: - Rebuild / dedupe

    private func rebuildItems() {
        let optimisticItems = items.filter { optimisticPromptIDs.contains($0.id) }
        var built = TranscriptBuilder.build(messages: rawMessages)
        // Drop optimistic placeholders that the server has now echoed back.
        let realPromptIDs = Set(built.map(\.id))
        // Merge queued flags from queuedMessages onto matching prompts.
        let queuedIDs = Set(queuedMessages.map(\.id))
        for i in built.indices {
            if case .userPrompt(let text, let model, _) = built[i].kind,
               queuedIDs.contains(built[i].id) {
                built[i].kind = .userPrompt(text: text, modelName: model, queued: true)
            }
        }
        // Remove local optimistic items whose id now appears from the server.
        optimisticPromptIDs = optimisticPromptIDs.filter { !realPromptIDs.contains($0) }
        failedMessageIDs.subtract(realPromptIDs)
        let remainingOptimistic = optimisticItems.filter { optimisticPromptIDs.contains($0.id) }
        items = built + remainingOptimistic
    }

    /// When a real userMessage envelope arrives for a queued client id, drop it
    /// from the queue.
    private func reconcileQueuedMessages() {
        guard !queuedMessages.isEmpty else { return }
        let arrivedIDs = Set(
            rawMessages.compactMap { msg -> String? in
                guard msg.type == "userMessage" else { return nil }
                return msg.content["id"]?.stringValue ?? msg.id
            }
        )
        queuedMessages.removeAll { arrivedIDs.contains($0.id) }
    }

    // MARK: - Optimistic prompts

    private func appendOptimisticPrompt(text: String, clientID: String) {
        optimisticPromptIDs.insert(clientID)
        items.append(
            TranscriptItem(
                id: clientID,
                kind: .userPrompt(text: text, modelName: modelName, queued: false),
                date: .now
            )
        )
    }

    private func markPromptQueued(clientID: String, queued: Bool) {
        guard let idx = items.firstIndex(where: { $0.id == clientID }) else { return }
        if case .userPrompt(let text, let model, _) = items[idx].kind {
            items[idx].kind = .userPrompt(text: text, modelName: model, queued: queued)
        }
    }

    // MARK: - Actions

    /// Sends a follow-up. Appends optimistically; marks it queued if the API
    /// reports state == "queued".
    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let sessionID else { return }
        let clientID = UUID().uuidString
        appendOptimisticPrompt(text: trimmed, clientID: clientID)
        await deliverMessage(id: clientID, text: trimmed, sessionID: sessionID)
    }

    /// Retries a failed optimistic prompt with the same client id, allowing the
    /// server to deduplicate a request whose response may have been lost.
    func retryMessage(id: String) async {
        guard failedMessageIDs.contains(id),
              let sessionID,
              let item = items.first(where: { $0.id == id }),
              case .userPrompt(let text, _, _) = item.kind
        else { return }
        failedMessageIDs.remove(id)
        await deliverMessage(id: id, text: text, sessionID: sessionID)
    }

    private func deliverMessage(id: String, text: String, sessionID: String) async {
        do {
            let response = try await api.sendMessage(sessionID: sessionID, text: text, clientMessageID: id)
            failedMessageIDs.remove(id)
            if response.isQueued {
                if !queuedMessages.contains(where: { $0.id == response.messageId }) {
                    queuedMessages.append(QueuedMessage(id: response.messageId, text: text))
                }
                markPromptQueued(clientID: id, queued: true)
            }
        } catch {
            failedMessageIDs.insert(id)
            lastError = errorText(error)
        }
    }

    /// Cancels the running turn and clears the queue.
    func cancel() async {
        guard let sessionID, !isCancelling else { return }
        isCancelling = true
        defer { isCancelling = false }
        do {
            _ = try await api.cancelSession(sessionID: sessionID)
            queuedMessages.removeAll()
            status = .idle
        } catch {
            lastError = errorText(error)
        }
    }

    /// Creates a fresh session in the same workspace on the chosen model, sends
    /// the starting message, and returns a store opened on it, ready to be
    /// pushed onto the nav stack. Throws on failure (and also surfaces the
    /// error on this store) so the composer can retain its draft.
    func createNewSession(model: ModelOption, initialMessage: String) async throws -> SessionStore {
        let trimmed = initialMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let derivedName = Self.derivedTitle(from: trimmed)
        do {
            let created = try await api.createSession(
                workspaceID: workspaceID,
                name: derivedName,
                agent: model.agent,
                model: model.modelID
            )
            let session = Self.session(created, fillingNameWith: derivedName, modelWith: model.modelID)
            publishSessionUpdate(session)
            let store = SessionStore(
                api: api,
                workspaceID: workspaceID,
                session: session,
                onSessionUpdate: onSessionUpdate
            )
            if store.modelID == nil {
                // Response omitted the model: reflect the chosen one locally.
                store.modelID = model.modelID
                store.modelName = model.displayName
            }
            if !trimmed.isEmpty {
                await store.sendInitialPrompt(trimmed)
            }
            return store
        } catch {
            lastError = errorText(error)
            throw error
        }
    }

    func rename(to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let sessionID else { return }
        do {
            let updated = try await api.renameSession(sessionID: sessionID, name: trimmed)
            adoptNamedSession(updated, fallbackName: trimmed)
        } catch {
            lastError = errorText(error)
        }
    }

    private func errorText(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// Persists a transcript-derived fallback. A failed best-effort attempt
    /// leaves the fallback flag set, allowing a later load/poll to retry.
    private func persistDerivedTitleIfNeeded() async {
        guard titleIsGenericFallback,
              let sessionID,
              title != "Session",
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        guard let updated = try? await api.renameSession(sessionID: sessionID, name: title) else { return }
        adoptNamedSession(updated, fallbackName: title)
    }

    /// Adopts the server representation and publishes the same value to home.
    private func adoptNamedSession(_ session: Session, fallbackName: String) {
        let effective = Self.session(session, fillingNameWith: fallbackName, modelWith: modelID)
        if let name = effective.name, !name.isEmpty {
            title = name
            titleIsGenericFallback = false
        }
        deepLink = effective.deepLink
        if let model = effective.model {
            modelID = model
            modelName = ModelOption.displayName(for: model)
        }
        publishSessionUpdate(effective)
    }

    private func publishSessionUpdate(_ session: Session) {
        if let idx = availableSessions.firstIndex(where: { $0.id == session.id }) {
            availableSessions[idx] = session
        }
        onSessionUpdate?(workspaceID, session)
    }

    /// Shares a useful local fallback immediately, even when persisting it is
    /// temporarily offline. Home's merge keeps this name until the retry lands.
    private func publishLocalTitleIfPossible() {
        guard let sessionID,
              let deepLink,
              title != "Session",
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        publishSessionUpdate(Session(
            id: sessionID,
            deepLink: deepLink,
            name: title,
            model: modelID
        ))
    }

    private static func session(
        _ session: Session,
        fillingNameWith fallbackName: String?,
        modelWith fallbackModel: String?
    ) -> Session {
        let name = session.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Session(
            id: session.id,
            deepLink: session.deepLink,
            name: (name?.isEmpty == false) ? session.name : fallbackName,
            model: session.model ?? fallbackModel
        )
    }
}
