import Foundation
import Observation

/// Mutable state backing the prompt composer (selected repo/branch/model/mode
/// and the draft text). Shared between the collapsed pill, the expanded card,
/// and the picker sheets.
@Observable
final class ComposerState {
    var prompt: String = ""
    var selectedProject: Project?
    var branch: String = "main"
    var selectedModel: ModelOption = .default
    var thinkingLevel: ThinkingLevel = .default
    var mode: ComposerMode = .agent

    private let store: HomeStore
    private let settings: AppSettings

    init(store: HomeStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
        self.selectedModel = ModelOption.named(settings.defaultModelID) ?? .default
        self.thinkingLevel = settings.defaultThinkingLevel
        self.selectedProject = Self.defaultProject(store: store)
    }

    /// Picks the most recently used project, falling back to the first project.
    static func defaultProject(store: HomeStore) -> Project? {
        if let firstRecentID = store.recentProjectIDs.first,
           let match = store.projects.first(where: { $0.id == firstRecentID }) {
            return match
        }
        return store.projects.first
    }

    /// Ensures a project is selected once projects have loaded.
    func syncDefaultProjectIfNeeded() {
        if selectedProject == nil {
            selectedProject = Self.defaultProject(store: store)
        }
    }

    func selectProject(_ project: Project) {
        selectedProject = project
        branch = "main"
        store.markProjectUsed(project)
    }

    func selectModel(_ model: ModelOption) {
        selectedModel = model
        settings.defaultModelID = model.modelID
    }

    func selectThinkingLevel(_ level: ThinkingLevel) {
        thinkingLevel = level
        settings.defaultThinkingLevel = level
    }

    var canSend: Bool {
        selectedProject != nil && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Builds a request from the current state, or nil if not sendable.
    func makeRequest() -> NewSessionRequest? {
        guard let project = selectedProject else { return nil }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let cleanedBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        return NewSessionRequest(
            project: project,
            branch: cleanedBranch.isEmpty ? nil : cleanedBranch,
            prompt: trimmed,
            model: selectedModel,
            mode: mode,
            thinkingLevel: thinkingLevel
        )
    }

    func reset() {
        prompt = ""
        mode = .agent
    }
}
