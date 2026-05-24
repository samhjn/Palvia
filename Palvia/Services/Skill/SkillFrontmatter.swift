import Foundation

/// Parsed frontmatter from a SKILL.md file.
///
/// Intentionally not a full YAML model — we only parse the shape documented
/// in the skill-standard-alignment proposal. Unknown top-level keys produce a
/// warning (not an error) so the format can grow.
struct SkillFrontmatter: Hashable {
    var name: String
    var description: String
    var iclaw: IClawBlock

    /// Other top-level keys found in the frontmatter (preserved for warnings
    /// and future-proofing). Values are the raw line text after the colon.
    var unknownKeys: [String: String] = [:]

    struct IClawBlock: Hashable {
        var version: String? = nil
        var tags: [String] = []
        var slash: String? = nil
        var configRaw: [[String: String]] = []
    }

    /// Overlay-only frontmatter — everything is optional. Used by
    /// `SKILL.<lang>.md` to override a subset of the canonical fields.
    struct Overlay: Hashable {
        var displayName: String?
        var description: String?
        /// Raw body text following the overlay's frontmatter block (localized
        /// skill content). Empty if the overlay has no body.
        var body: String = ""
    }
}

enum FrontmatterError: Error, CustomStringConvertible {
    case missingOpeningDelimiter(line: Int)
    case missingClosingDelimiter
    case malformed(line: Int, reason: String)

    var description: String {
        switch self {
        case .missingOpeningDelimiter(let line):
            return "Missing opening `---` delimiter at line \(line)"
        case .missingClosingDelimiter:
            return "Missing closing `---` delimiter"
        case .malformed(let line, let reason):
            return "Malformed frontmatter at line \(line): \(reason)"
        }
    }
}

enum SkillFrontmatterParser {

    /// Parse a full SKILL.md file (frontmatter + body).
    ///
    /// Returns the parsed frontmatter, the body text (markdown following the
    /// closing `---`), and the 1-based line on which the body begins.
    static func parse(_ source: String) throws -> (SkillFrontmatter, body: String, bodyStartLine: Int) {
        let (fmText, body, bodyStartLine) = try splitFrontmatter(source)
        let fm = try parseFrontmatterBlock(fmText)
        return (fm, body, bodyStartLine)
    }

