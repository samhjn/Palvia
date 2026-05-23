import XCTest
@testable import iClaw

@MainActor
final class AgentDirectoryPublisherTests: XCTestCase {

    private var publisher: AgentDirectoryPublisher!
    private var createdAgentIds: [UUID] = []

    override func setUp() {
        super.setUp()
        publisher = AgentDirectoryPublisher.shared
        // Clear any stale symlinks from previous runs.
        try? FileManager.default.removeItem(at: publisher.publishedRoot)
        createdAgentIds = []
    }

    override func tearDown() {
        for id in createdAgentIds {
            AgentFileManager.shared.cleanupAgentFiles(agentId: id)
        }
        try? FileManager.default.removeItem(at: publisher.publishedRoot)
        createdAgentIds = []
        publisher = nil
        super.tearDown()
    }

    // MARK: - Sanitize

    func testSanitizeBasic() {
        XCTAssertEqual(AgentDirectoryPublisher.sanitize("Hello"), "Hello")
        XCTAssertEqual(AgentDirectoryPublisher.sanitize("  Hello  "), "Hello")
    }

    func testSanitizeReplacesReservedCharacters() {
        XCTAssertEqual(AgentDirectoryPublisher.sanitize("a/b"), "a_b")
        XCTAssertEqual(AgentDirectoryPublisher.sanitize("a\\b"), "a_b")
        XCTAssertEqual(AgentDirectoryPublisher.sanitize("a:b"), "a_b")
    }

    func testSanitizeEmptyBecomesFallback() {
        XCTAssertEqual(AgentDirectoryPublisher.sanitize(""), "Agent")
        XCTAssertEqual(AgentDirectoryPublisher.sanitize("   "), "Agent")
    }

    func testSanitizeDotsBecomeFallback() {
        XCTAssertEqual(AgentDirectoryPublisher.sanitize("."), "Agent")
        XCTAssertEqual(AgentDirectoryPublisher.sanitize(".."), "Agent")
    }

    // MARK: - Sync

    func testSyncCreatesSymlinkForAgent() throws {
        let agent = Agent(name: "Sally")
        createdAgentIds.append(agent.id)
        try AgentFileManager.shared.writeFile(agentId: agent.id, name: "hello.txt", data: Data("hi".utf8))

        publisher.syncAll(agents: [agent])

        let link = publisher.publishedRoot.appendingPathComponent("Sally")
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        XCTAssertEqual(target, AgentFileManager.shared.agentDirectory(for: agent.id).path)

        // Resolved contents are readable via the symlink.
        let resolved = link.appendingPathComponent("hello.txt")
        let data = try Data(contentsOf: resolved)
        XCTAssertEqual(String(data: data, encoding: .utf8), "hi")
    }

    func testSyncDisambiguatesDuplicateNames() {
        let a = Agent(name: "Twin")
        let b = Agent(name: "Twin")
        createdAgentIds.append(contentsOf: [a.id, b.id])

        publisher.syncAll(agents: [a, b])

        let firstLink = publisher.publishedRoot.appendingPathComponent("Twin")
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: firstLink.path))

        let secondName = "Twin-\(String(b.id.uuidString.prefix(8)))"
        let secondLink = publisher.publishedRoot.appendingPathComponent(secondName)
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: secondLink.path))
    }

    func testSyncRemovesLinkForDeletedAgent() {
        let a = Agent(name: "Stays")
        let b = Agent(name: "Goes")
        createdAgentIds.append(contentsOf: [a.id, b.id])

        publisher.syncAll(agents: [a, b])
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(
            atPath: publisher.publishedRoot.appendingPathComponent("Goes").path))

        publisher.syncAll(agents: [a])
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(
            atPath: publisher.publishedRoot.appendingPathComponent("Goes").path))
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(
            atPath: publisher.publishedRoot.appendingPathComponent("Stays").path))
    }

    func testSyncHandlesRename() {
        let agent = Agent(name: "OldName")
        createdAgentIds.append(agent.id)

        publisher.syncAll(agents: [agent])
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(
            atPath: publisher.publishedRoot.appendingPathComponent("OldName").path))

        agent.name = "NewName"
        publisher.syncAll(agents: [agent])

        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(
            atPath: publisher.publishedRoot.appendingPathComponent("OldName").path))
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(
            atPath: publisher.publishedRoot.appendingPathComponent("NewName").path))
    }

    func testSyncIgnoresSubAgents() {
        let parent = Agent(name: "Parent")
        let child = Agent(name: "Child")
        parent.subAgents.append(child)
        createdAgentIds.append(parent.id)
        // Child shares parent's folder — cleanup via parent id is enough.

        publisher.syncAll(agents: [parent, child])

        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(
            atPath: publisher.publishedRoot.appendingPathComponent("Parent").path))
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(
            atPath: publisher.publishedRoot.appendingPathComponent("Child").path))
    }
}
