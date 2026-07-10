import Foundation

/// Composer mode chosen in the context sheet. Maps to how the prompt is
/// submitted (agent = normal, plan = plan-first, draft = scratch/no-run).
nonisolated enum ComposerMode: String, CaseIterable, Hashable, Sendable {
    case agent, plan, draft

    var label: String {
        switch self {
        case .agent: "Agent"
        case .plan: "Plan"
        case .draft: "Draft"
        }
    }
}

/// The payload the composer hands to the integrator when the user hits send.
/// The integrator is responsible for POST /workspaces + posting the initial
/// prompt and navigating to the session view.
nonisolated struct NewSessionRequest: Hashable {
    let project: Project
    let branch: String?
    let prompt: String
    let model: ModelOption
    let mode: ComposerMode
}
