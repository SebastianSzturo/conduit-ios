import SwiftUI
import UIKit

/// Session detail screen: live agent transcript, follow-up composer with
/// stop/cancel, queued-message handling, and the new-workspace setup hero.
///
/// Pushed inside a `NavigationStack` by the integrator; uses the native
/// toolbar/back button and dismisses via swipe-back.
///
/// Scroll behavior: the transcript opens pinned to the newest message
/// (`.defaultScrollAnchor(.bottom)`), stays anchored to the bottom while new
/// items stream in (no per-item animated scrolls), and never moves the reader's
/// position once they scroll up. Near-bottom state is tracked with
/// `onScrollGeometryChange`.
struct SessionView: View {
    let store: SessionStore
    let settings: AppSettings
    /// Called with a store for a freshly created sibling session so the
    /// integrator can push it onto the navigation stack.
    var onNewSession: (SessionStore) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss

    // Rename alert
    @State private var showRename = false
    @State private var renameText = ""

    // New-session composer overlay (model + starting message).
    @State private var showNewSessionComposer = false

    // Error banner dismissal (local; re-shows if the store reports a new error).
    @State private var dismissedError: String?

    // Scroll bookkeeping.
    /// Whether the viewport is within ~80pt of the transcript's bottom edge.
    @State private var isNearBottom = true
    /// True when items arrived while the user was scrolled up (pill dot).
    @State private var hasNewActivity = false
    /// Bumped when the jump-to-bottom pill is tapped.
    @State private var scrollRequestToken = 0
    /// Programmatic scroll handle. Always use its edge-based API for pinning:
    /// `scrollTo(y:)` applies this binding's `.bottom` anchor to a content
    /// coordinate, so passing a calculated offset lands one viewport short.
    @State private var scrollHandle = ScrollPosition(edge: .bottom)
    /// True once the view has actually settled at the bottom of scrollable
    /// content; until then, content growth keeps force-pinning to the tail.
    @State private var didInitialSettle = false
    /// Actual height of the controls floating over the transcript. The
    /// composer grows when focused or when queue/error status is present, so a
    /// fixed spacer can leave the last message hidden underneath it.
    @State private var bottomOverlayHeight: CGFloat = 120
    /// Height currently available to the session content. This shrinks with
    /// keyboard avoidance and gives the composer a device-independent drag
    /// target without hard-coding a phone size.
    @State private var composerContainerHeight: CGFloat = 500
    /// Number of newest rows rendered; grows via "Show earlier messages".
    @State private var rowWindow = SessionView.rowWindowStep
    static let rowWindowStep = 150

    /// Near-bottom tracking payload for `onScrollGeometryChange`.
    private struct ScrollState: Equatable {
        var nearBottom: Bool
        var atBottom: Bool
        var scrollable: Bool
        var contentHeight: CGFloat
        var containerHeight: CGFloat
    }

    /// Latest observed geometry, so the initial-settle retry task only runs
    /// once the transcript has become scrollable.
    @State private var lastScrollState: ScrollState?

    private let bottomAnchor = "transcript-bottom"
    /// How close (pt) to the bottom still counts as "at bottom".
    private let nearBottomThreshold: CGFloat = 80
    /// Breathing room between the transcript tail and whichever floating
    /// control is currently lowest over it (refresh status or composer).
    private let transcriptBottomGap: CGFloat = 20

    private var visibleError: String? {
        guard let err = store.lastError, err != dismissedError else { return nil }
        return err
    }

    /// True while the network catch-up is running behind a cache-hydrated
    /// transcript. Fresh sessions with no cached items show the centered
    /// spinner in the transcript instead.
    private var isRefreshingCache: Bool {
        store.isLoadingInitial && !store.items.isEmpty
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.background.ignoresSafeArea()

            Group {
                if let setup = store.workspaceSetup {
                    WorkspaceSetupHero(setup: setup)
                } else {
                    transcript
                }
            }

            VStack(spacing: 8) {
                if !isNearBottom && store.workspaceSetup == nil {
                    scrollToBottomPill
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }
                if isRefreshingCache && store.workspaceSetup == nil {
                    refreshingPill
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }
                SessionComposer(
                    modelName: store.modelName,
                    isWorking: store.isWorking,
                    queuedCount: store.queuedMessages.count,
                    errorMessage: visibleError,
                    maxExpandedHeight: max(240, composerContainerHeight * 0.78),
                    onSend: { text in Task { await store.send(text) } },
                    onStop: { Task { await store.cancel() } },
                    onDismissError: { dismissedError = store.lastError }
                )
            }
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.size.height
            } action: { height in
                bottomOverlayHeight = height
            }

