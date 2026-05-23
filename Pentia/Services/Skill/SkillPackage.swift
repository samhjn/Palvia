import Foundation

/// A parsed skill package — the in-memory result of reading a `/SKILL.md` +
/// `tools/` + `scripts/` directory, with locale overlays applied.
///
/// Produced by `SkillPackage.parse(at:)`. Not persisted — callers copy the
/// fields they need into the `Skill` SwiftData row, which remains a cache.
struct ParsedSkillPackage: Hashable {
    let slug: String
    let rootURL: URL
    /// Max `contentModificationDate` across `SKILL.md`, `tools/`, `scripts/`
    /// at parse time. Callers store this on the `Skill` row and compare on
    /// every read to detect out-of-band edits (Files app, git, Working Copy).
    let sourceMtime: Date?
    let frontmatter: SkillFrontmatter
    /// Body after the best-matching `SKILL.<locale>.md` overlay has been
    /// applied. If no overlay matched, this is the canonical English body.
    let body: String
    let displayName: String
    let description: String
    let tools: [ParsedSkillTool]
    let scripts: [ParsedSkillScript]
}

struct ParsedSkillTool: Hashable {
    /// Filename inside `tools/` including the `.js` extension.
    let fileName: String
    /// Tool metadata with overlay-applied description / parameter descriptions.
    let meta: ParsedToolMeta
    /// Full JS source — the declaration including `const META` plus the body
    /// that runs with `args`, `fs`, `apple`, `fetch`, `console` in scope.
    let code: String
    /// JS body with the `const META = { ... };` declaration stripped, suitable
    /// for use as `SkillToolDefinition.implementation` — what runs when the
    /// LLM calls `skill_<slug>_<tool>`.
    let body: String
}

struct ParsedSkillScript: Hashable {
    /// Filename inside `scripts/` including the `.js` extension.
    let fileName: String
    let code: String
    /// First-line comment if present, with overlay-applied translation.
    let description: String?
}

// MARK: - Conversion to model types

extension ParsedSkillPackage {
    /// Convert parsed scripts to the persistence-layer `SkillScript` shape used
    /// on `Skill.scripts`. Filename → script name (stripping `.js`).
    func toSkillScripts() -> [SkillScript] {
        scripts.map { script in
            let scriptName = (script.fileName as NSString).deletingPathExtension
            return SkillScript(
                name: scriptName,
                language: "javascript",
                code: script.code,
                description: script.description
            )
        }
    }

    /// Convert parsed tools to the persistence-layer `SkillToolDefinition`
    /// shape used on `Skill.customTools`. Drops the `META` declaration from
    /// the JS source — `body` is what actually executes.
    func toCustomTools() -> [SkillToolDefinition] {
        tools.map { tool in
            let params = tool.meta.parameters.map { p in
                SkillToolParam(
                    name: p.name,
                    type: p.type,
                    description: p.description ?? "",
                    required: p.required,
                    enumValues: p.enumValues
                )
            }
            return SkillToolDefinition(
                name: tool.meta.name,
                description: tool.meta.description,
                parameters: params,
                implementation: tool.body
            )
        }
    }
}

/// Entry point for reading, writing, and validating a skill package
/// directory.
///
/// All functions are synchronous and pure — callers are responsible for
/// threading. They are also side-effect-free outside of filesystem reads
/// and the explicit writes invoked by `write(_:to:)`.
enum SkillPackage {

    // MARK: - Write

    /// Errors thrown by `write(_:to:)` when serializing a Skill row to
    /// disk. Misshapen tools / scripts on the DB side surface as these
    /// rather than producing a malformed package.
    enum WriteError: LocalizedError {
        case invalidToolName(String)
        case invalidScriptName(String)
        case ioFailure(underlying: Error)

        var errorDescription: String? {
            switch self {
            case .invalidToolName(let n):
                return "Tool name '\(n)' is not a valid identifier — skipping write."
            case .invalidScriptName(let n):
                return "Script name '\(n)' is not a valid identifier — skipping write."
            case .ioFailure(let err):
                return "Failed to write package: \(err.localizedDescription)"
            }
        }
    }

    /// Sendable plain-Swift snapshot of a `Skill` row, captured on the
    /// actor that owns the row. The disk-writing helpers operate on a
    /// `WriteSnapshot` so the I/O can happen off-main without any SwiftData
    /// access — see `snapshot(of:)` + `commit(_:to:)` below.
    struct WriteSnapshot: Sendable, Hashable {
        let name: String
        let displayName: String
        let summary: String
        let body: String
        let tags: [String]
        let scripts: [SkillScript]
        let customTools: [SkillToolDefinition]
    }

