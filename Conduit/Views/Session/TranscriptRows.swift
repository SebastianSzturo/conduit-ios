import SwiftUI
import UIKit

// MARK: - User prompt bubble

struct UserPromptBubble: View {
    let text: String
    let queued: Bool
    var failed = false
    var onRetry: (() -> Void)?

    private static let collapseThreshold = 280
    @State private var expanded = false

    private var isLong: Bool { text.count > Self.collapseThreshold }

    var body: some View {
        HStack {
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: 6) {
                Text(text)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(isLong && !expanded ? 6 : nil)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .contextMenu {
                        Button {
                            UIPasteboard.general.string = text
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                    }
                    .accessibilityAction(named: "Copy") {
                        UIPasteboard.general.string = text
                    }

                if isLong {
                    Button(expanded ? "Show less" : "Show more") {
                        withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .buttonStyle(.plain)
                }

                if queued {
                    Text("Queued")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.trailing, 4)
                }
                if failed {
                    HStack(spacing: 8) {
                        Label("Failed to send", systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(Theme.error)
                        if let onRetry {
                            Button("Retry", action: onRetry)
                                .fontWeight(.semibold)
                                .buttonStyle(.plain)
                        }
                    }
                    .font(.system(size: 12))
                    .padding(.trailing, 4)
                }
            }
            .frame(maxWidth: 300, alignment: .trailing)
        }
        .opacity(queued ? 0.5 : 1)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Assistant text

struct AssistantTextRow: View {
    let text: String

    var body: some View {
        MarkdownText(text)
            .font(.system(size: 16))
            .foregroundStyle(Theme.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Pragmatic block-level markdown renderer with no external deps. The raw text is
/// split into blocks (headings, fenced code, lists, blockquotes, paragraphs) and
/// each is rendered natively. Inline emphasis (`code`, **bold**, *italic*) is
/// handled per-line via `AttributedString(markdown:)`, with inline code remapped
/// to a monospaced font. Defensive: unterminated fences render to end; never crashes.
struct MarkdownText: View {
    let raw: String

    init(_ raw: String) { self.raw = raw }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MarkdownBlockCache.shared.blocks(for: raw).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            SelectableText(
                Self.inlineAttributed(text),
                font: .systemFont(ofSize: Self.headingSize(level), weight: .bold),
                color: UIColor(Theme.textPrimary)
            )
                .padding(.top, 2)

        case .paragraph(let text):
            SelectableText(
                Self.inlineAttributed(text),
                font: .systemFont(ofSize: 16),
                color: UIColor(Theme.textPrimary)
            )

        case .codeBlock(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                SelectableText(
                    AttributedString(code),
                    font: .monospacedSystemFont(ofSize: 14, weight: .regular),
                    color: UIColor(Theme.textPrimary),
                    usesIntrinsicWidth: true
                )
                    .padding(12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))

        case .unorderedList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                            .foregroundStyle(Theme.textSecondary)
                        SelectableText(
                            Self.inlineAttributed(item.text),
                            font: .systemFont(ofSize: 16),
                            color: UIColor(Theme.textPrimary)
                        )
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.leading, CGFloat(item.depth) * 16)
                }
            }

        case .orderedList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(item.number).")
                            .foregroundStyle(Theme.textSecondary)
                            .monospacedDigit()
                        SelectableText(
                            Self.inlineAttributed(item.text),
                            font: .systemFont(ofSize: 16),
                            color: UIColor(Theme.textPrimary)
                        )
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

        case .blockquote(let text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.separator)
                    .frame(width: 3)
                SelectableText(
                    Self.inlineAttributed(text),
                    font: .systemFont(ofSize: 16),
                    color: UIColor(Theme.textSecondary)
                )
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private static func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 22
        case 2: return 20
        case 3: return 18
        case 4: return 17
        default: return 16
        }
    }

    /// Inline-only markdown → AttributedString, with inline code in mono font.
    /// Memoized: body re-evaluations (e.g. keyboard-avoidance layout passes)
    /// reuse the cached result instead of re-parsing every visible line.
    static func inlineAttributed(_ string: String) -> AttributedString {
        MarkdownBlockCache.shared.inlineAttributed(string, compute: computeInlineAttributed)
    }

    private static func computeInlineAttributed(_ string: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        guard var attributed = try? AttributedString(markdown: string, options: options) else {
            return AttributedString(string)
        }
        for run in attributed.runs where run.inlinePresentationIntent == .code {
            attributed[run.range].font = .system(size: 15, design: .monospaced)
        }
        return attributed
    }
}

/// UIKit-backed read-only text gives iOS the same granular selection handles as
/// Safari and Notes. SwiftUI's `.textSelection(.enabled)` selects an entire
/// `Text` view at once, which only surfaces the Copy/Share menu for our
/// block-based markdown renderer.
private struct SelectableText: UIViewRepresentable {
    let content: AttributedString
    let font: UIFont
    let color: UIColor
    let usesIntrinsicWidth: Bool

