import XCTest
@testable import iClaw

/// Covers the POSIX fd table on AppleEcosystemBridge: monotonic fd assignment,
/// write/seek/read round-trip, lifecycle (close, auto-close on unregister),
/// cross-context isolation, and the per-context fd cap.
@MainActor
final class AppleEcosystemBridgeFdTests: XCTestCase {

    private var bridge: AppleEcosystemBridge!
    private var agentId: UUID!
    private var execId: String!

    override func setUp() async throws {
        try await super.setUp()
        bridge = AppleEcosystemBridge.shared
        agentId = UUID()
        execId = UUID().uuidString
        bridge.registerContext(execId: execId, agentId: agentId) { _ in true }
    }

    override func tearDown() async throws {
        bridge.unregisterPermissions(execId: execId)
        AgentFileManager.shared.cleanupAgentFiles(agentId: agentId)
        bridge = nil
        agentId = nil
        execId = nil
        try await super.tearDown()
    }

    private func call(_ action: String, _ args: [String: Any]) async -> String {
        await bridge.dispatchForTesting(action: action, args: args, execId: execId)
    }

    private func openFd(_ path: String, flags: String) async throws -> Int {
        let res = await call("files.open", ["path": path, "flags": flags])
        guard let fd = Int(res) else {
            XCTFail("files.open returned non-numeric result: \(res)")
            throw NSError(domain: "test", code: 1)
        }
        return fd
    }

    // MARK: - Open / Close

    func testOpenReturnsMonotonicFd() async throws {
        try AgentFileManager.shared.writeFile(agentId: agentId, name: "a.txt", data: Data("a".utf8))
        try AgentFileManager.shared.writeFile(agentId: agentId, name: "b.txt", data: Data("b".utf8))

        let fdA = try await openFd("a.txt", flags: "r")
        let fdB = try await openFd("b.txt", flags: "r")

        XCTAssertEqual(fdB, fdA + 1, "fds should increment monotonically")

        _ = await call("files.close", ["fd": fdA])
        _ = await call("files.close", ["fd": fdB])
    }

    func testCloseInvalidatesFd() async throws {
        try AgentFileManager.shared.writeFile(agentId: agentId, name: "x.txt", data: Data("x".utf8))
        let fd = try await openFd("x.txt", flags: "r")

        let closeResult = await call("files.close", ["fd": fd])
        XCTAssertEqual(closeResult, "OK")

        let readResult = await call("files.read", ["fd": fd, "length": 10])
        XCTAssertTrue(readResult.contains("Invalid file descriptor"), "Post-close read should fail, got: \(readResult)")
    }

    func testOpenMissingFileInReadModeFails() async {
        let res = await call("files.open", ["path": "nonexistent.txt", "flags": "r"])
        XCTAssertTrue(res.contains("not found") || res.contains("Error"), "Expected error, got: \(res)")
    }

    func testOpenInvalidFlagFails() async {
        let res = await call("files.open", ["path": "anything.txt", "flags": "q"])
        XCTAssertTrue(res.contains("Invalid open flag"), "Expected invalid-flag error, got: \(res)")
    }

    func testOpenDirectoryFails() async throws {
        try AgentFileManager.shared.makeDirectory(agentId: agentId, path: "folder")
        let res = await call("files.open", ["path": "folder", "flags": "r"])
        XCTAssertTrue(res.contains("Is a directory"), "Expected directory error, got: \(res)")
    }

    // MARK: - Write / Seek / Read round-trip

    func testWriteThenSeekThenReadRoundtrips() async throws {
        let fd = try await openFd("log.txt", flags: "a+")

        _ = await call("files.write", ["fd": fd, "content": "hello"])
        _ = await call("files.write", ["fd": fd, "content": " world"])

        _ = await call("files.seek", ["fd": fd, "offset": 0, "whence": "start"])
        let read = await call("files.read", ["fd": fd, "length": 64])
        XCTAssertEqual(read, "hello world")

        _ = await call("files.close", ["fd": fd])
    }