    /// Capture a Skill row's fields into a Sendable snapshot. Must be
    /// called on the actor that owns the Skill (typically @MainActor).
    /// Returns a value type that's safe to hand to a Task.detached for
    /// off-main disk writes.
    static func snapshot(of skill: Skill) -> WriteSnapshot {
        WriteSnapshot(
            name: skill.name,
            displayName: skill.effectiveDisplayName,
            summary: skill.summary,
            body: skill.content,
            tags: skill.tags,
            scripts: skill.scripts,
            customTools: skill.customTools
        )
    }

    /// Write a previously-captured `WriteSnapshot` to disk. Pure I/O — no
    /// SwiftData access — so this is safe from any actor.
    ///
    /// Generated layout:
    ///   destination/
    ///   ├── SKILL.md            (frontmatter from name/summary/tags + body)
    ///   ├── tools/<tool>.js     (one per snapshot.customTools; META prefilled)
    ///   └── scripts/<script>.js (one per snapshot.scripts; first-line comment)
    static func commit(_ snapshot: WriteSnapshot, to destination: URL) throws {
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)

            try serializeSkillMd(snapshot).write(
                to: destination.appendingPathComponent("SKILL.md"),
                atomically: true, encoding: .utf8
            )

            if !snapshot.customTools.isEmpty {
                let toolsDir = destination.appendingPathComponent("tools", isDirectory: true)
                try fm.createDirectory(at: toolsDir, withIntermediateDirectories: true)
                for tool in snapshot.customTools {
                    guard isValidIdent(tool.name) else {
                        throw WriteError.invalidToolName(tool.name)
                    }
                    let body = serializeTool(tool)
                    try body.write(
                        to: toolsDir.appendingPathComponent("\(tool.name).js"),
                        atomically: true, encoding: .utf8
                    )
                }
            }

