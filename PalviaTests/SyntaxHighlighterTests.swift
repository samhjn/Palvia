import XCTest
@testable import Palvia

final class SyntaxHighlighterTests: XCTestCase {

    func testEmptyInputProducesNoTokens() {
        let tokens = SyntaxHighlighter.tokenize(code: "", language: "swift")

        XCTAssertTrue(tokens.isEmpty)
    }

    func testStringEndingWithEscapedBackslashDoesNotCrash() {
        let tokens = SyntaxHighlighter.tokenize(code: #"let value = "unfinished\"#, language: "swift")

        assertLastToken(in: tokens, text: #""unfinished\"#, type: .string)
    }

    func testSingleQuotedStringEndingWithEscapedBackslashDoesNotCrash() {
        let tokens = SyntaxHighlighter.tokenize(code: #"value = 'unfinished\"#, language: "python")

        assertLastToken(in: tokens, text: #"'unfinished\"#, type: .string)
    }

    func testStringWithEscapedQuoteRemainsOneStringToken() {
        let tokens = SyntaxHighlighter.tokenize(code: #"let value = "a \"quoted\" word""#, language: "swift")

        assertContainsToken(in: tokens, text: #""a \"quoted\" word""#, type: .string)
    }

    func testStringWithEscapeBeforeNewlineDoesNotReadPastEnd() {
        let source = "print(\"hello\\\nnext\")"
        let tokens = SyntaxHighlighter.tokenize(code: source, language: "swift")

        assertContainsToken(in: tokens, text: "\"hello\\", type: .string)
    }

    func testUnterminatedStringWithoutEscapeStopsAtEnd() {
        let tokens = SyntaxHighlighter.tokenize(code: #"let value = "unfinished"#, language: "swift")

        assertLastToken(in: tokens, text: #""unfinished"#, type: .string)
    }

    func testUnterminatedTripleQuotedStringIncludesTrailingCharacters() {
        let source = "\"\"\"line 1\\\nline 2"
        let tokens = SyntaxHighlighter.tokenize(code: source, language: "swift")

        assertOnlyToken(in: tokens, text: source, type: .string)
    }

    func testUnterminatedTripleQuotedStringWithShortTailIncludesAllInput() {
        let source = "\"\"\"ab"
        let tokens = SyntaxHighlighter.tokenize(code: source, language: "swift")

        assertOnlyToken(in: tokens, text: source, type: .string)
    }

    func testUnterminatedTripleQuotedStringEndingWithEscapeIncludesFinalCharacter() {
        let source = "\"\"\"line\\"
        let tokens = SyntaxHighlighter.tokenize(code: source, language: "swift")

        assertOnlyToken(in: tokens, text: source, type: .string)
    }

    func testClosedTripleQuotedStringStillConsumesClosingDelimiter() {
        let source = "\"\"\"line 1\nline 2\"\"\""
        let tokens = SyntaxHighlighter.tokenize(code: source, language: "swift")

        assertOnlyToken(in: tokens, text: source, type: .string)
    }

    func testClosedTripleQuotedStringLeavesFollowingToken() {
        let source = "\"\"\"line\"\"\"x"
        let tokens = SyntaxHighlighter.tokenize(code: source, language: "swift")

        XCTAssertEqual(tokens.count, 2)
        assertToken(tokens[0], text: "\"\"\"line\"\"\"", type: .string)
        assertToken(tokens[1], text: "x", type: .plain)
    }

    func testSwiftRawStringAtEndOfFile() {
        let source = ##"let value = #"raw"#"##
        let tokens = SyntaxHighlighter.tokenize(code: source, language: "swift")

        assertContainsToken(in: tokens, text: ##"#"raw"#"##, type: .string)
    }

    func testUnterminatedSwiftRawStringConsumesRemainingInput() {
        let source = ##"let value = #"raw"##
        let tokens = SyntaxHighlighter.tokenize(code: source, language: "swift")

        assertLastToken(in: tokens, text: ##"#"raw"##, type: .string)
    }

    func testUnterminatedBlockCommentConsumesRemainingInput() {
        let source = "let a = 1 /* unfinished"
        let tokens = SyntaxHighlighter.tokenize(code: source, language: "swift")

        assertLastToken(in: tokens, text: "/* unfinished", type: .comment)
    }

    func testLineCommentAtEndOfFileWithoutNewline() {
        let source = "let a = 1 // trailing comment"
        let tokens = SyntaxHighlighter.tokenize(code: source, language: "swift")

        assertLastToken(in: tokens, text: "// trailing comment", type: .comment)
    }

    func testAttributePrefixAtEndOfFileFallsBackToPlainToken() {
        let tokens = SyntaxHighlighter.tokenize(code: "@", language: "swift")

        assertOnlyToken(in: tokens, text: "@", type: .plain)
    }

    func testNumberWithExponentMarkerAtEndDoesNotCrash() {
        let tokens = SyntaxHighlighter.tokenize(code: "1e", language: "swift")

        assertOnlyToken(in: tokens, text: "1e", type: .number)
    }
}

private func assertOnlyToken(
    in tokens: [(String, SyntaxHighlighter.TokenType)],
    text: String,
    type: SyntaxHighlighter.TokenType,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(tokens.count, 1, file: file, line: line)
    guard let token = tokens.first else { return }
    assertToken(token, text: text, type: type, file: file, line: line)
}

private func assertLastToken(
    in tokens: [(String, SyntaxHighlighter.TokenType)],
    text: String,
    type: SyntaxHighlighter.TokenType,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard let token = tokens.last else {
        XCTFail("Expected at least one token", file: file, line: line)
        return
    }
    assertToken(token, text: text, type: type, file: file, line: line)
}

private func assertContainsToken(
    in tokens: [(String, SyntaxHighlighter.TokenType)],
    text: String,
    type: SyntaxHighlighter.TokenType,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertTrue(
        tokens.contains { $0.0 == text && $0.1 == type },
        "Expected token (text: \(text), type: \(type)) in \(tokens)",
        file: file,
        line: line
    )
}

private func assertToken(
    _ token: (String, SyntaxHighlighter.TokenType),
    text: String,
    type: SyntaxHighlighter.TokenType,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(token.0, text, file: file, line: line)
    XCTAssertEqual(token.1, type, file: file, line: line)
}
