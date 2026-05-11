import SwiftUI

struct SyntaxHighlighter {

    // MARK: - Public API

    static func highlight(code: String, language: String) -> AttributedString {
        let tokens = tokenize(code: code, language: language)
        var result = AttributedString()
        for (text, type) in tokens {
            var segment = AttributedString(text)
            segment.foregroundColor = Color(uiColor(for: type))
            result.append(segment)
        }
        return result
    }

    static func tokenize(code: String, language: String) -> [(String, TokenType)] {
        tokenize(code, lang: resolveLanguage(language.lowercased()))
    }

    static func uiColor(for type: TokenType) -> UIColor {
        switch type {
        case .plain:
            return .label
        case .keyword:
            return UIColor { $0.userInterfaceStyle == .dark
                ? UIColor(red: 0.85, green: 0.38, blue: 0.58, alpha: 1)
                : UIColor(red: 0.55, green: 0.14, blue: 0.52, alpha: 1) }
        case .string:
            return UIColor { $0.userInterfaceStyle == .dark
                ? UIColor(red: 0.88, green: 0.40, blue: 0.36, alpha: 1)
                : UIColor(red: 0.72, green: 0.12, blue: 0.11, alpha: 1) }
        case .comment:
            return UIColor { $0.userInterfaceStyle == .dark
                ? UIColor(red: 0.44, green: 0.50, blue: 0.56, alpha: 1)
                : UIColor(red: 0.40, green: 0.45, blue: 0.50, alpha: 1) }
        case .number:
            return UIColor { $0.userInterfaceStyle == .dark
                ? UIColor(red: 0.75, green: 0.68, blue: 0.39, alpha: 1)
                : UIColor(red: 0.16, green: 0.05, blue: 0.69, alpha: 1) }
        case .type:
            return UIColor { $0.userInterfaceStyle == .dark
                ? UIColor(red: 0.40, green: 0.75, blue: 0.87, alpha: 1)
                : UIColor(red: 0.06, green: 0.32, blue: 0.45, alpha: 1) }
        case .attribute:
            return UIColor { $0.userInterfaceStyle == .dark
                ? UIColor(red: 0.72, green: 0.55, blue: 0.40, alpha: 1)
                : UIColor(red: 0.50, green: 0.30, blue: 0.05, alpha: 1) }
        case .property:
            return UIColor { $0.userInterfaceStyle == .dark
                ? UIColor(red: 0.42, green: 0.65, blue: 0.58, alpha: 1)
                : UIColor(red: 0.20, green: 0.40, blue: 0.42, alpha: 1) }
        }
    }

    // MARK: - Token Types

    enum TokenType {
        case plain
        case keyword
        case string
        case comment
        case number
        case type
        case attribute
        case property
    }

    // MARK: - Language Definition

    struct LanguageDef {
        var lineComment: String?
        var blockCommentStart: String?
        var blockCommentEnd: String?
        var keywords: Set<String>
        var typeKeywords: Set<String>
        var stringDelimiters: [Character]
        var supportsTripleQuote: Bool
        var hashStringLiterals: Bool
        var attributePrefix: Character?
    }

    // MARK: - Tokenizer

