import Foundation
import SwiftData

final class SkillService {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    private func save() {
        do {
            try modelContext.save()
        } catch {
            print("[SkillService] Save failed: \(error.localizedDescription)")
        }
    }

    // MARK: - CRUD

    func createSkill(
        name: String,
        summary: String,
        content: String,
        tags: [String] = [],
        author: String = "user",
        scripts: [SkillScript] = [],
        customTools: [SkillToolDefinition] = [],
        configSchema: [SkillConfigField] = []
    ) -> Skill {
        let skill = Skill(
            name: name,
            summary: summary,
            content: content,
            tags: tags,
            author: author,
            scripts: scripts,
            customTools: customTools,
            configSchema: configSchema
        )
        modelContext.insert(skill)
        save()
        return skill
    }

    func updateSkill(_ skill: Skill, name: String? = nil, summary: String? = nil, content: String? = nil, tags: [String]? = nil) {
        if let name {
            skill.name = name
            skill.nameLowercase = name.lowercased()
        }
        if let summary { skill.summary = summary }
        if let content { skill.content = content }
        if let tags { skill.tags = tags }
        skill.updatedAt = Date()
        save()
    }

    func deleteSkill(_ skill: Skill) {
        guard !skill.isBuiltIn else { return }
        // Remove the on-disk package mirror first so a deleted skill leaves
        // no orphan directory under <Documents>/Skills/. Best-effort: a
        // missing package (e.g. legacy row that hadn't been migrated yet)
        // is fine — try? swallows the error.
        let slug = SkillPackage.derivedSlug(forName: skill.name)
        if !slug.isEmpty, !BuiltInSkills.shippedSlugs.contains(slug) {
            let url = AgentFileManager.shared.skillsRoot
                .appendingPathComponent(slug, isDirectory: true)
            try? FileManager.default.removeItem(at: url)
        }
        modelContext.delete(skill)
        save()
    }

