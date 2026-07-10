import Foundation

/// Live `ConductorAPI` implementation over the Conductor v0 REST API using
/// URLSession async/await.
final class ConductorClient: ConductorAPI {
    private let baseURL: URL
    private let apiKeyProvider: () -> String
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// - Parameters:
    ///   - baseURL: API base, e.g. `https://api.conductor.build/v0`.
    ///   - apiKeyProvider: Called per request so the key can rotate at runtime.
    init(baseURL: URL, apiKeyProvider: @escaping () -> String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKeyProvider = apiKeyProvider
        self.session = session
    }

    // MARK: - Identity

    func identity(apiKey: String) async throws -> Identity {
        let request = try makeRequest(url: url(path: "/me"), method: "GET", apiKey: apiKey)
        return try await perform(request)
    }

    func modelCapabilities() async throws -> ModelCapabilitiesResponse {
        try await get(path: "/models/capabilities")
    }

    // MARK: - Projects

    func projects() async throws -> [Project] {
        try await allPages(path: "/projects")
    }

    // MARK: - Workspaces

    func workspaces(projectID: String) async throws -> [Workspace] {
        try await allPages(path: "/projects/\(esc(projectID))/workspaces")
    }

    func workspace(workspaceID: String) async throws -> Workspace {
        try await get(path: "/workspaces/\(esc(workspaceID))")
    }

    func createWorkspace(
        projectID: String, name: String?, sessionName: String?, branch: String?,
        agent: AgentKind?, model: String?
    ) async throws -> WorkspaceCreateResponse {
        let body = CreateWorkspaceBody(
            projectId: projectID, branch: branch, name: name, sessionName: sessionName,
            agent: agent?.rawValue, model: model
        )
        return try await post(path: "/workspaces", body: body)
    }

    func renameWorkspace(workspaceID: String, name: String) async throws -> Workspace {
        try await post(path: "/workspaces/\(esc(workspaceID))/rename", body: RenameBody(name: name))
    }

    func archiveWorkspace(workspaceID: String) async throws {
        let _: EmptyResponse = try await post(path: "/workspaces/\(esc(workspaceID))/archive", body: EmptyBody())
    }

    func workspaceStatus(workspaceID: String) async throws -> WorkspaceStatus {
        try await get(path: "/workspaces/\(esc(workspaceID))/status")
    }

    // MARK: - Sessions

    func sessions(workspaceID: String) async throws -> [Session] {
        try await allPages(path: "/workspaces/\(esc(workspaceID))/sessions")
    }

    func session(sessionID: String) async throws -> Session {
        try await get(path: "/sessions/\(esc(sessionID))")
    }

    func createSession(
        workspaceID: String, name: String?, agent: AgentKind, model: String?
    ) async throws -> Session {
        let body = CreateSessionBody(workspaceId: workspaceID, name: name, agent: agent.rawValue, model: model)
        return try await post(path: "/sessions", body: body)
    }

    func renameSession(sessionID: String, name: String) async throws -> Session {
        try await post(path: "/sessions/\(esc(sessionID))/rename", body: RenameBody(name: name))
    }

    func sessionStatus(sessionID: String) async throws -> SessionStatus {
        try await get(path: "/sessions/\(esc(sessionID))/status")
    }

    func cancelSession(sessionID: String) async throws -> CancelResponse {
        try await post(path: "/sessions/\(esc(sessionID))/cancel", body: EmptyBody())
    }

    // MARK: - Messages

    func messages(sessionID: String, after: String?, limit: Int) async throws -> Page<APIMessage> {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        // The API forbids combining `after` with `offset`: send `after` when we
        // have a cursor, otherwise fall back to `offset=0` to read from the start.
        if let after {
            query.append(URLQueryItem(name: "after", value: after))
        } else {
            query.append(URLQueryItem(name: "offset", value: "0"))
        }
        return try await get(path: "/sessions/\(esc(sessionID))/messages", query: query)
    }

    func sendMessage(sessionID: String, text: String, clientMessageID: String) async throws -> SendMessageResponse {
        let body = SendMessageBody(message: text, messageId: clientMessageID)
        return try await post(path: "/sessions/\(esc(sessionID))/messages", body: body)
    }

    // MARK: - Request plumbing

    private func esc(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? component
    }

    private func url(path: String, query: [URLQueryItem] = []) -> URL {
        var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { comps?.queryItems = query }
        return comps?.url ?? baseURL.appendingPathComponent(path)
    }

    private func makeRequest(url: URL, method: String, apiKey: String? = nil) throws -> URLRequest {
        let key = apiKey ?? apiKeyProvider()
        guard !key.isEmpty else { throw APIError.missingAPIKey }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func get<T: Decodable>(path: String, query: [URLQueryItem] = []) async throws -> T {
        let request = try makeRequest(url: url(path: path, query: query), method: "GET")
        return try await perform(request)
    }

    private func getPage<T: Codable & Sendable>(path: String, limit: Int, offset: Int) async throws -> Page<T> {
        let query = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
        ]
        return try await get(path: path, query: query)
    }

    private func allPages<T: Codable & Sendable>(path: String, limit: Int = 100) async throws -> [T] {
        var all: [T] = []
        var offset = 0
        while true {
            let page: Page<T> = try await getPage(path: path, limit: limit, offset: offset)
            all.append(contentsOf: page.data)
            guard page.hasMore, !page.data.isEmpty else { return all }
            offset += page.data.count
        }
    }

    private func post<Body: Encodable, T: Decodable>(path: String, body: Body) async throws -> T {
        var request = try makeRequest(url: url(path: path), method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        return try await perform(request)
    }

    private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let structured = try? decoder.decode(StructuredError.self, from: data)
            throw APIError.http(
                status: http.statusCode,
                structured: structured,
                diagnostics: APIDiagnostics(
                    requestID: http.value(forHTTPHeaderField: "x-request-id")
                        ?? http.value(forHTTPHeaderField: "x-conductor-request-id"),
                    retryAfter: Self.retryAfterDate(http.value(forHTTPHeaderField: "retry-after"))
                )
            )
        }
        if T.self == EmptyResponse.self {
            return EmptyResponse() as! T
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.invalidResponse
        }
    }

    private static func retryAfterDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        if let seconds = TimeInterval(value) { return Date().addingTimeInterval(seconds) }
        return HTTPDateFormatter.shared.date(from: value)
    }

    // MARK: - Bodies

    private struct CreateWorkspaceBody: Encodable {
        let projectId: String
        let branch: String?
        let name: String?
        let sessionName: String?
        let agent: String?
        let model: String?
        // Optionals with nil values are omitted by default (encodeIfPresent semantics).
    }

    private struct CreateSessionBody: Encodable {
        let workspaceId: String
        let name: String?
        let agent: String
        let model: String?
    }

    private struct SendMessageBody: Encodable {
        let message: String
        let messageId: String
    }

    private struct RenameBody: Encodable { let name: String }
    private struct EmptyBody: Encodable {}
    private struct EmptyResponse: Decodable {}
}

private final class HTTPDateFormatter: @unchecked Sendable {
    static let shared: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter
    }()
}
