import XCTest
@testable import iClaw

/// Covers the new cp / mv / truncate / appendFile helpers added to AgentFileManager,
/// including recursive directory copy and path-traversal regressions on the new entry points.
final class AgentFileManagerExtTests: XCTestCase {

    private var fm: AgentFileManager!
    private var agentId: UUID!

    override func setUp() {
        super.setUp()
        fm = AgentFileManager.shared
        agentId = UUID()
    }

    override func tearDown() {
        fm.cleanupAgentFiles(agentId: agentId)
        fm = nil
        agentId = nil
        super.tearDown()
    }

    // MARK: - copyFile

    func testCopyFileCopiesBytes() throws {
        let payload = Data("hello cp".utf8)
        try fm.writeFile(agentId: agentId, name: "src.txt", data: payload)
        try fm.copyFile(agentId: agentId, src: "src.txt", dest: "dest.txt")

        let dest = try fm.readFile(agentId: agentId, name: "dest.txt")
        XCTAssertEqual(dest, payload)
        XCTAssertTrue(fm.fileExists(agentId: agentId, name: "src.txt"))
    }

    func testCopyFileCreatesMissingParentDirectories() throws {
        try fm.writeFile(agentId: agentId, name: "a.txt", data: Data("x".utf8))
        try fm.copyFile(agentId: agentId, src: "a.txt", dest: "nested/dir/copy.txt")

        XCTAssertTrue(fm.fileExists(agentId: agentId, name: "nested/dir/copy.txt"))
    }

    func testCopyDirectoryRecursive() throws {
        try fm.writeFile(agentId: agentId, name: "tree/a.txt", data: Data("a".utf8))
        try fm.writeFile(agentId: agentId, name: "tree/sub/b.txt", data: Data("b".utf8))

        try fm.copyFile(agentId: agentId, src: "tree", dest: "tree-copy", recursive: true)

        XCTAssertEqual(try fm.readFile(agentId: agentId, name: "tree-copy/a.txt"), Data("a".utf8))
        XCTAssertEqual(try fm.readFile(agentId: agentId, name: "tree-copy/sub/b.txt"), Data("b".utf8))
    }

    func testCopyDirectoryNonRecursiveThrows() throws {
        try fm.makeDirectory(agentId: agentId, path: "folder")

        XCTAssertThrowsError(try fm.copyFile(agentId: agentId, src: "folder", dest: "folder-copy", recursive: false)) { err in
            guard case FileToolError.isDirectory = err else {
                return XCTFail("Expected .isDirectory, got \(err)")
            }
        }
    }

    func testCopyFailsOnMissingSource() throws {
        XCTAssertThrowsError(try fm.copyFile(agentId: agentId, src: "nope.txt", dest: "dest.txt"))
    }

    func testCopyFailsWhenDestinationExists() throws {
        try fm.writeFile(agentId: agentId, name: "a.txt", data: Data("a".utf8))
        try fm.writeFile(agentId: agentId, name: "b.txt", data: Data("b".utf8))

        XCTAssertThrowsError(try fm.copyFile(agentId: agentId, src: "a.txt", dest: "b.txt"))
    }

    func testCopyRejectsPathTraversal() throws {
        try fm.writeFile(agentId: agentId, name: "src.txt", data: Data("x".utf8))

        XCTAssertThrowsError(try fm.copyFile(agentId: agentId, src: "src.txt", dest: "../escape.txt"))
        XCTAssertThrowsError(try fm.copyFile(agentId: agentId, src: "../src.txt", dest: "dest.txt"))
    }

    // MARK: - moveFile

    func testMoveFileRemovesSource() throws {
        try fm.writeFile(agentId: agentId, name: "src.txt", data: Data("mv".utf8))
        try fm.moveFile(agentId: agentId, src: "src.txt", dest: "dest.txt")

        XCTAssertFalse(fm.fileExists(agentId: agentId, name: "src.txt"))
        XCTAssertEqual(try fm.readFile(agentId: agentId, name: "dest.txt"), Data("mv".utf8))
    }

    func testMoveFailsWhenDestinationExists() throws {
        try fm.writeFile(agentId: agentId, name: "a.txt", data: Data("a".utf8))
        try fm.writeFile(agentId: agentId, name: "b.txt", data: Data("b".utf8))

        XCTAssertThrowsError(try fm.moveFile(agentId: agentId, src: "a.txt", dest: "b.txt"))
    }

    func testMoveCreatesMissingParentDirectories() throws {
        try fm.writeFile(agentId: agentId, name: "a.txt", data: Data("a".utf8))
        try fm.moveFile(agentId: agentId, src: "a.txt", dest: "archive/2026/a.txt")

        XCTAssertEqual(try fm.readFile(agentId: agentId, name: "archive/2026/a.txt"), Data("a".utf8))
    }

    func testMoveRejectsPathTraversal() throws {
        try fm.writeFile(agentId: agentId, name: "src.txt", data: Data("x".utf8))

        XCTAssertThrowsError(try fm.moveFile(agentId: agentId, src: "src.txt", dest: "../escape.txt"))
    }

    // MARK: - truncateFile

    func testTruncateShrinksFile() throws {
        try fm.writeFile(agentId: agentId, name: "f.txt", data: Data("hello world".utf8))
        try fm.truncateFile(agentId: agentId, path: "f.txt", length: 5)

        XCTAssertEqual(try fm.readFile(agentId: agentId, name: "f.txt"), Data("hello".utf8))
    }

    func testTruncateExtendsWithZeros() throws {
        try fm.writeFile(agentId: agentId, name: "f.txt", data: Data("abc".utf8))
        try fm.truncateFile(agentId: agentId, path: "f.txt", length: 8)

        let data = try fm.readFile(agentId: agentId, name: "f.txt")
        XCTAssertEqual(data.count, 8)
        XCTAssertEqual(data.prefix(3), Data("abc".utf8))
        XCTAssertEqual(Array(data.suffix(5)), [0, 0, 0, 0, 0])
    }

    func testTruncateCreatesMissingFile() throws {
        try fm.truncateFile(agentId: agentId, path: "new.bin", length: 4)

        let data = try fm.readFile(agentId: agentId, name: "new.bin")
        XCTAssertEqual(data, Data(count: 4))
    }

    func testTruncateRejectsDirectory() throws {
        try fm.makeDirectory(agentId: agentId, path: "folder")
        XCTAssertThrowsError(try fm.truncateFile(agentId: agentId, path: "folder", length: 0))
    }

    // MARK: - appendFile

    func testAppendFileAppendsBytes() throws {
        try fm.writeFile(agentId: agentId, name: "log.txt", data: Data("line1\n".utf8))
        try fm.appendFile(agentId: agentId, name: "log.txt", data: Data("line2\n".utf8))
        try fm.appendFile(agentId: agentId, name: "log.txt", data: Data("line3\n".utf8))

        let data = try fm.readFile(agentId: agentId, name: "log.txt")
        XCTAssertEqual(data, Data("line1\nline2\nline3\n".utf8))
    }

    func testAppendFileCreatesMissingFile() throws {
        try fm.appendFile(agentId: agentId, name: "log.txt", data: Data("new".utf8))
        XCTAssertEqual(try fm.readFile(agentId: agentId, name: "log.txt"), Data("new".utf8))
    }

    func testAppendFileRejectsPathTraversal() {
        XCTAssertThrowsError(try fm.appendFile(agentId: agentId, name: "../escape.txt", data: Data()))
    }
}
