import XCTest
import SwiftData
@testable import iClaw

/// Phase 4c: SkillService.reload(slug:) with last-good cache semantics.
///
/// Validates that:
/// - A user-skill rewrite refreshes the cached Skill row's fields.
/// - A broken edit (parse error) leaves the cache untouched and returns the
///   error report — the "last-good" property documented in the proposal.
/// - Reloading a slug with no installed Skill row is a no-op + report.
/// - Built-in skills can be reloaded against the bundle.
final class SkillServiceReloadTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var service: SkillService!
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
        service = SkillService(modelContext: context)

        scratchSlug = "test-reload-\(UUID().uuidString.prefix(8).lowercased())"
        scratchURL = AgentFileManager.shared.skillsRoot
            .appendingPathComponent(scratchSlug, isDirectory: true)
    }

    override func tearDown() {
        if let url = scratchURL, FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        scratchURL = nil
        scratchSlug = nil
        service = nil
        context = nil
        container = nil
        super.tearDown()
    }

    // MARK: - Helpers

    @MainActor
    private func installFromPackage(name: String, description: String) -> Skill {
        let skill = service.createSkill(
            name: name,
            summary: description,
            content: "stale body",
            tags: [],
            scripts: [],
            customTools: []
        )
        return skill
    }

    // MARK: - Tests

    @MainActor
    func testReload_emptySlugReturnsNil() {
        // No package on disk for an unknown slug.
        let report = service.reload(slug: "no-such-skill")
        XCTAssertNil(report, "Reload for an unknown slug should return nil (no-op)")
    }

    @MainActor
    func testReload_userSkillRefreshesCachedFields() throws {
        // The package's frontmatter `name` must derive to the same slug as
        // the directory name; otherwise SkillPackage.validate emits a
        // slug_mismatch error and reload bails out before touching the cache.
        let canonicalName = humanName(forSlug: scratchSlug)
        try FileManager.default.createDirectory(at: scratchURL, withIntermediateDirectories: true)
        try """
        ---
        name: \(canonicalName)
        description: Original description
        ---

        # Body
        Original body.
        """.write(
            to: scratchURL.appendingPathComponent("SKILL.md"),
            atomically: true, encoding: .utf8
        )

        let skill = installFromPackage(name: canonicalName, description: "Original description")
        XCTAssertEqual(skill.summary, "Original description")
        XCTAssertEqual(skill.content, "stale body")

        let report = service.reload(slug: scratchSlug)
        XCTAssertNotNil(report)
        XCTAssertTrue(report?.ok ?? false, "Expected clean report, got: \(String(describing: report))")
        XCTAssertTrue(skill.content.contains("Original body"),
                      "Reload should refresh content from SKILL.md, got: \(skill.content)")
    }

    @MainActor
    func testReload_brokenPackageKeepsLastGoodCache() throws {
        let canonicalName = humanName(forSlug: scratchSlug)
        let skill = installFromPackage(name: canonicalName, description: "good summary")
        let originalContent = skill.content
        let originalSummary = skill.summary

        // Write a broken SKILL.md (missing closing delimiter).
        try FileManager.default.createDirectory(at: scratchURL, withIntermediateDirectories: true)
        try "---\nname: \(canonicalName)\n".write(
            to: scratchURL.appendingPathComponent("SKILL.md"),
            atomically: true, encoding: .utf8
        )

        let report = service.reload(slug: scratchSlug)
        XCTAssertNotNil(report)
        XCTAssertFalse(report?.ok ?? true, "Broken package should produce errors")
        // Cache must be untouched — last-good property.
        XCTAssertEqual(skill.content, originalContent, "Content should keep last-good value")
        XCTAssertEqual(skill.summary, originalSummary, "Summary should keep last-good value")
    }

    @MainActor
    func testReload_packageWithNoMatchingSkillRowIsNoop() throws {
        // Write a valid package without installing a Skill row first.
        let canonicalName = humanName(forSlug: scratchSlug)
        try FileManager.default.createDirectory(at: scratchURL, withIntermediateDirectories: true)
        try """
        ---
        name: \(canonicalName)
        description: A skill not yet installed.
        ---
        Body.
        """.write(
            to: scratchURL.appendingPathComponent("SKILL.md"),
            atomically: true, encoding: .utf8
        )

        let report = service.reload(slug: scratchSlug)
        XCTAssertNotNil(report)
        XCTAssertTrue(report?.ok ?? false, "Package itself should validate cleanly")
    }

    @MainActor
    func testReload_builtInRefreshesFromBundle() {
        // The built-in's Skill row exists after ensureBuiltInSkills.
        service.ensureBuiltInSkills()
        let report = service.reload(slug: "deep-research")
        XCTAssertNotNil(report)
        XCTAssertTrue(report?.ok ?? false, "Built-in should reload cleanly: \(String(describing: report))")
    }

    // MARK: - Slug → human name helper

    /// Reverse-engineer a human-readable name that derives to `slug`. Required
    /// because the SkillService matches Skill rows to slugs by deriving the
    /// slug from the name field — we need the names to round-trip.
    private func humanName(forSlug slug: String) -> String {
        slug.split(separator: "-").map { $0.capitalized }.joined(separator: " ")
    }
}
