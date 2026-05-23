import XCTest
@testable import iClaw

/// Tests for the reserved `skills/` mount in `AgentFileManager.resolvedURL`.
///
/// Phase 4a adds path resolution only — built-in writes are blocked at the OS
/// level (read-only bundle) but the resolver itself doesn't yet emit a clean
/// error or consult the `fs_skill_write` permission. Those land in Phase 4b
/// alongside the `AppleEcosystemBridge` write hooks.
final class AgentFileManagerSkillsMountTests: XCTestCase {

    private let mgr = AgentFileManager.shared

    // MARK: - Path detection

    func testIsSkillsMountPath_root() {
        XCTAssertTrue(AgentFileManager.isSkillsMountPath("skills"))
    }

    func testIsSkillsMountPath_subPath() {
        XCTAssertTrue(AgentFileManager.isSkillsMountPath("skills/deep-research"))
        XCTAssertTrue(AgentFileManager.isSkillsMountPath("skills/foo/bar/baz.md"))
    }

    func testIsSkillsMountPath_negative() {
        XCTAssertFalse(AgentFileManager.isSkillsMountPath(""))
        XCTAssertFalse(AgentFileManager.isSkillsMountPath("notes/skills"))
        XCTAssertFalse(AgentFileManager.isSkillsMountPath("skill"))
        XCTAssertFalse(AgentFileManager.isSkillsMountPath("skillsy"))
        // A leading slash falls outside the mount because path normalization
        // happens at the bridge layer (Phase 4b); the resolver continues to
        // treat leading slashes as unsafe.
        XCTAssertFalse(AgentFileManager.isSkillsMountPath("/skills/foo"))
    }

    // MARK: - Built-in routing (read-only)

    func testResolveBuiltInSkillRoot_routesToBundle() throws {
        let res = try mgr.resolveSkillsPath("deep-research")
        XCTAssertTrue(res.isBuiltIn)
        XCTAssertEqual(res.slug, "deep-research")
        XCTAssertTrue(res.url.path.contains("BuiltInSkills/deep-research"),
                      "Expected bundle path, got \(res.url.path)")
    }

    func testResolveBuiltInSkillFile_routesToBundle() throws {
        let res = try mgr.resolveSkillsPath("deep-research/SKILL.md")
        XCTAssertTrue(res.isBuiltIn)
        XCTAssertEqual(res.slug, "deep-research")
        XCTAssertTrue(res.url.lastPathComponent == "SKILL.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: res.url.path),
                      "Bundle SKILL.md should be readable at \(res.url.path)")
    }

    func testResolveBuiltInSkillToolFile_routesToBundle() throws {
        let res = try mgr.resolveSkillsPath("deep-research/tools/fetch_and_extract.js")
        XCTAssertTrue(res.isBuiltIn)
        XCTAssertTrue(FileManager.default.fileExists(atPath: res.url.path))
    }

    // MARK: - User skill routing (read/write — Documents)

    func testResolveUserSkill_routesToDocuments() throws {
        let res = try mgr.resolveSkillsPath("my-custom-skill/SKILL.md")
        XCTAssertFalse(res.isBuiltIn)
        XCTAssertEqual(res.slug, "my-custom-skill")
        XCTAssertTrue(res.url.path.contains("Documents/Skills/my-custom-skill"),
                      "Expected Documents/Skills/my-custom-skill path, got \(res.url.path)")
    }

    func testResolveMountRoot_routesToDocumentsSkills() throws {
        let res = try mgr.resolveSkillsPath("")
        XCTAssertNil(res.slug)
        XCTAssertFalse(res.isBuiltIn)
        XCTAssertTrue(res.url.path.hasSuffix("/Skills"),
                      "Expected mount root at <Documents>/Skills, got \(res.url.path)")
    }

    // MARK: - Path traversal rejection

    func testResolveSkillsPath_rejectsTraversal() {
        XCTAssertThrowsError(try mgr.resolveSkillsPath("../../escape"))
        XCTAssertThrowsError(try mgr.resolveSkillsPath("foo/../../escape"))
        XCTAssertThrowsError(try mgr.resolveSkillsPath("foo/./bar/../baz"))
    }

    func testResolveSkillsPath_rejectsAbsolute() {
        XCTAssertThrowsError(try mgr.resolveSkillsPath("/absolute"))
    }

    func testResolveSkillsPath_rejectsBackslash() {
        XCTAssertThrowsError(try mgr.resolveSkillsPath("foo\\bar"))
    }

