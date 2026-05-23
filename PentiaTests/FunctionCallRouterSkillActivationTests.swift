import XCTest
import SwiftData
@testable import iClaw

/// Phase 6b: `FunctionCallRouter.activateSkillForSession` marks the skill
/// active in the session record so progressive disclosure expands its body
/// into the system prompt on the next turn.
@MainActor
final class FunctionCallRouterSkillActivationTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var agent: Agent!
    private var session: Session!

    override func setUp() {
        super.setUp()
        let schema = Schema([Agent.self, LLMProvider.self, Session.self, AgentConfig.self,
                             CodeSnippet.self, CronJob.self, InstalledSkill.self, Skill.self,
                             Message.self, SessionEmbedding.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: schema, configurations: [config])
        context = ModelContext(container)
        agent = Agent(name: "TestAgent")
        context.insert(agent)
        session = Session(title: "Test")
        session.agent = agent
        context.insert(session)
        try! context.save()
    }

    override func tearDown() {
        session = nil
        agent = nil
        context = nil
        container = nil
        super.tearDown()
    }

    // MARK: - Tests

    func testActivationAddsSlugToSession() {
        let router = FunctionCallRouter(
            agent: agent, modelContext: context, sessionId: session.id
        )
        router.activateSkillForSession(skillName: "Deep Research")
        XCTAssertEqual(session.activatedSkillSlugs, ["deep-research"])
    }

    func testActivationIsIdempotent() {
        let router = FunctionCallRouter(
            agent: agent, modelContext: context, sessionId: session.id
        )
        router.activateSkillForSession(skillName: "Deep Research")
        router.activateSkillForSession(skillName: "Deep Research")
        router.activateSkillForSession(skillName: "Deep Research")
        XCTAssertEqual(session.activatedSkillSlugs, ["deep-research"])
    }

    func testActivationAccumulatesAcrossCalls() {
        let router = FunctionCallRouter(
            agent: agent, modelContext: context, sessionId: session.id
        )
        router.activateSkillForSession(skillName: "Deep Research")
        router.activateSkillForSession(skillName: "File Ops")
        XCTAssertEqual(session.activatedSkillSlugs, ["deep-research", "file-ops"])
    }

    func testNoSessionId_isNoop() {
        // Cron / sub-agent flows have no chat session — activation must
        // no-op rather than throw or persist anything.
        let router = FunctionCallRouter(
            agent: agent, modelContext: context, sessionId: nil
        )
        router.activateSkillForSession(skillName: "Deep Research")
        // session.activatedSkillSlugs is unaffected (it belongs to a
        // different session row, queried by id).
        XCTAssertTrue(session.activatedSkillSlugs.isEmpty)
    }

    func testUnknownSessionId_isNoop() {
        // sessionId that doesn't match any persisted session — activation
        // must silently fail (the session was deleted, or it's stale).
        let router = FunctionCallRouter(
            agent: agent, modelContext: context, sessionId: UUID()
        )
        router.activateSkillForSession(skillName: "Deep Research")
        XCTAssertTrue(session.activatedSkillSlugs.isEmpty)
    }

    func testSlugDerivedFromSkillName() {
        // Names with spaces, mixed case, and punctuation must round-trip
        // through SkillPackage.derivedSlug — the same routine the rest of
        // the system uses.
        let router = FunctionCallRouter(
            agent: agent, modelContext: context, sessionId: session.id
        )
        router.activateSkillForSession(skillName: "Skill--Builder   v2!!")
        XCTAssertTrue(session.activatedSkillSlugs.contains("skill-builder-v2"))
    }
}