    static func tokenize(_ code: String, lang: LanguageDef) -> [(String, TokenType)] {
        var tokens: [(String, TokenType)] = []
        let chars = Array(code)
        var i = 0

        while i < chars.count {
            // Block comment
            if let start = lang.blockCommentStart, let end = lang.blockCommentEnd {
                let startChars = Array(start)
                if matchPrefix(chars, at: i, prefix: startChars) {
                    let begin = i
                    i += startChars.count
                    let endChars = Array(end)
                    while i < chars.count {
                        if matchPrefix(chars, at: i, prefix: endChars) {
                            i += endChars.count
                            break
                        }
                        i += 1
                    }
                    tokens.append((String(chars[begin..<i]), .comment))
                    continue
                }
            }

            // Line comment
            if let lc = lang.lineComment {
                let lcChars = Array(lc)
                if matchPrefix(chars, at: i, prefix: lcChars) {
                    let begin = i
                    while i < chars.count && chars[i] != "\n" {
                        i += 1
                    }
                    tokens.append((String(chars[begin..<i]), .comment))
                    continue
                }
            }

            // Triple-quoted strings
            if lang.supportsTripleQuote {
                if i + 2 < chars.count {
                    let tripleDouble = chars[i] == "\"" && chars[i+1] == "\"" && chars[i+2] == "\""
                    let tripleSingle = chars[i] == "'" && chars[i+1] == "'" && chars[i+2] == "'"
                    if tripleDouble || tripleSingle {
                        let delim: [Character] = tripleDouble ? ["\"","\"","\""] : ["'","'","'"]
                        let begin = i
                        i += 3
                        var foundTerminator = false
                        while i + 2 < chars.count {
                            if chars[i] == delim[0] && chars[i+1] == delim[1] && chars[i+2] == delim[2] {
                                i += 3
                                foundTerminator = true
                                break
                            }
                            if chars[i] == "\\" { i += 1 }
                            i += 1
                        }
                        if !foundTerminator { i = chars.count }
                        tokens.append((String(chars[begin..<i]), .string))
                        continue
                    }
                }
            }

            // String literals
            if lang.stringDelimiters.contains(chars[i]) {
                let delim = chars[i]
                let begin = i
                i += 1
                while i < chars.count && chars[i] != delim {
                    if chars[i] == "\\" {
                        i += 1
                        if i >= chars.count { break }
                    }
                    if chars[i] == "\n" && delim != "`" { break }
                    i += 1
                }
                if i < chars.count && chars[i] == delim { i += 1 }
                tokens.append((String(chars[begin..<i]), .string))
                continue
            }

            // Swift raw strings: #"..."#
            if lang.hashStringLiterals && chars[i] == "#" && i + 1 < chars.count && chars[i+1] == "\"" {
                let begin = i
                i += 2
                while i < chars.count {
                    if chars[i] == "\"" && i + 1 < chars.count && chars[i+1] == "#" {
                        i += 2
                        break
                    }
                    i += 1
                }
                tokens.append((String(chars[begin..<i]), .string))
                continue
            }

            // Attribute prefix (@ for Swift/Java/Python, # for C preprocessor)
            if let prefix = lang.attributePrefix, chars[i] == prefix {
                if i + 1 < chars.count && (chars[i+1].isLetter || chars[i+1] == "_") {
                    let begin = i
                    i += 1
                    while i < chars.count && (chars[i].isLetter || chars[i].isNumber || chars[i] == "_") {
                        i += 1
                    }
                    tokens.append((String(chars[begin..<i]), .attribute))
                    continue
                }
            }

            // Numbers
            if chars[i].isNumber || (chars[i] == "." && i + 1 < chars.count && chars[i+1].isNumber) {
                let begin = i
                if chars[i] == "0" && i + 1 < chars.count && (chars[i+1] == "x" || chars[i+1] == "X" || chars[i+1] == "b" || chars[i+1] == "B" || chars[i+1] == "o" || chars[i+1] == "O") {
                    i += 2
                    while i < chars.count && (chars[i].isHexDigit || chars[i] == "_") { i += 1 }
                } else {
                    while i < chars.count && (chars[i].isNumber || chars[i] == "." || chars[i] == "_") { i += 1 }
                    if i < chars.count && (chars[i] == "e" || chars[i] == "E") {
                        i += 1
                        if i < chars.count && (chars[i] == "+" || chars[i] == "-") { i += 1 }
                        while i < chars.count && chars[i].isNumber { i += 1 }
                    }
                }
                // Type suffixes like f, d, L, u, etc.
                if i < chars.count && (chars[i] == "f" || chars[i] == "F" || chars[i] == "d" || chars[i] == "D" || chars[i] == "L" || chars[i] == "l" || chars[i] == "u" || chars[i] == "U") {
                    i += 1
                }
                tokens.append((String(chars[begin..<i]), .number))
                continue
            }

            // Identifiers / keywords
            if chars[i].isLetter || chars[i] == "_" || chars[i] == "$" {
                let begin = i
                while i < chars.count && (chars[i].isLetter || chars[i].isNumber || chars[i] == "_" || chars[i] == "$") {
                    i += 1
                }
                let word = String(chars[begin..<i])
                if lang.keywords.contains(word) {
                    tokens.append((word, .keyword))
                } else if lang.typeKeywords.contains(word) || (word.first?.isUppercase == true && word.count > 1 && word.contains(where: { $0.isLowercase })) {
                    tokens.append((word, .type))
                } else {
                    // Check if followed by ( → treat as function-like (but keep as .plain for simplicity)
                    tokens.append((word, .plain))
                }
                continue
            }

            // Everything else
            tokens.append((String(chars[i]), .plain))
            i += 1
        }

        return tokens
    }

    // MARK: - Helpers

    private static func matchPrefix(_ chars: [Character], at index: Int, prefix: [Character]) -> Bool {
        guard index + prefix.count <= chars.count else { return false }
        for j in 0..<prefix.count {
            if chars[index + j] != prefix[j] { return false }
        }
        return true
    }


