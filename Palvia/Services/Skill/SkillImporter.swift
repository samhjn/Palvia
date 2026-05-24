import Foundation
import SwiftData

/// Imports a skill package from an arbitrary source directory (typically
/// chosen via the iOS file picker, possibly under iCloud Drive or Working
/// Copy) into `<Documents>/Skills/<slug>/`. Validation happens against a
/// scratch copy first — a malformed package never touches the live skills
/// directory.
///
/// **Security note.** Skills carry executable JavaScript that runs in the
/// WKWebView sandbox with access to the agent-permission-gated `fs.*` and
/// `apple.*` bridges. Imports from untrusted sources can exfiltrate data
/// the agent has access to. The UI must display a security confirmation
/// before invoking the file picker — see `SkillLibraryView`.
enum SkillImporter {

    /// Possible outcomes of `prepareImport`. The UI dispatches based on the
    /// case: errors abort, warnings/collisions ask for confirmation, ready
    /// is the happy path that flows into `commitImport`.
    enum Outcome: Equatable {
        /// Source path doesn't exist or isn't a directory.
        case notADirectory
        /// The package failed validation. Import must abort; report is
        /// shown to the user.
        case error(report: ValidationReport)
        /// The package validates with warnings. The UI should ask the user
        /// to confirm before proceeding.
        case warningsRequireConfirmation(
            package: ParsedSkillPackage,
            report: ValidationReport,
            collision: ExistingSkill?
        )
        /// Clean validation. The UI may proceed directly to commit, but
        /// when `collision` is non-nil it must still ask whether to replace
        /// the existing skill.
        case ready(
            package: ParsedSkillPackage,
            report: ValidationReport,
            collision: ExistingSkill?
        )

        var package: ParsedSkillPackage? {
            switch self {
            case .ready(let p, _, _), .warningsRequireConfirmation(let p, _, _):
                return p
            default: return nil
            }
        }

        var report: ValidationReport? {
            switch self {
            case .error(let r), .ready(_, let r, _),
                 .warningsRequireConfirmation(_, let r, _):
                return r
            case .notADirectory:
                return nil
            }
        }
    }

    /// Identifies a Skill row whose slug collides with the package being
    /// imported. The UI uses `id` to delete + reinstall on user confirmation.
    struct ExistingSkill: Equatable {
        let id: UUID
        let name: String
        let isBuiltIn: Bool
    }

    /// Validate a candidate source directory without copying anything to the
    /// live skills tree. The caller is responsible for `startAccessingSecurityScopedResource`
    /// on `sourceURL` if it came from the file picker.
    static func prepareImport(
        sourceURL: URL,
        modelContext: ModelContext
    ) -> Outcome {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDir),
              isDir.boolValue else {
            return .notADirectory
        }

        // Resolve the actual skill bundle inside the picked folder. Users
        // commonly pick the parent folder produced by unzipping (where the
        // bundle lives one level deeper). When the picked folder doesn't
        // have SKILL.md at its root, we look for exactly one subdirectory
        // that does and use that as the source.
        guard let resolvedURL = resolveSkillBundle(at: sourceURL) else {
            return .notADirectory
        }

        // Validate without the slug-match check: the importer always copies
        // to `<Documents>/Skills/<derivedSlug>/`, so the source folder name
        // is irrelevant. Slug-collision detection is handled separately via
        // `lookupCollision` and the UI's "replace existing?" prompt.
        let (parsed, report) = SkillPackage.parse(
            at: resolvedURL,
            knownSlugs: [],
            coreToolNames: coreToolNames(),
            enforceSlugMatch: false
        )

        guard report.ok, let pkg = parsed else {
            return .error(report: report)
        }

        let derivedSlug = SkillPackage.derivedSlug(
            forName: pkg.frontmatter.name,
            override: pkg.frontmatter.iclaw.slash
        )
        let collision = lookupCollision(forSlug: derivedSlug, modelContext: modelContext)

