import Foundation

/// Abstraction over the Conductor v0 REST API. Implemented by `ConductorClient`
/// (live) and `MockConductorAPI` (previews).
protocol ConductorAPI: Sendable {
    // Projects
    func projects() async throws -> [Project]

    // Workspaces
    /// Fetches all pages of a project's workspaces (newest first).
    func workspaces(projectID: String) async throws -> [Workspace]
    func workspace(workspaceID: String) async throws -> Workspace
    func createWorkspace(
        projectID: String, name: String?, branch: String?, agent: AgentKind?, model: String?
    ) async throws -> WorkspaceCreateResponse
    func renameWorkspace(workspaceID: String, name: String) async throws -> Workspace
    func archiveWorkspace(workspaceID: String) async throws
    func workspaceStatus(workspaceID: String) async throws -> WorkspaceStatus

    // Sessions
    func sessions(workspaceID: String) async throws -> [Session]
    func session(sessionID: String) async throws -> Session
    func createSession(
        workspaceID: String, name: String?, agent: AgentKind, model: String?
    ) async throws -> Session
    func renameSession(sessionID: String, name: String) async throws -> Session
    func sessionStatus(sessionID: String) async throws -> SessionStatus
    func cancelSession(sessionID: String) async throws -> CancelResponse

    // Messages
    func messages(sessionID: String, offset: Int, limit: Int) async throws -> Page<APIMessage>
    func sendMessage(sessionID: String, text: String, clientMessageID: String) async throws -> SendMessageResponse
}

enum APIError: Error, LocalizedError {
    case http(status: Int, structured: StructuredError?)
    case invalidResponse
    case missingAPIKey

    var errorDescription: String? {
        switch self {
        case .http(let status, let structured):
            structured?.userMessage ?? "Request failed (\(status))"
        case .invalidResponse:
            "Invalid response from server"
        case .missingAPIKey:
            "No API key configured"
        }
    }
}