    // MARK: - Language Definitions

    private static func resolveLanguage(_ name: String) -> LanguageDef {
        switch name {
        case "swift":
            return swiftLang
        case "python", "py":
            return pythonLang
        case "javascript", "js", "jsx":
            return javascriptLang
        case "typescript", "ts", "tsx":
            return typescriptLang
        case "json":
            return jsonLang
        case "bash", "sh", "shell", "zsh":
            return bashLang
        case "html", "xml", "svg":
            return htmlLang
        case "css", "scss", "less":
            return cssLang
        case "sql":
            return sqlLang
        case "go", "golang":
            return goLang
        case "rust", "rs":
            return rustLang
        case "ruby", "rb":
            return rubyLang
        case "java":
            return javaLang
        case "kotlin", "kt", "kts":
            return kotlinLang
        case "c":
            return cLang
        case "cpp", "c++", "cxx", "cc":
            return cppLang
        case "yaml", "yml":
            return yamlLang
        case "lua":
            return luaLang
        case "php":
            return phpLang
        case "r":
            return rLang
        case "dart":
            return dartLang
        case "scala":
            return scalaLang
        case "objc", "objective-c", "objectivec", "m":
            return objcLang
        case "perl", "pl":
            return perlLang
        case "markdown", "md":
            return markdownLang
        default:
            return genericLang
        }
    }

    // MARK: - Language Definitions (Static)

    private static let swiftLang = LanguageDef(
        lineComment: "//",
        blockCommentStart: "/*", blockCommentEnd: "*/",
        keywords: ["import", "let", "var", "func", "class", "struct", "enum", "protocol",
                    "extension", "if", "else", "guard", "switch", "case", "default", "for",
                    "while", "repeat", "do", "return", "throw", "throws", "try", "catch",
                    "async", "await", "in", "where", "is", "as", "self", "Self", "super",
                    "init", "deinit", "typealias", "associatedtype", "static", "private",
                    "fileprivate", "internal", "public", "open", "final", "override",
                    "mutating", "nonmutating", "lazy", "weak", "unowned", "convenience",
                    "required", "optional", "some", "any", "nil", "true", "false", "inout",
                    "break", "continue", "fallthrough", "defer", "actor", "nonisolated",
                    "isolated", "consuming", "borrowing", "willSet", "didSet", "get", "set",
                    "subscript", "operator", "precedencegroup", "macro", "package"],
        typeKeywords: ["Int", "String", "Bool", "Double", "Float", "Array", "Dictionary",
                       "Set", "Optional", "Result", "Void", "Any", "AnyObject", "Error",
                       "Never", "Data", "URL", "Date", "UUID", "CGFloat", "View", "some"],
        stringDelimiters: ["\""],
        supportsTripleQuote: true,
        hashStringLiterals: true,
        attributePrefix: "@"
    )

    private static let pythonLang = LanguageDef(
        lineComment: "#",
        blockCommentStart: nil, blockCommentEnd: nil,
        keywords: ["and", "as", "assert", "async", "await", "break", "class", "continue",
                    "def", "del", "elif", "else", "except", "finally", "for", "from",
                    "global", "if", "import", "in", "is", "lambda", "nonlocal", "not",
                    "or", "pass", "raise", "return", "try", "while", "with", "yield",
                    "True", "False", "None", "self", "cls", "match", "case", "type"],
        typeKeywords: ["int", "str", "float", "bool", "list", "dict", "tuple", "set",
                       "bytes", "object", "type", "Exception", "TypeError", "ValueError"],
        stringDelimiters: ["\"", "'"],
        supportsTripleQuote: true,
        hashStringLiterals: false,
        attributePrefix: "@"
    )

    private static let javascriptLang = LanguageDef(
        lineComment: "//",
        blockCommentStart: "/*", blockCommentEnd: "*/",
        keywords: ["break", "case", "catch", "class", "const", "continue", "debugger",
                    "default", "delete", "do", "else", "export", "extends", "finally",
                    "for", "function", "if", "import", "in", "instanceof", "let", "new",
                    "of", "return", "super", "switch", "this", "throw", "try", "typeof",
                    "var", "void", "while", "with", "yield", "async", "await", "from",
                    "static", "get", "set", "true", "false", "null", "undefined", "NaN"],
        typeKeywords: ["Array", "Object", "String", "Number", "Boolean", "Symbol",
                       "Map", "Set", "Promise", "Error", "RegExp", "Date", "JSON", "Math"],
        stringDelimiters: ["\"", "'", "`"],
        supportsTripleQuote: false,
        hashStringLiterals: false,
        attributePrefix: nil
    )

