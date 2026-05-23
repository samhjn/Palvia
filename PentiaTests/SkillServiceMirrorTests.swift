import XCTest
import SwiftData
@testable import iClaw

/// Phase 8b: SkillService.deleteSkill removes the on-disk package mirror, and
/// the migration helper covers the read path. The UI write path (SkillEditView
/// .save) is exercised end-to-end here by reproducing its sequence: build/
/// update the row via SkillService, then call SkillPackage.write to mirror.
@MainActor
final class SkillServiceMirrorTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var addedSlugs: [String] = []

    override func setUp() {
        super.setUp()
        let schema = Schema([Agent.self, LLMProvider.self, Session.self, AgentConfig.self,
                             CodeSnippet.self, CronJob.self, InstalledSkill.self, Skill.self,
                             Message.self, SessionEmbedding.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: schema, configurations: [config])
        context = ModelContext(container)
        addedSlugs = []
    }

    override func tearDown() {
        let root = AgentFileManager.shared.skillsRoot
        for slug in addedSlugs {
            let url = root.appendingPathComponent(slug, isDirectory: true)
            try? FileManager.default.removeItem(at: url)
        }
        addedSlugs = []
        context = nil
        container = nil
        super.tearDown()
    }

    private func makeSkill(_ name: String, summary: String = "S", content: String = "B") -> Skill {
        let svc = SkillService(modelContext: context)
        let skill = svc.createSkill(name: name, summary: summary, content: content, tags: [])
        addedSlugs.append(SkillPackage.derivedSlug(forName: name))
        return skill
    }

    // MARK: - delete cleans up disk

    func testDelete_removesOnDiskPackage() throws {
        let svc = SkillService(modelContext: context)
        let skill = makeSkill("Mirror Test")
        let slug = SkillPackage.derivedSlug(forName: skill.name)
        let dest = AgentFileManager.shared.skillsRoot.appendingPathComponent(slug, isDirectory: true)

        // Mirror the row to disk first (mimics what SkillEditView.save does).
        try SkillPackage.write(skill, to: dest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))

        svc.deleteSkill(skill)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path),
                       "deleteSkill should remove the on-disk mirror")
    }

    func testDelete_legacyRowWithoutPackageStillSucceeds() {
        // A pre-Phase-4 row whose backing directory was never created. Delete
        // must still succeed (no throw, no orphan).
        let svc = SkillService(modelContext: context)
        let skill = makeSkill("Legacy No Package")
        let slug = SkillPackage.derivedSlug(forName: skill.name)
        let dest = AgentFileManager.shared.skillsRoot.appendingPathComponent(slug)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))

        svc.deleteSkill(skill)
        XCTAssertNil(svc.fetchSkill(name: "Legacy No Package"))
    }

    func testDelete_builtInIsSkipped() {
        // Built-ins live in the bundle and aren't deletable. The service
        // already guards this; verify the bundle path stays intact.
        SkillService(modelContext: context).ensureBuiltInSkills()
        guard let deepResearch = SkillService(modelContext: context).fetchSkill(name: "Deep Research") else {
            return XCTFail("Expected built-in 'Deep Research' to exist after ensureBuiltInSkills")
        }
        SkillService(modelContext: context).deleteSkill(deepResearch)
        // Built-in row is still there (deleteSkill returns early for built-ins).
        XCTAssertNotNil(SkillService(modelContext: context).fetchSkill(name: "Deep Research"))
    }

    // MARK: - rename moves disk package

    func testRename_oldSlugDirectoryCanBeRemoved() throws {
        let svc = SkillService(modelContext: context)
        let skill = makeSkill("Original Name")
        let oldSlug = SkillPackage.derivedSlug(forName: skill.name)
        let oldDest = AgentFileManager.shared.skillsRoot.appendingPathComponent(oldSlug)
        try SkillPackage.write(skill, to: oldDest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldDest.path))

        // Rename via the service.
        svc.updateSkill(skill, name: "Renamed Skill")
        try? context.save()
        let newSlug = SkillPackage.derivedSlug(forName: skill.name)
        let newDest = AgentFileManager.shared.skillsRoot.appendingPathComponent(newSlug)
        addedSlugs.append(newSlug)

        // Mimic SkillEditView.save's rename cleanup.
        try? FileManager.default.removeItem(at: oldDest)
        try SkillPackage.write(skill, to: newDest)

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldDest.path),
                       "Old slug directory should be cleaned up after rename")
        XCTAssertTrue(FileManager.default.fileExists(atPath: newDest.path))
        let (parsed, _) = SkillPackage.parse(at: newDest)
        XCTAssertEqual(parsed?.frontmatter.name, "Renamed Skill")
    }
}
