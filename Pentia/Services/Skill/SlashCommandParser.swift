import Foundation

/// Result of parsing a chat message for a leading `/<skill-slug>` activation
/// command.
enum SlashCommandResult: Equatable {
    /// Not a slash command, or the slug didn't match any installed skill.
    /// The caller should send the original text unmodified — this is a soft-
    /// matching feature, not a strict command parser.
    case none

    /// Matched an installed skill. Strip the prefix and send `remaining` to
    /// the LLM along with a system note that the skill is now active.
    case activate(slug: String, remaining: String)

    /// Matched, but the message was only the slug (no follow-up content).
    /// The caller should mark the skill active in the session, render a UI
    /// hint locally, and NOT send anything to the LLM.
    case activateOnly(slug: String)
}

/// Pure parser for the `/skill-slug` activation syntax that runs at the head
/// of `ChatViewModel.sendMessage()`. Two design properties are load-bearing:
///
///   1. **Soft-matching.** Anything that doesn't match an installed skill is
///      returned as `.none` so existing user text starting with `/` (e.g. a
///      file path, a leading divider) keeps working.
///   2. **Slug normalization.** Both `/deep-research` and `/deep_research`
///      match the same skill — underscores are normalized to hyphens before
///      the lookup. This matches the iClaw convention that `Skill.name`
///      derives to a hyphenated slug via `SkillPackage.derivedSlug`.
enum SlashCommandParser {

    /// Parse `input` for a leading slash-command. `isInstalled` returns true
    /// when a slug corresponds to an installed-and-enabled skill on the
    /// current agent — the parser uses the closure rather than a Set so the
    /// caller can resolve aliases (display name, override slug) however it
    /// prefers.
    static func parse(_ input: String, isInstalled: (String) -> Bool) -> SlashCommandResult {
        let trimmed = input.drop { $0.isWhitespace }
        guard trimmed.first == "/" else { return .none }
        let afterSlash = trimmed.dropFirst()

        // Read the slug: contiguous slug characters. Stop at whitespace,
        // newline, or any other char that can't appear in a valid slug.
        var slugChars: [Character] = []
        var idx = afterSlash.startIndex
        while idx < afterSlash.endIndex, isSlugChar(afterSlash[idx]) {
            slugChars.append(afterSlash[idx])
            idx = afterSlash.index(after: idx)
        }
        guard !slugChars.isEmpty else { return .none }

        // Normalize: lowercase, underscores → hyphens.
        let slug = String(slugChars).lowercased().replacingOccurrences(of: "_", with: "-")
        guard isInstalled(slug) else { return .none }

        // Skip the separator whitespace before the remainder.
        var remIdx = idx
        while remIdx < afterSlash.endIndex, afterSlash[remIdx].isWhitespace {
            remIdx = afterSlash.index(after: remIdx)
        }
        let remaining = String(afterSlash[remIdx...])
        if remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .activateOnly(slug: slug)
        }
        return .activate(slug: slug, remaining: remaining)
    }

    /// True for characters that can appear in a slug after derivation by
    /// `SkillPackage.derivedSlug`. Underscore is allowed because users
    /// commonly type `/deep_research` even though the canonical slug uses
    /// hyphens — `parse` normalizes to hyphens before the lookup.
    private static func isSlugChar(_ c: Character) -> Bool {
        if c.isLetter || c.isNumber { return true }
        return c == "-" || c == "_"
    }
}
