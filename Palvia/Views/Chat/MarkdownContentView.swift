import SwiftUI
import UIKit

/// Renders markdown content with support for headers, code blocks, inline code,
/// bold, italic, strikethrough, links, images, tables, task lists, lists,
/// blockquotes, and horizontal rules.
struct MarkdownContentView: View {
    let content: String
    let isUserMessage: Bool
    var imageAttachments: [ImageAttachment]

    @State private var cachedBlocks: [MarkdownBlock] = []
    @State private var cachedContent: String = ""
    @State private var refreshTask: Task<Void, Never>?
    @State private var lastRefreshTime = Date.distantPast
    @State private var inlineCache: [String: AttributedString] = [:]

    static let streamingRefreshInterval: TimeInterval = 0.08

    static func streamingRefreshDelay(lastRefresh: Date, now: Date) -> TimeInterval {
        max(0, streamingRefreshInterval - now.timeIntervalSince(lastRefresh))
    }

    init(_ content: String, isUser: Bool = false, imageAttachments: [ImageAttachment] = []) {
        self.content = content
        self.isUserMessage = isUser
        self.imageAttachments = imageAttachments
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(cachedBlocks.enumerated()), id: \.offset) { _, block in
                renderBlock(block)
            }
        }
        .accessibilityIdentifier(AccessibilityID.Chat.markdownContent)
        .onAppear { refreshBlocksIfNeeded() }
        .onChange(of: content) { _, _ in refreshBlocksIfNeeded() }
        .onDisappear { refreshTask?.cancel() }
    }

    /// Cross-instance parse cache. Rows are re-created whenever the message
    /// list is rebuilt (verbose/silent toggle, re-entering a session) and
    /// during fast scrolling through history; without this, every
    /// re-materialization re-parses the full message on the main thread,
    /// which shows up as hitching and momentarily blank rows.
    private final class BlockCacheEntry {
        let blocks: [MarkdownBlock]
        init(_ blocks: [MarkdownBlock]) { self.blocks = blocks }
    }

    private static let blockCache: NSCache<NSString, BlockCacheEntry> = {
        let cache = NSCache<NSString, BlockCacheEntry>()
        cache.countLimit = 256
        return cache
    }()

    private func cachedOrParsedBlocks(_ source: String) -> [MarkdownBlock] {
        let key = source as NSString
        if let entry = Self.blockCache.object(forKey: key) { return entry.blocks }
        let blocks = parseBlocks(source)
        Self.blockCache.setObject(BlockCacheEntry(blocks), forKey: key)
        return blocks
    }

    private func refreshBlocksIfNeeded() {
        guard content != cachedContent else { return }

        // Instant path: first render of this instance, or content another
        // instance already parsed (cache hit) — no debounce needed.
        if cachedBlocks.isEmpty || Self.blockCache.object(forKey: content as NSString) != nil {
            refreshTask?.cancel()
            refreshTask = nil
            applyParsedContent(content)
            return
        }

        // Streaming path: throttle, rather than trailing-debounce, reparses.
        // A trailing debounce is continually cancelled by a fast stream and
        // eventually renders one very large block, producing a visible jump.
        // Anchoring the deadline to the previous render guarantees steady
        // progress at no more than ~12 parses/second.
        let now = Date()
        let delay = Self.streamingRefreshDelay(lastRefresh: lastRefreshTime, now: now)
        refreshTask?.cancel()
        let pendingContent = content

        if delay == 0 {
            refreshTask = nil
            applyParsedContent(pendingContent)
            return
        }

        refreshTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            applyParsedContent(pendingContent)
            refreshTask = nil
        }
    }

    private func applyParsedContent(_ source: String) {
        cachedContent = source
        cachedBlocks = cachedOrParsedBlocks(source)
        rebuildInlineCache()
        lastRefreshTime = Date()
    }

    private func rebuildInlineCache() {
        var cache: [String: AttributedString] = [:]
        let isUser = isUserMessage
        for block in cachedBlocks {
            switch block {
            case .paragraph(let text):
                cache[text] = Self.parseInlineMarkdown(text, isUserMessage: isUser)
            case .heading(_, let text):
                cache[text] = Self.parseInlineMarkdown(text, isUserMessage: isUser)
            case .bulletList(let items):
                for item in items { cache[item] = Self.parseInlineMarkdown(item, isUserMessage: isUser) }
            case .orderedList(let items):
                for item in items { cache[item] = Self.parseInlineMarkdown(item, isUserMessage: isUser) }
            case .taskList(let items):
                for item in items { cache[item.text] = Self.parseInlineMarkdown(item.text, isUserMessage: isUser) }
            case .blockquote(let text):
                cache[text] = Self.parseInlineMarkdown(text, isUserMessage: isUser)
            default:
                break
            }
        }
        inlineCache = cache
    }

    // MARK: - Block Rendering

    @ViewBuilder
    private func renderBlock(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            renderHeading(level: level, text: text)
        case .codeBlock(let language, let code):
            CodeBlockView(code: code, language: language)
        case .paragraph(let text):
            renderInlineText(text)
        case .bulletList(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                            .foregroundStyle(isUserMessage ? .white.opacity(0.7) : .secondary)
                        renderInlineText(item)
                    }
                }
            }
        case .orderedList(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(index + 1).")
                            .foregroundStyle(isUserMessage ? .white.opacity(0.7) : .secondary)
                            .monospacedDigit()
                        renderInlineText(item)
                    }
                }
            }
        case .taskList(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: item.checked ? "checkmark.square.fill" : "square")
                            .font(.caption)
                            .foregroundStyle(item.checked
                                ? (isUserMessage ? .white : .accentColor)
                                : (isUserMessage ? .white.opacity(0.5) : .secondary))
                        renderInlineText(item.text)
                    }
                }
            }
        case .blockquote(let text):
            renderInlineText(text)
                .foregroundStyle(isUserMessage ? .white.opacity(0.8) : .secondary)
                .padding(.leading, 14)
                .padding(.trailing, 4)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(isUserMessage ? Color.white.opacity(0.4) : Color.accentColor.opacity(0.5))
                        .frame(width: 3)
                }
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isUserMessage ? Color.white.opacity(0.06) : Color(.systemGray6).opacity(0.6))
                )
                .padding(.vertical, 2)
        case .table(let table):
            MarkdownTableView(table: table, isUserMessage: isUserMessage)
        case .image(let alt, let url):
            MarkdownImageView(alt: alt, urlString: url, isUserMessage: isUserMessage, imageAttachments: imageAttachments)
        case .horizontalRule:
            Divider()
                .padding(.vertical, 4)
        case .empty:
            EmptyView()
        }
    }

    @ViewBuilder
    private func renderHeading(level: Int, text: String) -> some View {
        let font: Font = switch level {
        case 1: .title2.bold()
        case 2: .title3.bold()
        case 3: .headline
        default: .subheadline.bold()
        }
        Text(inlineCache[text] ?? parseInlineMarkdown(text))
            .font(font)
            .foregroundStyle(isUserMessage ? .white : .primary)
            .padding(.top, level <= 2 ? 4 : 2)
    }

    @ViewBuilder
    private func renderInlineText(_ text: String) -> some View {
        let attributed = inlineCache[text] ?? parseInlineMarkdown(text)
        Text(attributed)
            .font(.body)
            .foregroundStyle(isUserMessage ? .white : .primary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    // MARK: - Block Parsing

    func parseBlocks() -> [MarkdownBlock] {
        parseBlocks(content)
    }

    private func parseBlocks(_ source: String) -> [MarkdownBlock] {
        let lines = source.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var i = 0

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Code block
            if trimmed.hasPrefix("```") {
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1
                while i < lines.count {
                    if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        i += 1
                        break
                    }
                    codeLines.append(lines[i])
                    i += 1
                }
                blocks.append(.codeBlock(language: lang.isEmpty ? "text" : lang, code: codeLines.joined(separator: "\n")))
                continue
            }

            // Empty line
            if trimmed.isEmpty {
                i += 1
                continue
            }

            // Heading
            if trimmed.hasPrefix("#") {
                let level = trimmed.prefix(while: { $0 == "#" }).count
                if level <= 6 {
                    let text = String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                    blocks.append(.heading(level: level, text: text))
                    i += 1
                    continue
                }
            }

            // Horizontal rule
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                blocks.append(.horizontalRule)
                i += 1
                continue
            }

            // Image (block-level): ![alt](url)
            if let imageMatch = parseBlockImage(trimmed) {
                blocks.append(.image(alt: imageMatch.alt, url: imageMatch.url))
                i += 1
                continue
            }

            // Blockquote
            if trimmed.hasPrefix("> ") || trimmed == ">" {
                var quoteLines: [String] = []
                while i < lines.count && lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    let ql = lines[i].trimmingCharacters(in: .whitespaces)
                    quoteLines.append(ql.hasPrefix("> ") ? String(ql.dropFirst(2)) : String(ql.dropFirst(1)))
                    i += 1
                }
                blocks.append(.blockquote(text: quoteLines.joined(separator: "\n")))
                continue
            }

            // Table: detect by checking if current and next line look like a table
            if trimmed.contains("|"), i + 1 < lines.count {
                let nextTrimmed = lines[i + 1].trimmingCharacters(in: .whitespaces)
                if isTableSeparator(nextTrimmed) {
                    let table = parseTable(lines: lines, from: &i)
                    if let table {
                        blocks.append(.table(table))
                        continue
                    }
                }
            }

            // Task list: - [ ] or - [x]
            if isTaskListItem(trimmed) {
                var items: [TaskListItem] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if let taskItem = parseTaskListItem(t) {
                        items.append(taskItem)
                        i += 1
                    } else if t.isEmpty {
                        break
                    } else if !items.isEmpty {
                        items[items.count - 1] = TaskListItem(
                            checked: items[items.count - 1].checked,
                            text: items[items.count - 1].text + " " + t
                        )
                        i += 1
                    } else {
                        break
                    }
                }
                blocks.append(.taskList(items: items))
                continue
            }

            // Bullet list
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                var items: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("+ ") {
                        items.append(String(t.dropFirst(2)))
                        i += 1
                    } else if t.isEmpty {
                        break
                    } else if !items.isEmpty {
                        items[items.count - 1] += " " + t
                        i += 1
                    } else {
                        break
                    }
                }
                blocks.append(.bulletList(items: items))
                continue
            }

            // Ordered list
            if let _ = trimmed.range(of: "^\\d+[.)]\\s", options: .regularExpression) {
                var items: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if let range = t.range(of: "^\\d+[.)]\\s", options: .regularExpression) {
                        items.append(String(t[range.upperBound...]))
                        i += 1
                    } else if t.isEmpty {
                        // Look ahead: if the next non-empty line is also an ordered list item, keep collecting
                        var lookahead = i + 1
                        while lookahead < lines.count && lines[lookahead].trimmingCharacters(in: .whitespaces).isEmpty {
                            lookahead += 1
                        }
                        if lookahead < lines.count,
                           lines[lookahead].trimmingCharacters(in: .whitespaces).range(of: "^\\d+[.)]\\s", options: .regularExpression) != nil {
                            i = lookahead
                            continue
                        }
                        break
                    } else if !items.isEmpty {
                        items[items.count - 1] += " " + t
                        i += 1
                    } else {
                        break
                    }
                }
                blocks.append(.orderedList(items: items))
                continue
            }

            // Paragraph (collect consecutive non-empty lines)
            var paraLines: [String] = []
            while i < lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if t.isEmpty || t.hasPrefix("#") || t.hasPrefix("```") || t.hasPrefix("> ") || t == ">" ||
                   t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("+ ") ||
                   t == "---" || t == "***" || t == "___" ||
                   isTaskListItem(t) ||
                   parseBlockImage(t) != nil ||
                   t.range(of: "^\\d+[.)]\\s", options: .regularExpression) != nil {
                    break
                }
                paraLines.append(t)
                i += 1
            }
            if !paraLines.isEmpty {
                let joined = paraLines.joined(separator: " ")
                let segments = splitParagraphIntoSegments(joined)
                if segments.count == 1, case .text = segments[0] {
                    blocks.append(.paragraph(text: joined))
                } else {
                    for seg in segments {
                        switch seg {
                        case .text(let t):
                            let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty { blocks.append(.paragraph(text: trimmed)) }
                        case .image(let alt, let url):
                            blocks.append(.image(alt: alt, url: url))
                        }
                    }
                }
            }
        }

        return blocks
    }

    // MARK: - Table Parsing

    private func isTableSeparator(_ line: String) -> Bool {
        let stripped = line.trimmingCharacters(in: .whitespaces)
        guard stripped.contains("|") else { return false }
        let cells = splitTableRow(stripped)
        return cells.allSatisfy { cell in
            let c = cell.trimmingCharacters(in: .whitespaces)
            return c.isEmpty || c.allSatisfy({ $0 == "-" || $0 == ":" || $0 == " " }) && c.contains("-")
        }
    }

    private func splitTableRow(_ line: String) -> [String] {
        var row = line.trimmingCharacters(in: .whitespaces)
        if row.hasPrefix("|") { row = String(row.dropFirst()) }
        if row.hasSuffix("|") { row = String(row.dropLast()) }
        return row.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private func parseAlignment(_ cell: String) -> TableAlignment {
        let c = cell.trimmingCharacters(in: .whitespaces)
        let left = c.hasPrefix(":")
        let right = c.hasSuffix(":")
        if left && right { return .center }
        if right { return .trailing }
        return .leading
    }

    private func parseTable(lines: [String], from i: inout Int) -> MarkdownTable? {
        let headerLine = lines[i].trimmingCharacters(in: .whitespaces)
        let separatorLine = lines[i + 1].trimmingCharacters(in: .whitespaces)

        let headers = splitTableRow(headerLine)
        let separatorCells = splitTableRow(separatorLine)
        let alignments = separatorCells.map { parseAlignment($0) }

        i += 2

        var rows: [[String]] = []
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.isEmpty || !t.contains("|") { break }
            if isTableSeparator(t) { i += 1; continue }
            let cells = splitTableRow(t)
            rows.append(cells)
            i += 1
        }

        guard !headers.isEmpty else { return nil }

        let columnCount = headers.count
        let normalizedAlignments = (0..<columnCount).map { idx in
            idx < alignments.count ? alignments[idx] : .leading
        }
        let normalizedRows = rows.map { row in
            (0..<columnCount).map { idx in idx < row.count ? row[idx] : "" }
        }

        return MarkdownTable(
            headers: headers,
            alignments: normalizedAlignments,
            rows: normalizedRows
        )
    }

    // MARK: - Paragraph Segment Splitting

    private enum ParagraphSegment {
        case text(String)
        case image(alt: String, url: String)
    }

    private func splitParagraphIntoSegments(_ text: String) -> [ParagraphSegment] {
        var segments: [ParagraphSegment] = []
        var remaining = text[text.startIndex...]

        while let imgStart = remaining.range(of: "![") {
            let before = String(remaining[remaining.startIndex..<imgStart.lowerBound])
            if !before.trimmingCharacters(in: .whitespaces).isEmpty {
                segments.append(.text(before))
            }

            let afterBang = remaining[imgStart.upperBound...]
            guard let closeBracket = afterBang.firstIndex(of: "]") else {
                segments.append(.text(String(remaining)))
                return segments
            }
            let alt = String(afterBang[afterBang.startIndex..<closeBracket])
            let afterBracket = afterBang[afterBang.index(after: closeBracket)...]
            guard afterBracket.hasPrefix("(") else {
                segments.append(.text(String(remaining[remaining.startIndex...closeBracket])))
                remaining = afterBracket
                continue
            }
            let urlPart = afterBracket.dropFirst()
            guard let closeParen = urlPart.firstIndex(of: ")") else {
                segments.append(.text(String(remaining)))
                return segments
            }
            let url = String(urlPart[urlPart.startIndex..<closeParen])
            segments.append(.image(alt: alt, url: url))
            remaining = urlPart[urlPart.index(after: closeParen)...]
        }

        let tail = String(remaining)
        if !tail.trimmingCharacters(in: .whitespaces).isEmpty {
            segments.append(.text(tail))
        }

        if segments.isEmpty {
            return [.text(text)]
        }
        return segments
    }

    // MARK: - Image Parsing

    private func parseBlockImage(_ line: String) -> (alt: String, url: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("![") else { return nil }
        let after = trimmed.dropFirst(2)
        guard let closeBracket = after.firstIndex(of: "]") else { return nil }
        let alt = String(after[after.startIndex..<closeBracket])
        let afterBracket = after[after.index(after: closeBracket)...]
        guard afterBracket.hasPrefix("(") else { return nil }
        let urlPart = afterBracket.dropFirst()
        guard let closeParen = urlPart.firstIndex(of: ")") else { return nil }
        let url = String(urlPart[urlPart.startIndex..<closeParen])
        // Verify this is the entire line content (block-level image)
        let remaining = urlPart[urlPart.index(after: closeParen)...].trimmingCharacters(in: .whitespaces)
        guard remaining.isEmpty else { return nil }
        return (alt, url)
    }

    // MARK: - Task List Parsing

    private func isTaskListItem(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("- [ ] ") || t.hasPrefix("- [x] ") || t.hasPrefix("- [X] ") ||
               t.hasPrefix("* [ ] ") || t.hasPrefix("* [x] ") || t.hasPrefix("* [X] ")
    }

    private func parseTaskListItem(_ line: String) -> TaskListItem? {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("- [ ] ") || t.hasPrefix("* [ ] ") {
            return TaskListItem(checked: false, text: String(t.dropFirst(6)))
        }
        if t.hasPrefix("- [x] ") || t.hasPrefix("- [X] ") || t.hasPrefix("* [x] ") || t.hasPrefix("* [X] ") {
            return TaskListItem(checked: true, text: String(t.dropFirst(6)))
        }
        return nil
    }

    // MARK: - Inline Parsing

    func parseInlineMarkdown(_ text: String) -> AttributedString {
        Self.parseInlineMarkdown(text, isUserMessage: isUserMessage)
    }

    static func parseInlineMarkdown(_ text: String, isUserMessage: Bool, baseFont: Font = .body) -> AttributedString {
        var result = AttributedString()
        var remaining = text[text.startIndex...]
        var plainBuffer = ""

        func flushPlain() {
            if !plainBuffer.isEmpty {
                result.append(AttributedString(plainBuffer))
                plainBuffer = ""
            }
        }

        while !remaining.isEmpty {
            // Image inline: ![alt](url) → render as [🖼 alt] link
            if remaining.hasPrefix("![") {
                let after = remaining.dropFirst(2)
                if let closeBracket = after.firstIndex(of: "]") {
                    let altText = String(after[after.startIndex..<closeBracket])
                    let afterBracket = after[after.index(after: closeBracket)...]
                    if afterBracket.hasPrefix("(") {
                        let urlPart = afterBracket.dropFirst()
                        if let closeParen = urlPart.firstIndex(of: ")") {
                            flushPlain()
                            let urlStr = String(urlPart[urlPart.startIndex..<closeParen])
                            var attr = AttributedString("🖼 \(altText.isEmpty ? urlStr : altText)")
                            if let url = URL(string: urlStr) {
                                attr.link = url
                            }
                            attr.foregroundColor = .blue
                            attr.underlineStyle = .single
                            result.append(attr)
                            remaining = urlPart[urlPart.index(after: closeParen)...]
                            continue
                        }
                    }
                }
            }

            // Inline code: `code`
            if remaining.hasPrefix("`") {
                let after = remaining.dropFirst()
                if let endIdx = after.firstIndex(of: "`") {
                    flushPlain()
                    let code = String(after[after.startIndex..<endIdx])
                    var attr = AttributedString(code)
                    attr.font = baseFont.monospaced()
                    attr.backgroundColor = isUserMessage ? .white.opacity(0.15) : Color(.systemGray5)
                    result.append(attr)
                    remaining = after[after.index(after: endIdx)...]
                    continue
                }
            }

            // Bold+Italic: ***text*** or ___text___
            if remaining.hasPrefix("***") {
                let after = remaining.dropFirst(3)
                if let endRange = after.range(of: "***") {
                    flushPlain()
                    let inner = String(after[after.startIndex..<endRange.lowerBound])
                    var attr = parseInlineMarkdown(inner, isUserMessage: isUserMessage, baseFont: baseFont)
                    attr.font = baseFont.bold().italic()
                    result.append(attr)
                    remaining = after[endRange.upperBound...]
                    continue
                }
            }

            // Bold: **text** or __text__
            if remaining.hasPrefix("**") {
                let after = remaining.dropFirst(2)
                if let endRange = after.range(of: "**") {
                    flushPlain()
                    let boldText = String(after[after.startIndex..<endRange.lowerBound])
                    var attr = parseInlineMarkdown(boldText, isUserMessage: isUserMessage, baseFont: baseFont)
                    attr.font = baseFont.bold()
                    result.append(attr)
                    remaining = after[endRange.upperBound...]
                    continue
                }
            }

            // Italic: *text* or _text_
            if (remaining.hasPrefix("*") && !remaining.hasPrefix("**")) ||
               (remaining.hasPrefix("_") && !remaining.hasPrefix("__")) {
                guard let marker = remaining.first else { break }
                let after = remaining.dropFirst()
                if let endIdx = after.firstIndex(of: marker) {
                    flushPlain()
                    let italicText = String(after[after.startIndex..<endIdx])
                    var attr = parseInlineMarkdown(italicText, isUserMessage: isUserMessage, baseFont: baseFont)
                    attr.font = baseFont.italic()
                    result.append(attr)
                    remaining = after[after.index(after: endIdx)...]
                    continue
                }
            }

            // Strikethrough: ~~text~~
            if remaining.hasPrefix("~~") {
                let after = remaining.dropFirst(2)
                if let endRange = after.range(of: "~~") {
                    flushPlain()
                    let strikeText = String(after[after.startIndex..<endRange.lowerBound])
                    var attr = AttributedString(strikeText)
                    attr.strikethroughStyle = .single
                    result.append(attr)
                    remaining = after[endRange.upperBound...]
                    continue
                }
            }

            // Link: [text](url)
            if remaining.hasPrefix("[") {
                let after = remaining.dropFirst()
                if let closeBracket = after.firstIndex(of: "]") {
                    let linkText = String(after[after.startIndex..<closeBracket])
                    let afterBracket = after[after.index(after: closeBracket)...]
                    if afterBracket.hasPrefix("(") {
                        let urlPart = afterBracket.dropFirst()
                        if let closeParen = urlPart.firstIndex(of: ")") {
                            flushPlain()
                            let urlStr = String(urlPart[urlPart.startIndex..<closeParen])
                            var attr = AttributedString(linkText)
                            if let url = URL(string: urlStr) {
                                attr.link = url
                            }
                            attr.foregroundColor = .blue
                            attr.underlineStyle = .single
                            result.append(attr)
                            remaining = urlPart[urlPart.index(after: closeParen)...]
                            continue
                        }
                    }
                }
            }

            // Batch plain characters instead of appending one at a time
            guard let char = remaining.first else { break }
            plainBuffer.append(char)
            remaining = remaining.dropFirst()
        }

        flushPlain()
        return result
    }
}