    /// Parse an overlay file (`SKILL.<lang>.md`) — all fields optional.
    static func parseOverlay(_ source: String) throws -> SkillFrontmatter.Overlay {
        let (fmText, body, _) = try splitFrontmatter(source)
        let lines = fmText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var overlay = SkillFrontmatter.Overlay()
        overlay.body = body

        for (idx, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let colonIdx = line.firstIndex(of: ":") else {
                throw FrontmatterError.malformed(line: idx + 2, reason: "Expected `key: value`")
            }
            let key = String(line[..<colonIdx]).trimmingCharacters(in: .whitespaces)
            let value = stripQuotes(String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces))
            switch key {
            case "display_name": overlay.displayName = value
            case "description":  overlay.description = value
            default:
                // Overlays tolerate unknown keys silently — they may be carrying
                // forward canonical fields that don't apply to overlays.
                continue
            }
        }
        return overlay
    }

    // MARK: - Internals

    /// Extract the frontmatter block text (without delimiters) and the body.
    private static func splitFrontmatter(_ source: String) throws -> (String, body: String, bodyStartLine: Int) {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let firstLine = lines.first else {
            throw FrontmatterError.missingOpeningDelimiter(line: 1)
        }
        guard firstLine.trimmingCharacters(in: .whitespaces) == "---" else {
            throw FrontmatterError.missingOpeningDelimiter(line: 1)
        }
        var closingIdx: Int? = nil
        for i in 1..<lines.count where lines[i].trimmingCharacters(in: .whitespaces) == "---" {
            closingIdx = i
            break
        }
        guard let close = closingIdx else {
            throw FrontmatterError.missingClosingDelimiter
        }
        let fmLines = Array(lines[1..<close])
        let bodyLines = Array(lines[(close + 1)...])
        // Trim a single leading blank line after the closing delimiter
        var trimmedBodyLines = bodyLines
        if let first = trimmedBodyLines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            trimmedBodyLines.removeFirst()
        }
        let bodyStartLine = close + 2 + (bodyLines.count - trimmedBodyLines.count)
        return (fmLines.joined(separator: "\n"), trimmedBodyLines.joined(separator: "\n"), bodyStartLine)
    }

    private static func parseFrontmatterBlock(_ text: String) throws -> SkillFrontmatter {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var fm = SkillFrontmatter(name: "", description: "", iclaw: .init())

        var i = 0
        while i < lines.count {
            let lineNum = i + 2 // +1 for 1-based, +1 for the opening `---`
            let raw = lines[i]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { i += 1; continue }

            // Indented lines belong to a preceding nested block — only the
            // `iclaw:` block is recognized, and its parsing is handled in
            // `parseIClawBlock`. At the top level we expect `key: value` or
            // `key:` (followed by an indented block).
            guard !isIndented(raw) else {
                throw FrontmatterError.malformed(line: lineNum, reason: "Unexpected indented line at top level")
            }
            guard let colonIdx = trimmed.firstIndex(of: ":") else {
                throw FrontmatterError.malformed(line: lineNum, reason: "Expected `key: value`")
            }
            let key = String(trimmed[..<colonIdx]).trimmingCharacters(in: .whitespaces)
            let valuePart = String(trimmed[trimmed.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)

            if key == "iclaw" {
                // Nested block: collect all following indented lines.
                var blockLines: [String] = []
                var j = i + 1
                while j < lines.count {
                    let next = lines[j]
                    if next.trimmingCharacters(in: .whitespaces).isEmpty {
                        blockLines.append(next)
                        j += 1
                        continue
                    }
                    if isIndented(next) {
                        blockLines.append(next)
                        j += 1
                    } else {
                        break
                    }
                }
                fm.iclaw = try parseIClawBlock(blockLines, startLine: lineNum + 1)
                i = j
                continue
            }

            switch key {
            case "name":        fm.name = stripQuotes(valuePart)
            case "description": fm.description = stripQuotes(valuePart)
            default:            fm.unknownKeys[key] = valuePart
            }
            i += 1
        }
        return fm
    }

    private static func parseIClawBlock(_ lines: [String], startLine: Int) throws -> SkillFrontmatter.IClawBlock {
        var block = SkillFrontmatter.IClawBlock()
        var i = 0
        while i < lines.count {
            let lineNum = startLine + i
            let raw = lines[i]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { i += 1; continue }

            guard let colonIdx = trimmed.firstIndex(of: ":") else {
                throw FrontmatterError.malformed(line: lineNum, reason: "Expected `key: value` in iclaw block")
            }
            let key = String(trimmed[..<colonIdx]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)

            switch key {
            case "version":
                block.version = stripQuotes(value)
            case "slash":
                block.slash = stripQuotes(value)
            case "tags":
                block.tags = try parseInlineStringList(value, line: lineNum)
            case "config":
                // `config:` followed by indented `- { ... }` items. Collect
                // following indented lines and parse each `-` item as an
                // inline map.
                var entryLines: [String] = []
                var j = i + 1
                while j < lines.count {
                    let next = lines[j]
                    let indent = leadingWhitespaceCount(next)
                    if next.trimmingCharacters(in: .whitespaces).isEmpty {
                        j += 1; continue
                    }
                    if indent > leadingWhitespaceCount(raw) {
                        entryLines.append(next)
                        j += 1
                    } else {
                        break
                    }
                }
                block.configRaw = try parseConfigEntries(entryLines, startLine: lineNum + 1)
                i = j
                continue
            default:
                // Unknown iclaw-block key: ignore silently — keeps the format
                // extensible without forcing an error on older parsers.
                break
            }
            i += 1
        }
        return block
    }

    private static func parseConfigEntries(_ lines: [String], startLine: Int) throws -> [[String: String]] {
        var entries: [[String: String]] = []
        for (idx, raw) in lines.enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard trimmed.hasPrefix("-") else {
                throw FrontmatterError.malformed(line: startLine + idx, reason: "Expected `- { ... }` list item")
            }
            var rest = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            guard rest.hasPrefix("{"), rest.hasSuffix("}") else {
                throw FrontmatterError.malformed(line: startLine + idx, reason: "config entry must be an inline `{ key: value, ... }` map")
            }
            rest = String(rest.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            var entry: [String: String] = [:]
            for pair in splitTopLevelCommas(rest) {
                guard let colon = pair.firstIndex(of: ":") else {
                    throw FrontmatterError.malformed(line: startLine + idx, reason: "inline map entry missing `:`")
                }
                let k = String(pair[..<colon]).trimmingCharacters(in: .whitespaces)
                let v = stripQuotes(String(pair[pair.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
                entry[k] = v
            }
            entries.append(entry)
        }
        return entries
    }

    // MARK: - Small helpers

    private static func parseInlineStringList(_ value: String, line: Int) throws -> [String] {
        guard value.hasPrefix("["), value.hasSuffix("]") else {
            throw FrontmatterError.malformed(line: line, reason: "Expected inline list `[a, b, c]`")
        }
        let inner = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        if inner.isEmpty { return [] }
        return splitTopLevelCommas(inner).map { stripQuotes($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Split `a, b, c` respecting matched `{}` and `[]` groupings so inline
    /// maps and lists nest cleanly.
    private static func splitTopLevelCommas(_ s: String) -> [String] {
        var parts: [String] = []
        var depth = 0
        var current = ""
        for ch in s {
            switch ch {
            case "{", "[": depth += 1; current.append(ch)
            case "}", "]": depth -= 1; current.append(ch)
            case "," where depth == 0:
                parts.append(current)
                current = ""
            default:
                current.append(ch)
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    private static func stripQuotes(_ s: String) -> String {
        if s.count >= 2,
           (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")) {
            return String(s.dropFirst().dropLast())
        }
        return s
    }

    private static func isIndented(_ line: String) -> Bool {
        guard let first = line.unicodeScalars.first else { return false }
        return first == " " || first == "\t"
    }

    private static func leadingWhitespaceCount(_ line: String) -> Int {
        var n = 0
        for ch in line.unicodeScalars {
            if ch == " " || ch == "\t" { n += 1 } else { break }
        }
        return n
    }
}