    private static let typescriptLang = LanguageDef(
        lineComment: "//",
        blockCommentStart: "/*", blockCommentEnd: "*/",
        keywords: javascriptLang.keywords.union(
            ["type", "interface", "enum", "namespace", "module", "declare", "abstract",
             "implements", "private", "protected", "public", "readonly", "as", "is",
             "keyof", "infer", "extends", "never", "unknown", "any", "asserts",
             "override", "satisfies"]),
        typeKeywords: javascriptLang.typeKeywords.union(
            ["Partial", "Required", "Record", "Pick", "Omit", "Exclude", "Extract",
             "ReturnType", "Awaited", "ReadonlyArray", "Readonly"]),
        stringDelimiters: ["\"", "'", "`"],
        supportsTripleQuote: false,
        hashStringLiterals: false,
        attributePrefix: "@"
    )

    private static let jsonLang = LanguageDef(
        lineComment: nil,
        blockCommentStart: nil, blockCommentEnd: nil,
        keywords: ["true", "false", "null"],
        typeKeywords: [],
        stringDelimiters: ["\""],
        supportsTripleQuote: false,
        hashStringLiterals: false,
        attributePrefix: nil
    )

    private static let bashLang = LanguageDef(
        lineComment: "#",
        blockCommentStart: nil, blockCommentEnd: nil,
        keywords: ["if", "then", "else", "elif", "fi", "for", "while", "do", "done",
                    "case", "esac", "in", "function", "return", "local", "export",
                    "source", "alias", "unalias", "set", "unset", "shift", "exit",
                    "exec", "eval", "readonly", "declare", "typeset", "select",
                    "until", "break", "continue", "trap", "true", "false"],
        typeKeywords: [],
        stringDelimiters: ["\"", "'"],
        supportsTripleQuote: false,
        hashStringLiterals: false,
        attributePrefix: nil
    )

    private static let htmlLang = LanguageDef(
        lineComment: nil,
        blockCommentStart: "<!--", blockCommentEnd: "-->",
        keywords: ["DOCTYPE", "html", "head", "body", "div", "span", "a", "p", "h1",
                    "h2", "h3", "h4", "h5", "h6", "img", "input", "button", "form",
                    "table", "tr", "td", "th", "ul", "ol", "li", "nav", "header",
                    "footer", "section", "article", "aside", "main", "script", "style",
                    "link", "meta", "title", "class", "id", "src", "href", "type",
                    "value", "name", "content", "rel", "charset"],
        typeKeywords: [],
        stringDelimiters: ["\"", "'"],
        supportsTripleQuote: false,
        hashStringLiterals: false,
        attributePrefix: nil
    )

    private static let cssLang = LanguageDef(
        lineComment: nil,
        blockCommentStart: "/*", blockCommentEnd: "*/",
        keywords: ["import", "media", "keyframes", "font-face", "charset", "supports",
                    "important", "inherit", "initial", "unset", "revert", "none", "auto",
                    "flex", "grid", "block", "inline", "relative", "absolute", "fixed",
                    "sticky", "static", "hidden", "visible", "solid", "dashed", "dotted",
                    "center", "left", "right", "top", "bottom"],
        typeKeywords: [],
        stringDelimiters: ["\"", "'"],
        supportsTripleQuote: false,
        hashStringLiterals: false,
        attributePrefix: nil
    )

