import Foundation

/// Registry of built-in skills shipped with the app.
///
/// The source of truth is on disk — each shipped skill is a directory under
/// `Resources/BuiltInSkills/<slug>/` with a standard `SKILL.md` + `tools/` +
/// `scripts/` layout (see `docs/skills-standard-alignment-proposal.md`).
/// Adding a new built-in is a two-step change: drop a `<slug>/` directory in
/// place and append the slug to `shippedSlugs`.
///
/// The directory layout, frontmatter format, JS `META` declarations, and
/// per-locale overlay files are defined by the same parser that handles
/// user-authored skills (`SkillPackage`) — so built-ins and user skills are
/// indistinguishable at the data layer.
enum BuiltInSkills {

    /// Slugs of every shipped built-in package. Iteration order is the order
    /// these are presented to the user in the library and to the LLM in the
    /// system prompt.
    static let shippedSlugs: [String] = [
        "deep-research",
        "file-ops",
        "health-plus",
        "skill-builder",
    ]

    /// In-memory representation of a built-in skill after parsing the package
    /// and applying locale overlays. `SkillService.ensureBuiltInSkills` upserts
    /// each of these into a `Skill` SwiftData row on launch.
    struct ResolvedTemplate: Hashable {
        let name: String
        let displayName: String
        let summary: String
        let content: String
        let tags: [String]
        let scripts: [SkillScript]
        let customTools: [SkillToolDefinition]
        let configSchema: [SkillConfigField]
    }

    /// Load every shipped built-in by reading its on-disk package, applying
    /// the locale overlay matching `Bundle.main.preferredLocalizations`.
    /// A package whose `SKILL.md` fails to parse is skipped — callers will
    /// see one fewer entry but never a crash.
    static func allResolvedTemplates() -> [ResolvedTemplate] {
        shippedSlugs.compactMap { slug in
            BuiltInSkillsDirectoryLoader.load(slug: slug)
        }
    }
}
