import XCTest
import SwiftData
@testable import iClaw

/// Phase 6: progressive disclosure of installed-skill bodies in the system
/// prompt.
///
/// The contract:
///   - Setting OFF → every installed skill renders its full body every turn
///     (pre-Phase-6 behavior).
///   - Setting ON + nil activated set (legacy callers like Cron) → same as
///     OFF; no progressive disclosure happens because there's no chat
///     session to derive activation from.
///   - Setting ON + non-nil activated set:
///       * dormant skills (not in the set) render as a single bullet line
///       * activated skills render their full body, scripts, and tools
@MainActor
final class PromptBuilderProgressiveDisclosureTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var builder: PromptBuilder!
    private var savedFlag: Bool!

    override func setUp() {
        super.setUp()
        let schema = Schema([Agent.self, LLMProvider.self, Session.self, AgentConfig.self,
                             CodeSnippet.self, CronJob.self, InstalledSkill.self, Skill.self,
                             Message.self, SessionEmbedding.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: schema, configurations: [config])
        context = ModelContext(container)
        builder = PromptBuilder()
        savedFlag = PromptBuilder.progressiveDisclosureEnabled
    }

    override func tearDown() {
        if let flag = savedFlag {
            PromptBuilder.progressiveDisclosureEnabled = flag
        }
        builder = nil
        context = nil
        container = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeAgentWithTwoSkills() -> Agent {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        let svc = SkillService(modelContext: context)
        let s1 = svc.createSkill(
            name: "Deep Research",
            summary: "Multi-source research methodology.",
            content: "RESEARCH METHODOLOGY BODY",
            tags: ["research"],
            scripts: [SkillScript(name: "extract", code: "// extract", description: "Extract links")],
            customTools: []
        )
        _ = svc.installSkill(s1, on: agent)
        let s2 = svc.createSkill(
            name: "File Ops",
            summary: "Advanced file operations.",
            content: "FILE OPS METHODOLOGY BODY",
            tags: ["files"],
            scripts: [],
            customTools: [
                SkillToolDefinition(
                    name: "cp",
                    description: "Copy a file.",
                    parameters: [SkillToolParam(name: "src", description: "Source")],
                    implementation: "// cp"
                )
            ]
        )
        _ = svc.installSkill(s2, on: agent)
        try! context.save()
        return agent
    }

    // MARK: - Setting OFF

    func testSettingOff_AllSkillsExpandedEvenWithEmptyActivatedSet() {
        PromptBuilder.progressiveDisclosureEnabled = false
        let agent = makeAgentWithTwoSkills()
        let prompt = builder.buildSystemPrompt(for: agent, activatedSkillSlugs: [])
        XCTAssertTrue(prompt.contains("RESEARCH METHODOLOGY BODY"))
        XCTAssertTrue(prompt.contains("FILE OPS METHODOLOGY BODY"))
        XCTAssertFalse(prompt.contains("dormant"), "Dormant section must not appear when the setting is off")
    }

    // MARK: - Legacy callers (nil activated set)

    func testNilActivatedSet_AllSkillsExpanded() {
        PromptBuilder.progressiveDisclosureEnabled = true
        let agent = makeAgentWithTwoSkills()
        // nil activated set = legacy / cron / sub-agent path → all bodies render.
        let prompt = builder.buildSystemPrompt(for: agent, activatedSkillSlugs: nil)
        XCTAssertTrue(prompt.contains("RESEARCH METHODOLOGY BODY"))
        XCTAssertTrue(prompt.contains("FILE OPS METHODOLOGY BODY"))
        XCTAssertFalse(prompt.contains("dormant"))
    }

    // MARK: - Progressive disclosure (chat path)

    func testEmptyActivatedSet_AllSkillsDormant() {
        PromptBuilder.progressiveDisclosureEnabled = true
        let agent = makeAgentWithTwoSkills()
        let prompt = builder.buildSystemPrompt(for: agent, activatedSkillSlugs: [])
        XCTAssertTrue(prompt.contains("Installed Skills (dormant)"))
        // Both skills appear as one-line bullets.
        XCTAssertTrue(prompt.contains("**Deep Research** (`/deep-research`) — Multi-source research methodology."))
        XCTAssertTrue(prompt.contains("**File Ops** (`/file-ops`) — Advanced file operations."))
        // Bodies are NOT in the prompt.
        XCTAssertFalse(prompt.contains("RESEARCH METHODOLOGY BODY"))
        XCTAssertFalse(prompt.contains("FILE OPS METHODOLOGY BODY"))
    }

    func testPartialActivation_SplitDormantAndActive() {
        PromptBuilder.progressiveDisclosureEnabled = true
        let agent = makeAgentWithTwoSkills()
        let prompt = builder.buildSystemPrompt(
            for: agent,
            activatedSkillSlugs: ["deep-research"]
        )
        // Active section appears with the activated body.
        XCTAssertTrue(prompt.contains("## Active Skills"))
        XCTAssertTrue(prompt.contains("RESEARCH METHODOLOGY BODY"))
        XCTAssertTrue(prompt.contains("Available scripts"),
                      "Activated skill's scripts list should appear")

        // Dormant section appears with the non-activated bullet.
        XCTAssertTrue(prompt.contains("## Installed Skills (dormant)"))
        XCTAssertTrue(prompt.contains("**File Ops** (`/file-ops`) — Advanced file operations."))
        XCTAssertFalse(prompt.contains("FILE OPS METHODOLOGY BODY"))
    }

    func testAllActivated_FullBodiesNoDormantSection() {
        PromptBuilder.progressiveDisclosureEnabled = true
        let agent = makeAgentWithTwoSkills()
        let prompt = builder.buildSystemPrompt(
            for: agent,
            activatedSkillSlugs: ["deep-research", "file-ops"]
        )
        XCTAssertTrue(prompt.contains("RESEARCH METHODOLOGY BODY"))
        XCTAssertTrue(prompt.contains("FILE OPS METHODOLOGY BODY"))
        XCTAssertFalse(prompt.contains("Installed Skills (dormant)"),
                       "No dormant section when every installed skill is active")
    }

    func testDormantBulletShowsNameSlugAndDescriptionOnly() {
        PromptBuilder.progressiveDisclosureEnabled = true
        let agent = makeAgentWithTwoSkills()
        let prompt = builder.buildSystemPrompt(for: agent, activatedSkillSlugs: [])
        // No script names, no tool names, no skill body — just the bullet.
        XCTAssertFalse(prompt.contains("`skill:Deep Research:extract`"),
                       "Script identifier must not leak into the dormant bullet")
        XCTAssertFalse(prompt.contains("skill_file_ops_cp"),
                       "Tool identifier must not leak into the dormant bullet")
    }

    func testFlagDefaultsToTrue() {
        // Reset to remove any value we've set in this test process.
        UserDefaults.standard.removeObject(forKey: PromptBuilder.progressiveDisclosureKey)
        XCTAssertTrue(PromptBuilder.progressiveDisclosureEnabled)
    }
}