    func testReadAtPositionDoesNotAffectSubsequentSequentialReads() async throws {
        try AgentFileManager.shared.writeFile(agentId: agentId, name: "f.txt", data: Data("0123456789".utf8))
        let fd = try await openFd("f.txt", flags: "r")

        let slice = await call("files.read", ["fd": fd, "length": 3, "position": 5])
        XCTAssertEqual(slice, "567")

        let next = await call("files.read", ["fd": fd, "length": 2])
        XCTAssertEqual(next, "89", "Sequential read after positioned read should resume from the new position")

        _ = await call("files.close", ["fd": fd])
    }

    func testSeekWhenceVariants() async throws {
        try AgentFileManager.shared.writeFile(agentId: agentId, name: "f.txt", data: Data("0123456789".utf8))
        let fd = try await openFd("f.txt", flags: "r")

        let r1 = await call("files.seek", ["fd": fd, "offset": 3, "whence": "start"])
        XCTAssertEqual(r1, "3")
        let r2 = await call("files.seek", ["fd": fd, "offset": 2, "whence": "current"])
        XCTAssertEqual(r2, "5")
        let r3 = await call("files.seek", ["fd": fd, "offset": -1, "whence": "end"])
        XCTAssertEqual(r3, "9")

        _ = await call("files.close", ["fd": fd])
    }

    func testAppendModeAlwaysWritesToEnd() async throws {
        try AgentFileManager.shared.writeFile(agentId: agentId, name: "log.txt", data: Data("head".utf8))
        let fd = try await openFd("log.txt", flags: "a+")

        // Even if we seek to the start, append mode should still append at end.
        _ = await call("files.seek", ["fd": fd, "offset": 0, "whence": "start"])
        _ = await call("files.write", ["fd": fd, "content": "-tail"])
        _ = await call("files.close", ["fd": fd])

        let data = try AgentFileManager.shared.readFile(agentId: agentId, name: "log.txt")
        XCTAssertEqual(String(data: data, encoding: .utf8), "head-tail")
    }

    func testWriteModeTruncatesOnOpen() async throws {
        try AgentFileManager.shared.writeFile(agentId: agentId, name: "t.txt", data: Data("existing".utf8))

        let fd = try await openFd("t.txt", flags: "w")
        _ = await call("files.write", ["fd": fd, "content": "new"])
        _ = await call("files.close", ["fd": fd])

        let data = try AgentFileManager.shared.readFile(agentId: agentId, name: "t.txt")
        XCTAssertEqual(String(data: data, encoding: .utf8), "new")
    }

    func testReadOnlyFdRejectsWrite() async throws {
        try AgentFileManager.shared.writeFile(agentId: agentId, name: "r.txt", data: Data("r".utf8))
        let fd = try await openFd("r.txt", flags: "r")

        let res = await call("files.write", ["fd": fd, "content": "x"])
        XCTAssertTrue(res.contains("not writable"))

        _ = await call("files.close", ["fd": fd])
    }

    // MARK: - Truncate via fd

    func testFtruncateShrinks() async throws {
        let fd = try await openFd("f.txt", flags: "w+")
        _ = await call("files.write", ["fd": fd, "content": "abcdefg"])
        _ = await call("files.truncate", ["fd": fd, "length": 3])
        _ = await call("files.close", ["fd": fd])

        let data = try AgentFileManager.shared.readFile(agentId: agentId, name: "f.txt")
        XCTAssertEqual(String(data: data, encoding: .utf8), "abc")
    }

    // MARK: - fstat / tell

    func testFstatReturnsPosition() async throws {
        try AgentFileManager.shared.writeFile(agentId: agentId, name: "f.txt", data: Data("hello".utf8))
        let fd = try await openFd("f.txt", flags: "r")

        _ = await call("files.seek", ["fd": fd, "offset": 2, "whence": "start"])
        let stat = await call("files.fstat", ["fd": fd])
        XCTAssertTrue(stat.contains("\"position\":2"), "fstat should report current position, got: \(stat)")
        XCTAssertTrue(stat.contains("\"size\":5"))

        let tell = await call("files.tell", ["fd": fd])
        XCTAssertEqual(tell, "2")

        _ = await call("files.close", ["fd": fd])
    }

    // MARK: - Lifecycle: auto-close on unregister

