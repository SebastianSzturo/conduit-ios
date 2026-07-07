import Foundation

/// In-memory API for SwiftUI previews and offline UI development.
final class MockConductorAPI: ConductorAPI {
    static let sampleProjects: [Project] = [
        Project(id: "p1", name: "mobile-app", gitRemote: "https://github.com/acme/mobile-app"),
        Project(id: "p2", name: "backend", gitRemote: "https://github.com/acme/backend"),
        Project(id: "p3", name: "design-system", gitRemote: "https://github.com/acme/design-system"),
    ]

    static let sampleWorkspaces: [Workspace] = [
        Workspace(id: "w1", name: "Improve onboarding", createdAt: "2026-07-07 05:30:00.1+00", deepLink: "conductor://workspace?id=w1", creatorId: nil),
        Workspace(id: "w2", name: "Fix empty states", createdAt: "2026-07-05 09:00:00.1+00", deepLink: "conductor://workspace?id=w2", creatorId: nil),
    ]

    static let sampleSessions: [Session] = [
        Session(id: "s1", deepLink: "conductor://workspace?id=w1&session=s1", name: "Improve onboarding", model: "fable-5"),
        Session(id: "s2", deepLink: "conductor://workspace?id=w2&session=s2", name: "Fix empty states", model: "gpt-5.5"),
    ]

    static let sampleTranscript: [TranscriptItem] = [
        TranscriptItem(id: "t1", kind: .userPrompt(text: "Let's improve the first-run onboarding flow and keep the change narrow.", modelName: "Fable 5", queued: false), date: .now),
        TranscriptItem(id: "t2", kind: .thinking(text: "The empty state behavior is already visible in previews, so I will verify it at a phone viewport.", seconds: 13), date: .now),
        TranscriptItem(id: "t3", kind: .assistantText("The onboarding list renders correctly: full-width, clear primary action, and no wasted detail pane."), date: .now),
        TranscriptItem(id: "t4", kind: .toolUse(TranscriptItem.ToolUseInfo(callID: "c1", name: "Bash", title: "Check dev server", detail: "curl -s localhost:3000", status: .done, output: "200 OK", category: .ran)), date: .now),
        TranscriptItem(id: "t5", kind: .subtask(title: "Set up mobile preview", status: .working), date: .now),
        TranscriptItem(id: "t6", kind: .todoList([
            TranscriptItem.TodoEntry(text: "Review current empty states", done: true),
            TranscriptItem.TodoEntry(text: "Draft focused onboarding changes", done: true),
            TranscriptItem.TodoEntry(text: "Verify the phone layout", done: false),
        ]), date: .now),
        TranscriptItem(id: "t7", kind: .turnMarker("Worked 27m 34s"), date: .now),
    ]

    func projects() async throws -> [Project] { Self.sampleProjects }

    func workspaces(projectID: String) async throws -> [Workspace] { Self.sampleWorkspaces }

    func workspace(workspaceID: String) async throws -> Workspace { Self.sampleWorkspaces[0] }

    func createWorkspace(projectID: String, name: String?, branch: String?, agent: AgentKind?, model: String?) async throws -> WorkspaceCreateResponse {
        WorkspaceCreateResponse(workspaceId: "w-new", sessionId: "s-new", deepLink: "conductor://workspace?id=w-new")
    }

    func renameWorkspace(workspaceID: String, name: String) async throws -> Workspace { Self.sampleWorkspaces[0] }

    func archiveWorkspace(workspaceID: String) async throws {}

    func workspaceStatus(workspaceID: String) async throws -> WorkspaceStatus {
        WorkspaceStatus(workspaceId: workspaceID, status: "ready", lifecycleStep: nil, updatedAt: "2026-07-07 05:30:00.1+00", errorMessage: nil)
    }

    func sessions(workspaceID: String) async throws -> [Session] { Self.sampleSessions }

    func session(sessionID: String) async throws -> Session { Self.sampleSessions[0] }

    func createSession(workspaceID: String, name: String?, agent: AgentKind, model: String?) async throws -> Session {
        Self.sampleSessions[0]
    }

    func renameSession(sessionID: String, name: String) async throws -> Session { Self.sampleSessions[0] }

    func sessionStatus(sessionID: String) async throws -> SessionStatus {
        SessionStatus(workspaceId: "w1", sessionId: sessionID, status: "working", updatedAt: "2026-07-07 05:30:00.1+00", errorMessage: nil)
    }

    func cancelSession(sessionID: String) async throws -> CancelResponse {
        CancelResponse(workspaceId: "w1", sessionId: sessionID, status: "idle", canceledQueuedMessages: 0)
    }

    func messages(sessionID: String, offset: Int, limit: Int) async throws -> Page<APIMessage> {
        Page(data: [], offset: offset, hasMore: false)
    }

    func sendMessage(sessionID: String, text: String, clientMessageID: String) async throws -> SendMessageResponse {
        SendMessageResponse(messageId: clientMessageID, state: "sent")
    }
}