    private static let sqlLang = LanguageDef(
        lineComment: "--",
        blockCommentStart: "/*", blockCommentEnd: "*/",
        keywords: ["select", "from", "where", "and", "or", "not", "in", "is", "null",
                    "like", "between", "exists", "insert", "into", "values", "update",
                    "set", "delete", "create", "drop", "alter", "table", "index", "view",
                    "database", "schema", "grant", "revoke", "join", "inner", "outer",
                    "left", "right", "full", "cross", "on", "as", "distinct", "group",
                    "by", "order", "having", "limit", "offset", "union", "all", "case",
                    "when", "then", "else", "end", "begin", "commit", "rollback",
                    "primary", "key", "foreign", "references", "constraint", "default",
                    "not", "null", "unique", "check", "asc", "desc", "true", "false",
                    "SELECT", "FROM", "WHERE", "AND", "OR", "NOT", "IN", "IS", "NULL",
                    "LIKE", "BETWEEN", "EXISTS", "INSERT", "INTO", "VALUES", "UPDATE",
                    "SET", "DELETE", "CREATE", "DROP", "ALTER", "TABLE", "INDEX", "VIEW",
                    "JOIN", "INNER", "OUTER", "LEFT", "RIGHT", "ON", "AS", "DISTINCT",
                    "GROUP", "BY", "ORDER", "HAVING", "LIMIT", "OFFSET", "UNION", "ALL",
                    "CASE", "WHEN", "THEN", "ELSE", "END", "BEGIN", "COMMIT", "PRIMARY",
                    "KEY", "FOREIGN", "REFERENCES", "DEFAULT", "UNIQUE", "ASC", "DESC"],
        typeKeywords: ["INT", "INTEGER", "BIGINT", "SMALLINT", "FLOAT", "DOUBLE",
                       "DECIMAL", "NUMERIC", "VARCHAR", "CHAR", "TEXT", "BLOB", "DATE",
                       "DATETIME", "TIMESTAMP", "BOOLEAN", "SERIAL",
                       "int", "integer", "bigint", "smallint", "float", "double",
                       "decimal", "numeric", "varchar", "char", "text", "blob", "date",
                       "datetime", "timestamp", "boolean", "serial"],
        stringDelimiters: ["\"", "'"],
        supportsTripleQuote: false,
        hashStringLiterals: false,
        attributePrefix: nil
    )

    private static let goLang = LanguageDef(
        lineComment: "//",
        blockCommentStart: "/*", blockCommentEnd: "*/",
        keywords: ["break", "case", "chan", "const", "continue", "default", "defer",
                    "else", "fallthrough", "for", "func", "go", "goto", "if", "import",
                    "interface", "map", "package", "range", "return", "select", "struct",
                    "switch", "type", "var", "nil", "true", "false", "iota", "append",
                    "cap", "close", "copy", "delete", "len", "make", "new", "panic",
                    "print", "println", "recover"],
        typeKeywords: ["int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16",
                       "uint32", "uint64", "float32", "float64", "complex64", "complex128",
                       "string", "bool", "byte", "rune", "error", "any", "comparable"],
        stringDelimiters: ["\"", "'", "`"],
        supportsTripleQuote: false,
        hashStringLiterals: false,
        attributePrefix: nil
    )

    private static let rustLang = LanguageDef(
        lineComment: "//",
        blockCommentStart: "/*", blockCommentEnd: "*/",
        keywords: ["as", "async", "await", "break", "const", "continue", "crate", "dyn",
                    "else", "enum", "extern", "false", "fn", "for", "if", "impl", "in",
                    "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return",
                    "self", "Self", "static", "struct", "super", "trait", "true", "type",
                    "unsafe", "use", "where", "while", "yield", "macro_rules"],
        typeKeywords: ["i8", "i16", "i32", "i64", "i128", "isize", "u8", "u16", "u32",
                       "u64", "u128", "usize", "f32", "f64", "bool", "char", "str",
                       "String", "Vec", "Box", "Rc", "Arc", "Option", "Result", "Some",
                       "None", "Ok", "Err", "HashMap", "HashSet"],
        stringDelimiters: ["\""],
        supportsTripleQuote: false,
        hashStringLiterals: false,
        attributePrefix: "#"
    )

    private static let rubyLang = LanguageDef(
        lineComment: "#",
        blockCommentStart: "=begin", blockCommentEnd: "=end",
        keywords: ["alias", "and", "begin", "break", "case", "class", "def", "defined?",
                    "do", "else", "elsif", "end", "ensure", "false", "for", "if", "in",
                    "module", "next", "nil", "not", "or", "redo", "rescue", "retry",
                    "return", "self", "super", "then", "true", "undef", "unless", "until",
                    "when", "while", "yield", "require", "require_relative", "include",
                    "extend", "attr_reader", "attr_writer", "attr_accessor", "puts", "print"],
        typeKeywords: ["Array", "Hash", "String", "Integer", "Float", "Symbol", "Proc",
                       "Lambda", "Regexp", "NilClass", "TrueClass", "FalseClass"],
        stringDelimiters: ["\"", "'"],
        supportsTripleQuote: false,
        hashStringLiterals: false,
        attributePrefix: nil
    )

