import XCTest
import SwiftData
@testable import iClaw

/// Phase 8a: round-trip tests for `SkillPackage.write` + the launch-time
/// `SkillService.migrateRowsToOnDiskPackages`.
@MainActor
final class SkillPackageWriteTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var scratchDir: URL!

    override func setUp() {
        super.setUp()
        let schema = Schema([Agent.self, LLMProvider.self, Session.self, AgentConfig.self,
                             CodeSnippet.self, CronJob.self, InstalledSkill.self, Skill.self,
                             Message.self, SessionEmbedding.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: schema, configurations: [config])
        context = ModelContext(container)
        scratchDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("write-tests-\(UUID().uuidString.prefix(8))")
    }

    override func tearDown() {
        if let d = scratchDir, FileManager.default.fileExists(atPath: d.path) {
            try? FileManager.default.removeItem(at: d)
        }
        // Clean up any user-skill scratch directories the migration created.
        let root = AgentFileManager.shared.skillsRoot
        if let contents = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            for url in contents where url.lastPathComponent.hasPrefix("legacy-") || url.lastPathComponent.hasPrefix("uitest-") {
                try? FileManager.default.removeItem(at: url)
            }
        }
        scratchDir = nil
        context = nil
        container = nil
        super.tearDown()
    }

    // MARK: - write round-trip

    func testWrite_minimalSkill_roundTripsThroughParser() throws {
        let svc = SkillService(modelContext: context)
        let skill = svc.createSkill(
            name: "Round Trip",
            summary: "A test of write + parse round-trip.",
            content: "# Round Trip\nBody content.",
            tags: ["test", "round-trip"]
        )

        let dest = scratchDir.appendingPathComponent("round-trip", isDirectory: true)
        try SkillPackage.write(skill, to: dest)

        let (parsed, report) = SkillPackage.parse(at: dest)
        XCTAssertTrue(report.ok, "Round-tripped package must validate cleanly. Errors: \(report.errors)")
        XCTAssertEqual(parsed?.frontmatter.name, "Round Trip")
        XCTAssertEqual(parsed?.description, "A test of write + parse round-trip.")
        XCTAssertEqual(parsed?.frontmatter.iclaw.tags, ["test", "round-trip"])
        XCTAssertTrue(parsed?.body.contains("Body content.") ?? false)
    }

    func testWrite_skillWithToolsAndScripts_roundTrips() throws {
        let svc = SkillService(modelContext: context)
        let skill = svc.createSkill(
            name: "Round Trip",
            summary: "Skill with tools and scripts.",
            content: "Body.",
            tags: [],
            scripts: [
                SkillScript(name: "helper", code: "console.log('helper');", description: "A helper script.")
            ],
            customTools: [
                SkillToolDefinition(
                    name: "greet",
                    description: "Greet the user.",
                    parameters: [
                        SkillToolParam(name: "who", type: "string", description: "The person to greet"),
                        SkillToolParam(name: "formal", type: "boolean", description: "Use formal greeting", required: false)
                    ],
                    implementation: "console.log(`Hi, ${args.who}!`);"
                )
            ]
        )

        let dest = scratchDir.appendingPathComponent("round-trip", isDirectory: true)
        try SkillPackage.write(skill, to: dest)

        let (parsed, report) = SkillPackage.parse(at: dest)
        XCTAssertTrue(report.ok, "Errors: \(report.errors)")

        let tools = parsed?.tools ?? []
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools.first?.meta.name, "greet")
        XCTAssertEqual(tools.first?.meta.description, "Greet the user.")
        XCTAssertEqual(tools.first?.meta.parameters.map(\.name), ["who", "formal"])
        XCTAssertEqual(tools.first?.meta.parameters[1].required, false)

        let scripts = parsed?.scripts ?? []
        XCTAssertEqual(scripts.count, 1)
        XCTAssertEqual(scripts.first?.description, "A helper script.")
        XCTAssertTrue(scripts.first?.code.contains("console.log('helper')") ?? false)
    }

    func testWrite_overwritesExistingDirectory() throws {
        let svc = SkillService(modelContext: context)
        let skill = svc.createSkill(
            name: "Overwrite",
            summary: "First version.",
            content: "Body v1.",
            tags: []
        )
        let dest = scratchDir.appendingPathComponent("overwrite", isDirectory: true)
        try SkillPackage.write(skill, to: dest)

        // Drop a stale file inside; subsequent write must remove it.
        try "stale".write(
            to: dest.appendingPathComponent("stale.txt"),
            atomically: true, encoding: .utf8
        )

        skill.summary = "Second version."
        try SkillPackage.write(skill, to: dest)

        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.appendingPathComponent("stale.txt").path),
                       "Stale file should be removed when the destination is overwritten")
        let (parsed, _) = SkillPackage.parse(at: dest)
        XCTAssertEqual(parsed?.description, "Second version.")
    }

    func testWrite_invalidToolNameThrows() {
        let svc = SkillService(modelContext: context)
        let skill = svc.createSkill(
            name: "BadTool",
            summary: "x",
            content: "body",
            tags: [],
            customTools: [
                SkillToolDefinition(
                    name: "has-hyphen",  // not a valid JS identifier
                    description: "x", parameters: [],
                    implementation: "console.log('x');"
                )
            ]
        )
        let dest = scratchDir.appendingPathComponent("bad-tool", isDirectory: true)
        XCTAssertThrowsError(try SkillPackage.write(skill, to: dest)) { err in
            guard case SkillPackage.WriteError.invalidToolName = err else {
                return XCTFail("Expected invalidToolName, got \(err)")
            }
        }
    }

    // MARK: - migration

    func testMigration_createsPackageForLegacyRow() throws {
        let svc = SkillService(modelContext: context)
        let skill = svc.createSkill(
            name: "Legacy Skill",
            summary: "Created before Phase 4.",
            content: "Methodology body.",
            tags: ["legacy"]
        )
        let slug = SkillPackage.derivedSlug(forName: skill.name)
        let dest = AgentFileManager.shared.skillsRoot.appendingPathComponent(slug)
        // Sanity: no on-disk package yet.
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))

        svc.migrateRowsToOnDiskPackages()

        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("SKILL.md").path),
                      "Migration should materialize the on-disk package")
        let (parsed, report) = SkillPackage.parse(at: dest)
        XCTAssertTrue(report.ok, "Migrated package must validate. Errors: \(report.errors)")
        XCTAssertEqual(parsed?.frontmatter.name, "Legacy Skill")
    }

    func testMigration_skipsExistingPackage() throws {
        let svc = SkillService(modelContext: context)
        let skill = svc.createSkill(
            name: "Legacy Skill",
            summary: "x", content: "first body", tags: []
        )
        let slug = SkillPackage.derivedSlug(forName: skill.name)
        let dest = AgentFileManager.shared.skillsRoot.appendingPathComponent(slug)
        try SkillPackage.write(skill, to: dest)
        // Mutate the on-disk body to verify migration doesn't clobber it.
        try "---\nname: Legacy Skill\ndescription: edited\n---\nedited body".write(
            to: dest.appendingPathComponent("SKILL.md"),
            atomically: true, encoding: .utf8
        )

        svc.migrateRowsToOnDiskPackages()

        let onDiskBody = try String(contentsOf: dest.appendingPathComponent("SKILL.md"))
        XCTAssertTrue(onDiskBody.contains("edited body"),
                      "Migration must not overwrite an existing package")
    }

    func testMigration_skipsBuiltIns() {
        // Build out built-ins so they get rows.
        SkillService(modelContext: context).ensureBuiltInSkills()
        // Migration walks user skills only; built-ins live in the bundle
        // (read-only) and migrating them would clobber the canonical
        // bundle source. Verify by counting how many directories migration
        // would touch under /Documents/Skills/.
        SkillService(modelContext: context).migrateRowsToOnDiskPackages()
        let root = AgentFileManager.shared.skillsRoot
        let contents = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for url in contents {
            XCTAssertFalse(BuiltInSkills.shippedSlugs.contains(url.lastPathComponent),
                           "Built-in slug \(url.lastPathComponent) should not appear under /Documents/Skills/")
        }
    }
}
