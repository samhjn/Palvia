import XCTest
@testable import iClaw

/// Phase 4b: bridge-level enforcement for the `/skills/` mount.
///
/// Validates the two layers added on top of the resolver work:
///   1. `FileToolError.readOnlySkill` from the resolver bubbles up as a
///      readable JS-side error for any built-in write.
///   2. The per-agent `fs_skill_write` permission gates writes to user slugs
///      independently of the broader `files.*` permissions.
@MainActor
final class AppleEcosystemBridgeSkillsMountTests: XCTestCase {

    private var bridge: AppleEcosystemBridge!
    private var agentId: UUID!
    private var execId: String!

    override func setUp() async throws {
        try await super.setUp()
        bridge = AppleEcosystemBridge.shared
        agentId = UUID()
        execId = UUID().uuidString
    }

    override func tearDown() async throws {
        bridge.unregisterPermissions(execId: execId)
        AgentFileManager.shared.cleanupAgentFiles(agentId: agentId)
        // Clean up any user-skill scratch directories created by tests.
        let scratch = AgentFileManager.shared.skillsRoot.appendingPathComponent("test-bridge-scratch")
        try? FileManager.default.removeItem(at: scratch)
        bridge = nil
        agentId = nil
        execId = nil
        try await super.tearDown()
    }

    private func call(_ action: String, _ args: [String: Any]) async -> String {
        await bridge.dispatchForTesting(action: action, args: args, execId: execId)
    }

    private func registerWithSkillWrite(_ allow: Bool) {
        bridge.registerContext(execId: execId, agentId: agentId) { action in
            // Allow everything except (optionally) fs_skill_write.
            if action == AppleEcosystemBridge.fsSkillWriteAction { return allow }
            return true
        }
    }

    // MARK: - Built-in read-only

    func testWriteToBuiltInReturnsReadOnlyError() async {
        registerWithSkillWrite(true)
        let res = await call("files.writeFile", [
            "path": "skills/deep-research/SKILL.md",
            "content": "hijack",
        ])
        XCTAssertTrue(res.contains("read-only"),
                      "Built-in write should surface readOnlySkill error, got: \(res)")
        // Bundle file must be untouched.
        guard let url = BuiltInSkillsDirectoryLoader.packageURL(forSlug: "deep-research") else {
            return XCTFail("Built-in package not found")
        }
        let actual = try? String(contentsOf: url.appendingPathComponent("SKILL.md"))
        XCTAssertNotEqual(actual, "hijack")
    }

    func testDeleteOnBuiltInReturnsReadOnlyError() async {
        registerWithSkillWrite(true)
        let res = await call("files.delete", ["path": "skills/deep-research"])
        XCTAssertTrue(res.contains("read-only"),
                      "Built-in delete should surface readOnlySkill error, got: \(res)")
    }

    func testMkdirOnBuiltInReturnsReadOnlyError() async {
        registerWithSkillWrite(true)
        let res = await call("files.mkdir", ["path": "skills/deep-research/new-subdir"])
        XCTAssertTrue(res.contains("read-only"),
                      "Built-in mkdir should surface readOnlySkill error, got: \(res)")
    }

    func testReadFromBuiltInAllowedRegardlessOfWritePermission() async {
        registerWithSkillWrite(false)
        // Write permission denied — read should still work.
        let res = await call("files.readFile", ["path": "skills/deep-research/SKILL.md"])
        XCTAssertTrue(res.contains("Deep Research"),
                      "Built-in read should be allowed even when fs_skill_write is denied")
    }

    // MARK: - User-skill permission gate

    func testWriteToUserSkillBlockedWhenPermissionDenied() async {
        registerWithSkillWrite(false)
        let res = await call("files.writeFile", [
            "path": "skills/test-bridge-scratch/SKILL.md",
            "content": "---\nname: Test\ndescription: Test\n---\nbody",
        ])
        XCTAssertTrue(res.contains("fs_skill_write"),
                      "User-skill write should fail with fs_skill_write permission error, got: \(res)")
        // File must not have been created.
        let url = AgentFileManager.shared.skillsRoot
            .appendingPathComponent("test-bridge-scratch/SKILL.md")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testWriteToUserSkillAllowedWhenPermissionGranted() async {
        registerWithSkillWrite(true)
        let res = await call("files.writeFile", [
            "path": "skills/test-bridge-scratch/SKILL.md",
            "content": "---\nname: Test\ndescription: Test desc\n---\nbody",
        ])
        XCTAssertEqual(res, "OK", "User-skill write should succeed with fs_skill_write granted, got: \(res)")
        let url = AgentFileManager.shared.skillsRoot
            .appendingPathComponent("test-bridge-scratch/SKILL.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testMkdirOnUserSkillRequiresPermission() async {
        registerWithSkillWrite(false)
        let res = await call("files.mkdir", ["path": "skills/test-bridge-scratch"])
        XCTAssertTrue(res.contains("fs_skill_write"),
                      "User-skill mkdir should require fs_skill_write, got: \(res)")
    }

    // MARK: - cp / mv

    func testCpFromBuiltInToUserAllowedWithPermission() async {
        registerWithSkillWrite(true)
        let res = await call("files.cp", [
            "src": "skills/deep-research",
            "dest": "skills/test-bridge-scratch",
            "recursive": true,
        ])
        XCTAssertEqual(res, "OK", "Fork-from-built-in should succeed, got: \(res)")
        let forkedSkillMd = AgentFileManager.shared.skillsRoot
            .appendingPathComponent("test-bridge-scratch/SKILL.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: forkedSkillMd.path))
    }

    func testCpFromBuiltInToUserBlockedWithoutPermission() async {
        registerWithSkillWrite(false)
        let res = await call("files.cp", [
            "src": "skills/deep-research",
            "dest": "skills/test-bridge-scratch",
            "recursive": true,
        ])
        XCTAssertTrue(res.contains("fs_skill_write"),
                      "Fork without permission should be blocked at dest, got: \(res)")
    }

    func testCpToBuiltInRejected() async {
        registerWithSkillWrite(true)
        // Set up a source file under user mount first.
        _ = await call("files.writeFile", [
            "path": "skills/test-bridge-scratch/SKILL.md",
            "content": "---\nname: Test\ndescription: Test\n---\nbody",
        ])
        let res = await call("files.cp", [
            "src": "skills/test-bridge-scratch/SKILL.md",
            "dest": "skills/deep-research/SKILL.md",
        ])
        XCTAssertTrue(res.contains("read-only"),
                      "Copy targeting a built-in should surface readOnlySkill, got: \(res)")
    }

    // MARK: - Path normalization

    func testLeadingSlashSkillsPathAccepted() async {
        registerWithSkillWrite(true)
        let res = await call("files.writeFile", [
            "path": "/skills/test-bridge-scratch/note.txt",
            "content": "hello",
        ])
        XCTAssertEqual(res, "OK", "Leading slash on /skills/ should be normalized, got: \(res)")
    }

    func testLeadingSlashOnNonSkillsPathStillRejected() async {
        registerWithSkillWrite(true)
        let res = await call("files.writeFile", [
            "path": "/notes/foo.txt",
            "content": "hello",
        ])
        XCTAssertTrue(res.contains("Unsafe path") || res.contains("Error"),
                      "Non-skills absolute path must remain rejected, got: \(res)")
    }
}