    private static let javaLang = LanguageDef(
        lineComment: "//",
        blockCommentStart: "/*", blockCommentEnd: "*/",
        keywords: ["abstract", "assert", "boolean", "break", "byte", "case", "catch",
                    "char", "class", "const", "continue", "default", "do", "double",
                    "else", "enum", "extends", "final", "finally", "float", "for",
                    "goto", "if", "implements", "import", "instanceof", "int",
                    "interface", "long", "native", "new", "package", "private",
                    "protected", "public", "return", "short", "static", "strictfp",
                    "super", "switch", "synchronized", "this", "throw", "throws",
                    "transient", "try", "void", "volatile", "while", "true", "false",
                    "null", "var", "yield", "record", "sealed", "permits", "non-sealed"],
        typeKeywords: ["String", "Integer", "Boolean", "Double", "Float", "Long", "Short",
                       "Byte", "Character", "Object", "List", "Map", "Set", "ArrayList",
                       "HashMap", "HashSet", "Optional", "Stream", "Exception", "Throwable"],
        stringDelimiters: ["\"", "'"],
        supportsTripleQuote: true,
        hashStringLiterals: false,
        attributePrefix: "@"
    )

    private static let kotlinLang = LanguageDef(
        lineComment: "//",
        blockCommentStart: "/*", blockCommentEnd: "*/",
        keywords: ["as", "break", "class", "continue", "do", "else", "false", "for",
                    "fun", "if", "in", "interface", "is", "null", "object", "package",
                    "return", "super", "this", "throw", "true", "try", "typealias",
                    "typeof", "val", "var", "when", "while", "by", "catch", "constructor",
                    "delegate", "dynamic", "field", "file", "finally", "get", "import",
                    "init", "param", "property", "receiver", "set", "setparam", "where",
                    "actual", "abstract", "annotation", "companion", "const", "crossinline",
                    "data", "enum", "expect", "external", "final", "infix", "inline",
                    "inner", "internal", "lateinit", "noinline", "open", "operator",
                    "out", "override", "private", "protected", "public", "reified",
                    "sealed", "suspend", "tailrec", "vararg"],
        typeKeywords: ["Int", "Long", "Short", "Byte", "Float", "Double", "Boolean",
                       "Char", "String", "Unit", "Nothing", "Any", "Array", "List",
                       "Map", "Set", "MutableList", "MutableMap", "MutableSet", "Pair"],
        stringDelimiters: ["\"", "'"],
        supportsTripleQuote: true,
        hashStringLiterals: false,
        attributePrefix: "@"
    )

    private static let cLang = LanguageDef(
        lineComment: "//",
        blockCommentStart: "/*", blockCommentEnd: "*/",
        keywords: ["auto", "break", "case", "char", "const", "continue", "default", "do",
                    "double", "else", "enum", "extern", "float", "for", "goto", "if",
                    "inline", "int", "long", "register", "restrict", "return", "short",
                    "signed", "sizeof", "static", "struct", "switch", "typedef", "union",
                    "unsigned", "void", "volatile", "while", "_Bool", "_Complex",
                    "_Imaginary", "NULL", "true", "false"],
        typeKeywords: ["size_t", "int8_t", "int16_t", "int32_t", "int64_t", "uint8_t",
                       "uint16_t", "uint32_t", "uint64_t", "ptrdiff_t", "FILE", "bool"],
        stringDelimiters: ["\"", "'"],
        supportsTripleQuote: false,
        hashStringLiterals: false,
        attributePrefix: "#"
    )

    private static let cppLang = LanguageDef(
        lineComment: "//",
        blockCommentStart: "/*", blockCommentEnd: "*/",
        keywords: cLang.keywords.union(
            ["alignas", "alignof", "and", "and_eq", "asm", "bitand", "bitor", "bool",
             "catch", "class", "compl", "concept", "consteval", "constexpr", "constinit",
             "co_await", "co_return", "co_yield", "decltype", "delete", "dynamic_cast",
             "explicit", "export", "friend", "mutable", "namespace", "new", "noexcept",
             "not", "not_eq", "nullptr", "operator", "or", "or_eq", "private",
             "protected", "public", "reinterpret_cast", "requires", "static_assert",
             "static_cast", "template", "this", "throw", "try", "typeid", "typename",
             "using", "virtual", "wchar_t", "xor", "xor_eq", "override", "final"]),
        typeKeywords: cLang.typeKeywords.union(
            ["string", "vector", "map", "set", "unordered_map", "unordered_set",
             "shared_ptr", "unique_ptr", "weak_ptr", "optional", "variant", "any",
             "tuple", "pair", "array", "span", "string_view", "ostream", "istream"]),
        stringDelimiters: ["\"", "'"],
        supportsTripleQuote: false,
        hashStringLiterals: false,
        attributePrefix: "#"
    )

