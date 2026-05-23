import XCTest
import SwiftData
@testable import iClaw

// MARK: - PromptBuilder Tests

final class PromptBuilderTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var builder: PromptBuilder!

    @MainActor
    override func setUp() {
        super.setUp()
        let schema = Schema([Agent.self, LLMProvider.self, Session.self, AgentConfig.self,
                             CodeSnippet.self, CronJob.self, InstalledSkill.self, Skill.self,
                             Message.self, SessionEmbedding.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: schema, configurations: [config])
        context = ModelContext(container)
        builder = PromptBuilder()
    }

    override func tearDown() {
        container = nil
        context = nil
        builder = nil
        super.tearDown()
    }

    // MARK: - Basic System Prompt

    @MainActor
    func testBuildSystemPromptContainsSoulSection() {
        let agent = Agent(name: "Test", soulMarkdown: "I am a creative AI.")
        context.insert(agent)
        try! context.save()

        let prompt = builder.buildSystemPrompt(for: agent)

        XCTAssertTrue(prompt.contains("Soul (Identity & Personality)"))
        XCTAssertTrue(prompt.contains("I am a creative AI."))
    }

    @MainActor
    func testBuildSystemPromptContainsMemoryAndUser() {
        let agent = Agent(name: "Test",
                          soulMarkdown: "Soul",
                          memoryMarkdown: "Remember this fact",
                          userMarkdown: "User prefers Chinese")
        context.insert(agent)
        try! context.save()

        let prompt = builder.buildSystemPrompt(for: agent)

        XCTAssertTrue(prompt.contains("Memory (Persistent Knowledge)"))
        XCTAssertTrue(prompt.contains("Remember this fact"))
        XCTAssertTrue(prompt.contains("User Profile"))
        XCTAssertTrue(prompt.contains("User prefers Chinese"))
    }

    @MainActor
    func testBuildSystemPromptContainsCapabilities() {
        let agent = Agent(name: "Test")
        context.insert(agent)
        try! context.save()

        let prompt = builder.buildSystemPrompt(for: agent)

        XCTAssertTrue(prompt.contains("Your Capabilities"))
        XCTAssertTrue(prompt.contains("read_config"))
        XCTAssertTrue(prompt.contains("write_config"))
    }

    @MainActor
    func testBuildSystemPromptSectionsSeparatedByDivider() {
        let agent = Agent(name: "Test", soulMarkdown: "Soul text")
        context.insert(agent)
        try! context.save()

        let prompt = builder.buildSystemPrompt(for: agent)

        XCTAssertTrue(prompt.contains("---"),
                      "Sections should be separated by --- dividers")
    }

    // MARK: - Sub-Agent Mode

    @MainActor
    func testSubAgentPromptExcludesMemoryAndUser() {
        let agent = Agent(name: "Test",
                          soulMarkdown: "Soul",
                          memoryMarkdown: "Memory",
                          userMarkdown: "User")
        context.insert(agent)
        try! context.save()

        let prompt = builder.buildSystemPrompt(for: agent, isSubAgent: true)

        XCTAssertTrue(prompt.contains("Sub-Agent Notice"))
        XCTAssertFalse(prompt.contains("Memory (Persistent Knowledge)"))
        XCTAssertFalse(prompt.contains("User Profile"))
    }

    @MainActor
    func testSubAgentPromptContainsSoul() {
        let agent = Agent(name: "Test", soulMarkdown: "Creative soul")
        context.insert(agent)
        try! context.save()

        let prompt = builder.buildSystemPrompt(for: agent, isSubAgent: true)

        XCTAssertTrue(prompt.contains("Creative soul"))
    }

    @MainActor
    func testSubAgentHintsContent() {
        let agent = Agent(name: "Test")
        context.insert(agent)
        try! context.save()

        let prompt = builder.buildSystemPrompt(for: agent, isSubAgent: true)

        XCTAssertTrue(prompt.contains("sub-agent"))
        XCTAssertTrue(prompt.contains("read_config"))
        XCTAssertTrue(prompt.contains("MEMORY.md"))
    }

    // MARK: - Compressed Context

    @MainActor
    func testBuildSystemPromptWithCompressedContext() {
        let agent = Agent(name: "Test", soulMarkdown: "Soul")
        context.insert(agent)
        try! context.save()

        let prompt = builder.buildSystemPromptWithCompressedContext(
            for: agent,
            compressedContext: "Earlier we discussed Swift testing."
        )

        XCTAssertTrue(prompt.contains("Conversation History Summary"))
        XCTAssertTrue(prompt.contains("Earlier we discussed Swift testing."))
        XCTAssertTrue(prompt.contains("Soul"))
    }

    @MainActor
    func testBuildSystemPromptWithNilCompressedContext() {
        let agent = Agent(name: "Test", soulMarkdown: "Soul")
        context.insert(agent)
        try! context.save()

        let prompt = builder.buildSystemPromptWithCompressedContext(
            for: agent,
            compressedContext: nil
        )

        XCTAssertFalse(prompt.contains("Conversation History Summary"))
    }

    @MainActor
    func testBuildSystemPromptWithEmptyCompressedContext() {
        let agent = Agent(name: "Test")
        context.insert(agent)
        try! context.save()

        let prompt = builder.buildSystemPromptWithCompressedContext(
            for: agent,
            compressedContext: ""
        )

        XCTAssertFalse(prompt.contains("Conversation History Summary"))
    }

    // MARK: - Sub-Agent Init Prompt

    @MainActor
    func testBuildSubAgentInitPromptWithContext() {
        let parent = Agent(name: "Parent", soulMarkdown: "Parent soul")
        context.insert(parent)
        try! context.save()

        let prompt = builder.buildSubAgentInitPrompt(
            parentAgent: parent,
            subAgentName: "Worker",
            initialContext: "Analyze this dataset and return results."
        )

        XCTAssertTrue(prompt.contains("Sub-Agent Notice"))
        XCTAssertTrue(prompt.contains("Parent soul"))
        XCTAssertTrue(prompt.contains("Context from Parent Agent"))
        XCTAssertTrue(prompt.contains("Analyze this dataset"))
    }

    @MainActor
    func testBuildSubAgentInitPromptWithoutContext() {
        let parent = Agent(name: "Parent")
        context.insert(parent)
        try! context.save()

        let prompt = builder.buildSubAgentInitPrompt(
            parentAgent: parent,
            subAgentName: "Worker",
            initialContext: nil
        )

        XCTAssertTrue(prompt.contains("Sub-Agent Notice"))
        XCTAssertFalse(prompt.contains("Context from Parent Agent"))
    }

    @MainActor
    func testBuildSubAgentInitPromptWithEmptyContext() {
        let parent = Agent(name: "Parent")
        context.insert(parent)
        try! context.save()

        let prompt = builder.buildSubAgentInitPrompt(
            parentAgent: parent,
            subAgentName: "Worker",
            initialContext: ""
        )

        XCTAssertFalse(prompt.contains("Context from Parent Agent"))
    }

    // MARK: - Capability Sections Based on Permissions

    @MainActor
    func testDefaultAgentHasAllCapabilitySections() {
        let agent = Agent(name: "Test")
        context.insert(agent)
        try! context.save()

        let prompt = builder.buildSystemPrompt(for: agent)

        XCTAssertTrue(prompt.contains("Code Execution"))
        XCTAssertTrue(prompt.contains("Sub-Agent Management"))
        XCTAssertTrue(prompt.contains("Session Memory"))
        XCTAssertTrue(prompt.contains("Cron Job Scheduling"))
        XCTAssertTrue(prompt.contains("Skills Management"))
        XCTAssertTrue(prompt.contains("File Management"))
        XCTAssertTrue(prompt.contains("Browser"))
        XCTAssertTrue(prompt.contains("Model Management"))
        XCTAssertTrue(prompt.contains("Apple Ecosystem"))
    }

    @MainActor
    func testDisabledBrowserExcludesBrowserSection() {
        let agent = Agent(name: "Test")
        context.insert(agent)
        agent.setPermissionLevel(.disabled, for: .browser)
        try! context.save()

        let prompt = builder.buildSystemPrompt(for: agent)

        XCTAssertFalse(prompt.contains("### Browser"))
        XCTAssertFalse(prompt.contains("browser_navigate"))
    }

    @MainActor
    func testDisabledCodeExecutionExcludesSection() {
        let agent = Agent(name: "Test")
        context.insert(agent)
        agent.setPermissionLevel(.disabled, for: .codeExecution)
        try! context.save()

        let prompt = builder.buildSystemPrompt(for: agent)

        XCTAssertFalse(prompt.contains("### Code Execution"))
        XCTAssertFalse(prompt.contains("execute_javascript"))
    }

    @MainActor
    func testDisabledSubAgentsExcludesSection() {
        let agent = Agent(name: "Test")
        context.insert(agent)
        agent.setPermissionLevel(.disabled, for: .subAgents)
        try! context.save()

        let prompt = builder.buildSystemPrompt(for: agent)

        XCTAssertFalse(prompt.contains("### Sub-Agent Management"))
        XCTAssertFalse(prompt.contains("create_sub_agent"))
    }

    @MainActor
    func testDisabledCronExcludesSection() {
        let agent = Agent(name: "Test")
        context.insert(agent)
        agent.setPermissionLevel(.disabled, for: .cron)
        try! context.save()

        let prompt = builder.buildSystemPrompt(for: agent)

        XCTAssertFalse(prompt.contains("### Cron Job Scheduling"))
        XCTAssertFalse(prompt.contains("schedule_cron"))
    }

    @MainActor
    func testDisabledSkillsExcludesSection() {
        let agent = Agent(name: "Test")
        context.insert(agent)
        agent.setPermissionLevel(.disabled, for: .skills)
        try! context.save()

        let prompt = builder.buildSystemPrompt(for: agent)

        XCTAssertFalse(prompt.contains("### Skills Management"))
        XCTAssertFalse(prompt.contains("create_skill"))
    }

    @MainActor
    func testDisabledFilesExcludesSection() {
        let agent = Agent(name: "Test")
        context.insert(agent)
        agent.setPermissionLevel(.disabled, for: .files)
        try! context.save()

        let prompt = builder.buildSystemPrompt(for: agent)

        XCTAssertFalse(prompt.contains("### File Management"))
        XCTAssertFalse(prompt.contains("file_list"))
    }

    @MainActor
    func testDisabledModelExcludesSection() {
        let agent = Agent(name: "Test")
        context.insert(agent)
        agent.setPermissionLevel(.disabled, for: .model)
        try! context.save()

        let prompt = builder.buildSystemPrompt(for: agent)

        XCTAssertFalse(prompt.contains("### Model Management"))
        XCTAssertFalse(prompt.contains("set_model"))
    }

    @MainActor
    func testDisabledCalendarExcludesFromAppleSection() {
        let agent = Agent(name: "Test")
        context.insert(agent)
        agent.setPermissionLevel(.disabled, for: .calendar)
        try! context.save()

        let prompt = builder.buildSystemPrompt(for: agent)

        XCTAssertFalse(prompt.contains("calendar_create_event"))
        XCTAssertTrue(prompt.contains("Apple Ecosystem"),
                      "Other Apple tools should still appear")
    }

    @MainActor
    func testAllAppleDisabledExcludesAppleSection() {
        let agent = Agent(name: "Test")
        context.insert(agent)
        for cat in ToolCategory.appleCategories {
            agent.setPermissionLevel(.disabled, for: cat)
        }
        try! context.save()

        let prompt = builder.buildSystemPrompt(for: agent)

        XCTAssertFalse(prompt.contains("### Apple Ecosystem"))
    }

    @MainActor
    func testMultipleDisabledCategories() {
        let agent = Agent(name: "Test")
        context.insert(agent)
        agent.setPermissionLevel(.disabled, for: .browser)
        agent.setPermissionLevel(.disabled, for: .cron)
        agent.setPermissionLevel(.disabled, for: .model)
        try! context.save()

        let prompt = builder.buildSystemPrompt(for: agent)

        XCTAssertFalse(prompt.contains("### Browser"))
        XCTAssertFalse(prompt.contains("### Cron Job Scheduling"))
        XCTAssertFalse(prompt.contains("### Model Management"))
        XCTAssertTrue(prompt.contains("Code Execution"))
        XCTAssertTrue(prompt.contains("Sub-Agent Management"))
    }

    // MARK: - Guidelines

    @MainActor
    func testGuidelinesAlwaysPresent() {
        let agent = Agent(name: "Test")
        context.insert(agent)
        try! context.save()

        let prompt = builder.buildSystemPrompt(for: agent)

        XCTAssertTrue(prompt.contains("Important Guidelines"))
        XCTAssertTrue(prompt.contains("MEMORY.md"))
    }

    @MainActor
    func testGuidelinesConditionalOnPermissions() {
        let agent = Agent(name: "Test")
        context.insert(agent)
        try! context.save()

        let prompt = builder.buildSystemPrompt(for: agent)

        XCTAssertTrue(prompt.contains("JavaScript execution"))
        XCTAssertTrue(prompt.contains("sub-agents") || prompt.contains("Sub-agents") || prompt.contains("agent_id"))
        XCTAssertTrue(prompt.contains("cron jobs") || prompt.contains("Cron") || prompt.contains("recurring"))
    }

    @MainActor
    func testGuidelinesOmittedWhenCategoryDisabled() {
        let agent = Agent(name: "Test")
        context.insert(agent)
        agent.setPermissionLevel(.disabled, for: .codeExecution)
        agent.setPermissionLevel(.disabled, for: .subAgents)
        agent.setPermissionLevel(.disabled, for: .cron)
        agent.setPermissionLevel(.disabled, for: .skills)
        agent.setPermissionLevel(.disabled, for: .sessions)
        try! context.save()

        let prompt = builder.buildSystemPrompt(for: agent)

        XCTAssertFalse(prompt.contains("JavaScript execution"))
    }

    // MARK: - Installed Skills Section

    @MainActor
    func testNoSkillsSectionWhenNoSkillsInstalled() {
        let agent = Agent(name: "Test")
        context.insert(agent)
        try! context.save()

        let prompt = builder.buildSystemPrompt(for: agent)

        XCTAssertFalse(prompt.contains("## Installed Skills"))
    }

    @MainActor
    func testSkillsSectionWithActiveSkills() {
        let agent = Agent(name: "Test")
        context.insert(agent)

        let skill = Skill(name: "Code Review", summary: "Review code", content: "Always check for edge cases.")
        context.insert(skill)

        let installation = InstalledSkill(isEnabled: true)
        context.insert(installation)
        agent.installedSkills.append(installation)
        installation.skill = skill
        try! context.save()

        let prompt = builder.buildSystemPrompt(for: agent)

        XCTAssertTrue(prompt.contains("Installed Skills"))
        XCTAssertTrue(prompt.contains("Skill: Code Review"))
        XCTAssertTrue(prompt.contains("Always check for edge cases."))
    }

    @MainActor
    func testDisabledSkillNotInPrompt() {
        let agent = Agent(name: "Test")
        context.insert(agent)

        let skill = Skill(name: "Disabled Skill", summary: "Off", content: "Should not appear")
        context.insert(skill)

        let installation = InstalledSkill(isEnabled: false)
        context.insert(installation)
        agent.installedSkills.append(installation)
        installation.skill = skill
        try! context.save()

        let prompt = builder.buildSystemPrompt(for: agent)

        XCTAssertFalse(prompt.contains("Disabled Skill"))
        XCTAssertFalse(prompt.contains("Should not appear"))
    }

    @MainActor
    func testMultipleActiveSkills() {
        let agent = Agent(name: "Test")
        context.insert(agent)

        let s1 = Skill(name: "Skill A", summary: "A", content: "Content A")
        let s2 = Skill(name: "Skill B", summary: "B", content: "Content B")
        context.insert(s1)
        context.insert(s2)

        let i1 = InstalledSkill(isEnabled: true)
        let i2 = InstalledSkill(isEnabled: true)
        context.insert(i1)
        context.insert(i2)
        agent.installedSkills.append(i1)
        agent.installedSkills.append(i2)
        i1.skill = s1
        i2.skill = s2
        try! context.save()

        let prompt = builder.buildSystemPrompt(for: agent)

        XCTAssertTrue(prompt.contains("Skill: Skill A"))
        XCTAssertTrue(prompt.contains("Content A"))
        XCTAssertTrue(prompt.contains("Skill: Skill B"))
        XCTAssertTrue(prompt.contains("Content B"))
    }

    // MARK: - Custom Configs Section

    @MainActor
    func testNoCustomConfigsSectionWhenEmpty() {
        let agent = Agent(name: "Test")
        context.insert(agent)
        try! context.save()

        let prompt = builder.buildSystemPrompt(for: agent)

        XCTAssertFalse(prompt.contains("Additional Configs Available"))
    }

    @MainActor
    func testCustomConfigsSectionShowsKeys() {
        let agent = Agent(name: "Test")
        context.insert(agent)

        let c1 = AgentConfig(key: "notes.md", content: "My notes")
        let c2 = AgentConfig(key: "todo.md", content: "My tasks")
        context.insert(c1)
        context.insert(c2)
        agent.customConfigs.append(c1)
        agent.customConfigs.append(c2)
        try! context.save()

        let prompt = builder.buildSystemPrompt(for: agent)

        XCTAssertTrue(prompt.contains("Additional Configs Available"))
        XCTAssertTrue(prompt.contains("notes.md"))
        XCTAssertTrue(prompt.contains("todo.md"))
    }

    // MARK: - Related Sessions Section

    @MainActor
    func testNoRelatedSessionsSectionWhenEmpty() {
        let agent = Agent(name: "Test")
        context.insert(agent)
        try! context.save()

        let prompt = builder.buildSystemPrompt(for: agent, relatedSessions: [])

        XCTAssertFalse(prompt.contains("## Related Sessions"),
                       "Should not have a Related Sessions heading when list is empty")
    }

    @MainActor
    func testRelatedSessionsSectionWithSessions() {
        let agent = Agent(name: "Test")
        context.insert(agent)
        try! context.save()

        let sessionId = UUID()
        let sessions = [
            (id: sessionId, title: "Previous Chat", updatedAt: Date())
        ]

        let prompt = builder.buildSystemPrompt(for: agent, relatedSessions: sessions)

        XCTAssertTrue(prompt.contains("Related Sessions"))
        XCTAssertTrue(prompt.contains("Previous Chat"))
        XCTAssertTrue(prompt.contains(sessionId.uuidString))
        XCTAssertTrue(prompt.contains("recall_session"))
    }

    @MainActor
    func testMultipleRelatedSessions() {
        let agent = Agent(name: "Test")
        context.insert(agent)
        try! context.save()

        let s1 = (id: UUID(), title: "Chat A", updatedAt: Date(timeIntervalSince1970: 1000))
        let s2 = (id: UUID(), title: "Chat B", updatedAt: Date(timeIntervalSince1970: 2000))
        let s3 = (id: UUID(), title: "Chat C", updatedAt: Date(timeIntervalSince1970: 3000))

        let prompt = builder.buildSystemPrompt(for: agent, relatedSessions: [s1, s2, s3])

        XCTAssertTrue(prompt.contains("Chat A"))
        XCTAssertTrue(prompt.contains("Chat B"))
        XCTAssertTrue(prompt.contains("Chat C"))
    }

    // MARK: - Code Execution Section with File & Apple Integration

    @MainActor
    func testCodeExecutionSectionIncludesFileSystem() {
        let agent = Agent(name: "Test")
        context.insert(agent)
        try! context.save()

        let prompt = builder.buildSystemPrompt(for: agent)

        XCTAssertTrue(prompt.contains("fs.list"))
        XCTAssertTrue(prompt.contains("fs.read"))
        XCTAssertTrue(prompt.contains("fs.write"))
    }

    @MainActor
    func testCodeExecutionSectionExcludesFileSystemWhenDisabled() {
        let agent = Agent(name: "Test")
        context.insert(agent)
        agent.setPermissionLevel(.disabled, for: .files)
        try! context.save()

        let prompt = builder.buildSystemPrompt(for: agent)

        XCTAssertTrue(prompt.contains("Code Execution"))
        XCTAssertFalse(prompt.contains("fs.list"))
        XCTAssertFalse(prompt.contains("fs.read"))
    }

    @MainActor
    func testCodeExecutionSectionIncludesAppleNamespaces() {
        let agent = Agent(name: "Test")
        context.insert(agent)
        try! context.save()

        let prompt = builder.buildSystemPrompt(for: agent)

        XCTAssertTrue(prompt.contains("apple.calendar"))
        XCTAssertTrue(prompt.contains("apple.health"))
    }

    @MainActor
    func testCodeExecutionSectionExcludesDisabledAppleNamespaces() {
        let agent = Agent(name: "Test")
        context.insert(agent)
        for cat in ToolCategory.appleCategories {
            agent.setPermissionLevel(.disabled, for: cat)
        }
        try! context.save()

        let prompt = builder.buildSystemPrompt(for: agent)

        XCTAssertTrue(prompt.contains("Code Execution"))
        XCTAssertFalse(prompt.contains("apple.calendar"))
        XCTAssertFalse(prompt.contains("apple.health"))
    }

    // MARK: - readOnly Permission Keeps Section Visible

    @MainActor
    func testReadOnlyPermissionStillShowsSection() {
        let agent = Agent(name: "Test")
        context.insert(agent)
        agent.setPermissionLevel(.readOnly, for: .browser)
        try! context.save()

        let prompt = builder.buildSystemPrompt(for: agent)

        XCTAssertTrue(prompt.contains("### Browser"),
                      "readOnly != disabled, section should appear")
    }
}

// MARK: - DefaultPrompts Tests

final class DefaultPromptsTests: XCTestCase {

    func testDefaultSoulIsNonEmpty() {
        let soul = DefaultPrompts.defaultSoul
        XCTAssertFalse(soul.isEmpty)
        XCTAssertTrue(soul.contains("Soul") || soul.contains("soul") || soul.contains("iClaw"))
    }

    func testDefaultMemoryIsNonEmpty() {
        let memory = DefaultPrompts.defaultMemory
        XCTAssertFalse(memory.isEmpty)
        XCTAssertTrue(memory.contains("Memory") || memory.contains("memory"))
    }

    func testDefaultUserIsNonEmpty() {
        let user = DefaultPrompts.defaultUser
        XCTAssertFalse(user.isEmpty)
        XCTAssertTrue(user.contains("User") || user.contains("user") || user.contains("Profile"))
    }

    func testDefaultPromptsAreDistinct() {
        let soul = DefaultPrompts.defaultSoul
        let memory = DefaultPrompts.defaultMemory
        let user = DefaultPrompts.defaultUser

        XCTAssertNotEqual(soul, memory)
        XCTAssertNotEqual(soul, user)
        XCTAssertNotEqual(memory, user)
    }
}