// MARK: - Block Types

enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case codeBlock(language: String, code: String)
    case paragraph(text: String)
    case bulletList(items: [String])
    case orderedList(items: [String])
    case taskList(items: [TaskListItem])
    case blockquote(text: String)
    case table(MarkdownTable)
    case image(alt: String, url: String)
    case horizontalRule
    case empty
}

struct TaskListItem: Equatable {
    let checked: Bool
    let text: String
}

// MARK: - Table Types

enum TableAlignment: Equatable {
    case leading, center, trailing

    var horizontal: HorizontalAlignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    var textAlignment: TextAlignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

struct MarkdownTable: Equatable {
    let headers: [String]
    let alignments: [TableAlignment]
    let rows: [[String]]
}

// MARK: - Table View

private struct MarkdownTableView: View {
    let table: MarkdownTable
    let isUserMessage: Bool

    @State private var parsedHeaders: [AttributedString] = []
    @State private var parsedRows: [[AttributedString]] = []
    @State private var columnWidths: [CGFloat] = []
    @State private var hasBuilt = false
    @State private var showAll = false
    @State private var popoverCell: PopoverCell?
    @State private var containerWidth: CGFloat = 0

    private struct PopoverCell: Identifiable {
        let id = UUID()
        let text: AttributedString
    }

