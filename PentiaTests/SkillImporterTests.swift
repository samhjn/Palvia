import XCTest
import SwiftData
@testable import iClaw

/// Phase 7a: SkillImporter — directory-based import with validate-then-copy
/// semantics.
@MainActor
final class SkillImporterTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var scratchSource: URL!
    private var scratchDest: URL!

    override func setUp() {
        super.setUp()
        let schema = Schema([Agent.self, LLMProvider.self, Session.self, AgentConfig.self,
                             CodeSnippet.self, CronJob.self, InstalledSkill.self, Skill.self,
                             Message.self, SessionEmbedding.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: schema, configurations: [config])
        context = ModelContext(container)

        let stem = UUID().uuidString.prefix(8).lowercased()
        scratchSource = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("import-src-\(stem)")
        // Will be set by individual tests after writing a SKILL.md whose
        // frontmatter name derives to the directory slug.
    }

    override func tearDown() {
        if let url = scratchSource, FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        if let url = scratchDest, FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        scratchSource = nil
        scratchDest = nil
        context = nil
        container = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// Write a valid skill package to the scratch source directory under a
    /// slug-shaped subdirectory. Returns the package directory URL.
    @discardableResult
    private func writeValidPackage(slug: String, includeWarning: Bool = false) throws -> URL {
        let pkgDir = scratchSource.appendingPathComponent(slug, isDirectory: true)
        try FileManager.default.createDirectory(
            at: pkgDir.appendingPathComponent("tools"),
            withIntermediateDirectories: true
        )
        let canonicalName = slug.split(separator: "-").map(\.capitalized).joined(separator: " ")
        try """
        ---
        name: \(canonicalName)
        description: Imported test skill.
        ---

        # \(canonicalName)
        Body.
        """.write(
            to: pkgDir.appendingPathComponent("SKILL.md"),
            atomically: true, encoding: .utf8
        )
        // Optional: a tool that triggers the toolHasNoOutput warning when
        // the test wants to exercise the warnings-confirmation path. The
        // validator's heuristic is a literal substring scan for
        // `console.log` / `return ` — so a body that wants to NOT trigger
        // the warning must avoid those tokens entirely (including in
        // comments, since the heuristic is naive on purpose).
        let toolBody = includeWarning
            ? "const x = 1; const y = x + 2;"
            : "console.log('hi');"
        try """
        const META = {
          name: "greet",
          description: "Greet the user.",
          parameters: []
        };
        \(toolBody)
        """.write(
            to: pkgDir.appendingPathComponent("tools/greet.js"),
            atomically: true, encoding: .utf8
        )
        return pkgDir
    }

    private func uniqueSlug(prefix: String = "imp") -> String {
        "\(prefix)-\(UUID().uuidString.prefix(6).lowercased())"
    }

    // MARK: - prepareImport

    func testPrepareImport_notADirectoryReturnsError() {
        let bogus = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("does-not-exist-\(UUID().uuidString)")
        XCTAssertEqual(SkillImporter.prepareImport(sourceURL: bogus, modelContext: context),
                       .notADirectory)
    }

    func testPrepareImport_validPackageIsReady() throws {
        let slug = uniqueSlug()
        let pkgDir = try writeValidPackage(slug: slug)
        let outcome = SkillImporter.prepareImport(sourceURL: pkgDir, modelContext: context)
        guard case .ready(_, let report, let collision) = outcome else {
            return XCTFail("Expected .ready, got \(outcome)")
        }
        XCTAssertTrue(report.errors.isEmpty)
        XCTAssertNil(collision, "Fresh slug shouldn't collide")
    }

    func testPrepareImport_brokenPackageIsError() throws {
        let pkgDir = scratchSource.appendingPathComponent("broken")
        try FileManager.default.createDirectory(at: pkgDir, withIntermediateDirectories: true)
        try "---\nname: Bad\n".write(   // missing closing delimiter
            to: pkgDir.appendingPathComponent("SKILL.md"),
            atomically: true, encoding: .utf8
        )
        let outcome = SkillImporter.prepareImport(sourceURL: pkgDir, modelContext: context)
        guard case .error(let report) = outcome else {
            return XCTFail("Expected .error, got \(outcome)")
        }
        XCTAssertFalse(report.errors.isEmpty)
    }

    func testPrepareImport_warningsRequireConfirmation() throws {
        let slug = uniqueSlug()
        let pkgDir = try writeValidPackage(slug: slug, includeWarning: true)
        let outcome = SkillImporter.prepareImport(sourceURL: pkgDir, modelContext: context)
        guard case .warningsRequireConfirmation(_, let report, _) = outcome else {
            return XCTFail("Expected warnings outcome, got \(outcome)")
        }
        XCTAssertTrue(report.warnings.contains(where: { $0.code == .toolHasNoOutput }),
                      "Expected the toolHasNoOutput warning, got: \(report.warnings)")
    }

    func testPrepareImport_collisionDetected() throws {
        let slug = uniqueSlug()
        let pkgDir = try writeValidPackage(slug: slug)

        // Create a Skill row with the same name to trigger the collision.
        let canonicalName = slug.split(separator: "-").map(\.capitalized).joined(separator: " ")
        let svc = SkillService(modelContext: context)
        _ = svc.createSkill(name: canonicalName, summary: "x", content: "y", tags: [])
        try? context.save()

        let outcome = SkillImporter.prepareImport(sourceURL: pkgDir, modelContext: context)
        guard case .ready(_, _, let collision?) = outcome else {
            return XCTFail("Expected ready+collision, got \(outcome)")
        }
        XCTAssertEqual(collision.name, canonicalName)
        XCTAssertFalse(collision.isBuiltIn)
    }

    func testPrepareImport_builtInCollisionFlagged() throws {
        let pkgDir = scratchSource.appendingPathComponent("deep-research")
        try FileManager.default.createDirectory(
            at: pkgDir.appendingPathComponent("tools"),
            withIntermediateDirectories: true
        )
        try """
        ---
        name: Deep Research
        description: A spoof of the built-in.
        ---
        body
        """.write(
            to: pkgDir.appendingPathComponent("SKILL.md"),
            atomically: true, encoding: .utf8
        )
        let outcome = SkillImporter.prepareImport(sourceURL: pkgDir, modelContext: context)
        // The validator's slug_collision check would NOT trigger because we
        // exclude the source's own slug from the validator's known set —
        // collision flagging happens at the importer level via collision.isBuiltIn.
        switch outcome {
        case .ready(_, _, let collision?), .warningsRequireConfirmation(_, _, let collision?):
            XCTAssertTrue(collision.isBuiltIn,
                          "Built-in slug must surface as collision so the UI refuses replacement.")
        default:
            XCTFail("Expected ready+builtInCollision, got \(outcome)")
        }
    }

    // MARK: - commitImport

    func testCommitImport_freshSlugCreatesPackageAndRow() throws {
        let slug = uniqueSlug()
        scratchDest = AgentFileManager.shared.skillsRoot.appendingPathComponent(slug)
        let pkgDir = try writeValidPackage(slug: slug)
        let outcome = SkillImporter.prepareImport(sourceURL: pkgDir, modelContext: context)
        let skill = try SkillImporter.commitImport(
            outcome: outcome, replaceExisting: false, modelContext: context
        )
        XCTAssertEqual(SkillPackage.derivedSlug(forName: skill.name), slug)
        XCTAssertTrue(FileManager.default.fileExists(atPath: scratchDest.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: scratchDest.appendingPathComponent("SKILL.md").path))
    }

    func testCommitImport_existingSlugWithoutReplaceThrows() throws {
        let slug = uniqueSlug()
        scratchDest = AgentFileManager.shared.skillsRoot.appendingPathComponent(slug)
        let pkgDir = try writeValidPackage(slug: slug)

        // First import creates the destination.
        let firstOutcome = SkillImporter.prepareImport(sourceURL: pkgDir, modelContext: context)
        _ = try SkillImporter.commitImport(
            outcome: firstOutcome, replaceExisting: false, modelContext: context
        )
        // Second attempt without replaceExisting must throw.
        XCTAssertThrowsError(
            try SkillImporter.commitImport(
                outcome: firstOutcome, replaceExisting: false, modelContext: context
            )
        ) { err in
            guard case SkillImporter.ImportError.slugUnchangedButExists = err else {
                return XCTFail("Expected slugUnchangedButExists, got \(err)")
            }
        }
    }

    func testCommitImport_builtInSlugRefused() throws {
        let pkgDir = scratchSource.appendingPathComponent("deep-research")
        try FileManager.default.createDirectory(
            at: pkgDir.appendingPathComponent("tools"),
            withIntermediateDirectories: true
        )
        try """
        ---
        name: Deep Research
        description: Spoofed.
        ---
        body
        """.write(
            to: pkgDir.appendingPathComponent("SKILL.md"),
            atomically: true, encoding: .utf8
        )
        let outcome = SkillImporter.prepareImport(sourceURL: pkgDir, modelContext: context)
        XCTAssertThrowsError(
            try SkillImporter.commitImport(
                outcome: outcome, replaceExisting: true, modelContext: context
            )
        ) { err in
            guard case SkillImporter.ImportError.builtInCollision = err else {
                return XCTFail("Expected builtInCollision, got \(err)")
            }
        }
    }
}