    init(
        _ content: AttributedString,
        font: UIFont,
        color: UIColor,
        usesIntrinsicWidth: Bool = false
    ) {
        self.content = content
        self.font = font
        self.color = color
        self.usesIntrinsicWidth = usesIntrinsicWidth
    }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        let attributed = uiKitAttributedText
        if !uiView.attributedText.isEqual(to: attributed) {
            uiView.attributedText = attributed
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UITextView,
        context: Context
    ) -> CGSize? {
        if usesIntrinsicWidth {
            let bounds = uiKitAttributedText.boundingRect(
                with: CGSize(
                    width: CGFloat.greatestFiniteMagnitude,
                    height: CGFloat.greatestFiniteMagnitude
                ),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            )
            return CGSize(width: ceil(bounds.width), height: ceil(bounds.height))
        }

        guard let width = proposal.width, width.isFinite else { return nil }
        let size = uiView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)
        )
        return CGSize(width: width, height: ceil(size.height))
    }

    private var uiKitAttributedText: NSAttributedString {
        let result = NSMutableAttributedString()
        for run in content.runs {
            let string = String(content[run.range].characters)
            var runFont = font
            if run.inlinePresentationIntent?.contains(.code) == true {
                runFont = .monospacedSystemFont(ofSize: max(12, font.pointSize - 1), weight: .regular)
            } else {
                var traits = font.fontDescriptor.symbolicTraits
                if run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
                    traits.insert(.traitBold)
                }
                if run.inlinePresentationIntent?.contains(.emphasized) == true {
                    traits.insert(.traitItalic)
                }
                if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) {
                    runFont = UIFont(descriptor: descriptor, size: font.pointSize)
                }
            }

            var attributes: [NSAttributedString.Key: Any] = [
                .font: runFont,
                .foregroundColor: color,
            ]
            if run.inlinePresentationIntent?.contains(.strikethrough) == true {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let link = run.link {
                attributes[.link] = link
            }
            result.append(NSAttributedString(string: string, attributes: attributes))
        }
        return result
    }
}

// MARK: - Markdown parse cache

/// Bounded memoization for markdown parsing so `MarkdownText.body` doesn't
/// re-run `MarkdownBlock.parse` (and per-line `AttributedString(markdown:)`)
/// for every visible row on every layout pass — e.g. the whole-transcript
/// re-layout triggered by keyboard avoidance when the follow-up field focuses.
nonisolated final class MarkdownBlockCache {
    static let shared = MarkdownBlockCache()

    private final class Box<T>: NSObject {
        let value: T
        init(_ value: T) { self.value = value }
    }

    private let blockCache = NSCache<NSString, Box<[MarkdownBlock]>>()
    private let inlineCache = NSCache<NSString, Box<AttributedString>>()

    private init() {
        blockCache.countLimit = 300
        inlineCache.countLimit = 2000
    }

    /// Parsed blocks for `raw`, computed once per unique string.
    func blocks(for raw: String) -> [MarkdownBlock] {
        let key = raw as NSString
        if let cached = blockCache.object(forKey: key) { return cached.value }
        let parsed = MarkdownBlock.parse(raw)
        blockCache.setObject(Box(parsed), forKey: key)
        return parsed
    }

    /// Memoized inline-markdown attributed string.
    func inlineAttributed(_ string: String, compute: (String) -> AttributedString) -> AttributedString {
        let key = string as NSString
        if let cached = inlineCache.object(forKey: key) { return cached.value }
        let value = compute(string)
        inlineCache.setObject(Box(value), forKey: key)
        return value
    }
}

// MARK: - Markdown block parsing

/// A pragmatic block model for `MarkdownText`. Line-based; no external deps.
enum MarkdownBlock {
    struct ListItem { var text: String; var depth: Int; var number: Int }

    case heading(level: Int, text: String)
    case paragraph(String)
    case codeBlock(String)
    case unorderedList([ListItem])
    case orderedList([ListItem])
    case blockquote(String)