    private static let yamlLang = LanguageDef(
        lineComment: "#",
        blockCommentStart: nil, blockCommentEnd: nil,
        keywords: ["true", "false", "yes", "no", "on", "off", "null", "~",
                    "True", "False", "Yes", "No", "On", "Off", "Null", "NULL"],
        typeKeywords: [],
        stringDelimiters: ["\"", "'"],
        supportsTripleQuote: false,
        hashStringLiterals: false,
        attributePrefix: nil
    )

    private static let luaLang = LanguageDef(
        lineComment: "--",
        blockCommentStart: "--[[", blockCommentEnd: "]]",
        keywords: ["and", "break", "do", "else", "elseif", "end", "false", "for",
                    "function", "goto", "if", "in", "local", "nil", "not", "or",
                    "repeat", "return", "then", "true", "until", "while",
                    "require", "print", "pairs", "ipairs", "type", "tostring",
                    "tonumber", "error", "pcall", "xpcall", "assert", "select",
                    "next", "rawget", "rawset", "setmetatable", "getmetatable"],
        typeKeywords: ["table", "string", "math", "io", "os", "coroutine", "debug"],
        stringDelimiters: ["\"", "'"],
        supportsTripleQuote: false,
        hashStringLiterals: false,
        attributePrefix: nil
    )

    private static let phpLang = LanguageDef(
        lineComment: "//",
        blockCommentStart: "/*", blockCommentEnd: "*/",
        keywords: ["abstract", "and", "array", "as", "break", "callable", "case", "catch",
                    "class", "clone", "const", "continue", "declare", "default", "die",
                    "do", "echo", "else", "elseif", "empty", "enddeclare", "endfor",
                    "endforeach", "endif", "endswitch", "endwhile", "eval", "exit",
                    "extends", "final", "finally", "fn", "for", "foreach", "function",
                    "global", "goto", "if", "implements", "include", "include_once",
                    "instanceof", "insteadof", "interface", "isset", "list", "match",
                    "namespace", "new", "or", "print", "private", "protected", "public",
                    "readonly", "require", "require_once", "return", "static", "switch",
                    "throw", "trait", "try", "unset", "use", "var", "while", "xor",
                    "yield", "true", "false", "null", "self", "parent"],
        typeKeywords: ["int", "float", "string", "bool", "array", "object", "void",
                       "mixed", "never", "null"],
        stringDelimiters: ["\"", "'"],
        supportsTripleQuote: false,
        hashStringLiterals: false,
        attributePrefix: "#"
    )

    private static let rLang = LanguageDef(
        lineComment: "#",
        blockCommentStart: nil, blockCommentEnd: nil,
        keywords: ["if", "else", "for", "while", "repeat", "in", "next", "break",
                    "return", "function", "TRUE", "FALSE", "NULL", "NA", "Inf", "NaN",
                    "library", "require", "source", "print", "cat"],
        typeKeywords: ["numeric", "character", "logical", "integer", "complex", "raw",
                       "list", "vector", "matrix", "data.frame", "factor"],
        stringDelimiters: ["\"", "'"],
        supportsTripleQuote: false,
        hashStringLiterals: false,
        attributePrefix: nil
    )

    private static let dartLang = LanguageDef(
        lineComment: "//",
        blockCommentStart: "/*", blockCommentEnd: "*/",
        keywords: ["abstract", "as", "assert", "async", "await", "break", "case", "catch",
                    "class", "const", "continue", "covariant", "default", "deferred", "do",
                    "dynamic", "else", "enum", "export", "extends", "extension", "external",
                    "factory", "false", "final", "finally", "for", "get", "hide", "if",
                    "implements", "import", "in", "interface", "is", "late", "library",
                    "mixin", "new", "null", "on", "operator", "part", "required", "rethrow",
                    "return", "sealed", "set", "show", "static", "super", "switch",
                    "sync", "this", "throw", "true", "try", "typedef", "var", "void",
                    "when", "while", "with", "yield"],
        typeKeywords: ["int", "double", "num", "String", "bool", "List", "Map", "Set",
                       "Future", "Stream", "Iterable", "dynamic", "Object", "Function",
                       "Type", "Symbol", "Null", "Never"],
        stringDelimiters: ["\"", "'"],
        supportsTripleQuote: true,
        hashStringLiterals: false,
        attributePrefix: "@"
    )