            if showNewSessionComposer {
                newSessionComposerOverlay
                    .zIndex(1)
            }
        }
        .onGeometryChange(for: CGFloat.self) { geometry in
            geometry.size.height
        } action: { height in
            composerContainerHeight = height
        }
        .animation(.easeInOut(duration: 0.18), value: isNearBottom)
        .animation(.easeInOut(duration: 0.18), value: isRefreshingCache)
        .toolbar { toolbarContent }
        .task { await store.start() }
        .onDisappear { store.stop() }
        .alert("Rename session", isPresented: $showRename) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                Task { await store.rename(to: name) }
            }
        }
    }

    // MARK: - New-session composer overlay

    /// Dimmed backdrop + composer card for spawning a sibling session, mirroring
    /// the home screen's expanded-composer presentation.
    private var newSessionComposerOverlay: some View {
        ZStack(alignment: .bottom) {
            Color.primary.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { collapseNewSessionComposer() }

            NewSessionComposer(
                initialModel: settings.model(named: store.modelID) ?? .default,
                models: settings.availableModels,
                onSubmit: { prompt, model in
                    let created = try await store.createNewSession(model: model, initialMessage: prompt)
                    onNewSession(created)
                },
                onDismiss: collapseNewSessionComposer
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func collapseNewSessionComposer() {
        withAnimation(.easeInOut(duration: 0.2)) { showNewSessionComposer = false }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Menu {
                ForEach(Array(store.availableSessions.enumerated()), id: \.element.id) { index, session in
                    Button {
                        store.switchTo(session)
                    } label: {
                        if session.id == store.sessionID {
                            Label(sessionLabel(session, index: index), systemImage: "circle.fill")
                        } else {
                            Text(sessionLabel(session, index: index))
                        }
                    }
                }
            } label: {
                VStack(spacing: 1) {
                    HStack(spacing: 5) {
                        Text(store.title)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .truncationMode(.middle)
                            .lineLimit(1)
                        if store.availableSessions.count > 1 {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    if let modelName = store.modelName {
                        Text(modelName)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: 220)
            }
            .buttonStyle(.plain)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                // Not offered while the workspace is still provisioning — a
                // sibling session can only be created once it exists.
                if store.workspaceSetup == nil {
                    Button {
                        withAnimation(.easeOut(duration: 0.25)) { showNewSessionComposer = true }
                    } label: {
                        Label("New session", systemImage: "plus.bubble")
                    }
                }
                Button {
                    renameText = store.title
                    showRename = true
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                if let link = store.deepLink {
                    Button {
                        copyToPasteboard(link)
                    } label: {
                        Label("Copy session link", systemImage: "link")
                    }
                }
                if let sessionID = store.sessionID {
                    Button {
                        copyToPasteboard(sessionID)
                    } label: {
                        Label("Copy session ID", systemImage: "number")
                    }
                }
                if store.isWorking {
                    Button(role: .destructive) {
                        Task { await store.cancel() }
                    } label: {
                        Label("Stop current run", systemImage: "stop.fill")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
        }
    }

    /// Copies session debugging information to the system clipboard.
    private func copyToPasteboard(_ value: String) {
        UIPasteboard.general.string = value
    }

    /// Display name for a session in the switcher menu.
    private func sessionLabel(_ session: Session, index: Int) -> String {
        if let name = session.name, !name.isEmpty { return name }
        return "Session \(index + 1)"
    }

    // MARK: - Rows (turn structure, time markers)

    /// A renderable transcript row: a group plus its computed top spacing, or a
    /// small centered time marker between turns.
    private enum Row: Identifiable {
        case group(TranscriptGroup, topSpacing: CGFloat)
        case timeMarker(id: String, text: String)

        var id: String {
            switch self {
            case .group(let group, _): group.id
            case .timeMarker(let id, _): "time-\(id)"
            }
        }
    }

    /// Spacing between turns (before a user prompt) vs. within a turn.
    private static let turnSpacing: CGFloat = 28
    private static let itemSpacing: CGFloat = 14
    /// Minimum gap between turns before a time marker is inserted.
    private static let timeMarkerGap: TimeInterval = 15 * 60

    private var rows: [Row] {
        let groups = TranscriptGroup.build(from: store.items)
        // Previous-item date lookup for time markers: for each userPrompt item id,
        // the date of the item immediately before it in the raw stream.
        var previousDateByPromptID: [String: Date?] = [:]
        var lastDate: Date?
        for item in store.items {
            if case .userPrompt = item.kind {
                previousDateByPromptID[item.id] = lastDate
            }
            if let date = item.date { lastDate = date }
        }

        var out: [Row] = []
        for group in groups {
            var isTurnStart = false
            if case .single(let item) = group, case .userPrompt = item.kind {
                isTurnStart = true
                if !out.isEmpty,
                   let promptDate = item.date,
                   let previousDate = previousDateByPromptID[item.id] ?? nil,
                   shouldShowTimeMarker(previous: previousDate, current: promptDate) {
                    out.append(.timeMarker(id: item.id, text: Self.timeMarkerText(promptDate)))
                }
            }
            let spacing: CGFloat = out.isEmpty ? 0 : (isTurnStart ? Self.turnSpacing : Self.itemSpacing)
            out.append(.group(group, topSpacing: spacing))
        }
        return out
    }

    private func shouldShowTimeMarker(previous: Date, current: Date) -> Bool {
        if current.timeIntervalSince(previous) > Self.timeMarkerGap { return true }
        return !Calendar.current.isDate(previous, inSameDayAs: current)
    }

    /// "14:32" today, "Yesterday 14:32", else "Jul 3, 14:32".
    private static func timeMarkerText(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return time }
        if calendar.isDateInYesterday(date) { return "Yesterday \(time)" }
        return "\(date.formatted(.dateTime.month(.abbreviated).day())), \(time)"
    }

    // MARK: - Live status

    /// Queued messages not yet represented in `items` (render as trailing dimmed
    /// bubbles). Defensive: matches by exact text since ids differ across sources.
    private var trailingQueued: [SessionStore.QueuedMessage] {
        let existing = Set(store.items.compactMap { item -> String? in
            if case .userPrompt(let text, _, true) = item.kind { return text }
            return nil
        })
        return store.queuedMessages.filter { !existing.contains($0.text) }
    }

    /// Contextual label for the bottom shimmer while the agent is working.
    private var workingLabel: String {
        switch store.items.last?.kind {
        case .thinking:
            return "Thinking…"
        case .toolUse(let info) where info.status == .running:
            return "Running \(info.title)…"
        default:
            return "Working…"
        }
    }

    /// Inline error marker at the end of the transcript (separate from the
    /// dismissible composer banner).
    private var inlineError: String? {
        guard store.status == .error, let err = store.lastError else { return nil }
        return err
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Plain (non-lazy) VStack over a bounded row window: exact
                // layout makes bottom anchoring precise. LazyVStack's estimated
                // heights made scroll-to-tail land in unrealized gaps on large
                // cached transcripts. Older rows load via "Show earlier".
                VStack(alignment: .leading, spacing: 0) {
                    if store.isLoadingInitial && store.items.isEmpty {
                        ProgressView()
                            .tint(Theme.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                    } else if store.items.isEmpty && store.queuedMessages.isEmpty && !store.isWorking {
                        VStack(spacing: 8) {
                            Image(systemName: "bubble.left.and.bubble.right")
                                .font(.system(size: 28))
                                .foregroundStyle(Theme.textTertiary)
                            Text("No messages yet")
                                .font(.subheadline)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 120)
                    }

                    if hiddenRowCount > 0 {
                        Button {
                            let previousFirstID = windowedRows.first?.id
                            rowWindow += Self.rowWindowStep
                            // Keep the reader anchored at what they were seeing.
                            if let previousFirstID {
                                DispatchQueue.main.async {
                                    proxy.scrollTo(previousFirstID, anchor: .top)
                                }
                            }
                        } label: {
                            Text("Show earlier messages (\(hiddenRowCount))")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Theme.textSecondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                    }

                    ForEach(windowedRows) { row in
                        rowView(row)
                    }

                    ForEach(trailingQueued) { queued in
                        UserPromptBubble(text: queued.text, queued: true)
                            .padding(.top, Self.itemSpacing)
                    }

                    if store.isWorking {
                        WorkingShimmerRow(label: workingLabel)
                            .padding(.top, Self.itemSpacing)
                    }

                    if let inlineError {
                        ErrorMarkerRow(message: inlineError, timestamp: store.lastErrorAt)
                            .padding(.top, Self.itemSpacing)
                    }

                    // Bottom spacer doubles as the scroll anchor. Match the
                    // floating controls' measured height, plus a deliberate
                    // content gap, so the final row clears either the refresh
                    // pill or follow-up composer without visually crowding it.
                    Color.clear
                        .frame(height: bottomOverlayHeight + transcriptBottomGap)
                        .id(bottomAnchor)
                }
                .scrollTargetLayout()
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
            // Open at the newest message with no flash. Streaming/hydration
            // pinning is handled explicitly below via content-size changes —
            // the .sizeChanges anchor variant is unreliable for large one-shot
            // LazyVStack hydrations.
            .defaultScrollAnchor(.bottom)
            .scrollPosition($scrollHandle, anchor: .bottom)
            .scrollDismissesKeyboard(.interactively)
            .onScrollGeometryChange(for: ScrollState.self) { geometry in
                // Content shorter than the viewport can't be scrolled — always
                // counts as "at bottom" (otherwise empty/short transcripts show
                // a stray jump-to-bottom pill).
                let scrollable = geometry.contentSize.height > geometry.containerSize.height
                // Use SwiftUI's resolved visible content rect instead of
                // reconstructing it from offsets and safe-area insets. The
                // latter change during the navigation transition.
                let visibleBottom = geometry.visibleRect.maxY
                let distanceFromBottom = geometry.contentSize.height - visibleBottom
                return ScrollState(
                    nearBottom: !scrollable || visibleBottom >= geometry.contentSize.height - nearBottomThreshold,
                    // Near-bottom is deliberately generous for normal reader
                    // behavior. Initial opening must be stricter: accepting an
                    // 80pt-short position as settled permanently hides the
                    // transcript tail behind the composer.
                    atBottom: !scrollable || distanceFromBottom <= 1,
                    scrollable: scrollable,
                    contentHeight: geometry.contentSize.height,
                    containerHeight: geometry.containerSize.height
                )
            } action: { old, state in
                lastScrollState = state
                // Initial settle: the push transition shifts container size and
                // safe-area insets over several frames AFTER content lands, so
                // a single pin lands short. The retry task (below) keeps forcing
                // the tail until we genuinely observe the bottom; here we just
                // record success and keep the pill hidden meanwhile.
                guard didInitialSettle else {
                    isNearBottom = true
                    hasNewActivity = false
                    if state.scrollable {
                        if state.atBottom {
                            didInitialSettle = true
                        } else {
                            // Content became scrollable after the retry task
                            // expired (session opened short, agent reply grew
                            // it past the viewport): pin to the tail here so
                            // new messages still autoscroll, converging on
                            // nearBottom and settling on the next pass.
                            scrollHandle.scrollTo(edge: .bottom)
                        }
                    }
                    return
                }
                // Explicit bottom pinning. Judged against `old.nearBottom` —
                // the position BEFORE this batch of content landed — because a
                // large append instantly pushes the (unchanged) offset far from
                // the new bottom, so the fresh `state.nearBottom` is false even
                // for a reader who was pinned. Same when the container shrinks
                // under a pinned reader (keyboard appearing).
                let grewWhilePinned = state.contentHeight != old.contentHeight
                    && old.nearBottom
                let shrankWhilePinned = state.containerHeight < old.containerHeight
                    && old.nearBottom
                if grewWhilePinned || shrankWhilePinned {
                    isNearBottom = true
                    hasNewActivity = false
                    scrollHandle.scrollTo(edge: .bottom)
                    return
                }
                isNearBottom = state.nearBottom
                if state.nearBottom {
                    hasNewActivity = false
                }
            }
            // Initial-settle retry loop: re-issue the bottom-edge target until
            // the geometry callback confirms we're there. A single fire-and-
            // forget scroll gets eaten by the push transition's container and
            // inset shuffling. Re-armed per session via `didInitialSettle`.
            .task(id: didInitialSettle) {
                guard !didInitialSettle else { return }
                for _ in 0..<40 {
                    if didInitialSettle || Task.isCancelled { return }
                    if let s = lastScrollState, s.scrollable {
                        scrollHandle.scrollTo(edge: .bottom)
                    }
                    try? await Task.sleep(for: .milliseconds(80))
                }
            }
            .onChange(of: store.items.count) { _, _ in
                if !isNearBottom { hasNewActivity = true }
            }
            // Reset the initial-pin state when the transcript empties (switchTo)
            // so the next session pins to its bottom again.
            .onChange(of: store.items.isEmpty) { _, isEmpty in
                if isEmpty { didInitialSettle = false }
            }
            .onChange(of: scrollRequestToken) { _, _ in
                withAnimation(.easeOut(duration: 0.3)) {
                    scrollHandle.scrollTo(edge: .bottom)
                }
                hasNewActivity = false
            }
            // Soft fade where content passes under the floating composer.
            .overlay(alignment: .bottom) {
                LinearGradient(
                    colors: [Theme.background.opacity(0), Theme.background.opacity(0.85)],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 90)
                .allowsHitTesting(false)
            }
        }
    }

    /// The newest `rowWindow` rows (bounded so the non-lazy VStack stays cheap).
    private var windowedRows: [Row] {
        let all = rows
        guard all.count > rowWindow else { return all }
        return Array(all.suffix(rowWindow))
    }

    private var hiddenRowCount: Int {
        max(0, rows.count - rowWindow)
    }

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        switch row {
        case .timeMarker(_, let text):
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, Self.turnSpacing)
                .accessibilityLabel("Sent \(text)")
        case .group(let group, let topSpacing):
            groupView(group)
                .padding(.top, topSpacing)
        }
    }

    private var scrollToBottomPill: some View {
        Button {
            scrollRequestToken += 1
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 40, height: 40)
                    .background(.thinMaterial, in: Circle())
                    .overlay(Circle().stroke(Theme.separator, lineWidth: 1))
                if hasNewActivity {
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 9, height: 9)
                        .offset(x: 1, y: -1)
                }
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hasNewActivity ? "Scroll to bottom, new activity" : "Scroll to bottom")
    }

    /// Floating pill shown while cached transcript content is on screen and the
    /// network catch-up is still running, so long sessions signal when they're
    /// fully loaded.
    private var refreshingPill: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .tint(Theme.textSecondary)
            Text("Updating…")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Theme.separator, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Updating messages")
    }

    // MARK: - Group dispatch

    @ViewBuilder
    private func groupView(_ group: TranscriptGroup) -> some View {
        switch group {
        case .toolGroup(_, let tools):
            ToolGroupRow(tools: tools)
        case .subtaskGroup(_, let subtasks):
            SubtaskGroupCard(subtasks: subtasks)
        case .single(let item):
            singleView(item)
        }
    }

    @ViewBuilder
    private func singleView(_ item: TranscriptItem) -> some View {
        switch item.kind {
        case .userPrompt(let text, _, let queued):
            UserPromptBubble(
                text: text,
                queued: queued,
                failed: store.failedMessageIDs.contains(item.id),
                onRetry: { Task { await store.retryMessage(id: item.id) } }
            )
        case .assistantText(let text):
            AssistantTextRow(text: text)
        case .thinking(let text, let seconds):
            ThinkingRow(text: text, seconds: seconds)
        case .toolUse(let info):
            ToolGroupRow(tools: [info])
        case .todoList(let entries):
            TodoListCard(entries: entries)
        case .subtask(let title, let status):
            SubtaskGroupCard(subtasks: [(id: item.id, title: title, status: status)])
        case .turnMarker(let text):
            TurnMarkerRow(text: text)
        case .info(let text):
            InfoRow(text: text)
        case .unknown(let typeName):
            UnknownRow(typeName: typeName)
        }
    }
}

// MARK: - Workspace setup hero

struct WorkspaceSetupHero: View {
    let setup: SessionStore.WorkspaceSetup

    var body: some View {
        VStack(spacing: 0) {
            UserPromptBubble(text: setup.pendingPrompt, queued: false)
                .padding(.horizontal, 16)
                .padding(.top, 12)

            Spacer()

            VStack(spacing: 16) {
                WorkingIndicator()
                    .scaleEffect(2.0)
                    .frame(height: 40)
                Text("Setting up workspace…")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                if let step = setup.stepLabel {
                    Text(step)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Previews

#Preview("SessionView (mock)") {
    NavigationStack {
        SessionView(
            store: SessionStore(
                api: MockConductorAPI(),
                workspaceID: "w1",
                session: MockConductorAPI.sampleSessions[0]
            ),
            settings: AppSettings()
        )
    }
    .preferredColorScheme(.dark)
}

#Preview("Workspace setup hero") {
    WorkspaceSetupHero(
        setup: SessionStore.WorkspaceSetup(
            statusKind: .initializing,
            stepLabel: "Building snapshot",
            pendingPrompt: "Make the /tickets view a 3 column layout."
        )
    )
    .background(Theme.background)
    .preferredColorScheme(.dark)
}
