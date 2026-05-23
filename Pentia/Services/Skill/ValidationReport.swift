import Foundation

/// Severity of a validation finding.
///
/// `error` means the skill cannot be loaded or used; it must not be exposed as
/// `skill_<slug>_*` function-call tools. `warning` means the skill can still
/// load and run, but something should be fixed.
enum ValidationSeverity: String, Codable, Hashable {
    case error
    case warning
}

/// Stable identifiers for validator findings. The LLM, UI, and logs all match
/// on these, so renames are a breaking change — add new codes instead.
enum IssueCode: String, Codable, Hashable {
    // Structural errors
    case skillMdMissing          = "skill_md_missing"
    case frontmatterMissing      = "frontmatter_missing"
    case frontmatterMalformed    = "frontmatter_malformed"

    // Field errors
    case missingField            = "missing_field"
    case emptyField              = "empty_field"
    case fieldTooLong            = "field_too_long"
    case slugMismatch            = "slug_mismatch"
    case slugCollision           = "slug_collision"

    // META errors
    case metaMissing             = "meta_missing"
    case metaMalformed           = "meta_malformed"
    case metaDuplicate           = "meta_duplicate"
    case badParamType            = "bad_param_type"

    // Code errors
    case jsSyntaxError           = "js_syntax_error"
    case toolNameShadowsCore     = "tool_name_shadows_core"
    case localeOverlayMalformed  = "locale_overlay_malformed"

    // Warnings
    case descriptionLong         = "description_long"
    case descriptionShort        = "description_short"
    case noDescriptionComment    = "no_description_comment"
    case duplicateParam          = "duplicate_param"
    case staleLocaleOverlay      = "stale_locale_overlay"
    case nonAsciiTag             = "non_ascii_tag"
    case orphanReferenceFile     = "orphan_reference_file"
    case brokenInternalLink      = "broken_internal_link"
    case toolHasNoOutput         = "tool_has_no_output"
}

struct ValidationIssue: Codable, Hashable {
    let severity: ValidationSeverity
    /// Relative path inside the skill package, e.g. "SKILL.md", "tools/foo.js".
    let file: String
    /// 1-based line number. Zero means "line not applicable / whole-file issue".
    let line: Int
    let code: IssueCode
    let message: String
}

struct ValidationReport: Codable, Hashable {
    let slug: String
    let errors: [ValidationIssue]
    let warnings: [ValidationIssue]

    var ok: Bool { errors.isEmpty }

    init(slug: String, errors: [ValidationIssue] = [], warnings: [ValidationIssue] = []) {
        self.slug = slug
        self.errors = errors
        self.warnings = warnings
    }
}

extension ValidationReport {
    /// JSON encoding used by the `validate_skill` LLM tool and tests that
    /// assert consumer parity.
    func jsonString(pretty: Bool = true) -> String {
        let encoder = JSONEncoder()
        if pretty {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        } else {
            encoder.outputFormatting = [.sortedKeys]
        }
        guard let data = try? encoder.encode(self),
              let str = String(data: data, encoding: .utf8) else {
            return #"{"slug":"\#(slug)","errors":[],"warnings":[],"encoding_failed":true}"#
        }
        return str
    }
}
