import Foundation
import SwiftData

/// LLM tool implementations for skill management.
///
/// Authoring (create / edit / delete / read) happens via the `fs.*` bridge
/// against the reserved `/skills/<slug>/` mount — there are no dedicated CRUD
/// tools. The remaining tools here are the per-agent binding concerns
/// (install / uninstall / list) plus the structural validator.
struct SkillTools {
    let agent: Agent
    let modelContext: ModelContext
    private let service: SkillService

    init(agent: Agent, modelContext: ModelContext) {
        self.agent = agent
        self.modelContext = modelContext
        self.service = SkillService(modelContext: modelContext)
    }

    // MARK: - install / uninstall

    /// Install a skill on the current agent.
    ///
    /// Lookup precedence:
    ///   1. Explicit `skill_id` (UUID) → existing Skill row.
    ///   2. `name` matches an existing Skill row → install that.
    ///   3. `name` (or `slug`) matches a `/skills/<slug>/` package on disk →
    ///      parse the package, materialize a `Skill` row from it, then install.
    ///
    /// The third path is what makes `fs.writeFile('/skills/foo/...')` followed
    /// by `install_skill name="Foo"` work end-to-end: an agent never has to
    /// touch the SwiftData layer to ship a new skill.
    func installSkill(arguments: [String: Any]) -> String {
        // (1) explicit skill_id
        if let idStr = arguments["skill_id"] as? String, let id = UUID(uuidString: idStr) {
            return installExistingSkill(id: id)
        }

        // (2) name → existing row
        if let name = arguments["name"] as? String, !name.isEmpty,
           let skill = service.fetchSkill(name: name) {
            return installExistingSkill(id: skill.id)
        }

        // (3) on-disk package → materialize and install
        let slugArg = (arguments["slug"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let nameArg = (arguments["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let candidateSlug: String? = slugArg
            ?? nameArg.map { SkillPackage.derivedSlug(forName: $0) }
        guard let slug = candidateSlug else {
            return "[Error] Provide either 'skill_id' (UUID), 'name', or 'slug' to identify the skill."
        }
        return installFromDisk(slug: slug)
    }

    private func installExistingSkill(id: UUID) -> String {
        guard let skill = service.fetchSkill(id: id) else {
            return "[Error] Skill not found"
        }
        if let _ = service.installSkill(skill, on: agent) {
            return formatInstallSuccess(skill)
        }
        return "Skill '\(skill.name)' is already installed on this agent."
    }

    private func installFromDisk(slug: String) -> String {
        let packageURL = AgentFileManager.shared.skillsRoot
            .appendingPathComponent(slug, isDirectory: true)
        guard FileManager.default.fileExists(atPath: packageURL.path) else {
            return "[Error] No installed skill or on-disk package found for '\(slug)'. Author one with `fs.writeFile('skills/\(slug)/SKILL.md', ...)` first, or check `list_skills`."
        }

        let (parsed, report) = SkillPackage.parse(at: packageURL)
        guard report.ok, let pkg = parsed else {
            // Surface the validator's report so the agent can fix the package.
            return "[Error] Skill package at /skills/\(slug)/ failed to validate. \(report.jsonString(pretty: false))"
        }

        if let existing = service.fetchSkill(name: pkg.frontmatter.name) {
            // Package was authored, then renamed via SKILL.md, then install
            // called — fall back to installing the existing row.
            return installExistingSkill(id: existing.id)
        }

        let skill = service.createSkill(
            name: pkg.frontmatter.name,
            summary: pkg.description,
            content: pkg.body,
            tags: pkg.frontmatter.iclaw.tags,
            author: agent.name,
            scripts: pkg.toSkillScripts(),
            customTools: pkg.toCustomTools()
        )
        if !pkg.displayName.isEmpty {
            skill.displayName = pkg.displayName
        }
        try? modelContext.save()

        guard let _ = service.installSkill(skill, on: agent) else {
            return "[Error] Failed to install '\(skill.name)' after creating its row."
        }
        var msg = "Skill '\(skill.name)' authored from /skills/\(slug)/ and installed on agent '\(agent.name)'."
        if !skill.scripts.isEmpty {
            msg += "\n- \(skill.scripts.count) script(s) registered as code snippets"
        }
        if !skill.customTools.isEmpty {
            let toolNames = skill.customTools.map {
                PromptBuilder.skillToolName(skillName: skill.name, toolName: $0.name)
            }
            msg += "\n- \(skill.customTools.count) custom tool(s): \(toolNames.joined(separator: ", "))"
        }
        return msg
    }

    private func formatInstallSuccess(_ skill: Skill) -> String {
        var msg = "Skill '\(skill.name)' installed on agent '\(agent.name)'. It will now be included in your system prompt."
        if !skill.scripts.isEmpty {
            msg += "\n- \(skill.scripts.count) script(s) registered as code snippets (use `run_snippet` to execute)"
        }
        if !skill.customTools.isEmpty {
            let toolNames = skill.customTools.map {
                PromptBuilder.skillToolName(skillName: skill.name, toolName: $0.name)
            }
            msg += "\n- \(skill.customTools.count) custom tool(s) now available: \(toolNames.joined(separator: ", "))"
        }
        return msg
    }

    func uninstallSkill(arguments: [String: Any]) -> String {
        guard let skillId = resolveSkillId(arguments) else {
            return "[Error] Provide either 'skill_id' (UUID) or 'name' to identify the skill"
        }
        guard let skill = service.fetchSkill(id: skillId) else {
            return "[Error] Skill not found"
        }
        if service.uninstallSkill(skill, from: agent) {
            return "Skill '\(skill.name)' uninstalled from agent '\(agent.name)'."
        }
        return "Skill '\(skill.name)' is not installed on this agent."
    }

    // MARK: - list

    /// List skills. Combines installed `Skill` rows with on-disk packages
    /// under `<Documents>/Skills/<slug>/` that have no row yet — so the agent
    /// can see packages it just authored but hasn't installed.
    func listSkills(arguments: [String: Any]) -> String {
        let query = (arguments["query"] as? String) ?? ""
        let scope = (arguments["scope"] as? String) ?? "all"

        switch scope {
        case "installed":
            return formatInstalledSkills()
        case "library", "all":
            let installedSkills = service.searchSkills(query: query)
            let installedNames = Set(installedSkills.map { SkillPackage.derivedSlug(forName: $0.name) })
            let unattached = unattachedDiskPackages(matching: query, excluding: installedNames)
            if installedSkills.isEmpty && unattached.isEmpty {
                return query.isEmpty
                    ? "(No skills in the library)"
                    : "(No skills matching '\(query)')"
            }
            var sections: [String] = []
            if !installedSkills.isEmpty {
                sections.append(formatLibrarySkills(installedSkills))
            }
            if !unattached.isEmpty {
                sections.append("**Authored but not installed** (call `install_skill name=\"<name>\"` to activate):")
                sections.append(unattached.joined(separator: "\n\n"))
            }
            return sections.joined(separator: "\n\n")
        default:
            return formatLibrarySkills(service.fetchAllSkills())
        }
    }

    /// Walk `<Documents>/Skills/` for slugs with no matching `Skill` row.
    /// Each entry is rendered as a single line so agents see them next to the
    /// installed skills.
    private func unattachedDiskPackages(matching query: String, excluding installedSlugs: Set<String>) -> [String] {
        let root = AgentFileManager.shared.skillsRoot
        guard let urls = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        var lines: [String] = []
        for dirURL in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dirURL.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let slug = dirURL.lastPathComponent
            if installedSlugs.contains(slug) { continue }
            let (parsed, report) = SkillPackage.parse(at: dirURL)
            if !report.ok || parsed == nil {
                lines.append("- **\(slug)** (parse errors — call `validate_skill slug=\"\(slug)\"`)")
                continue
            }
            guard let pkg = parsed else { continue }
            // Filter by query on name + description.
            if !query.isEmpty {
                let q = query.lowercased()
                let matches = pkg.frontmatter.name.lowercased().contains(q)
                    || pkg.description.lowercased().contains(q)
                    || pkg.frontmatter.iclaw.tags.contains(where: { $0.lowercased().contains(q) })
                if !matches { continue }
            }
            lines.append("- **\(pkg.frontmatter.name)** (slug: `\(slug)`) — \(pkg.description)")
        }
        return lines.sorted()
    }

    // MARK: - validate

    /// Validate the skill package at `<Documents>/Skills/<slug>/` (or the
    /// matching built-in) and return a JSON `ValidationReport`. The agent
    /// uses this after editing a package to check for parse errors before
    /// calling `install_skill`. Identical wire format to the auto-reload
    /// path's report — single source of truth lives in
    /// `SkillPackage.validate`.
    func validateSkill(arguments: [String: Any]) -> String {
        let slugArg = (arguments["slug"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let nameArg = (arguments["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let candidateSlug: String? = slugArg
            ?? nameArg.map { SkillPackage.derivedSlug(forName: $0) }
        guard let slug = candidateSlug else {
            return "[Error] Provide either 'slug' or 'name' to identify the package."
        }
        guard let url = packageURL(forSlug: slug) else {
            return "[Error] No package found at /skills/\(slug)/."
        }
        let knownSlugs = otherSlugs(excluding: slug)
        let report = SkillPackage.validate(at: url, knownSlugs: knownSlugs)
        return report.jsonString()
    }

    private func packageURL(forSlug slug: String) -> URL? {
        if BuiltInSkills.shippedSlugs.contains(slug) {
            return BuiltInSkillsDirectoryLoader.packageURL(forSlug: slug)
        }
        let url = AgentFileManager.shared.skillsRoot.appendingPathComponent(slug, isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Return the set of slugs that are NOT `slug` — used by the validator's
    /// `slug_collision` check so a fresh package can detect a name clash with
    /// every other registered skill.
    private func otherSlugs(excluding slug: String) -> Set<String> {
        var set = Set<String>(BuiltInSkills.shippedSlugs)
        let descriptor = FetchDescriptor<Skill>()
        let all = (try? modelContext.fetch(descriptor)) ?? []
        for s in all {
            set.insert(SkillPackage.derivedSlug(forName: s.name))
        }
        set.remove(slug)
        return set
    }

    // MARK: - Helpers

    private func resolveSkillId(_ arguments: [String: Any]) -> UUID? {
        if let idStr = arguments["skill_id"] as? String, let id = UUID(uuidString: idStr) {
            return id
        }
        if let name = arguments["name"] as? String, let skill = service.fetchSkill(name: name) {
            return skill.id
        }
        return nil
    }

    private func formatInstalledSkills() -> String {
        let installed = service.installedSkills(for: agent)
        if installed.isEmpty {
            return "(No skills installed on this agent)"
        }
        return installed.compactMap { inst in
            guard let skill = inst.skill else { return nil }
            let status = inst.isEnabled ? "active" : "disabled"
            return "- **\(skill.name)** [\(status)] — \(skill.summary)\n  ID: \(skill.id.uuidString)"
        }.joined(separator: "\n\n")
    }

    private func formatLibrarySkills(_ skills: [Skill]) -> String {
        let installed = Set(agent.installedSkills.compactMap { $0.skill?.id })
        return skills.map { skill in
            let marker = installed.contains(skill.id) ? " [installed]" : ""
            let builtIn = skill.isBuiltIn ? " (built-in)" : ""
            let tags = skill.tags.isEmpty ? "" : " [\(skill.tags.joined(separator: ", "))]"
            return "- **\(skill.name)**\(marker)\(builtIn)\(tags)\n  \(skill.summary)\n  ID: \(skill.id.uuidString)"
        }.joined(separator: "\n\n")
    }
}
