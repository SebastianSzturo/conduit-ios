import Foundation

/// Abstraction over the Conductor v0 REST API. Implemented by `ConductorClient`
/// (live) and `MockConductorAPI` (previews).
protocol ConductorAPI: Sendable {
    // Identity
    /// Validates a draft credential without changing the key used by other requests.
    func identity(apiKey: String) async throws -> Identity
    func modelCapabilities() async throws -> ModelCapabilitiesResponse

    // Projects
    func projects() async throws -> [Project]

    // Workspaces
    /// Fetches all pages of a project's workspaces (newest first).
    func workspaces(projectID: String) async throws -> [Workspace]
    func workspace(workspaceID: String) async throws -> Workspace
    func createWorkspace(
        projectID: String, name: String?, sessionName: String?, branch: String?,
        agent: AgentKind?, model: String?
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
    /// Fetches a page of messages in ascending `sessionIndex` order. Pass the id
    /// of the last message already held as `after` to fetch only unseen messages
    /// (exclusive); `after == nil` starts from the beginning of the transcript.
    /// An id cursor resumes a cached transcript robustly — unlike a count-based
    /// offset, it cannot drift if the backing list changes.
    func messages(sessionID: String, after: String?, limit: Int) async throws -> Page<APIMessage>
    func sendMessage(sessionID: String, text: String, clientMessageID: String) async throws -> SendMessageResponse
}

enum APIError: Error, LocalizedError {
    case http(status: Int, structured: StructuredError?, diagnostics: APIDiagnostics)
    case invalidResponse
    case missingAPIKey

    var errorDescription: String? {
        switch self {
        case .http(let status, let structured, let diagnostics):
            // Prefer the server's structured, user-facing message; otherwise fall
            // back to a friendly hint keyed on the status code.
            let message = structured?.userMessage ?? Self.friendlyMessage(for: status)
            var details: [String] = []
            if let retryAfter = diagnostics.retryAfter {
                details.append("Retry after \(retryAfter.formatted(date: .omitted, time: .shortened)).")
            }
            if let requestID = diagnostics.requestID {
                details.append("Request ID: \(requestID)")
            }
            return ([message] + details).joined(separator: " ")
        case .invalidResponse:
            return "The server returned a response the app couldn't read. Please try again."
        case .missingAPIKey:
            return "No API key configured"
        }
    }

    var diagnostics: APIDiagnostics? {
        guard case .http(_, _, let diagnostics) = self else { return nil }
        return diagnostics
    }

    var isRetryable: Bool {
        guard case .http(let status, let structured, _) = self else { return true }
        return structured?.retryable ?? (status == 408 || status == 429 || status >= 500)
    }

    /// Human-friendly fallback for common HTTP statuses when the server didn't
    /// send a structured `userMessage`. The raw code stays visible for support.
    private static func friendlyMessage(for status: Int) -> String {
        let hint: String
        switch status {
        case 401, 403:
            hint = "Your API key may be invalid or unauthorized — check it in Settings."
        case 404:
            hint = "That resource wasn't found — it may have been deleted or archived."
        case 429:
            hint = "You're being rate limited — wait a moment and try again."
        case 500...599:
            hint = "The server ran into a problem — please try again shortly."
        default:
            hint = "Request failed."
        }
        return "\(hint) (\(status))"
    }
}
