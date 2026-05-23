import Foundation

/// Parsed output of a `tools/*.js` file's `const META = { ... }` declaration.
///
/// The parser deliberately implements a strict subset of JavaScript object
/// literals — enough to cover what a skill author would reasonably write, but
/// not a full JS expression evaluator. No function calls, no template strings,
/// no spread operators, no computed property names.
struct ParsedToolMeta: Hashable {
    var name: String
    var description: String
    var parameters: [ParsedToolParam]

    /// The 1-based line range the `META = { ... }` declaration occupied in the
    /// source. Used for error reporting.
    var metaLineRange: ClosedRange<Int>
}

struct ParsedToolParam: Hashable {
    var name: String
    var type: String
    var required: Bool
    var description: String?
    var enumValues: [String]?
}

enum JSMetaError: Error, CustomStringConvertible, Hashable {
    case notFound
    case unterminated(line: Int)
    case unexpected(line: Int, reason: String)
    case missingField(line: Int, field: String)
    case wrongType(line: Int, field: String, expected: String)

    var description: String {
        switch self {
        case .notFound: return "No `const META = {...}` declaration found"
        case .unterminated(let line): return "Unterminated value starting at line \(line)"
        case .unexpected(let line, let r): return "Unexpected token at line \(line): \(r)"
        case .missingField(let line, let f): return "Missing required field `\(f)` near line \(line)"
        case .wrongType(let line, let f, let ex): return "Field `\(f)` near line \(line) is not a \(ex)"
        }
    }
}

/// One-shot parser. Create, call `parse()`, discard.
///
/// Walks a tiny JS value grammar: `object | array | string | number | bool | null`.
/// Identifiers are accepted as object keys (bare keys). Both `"str"` and `'str'`
/// are accepted. Trailing commas are tolerated. Line comments (`// ...`) and
/// block comments (`/* ... */`) are skipped.
final class SkillJSMetaParser {

    // MARK: - Public entry point

    /// Extract the `META = { ... }` declaration from a `tools/*.js` file and
    /// parse it into a `ParsedToolMeta`.
    static func parse(_ source: String) throws -> ParsedToolMeta {
        guard let region = findMetaRegion(in: source) else {
            throw JSMetaError.notFound
        }
        let parser = SkillJSMetaParser(source: source, region: region)
        let obj = try parser.parseObject()
        try parser.skipTrivia()
        // Optional trailing semicolon
        if parser.index < region.upperBound, source[parser.index] == ";" {
            parser.advance()
        }

        let startLine = lineNumber(of: region.lowerBound, in: source)
        let endLine = lineNumber(of: region.upperBound, in: source)
        let lineRange = startLine...max(startLine, endLine)

        return try buildMeta(from: obj, lineRange: lineRange)
    }

    /// Return the JS body text that follows the `META = { ... };` declaration,
    /// with any leading whitespace trimmed. If no META is found, returns the
    /// full source.
    ///
    /// Used by `SkillPackage.parse` to populate `ParsedSkillTool.body` — what
    /// gets stored in `SkillToolDefinition.implementation` and executed when
    /// the LLM calls `skill_<slug>_<tool>`.
    static func bodyAfterMeta(_ source: String) -> String {
        guard let region = findMetaRegion(in: source) else { return source }
        var idx = region.upperBound
        while idx < source.endIndex {
            let ch = source[idx]
            if ch.isWhitespace || ch == ";" {
                idx = source.index(after: idx)
            } else {
                break
            }
        }
        return String(source[idx...])
    }

    // MARK: - Instance state (single-shot parser)

    private let source: String
    private let region: Range<String.Index>
    private var index: String.Index

    private init(source: String, region: Range<String.Index>) {
        self.source = source
        self.region = region
        self.index = region.lowerBound
    }

    private var isAtEnd: Bool { index >= region.upperBound }

    private func advance() {
        if !isAtEnd { index = source.index(after: index) }
    }

    private func peek() -> Character? {
        isAtEnd ? nil : source[index]
    }

    // MARK: - Value grammar

    /// Minimal JS value as recovered by the parser.
    indirect enum Value: Hashable {
        case string(String, line: Int)
        case number(Double, line: Int)
        case bool(Bool, line: Int)
        case null(line: Int)
        case array([Value], line: Int)
        case object([ObjectEntry], line: Int)

        var line: Int {
            switch self {
            case .string(_, let l), .number(_, let l), .bool(_, let l), .null(let l),
                 .array(_, let l), .object(_, let l):
                return l
            }
        }
    }

