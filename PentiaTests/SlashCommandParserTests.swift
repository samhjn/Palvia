import XCTest
@testable import iClaw

/// Phase 5a: pure parser for the `/skill-slug` slash-command.
final class SlashCommandParserTests: XCTestCase {

    private let installedSlugs: Set<String> = ["deep-research", "file-ops", "skill-builder"]

    private func parse(_ input: String) -> SlashCommandResult {
        SlashCommandParser.parse(input) { self.installedSlugs.contains($0) }
    }

    // MARK: - Negative cases (return .none, send unchanged)

    func testEmptyInputIsNone() {
        XCTAssertEqual(parse(""), .none)
    }

    func testPlainTextIsNone() {
        XCTAssertEqual(parse("hello world"), .none)
    }

    func testTextStartingWithSlashButNoSkillIsNone() {
        // A leading `/` followed by alphanumerics that don't match any
        // installed skill must be a no-op so existing usage (file paths,
        // dividers) keeps working.
        XCTAssertEqual(parse("/etc/passwd"), .none)
        XCTAssertEqual(parse("/foo bar"), .none)
        XCTAssertEqual(parse("/unknown"), .none)
    }

    func testSlashAlone_isNone() {
        XCTAssertEqual(parse("/"), .none)
        XCTAssertEqual(parse("/   "), .none)
    }

    func testInternalSlashIsNotCommand() {
        XCTAssertEqual(parse("see /deep-research below"), .none)
    }

    // MARK: - Positive cases

    func testActivateOnly_noRemainingText() {
        XCTAssertEqual(parse("/deep-research"), .activateOnly(slug: "deep-research"))
        XCTAssertEqual(parse("/file-ops"), .activateOnly(slug: "file-ops"))
    }

    func testActivateOnly_trailingWhitespaceIgnored() {
        XCTAssertEqual(parse("/deep-research   "), .activateOnly(slug: "deep-research"))
        XCTAssertEqual(parse("/deep-research\n"), .activateOnly(slug: "deep-research"))
    }

    func testActivateWithRemainingText() {
        XCTAssertEqual(parse("/deep-research what is RLHF?"),
                       .activate(slug: "deep-research", remaining: "what is RLHF?"))
    }

    func testActivateWithMultilineRemaining() {
        let input = "/file-ops\nlist agent files"
        XCTAssertEqual(parse(input), .activate(slug: "file-ops", remaining: "list agent files"))
    }

    func testLeadingWhitespaceIgnored() {
        XCTAssertEqual(parse("  /deep-research go"),
                       .activate(slug: "deep-research", remaining: "go"))
    }

    // MARK: - Slug normalization

    func testUnderscoreAcceptedAsHyphen() {
        // Users commonly type `/deep_research` even though the canonical slug
        // uses hyphens. Both must resolve to the same skill.
        XCTAssertEqual(parse("/deep_research what?"),
                       .activate(slug: "deep-research", remaining: "what?"))
        XCTAssertEqual(parse("/deep_research"),
                       .activateOnly(slug: "deep-research"))
    }

    func testUppercaseFolded() {
        XCTAssertEqual(parse("/Deep-Research go"),
                       .activate(slug: "deep-research", remaining: "go"))
        XCTAssertEqual(parse("/DEEP_RESEARCH"),
                       .activateOnly(slug: "deep-research"))
    }

    func testMixedSeparatorsNormalized() {
        // `/deep-research_v2` is unusual but should still resolve cleanly
        // via underscore→hyphen normalization. Won't match anything in the
        // test set; expect .none.
        XCTAssertEqual(parse("/deep-research_v2"), .none)
    }

    // MARK: - Lookup behavior

    func testLookupClosureCalledWithNormalizedSlug() {
        var seenSlugs: [String] = []
        _ = SlashCommandParser.parse("/Deep_Research foo") { slug in
            seenSlugs.append(slug)
            return false
        }
        XCTAssertEqual(seenSlugs, ["deep-research"])
    }
}
