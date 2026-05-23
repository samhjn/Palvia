import Foundation

/// Anchor class for `Bundle(for:)` so resource lookups work in both the host
/// app and the unit-test runner.
private final class BuiltInSkillsDirectoryAnchor {}

/// Reads each shipped built-in skill from its on-disk package under
/// `Resources/BuiltInSkills/<slug>/` and produces a `BuiltInSkills.ResolvedTemplate`.
///
/// All i18n is resolved against `Bundle.main.preferredLocalizations` by
/// `SkillPackage.parse` via per-locale overlay files (`SKILL.<lang>.md`,
/// `tools/<tool>.<lang>.json`, `scripts/<script>.<lang>.txt`) inside each
/// package — no `Localizable.strings` consultation.
enum BuiltInSkillsDirectoryLoader {

    /// Bundle holding the `Resources/BuiltInSkills/` directory. Same anchor
    /// trick the rest of the skill plumbing uses — works under XCTest too.
    private static var bundle: Bundle {
        Bundle(for: BuiltInSkillsDirectoryAnchor.self)
    }

    /// Load a single built-in by slug. Returns `nil` if the package is missing
    /// or its frontmatter / META declarations fail to parse.
    static func load(slug: String) -> BuiltInSkills.ResolvedTemplate? {
        guard let url = packageURL(forSlug: slug) else { return nil }
        let (parsed, report) = SkillPackage.parse(at: url)
        guard report.ok, let pkg = parsed else { return nil }

        let frontmatter = pkg.frontmatter

        // Every i18n-bearing field below is already overlay-resolved by
        // `SkillPackage.parse` against `Bundle.main.preferredLocalizations`:
        //   - `pkg.displayName` / `pkg.description` / `pkg.body` come from the
        //     best-matching `SKILL.<locale>.md` overlay (canonical fallback).
        //   - `pkg.tools[i].meta.description` and parameter descriptions come
        //     from `tools/<tool>.<locale>.json`.
        //   - `pkg.scripts[i].description` comes from
        //     `scripts/<script>.<locale>.txt`.
        return BuiltInSkills.ResolvedTemplate(
            name: frontmatter.name,
            displayName: pkg.displayName,
            summary: pkg.description,
            content: pkg.body,
            tags: frontmatter.iclaw.tags,
            scripts: pkg.toSkillScripts(),
            customTools: pkg.toCustomTools(),
            configSchema: []
        )
    }

    /// Locate a built-in skill's package directory in the app bundle. Exposed
    /// (rather than `private`) so the `fs.*` bridge resolver can route
    /// `/skills/<built-in-slug>/...` reads at the bundle.
    static func packageURL(forSlug slug: String) -> URL? {
        // We anchor on `SKILL.md` because `Bundle.url(forResource:withExtension:subdirectory:)`
        // only finds files, not directories. The package URL is the parent of
        // that match.
        if let skillMd = bundle.url(
            forResource: "SKILL",
            withExtension: "md",
            subdirectory: "BuiltInSkills/\(slug)"
        ) {
            return skillMd.deletingLastPathComponent()
        }
        return nil
    }
}