    /// One key/value pair inside an object literal. Modeled as a named
    /// struct rather than a tuple so the enclosing `Value` enum can
    /// synthesize `Hashable` (Swift tuples don't conform).
    struct ObjectEntry: Hashable {
        let key: String
        let keyLine: Int
        let value: Value
    }

    private func parseValue() throws -> Value {
        try skipTrivia()
        guard let c = peek() else {
            throw JSMetaError.unexpected(line: currentLine(), reason: "Unexpected end of META literal")
        }
        switch c {
        case "{": return try parseObject()
        case "[": return try parseArray()
        case "\"", "'": return try parseString()
        case "-", "0"..."9": return try parseNumber()
        case "t", "f", "n":
            return try parseKeyword()
        default:
            throw JSMetaError.unexpected(line: currentLine(), reason: "Unexpected character `\(c)`")
        }
    }

    private func parseObject() throws -> Value {
        try skipTrivia()
        let startLine = currentLine()
        guard peek() == "{" else {
            throw JSMetaError.unexpected(line: startLine, reason: "Expected `{`")
        }
        advance()
        var entries: [ObjectEntry] = []
        while true {
            try skipTrivia()
            if peek() == "}" {
                advance()
                return .object(entries, line: startLine)
            }
            let keyLine = currentLine()
            let key = try parseKey()
            try skipTrivia()
            guard peek() == ":" else {
                throw JSMetaError.unexpected(line: currentLine(), reason: "Expected `:` after key `\(key)`")
            }
            advance()
            let value = try parseValue()
            entries.append(ObjectEntry(key: key, keyLine: keyLine, value: value))
            try skipTrivia()
            if peek() == "," {
                advance()
                continue
            }
            try skipTrivia()
            if peek() == "}" {
                advance()
                return .object(entries, line: startLine)
            }
            throw JSMetaError.unexpected(line: currentLine(), reason: "Expected `,` or `}` in object")
        }
    }

    private func parseArray() throws -> Value {
        try skipTrivia()
        let startLine = currentLine()
        guard peek() == "[" else {
            throw JSMetaError.unexpected(line: startLine, reason: "Expected `[`")
        }
        advance()
        var items: [Value] = []
        while true {
            try skipTrivia()
            if peek() == "]" {
                advance()
                return .array(items, line: startLine)
            }
            let value = try parseValue()
            items.append(value)
            try skipTrivia()
            if peek() == "," {
                advance()
                continue
            }
            try skipTrivia()
            if peek() == "]" {
                advance()
                return .array(items, line: startLine)
            }
            throw JSMetaError.unexpected(line: currentLine(), reason: "Expected `,` or `]` in array")
        }
    }

    private func parseKey() throws -> String {
        try skipTrivia()
        guard let c = peek() else {
            throw JSMetaError.unexpected(line: currentLine(), reason: "Expected key")
        }
        if c == "\"" || c == "'" {
            if case .string(let s, _) = try parseString() { return s }
        }
        // Bare identifier
        var ident = ""
        while let ch = peek(), ch.isLetter || ch.isNumber || ch == "_" || ch == "$" {
            ident.append(ch)
            advance()
        }
        if ident.isEmpty {
            throw JSMetaError.unexpected(line: currentLine(), reason: "Expected identifier or quoted key")
        }
        return ident
    }

    private func parseString() throws -> Value {
        let startLine = currentLine()
        guard let quote = peek(), quote == "\"" || quote == "'" else {
            throw JSMetaError.unexpected(line: startLine, reason: "Expected string")
        }
        advance()
        var out = ""
        while let c = peek() {
            if c == quote {
                advance()
                return .string(out, line: startLine)
            }
            if c == "\\" {
                advance()
                guard let esc = peek() else {
                    throw JSMetaError.unterminated(line: startLine)
                }
                switch esc {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                case "\\": out.append("\\")
                case "\"": out.append("\"")
                case "'": out.append("'")
                case "/": out.append("/")
                default: out.append(esc)
                }
                advance()
                continue
            }
            if c == "\n" {
                // Unterminated string — JS strings cannot span raw newlines.
                throw JSMetaError.unterminated(line: startLine)
            }
            out.append(c)
            advance()
        }
        throw JSMetaError.unterminated(line: startLine)
    }