    /// Splits raw markdown into ordered blocks.
    static func parse(_ raw: String) -> [MarkdownBlock] {
        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var paragraphBuffer: [String] = []

        func flushParagraph() {
            let joined = paragraphBuffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            paragraphBuffer.removeAll()
        }

        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block
            if trimmed.hasPrefix("```") {
                flushParagraph()
                var code: [String] = []
                i += 1
                while i < lines.count {
                    let inner = lines[i]
                    if inner.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        i += 1
                        break
                    }
                    code.append(inner)
                    i += 1
                }
                // Trim leading/trailing blank lines, keep interior verbatim.
                blocks.append(.codeBlock(trimCodeEdges(code)))
                continue
            }

            // Blank line ends a paragraph.
            if trimmed.isEmpty {
                flushParagraph()
                i += 1
                continue
            }

            // Heading
            if let heading = parseHeading(trimmed) {
                flushParagraph()
                blocks.append(heading)
                i += 1
                continue
            }

            // Blockquote (consecutive `>` lines).
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoteLines: [String] = []
                while i < lines.count {
                    let qt = lines[i].trimmingCharacters(in: .whitespaces)
                    guard qt.hasPrefix(">") else { break }
                    quoteLines.append(String(qt.dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.blockquote(quoteLines.joined(separator: "\n")))
                continue
            }

            // Unordered list (consecutive bullet lines).
            if isUnorderedBullet(trimmed) {
                flushParagraph()
                var items: [ListItem] = []
                while i < lines.count {
                    let raw = lines[i]
                    let rt = raw.trimmingCharacters(in: .whitespaces)
                    guard isUnorderedBullet(rt) else { break }
                    let depth = leadingSpaces(raw) >= 2 ? 1 : 0
                    let text = String(rt.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                    items.append(ListItem(text: text, depth: depth, number: 0))
                    i += 1
                }
                blocks.append(.unorderedList(items))
                continue
            }

            // Ordered list (consecutive "N. " lines).
            if let _ = parseOrderedPrefix(trimmed) {
                flushParagraph()
                var items: [ListItem] = []
                while i < lines.count {
                    let rt = lines[i].trimmingCharacters(in: .whitespaces)
                    guard let parsed = parseOrderedPrefix(rt) else { break }
                    items.append(ListItem(text: parsed.text, depth: 0, number: parsed.number))
                    i += 1
                }
                blocks.append(.orderedList(items))
                continue
            }

            // Default: accumulate into a paragraph.
            paragraphBuffer.append(line)
            i += 1
        }
        flushParagraph()
        return blocks
    }

    // MARK: Helpers

    private static func parseHeading(_ trimmed: String) -> MarkdownBlock? {
        guard trimmed.hasPrefix("#") else { return nil }
        var level = 0
        for ch in trimmed {
            if ch == "#" { level += 1 } else { break }
        }
        guard level >= 1, level <= 6 else { return nil }
        let rest = trimmed.dropFirst(level)
        // Require a space after the hashes (ATX). Otherwise treat as text.
        guard rest.first == " " else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        return .heading(level: level, text: text)
    }

    private static func isUnorderedBullet(_ trimmed: String) -> Bool {
        for marker in ["- ", "* ", "+ "] where trimmed.hasPrefix(marker) {
            return true
        }
        return false
    }

    private static func parseOrderedPrefix(_ trimmed: String) -> (number: Int, text: String)? {
        var digits = ""
        var idx = trimmed.startIndex
        while idx < trimmed.endIndex, trimmed[idx].isNumber {
            digits.append(trimmed[idx])
            idx = trimmed.index(after: idx)
        }
        guard !digits.isEmpty, idx < trimmed.endIndex, trimmed[idx] == "." else { return nil }
        let afterDot = trimmed.index(after: idx)
        guard afterDot < trimmed.endIndex, trimmed[afterDot] == " " else { return nil }
        let text = String(trimmed[trimmed.index(after: afterDot)...]).trimmingCharacters(in: .whitespaces)
        return (Int(digits) ?? 0, text)
    }

    private static func leadingSpaces(_ line: String) -> Int {
        var count = 0
        for ch in line {
            if ch == " " { count += 1 }
            else if ch == "\t" { count += 2 }
            else { break }
        }
        return count
    }

    private static func trimCodeEdges(_ lines: [String]) -> String {
        var slice = lines[...]
        while let first = slice.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            slice = slice.dropFirst()
        }
        while let last = slice.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            slice = slice.dropLast()
        }
        return slice.joined(separator: "\n")
    }
}

// MARK: - Thinking

struct ThinkingRow: View {
    let text: String
    let seconds: Int?

    @State private var expanded = false