    private static let maxCollapsedRows = 10
    private static let cellPaddingH: CGFloat = 8
    private static let cellPaddingV: CGFloat = 4
    private static let minColWidth: CGFloat = 50
    private static let maxColWidth: CGFloat = 280

    private var visibleRowCount: Int {
        if showAll || table.rows.count <= Self.maxCollapsedRows {
            return parsedRows.count
        }
        return min(Self.maxCollapsedRows, parsedRows.count)
    }

    private var separatorColor: Color {
        isUserMessage ? Color.white.opacity(0.2) : Color(.systemGray4)
    }

    var body: some View {
        if hasBuilt && !columnWidths.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(spacing: 0) {
                        tableRow(cells: parsedHeaders, isHeader: true)
                            .background(isUserMessage ? Color.white.opacity(0.1) : Color(.systemGray5))

                        Rectangle()
                            .fill(isUserMessage ? Color.white.opacity(0.3) : Color(.systemGray4))
                            .frame(height: 1)

                        ForEach(0..<visibleRowCount, id: \.self) { rowIdx in
                            tableRow(cells: parsedRows[rowIdx], isHeader: false)
                                .background(rowIdx % 2 == 1
                                    ? (isUserMessage ? Color.white.opacity(0.05) : Color(.systemGray6).opacity(0.5))
                                    : Color.clear)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(separatorColor, lineWidth: 0.5)
                    )
                }
                .textSelection(.enabled)

                HStack(spacing: 12) {
                    if table.rows.count > Self.maxCollapsedRows && !showAll {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { showAll = true }
                        } label: {
                            Text("\(Image(systemName: "chevron.down")) \(table.rows.count - Self.maxCollapsedRows) more rows")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }

                    Text(L10n.Chat.doubleTapToExpand)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.top, 4)
            }
            .onAppear { buildIfNeeded() }
            .onChange(of: table) { _, _ in rebuild() }
            .background(
                GeometryReader { geo in
                    Color.clear.onChange(of: geo.size.width) { _, newW in
                        if newW > 0 && newW != containerWidth {
                            containerWidth = newW
                            rebuild()
                        }
                    }
                    .onAppear {
                        let w = geo.size.width
                        if w > 0 && w != containerWidth {
                            containerWidth = w
                            rebuild()
                        }
                    }
                }
            )
            .sheet(item: $popoverCell) { cell in
                NavigationStack {
                    ScrollView {
                        Text(cell.text)
                            .font(.body)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .navigationTitle(L10n.Chat.cellDetail)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(L10n.Common.done) { popoverCell = nil }
                        }
                    }
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        } else {
            GeometryReader { geo in
                Color.clear.onAppear {
                    if geo.size.width > 0 {
                        containerWidth = geo.size.width
                    }
                    buildIfNeeded()
                }
            }
            .frame(height: 1)
        }
    }