        if !report.warnings.isEmpty {
            return .warningsRequireConfirmation(package: pkg, report: report, collision: collision)
        }
        return .ready(package: pkg, report: report, collision: collision)
    }

    /// Walk the picked folder and return the URL of the actual skill bundle
    /// (the directory containing SKILL.md). Returns the input URL when it is
    /// itself a bundle, the single matching child when the user picked a
    /// wrapper folder, or nil when no usable bundle is found.
    private static func resolveSkillBundle(at url: URL) -> URL? {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.appendingPathComponent("SKILL.md").path) {
            return url
        }
        guard let children = try? fm.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        let candidates = children.filter { child in
            // Filter zip-leftover sidecars like __MACOSX. The actual content
            // check is "directory containing SKILL.md".
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: child.path, isDirectory: &isDir), isDir.boolValue else {
                return false
            }
            if child.lastPathComponent == "__MACOSX" { return false }
            return fm.fileExists(atPath: child.appendingPathComponent("SKILL.md").path)
        }
        // Exactly one candidate → use it. Zero or multiple → ambiguous,
        // surface the original "not a bundle directory" error.
        return candidates.count == 1 ? candidates.first : nil
    }

    /// Copy the validated package into `<Documents>/Skills/<slug>/` and
    /// materialize a `Skill` row.
    ///
    /// - Parameter replaceExisting: when true, an existing Skill row with the
    ///   same slug is deleted before the import (and its on-disk package
    ///   replaced). Built-in skills are never replaceable; if the collision
    ///   is built-in this throws.
    /// - Throws: `ImportError.builtInCollision`, `ImportError.copyFailed`,
    ///   `ImportError.slugUnchangedButExists` when the destination exists
    ///   and `replaceExisting` is false.
    @discardableResult
    static func commitImport(
        outcome: Outcome,
        replaceExisting: Bool,
        modelContext: ModelContext
    ) throws -> Skill {
        guard let pkg = outcome.package else {
            throw ImportError.notReady
        }
        let slug = SkillPackage.derivedSlug(forName: pkg.frontmatter.name)
        let destDir = AgentFileManager.shared.skillsRoot.appendingPathComponent(slug, isDirectory: true)

        if BuiltInSkills.shippedSlugs.contains(slug) {
            throw ImportError.builtInCollision(slug: slug)
        }

        let fm = FileManager.default

        // If the destination already exists, the caller must have explicitly
        // confirmed `replaceExisting`. Otherwise we abort to avoid silently
        // clobbering a user package.
        if fm.fileExists(atPath: destDir.path) {
            guard replaceExisting else {
                throw ImportError.slugUnchangedButExists(slug: slug)
            }
            try fm.removeItem(at: destDir)
        }

        // Create the parent if missing (first-ever user skill).
        let skillsRoot = AgentFileManager.shared.skillsRoot
        if !fm.fileExists(atPath: skillsRoot.path) {
            try fm.createDirectory(at: skillsRoot, withIntermediateDirectories: true)
        }

        do {
            try fm.copyItem(at: pkg.rootURL, to: destDir)
        } catch {
            throw ImportError.copyFailed(underlying: error)
        }

        // Replace any pre-existing Skill row for the same name (slug match
        // is conservative — names that diverged but derive to the same slug
        // would also be replaced; that's the intent of `replaceExisting`).
        let service = SkillService(modelContext: modelContext)
        if replaceExisting, let existing = service.fetchSkill(name: pkg.frontmatter.name) {
            // Built-ins are filtered above; this is safe for user skills.
            service.deleteSkill(existing)
        }

        let skill = service.createSkill(
            name: pkg.frontmatter.name,
            summary: pkg.description,
            content: pkg.body,
            tags: pkg.frontmatter.iclaw.tags,
            author: "imported",
            scripts: pkg.toSkillScripts(),
            customTools: pkg.toCustomTools()
        )
        if !pkg.displayName.isEmpty {
            skill.displayName = pkg.displayName
        }
        try? modelContext.save()
        return skill
    }

    enum ImportError: LocalizedError {
        case notReady
        case builtInCollision(slug: String)
        case slugUnchangedButExists(slug: String)
        case copyFailed(underlying: Error)

        var errorDescription: String? {
            switch self {
            case .notReady:
                return "Import outcome doesn't carry a parsed package."
            case .builtInCollision(let slug):
                return "Slug '\(slug)' is reserved by a built-in skill and cannot be replaced. Rename your package or fork the built-in via fs.cp."
            case .slugUnchangedButExists(let slug):
                return "A skill at /skills/\(slug)/ already exists. Confirm replacement to proceed."
            case .copyFailed(let underlying):
                return "Failed to copy package: \(underlying.localizedDescription)"
            }
        }
    }

    // MARK: - Internals

    private static func lookupCollision(forSlug slug: String, modelContext: ModelContext) -> ExistingSkill? {
        if BuiltInSkills.shippedSlugs.contains(slug) {
            // The slug-mismatch case won't reach here — built-in shipped
            // slugs match real bundle directories. Surface the collision so
            // the UI can refuse with a clean message.
            return ExistingSkill(id: UUID(), name: slug, isBuiltIn: true)
        }
        let descriptor = FetchDescriptor<Skill>()
        let all = (try? modelContext.fetch(descriptor)) ?? []
        for s in all where SkillPackage.derivedSlug(forName: s.name) == slug {
            return ExistingSkill(id: s.id, name: s.name, isBuiltIn: s.isBuiltIn)
        }
        return nil
    }

    /// Subset of core-tool names a skill must not shadow. Matched against
    /// META.name in the validator's `tool_name_shadows_core` rule. Kept
    /// narrow on purpose — the validator only needs to catch obvious
    /// conflicts, not every internal helper.
    private static func coreToolNames() -> Set<String> {
        [
            "read_config", "write_config",
            "install_skill", "uninstall_skill", "list_skills", "validate_skill",
            "run_snippet", "delete_code",
            "set_model", "get_model", "list_models",
            "file_list", "file_read", "file_write",
            "schedule_cron", "unschedule_cron", "list_cron",
            "browser_navigate", "browser_get_page_info", "browser_extract",
            "recall_session",
        ]
    }
}