    private func parseNumber() throws -> Value {
        let startLine = currentLine()
        var literal = ""
        if peek() == "-" { literal.append("-"); advance() }
        while let c = peek(), c.isNumber || c == "." || c == "e" || c == "E" || c == "+" || c == "-" {
            literal.append(c)
            advance()
        }
        guard let value = Double(literal) else {
            throw JSMetaError.unexpected(line: startLine, reason: "Invalid number literal `\(literal)`")
        }
        return .number(value, line: startLine)
    }

    private func parseKeyword() throws -> Value {
        let startLine = currentLine()
        let remaining = source[index..<region.upperBound]
        if remaining.hasPrefix("true") {
            for _ in 0..<4 { advance() }
            return .bool(true, line: startLine)
        }
        if remaining.hasPrefix("false") {
            for _ in 0..<5 { advance() }
            return .bool(false, line: startLine)
        }
        if remaining.hasPrefix("null") {
            for _ in 0..<4 { advance() }
            return .null(line: startLine)
        }
        throw JSMetaError.unexpected(line: startLine, reason: "Expected `true`, `false`, or `null`")
    }

    // MARK: - Trivia (whitespace + comments)

    fileprivate func skipTrivia() throws {
        while let c = peek() {
            if c.isWhitespace { advance(); continue }
            if c == "/" {
                let after = source.index(after: index)
                if after < region.upperBound {
                    if source[after] == "/" {
                        // Line comment
                        while let nc = peek(), nc != "\n" { advance() }
                        continue
                    }
                    if source[after] == "*" {
                        // Block comment
                        advance(); advance()
                        while !isAtEnd {
                            if peek() == "*" {
                                advance()
                                if peek() == "/" { advance(); break }
                            } else {
                                advance()
                            }
                        }
                        continue
                    }
                }
                return
            }
            return
        }
    }

    // MARK: - Line tracking

    private func currentLine() -> Int {
        Self.lineNumber(of: index, in: source)
    }

    private static func lineNumber(of idx: String.Index, in source: String) -> Int {
        var line = 1
        var i = source.startIndex
        while i < idx && i < source.endIndex {
            if source[i] == "\n" { line += 1 }
            i = source.index(after: i)
        }
        return line
    }

    // MARK: - Declaration discovery

    /// Locate the braced body of a `const META = { ... }` / `let META = { ... }` /
    /// `var META = { ... }` declaration. Matches the first occurrence at the
    /// top of the file that isn't preceded by a comment-only line.
    private static func findMetaRegion(in source: String) -> Range<String.Index>? {
        // Accept any of: `const META`, `let META`, `var META`. Tolerate surrounding
        // whitespace. We rely on the author putting the META block near the top,
        // which is the authoring convention.
        let patterns = ["const META", "let META", "var META", "META"]
        var searchStart = source.startIndex
        while searchStart < source.endIndex {
            // Find the next `META` occurrence.
            var matchRange: Range<String.Index>? = nil
            for p in patterns {
                if let r = source.range(of: p, range: searchStart..<source.endIndex) {
                    if matchRange == nil || r.lowerBound < matchRange!.lowerBound {
                        matchRange = r
                    }
                }
            }
            guard let m = matchRange else { return nil }

            // Skip from after the match to find `=`
            var i = m.upperBound
            while i < source.endIndex, source[i].isWhitespace { i = source.index(after: i) }
            guard i < source.endIndex, source[i] == "=" else {
                searchStart = m.upperBound
                continue
            }
            i = source.index(after: i)
            while i < source.endIndex, source[i].isWhitespace { i = source.index(after: i) }
            guard i < source.endIndex, source[i] == "{" else {
                searchStart = m.upperBound
                continue
            }

            // Match balanced braces, respecting strings and comments
            let start = i
            var depth = 0
            var pos = start
            var inString: Character? = nil
            var inLineComment = false
            var inBlockComment = false
            while pos < source.endIndex {
                let ch = source[pos]
                if inLineComment {
                    if ch == "\n" { inLineComment = false }
                    pos = source.index(after: pos)
                    continue
                }
                if inBlockComment {
                    if ch == "*", source.index(after: pos) < source.endIndex, source[source.index(after: pos)] == "/" {
                        pos = source.index(pos, offsetBy: 2)
                        inBlockComment = false
                    } else {
                        pos = source.index(after: pos)
                    }
                    continue
                }
                if let q = inString {
                    if ch == "\\" {
                        pos = source.index(after: pos)
                        if pos < source.endIndex { pos = source.index(after: pos) }
                        continue
                    }
                    if ch == q { inString = nil }
                    pos = source.index(after: pos)
                    continue
                }
                if ch == "\"" || ch == "'" { inString = ch; pos = source.index(after: pos); continue }
                if ch == "/", source.index(after: pos) < source.endIndex {
                    let next = source[source.index(after: pos)]
                    if next == "/" { inLineComment = true; pos = source.index(pos, offsetBy: 2); continue }
                    if next == "*" { inBlockComment = true; pos = source.index(pos, offsetBy: 2); continue }
                }
                if ch == "{" { depth += 1 }
                if ch == "}" {
                    depth -= 1
                    if depth == 0 {
                        let end = source.index(after: pos)
                        return start..<end
                    }
                }
                pos = source.index(after: pos)
            }
            return nil
        }
        return nil
    }

