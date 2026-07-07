import Foundation

// MARK: - Core resources

nonisolated struct Project: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let gitRemote: String

    /// "owner/repo" derived from the git remote URL, falling back to `name`.
    var repoSlug: String {
        guard let url = URL(string: gitRemote) else { return name }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return name }
        let repo = parts[parts.count - 1].replacingOccurrences(of: ".git", with: "")
        return "\(parts[parts.count - 2])/\(repo)"
    }

    var owner: String? {
        let slug = repoSlug
        guard let slash = slug.firstIndex(of: "/") else { return nil }
        return String(slug[..<slash])
    }
}

nonisolated struct Workspace: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    /// Raw Postgres timestamp, e.g. "2026-07-06 07:33:24.77353+00".
    let createdAt: String
    let deepLink: String
    let creatorId: String?

    var createdAtDate: Date? { PostgresTimestamp.parse(createdAt) }
}

nonisolated struct Session: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let deepLink: String
    let name: String?
    let model: String?
}

// MARK: - Statuses

nonisolated enum WorkspaceStatusKind: String, Sendable {
    case initializing, ready, sleeping, archived, deleted, updating, unknown
}

nonisolated enum WorkspaceLifecycleStep: String, Sendable {
    case buildingSnapshot = "building_snapshot"
    case preparing
    case settingUp = "setting_up"
    case updating

    var label: String {
        switch self {
        case .buildingSnapshot: "Building snapshot"
        case .preparing: "Preparing"
        case .settingUp: "Setting up"
        case .updating: "Updating"
        }
    }
}

nonisolated struct WorkspaceStatus: Codable, Hashable, Sendable {
    let workspaceId: String
    let status: String
    let lifecycleStep: String?
    let updatedAt: String
    let errorMessage: String?

    var kind: WorkspaceStatusKind { WorkspaceStatusKind(rawValue: status) ?? .unknown }
    var step: WorkspaceLifecycleStep? { lifecycleStep.flatMap(WorkspaceLifecycleStep.init(rawValue:)) }
}

nonisolated enum SessionStatusKind: String, Sendable {
    case idle, working, error, unknown
}

nonisolated struct SessionStatus: Codable, Hashable, Sendable {
    let workspaceId: String
    let sessionId: String
    let status: String
    let updatedAt: String
    let errorMessage: String?

    var kind: SessionStatusKind { SessionStatusKind(rawValue: status) ?? .unknown }
}

// MARK: - Requests / responses

nonisolated struct Page<T: Codable & Sendable>: Codable, Sendable {
    let data: [T]
    let offset: Int
    let hasMore: Bool
}

nonisolated struct WorkspaceCreateResponse: Codable, Sendable {
    let workspaceId: String
    let sessionId: String
    let deepLink: String
}

nonisolated struct SendMessageResponse: Codable, Sendable {
    let messageId: String
    /// "queued" when the agent is busy, "sent" when delivered immediately.
    let state: String

    var isQueued: Bool { state == "queued" }
}

nonisolated struct CancelResponse: Codable, Sendable {
    let workspaceId: String
    let sessionId: String
    let status: String
    let canceledQueuedMessages: Int
}

/// Envelope for GET /sessions/{id}/messages items. `content` shape varies by agent.
nonisolated struct APIMessage: Codable, Identifiable, Sendable {
    let id: String
    let sessionId: String
    let sessionIndex: Int
    let type: String
    let content: JSONValue
    let receivedAt: String

    var receivedAtDate: Date? { PostgresTimestamp.parse(receivedAt) }
}

nonisolated struct StructuredError: Codable, Sendable, Error {
    let code: String?
    let userMessage: String
    let debugMessage: String?
    let retryable: Bool?
}

// MARK: - Agents & models

nonisolated enum AgentKind: String, Codable, CaseIterable, Sendable {
    case claude, codex, cursor, acp
}

/// Reasoning-effort setting, selectable separately from the model (mirrors
/// Conductor desktop's composer). NOTE: the v0 API does not yet accept a
/// thinking level on session/message creation — this is stored locally and
/// shown in the UI, ready to be wired once the API exposes it.
nonisolated enum ThinkingLevel: String, CaseIterable, Codable, Sendable {
    case low, medium, high, xhigh

    var displayName: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "Extra High"
        }
    }

    /// Bars shown in the desktop-style chip (1–4).
    var barCount: Int {
        switch self {
        case .low: 1
        case .medium: 2
        case .high: 3
        case .xhigh: 4
        }
    }

    static let `default` = ThinkingLevel.medium
}

/// Curated model options for the picker; `modelID` is sent as `model` on create.
nonisolated struct ModelOption: Identifiable, Hashable, Sendable {
    let displayName: String
    let effortTag: String?
    let agent: AgentKind
    let modelID: String

    var id: String { modelID }

    static let all: [ModelOption] = [
        ModelOption(displayName: "Fable 5", effortTag: "High", agent: .claude, modelID: "fable-5"),
        ModelOption(displayName: "Opus 4.8", effortTag: "High", agent: .claude, modelID: "opus-4-8"),
        ModelOption(displayName: "Opus 4.8 (1M)", effortTag: "High", agent: .claude, modelID: "opus-4-8-1m"),
        ModelOption(displayName: "Sonnet 5", effortTag: "Medium", agent: .claude, modelID: "sonnet-5"),
        ModelOption(displayName: "Haiku 4.5", effortTag: "Fast", agent: .claude, modelID: "haiku-4-5"),
        ModelOption(displayName: "GPT-5.5", effortTag: "Medium", agent: .codex, modelID: "gpt-5.5"),
        ModelOption(displayName: "Codex 5.3", effortTag: "Medium", agent: .codex, modelID: "codex-5.3"),
        ModelOption(displayName: "Composer 2.5", effortTag: "Fast", agent: .cursor, modelID: "composer-2.5"),
    ]

    /// GPT-5.5 is the app default.
    static let `default` = all.first { $0.modelID == "gpt-5.5" } ?? all[0]

    static func named(_ modelID: String?) -> ModelOption? {
        all.first { $0.modelID == modelID }
    }

    /// Display name for an arbitrary API model string (e.g. "opus-4-8-1m" from a session).
    static func displayName(for modelID: String?) -> String? {
        guard let modelID else { return nil }
        if let known = named(modelID) { return known.displayName }
        return modelID
            .split(separator: "-")
            .map { ($0.first.map(String.init)?.uppercased() ?? "") + $0.dropFirst() }
            .joined(separator: " ")
    }
}

// MARK: - Timestamp parsing

/// Parses Postgres-style timestamps like "2026-07-06 07:33:24.77353+00".
nonisolated enum PostgresTimestamp {
    static func parse(_ raw: String) -> Date? {
        var normalized = raw.replacingOccurrences(of: " ", with: "T")
        if normalized.hasSuffix("+00") {
            normalized = String(normalized.dropLast(3)) + "Z"
        }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: normalized) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: normalized)
    }
}