    private var hasBody: Bool { !text.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                guard hasBody else { return }
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text("Thought")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textSecondary)
                    if let seconds {
                        Text("\(seconds)s")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    if hasBody {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(!hasBody)

            if expanded, hasBody {
                Text(text)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Tool group

struct ToolGroupRow: View {
    let tools: [TranscriptItem.ToolUseInfo]

    @State private var expanded = false

    /// A lone running tool renders inline with a spinner and no collapse chrome.
    private var isSingleRunning: Bool {
        tools.count == 1 && tools[0].status == .running
    }

    var body: some View {
        if isSingleRunning {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.mini)
                    .tint(Theme.textSecondary)
                Text(tools[0].title)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Running \(tools[0].title)")
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Text(tools.summaryLabel)
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.textSecondary)
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .buttonStyle(.plain)

                if expanded {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(tools.enumerated()), id: \.offset) { _, tool in
                            ToolDetailRow(tool: tool)
                        }
                    }
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A single expandable tool row inside a group: icon + title, tap reveals the
/// mono detail line and truncated output card.
struct ToolDetailRow: View {
    let tool: TranscriptItem.ToolUseInfo

    @State private var showBody = false

    private var hasBody: Bool { tool.detail != nil || tool.output != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                guard hasBody else { return }
                withAnimation(.easeInOut(duration: 0.2)) { showBody.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: tool.category.iconName)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 16)
                    Text(tool.title)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textPrimary.opacity(0.9))
                        .lineLimit(1)
                    if tool.status == .running {
                        ProgressView().controlSize(.mini).tint(Theme.textSecondary)
                    } else if tool.status == .failed {
                        Image(systemName: "exclamationmark.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.error)
                    }
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
            .disabled(!hasBody)

            if showBody {
                VStack(alignment: .leading, spacing: 6) {
                    if let detail = tool.detail {
                        Text(detail)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    if let output = tool.output, !output.isEmpty {
                        Text(output)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
                    }
                }
                .padding(.leading, 26)
                .transition(.opacity)
            }
        }
    }
}

// MARK: - To-do list

struct TodoListCard: View {
    let entries: [TranscriptItem.TodoEntry]

    private var doneCount: Int { entries.filter(\.done).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("To-dos \(doneCount)/\(entries.count)")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.textSecondary)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: entry.done ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 15))
                            .foregroundStyle(entry.done ? Theme.textSecondary : Theme.textTertiary)
                        Text(entry.text)
                            .font(.system(size: 15))
                            .foregroundStyle(entry.done ? Theme.textSecondary : Theme.textPrimary)
                            .strikethrough(entry.done, color: Theme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themedCard()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Subtask card stack

struct SubtaskGroupCard: View {
    let subtasks: [(id: String, title: String, status: TranscriptItem.SubtaskStatus)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if subtasks.count > 1 {
                Text("Subagents \(subtasks.count)")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            VStack(alignment: .leading, spacing: 14) {
                ForEach(subtasks, id: \.id) { sub in
                    HStack(alignment: .top, spacing: 12) {
                        Group {
                            if sub.status == .working {
                                WorkingIndicator()
                            } else {
                                Circle()
                                    .fill(sub.status == .failed ? Theme.error : Theme.textTertiary)
                                    .frame(width: 10, height: 10)
                                    .padding(.top, 3)
                            }
                        }
                        .frame(width: 16, alignment: .center)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(sub.title)
                                .font(.system(size: 15))
                                .foregroundStyle(Theme.textPrimary)
                            Text(sub.status.rawValue)
                                .font(.system(size: 13))
                                .foregroundStyle(sub.status == .failed ? Theme.error : Theme.textSecondary)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themedCard()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Small marker rows

struct TurnMarkerRow: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 14))
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct InfoRow: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(Theme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

struct UnknownRow: View {
    let typeName: String
    var body: some View {
        Text("· \(typeName)")
            .font(.system(size: 13))
            .foregroundStyle(Theme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Working shimmer

/// Animated contextual status row shown at the bottom of the transcript while
/// the agent is working ("Thinking…" / "Running <tool>…" / "Working…").
/// A status marker, not message content.
struct WorkingShimmerRow: View {
    var label: String = "Working…"

    @State private var phase: CGFloat = -1

    var body: some View {
        HStack(spacing: 8) {
            WorkingIndicator()
            Text(label)
                .font(.system(size: 15))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .overlay(
                    LinearGradient(
                        colors: [.clear, Theme.textPrimary.opacity(0.6), .clear],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .offset(x: phase * 80)
                    .mask(
                        Text(label).font(.system(size: 15)).lineLimit(1)
                    )
                )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .onAppear {
            withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                phase = 1.6
            }
        }
    }
}

// MARK: - Error marker

/// Inline error marker rendered at the end of the transcript when the session
/// status is `.error` — separate from the dismissible composer banner.
struct ErrorMarkerRow: View {
    let message: String
    /// When the error occurred, if the server reported it. Shows a subtle
    /// relative-time hint ("5m") so a lingering error reads as timestamped.
    var timestamp: Date? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(Theme.error)
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(Theme.error)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let timestamp {
                Text(relativeTimeLabel(timestamp))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Previews

#Preview("Transcript rows") {
    ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(MockConductorAPI.sampleTranscript) { item in
                switch item.kind {
                case .userPrompt(let text, _, let queued):
                    UserPromptBubble(text: text, queued: queued)
                case .assistantText(let text):
                    AssistantTextRow(text: text)
                case .thinking(let text, let seconds):
                    ThinkingRow(text: text, seconds: seconds)
                case .toolUse(let info):
                    ToolGroupRow(tools: [info])
                case .todoList(let entries):
                    TodoListCard(entries: entries)
                case .subtask(let title, let status):
                    SubtaskGroupCard(subtasks: [(id: item.id, title: title, status: status)])
                case .turnMarker(let text):
                    TurnMarkerRow(text: text)
                case .info(let text):
                    InfoRow(text: text)
                case .unknown(let typeName):
                    UnknownRow(typeName: typeName)
                }
            }
            WorkingShimmerRow()
        }
        .padding(16)
    }
    .background(Theme.background)
    .preferredColorScheme(.dark)
}

#Preview("Long prompt + queued") {
    VStack(spacing: 24) {
        UserPromptBubble(
            text: String(repeating: "Make the onboarding view clearer without changing navigation. ", count: 8),
            queued: false
        )
        UserPromptBubble(text: "Also cover the empty state", queued: true)
    }
    .padding(16)
    .background(Theme.background)
    .preferredColorScheme(.dark)
}

private let markdownSample = """
# Language breakdown

By language:

- Ruby: **21,427**
- TSX: **17,327**
  - nested item under TSX
- Swift: **2,240**

Some **bold** and *italic* and `inline code` in a paragraph.

1. First step
2. Second step

> A blockquote with a `note` inside.

```swift
func hello() {
    print("world")
}
```

## Smaller heading
Trailing paragraph.
"""

#Preview("Markdown blocks") {
    ScrollView {
        AssistantTextRow(text: markdownSample)
            .padding(16)
    }
    .background(Theme.background)
    .preferredColorScheme(.dark)
}

#Preview("Transcript rows (light)") {
    ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(MockConductorAPI.sampleTranscript) { item in
                switch item.kind {
                case .userPrompt(let text, _, let queued):
                    UserPromptBubble(text: text, queued: queued)
                case .assistantText(let text):
                    AssistantTextRow(text: text)
                case .thinking(let text, let seconds):
                    ThinkingRow(text: text, seconds: seconds)
                case .toolUse(let info):
                    ToolGroupRow(tools: [info])
                case .todoList(let entries):
                    TodoListCard(entries: entries)
                case .subtask(let title, let status):
                    SubtaskGroupCard(subtasks: [(id: item.id, title: title, status: status)])
                case .turnMarker(let text):
                    TurnMarkerRow(text: text)
                case .info(let text):
                    InfoRow(text: text)
                case .unknown(let typeName):
                    UnknownRow(typeName: typeName)
                }
            }
            AssistantTextRow(text: markdownSample)
        }
        .padding(16)
    }
    .background(Theme.background)
    .preferredColorScheme(.light)
}

#Preview("Grouped tools") {
    let tools = [
        TranscriptItem.ToolUseInfo(callID: "a", name: "Read", title: "Read page.tsx", detail: "cat app/tickets/page.tsx", status: .done, output: "…file contents…", category: .explored),
        TranscriptItem.ToolUseInfo(callID: "b", name: "Read", title: "Read layout.tsx", detail: nil, status: .done, output: nil, category: .explored),
        TranscriptItem.ToolUseInfo(callID: "c", name: "Bash", title: "Run typecheck", detail: "npm run typecheck", status: .done, output: "0 errors", category: .ran),
    ]
    return VStack(alignment: .leading, spacing: 20) {
        ToolGroupRow(tools: tools)
        ToolGroupRow(tools: [
            TranscriptItem.ToolUseInfo(callID: "d", name: "Bash", title: "Running tests…", detail: nil, status: .running, output: nil, category: .ran)
        ])
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Theme.background)
    .preferredColorScheme(.dark)
}
