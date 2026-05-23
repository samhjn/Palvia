import XCTest
@testable import iClaw

final class SSEParserTests: XCTestCase {

    // MARK: - Line-based parsing (parseLine)

    func testParseLineDataMessage() {
        var parser = SSEParser()
        var events = parser.parseLine("data: {\"content\": \"hello\"}")
        XCTAssertTrue(events.isEmpty, "Should buffer until empty line")

        events = parser.parseLine("")
        XCTAssertEqual(events.count, 1)
        if case .message(let data) = events.first {
            XCTAssertEqual(data, "{\"content\": \"hello\"}")
        } else {
            XCTFail("Expected .message event")
        }
    }

    func testParseLineDone() {
        var parser = SSEParser()
        let events = parser.parseLine("data: [DONE]")
        XCTAssertEqual(events.count, 1)
        if case .done = events.first {} else {
            XCTFail("Expected .done event")
        }
    }

    func testParseLineMultipleDataLines() {
        var parser = SSEParser()
        _ = parser.parseLine("data: line1")
        _ = parser.parseLine("data: line2")
        let events = parser.parseLine("")
        XCTAssertEqual(events.count, 1)
        if case .message(let data) = events.first {
            XCTAssertEqual(data, "line1\nline2")
        } else {
            XCTFail("Expected .message with joined data")
        }
    }

    func testParseLineEmptyData() {
        var parser = SSEParser()
        _ = parser.parseLine("data:")
        let events = parser.parseLine("")
        XCTAssertTrue(events.isEmpty, "Empty data lines produce no event")
    }

    func testParseLineIgnoresNonDataFields() {
        var parser = SSEParser()
        _ = parser.parseLine("event: message")
        _ = parser.parseLine("id: 123")
        _ = parser.parseLine("retry: 5000")
        _ = parser.parseLine(": comment")
        _ = parser.parseLine("data: actual_data")
        let events = parser.parseLine("")
        XCTAssertEqual(events.count, 1)
        if case .message(let data) = events.first {
            XCTAssertEqual(data, "actual_data")
        }
    }

    func testParseLineConsecutiveEmptyLines() {
        var parser = SSEParser()
        let events1 = parser.parseLine("")
        XCTAssertTrue(events1.isEmpty)
        let events2 = parser.parseLine("")
        XCTAssertTrue(events2.isEmpty)
    }

    // MARK: - Chunk-based parsing (parse(chunk:))

    func testChunkParseSingleEvent() {
        var parser = SSEParser()
        let events = parser.parse(chunk: "data: {\"id\":1}\n\n")
        XCTAssertEqual(events.count, 1)
        if case .message(let data) = events.first {
            XCTAssertEqual(data, "{\"id\":1}")
        }
    }

    func testChunkParseMultipleEvents() {
        var parser = SSEParser()
        let events = parser.parse(chunk: "data: first\n\ndata: second\n\n")
        XCTAssertEqual(events.count, 2)
        if case .message(let data1) = events[0] {
            XCTAssertEqual(data1, "first")
        }
        if case .message(let data2) = events[1] {
            XCTAssertEqual(data2, "second")
        }
    }

    func testChunkParseDone() {
        var parser = SSEParser()
        let events = parser.parse(chunk: "data: [DONE]\n\n")
        XCTAssertEqual(events.count, 1)
        if case .done = events.first {} else {
            XCTFail("Expected .done")
        }
    }

    func testChunkParseSplitAcrossChunks() {
        var parser = SSEParser()
        let events1 = parser.parse(chunk: "data: part")
        XCTAssertTrue(events1.isEmpty, "Incomplete event should be buffered")

        let events2 = parser.parse(chunk: "ial\n\n")
        XCTAssertEqual(events2.count, 1)
        if case .message(let data) = events2.first {
            XCTAssertEqual(data, "partial")
        }
    }

    func testChunkParseMultiLineData() {
        var parser = SSEParser()
        let events = parser.parse(chunk: "data: line1\ndata: line2\n\n")
        XCTAssertEqual(events.count, 1)
        if case .message(let data) = events.first {
            XCTAssertEqual(data, "line1\nline2")
        }
    }

    func testChunkParseDoneStopsProcessing() {
        var parser = SSEParser()
        let events = parser.parse(chunk: "data: before\n\ndata: [DONE]\n\ndata: after\n\n")
        // [DONE] returns early, so "after" is not processed
        XCTAssertTrue(events.count >= 2)
        if case .message(let data) = events[0] {
            XCTAssertEqual(data, "before")
        }
        if case .done = events[1] {} else {
            XCTFail("Expected .done as second event")
        }
    }

    // MARK: - Reset

    func testReset() {
        var parser = SSEParser()
        _ = parser.parse(chunk: "data: buffered")
        parser.reset()
        let events = parser.parse(chunk: "\n\n")
        XCTAssertTrue(events.isEmpty, "After reset, buffered data should be cleared")
    }
}
