import Foundation

/// A display-level grouping of consecutive `TranscriptItem`s.
///
/// The raw `store.items` stream is flattened into these groups so that runs of
/// `toolUse` and `subtask` items collapse into single expandable cards, matching
/// the Cursor transcript (see frames 054 / 070 / 078).
enum TranscriptGroup: Identifiable {
    /// A run of one or more consecutive `toolUse` items.
    case toolGroup(id: String, tools: [TranscriptItem.ToolUseInfo])
    /// A run of one or more consecutive `subtask` items.
    case subtaskGroup(id: String, subtasks: [(id: String, title: String, status: TranscriptItem.SubtaskStatus)])
    /// Any other single item, rendered on its own.
    case single(TranscriptItem)

    var id: String {
        switch self {
        case .toolGroup(let id, _): "tools-\(id)"
        case .subtaskGroup(let id, _): "subs-\(id)"
        case .single(let item): "item-\(item.id)"
        }
    }

    /// Collapses a raw transcript stream into renderable groups.
    static func build(from items: [TranscriptItem]) -> [TranscriptGroup] {
        var groups: [TranscriptGroup] = []
        var index = 0
        while index < items.count {
            let item = items[index]
            switch item.kind {
            case .toolUse:
                var tools: [TranscriptItem.ToolUseInfo] = []
                let anchorID = item.id
                while index < items.count, case .toolUse(let info) = items[index].kind {
                    tools.append(info)
                    index += 1
                }
                groups.append(.toolGroup(id: anchorID, tools: tools))
            case .subtask:
                var subs: [(id: String, title: String, status: TranscriptItem.SubtaskStatus)] = []
                let anchorID = item.id
                while index < items.count, case .subtask(let title, let status) = items[index].kind {
                    subs.append((id: items[index].id, title: title, status: status))
                    index += 1
                }
                groups.append(.subtaskGroup(id: anchorID, subtasks: subs))
            default:
                groups.append(.single(item))
                index += 1
            }
        }
        return groups
    }
}

extension TranscriptItem.ToolUseInfo.Category {
    /// SF Symbol used for the tool row icon.
    var iconName: String {
        switch self {
        case .explored: "magnifyingglass"
        case .edited: "pencil"
        case .ran: "terminal"
        case .other: "wrench"
        }
    }

    /// Whether this category counts as a "file" tool in the grouped summary
    /// ("Explored 2 files, 1 other tool").
    var countsAsFile: Bool {
        self == .explored || self == .edited
    }
}

extension Array where Element == TranscriptItem.ToolUseInfo {
    /// Builds the gray summary label for a collapsed tool group, e.g.
    /// "Explored 2 files, 1 other tool".
    var summaryLabel: String {
        let fileTools = filter { $0.category.countsAsFile }
        let otherTools = filter { !$0.category.countsAsFile }

        // Leading verb: prefer the dominant file category, else the first tool's.
        let verb: String = {
            if let edited = first(where: { $0.category == .edited }) {
                return edited.category.rawValue
            }
            if let explored = first(where: { $0.category == .explored }) {
                return explored.category.rawValue
            }
            return first?.category.rawValue ?? "Used"
        }()

        var parts: [String] = []
        if !fileTools.isEmpty {
            parts.append("\(fileTools.count) file\(fileTools.count == 1 ? "" : "s")")
        }
        if !otherTools.isEmpty {
            parts.append("\(otherTools.count) other tool\(otherTools.count == 1 ? "" : "s")")
        }
        if parts.isEmpty { parts.append("\(count) tool\(count == 1 ? "" : "s")") }
        return "\(verb) \(parts.joined(separator: ", "))"
    }
}
