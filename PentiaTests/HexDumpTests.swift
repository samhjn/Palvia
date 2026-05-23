import XCTest
@testable import iClaw

final class HexDumpTests: XCTestCase {

    func testEmptyData() {
        XCTAssertEqual(HexDump.format(Data()), "")
    }

    func testSingleByte() {
        let out = HexDump.format(Data([0x41]))
        // Address, 16 hex cells (15 present as spaces), ASCII side.
        XCTAssertTrue(out.hasPrefix("00000000: 41"))
        XCTAssertTrue(out.hasSuffix("A"))
    }

    func testSixteenBytes() {
        let data = Data((0..<16).map { UInt8($0) })
        let out = HexDump.format(data)
        let lines = out.split(separator: "\n")
        XCTAssertEqual(lines.count, 1)
        let line = String(lines[0])
        XCTAssertTrue(line.hasPrefix("00000000: "))
        XCTAssertTrue(line.contains("00 01 02 03 04 05 06 07  08 09 0a 0b 0c 0d 0e 0f"))
    }

    func testSeventeenBytesProducesTwoLines() {
        let data = Data((0..<17).map { UInt8($0) })
        let out = HexDump.format(data)
        let lines = out.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(String(lines[0]).hasPrefix("00000000: "))
        XCTAssertTrue(String(lines[1]).hasPrefix("00000010: 10"))
    }

    func testNonPrintableByteRendersDot() {
        let data = Data([0x00, 0x41, 0xff, 0x42])
        let out = HexDump.format(data)
        XCTAssertTrue(out.hasSuffix(".A.B"))
    }

    func testStartOffsetAddress() {
        let out = HexDump.format(Data([0x41]), startOffset: 0x100)
        XCTAssertTrue(out.hasPrefix("00000100: 41"))
    }

    func testPrintableAsciiMidRange() {
        let data = Data("Hello!".utf8)
        let out = HexDump.format(data)
        XCTAssertTrue(out.hasSuffix("Hello!"))
    }
}
