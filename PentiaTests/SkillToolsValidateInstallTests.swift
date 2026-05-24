import XCTest
import SwiftData
@testable import Pentia

/// Phase 4d coverage for `SkillTools`:
///   - `validate_skill` returns the same JSON ValidationReport shape every
///     other consumer sees, keyed by slug or by name.
///   - `install_skill` falls back to materializing a Skill row from a
///     `<Documents>/Skills/<slug>/` package when no row exists yet — the
///     fs-authoring → install_skill end-to-end flow.
///   - `list_skills` surfaces authored-but-uninstalled packages.
final class SkillToolsValidateInstallTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var agent: Agent!
    private var tools: SkillTools!
    private var scratchSlug: String!
    private var scratchURL: URL!

    @MainActor
    override func setUp() {
        super.setUp()
        let schema = Schema([Agent.self, LLMProvider.self, Session.self, AgentConfig.self,
                             CodeSnippet.self, CronJob.self, InstalledSkill.self, Skill.self,
                             Message.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: schema, configurations: [config])
        context = ModelContext(container)
        agent = Agent(name: "TestAgent")
        context.insert(agent)
        try! context.save()
        tools = SkillTools(agent: agent, modelContext: context)

        scratchSlug = "test-tools-\(UUID().uuidString.prefix(8).lowercased())"
        scratchURL = AgentFileManager.shared.skillsRoot
            .appendingPathComponent(scratchSlug, isDirectory: true)
    }

    override func tearDown() {
        if let url = scratchURL, FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        scratchURL = nil
        scratchSlug = nil
        tools = nil
        agent = nil
        context = nil
        container = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func writeValidPackage() throws {
        let canonicalName = humanName(forSlug: scratchSlug)
        try FileManager.default.createDirectory(
            at: scratchURL.appendingPathComponent("tools"),
            withIntermediateDirectories: true
        )
        try """
        ---
        name: \(canonicalName)
        description: Test skill from disk.
        ---

        # \(canonicalName)
        Body.
        """.write(
            to: scratchURL.appendingPathComponent("SKILL.md"),
            atomically: true, encoding: .utf8
        )
        try """
        const META = {
          name: "greet",
          description: "Greet the user politely.",
          parameters: []
        };
        console.log("hello");
        """.write(
            to: scratchURL.appendingPathComponent("tools/greet.js"),
            atomically: true, encoding: .utf8
        )
    }

    private func humanName(forSlug slug: String) -> String {
        slug.split(separator: "-").map { $0.capitalized }.joined(separator: " ")
    }

    // MARK: - validate_skill

    @MainActor
    func testValidate_unknownSlugReturnsError() {
        let result = tools.validateSkill(arguments: ["slug": "no-such-skill"])
        XCTAssertTrue(result.contains("[Error]"), "Expected error for unknown slug, got: \(result)")
    }

    @MainActor
    func testValidate_validPackageReturnsOk() throws {
        try writeValidPackage()
        let result = tools.validateSkill(arguments: ["slug": scratchSlug!])
        XCTAssertTrue(result.contains("\"errors\"") && result.contains("\"warnings\""),
                      "Expected JSON ValidationReport, got: \(result)")
        XCTAssertFalse(result.contains("missing_field"))
        XCTAssertFalse(result.contains("frontmatter_malformed"))
    }

    @MainActor
    func testValidate_byName() throws {
        try writeValidPackage()
        let canonicalName = humanName(forSlug: scratchSlug)
        let result = tools.validateSkill(arguments: ["name": canonicalName])
        XCTAssertTrue(result.contains("\"errors\""), "validate by name should also work, got: \(result)")
    }

    @MainActor
    func testValidate_brokenPackageSurfacesErrors() throws {
        try FileManager.default.createDirectory(at: scratchURL, withIntermediateDirectories: true)
        try "---\nname: Bad\n".write(  // missing closing delimiter
            to: scratchURL.appendingPathComponent("SKILL.md"),
            atomically: true, encoding: .utf8
        )
        let result = tools.validateSkill(arguments: ["slug": scratchSlug!])
        XCTAssertTrue(result.contains("frontmatter_malformed") || result.contains("frontmatter_missing"),
                      "Expected frontmatter error, got: \(result)")
    }

    @MainActor
    func testValidate_builtInSkillCleanReport() {
        let result = tools.validateSkill(arguments: ["slug": "deep-research"])
        XCTAssertTrue(result.contains("\"errors\""), "Expected JSON, got: \(result)")
        // Built-ins must always validate cleanly — they're the canonical
        // examples agents copy from.
        XCTAssertFalse(result.contains("\"severity\":\"error\""),
                       "Built-in deep-research should have no errors, got: \(result)")
    }

    // MARK: - install_skill from disk

    @MainActor
    func testInstall_fromOnDiskPackageMaterializesAndInstalls() throws {
        try writeValidPackage()
        let canonicalName = humanName(forSlug: scratchSlug)

        let result = tools.installSkill(arguments: ["slug": scratchSlug!])
        XCTAssertFalse(result.hasPrefix("[Error]"),
                       "Install from disk should succeed, got: \(result)")
        XCTAssertTrue(result.contains(canonicalName),
                      "Result should reference the materialized skill name, got: \(result)")

        // Skill row was created.
        XCTAssertNotNil(SkillService(modelContext: context).fetchSkill(name: canonicalName))
        // Agent has it bound.
        XCTAssertTrue(agent.installedSkills.contains { $0.skill?.name == canonicalName })
    }

    @MainActor
    func testInstall_fromOnDiskByName() throws {
        try writeValidPackage()
        let canonicalName = humanName(forSlug: scratchSlug)
        let result = tools.installSkill(arguments: ["name": canonicalName])
        XCTAssertFalse(result.hasPrefix("[Error]"),
                       "Install by name (no row yet) should fall back to disk, got: \(result)")
        XCTAssertNotNil(SkillService(modelContext: context).fetchSkill(name: canonicalName))
    }

    @MainActor
    func testInstall_brokenOnDiskPackageReturnsValidationErrors() throws {
        try FileManager.default.createDirectory(at: scratchURL, withIntermediateDirectories: true)
        try "---\nname: Bad\n".write(
            to: scratchURL.appendingPathComponent("SKILL.md"),
            atomically: true, encoding: .utf8
        )
        let result = tools.installSkill(arguments: ["slug": scratchSlug!])
        XCTAssertTrue(result.hasPrefix("[Error]"),
                      "Install of a broken package should surface validation errors, got: \(result)")
        XCTAssertTrue(result.contains("frontmatter") || result.contains("validate"),
                      "Error should explain why, got: \(result)")
    }

    @MainActor
    func testInstall_unknownSlugReturnsError() {
        let result = tools.installSkill(arguments: ["slug": "no-such-skill"])
        XCTAssertTrue(result.hasPrefix("[Error]"), "Unknown slug should error, got: \(result)")
    }

    // MARK: - list_skills with on-disk discovery

    @MainActor
    func testList_includesAuthoredButUninstalledPackages() throws {
        try writeValidPackage()
        // Don't call installSkill — the package exists on disk only.

        let result = tools.listSkills(arguments: ["scope": "all"])
        XCTAssertTrue(result.contains("Authored but not installed"),
                      "list should surface uninstalled disk packages, got: \(result)")
        XCTAssertTrue(result.contains(scratchSlug),
                      "list should mention the scratch slug, got: \(result)")
    }

    @MainActor
    func testList_omitsAuthoredPackagesAfterInstall() throws {
        try writeValidPackage()
        _ = tools.installSkill(arguments: ["slug": scratchSlug!])

        let result = tools.listSkills(arguments: ["scope": "all"])
        let canonicalName = humanName(forSlug: scratchSlug)
        XCTAssertTrue(result.contains(canonicalName),
                      "Installed package should appear somewhere in the list, got: \(result)")
        XCTAssertFalse(result.contains("slug: `\(scratchSlug!)`)"),
                       "After install, the package should not appear in the authored-but-uninstalled section, got: \(result)")
    }
}