    private static let scalaLang = LanguageDef(
        lineComment: "//",
        blockCommentStart: "/*", blockCommentEnd: "*/",
        keywords: ["abstract", "case", "catch", "class", "def", "do", "else", "extends",
                    "false", "final", "finally", "for", "forSome", "if", "implicit",
                    "import", "lazy", "match", "new", "null", "object", "override",
                    "package", "private", "protected", "return", "sealed", "super",
                    "this", "throw", "trait", "true", "try", "type", "val", "var",
                    "while", "with", "yield", "given", "using", "enum", "then", "end",
                    "export", "extension", "transparent", "inline", "opaque"],
        typeKeywords: ["Int", "Long", "Short", "Byte", "Float", "Double", "Boolean",
                       "Char", "String", "Unit", "Nothing", "Any", "AnyRef", "AnyVal",
                       "Option", "Some", "None", "List", "Map", "Set", "Seq", "Vector",
                       "Array", "Either", "Left", "Right", "Future", "Try", "Success",
                       "Failure", "Tuple"],
        stringDelimiters: ["\"", "'"],
        supportsTripleQuote: true,
        hashStringLiterals: false,
        attributePrefix: "@"
    )

    private static let objcLang = LanguageDef(
        lineComment: "//",
        blockCommentStart: "/*", blockCommentEnd: "*/",
        keywords: cLang.keywords.union(
            ["id", "Class", "SEL", "IMP", "BOOL", "YES", "NO", "nil", "Nil",
             "self", "super", "in", "out", "inout", "bycopy", "byref", "oneway",
             "property", "synthesize", "dynamic", "optional", "required",
             "interface", "implementation", "protocol", "end", "selector",
             "encode", "synchronized", "autoreleasepool", "try", "catch",
             "throw", "finally", "import", "class", "public", "private",
             "protected", "package", "strong", "weak", "assign", "copy",
             "retain", "nonatomic", "atomic", "readonly", "readwrite",
             "nonnull", "nullable"]),
        typeKeywords: ["NSObject", "NSString", "NSArray", "NSDictionary", "NSNumber",
                       "NSInteger", "NSUInteger", "CGFloat", "NSError", "NSURL",
                       "NSData", "NSDate", "NSMutableArray", "NSMutableDictionary",
                       "NSMutableString", "UIView", "UIViewController"],
        stringDelimiters: ["\""],
        supportsTripleQuote: false,
        hashStringLiterals: false,
        attributePrefix: "@"
    )

    private static let perlLang = LanguageDef(
        lineComment: "#",
        blockCommentStart: "=pod", blockCommentEnd: "=cut",
        keywords: ["my", "our", "local", "sub", "if", "elsif", "else", "unless", "while",
                    "until", "for", "foreach", "do", "last", "next", "redo", "return",
                    "die", "warn", "print", "say", "use", "require", "package", "BEGIN",
                    "END", "eval", "chomp", "chop", "push", "pop", "shift", "unshift",
                    "splice", "grep", "map", "sort", "keys", "values", "exists", "delete",
                    "defined", "undef", "ref", "bless", "qw", "qq", "qr"],
        typeKeywords: [],
        stringDelimiters: ["\"", "'"],
        supportsTripleQuote: false,
        hashStringLiterals: false,
        attributePrefix: nil
    )

    private static let markdownLang = LanguageDef(
        lineComment: nil,
        blockCommentStart: nil, blockCommentEnd: nil,
        keywords: [],
        typeKeywords: [],
        stringDelimiters: [],
        supportsTripleQuote: false,
        hashStringLiterals: false,
        attributePrefix: nil
    )

    private static let genericLang = LanguageDef(
        lineComment: "//",
        blockCommentStart: "/*", blockCommentEnd: "*/",
        keywords: ["if", "else", "for", "while", "do", "switch", "case", "default",
                    "break", "continue", "return", "function", "class", "struct", "enum",
                    "var", "let", "const", "import", "export", "from", "try", "catch",
                    "throw", "new", "delete", "typeof", "instanceof", "in", "of",
                    "true", "false", "null", "nil", "undefined", "void", "this", "self",
                    "super", "async", "await", "yield", "def", "fn", "pub", "private",
                    "public", "protected", "static", "final", "abstract", "interface",
                    "extends", "implements", "override", "package", "module", "type",
                    "val", "mut", "ref", "some", "any"],
        typeKeywords: ["Int", "String", "Bool", "Float", "Double", "Array", "List",
                       "Map", "Set", "Dict", "Object", "Error", "Result", "Option",
                       "None", "Some", "Ok", "Err"],
        stringDelimiters: ["\"", "'", "`"],
        supportsTripleQuote: false,
        hashStringLiterals: false,
        attributePrefix: "@"
    )
}
