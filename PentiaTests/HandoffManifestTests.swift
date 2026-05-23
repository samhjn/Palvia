import XCTest
@testable import iClaw

/// Tests for `HandoffManifest` — the payload the Share Extension drops into
/// each staging directory to tell the main app which files belong to which
/// agent.
///
/// The bug that motivated the tolerant loader: the extension wrote dates
/// with `dateEncodingStrategy = .iso8601` while the main app decoded with
/// the default strategy. Every staging directory silently failed to load,
/// so shares were staged but never materialized. These tests pin that down.
final class HandoffManifestTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("iClawHandoffTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        super.tearDown()
    }

    // MARK: - Round-trip

    func testWriteAndLoadRoundTrip() throws {
        let agentId = UUID()
        let manifest = HandoffManifest(
            version: HandoffManifest.currentVersion,
            agentId: agentId,
            files: [
                HandoffFile(name: "img_1.jpg", kind: .image, displayName: nil),
                HandoffFile(name: "report.pdf", kind: .file, displayName: "Q3 Report.pdf"),
                HandoffFile(name: "clip.mp4", kind: .video, displayName: nil),
                HandoffFile(name: "shared.txt", kind: .text, displayName: nil),
            ]
        )

        try manifest.write(to: tempDir)

        let reloaded = HandoffManifest.load(from: tempDir)
        XCTAssertEqual(reloaded, manifest)
    }

    func testLoadMissingManifestReturnsNil() {
        XCTAssertNil(HandoffManifest.load(from: tempDir))
    }

    func testManifestFilenameIsStable() {
        XCTAssertEqual(HandoffManifest.filename, "manifest.json")
    }

    // MARK: - Tolerant loader: legacy createdAt field

    /// Regression test for the original bug. The old shipped schema had a
    /// `createdAt: Date` field that was encoded as ISO-8601 (e.g. by the
    /// extension) and failed to decode on the main app (which used the
    /// default `secondsSinceReferenceDate` strategy). Any future manifest
    /// carrying that field in any date format must still parse.
    func testLoadToleratesLegacyIso8601CreatedAt() throws {
        let agentId = UUID()
        let payload = """
        {
            "version": 1,
            "createdAt": "2026-04-20T14:54:08Z",
            "agentId": "\(agentId.uuidString)",
            "files": [
                { "name": "img_abc.jpg", "kind": "image" }
            ]
        }
        """
        try Data(payload.utf8).write(to: tempDir.appendingPathComponent(HandoffManifest.filename))

        guard let manifest = HandoffManifest.load(from: tempDir) else {
            return XCTFail("Tolerant loader should decode legacy ISO-8601 createdAt")
        }
        XCTAssertEqual(manifest.agentId, agentId)
        XCTAssertEqual(manifest.files.count, 1)
        XCTAssertEqual(manifest.files[0].name, "img_abc.jpg")
        XCTAssertEqual(manifest.files[0].kind, .image)
    }

    func testLoadToleratesLegacySecondsSinceReferenceDateCreatedAt() throws {
        let agentId = UUID()
        let payload = """
        {
            "version": 1,
            "createdAt": 767891648.0,
            "agentId": "\(agentId.uuidString)",
            "files": [
                { "name": "doc.pdf", "kind": "file", "displayName": "Doc.pdf" }
            ]
        }
        """
        try Data(payload.utf8).write(to: tempDir.appendingPathComponent(HandoffManifest.filename))

        guard let manifest = HandoffManifest.load(from: tempDir) else {
            return XCTFail("Tolerant loader should decode legacy seconds-since-ref createdAt")
        }
        XCTAssertEqual(manifest.agentId, agentId)
        XCTAssertEqual(manifest.files.first?.displayName, "Doc.pdf")
    }

    func testLoadToleratesLegacyMillisecondsSinceEpochCreatedAt() throws {
        let agentId = UUID()
        let payload = """
        {
            "version": 1,
            "createdAt": 1745148848000,
            "agentId": "\(agentId.uuidString)",
            "files": [ { "name": "a.txt", "kind": "text" } ]
        }
        """
        try Data(payload.utf8).write(to: tempDir.appendingPathComponent(HandoffManifest.filename))

        XCTAssertNotNil(HandoffManifest.load(from: tempDir))
    }

    // MARK: - Tolerant loader: missing optional fields

    func testLoadToleratesMissingVersion() throws {
        let agentId = UUID()
        let payload = """
        { "agentId": "\(agentId.uuidString)", "files": [ { "name": "x.txt", "kind": "text" } ] }
        """
        try Data(payload.utf8).write(to: tempDir.appendingPathComponent(HandoffManifest.filename))

        let manifest = HandoffManifest.load(from: tempDir)
        XCTAssertNotNil(manifest)
        XCTAssertEqual(manifest?.version, HandoffManifest.currentVersion)
    }

    func testLoadToleratesUnknownExtraFields() throws {
        let agentId = UUID()
        let payload = """
        {
            "version": 1,
            "agentId": "\(agentId.uuidString)",
            "source": "wechat",
            "futureFeature": true,
            "files": [
                { "name": "img.png", "kind": "image", "extraMeta": "ignore" }
            ]
        }
        """
        try Data(payload.utf8).write(to: tempDir.appendingPathComponent(HandoffManifest.filename))

        let manifest = HandoffManifest.load(from: tempDir)
        XCTAssertEqual(manifest?.files.count, 1)
    }

    // MARK: - Tolerant loader: rejects invalid payloads

    func testLoadRejectsInvalidJSON() throws {
        try Data("{ not json".utf8)
            .write(to: tempDir.appendingPathComponent(HandoffManifest.filename))
        XCTAssertNil(HandoffManifest.load(from: tempDir))
    }

    func testLoadRejectsEmptyFile() throws {
        try Data().write(to: tempDir.appendingPathComponent(HandoffManifest.filename))
        XCTAssertNil(HandoffManifest.load(from: tempDir))
    }

    func testLoadRejectsMissingAgentId() throws {
        let payload = """
        { "version": 1, "files": [ { "name": "x.txt", "kind": "text" } ] }
        """
        try Data(payload.utf8).write(to: tempDir.appendingPathComponent(HandoffManifest.filename))
        XCTAssertNil(HandoffManifest.load(from: tempDir))
    }

    func testLoadRejectsBadAgentId() throws {
        let payload = """
        { "version": 1, "agentId": "not-a-uuid", "files": [ { "name": "x.txt", "kind": "text" } ] }
        """
        try Data(payload.utf8).write(to: tempDir.appendingPathComponent(HandoffManifest.filename))
        XCTAssertNil(HandoffManifest.load(from: tempDir))
    }

    func testLoadRejectsEmptyFilesArray() throws {
        let agentId = UUID()
        let payload = """
        { "version": 1, "agentId": "\(agentId.uuidString)", "files": [] }
        """
        try Data(payload.utf8).write(to: tempDir.appendingPathComponent(HandoffManifest.filename))
        XCTAssertNil(HandoffManifest.load(from: tempDir))
    }

    func testLoadSkipsFilesWithUnknownKind() throws {
        let agentId = UUID()
        let payload = """
        {
            "version": 1,
            "agentId": "\(agentId.uuidString)",
            "files": [
                { "name": "a.png", "kind": "image" },
                { "name": "b.weird", "kind": "future-kind" },
                { "name": "", "kind": "file" }
            ]
        }
        """
        try Data(payload.utf8).write(to: tempDir.appendingPathComponent(HandoffManifest.filename))

        let manifest = HandoffManifest.load(from: tempDir)
        XCTAssertEqual(manifest?.files.count, 1)
        XCTAssertEqual(manifest?.files.first?.name, "a.png")
    }

    // MARK: - HandoffFileKind

    func testHandoffFileKindEncodesAsString() throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode([HandoffFileKind.image, .video, .file, .text])
        let string = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(string, "[\"image\",\"video\",\"file\",\"text\"]")
    }

    func testHandoffFileKindAllRawValuesStable() {
        XCTAssertEqual(HandoffFileKind.image.rawValue, "image")
        XCTAssertEqual(HandoffFileKind.video.rawValue, "video")
        XCTAssertEqual(HandoffFileKind.file.rawValue, "file")
        XCTAssertEqual(HandoffFileKind.text.rawValue, "text")
    }
}