    private func tableRow(cells: [AttributedString], isHeader: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<columnWidths.count, id: \.self) { colIdx in
                let alignment = colIdx < table.alignments.count ? table.alignments[colIdx] : TableAlignment.leading
                let cellText = colIdx < cells.count ? cells[colIdx] : AttributedString()
                Text(cellText)
                    .font(isHeader ? .caption.bold() : .caption)
                    .foregroundStyle(isUserMessage ? .white : .primary)
                    .lineLimit(isHeader ? 2 : 8)
                    .multilineTextAlignment(alignment.textAlignment)
                    .padding(.horizontal, Self.cellPaddingH)
                    .padding(.vertical, Self.cellPaddingV)
                    .frame(
                        width: columnWidths[colIdx],
                        alignment: Alignment(horizontal: alignment.horizontal, vertical: .center)
                    )
                    .overlay(alignment: .trailing) {
                        if colIdx < columnWidths.count - 1 {
                            Rectangle()
                                .fill(isUserMessage ? Color.white.opacity(0.1) : Color(.systemGray5))
                                .frame(width: 0.5)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        popoverCell = PopoverCell(text: cellText)
                    }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func buildIfNeeded() {
        guard !hasBuilt else { return }
        rebuild()
    }

    private func rebuild() {
        let isUser = isUserMessage
        parsedHeaders = table.headers.map {
            MarkdownContentView.parseInlineMarkdown($0, isUserMessage: isUser, baseFont: .caption)
        }
        parsedRows = table.rows.map { row in
            row.map { MarkdownContentView.parseInlineMarkdown($0, isUserMessage: isUser, baseFont: .caption) }
        }
        columnWidths = measureColumnWidths()
        hasBuilt = true
    }

    private static func stripInlineMarkdown(_ text: String) -> String {
        TableWidthCalculator.stripInlineMarkdown(text)
    }

    private func measureColumnWidths() -> [CGFloat] {
        // Use actual container width if measured, otherwise fall back to screen width
        let maxWidth: CGFloat? = containerWidth > 0 ? containerWidth : nil
        return TableWidthCalculator.measureColumnWidths(
            for: table,
            cellPaddingH: Self.cellPaddingH,
            minColWidth: Self.minColWidth,
            maxColWidth: Self.maxColWidth,
            maxTableWidth: maxWidth
        )
    }
}

// MARK: - Table Width Calculator (testable)

enum TableWidthCalculator {

    /// Strip markdown inline syntax characters for width measurement.
    static func stripInlineMarkdown(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: "***", with: "")
        s = s.replacingOccurrences(of: "___", with: "")
        s = s.replacingOccurrences(of: "**", with: "")
        s = s.replacingOccurrences(of: "__", with: "")
        s = s.replacingOccurrences(of: "*", with: "")
        s = s.replacingOccurrences(of: "_", with: "")
        s = s.replacingOccurrences(of: "~~", with: "")
        s = s.replacingOccurrences(of: "`", with: "")
        // Strip link/image syntax: [text](url) → text, ![alt](url) → alt
        while let open = s.range(of: "![") ?? s.range(of: "[") {
            let isImage = s[open].first == "!"
            let afterBracket = s[open.upperBound...]
            guard let close = afterBracket.firstIndex(of: "]") else { break }
            let inner = String(afterBracket[afterBracket.startIndex..<close])
            let afterClose = s[s.index(after: close)...]
            if afterClose.hasPrefix("("), let paren = afterClose.firstIndex(of: ")") {
                let replacement = isImage ? inner : inner
                s.replaceSubrange(open.lowerBound...paren, with: replacement)
            } else {
                break
            }
        }
        return s
    }

    static func measureColumnWidths(
        for table: MarkdownTable,
        cellPaddingH: CGFloat = 8,
        minColWidth: CGFloat = 50,
        maxColWidth: CGFloat = 280,
        maxTableWidth: CGFloat? = nil
    ) -> [CGFloat] {
        let font = UIFont.preferredFont(forTextStyle: .caption1)
        let boldFont = UIFont.boldSystemFont(ofSize: font.pointSize)
        let padding = cellPaddingH * 2
        // Small buffer to account for UIKit/SwiftUI font metric differences
        let measureBuffer: CGFloat = 4
        let effectiveMaxTableWidth = maxTableWidth ?? (UIScreen.main.bounds.width - 32)

        var widths = (0..<table.headers.count).map { col -> CGFloat in
            let headerText = stripInlineMarkdown(table.headers[col])
            let headerSize = NSAttributedString(string: headerText, attributes: [.font: boldFont]).size()
            var maxWidth = headerSize.width

            let rowsToMeasure = min(table.rows.count, 30)
            for rowIdx in 0..<rowsToMeasure {
                if col < table.rows[rowIdx].count {
                    let cellText = stripInlineMarkdown(table.rows[rowIdx][col])
                    let cellSize = NSAttributedString(string: cellText, attributes: [.font: boldFont]).size()
                    maxWidth = max(maxWidth, cellSize.width)
                }
            }
            return max(minColWidth, min(ceil(maxWidth) + padding + measureBuffer, maxColWidth))
        }

        let totalWidth = widths.reduce(0, +)
        if totalWidth > effectiveMaxTableWidth && totalWidth > 0 {
            // Scale down to fit screen
            let scale = effectiveMaxTableWidth / totalWidth
            widths = widths.map { max(minColWidth, floor($0 * scale)) }
        } else if totalWidth < effectiveMaxTableWidth && totalWidth > 0 {
            // Distribute extra space proportionally so wider columns get more
            let extraSpace = effectiveMaxTableWidth - totalWidth
            let expandableTotal = widths.filter { $0 < maxColWidth }.reduce(0, +)
            if expandableTotal > 0 {
                for idx in widths.indices where widths[idx] < maxColWidth {
                    let share = extraSpace * (widths[idx] / expandableTotal)
                    widths[idx] = min(widths[idx] + share, maxColWidth)
                }
            }
        }

        return widths
    }
}

// MARK: - Image View

private struct MarkdownImageView: View {
    let alt: String
    let urlString: String
    let isUserMessage: Bool
    var imageAttachments: [ImageAttachment] = []

