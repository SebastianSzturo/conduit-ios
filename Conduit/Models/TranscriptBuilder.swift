import Foundation

/// Normalizes raw `APIMessage` envelopes (Claude stream-json or Codex event
/// families) into renderable `TranscriptItem`s. Pure and stateless per call;
/// safe to re-run over the full message list on every poll.
nonisolated enum TranscriptBuilder {

    static func build(messages: [APIMessage]) -> [TranscriptItem] {
        var acc = Accumulator()
        for message in messages {
            switch message.type {
            case "userMessage":
                acc.appendUserPrompt(message)
            case "agent":
                acc.appendAgent(message)
            default:
                // Unknown envelope type — emit a defensive marker, never crash.
                acc.append(
                    TranscriptItem(
                        id: message.id,
                        kind: .unknown(typeName: message.type),
                        date: message.receivedAtDate
                    )
                )
            }
        }
        return acc.items
    }

    // MARK: - Accumulator

    /// Collects items while preserving first-appearance order and allowing
    /// in-place updates keyed by a stable id (tool_use call id / Codex item id).
    private struct Accumulator {
        private(set) var items: [TranscriptItem] = []
        /// id -> index in `items`, for in-place updates.
        private var indexByID: [String: Int] = [:]
        /// Claude emits a system/init event on every turn; only the first one
        /// should surface as a "Session started" marker.
        var didEmitSessionStart = false

        mutating func append(_ item: TranscriptItem) {
            indexByID[item.id] = items.count
            items.append(item)
        }

        /// Upserts by id: updates the existing item in place, else appends.
        mutating func upsert(_ item: TranscriptItem) {
            if let idx = indexByID[item.id] {
                items[idx] = item
            } else {
                append(item)
            }
        }

        func item(id: String) -> TranscriptItem? {
            indexByID[id].map { items[$0] }
        }

        mutating func mutate(id: String, _ body: (inout TranscriptItem) -> Void) {
            guard let idx = indexByID[id] else { return }
            body(&items[idx])
        }

        // MARK: userMessage envelope

        mutating func appendUserPrompt(_ message: APIMessage) {
            let content = message.content
            let text = Self.stripAttachments(content["message"]?.stringValue ?? "")
            let modelID = content["config"]?["model"]?.stringValue
            let modelName = ModelOption.displayName(for: modelID)
            let state = content["state"]?.stringValue ?? "sent"
            // Stable id from the message content id if present, else envelope id.
            let id = content["id"]?.stringValue ?? message.id
            append(
                TranscriptItem(
                    id: id,
                    kind: .userPrompt(text: text, modelName: modelName, queued: state == "queued"),
                    date: message.receivedAtDate
                )
            )
        }

        // MARK: agent envelope dispatch

        mutating func appendAgent(_ message: APIMessage) {
            let raw = message.content["rawPayload"]
            guard let raw else {
                append(TranscriptItem(id: message.id, kind: .unknown(typeName: "agent"), date: message.receivedAtDate))
                return
            }
            // Codex family: rawPayload.event.type present.
            if let event = raw["event"], event["type"] != nil {
                appendCodex(event: event, message: message)
                return
            }
            // Claude family: rawPayload.type present.
            appendClaude(raw: raw, message: message)
        }

        // MARK: - Claude (stream-json)

        mutating func appendClaude(raw: JSONValue, message: APIMessage) {
            let date = message.receivedAtDate
            let type = raw["type"]?.stringValue
            let subtype = raw["subtype"]?.stringValue

            switch type {
            case "system":
                switch subtype {
                case "init":
                    if !didEmitSessionStart {
                        didEmitSessionStart = true
                        append(TranscriptItem(id: message.id, kind: .info("Session started"), date: date))
                    }
                case "thinking_tokens":
                    // Progress ticks — do not render.
                    break
                default:
                    break
                }
            case "assistant":
                appendClaudeAssistant(raw: raw, message: message)
            case "user":
                appendClaudeUser(raw: raw)
            case "rate_limit_event":
                // Ignore; UI can surface a subtle notice elsewhere.
                break
            case "result":
                if let marker = Self.claudeResultMarker(raw) {
                    append(TranscriptItem(id: message.id, kind: .turnMarker(marker), date: date))
                }
            default:
                append(TranscriptItem(id: message.id, kind: .unknown(typeName: type ?? "system"), date: date))
            }
        }

        mutating func appendClaudeAssistant(raw: JSONValue, message: APIMessage) {
            let date = message.receivedAtDate
            // Key text/thinking blocks by the envelope id, not the Claude message
            // id: one Claude message spans multiple stream events (thinking and
            // text blocks arrive separately, each restarting at block index 0),
            // so message-id keys collide and break SwiftUI diffing.
            let msgID = message.id
            guard let blocks = raw["message"]?["content"]?.arrayValue else { return }
            var blockIndex = 0
            for block in blocks {
                defer { blockIndex += 1 }
                let blockType = block["type"]?.stringValue
                switch blockType {
                case "text":
                    let text = block["text"]?.stringValue ?? ""
                    guard !text.isEmpty else { break }
                    append(TranscriptItem(
                        id: "\(msgID):text:\(blockIndex)",
                        kind: .assistantText(text),
                        date: date
                    ))
                case "thinking":
                    let text = block["thinking"]?.stringValue ?? ""
                    append(TranscriptItem(
                        id: "\(msgID):thinking:\(blockIndex)",
                        kind: .thinking(text: text, seconds: nil),
                        date: date
                    ))
                case "tool_use":
                    appendClaudeToolUse(block: block, date: date)
                default:
                    break
                }
            }
        }

        mutating func appendClaudeToolUse(block: JSONValue, date: Date?) {
            let callID = block["id"]?.stringValue ?? UUID().uuidString
            let name = block["name"]?.stringValue ?? "Tool"
            let input = block["input"] ?? .null

            switch name {
            case "TodoWrite":
                let todos = Self.parseTodos(input)
                upsert(TranscriptItem(id: callID, kind: .todoList(todos), date: date))
            case "Task":
                let title = input["description"]?.stringValue
                    ?? input["prompt"]?.stringValue
                    ?? "Subtask"
                upsert(TranscriptItem(id: callID, kind: .subtask(title: title, status: .working), date: date))
            default:
                let info = Self.claudeToolInfo(callID: callID, name: name, input: input)
                upsert(TranscriptItem(id: callID, kind: .toolUse(info), date: date))
            }
        }

        mutating func appendClaudeUser(raw: JSONValue) {
            guard let blocks = raw["message"]?["content"]?.arrayValue else { return }
            for block in blocks where block["type"]?.stringValue == "tool_result" {
                guard let callID = block["tool_use_id"]?.stringValue else { continue }
                let output = Self.flattenResultContent(block["content"])
                let isError = block["is_error"]?.boolValue ?? false
                // Attach result to matching tool_use / flip subtask to done.
                mutate(id: callID) { existing in
                    switch existing.kind {
                    case .toolUse(var info):
                        info.output = output
                        info.status = isError ? .failed : .done
                        existing.kind = .toolUse(info)
                    case .subtask(let title, _):
                        existing.kind = .subtask(title: title, status: isError ? .failed : .done)
                    default:
                        break
                    }
                }
            }
        }

        // MARK: - Codex

        mutating func appendCodex(event: JSONValue, message: APIMessage) {
            let date = message.receivedAtDate
            let eventType = event["type"]?.stringValue ?? ""

            switch eventType {
            case "item.started", "item.updated", "item.completed":
                guard let item = event["item"] else { break }
                appendCodexItem(item, date: date)
            case "thread.started", "turn.started":
                // Structural; no visible item.
                break
            case "turn.completed", "turn.failed":
                // Could carry usage/duration; nothing renderable observed.
                break
            default:
                append(TranscriptItem(id: message.id, kind: .unknown(typeName: eventType), date: date))
            }
        }

        mutating func appendCodexItem(_ item: JSONValue, date: Date?) {
            let itemType = item["type"]?.stringValue ?? ""
            let itemID = item["id"]?.stringValue ?? UUID().uuidString

            switch itemType {
            case "userMessage":
                // Echoed system prompt — skip entirely.
                break
            case "agentMessage":
                let text = item["text"]?.stringValue ?? ""
                guard !text.isEmpty else { break }
                upsert(TranscriptItem(id: itemID, kind: .assistantText(text), date: date))
            case "reasoning":
                let text = Self.codexReasoningText(item)
                upsert(TranscriptItem(id: itemID, kind: .thinking(text: text, seconds: nil), date: date))
            case "commandExecution":
                let info = Self.codexCommandInfo(itemID: itemID, item: item)
                upsert(TranscriptItem(id: itemID, kind: .toolUse(info), date: date))
            case "imageView":
                let path = item["path"]?.stringValue
                let info = TranscriptItem.ToolUseInfo(
                    callID: itemID, name: "imageView",
                    title: "Viewed image",
                    detail: path, status: .done, output: nil, category: .explored
                )
                upsert(TranscriptItem(id: itemID, kind: .toolUse(info), date: date))
            default:
                upsert(TranscriptItem(id: itemID, kind: .unknown(typeName: itemType), date: date))
            }
        }

        // MARK: - Helpers (static, pure)

        /// Strips `@⟦name⟧(path)` attachment tokens down to just `name`.
        static func stripAttachments(_ text: String) -> String {
            guard text.contains("⟦") else { return text }
            var result = ""
            let chars = Array(text)
            var i = 0
            while i < chars.count {
                if chars[i] == "@", i + 1 < chars.count, chars[i + 1] == "⟦" {
                    // Parse @⟦name⟧(path)
                    var j = i + 2
                    var name = ""
                    while j < chars.count, chars[j] != "⟧" {
                        name.append(chars[j]); j += 1
                    }
                    if j < chars.count { j += 1 } // skip ⟧
                    // Optional (path)
                    if j < chars.count, chars[j] == "(" {
                        var depth = 0
                        while j < chars.count {
                            if chars[j] == "(" { depth += 1 }
                            else if chars[j] == ")" { depth -= 1; if depth == 0 { j += 1; break } }
                            j += 1
                        }
                    }
                    result += name
                    i = j
                } else {
                    result.append(chars[i]); i += 1
                }
            }
            return result
        }

        static func parseTodos(_ input: JSONValue) -> [TranscriptItem.TodoEntry] {
            guard let list = input["todos"]?.arrayValue else { return [] }
            return list.compactMap { entry in
                guard let text = entry["content"]?.stringValue ?? entry["text"]?.stringValue else { return nil }
                let status = entry["status"]?.stringValue
                return TranscriptItem.TodoEntry(text: text, done: status == "completed")
            }
        }

        static func claudeToolInfo(callID: String, name: String, input: JSONValue) -> TranscriptItem.ToolUseInfo {
            let category = category(for: name)
            let title = toolTitle(name: name, input: input)
            let detail = toolDetail(name: name, input: input)
            return TranscriptItem.ToolUseInfo(
                callID: callID, name: name, title: title,
                detail: detail, status: .running, output: nil, category: category
            )
        }

        static func category(for name: String) -> TranscriptItem.ToolUseInfo.Category {
            switch name {
            case "Read", "Grep", "Glob", "WebFetch", "WebSearch": return .explored
            case "Edit", "Write", "NotebookEdit", "MultiEdit": return .edited
            case "Bash", "BashOutput": return .ran
            default: return .other
            }
        }

        static func toolTitle(name: String, input: JSONValue) -> String {
            switch name {
            case "Read", "Edit", "Write", "NotebookEdit":
                if let path = input["file_path"]?.stringValue ?? input["notebook_path"]?.stringValue {
                    return "\(name) \((path as NSString).lastPathComponent)"
                }
                return name
            case "Bash":
                if let desc = input["description"]?.stringValue, !desc.isEmpty { return desc }
                if let cmd = input["command"]?.stringValue { return firstLine(cmd) }
                return "Bash"
            case "Grep":
                if let pattern = input["pattern"]?.stringValue { return "Grep \(pattern)" }
                return "Grep"
            case "Glob":
                if let pattern = input["pattern"]?.stringValue { return "Glob \(pattern)" }
                return "Glob"
            case "WebFetch":
                if let url = input["url"]?.stringValue { return "Fetch \(url)" }
                return "WebFetch"
            case "WebSearch":
                if let q = input["query"]?.stringValue { return "Search \(q)" }
                return "WebSearch"
            default:
                if let desc = input["description"]?.stringValue, !desc.isEmpty { return desc }
                return name
            }
        }

        static func toolDetail(name: String, input: JSONValue) -> String? {
            switch name {
            case "Bash": return input["command"]?.stringValue
            case "Read", "Edit", "Write", "NotebookEdit":
                return input["file_path"]?.stringValue ?? input["notebook_path"]?.stringValue
            default:
                return nil
            }
        }

        static func firstLine(_ s: String) -> String {
            s.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? s
        }

        /// tool_result content is a string or an array of `{type:"text", text}` blocks.
        static func flattenResultContent(_ value: JSONValue?) -> String? {
            guard let value else { return nil }
            switch value {
            case .string(let s): return s
            case .array(let blocks):
                let texts = blocks.compactMap { block -> String? in
                    block["text"]?.stringValue ?? block.stringValue
                }
                return texts.isEmpty ? nil : texts.joined(separator: "\n")
            default:
                return nil
            }
        }

        static func codexReasoningText(_ item: JSONValue) -> String {
            let parts = (item["summary"]?.arrayValue ?? []) + (item["content"]?.arrayValue ?? [])
            let texts = parts.compactMap { $0["text"]?.stringValue ?? $0.stringValue }
            return texts.joined(separator: "\n")
        }

        static func codexCommandInfo(itemID: String, item: JSONValue) -> TranscriptItem.ToolUseInfo {
            let actions = item["commandActions"]?.arrayValue ?? []
            let command = item["command"]?.stringValue ?? ""
            let title: String
            if let first = actions.first,
               let name = first["name"]?.stringValue, !name.isEmpty {
                title = name
            } else if let firstCmd = actions.first?["command"]?.stringValue, !firstCmd.isEmpty {
                title = firstLine(firstCmd)
            } else if !command.isEmpty {
                title = firstLine(command)
            } else {
                title = "commandExecution"
            }

            let statusStr = item["status"]?.stringValue
            let exitCode = item["exitCode"]?.numberValue
            let status: TranscriptItem.ToolUseInfo.Status
            switch statusStr {
            case "completed": status = (exitCode ?? 0) == 0 ? .done : .failed
            case "failed": status = .failed
            case "inProgress", "in_progress", "running": status = .running
            default: status = exitCode.map { $0 == 0 ? .done : .failed } ?? .running
            }

            let output = item["aggregatedOutput"]?.stringValue
            // Categorize by the first action type when available.
            let actionType = actions.first?["type"]?.stringValue
            let category: TranscriptItem.ToolUseInfo.Category
            switch actionType {
            case "read", "search": category = .explored
            case "edit", "write": category = .edited
            default: category = .ran
            }

            return TranscriptItem.ToolUseInfo(
                callID: itemID, name: "commandExecution", title: title,
                detail: command.isEmpty ? nil : command,
                status: status, output: output, category: category
            )
        }

        /// Builds a "Worked <duration>" marker from a Claude `result` payload if
        /// a duration field exists.
        static func claudeResultMarker(_ raw: JSONValue) -> String? {
            let ms = raw["duration_ms"]?.numberValue ?? raw["durationMs"]?.numberValue
            guard let ms, ms > 0 else { return nil }
            return "Worked \(formatDuration(seconds: Int(ms / 1000)))"
        }

        static func formatDuration(seconds: Int) -> String {
            if seconds < 60 { return "\(seconds)s" }
            let m = seconds / 60
            let s = seconds % 60
            if m < 60 { return s == 0 ? "\(m)m" : "\(m)m \(s)s" }
            let h = m / 60
            let rm = m % 60
            return rm == 0 ? "\(h)h" : "\(h)h \(rm)m"
        }
    }
}
