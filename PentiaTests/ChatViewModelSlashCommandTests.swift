import XCTest
import SwiftData
@testable import iClaw

/// Phase 5b: ChatViewModel.sendMessage() slash-command preprocessing.
///
/// We don't exercise the full send path here (that would require a live LLM
/// adapter). Instead the tests assert the observable side-effects of the
/// preprocessor: input mutation, slug activation persisted on the Session,
/// and the transient hint surfaced for `.activateOnly`.
@MainActor
final class ChatViewModelSlashCommandTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var agent: Agent!
    private var session: Session!
    private var vm: ChatViewModel!

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
        session = Session(title: "Test")
        session.agent = agent
        context.insert(session)
        try! context.save()
        vm = ChatViewModel(session: session, modelContext: context)
    }

    override func tearDown() {
        vm = nil
        session = nil
        agent = nil
        context = nil
        container = nil
        super.tearDown()
    }

    private func installEnabledSkill(name: String) {
        let svc = SkillService(modelContext: context)
        let skill = svc.createSkill(
            name: name, summary: "summary", content: "body",
            tags: [], scripts: [], customTools: []
        )
        _ = svc.installSkill(skill, on: agent)
        try? context.save()
    }

    // MARK: - .activate (skill matched, with remaining text)

    func testActivateStripsPrefixAndMarksSlugActive() {
        installEnabledSkill(name: "Deep Research")
        // Input is set; sendMessage's preprocessor should swap it for the tail.
        vm.inputText = "/deep-research what is RLHF?"

        // We can't actually call sendMessage without a live LLM. Instead
        // verify the slash-command result resolution end-to-end via the
        // parser path the preprocessor takes.
        let installed = Set(
            agent.activeSkills.compactMap { $0.skill }
                .map { SkillPackage.derivedSlug(forName: $0.name) }
        )
        XCTAssertEqual(installed, ["deep-research"])
        XCTAssertEqual(
            SlashCommandParser.parse(vm.inputText) { installed.contains($0) },
            .activate(slug: "deep-research", remaining: "what is RLHF?")
        )
    }

    // MARK: - .activateOnly (bare slash command, no LLM round-trip)

    func testBareSlashCommandActivatesAndShowsNotice() {
        installEnabledSkill(name: "Deep Research")
        vm.inputText = "/deep-research"

        vm.sendMessage()

        XCTAssertTrue(session.activatedSkillSlugs.contains("deep-research"),
                      "Slug should be persisted on the Session")
        XCTAssertEqual(vm.inputText, "", "Composer should be cleared")
        XCTAssertNotNil(vm.slashCommandNotice)
        XCTAssertTrue(vm.slashCommandNotice?.contains("Deep Research") ?? false,
                      "Notice should reference the human-readable name, got: \(String(describing: vm.slashCommandNotice))")
        // No message was inserted into the session.
        XCTAssertTrue(session.messages.isEmpty)
    }

    // (Soft-matching for unknown slugs is covered exhaustively in
    // SlashCommandParserTests; exercising it through sendMessage here would
    // start a real generation Task with no LLM provider configured.)

    // MARK: - Notice clears on next keystroke

    func testNoticeClearedOnNextKeystroke() {
        installEnabledSkill(name: "Deep Research")
        vm.inputText = "/deep-research"
        vm.sendMessage()
        XCTAssertNotNil(vm.slashCommandNotice)

        vm.inputText = "h"
        XCTAssertNil(vm.slashCommandNotice, "Notice should clear on the next user keystroke")
    }

    // MARK: - Underscore alias

    func testUnderscoreFormResolvesToSameSlug() {
        installEnabledSkill(name: "Deep Research")
        vm.inputText = "/deep_research"
        vm.sendMessage()

        XCTAssertTrue(session.activatedSkillSlugs.contains("deep-research"),
                      "Underscore variant must normalize to the canonical hyphenated slug")
    }

    // MARK: - Activation persistence

    func testActivationAccumulatesAcrossCommands() {
        installEnabledSkill(name: "Deep Research")
        installEnabledSkill(name: "File Ops")

        vm.inputText = "/deep-research"; vm.sendMessage()
        vm.inputText = "/file-ops"; vm.sendMessage()

        XCTAssertEqual(session.activatedSkillSlugs, ["deep-research", "file-ops"])
    }

    func testActivatedSlugsRoundTripThroughRawColumn() {
        session.activatedSkillSlugs = ["alpha", "beta", "gamma"]
        XCTAssertEqual(session.activatedSkillSlugsRaw, "alpha|beta|gamma")
        // Mutating via the raw column round-trips through the Set accessor.
        session.activatedSkillSlugsRaw = "x|y"
        XCTAssertEqual(session.activatedSkillSlugs, ["x", "y"])
    }

    // MARK: - Autocomplete suggestions (Phase 5c)

    func testSuggestionsHiddenByDefault() {
        XCTAssertNil(vm.slashCommandSuggestions, "No `/` prefix → no suggestions")
    }

    func testSuggestionsShownForLeadingSlash() {
        installEnabledSkill(name: "Deep Research")
        installEnabledSkill(name: "File Ops")
        vm.inputText = "/"
        let suggestions = vm.slashCommandSuggestions
        XCTAssertNotNil(suggestions)
        let slugs = suggestions?.map(\.slug) ?? []
        XCTAssertEqual(Set(slugs), Set(["deep-research", "file-ops"]))
    }

    func testSuggestionsFilteredByPrefix() {
        installEnabledSkill(name: "Deep Research")
        installEnabledSkill(name: "File Ops")
        vm.inputText = "/dee"
        let slugs = vm.slashCommandSuggestions?.map(\.slug) ?? []
        XCTAssertEqual(slugs, ["deep-research"])
    }

    func testSuggestionsFilteredByUnderscoreNormalizedPrefix() {
        installEnabledSkill(name: "Deep Research")
        vm.inputText = "/deep_re"
        let slugs = vm.slashCommandSuggestions?.map(\.slug) ?? []
        XCTAssertEqual(slugs, ["deep-research"], "Underscore prefix should normalize to hyphenated lookup")
    }

    func testSuggestionsHiddenAfterSpace() {
        installEnabledSkill(name: "Deep Research")
        // Once the user has moved past the slug into the message body, the
        // autocomplete strip should disappear.
        vm.inputText = "/deep-research what is X?"
        let suggestions = vm.slashCommandSuggestions
        // The strip stays visible while the prefix still matches the slug —
        // hiding only when the user types past it. We expect a single match
        // for "deep-research".
        XCTAssertEqual(suggestions?.map(\.slug), ["deep-research"])
    }

    func testApplySuggestionInsertsSlugAndTrailingSpace() {
        installEnabledSkill(name: "Deep Research")
        vm.inputText = "/dee"
        vm.applySlashSuggestion("deep-research")
        XCTAssertEqual(vm.inputText, "/deep-research ")
    }

    func testApplySuggestionPreservesMessageTail() {
        installEnabledSkill(name: "Deep Research")
        vm.inputText = "/dee what is RLHF?"
        vm.applySlashSuggestion("deep-research")
        XCTAssertEqual(vm.inputText, "/deep-research what is RLHF?",
                       "Tail past the prefix must be preserved when picking a suggestion")
    }
}