    func testUnregisterClosesAllFds() async throws {
        try AgentFileManager.shared.writeFile(agentId: agentId, name: "x.txt", data: Data("x".utf8))
        _ = try await openFd("x.txt", flags: "r")
        _ = try await openFd("x.txt", flags: "r")

        XCTAssertEqual(bridge.fdCount(execId: execId), 2)
        bridge.unregisterPermissions(execId: execId)
        XCTAssertEqual(bridge.fdCount(execId: execId), 0, "All fds must be released when context is unregistered")

        // Re-register so tearDown's unregister is a no-op on this exec (it still calls it safely).
        bridge.registerContext(execId: execId, agentId: agentId) { _ in true }
    }

    // MARK: - Cross-context isolation

    func testFdFromOtherContextIsRejected() async throws {
        try AgentFileManager.shared.writeFile(agentId: agentId, name: "x.txt", data: Data("x".utf8))
        let fdA = try await openFd("x.txt", flags: "r")

        let otherExec = UUID().uuidString
        bridge.registerContext(execId: otherExec, agentId: agentId) { _ in true }
        defer { bridge.unregisterPermissions(execId: otherExec) }

        let res = await bridge.dispatchForTesting(action: "files.read", args: ["fd": fdA, "length": 1], execId: otherExec)
        XCTAssertTrue(res.contains("Invalid file descriptor"), "Cross-context fd reuse must be rejected, got: \(res)")
    }

    // MARK: - Fd cap

    func testMaxFdsEnforced() async throws {
        try AgentFileManager.shared.writeFile(agentId: agentId, name: "x.txt", data: Data("x".utf8))

        for _ in 0..<AppleEcosystemBridge.maxFdsPerContext {
            _ = try await openFd("x.txt", flags: "r")
        }
        let res = await call("files.open", ["path": "x.txt", "flags": "r"])
        XCTAssertTrue(res.contains("Too many open descriptors"), "Expected cap to trigger, got: \(res)")
    }

    // MARK: - Legacy whole-file path (files.readFile / files.writeFile)

    func testReadFileAndWriteFileDispatch() async throws {
        _ = await call("files.writeFile", ["path": "note.txt", "content": "hello via bridge"])
        let read = await call("files.readFile", ["path": "note.txt"])
        XCTAssertEqual(read, "hello via bridge")
    }

    func testAppendFileDispatch() async throws {
        _ = await call("files.writeFile", ["path": "log.txt", "content": "a"])
        _ = await call("files.appendFile", ["path": "log.txt", "content": "b"])
        _ = await call("files.appendFile", ["path": "log.txt", "content": "c"])
        let res = await call("files.readFile", ["path": "log.txt"])
        XCTAssertEqual(res, "abc")
    }

    func testStatReturnsJsonShape() async throws {
        try AgentFileManager.shared.writeFile(agentId: agentId, name: "f.txt", data: Data("abc".utf8))
        let res = await call("files.stat", ["path": "f.txt"])
        XCTAssertTrue(res.contains("\"size\":3"))
        XCTAssertTrue(res.contains("\"is_file\":true"))
        XCTAssertTrue(res.contains("\"is_dir\":false"))
        XCTAssertTrue(res.contains("\"mtime_ms\":"))
    }

    func testCpAndMvDispatch() async throws {
        _ = await call("files.writeFile", ["path": "src.txt", "content": "data"])

        let cp = await call("files.cp", ["src": "src.txt", "dest": "copy.txt"])
        XCTAssertEqual(cp, "OK")
        let readCopy = await call("files.readFile", ["path": "copy.txt"])
        XCTAssertEqual(readCopy, "data")

        let mv = await call("files.mv", ["src": "copy.txt", "dest": "renamed.txt"])
        XCTAssertEqual(mv, "OK")
        let existsCopy = await call("files.exists", ["path": "copy.txt"])
        XCTAssertEqual(existsCopy, "false")
        let existsRenamed = await call("files.exists", ["path": "renamed.txt"])
        XCTAssertEqual(existsRenamed, "true")
    }

    func testExistsReturnsBooleanString() async throws {
        try AgentFileManager.shared.writeFile(agentId: agentId, name: "here.txt", data: Data())
        let here = await call("files.exists", ["path": "here.txt"])
        XCTAssertEqual(here, "true")
        let missing = await call("files.exists", ["path": "missing.txt"])
        XCTAssertEqual(missing, "false")
    }
}