            if !snapshot.scripts.isEmpty {
                let scriptsDir = destination.appendingPathComponent("scripts", isDirectory: true)
                try fm.createDirectory(at: scriptsDir, withIntermediateDirectories: true)
                for script in snapshot.scripts {
                    guard isValidIdent(script.name) else {
                        throw WriteError.invalidScriptName(script.name)
                    }
                    let body = serializeScript(script)
                    try body.write(
                        to: scriptsDir.appendingPathComponent("\(script.name).js"),
                        atomically: true, encoding: .utf8
                    )
                }
            }
        } catch let e as WriteError {
            throw e
        } catch {
            throw WriteError.ioFailure(underlying: error)
        }
    }

    /// Convenience: snapshot the row and commit in one call. Synchronous,
    /// runs on whatever actor invokes it. Use the snapshot/commit split
    /// directly when you want the disk work off-main (e.g. launch
    /// migration).
    static func write(_ skill: Skill, to destination: URL) throws {
        try commit(snapshot(of: skill), to: destination)
    }

    private static func serializeSkillMd(_ snapshot: WriteSnapshot) -> String {
        var out: [String] = ["---"]
        out.append("name: \(yamlScalar(snapshot.name))")
        out.append("description: \(yamlScalar(snapshot.summary))")
        if !snapshot.tags.isEmpty {
            out.append("iclaw:")
            let inline = snapshot.tags.map { yamlScalar($0) }.joined(separator: ", ")
            out.append("  tags: [\(inline)]")
        }
        out.append("---")
        out.append("")
        let body = snapshot.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty {
            // Minimal body: a heading so SkillPackage.parse's body
            // resolution returns something non-empty.
            out.append("# \(snapshot.displayName)")
        } else {
            out.append(body)
        }
        out.append("") // trailing newline
        return out.joined(separator: "\n")
    }

    private static func serializeTool(_ tool: SkillToolDefinition) -> String {
        let paramsJSON = renderParameters(tool.parameters)
        let descLiteral = jsStringLiteral(tool.description)
        let nameLiteral = jsStringLiteral(tool.name)
        let body = tool.implementation.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        const META = {
          name: \(nameLiteral),
          description: \(descLiteral),
          parameters: \(paramsJSON)
        };

        \(body.isEmpty ? "// TODO: implement\nconsole.log(\"TODO\");" : body)

        """
    }

    private static func serializeScript(_ script: SkillScript) -> String {
        let head = (script.description?.trimmingCharacters(in: .whitespacesAndNewlines)).map {
            "// \($0)\n\n"
        } ?? ""
        let body = script.code.trimmingCharacters(in: .whitespacesAndNewlines)
        return head + (body.isEmpty ? "console.log(\"TODO\");" : body) + "\n"
    }

    private static func renderParameters(_ params: [SkillToolParam]) -> String {
        if params.isEmpty { return "[]" }
        let lines = params.map { p -> String in
            var fields: [String] = [
                "name: \(jsStringLiteral(p.name))",
                "type: \(jsStringLiteral(p.type))",
                "required: \(p.required ? "true" : "false")",
            ]
            if !p.description.isEmpty {
                fields.append("description: \(jsStringLiteral(p.description))")
            }
            if let enumValues = p.enumValues, !enumValues.isEmpty {
                let inner = enumValues.map { jsStringLiteral($0) }.joined(separator: ", ")
                fields.append("enum: [\(inner)]")
            }
            return "    { \(fields.joined(separator: ", ")) }"
        }
        return "[\n\(lines.joined(separator: ",\n"))\n  ]"
    }

    private static func isValidIdent(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first else { return false }
        let startSet = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_")
        let bodySet = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")
        guard startSet.contains(first) else { return false }
        for u in s.unicodeScalars.dropFirst() where !bodySet.contains(u) { return false }
        return true
    }

    /// Produce a YAML scalar safe for the SKILL.md frontmatter parser.
    /// Quotes the value when it contains characters the parser splits on
    /// (`:`, `#`, leading/trailing whitespace) or that look like list/map
    /// delimiters.
    private static func yamlScalar(_ s: String) -> String {
        let trimmed = s
        let needsQuote = trimmed != s
            || trimmed.contains(":") || trimmed.contains("#")
            || trimmed.contains("\n") || trimmed.contains("\r")
            || ["-", "[", "{", "&", "*", "!", "|", ">", "'", "\"", "%", "@", "`"].contains { trimmed.hasPrefix($0) }
        guard needsQuote else { return trimmed }
        let escaped = trimmed
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// Encode a Swift string as a JS double-quoted literal — used for META
    /// declaration fields. JSON encoding is the safe shortcut: it produces
    /// a string that's both valid JS and valid JSON.
    private static func jsStringLiteral(_ s: String) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: [s], options: []),
           let str = String(data: data, encoding: .utf8) {
            // Strip the surrounding `[` and `]`.
            let inner = str.dropFirst().dropLast()
            return String(inner)
        }
        // Last-resort fallback: naive escape.
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"\(escaped)\""
    }

    // MARK: - Validation

    /// Produce a `ValidationReport` for the package rooted at `url`.
    ///
    /// Never throws — a directory that is completely unreadable still produces
    /// a report with a single error entry. This makes the function safe to
    /// call from any consumer (LLM tool, import dialog, auto-reload path,
    /// on-read mtime check).
    static func validate(
        at url: URL,
        preferredLocales: [String] = [],
        knownSlugs: Set<String> = [],
        coreToolNames: Set<String> = [],
        enforceSlugMatch: Bool = true
    ) -> ValidationReport {
        let slug = url.lastPathComponent
        var errors: [ValidationIssue] = []
        var warnings: [ValidationIssue] = []

        let skillMd = url.appendingPathComponent("SKILL.md")
        guard FileManager.default.fileExists(atPath: skillMd.path) else {
            errors.append(.init(
                severity: .error, file: "SKILL.md", line: 0,
                code: .skillMdMissing,
                message: "Required `SKILL.md` is missing from the skill package."
            ))
            return ValidationReport(slug: slug, errors: errors, warnings: warnings)
        }

        // Frontmatter + body
        let source: String
        do {
            source = try String(contentsOf: skillMd, encoding: .utf8)
        } catch {
            errors.append(.init(
                severity: .error, file: "SKILL.md", line: 0,
                code: .skillMdMissing,
                message: "Failed to read SKILL.md: \(error.localizedDescription)"
            ))
            return ValidationReport(slug: slug, errors: errors, warnings: warnings)
        }

        let fm: SkillFrontmatter
        do {
            fm = try SkillFrontmatterParser.parse(source).0
        } catch let FrontmatterError.missingOpeningDelimiter(line) {
            errors.append(.init(
                severity: .error, file: "SKILL.md", line: line,
                code: .frontmatterMissing,
                message: "Missing opening `---` delimiter."
            ))
            return ValidationReport(slug: slug, errors: errors, warnings: warnings)
        } catch FrontmatterError.missingClosingDelimiter {
            errors.append(.init(
                severity: .error, file: "SKILL.md", line: 0,
                code: .frontmatterMalformed,
                message: "Missing closing `---` delimiter."
            ))
            return ValidationReport(slug: slug, errors: errors, warnings: warnings)
        } catch let FrontmatterError.malformed(line, reason) {
            errors.append(.init(
                severity: .error, file: "SKILL.md", line: line,
                code: .frontmatterMalformed,
                message: reason
            ))
            return ValidationReport(slug: slug, errors: errors, warnings: warnings)
        } catch {
            errors.append(.init(
                severity: .error, file: "SKILL.md", line: 0,
                code: .frontmatterMalformed,
                message: error.localizedDescription
            ))
            return ValidationReport(slug: slug, errors: errors, warnings: warnings)
        }

        // Field checks
        if fm.name.trimmingCharacters(in: .whitespaces).isEmpty {
            errors.append(.init(
                severity: .error, file: "SKILL.md", line: 0,
                code: fm.name.isEmpty ? .missingField : .emptyField,
                message: "Frontmatter field `name` is required and must be non-empty."
            ))
        } else if fm.name.count > 64 {
            errors.append(.init(
                severity: .error, file: "SKILL.md", line: 0,
                code: .fieldTooLong,
                message: "Frontmatter field `name` is \(fm.name.count) characters; maximum is 64."
            ))
        }

        if fm.description.trimmingCharacters(in: .whitespaces).isEmpty {
            errors.append(.init(
                severity: .error, file: "SKILL.md", line: 0,
                code: fm.description.isEmpty ? .missingField : .emptyField,
                message: "Frontmatter field `description` is required and must be non-empty."
            ))
        } else if fm.description.count > 200 {
            errors.append(.init(
                severity: .error, file: "SKILL.md", line: 0,
                code: .fieldTooLong,
                message: "Frontmatter field `description` is \(fm.description.count) characters; maximum is 200."
            ))
        } else if fm.description.count > 150 {
            warnings.append(.init(
                severity: .warning, file: "SKILL.md", line: 0,
                code: .descriptionLong,
                message: "`description` is \(fm.description.count) characters; long descriptions reduce matching quality. Consider trimming toward 100–150."
            ))
        }

        // Slug derivation + directory-name match. The mismatch check is
        // skipped for callers that will rename the destination anyway (the
        // importer copies to `<Documents>/Skills/<derivedSlug>/` regardless
        // of what the source folder is called).
        let derivedSlug = derivedSlug(forName: fm.name, override: fm.iclaw.slash)
        if enforceSlugMatch, !derivedSlug.isEmpty, derivedSlug != slug {
            errors.append(.init(
                severity: .error, file: "SKILL.md", line: 0,
                code: .slugMismatch,
                message: "Derived slug `\(derivedSlug)` does not match the directory name `\(slug)`. Rename the directory or set `iclaw.slash` to match."
            ))
        }

        // Slug collision with another known skill. When slug-match is not
        // enforced (import path), check the derived slug instead — that's
        // the slug the package will land at on disk.
        let collisionSlug = enforceSlugMatch ? slug : (derivedSlug.isEmpty ? slug : derivedSlug)
        if knownSlugs.contains(collisionSlug) {
            errors.append(.init(
                severity: .error, file: "SKILL.md", line: 0,
                code: .slugCollision,
                message: "Slug `\(collisionSlug)` is already registered by another skill."
            ))
        }

        // Tags ASCII check
        for tag in fm.iclaw.tags where tag.unicodeScalars.contains(where: { !$0.isASCII }) {
            warnings.append(.init(
                severity: .warning, file: "SKILL.md", line: 0,
                code: .nonAsciiTag,
                message: "Tag `\(tag)` contains non-ASCII characters; tags are search keys and are expected to stay English."
            ))
        }

        // Tools
        let toolsDir = url.appendingPathComponent("tools", isDirectory: true)
        var seenToolNames: Set<String> = []
        if FileManager.default.fileExists(atPath: toolsDir.path) {
            let toolFiles = (try? FileManager.default.contentsOfDirectory(
                at: toolsDir, includingPropertiesForKeys: nil
            )) ?? []
            for toolURL in toolFiles where toolURL.pathExtension == "js" {
                // Skip locale overlay files: `foo.zh-Hans.json` — those are
                // not tool sources, they're sibling overlays.
                let filename = toolURL.lastPathComponent
                let (toolFileErrors, toolFileWarnings, parsed) = validateToolFile(at: toolURL, fileName: filename)
                errors.append(contentsOf: toolFileErrors)
                warnings.append(contentsOf: toolFileWarnings)

                if let meta = parsed {
                    if seenToolNames.contains(meta.name) {
                        errors.append(.init(
                            severity: .error, file: "tools/\(filename)", line: meta.metaLineRange.lowerBound,
                            code: .metaDuplicate,
                            message: "Duplicate tool name `\(meta.name)` within this skill."
                        ))
                    } else {
                        seenToolNames.insert(meta.name)
                    }
                    let derivedToolName = "skill_\(slug)_\(meta.name)"
                    if coreToolNames.contains(meta.name) || coreToolNames.contains(derivedToolName) {
                        errors.append(.init(
                            severity: .error, file: "tools/\(filename)", line: meta.metaLineRange.lowerBound,
                            code: .toolNameShadowsCore,
                            message: "Tool name `\(meta.name)` would shadow a core iClaw tool."
                        ))
                    }
                }
            }
        }

        // Scripts
        let scriptsDir = url.appendingPathComponent("scripts", isDirectory: true)
        if FileManager.default.fileExists(atPath: scriptsDir.path) {
            let scriptFiles = (try? FileManager.default.contentsOfDirectory(
                at: scriptsDir, includingPropertiesForKeys: nil
            )) ?? []
            for scriptURL in scriptFiles where scriptURL.pathExtension == "js" {
                let filename = scriptURL.lastPathComponent
                let src = (try? String(contentsOf: scriptURL, encoding: .utf8)) ?? ""
                if firstLineComment(in: src) == nil {
                    warnings.append(.init(
                        severity: .warning, file: "scripts/\(filename)", line: 1,
                        code: .noDescriptionComment,
                        message: "Script has no first-line comment. Add `// <description>` to surface it in the skill's scripts list."
                    ))
                }
            }
        }

        // Locale overlay sanity — SKILL.<L>.md parseable
        if let contents = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
            for f in contents {
                let n = f.lastPathComponent
                if n.hasPrefix("SKILL.") && n.hasSuffix(".md") && n != "SKILL.md" {
                    if let src = try? String(contentsOf: f, encoding: .utf8) {
                        do {
                            _ = try SkillFrontmatterParser.parseOverlay(src)
                        } catch {
                            errors.append(.init(
                                severity: .error, file: n, line: 0,
                                code: .localeOverlayMalformed,
                                message: "Locale overlay `\(n)` failed to parse: \(error.localizedDescription)"
                            ))
                        }
                    }
                }
            }
        }

        return ValidationReport(slug: slug, errors: errors, warnings: warnings)
    }

    // MARK: - Parse

    /// Full parse: validate, and on success return the parsed package.
    ///
    /// The report is returned alongside a parsed package when it exists (so
    /// warnings-only cases still yield usable output). On errors, the package
    /// is nil and callers should surface the report.
    static func parse(
        at url: URL,
        preferredLocales: [String] = Bundle.main.preferredLocalizations,
        knownSlugs: Set<String> = [],
        coreToolNames: Set<String> = [],
        enforceSlugMatch: Bool = true
    ) -> (ParsedSkillPackage?, ValidationReport) {
        let report = validate(
            at: url,
            preferredLocales: preferredLocales,
            knownSlugs: knownSlugs,
            coreToolNames: coreToolNames,
            enforceSlugMatch: enforceSlugMatch
        )
        guard report.ok else { return (nil, report) }

        let slug = url.lastPathComponent
        let skillMd = url.appendingPathComponent("SKILL.md")
        guard let canonicalSource = try? String(contentsOf: skillMd, encoding: .utf8),
              let parsed = try? SkillFrontmatterParser.parse(canonicalSource) else {
            return (nil, report)
        }
        let (frontmatter, canonicalBody, _) = parsed

        // Apply SKILL.<locale>.md overlay
        let pickedOverlay = pickBestOverlay(in: url, preferredLocales: preferredLocales)
        var body = canonicalBody
        var displayName = frontmatter.name
        var description = frontmatter.description
        if let (_, overlaySource) = pickedOverlay,
           let overlay = try? SkillFrontmatterParser.parseOverlay(overlaySource) {
            if let d = overlay.displayName, !d.isEmpty { displayName = d }
            if let d = overlay.description, !d.isEmpty { description = d }
            if !overlay.body.isEmpty { body = overlay.body }
        }

        // Tools
        var tools: [ParsedSkillTool] = []
        let toolsDir = url.appendingPathComponent("tools", isDirectory: true)
        if let files = try? FileManager.default.contentsOfDirectory(at: toolsDir, includingPropertiesForKeys: nil) {
            for f in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where f.pathExtension == "js" {
                guard let src = try? String(contentsOf: f, encoding: .utf8),
                      let meta = try? SkillJSMetaParser.parse(src) else { continue }
                let overlaid = applyToolOverlay(
                    meta: meta,
                    toolFile: f,
                    skillRoot: url,
                    preferredLocales: preferredLocales
                )
                tools.append(ParsedSkillTool(
                    fileName: f.lastPathComponent,
                    meta: overlaid,
                    code: src,
                    body: SkillJSMetaParser.bodyAfterMeta(src)
                ))
            }
        }

        // Scripts
        var scripts: [ParsedSkillScript] = []
        let scriptsDir = url.appendingPathComponent("scripts", isDirectory: true)
        if let files = try? FileManager.default.contentsOfDirectory(at: scriptsDir, includingPropertiesForKeys: nil) {
            for f in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where f.pathExtension == "js" {
                guard let src = try? String(contentsOf: f, encoding: .utf8) else { continue }
                let desc = applyScriptOverlay(
                    canonical: firstLineComment(in: src),
                    scriptFile: f,
                    skillRoot: url,
                    preferredLocales: preferredLocales
                )
                scripts.append(ParsedSkillScript(
                    fileName: f.lastPathComponent,
                    code: src,
                    description: desc
                ))
            }
        }

        let pkg = ParsedSkillPackage(
            slug: slug,
            rootURL: url,
            sourceMtime: packageMtime(at: url),
            frontmatter: frontmatter,
            body: body,
            displayName: displayName,
            description: description,
            tools: tools,
            scripts: scripts
        )
        return (pkg, report)
    }

    /// Most recent `contentModificationDate` across the package's canonical
    /// files and subdirectories. Used by the on-read mtime cache to detect
    /// external edits without a filesystem watcher.
    static func packageMtime(at url: URL) -> Date? {
        var latest: Date? = nil
        let paths: [URL] = [
            url,
            url.appendingPathComponent("SKILL.md"),
            url.appendingPathComponent("tools", isDirectory: true),
            url.appendingPathComponent("scripts", isDirectory: true),
        ]
        for p in paths {
            if let v = try? p.resourceValues(forKeys: [.contentModificationDateKey]),
               let d = v.contentModificationDate {
                if latest == nil || d > latest! { latest = d }
            }
        }
        return latest
    }

    // MARK: - Slug derivation

    /// Convert a human-friendly `name` to a directory-safe slug. Preserves
    /// an explicit override from `iclaw.slash` when provided.
    ///
    /// Rule: lowercase, non-alphanumerics collapsed to single hyphens, leading
    /// and trailing hyphens trimmed. `iclaw.slash` is sanitized the same way
    /// so the override still has to be a valid slug.
    static func derivedSlug(forName name: String, override: String? = nil) -> String {
        if let raw = override, !raw.isEmpty {
            return sluggify(raw)
        }
        return sluggify(name)
    }

    private static func sluggify(_ s: String) -> String {
        var out = ""
        var lastWasHyphen = false
        for scalar in s.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.append(Character(scalar).lowercased())
                lastWasHyphen = false
            } else if !lastWasHyphen && !out.isEmpty {
                out.append("-")
                lastWasHyphen = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }

    // MARK: - Overlay helpers

    /// Return the best `SKILL.<locale>.md` overlay contents for the preferred
    /// locale list, falling back to the nearest available base language.
    private static func pickBestOverlay(
        in skillRoot: URL,
        preferredLocales: [String]
    ) -> (locale: String, source: String)? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: skillRoot, includingPropertiesForKeys: nil
        ) else { return nil }
        let available: [(locale: String, url: URL)] = files.compactMap { f in
            let n = f.lastPathComponent
            guard n.hasPrefix("SKILL.") && n.hasSuffix(".md") && n != "SKILL.md" else { return nil }
            let locale = String(n.dropFirst("SKILL.".count).dropLast(".md".count))
            return (locale, f)
        }
        for pref in preferredLocales {
            if let hit = available.first(where: { $0.locale == pref }) {
                if let src = try? String(contentsOf: hit.url, encoding: .utf8) {
                    return (hit.locale, src)
                }
            }
        }
        // Base language fallback: `zh-Hans` → `zh`
        for pref in preferredLocales {
            let base = pref.split(separator: "-").first.map(String.init) ?? pref
            if let hit = available.first(where: { $0.locale == base }) {
                if let src = try? String(contentsOf: hit.url, encoding: .utf8) {
                    return (hit.locale, src)
                }
            }
        }
        return nil
    }

    /// Apply a tool's JSON overlay (`tools/<tool>.<locale>.json`) to translate
    /// `description` / `parameters[].description` / `parameters[].enum`. The
    /// canonical META's structural fields (name, type, required) are
    /// unchanged.
    private static func applyToolOverlay(
        meta: ParsedToolMeta,
        toolFile: URL,
        skillRoot: URL,
        preferredLocales: [String]
    ) -> ParsedToolMeta {
        let base = (toolFile.lastPathComponent as NSString).deletingPathExtension
        let toolsDir = toolFile.deletingLastPathComponent()
        guard let all = try? FileManager.default.contentsOfDirectory(at: toolsDir, includingPropertiesForKeys: nil) else {
            return meta
        }
        // Available overlays: `<base>.<locale>.json`
        let overlays: [(locale: String, url: URL)] = all.compactMap { f in
            let n = f.lastPathComponent
            guard n.hasPrefix("\(base).") && n.hasSuffix(".json") else { return nil }
            let middle = String(n.dropFirst("\(base).".count).dropLast(".json".count))
            return (middle, f)
        }
        _ = skillRoot // reserved for future cross-file overlay patterns
        var pickedURL: URL? = nil
        for pref in preferredLocales {
            if let hit = overlays.first(where: { $0.locale == pref }) {
                pickedURL = hit.url; break
            }
        }
        if pickedURL == nil {
            for pref in preferredLocales {
                let bLoc = pref.split(separator: "-").first.map(String.init) ?? pref
                if let hit = overlays.first(where: { $0.locale == bLoc }) {
                    pickedURL = hit.url; break
                }
            }
        }
        guard let url = pickedURL,
              let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return meta }

        var newMeta = meta
        if let d = obj["description"] as? String, !d.isEmpty {
            newMeta.description = d
        }
        if let paramsObj = obj["parameters"] as? [String: Any] {
            newMeta.parameters = meta.parameters.map { p in
                guard let patch = paramsObj[p.name] as? [String: Any] else { return p }
                var q = p
                if let d = patch["description"] as? String, !d.isEmpty {
                    q.description = d
                }
                return q
            }
        }
        return newMeta
    }

    /// Apply a script's single-line overlay (`scripts/<script>.<locale>.txt`)
    /// to translate its description.
    private static func applyScriptOverlay(
        canonical: String?,
        scriptFile: URL,
        skillRoot: URL,
        preferredLocales: [String]
    ) -> String? {
        let base = (scriptFile.lastPathComponent as NSString).deletingPathExtension
        let scriptsDir = scriptFile.deletingLastPathComponent()
        guard let all = try? FileManager.default.contentsOfDirectory(at: scriptsDir, includingPropertiesForKeys: nil) else {
            return canonical
        }
        let overlays: [(locale: String, url: URL)] = all.compactMap { f in
            let n = f.lastPathComponent
            guard n.hasPrefix("\(base).") && n.hasSuffix(".txt") else { return nil }
            let middle = String(n.dropFirst("\(base).".count).dropLast(".txt".count))
            return (middle, f)
        }
        _ = skillRoot
        var pickedURL: URL? = nil
        for pref in preferredLocales {
            if let hit = overlays.first(where: { $0.locale == pref }) {
                pickedURL = hit.url; break
            }
        }
        if pickedURL == nil {
            for pref in preferredLocales {
                let bLoc = pref.split(separator: "-").first.map(String.init) ?? pref
                if let hit = overlays.first(where: { $0.locale == bLoc }) {
                    pickedURL = hit.url; break
                }
            }
        }
        if let url = pickedURL,
           let text = try? String(contentsOf: url, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return canonical
    }

    // MARK: - Per-tool validation

    private static func validateToolFile(
        at url: URL,
        fileName: String
    ) -> ([ValidationIssue], [ValidationIssue], ParsedToolMeta?) {
        var errors: [ValidationIssue] = []
        var warnings: [ValidationIssue] = []
        guard let src = try? String(contentsOf: url, encoding: .utf8) else {
            errors.append(.init(
                severity: .error, file: "tools/\(fileName)", line: 0,
                code: .metaMissing,
                message: "Failed to read tool file."
            ))
            return (errors, warnings, nil)
        }

        let meta: ParsedToolMeta
        do {
            meta = try SkillJSMetaParser.parse(src)
        } catch JSMetaError.notFound {
            errors.append(.init(
                severity: .error, file: "tools/\(fileName)", line: 0,
                code: .metaMissing,
                message: "No `const META = { ... }` declaration found."
            ))
            return (errors, warnings, nil)
        } catch let JSMetaError.missingField(line, field) {
            errors.append(.init(
                severity: .error, file: "tools/\(fileName)", line: line,
                code: .metaMalformed,
                message: "META is missing required field `\(field)`."
            ))
            return (errors, warnings, nil)
        } catch let JSMetaError.wrongType(line, field, expected) {
            errors.append(.init(
                severity: .error, file: "tools/\(fileName)", line: line,
                code: .metaMalformed,
                message: "META field `\(field)` is not a \(expected)."
            ))
            return (errors, warnings, nil)
        } catch let JSMetaError.unexpected(line, reason) {
            errors.append(.init(
                severity: .error, file: "tools/\(fileName)", line: line,
                code: .metaMalformed,
                message: reason
            ))
            return (errors, warnings, nil)
        } catch let JSMetaError.unterminated(line) {
            errors.append(.init(
                severity: .error, file: "tools/\(fileName)", line: line,
                code: .metaMalformed,
                message: "Unterminated literal in META."
            ))
            return (errors, warnings, nil)
        } catch {
            errors.append(.init(
                severity: .error, file: "tools/\(fileName)", line: 0,
                code: .metaMalformed,
                message: error.localizedDescription
            ))
            return (errors, warnings, nil)
        }

        // Name
        if meta.name.isEmpty {
            errors.append(.init(
                severity: .error, file: "tools/\(fileName)", line: meta.metaLineRange.lowerBound,
                code: .missingField,
                message: "META.name is empty."
            ))
        } else if !isValidToolName(meta.name) {
            errors.append(.init(
                severity: .error, file: "tools/\(fileName)", line: meta.metaLineRange.lowerBound,
                code: .metaMalformed,
                message: "META.name `\(meta.name)` must match [a-zA-Z_][a-zA-Z0-9_]* so the derived `skill_<slug>_<name>` tool name is valid."
            ))
        }

        // Description
        if meta.description.isEmpty {
            errors.append(.init(
                severity: .error, file: "tools/\(fileName)", line: meta.metaLineRange.lowerBound,
                code: .missingField,
                message: "META.description is empty."
            ))
        } else if meta.description.count < 10 {
            warnings.append(.init(
                severity: .warning, file: "tools/\(fileName)", line: meta.metaLineRange.lowerBound,
                code: .descriptionShort,
                message: "META.description is very short (\(meta.description.count) chars). The model needs ~1 sentence to pick the tool reliably."
            ))
        }

        // Params
        let allowedTypes: Set<String> = ["string", "number", "boolean", "array", "object"]
        var seenParamNames: Set<String> = []
        for (idx, p) in meta.parameters.enumerated() {
            if !allowedTypes.contains(p.type) {
                let suggestion = typoHint(p.type, allowedTypes)
                errors.append(.init(
                    severity: .error, file: "tools/\(fileName)", line: meta.metaLineRange.lowerBound,
                    code: .badParamType,
                    message: "parameters[\(idx)].type: unknown type `\(p.type)`\(suggestion)."
                ))
            }
            if seenParamNames.contains(p.name) {
                warnings.append(.init(
                    severity: .warning, file: "tools/\(fileName)", line: meta.metaLineRange.lowerBound,
                    code: .duplicateParam,
                    message: "Duplicate parameter name `\(p.name)`; later occurrences are ignored."
                ))
            } else {
                seenParamNames.insert(p.name)
            }
        }

        // `console.log` / return heuristic — warn, not error.
        if !src.contains("console.log") && !src.contains("return ") {
            warnings.append(.init(
                severity: .warning, file: "tools/\(fileName)", line: meta.metaLineRange.upperBound,
                code: .toolHasNoOutput,
                message: "Tool body doesn't call `console.log` or `return` — its result will be empty."
            ))
        }

        return (errors, warnings, meta)
    }

    // MARK: - Small utilities

    private static func firstLineComment(in src: String) -> String? {
        for raw in src.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("//") {
                let body = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
                return body.isEmpty ? nil : String(body)
            }
            return nil
        }
        return nil
    }

    /// Tool names flow into `skill_<slug>_<name>` which is sent to the LLM as
    /// a function-call tool name — that surface accepts ASCII identifiers
    /// only. Reject non-ASCII letters here even though Swift's
    /// `CharacterSet.letters` would accept them.
    private static let toolNameStart: CharacterSet =
        CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_")
    private static let toolNameBody: CharacterSet =
        CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")

    private static func isValidToolName(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first, toolNameStart.contains(first) else { return false }
        for u in s.unicodeScalars.dropFirst() where !toolNameBody.contains(u) {
            return false
        }
        return true
    }

    private static func typoHint(_ bad: String, _ allowed: Set<String>) -> String {
        // Cheap Levenshtein-1 check for simple typos like "strng" → "string".
        for a in allowed where editDistanceAtMostOne(bad, a) {
            return " (did you mean `\(a)`?)"
        }
        return ""
    }

    private static func editDistanceAtMostOne(_ a: String, _ b: String) -> Bool {
        let aChars = Array(a)
        let bChars = Array(b)
        if abs(aChars.count - bChars.count) > 1 { return false }
        let (s, t) = aChars.count <= bChars.count ? (aChars, bChars) : (bChars, aChars)
        var i = 0, j = 0
        var diffs = 0
        while i < s.count && j < t.count {
            if s[i] == t[j] { i += 1; j += 1 }
            else {
                diffs += 1
                if diffs > 1 { return false }
                if s.count == t.count { i += 1; j += 1 }
                else { j += 1 }
            }
        }
        if j < t.count { diffs += t.count - j }
        return diffs <= 1
    }
}
