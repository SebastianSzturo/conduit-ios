import Foundation

/// A normalized, renderable transcript entry, produced by `TranscriptBuilder`
/// from raw `APIMessage` payloads (Claude or Codex event families).
nonisolated struct TranscriptItem: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        /// A prompt sent by the user. `queued` when it is still waiting in the reply queue.
        case userPrompt(text: String, modelName: String?, queued: Bool)
        /// Assistant prose; markdown.
        case assistantText(String)
        /// Extended thinking. `text` may be empty (render as bare "Thought" row).
        case thinking(text: String, seconds: Int?)
        /// A tool invocation (Bash, Read, Edit, commandExecution, …).
        case toolUse(ToolUseInfo)
        /// A to-do checklist snapshot (Claude TodoWrite).
        case todoList([TodoEntry])
        /// A subagent / sub-task card (Claude Task tool).
        case subtask(title: String, status: SubtaskStatus)
        /// End-of-turn marker, e.g. "Worked 27m 34s".
        case turnMarker(String)
        /// Low-priority informational row (rate limits, session init).
        case info(String)
        /// Unrecognized payload; `typeName` is the raw event/item type.
        case unknown(typeName: String)
    }

    enum SubtaskStatus: String, Hashable, Sendable {
        case working = "Working"
        case done = "Done"
        case failed = "Failed"
    }

    struct ToolUseInfo: Hashable, Sendable {
        enum Status: Hashable, Sendable { case running, done, failed }
        /// Tool-call id used to attach results (tool_use_id / item id).
        let callID: String
        /// Tool name, e.g. "Bash", "Read", "commandExecution".
        let name: String
        /// One-line summary for the row, e.g. "Read harness-agent.ts".
        var title: String
        /// Full command / input detail shown when expanded.
        var detail: String?
        var status: Status
        /// Result output, attached when the matching tool_result arrives.
        var output: String?
        /// Category used for grouped summaries ("Explored", "Edited", "Ran").
        var category: Category

        enum Category: String, Hashable, Sendable {
            case explored = "Explored"
            case edited = "Edited"
            case ran = "Ran"
            case other = "Used"
        }
    }

    struct TodoEntry: Hashable, Sendable {
        let text: String
        let done: Bool
    }

    let id: String
    var kind: Kind
    var date: Date?
}