    // MARK: - Semantic binding

    /// Convert the untyped `Value` tree rooted at an object literal into a
    /// `ParsedToolMeta`. The caller supplies the line range spanned by the
    /// original `META = { ... }` declaration.
    private static func buildMeta(from value: Value, lineRange: ClosedRange<Int>) throws -> ParsedToolMeta {
        guard case .object(let entries, let objLine) = value else {
            throw JSMetaError.wrongType(line: value.line, field: "META", expected: "object")
        }
        // Last-write-wins on duplicate keys — matches JS semantics and avoids
        // the crash that `Dictionary(uniqueKeysWithValues:)` would cause.
        var dict: [String: ObjectEntry] = [:]
        for entry in entries { dict[entry.key] = entry }

        guard let nameEntry = dict["name"] else {
            throw JSMetaError.missingField(line: objLine, field: "name")
        }
        guard case .string(let name, _) = nameEntry.value else {
            throw JSMetaError.wrongType(line: nameEntry.keyLine, field: "name", expected: "string")
        }

        guard let descEntry = dict["description"] else {
            throw JSMetaError.missingField(line: objLine, field: "description")
        }
        guard case .string(let description, _) = descEntry.value else {
            throw JSMetaError.wrongType(line: descEntry.keyLine, field: "description", expected: "string")
        }

        var params: [ParsedToolParam] = []
        if let paramsEntry = dict["parameters"] {
            guard case .array(let arr, _) = paramsEntry.value else {
                throw JSMetaError.wrongType(line: paramsEntry.keyLine, field: "parameters", expected: "array")
            }
            for item in arr {
                params.append(try buildParam(from: item))
            }
        }
        return ParsedToolMeta(name: name, description: description, parameters: params, metaLineRange: lineRange)
    }

    private static func buildParam(from value: Value) throws -> ParsedToolParam {
        guard case .object(let entries, let objLine) = value else {
            throw JSMetaError.wrongType(line: value.line, field: "parameter", expected: "object")
        }
        var dict: [String: ObjectEntry] = [:]
        for entry in entries { dict[entry.key] = entry }

        guard let nameEntry = dict["name"] else {
            throw JSMetaError.missingField(line: objLine, field: "parameter.name")
        }
        guard case .string(let pName, _) = nameEntry.value else {
            throw JSMetaError.wrongType(line: nameEntry.keyLine, field: "parameter.name", expected: "string")
        }

        guard let typeEntry = dict["type"] else {
            throw JSMetaError.missingField(line: objLine, field: "parameter.type")
        }
        guard case .string(let pType, _) = typeEntry.value else {
            throw JSMetaError.wrongType(line: typeEntry.keyLine, field: "parameter.type", expected: "string")
        }

        var required = true
        if let r = dict["required"] {
            guard case .bool(let b, _) = r.value else {
                throw JSMetaError.wrongType(line: r.keyLine, field: "parameter.required", expected: "boolean")
            }
            required = b
        }

        var description: String? = nil
        if let d = dict["description"] {
            guard case .string(let s, _) = d.value else {
                throw JSMetaError.wrongType(line: d.keyLine, field: "parameter.description", expected: "string")
            }
            description = s
        }

        var enumValues: [String]? = nil
        if let e = dict["enum"] {
            guard case .array(let arr, _) = e.value else {
                throw JSMetaError.wrongType(line: e.keyLine, field: "parameter.enum", expected: "array")
            }
            var vals: [String] = []
            for item in arr {
                guard case .string(let s, _) = item else {
                    throw JSMetaError.wrongType(line: item.line, field: "parameter.enum[]", expected: "string")
                }
                vals.append(s)
            }
            enumValues = vals
        }

        return ParsedToolParam(
            name: pName,
            type: pType,
            required: required,
            description: description,
            enumValues: enumValues
        )
    }
}