    func fetchSkill(id: UUID) -> Skill? {
        var descriptor = FetchDescriptor<Skill>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    func fetchSkill(name: String) -> Skill? {
        let lowered = name.lowercased()
        var descriptor = FetchDescriptor<Skill>(
            predicate: #Predicate { $0.nameLowercase == lowered }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    func fetchAllSkills() -> [Skill] {
        let descriptor = FetchDescriptor<Skill>(
            sortBy: [SortDescriptor(\.name)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    func searchSkills(query: String) -> [Skill] {
        guard !query.isEmpty else { return fetchAllSkills() }
        let descriptor = FetchDescriptor<Skill>(
            predicate: #Predicate {
                $0.name.localizedStandardContains(query) ||
                $0.displayName.localizedStandardContains(query) ||
                $0.summary.localizedStandardContains(query) ||
                $0.tagsRaw.localizedStandardContains(query)
            },
            sortBy: [SortDescriptor(\.name)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    // MARK: - Installation

    func installSkill(_ skill: Skill, on agent: Agent) -> InstalledSkill? {
        if agent.installedSkills.contains(where: { $0.skill?.id == skill.id }) {
            return nil
        }
        let installation = InstalledSkill()
        modelContext.insert(installation)
        agent.installedSkills.append(installation)
        installation.skill = skill

        // Register skill scripts as CodeSnippets on the agent
        for script in skill.scripts {
            let snippetName = "skill:\(skill.name):\(script.name)"
            if !agent.codeSnippets.contains(where: { $0.name == snippetName }) {
                let snippet = CodeSnippet(name: snippetName, language: script.language, code: script.code)
                modelContext.insert(snippet)
                agent.codeSnippets.append(snippet)
            }
        }

        agent.updatedAt = Date()
        save()
        return installation
    }

    func uninstallSkill(_ skill: Skill, from agent: Agent) -> Bool {
        guard let installation = agent.installedSkills.first(where: { $0.skill?.id == skill.id }) else {
            return false
        }
        modelContext.delete(installation)

        // Clean up skill-registered CodeSnippets
        let prefix = "skill:\(skill.name):"
        let toRemove = agent.codeSnippets.filter { $0.name.hasPrefix(prefix) }
        for snippet in toRemove {
            modelContext.delete(snippet)
        }

        agent.updatedAt = Date()
        save()
        return true
    }

    func toggleSkill(_ installation: InstalledSkill) {
        installation.isEnabled.toggle()
        installation.agent?.updatedAt = Date()
        save()
    }

    func isInstalled(_ skill: Skill, on agent: Agent) -> Bool {
        agent.installedSkills.contains { $0.skill?.id == skill.id }
    }

    func installedSkills(for agent: Agent) -> [InstalledSkill] {
        agent.installedSkills.sorted { ($0.skill?.name ?? "") < ($1.skill?.name ?? "") }
    }

    // MARK: - One-time migration: row → on-disk package

    /// Plan a row → on-disk migration without touching disk. Walks every
    /// non-built-in `Skill` row and snapshots the ones whose backing
    /// directory is missing. The returned `[Pending]` is plain Sendable
    /// values, safe to hand to a `Task.detached` for off-main commit —
    /// keeping the launch thread free of disk I/O even when the user has
    /// many legacy skills to migrate.
    ///
    /// Must be called on the actor that owns `modelContext` (typically
    /// @MainActor). Idempotent: skills whose package directory already
    /// exists are skipped.
    func planMigrationToOnDiskPackages() -> [PendingMigration] {
        let descriptor = FetchDescriptor<Skill>(
            predicate: #Predicate { $0.isBuiltIn == false }
        )
        let userSkills = (try? modelContext.fetch(descriptor)) ?? []
        let fm = FileManager.default
        let root = AgentFileManager.shared.skillsRoot
        var pending: [PendingMigration] = []
        for skill in userSkills {
            let slug = SkillPackage.derivedSlug(forName: skill.name)
            guard !slug.isEmpty else { continue }
            // Slug collision with a built-in: never clobber the bundle
            // path. Legacy row keeps working through SwiftData; the user
            // can rename it later if they want a backing directory.
            if BuiltInSkills.shippedSlugs.contains(slug) { continue }

            let dest = root.appendingPathComponent(slug, isDirectory: true)
            if fm.fileExists(atPath: dest.path) { continue }

            pending.append(PendingMigration(
                destination: dest,
                snapshot: SkillPackage.snapshot(of: skill)
            ))
        }
        return pending
    }

    /// Synchronous one-shot migration kept for tests and any caller that
    /// doesn't care about main-thread cost. The launch path uses
    /// `planMigrationToOnDiskPackages` + a detached task to keep the
    /// launch thread free of disk I/O.
    func migrateRowsToOnDiskPackages() {
        let pending = planMigrationToOnDiskPackages()
        Self.commitPendingMigrations(pending)
    }

    /// Commit a previously-planned migration to disk. Pure I/O — safe to
    /// invoke from any actor. Failures are logged but don't block
    /// subsequent commits.
    static func commitPendingMigrations(_ pending: [PendingMigration]) {
        guard !pending.isEmpty else { return }
        let root = AgentFileManager.shared.skillsRoot
        if !FileManager.default.fileExists(atPath: root.path) {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        for item in pending {
            do {
                try SkillPackage.commit(item.snapshot, to: item.destination)
            } catch {
                print("[SkillService] migration failed for '\(item.snapshot.name)': \(error.localizedDescription)")
            }
        }
    }

    /// One pending row → directory write captured by
    /// `planMigrationToOnDiskPackages`. All-Sendable so it can travel
    /// across actors.
    struct PendingMigration: Sendable, Hashable {
        let destination: URL
        let snapshot: SkillPackage.WriteSnapshot
    }

    // MARK: - Built-in Skills

    func ensureBuiltInSkills() {
        let descriptor = FetchDescriptor<Skill>(
            predicate: #Predicate { $0.isBuiltIn == true }
        )
        let existing = (try? modelContext.fetch(descriptor)) ?? []
        let existingByName = Dictionary(uniqueKeysWithValues: existing.map { ($0.name, $0) })

        let resolved = BuiltInSkills.allResolvedTemplates()
        let templateNames = Set(resolved.map(\.name))

        for template in resolved {
            if let skill = existingByName[template.name] {
                // Upgrade existing built-in skill if template has changed
                upgradeBuiltInSkill(skill, from: template)
            } else {
                let skill = Skill(
                    name: template.name,
                    summary: template.summary,
                    content: template.content,
                    tags: template.tags,
                    author: "system",
                    isBuiltIn: true,
                    scripts: template.scripts,
                    customTools: template.customTools,
                    configSchema: template.configSchema
                )
                skill.displayName = template.displayName
                modelContext.insert(skill)
            }
        }

        // Demote any previously-built-in skill whose template has been removed.
        // Keep the record so existing installations keep working, but flip
        // `isBuiltIn` so users can edit/delete them like ordinary skills.
        for skill in existing where !templateNames.contains(skill.name) {
            skill.isBuiltIn = false
            skill.author = "system (legacy)"
            skill.displayName = ""
            skill.updatedAt = Date()
        }

        save()
    }

    /// Update an existing built-in skill to match the latest template.
    /// Only updates fields that have changed to avoid unnecessary writes.
    /// Diffing on `content` / `summary` / `displayName` also naturally handles
    /// UI-language switches: resolving the template in a new locale produces
    /// different strings, which trip the diff and rewrite the DB row.
    private func upgradeBuiltInSkill(_ skill: Skill, from template: BuiltInSkills.ResolvedTemplate) {
        var changed = false

        if skill.displayName != template.displayName {
            skill.displayName = template.displayName
            changed = true
        }
        if skill.content != template.content {
            skill.content = template.content
            changed = true
        }
        if skill.summary != template.summary {
            skill.summary = template.summary
            changed = true
        }
        if skill.tags != template.tags {
            skill.tags = template.tags
            changed = true
        }
        if skill.scripts != template.scripts {
            skill.scripts = template.scripts
            changed = true
        }
        if skill.customTools != template.customTools {
            skill.customTools = template.customTools
            changed = true
        }
        if skill.configSchema != template.configSchema {
            skill.configSchema = template.configSchema
            changed = true
        }
        // Backfill nameLowercase for skills created before this field existed
        if skill.nameLowercase.isEmpty {
            skill.nameLowercase = skill.name.lowercased()
            changed = true
        }

        if changed {
            skill.updatedAt = Date()
        }
    }

    // MARK: - Discover orphan disk packages

    /// Walk `<Documents>/Skills/` and create `Skill` rows for any package
    /// that parses cleanly but has no matching row. Lets users drop a skill
    /// folder into the Documents/Skills directory (via Files.app, a zip
    /// extraction, Working Copy, etc.) and have it picked up the next time
    /// the library view appears or the app launches — no manual import or
    /// agent-mediated `install_skill` step required.
    ///
    /// Existing rows are never touched; the on-disk-write path
    /// (`SkillsAutoReloader` + `reload(slug:)`) handles those. Packages
    /// whose name collides with an existing Skill are skipped to avoid
    /// silently clobbering user data.
    @discardableResult
    func discoverDiskPackages() -> [Skill] {
        let fm = FileManager.default
        let root = AgentFileManager.shared.skillsRoot
        guard fm.fileExists(atPath: root.path),
              let urls = try? fm.contentsOfDirectory(
                  at: root, includingPropertiesForKeys: [.isDirectoryKey],
                  options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        let descriptor = FetchDescriptor<Skill>()
        let allRows = (try? modelContext.fetch(descriptor)) ?? []
        let knownSlugs = Set(allRows.map { SkillPackage.derivedSlug(forName: $0.name) })
        let knownNames = Set(allRows.map { $0.name.lowercased() })

        var created: [Skill] = []
        for dirURL in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dirURL.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let slug = dirURL.lastPathComponent
            if BuiltInSkills.shippedSlugs.contains(slug) { continue }
            if knownSlugs.contains(slug) { continue }

            let (parsed, report) = SkillPackage.parse(at: dirURL)
            guard report.ok, let pkg = parsed else { continue }

            // Avoid clobbering: if a row by this name already exists (under a
            // different slug), skip — the user can resolve via the importer.
            if knownNames.contains(pkg.frontmatter.name.lowercased()) { continue }

            let skill = createSkill(
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
            created.append(skill)
        }
        if !created.isEmpty { save() }
        return created
    }

    // MARK: - Reload (file-system → cache)

    /// Re-parse the on-disk package for `slug` and update the matching `Skill`
    /// row's cached fields (`content`, `summary`, `displayName`, `scripts`,
    /// `customTools`). On parse failure the cache is left untouched — the
    /// last good version of the skill keeps running until the package is
    /// fixed (the "broken-edit resilience" property documented in the
    /// proposal). The returned `ValidationReport` always reflects the latest
    /// parse attempt; callers surface its errors / warnings to the user.
    ///
    /// Returns `nil` when the slug is unknown (no matching `Skill` row, no
    /// built-in package) — there's nothing to reload.
    @discardableResult
    func reload(slug: String) -> ValidationReport? {
        guard let url = Self.packageURL(forSlug: slug) else { return nil }
        let (parsed, report) = SkillPackage.parse(at: url)

        // Last-good cache: parse failed → leave the existing Skill row as-is.
        // The report still surfaces every error/warning so callers can show
        // them.
        guard report.ok, let pkg = parsed else { return report }

        // Find the installed Skill row whose derived slug matches. For new
        // packages with no installed row yet, this is a no-op — install_skill
        // is the entry point that creates the row.
        guard let skill = skillForSlug(slug) else { return report }

        let oldName = skill.name
        let newScripts = pkg.toSkillScripts()
        let newTools = pkg.toCustomTools()

        var changed = false
        if skill.content != pkg.body { skill.content = pkg.body; changed = true }
        if skill.summary != pkg.description { skill.summary = pkg.description; changed = true }
        if !pkg.displayName.isEmpty, skill.displayName != pkg.displayName {
            skill.displayName = pkg.displayName
            changed = true
        }
        if skill.tags != pkg.frontmatter.iclaw.tags {
            skill.tags = pkg.frontmatter.iclaw.tags
            changed = true
        }
        if skill.scripts != newScripts {
            skill.scripts = newScripts
            changed = true
        }
        if skill.customTools != newTools {
            skill.customTools = newTools
            changed = true
        }
        if changed {
            skill.updatedAt = Date()
            save()
            // Re-sync per-agent CodeSnippet rows so `run_snippet` invocations
            // pick up renamed / modified scripts on the next turn.
            resyncSnippetsForReloadedSkill(skill, oldName: oldName)
        }
        return report
    }

    /// Look up the installed `Skill` whose name derives to `slug`. Slow
    /// (linear scan) but the built-in + user skill count is small.
    private func skillForSlug(_ slug: String) -> Skill? {
        let descriptor = FetchDescriptor<Skill>()
        let all = (try? modelContext.fetch(descriptor)) ?? []
        return all.first { SkillPackage.derivedSlug(forName: $0.name) == slug }
    }

    /// Resolve a slug to its on-disk package URL. Built-ins live in the read-
    /// only app bundle; user skills live under `<Documents>/Skills/<slug>/`.
    /// Returns `nil` when neither location exists.
    private static func packageURL(forSlug slug: String) -> URL? {
        if BuiltInSkills.shippedSlugs.contains(slug) {
            return BuiltInSkillsDirectoryLoader.packageURL(forSlug: slug)
        }
        let url = AgentFileManager.shared.skillsRoot.appendingPathComponent(slug, isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Re-register CodeSnippets for every agent that has the reloaded skill
    /// installed. Mirror of `SkillTools.resyncInstalledSnippets`. Phase 4d
    /// will fold these two implementations together.
    private func resyncSnippetsForReloadedSkill(_ skill: Skill, oldName: String) {
        for installation in skill.installations {
            guard let agent = installation.agent else { continue }
            // Purge stale entries (by old name prefix; covers renames and
            // removed scripts).
            let oldPrefix = "skill:\(oldName):"
            let newPrefix = "skill:\(skill.name):"
            let stale = agent.codeSnippets.filter {
                $0.name.hasPrefix(oldPrefix) || $0.name.hasPrefix(newPrefix)
            }
            for snip in stale {
                agent.codeSnippets.removeAll { $0.id == snip.id }
                modelContext.delete(snip)
            }
            // Insert fresh entries from the latest scripts.
            for script in skill.scripts {
                let snip = CodeSnippet(
                    name: "\(newPrefix)\(script.name)",
                    language: script.language,
                    code: script.code
                )
                modelContext.insert(snip)
                agent.codeSnippets.append(snip)
            }
            agent.updatedAt = Date()
        }
        save()
    }
}