    // MARK: - Integration with resolvedURL(agentId:path:)

    func testResolvedURL_routesSkillsPathToMount() throws {
        let agentId = UUID()
        let url = try mgr.resolvedURL(agentId: agentId, path: "skills/deep-research/SKILL.md")
        XCTAssertTrue(url.path.contains("BuiltInSkills/deep-research"),
                      "Expected built-in routing, got \(url.path)")
        XCTAssertFalse(url.path.contains(agentId.uuidString),
                       "Skills mount must not be scoped to the agent's per-agent dir")
    }

    func testResolvedURL_routesUserSkillsPathToDocuments() throws {
        let agentId = UUID()
        let url = try mgr.resolvedURL(agentId: agentId, path: "skills/my-custom/file.txt")
        XCTAssertTrue(url.path.contains("Documents/Skills/my-custom"),
                      "Expected user-skill routing, got \(url.path)")
        XCTAssertFalse(url.path.contains(agentId.uuidString))
    }

    func testResolvedURL_nonSkillsPathStillScopedToAgent() throws {
        let agentId = UUID()
        let url = try mgr.resolvedURL(agentId: agentId, path: "notes/foo.md")
        XCTAssertTrue(url.path.contains("AgentFiles/\(agentId.uuidString)/notes/foo.md"),
                      "Expected per-agent routing, got \(url.path)")
    }

    // MARK: - Phase 4b: read-only built-in enforcement

    func testResolveSkillsPath_builtInWriteThrowsReadOnlySkill() {
        XCTAssertThrowsError(try mgr.resolveSkillsPath("deep-research/SKILL.md", forWriting: true)) { err in
            guard case FileToolError.readOnlySkill(let slug) = err else {
                return XCTFail("Expected readOnlySkill, got \(err)")
            }
            XCTAssertEqual(slug, "deep-research")
        }
    }

    func testResolveSkillsPath_userWriteAllowed() throws {
        let res = try mgr.resolveSkillsPath("my-custom/SKILL.md", forWriting: true)
        XCTAssertFalse(res.isBuiltIn)
        XCTAssertEqual(res.slug, "my-custom")
    }

    func testResolveSkillsPath_builtInReadStillAllowed() throws {
        // forWriting: false (the default) must still permit reads from built-ins.
        let res = try mgr.resolveSkillsPath("deep-research/SKILL.md")
        XCTAssertTrue(res.isBuiltIn)
    }

    func testResolvedURL_writeToBuiltInPathRejected() {
        let agentId = UUID()
        XCTAssertThrowsError(
            try mgr.resolvedURL(agentId: agentId, path: "skills/deep-research/SKILL.md", forWriting: true)
        ) { err in
            guard case FileToolError.readOnlySkill = err else {
                return XCTFail("Expected readOnlySkill, got \(err)")
            }
        }
    }

    func testWriteFile_toBuiltInSurfaceReadOnlyError() {
        // The actual write operation should bubble up the resolver error.
        let agentId = UUID()
        XCTAssertThrowsError(
            try mgr.writeFile(agentId: agentId, name: "skills/deep-research/SKILL.md", data: Data("hijack".utf8))
        ) { err in
            guard case FileToolError.readOnlySkill = err else {
                return XCTFail("Expected readOnlySkill, got \(err)")
            }
        }
    }

    func testDeleteFile_onBuiltInRejected() {
        let agentId = UUID()
        XCTAssertThrowsError(
            try mgr.deleteFile(agentId: agentId, name: "skills/deep-research/SKILL.md")
        ) { err in
            guard case FileToolError.readOnlySkill = err else {
                return XCTFail("Expected readOnlySkill, got \(err)")
            }
        }
    }

    // MARK: - Phase 4b: leading-slash normalization for /skills/

    func testResolvedURL_acceptsLeadingSlashOnSkillsMount() throws {
        let agentId = UUID()
        let url = try mgr.resolvedURL(agentId: agentId, path: "/skills/deep-research/SKILL.md")
        XCTAssertTrue(url.path.contains("BuiltInSkills/deep-research"))
    }

    func testResolvedURL_leadingSlashOnNonSkillsPathStillRejected() {
        let agentId = UUID()
        // Non-skills absolute-style paths must continue to be rejected so the
        // existing safety contract is preserved.
        XCTAssertThrowsError(try mgr.resolvedURL(agentId: agentId, path: "/etc/passwd"))
        XCTAssertThrowsError(try mgr.resolvedURL(agentId: agentId, path: "/notes/foo.md"))
    }
}