    @State private var resolvedImage: UIImage?

    private var isDataURI: Bool { urlString.hasPrefix("data:image/") }
    private var isAttachmentRef: Bool { urlString.hasPrefix("attachment:") }
    private var isAgentFileRef: Bool { urlString.hasPrefix("agentfile://") }

    private var isAgentFileImage: Bool {
        guard isAgentFileRef,
              let (_, filename) = AgentFileManager.parseFileReference(urlString) else { return false }
        let ext = (filename as NSString).pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tiff", "tif"].contains(ext)
    }

    private var attachmentIndex: Int? {
        guard isAttachmentRef,
              let idx = Int(urlString.dropFirst("attachment:".count)),
              idx >= 0, idx < imageAttachments.count
        else { return nil }
        return idx
    }

    private var attachmentImage: UIImage? {
        guard let idx = attachmentIndex else { return nil }
        return imageAttachments[idx].uiImage
    }

    private var isAttachmentFileDeleted: Bool {
        guard let idx = attachmentIndex else { return false }
        return imageAttachments[idx].isFileDeleted
    }

    private static func decodeDataURI(_ urlString: String) -> UIImage? {
        guard let commaIdx = urlString.firstIndex(of: ",") else { return nil }
        let base64 = String(urlString[urlString.index(after: commaIdx)...])
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else { return nil }
        return UIImage(data: data)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isAgentFileRef {
                if isAgentFileImage {
                    if let data = AgentFileManager.shared.loadImageData(from: urlString),
                       let uiImage = UIImage(data: data) {
                        thumbnailImage(Image(uiImage: uiImage))
                            .onAppear { resolvedImage = uiImage }
                    } else {
                        imageDeletedView
                    }
                } else {
                    agentFileLinkView
                }
            } else if isAttachmentRef {
                if isAttachmentFileDeleted {
                    imageDeletedView
                } else if let uiImage = attachmentImage {
                    thumbnailImage(Image(uiImage: uiImage))
                        .onAppear { resolvedImage = uiImage }
                } else {
                    imageFailedView
                }
            } else if isDataURI {
                if let uiImage = resolvedImage {
                    thumbnailImage(Image(uiImage: uiImage))
                } else {
                    imageFailedView
                }
            } else if let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(L10n.Chat.loadingImage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(height: 100)
                    case .success(let image):
                        thumbnailImage(image)
                    case .failure:
                        imageFailedView
                    @unknown default:
                        EmptyView()
                    }
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "link.badge.plus")
                        .foregroundStyle(.secondary)
                    Text(alt.isEmpty ? urlString.prefix(80) + "…" : alt)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !alt.isEmpty {
                Text(alt)
                    .font(.caption)
                    .foregroundStyle(isUserMessage ? .white.opacity(0.6) : .secondary)
                    .italic()
            }
        }
        .task {
            if isAgentFileRef && isAgentFileImage {
                if let data = AgentFileManager.shared.loadImageData(from: urlString) {
                    resolvedImage = UIImage(data: data)
                }
            } else if isDataURI {
                resolvedImage = Self.decodeDataURI(urlString)
            } else if !isAttachmentRef, let url = URL(string: urlString) {
                resolvedImage = await Self.downloadImage(from: url)
            }
        }
    }

    private func thumbnailImage(_ image: Image) -> some View {
        image
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: 400, maxHeight: 400)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .onTapGesture {
                if let resolvedImage {
                    ImagePreviewCoordinator.shared.show(resolvedImage)
                }
            }
    }

    private var imageFailedView: some View {
        HStack(spacing: 6) {
            Image(systemName: "photo.badge.exclamationmark")
                .foregroundStyle(.secondary)
            Text(L10n.Chat.imageLoadFailed)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.systemGray6))
        )
    }

    private var agentFileLinkView: some View {
        let filename = AgentFileManager.parseFileReference(urlString).map(\.1) ?? urlString
        return HStack(spacing: 6) {
            Image(systemName: "doc.fill")
                .foregroundStyle(.blue)
            Text(alt.isEmpty ? filename : alt)
                .font(.caption)
                .foregroundStyle(.blue)
                .underline()
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.systemGray6))
        )
    }

    private var imageDeletedView: some View {
        HStack(spacing: 6) {
            Image(systemName: "trash.slash")
                .foregroundStyle(.secondary)
            Text(L10n.Chat.imageDeleted)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.systemGray6))
        )
    }

    private static func downloadImage(from url: URL) async -> UIImage? {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return UIImage(data: data)
        } catch {
            return nil
        }
    }
}
