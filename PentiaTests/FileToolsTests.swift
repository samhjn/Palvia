import XCTest
@testable import iClaw

@MainActor
final class FileToolsTests: XCTestCase {

    private var tools: FileTools!
    private var agent: Agent!

    override func setUp() {
        super.setUp()
        agent = Agent(name: "FileToolsTest")
        tools = FileTools(agent: agent)
    }

    override func tearDown() {
        AgentFileManager.shared.cleanupAgentFiles(agentId: agent.id)
        tools = nil
        agent = nil
        super.tearDown()
    }

    // MARK: - Default 1KB cap

    func testReadDefaultsToOneKilobyte() throws {
        let big = Data(repeating: UInt8(ascii: "A"), count: 4096)
        try AgentFileManager.shared.writeFile(agentId: agent.id, name: "big.txt", data: big)

        let result = tools.readFile(arguments: ["path": "big.txt"])
        // Should contain 1024 'A' characters followed by a truncation note.
        XCTAssertTrue(result.contains("[truncated: read 1024 of 4096 bytes, next offset=1024]"))
        let visible = result.split(separator: "\n").first.map(String.init) ?? ""
        XCTAssertEqual(visible.count, 1024)
    }

    func testReadHonorsExplicitSize() throws {
        let big = Data(repeating: UInt8(ascii: "B"), count: 4096)
        try AgentFileManager.shared.writeFile(agentId: agent.id, name: "big.txt", data: big)

        let result = tools.readFile(arguments: ["path": "big.txt", "size": 10])
        XCTAssertTrue(result.hasPrefix("BBBBBBBBBB"))
        XCTAssertTrue(result.contains("next offset=10"))
    }

    func testReadWithOffset() throws {
        let data = Data("0123456789ABCDEF".utf8)
        try AgentFileManager.shared.writeFile(agentId: agent.id, name: "f.txt", data: data)

        let result = tools.readFile(arguments: ["path": "f.txt", "size": 4, "offset": 4])
        XCTAssertTrue(result.hasPrefix("4567"))
    }

    func testReadSmallFileNoTruncationSuffix() throws {
        try AgentFileManager.shared.writeFile(agentId: agent.id, name: "tiny.txt", data: Data("hi".utf8))
        let result = tools.readFile(arguments: ["path": "tiny.txt"])
        XCTAssertEqual(result, "hi")
    }

    // MARK: - Hex Mode

    func testReadHexMode() throws {
        try AgentFileManager.shared.writeFile(agentId: agent.id, name: "bin", data: Data([0xde, 0xad, 0xbe, 0xef]))
        let result = tools.readFile(arguments: ["path": "bin", "mode": "hex"])
        XCTAssertTrue(result.hasPrefix("00000000: de ad be ef"))
    }

    func testReadBase64Mode() throws {
        try AgentFileManager.shared.writeFile(agentId: agent.id, name: "bin", data: Data([0x01, 0x02, 0x03]))
        let result = tools.readFile(arguments: ["path": "bin", "mode": "base64"])
        XCTAssertEqual(result, Data([0x01, 0x02, 0x03]).base64EncodedString())
    }

    func testReadBinaryInTextModeReportsError() throws {
        // 0xff 0xfe is not valid UTF-8.
        try AgentFileManager.shared.writeFile(agentId: agent.id, name: "bin", data: Data([0xff, 0xfe]))
        let result = tools.readFile(arguments: ["path": "bin"])
        XCTAssertTrue(result.contains("[Error]"))
        XCTAssertTrue(result.contains("hex"))
    }

    // MARK: - Mkdir & list

    func testMakeDirectoryCreatesFolder() throws {
        // file_mkdir is no longer a default LLM tool; the underlying File Ops skill
        // (and the JS `fs.mkdir` API) both delegate to AgentFileManager.makeDirectory.
        try AgentFileManager.shared.makeDirectory(agentId: agent.id, path: "docs/2026")
        XCTAssertTrue(AgentFileManager.shared.fileInfo(agentId: agent.id, name: "docs/2026")?.isDirectory ?? false)
    }

    func testListShowsDirectoryTag() throws {
        try AgentFileManager.shared.makeDirectory(agentId: agent.id, path: "docs")
        try AgentFileManager.shared.writeFile(agentId: agent.id, name: "root.txt", data: Data("r".utf8))

        let result = tools.listFiles(arguments: [:])
        XCTAssertTrue(result.contains("docs"))
        XCTAssertTrue(result.contains("[dir]"))
        XCTAssertTrue(result.contains("root.txt"))
    }

    func testListInSubdirectory() throws {
        try AgentFileManager.shared.writeFile(agentId: agent.id, name: "docs/a.txt", data: Data("a".utf8))
        try AgentFileManager.shared.writeFile(agentId: agent.id, name: "outside.txt", data: Data("o".utf8))

        let result = tools.listFiles(arguments: ["path": "docs"])
        XCTAssertTrue(result.contains("a.txt"))
        XCTAssertFalse(result.contains("outside.txt"))
    }

    // MARK: - Backward compat: legacy `name` parameter

    func testLegacyNameParameterStillAccepted() throws {
        try AgentFileManager.shared.writeFile(agentId: agent.id, name: "legacy.txt", data: Data("ok".utf8))
        let result = tools.readFile(arguments: ["name": "legacy.txt"])
        XCTAssertEqual(result, "ok")
    }
}
