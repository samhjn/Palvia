import XCTest
@testable import iClaw

/// Tests for `ShareHandoff` — the main-app side of the Share Extension flow.
///
/// Focused on pure helpers (URL matching, sweepOrphans) that don't require
/// an App Group container to be active. The end-to-end `processPending`
/// path is exercised manually because it hard-depends on the live
/// SwiftData store and App Group.
final class ShareHandoffTests: XCTestCase {

    // MARK: - isHandoffURL

    func testAcceptsSessionNewURL() {
        let url = URL(string: "iclaw://session/new?agentId=\(UUID().uuidString)&handoffId=\(UUID().uuidString)")!
        XCTAssertTrue(ShareHandoff.isHandoffURL(url))
    }

    func testAcceptsSessionNewWithoutQuery() {
        // Query parsing happens later — URL shape itself is still a handoff.
        let url = URL(string: "iclaw://session/new")!
        XCTAssertTrue(ShareHandoff.isHandoffURL(url))
    }

    func testRejectsNonSessionHost() {
        let url = URL(string: "iclaw://cron/run-due")!
        XCTAssertFalse(ShareHandoff.isHandoffURL(url))
    }

    func testRejectsDifferentPath() {
        let url = URL(string: "iclaw://session/edit")!
        XCTAssertFalse(ShareHandoff.isHandoffURL(url))
    }

    func testRejectsWrongScheme() {
        let url = URL(string: "https://session/new")!
        XCTAssertFalse(ShareHandoff.isHandoffURL(url))
    }

    func testRejectsAgentfileScheme() {
        let url = URL(string: "agentfile://\(UUID().uuidString)/img.jpg")!
        XCTAssertFalse(ShareHandoff.isHandoffURL(url))
    }

    // MARK: - sweepOrphans

    func testSweepOrphansDeletesOldDirectories() throws {
        let root = try makeTempStagingRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let freshDir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let staleDir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: freshDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staleDir, withIntermediateDirectories: true)

        // Backdate the stale directory's modification time by 48h.
        let backdated = Date().addingTimeInterval(-48 * 60 * 60)
        try FileManager.default.setAttributes(
            [.modificationDate: backdated],
            ofItemAtPath: staleDir.path
        )

        ShareHandoff.sweepOrphans(in: root, maxAge: 24 * 60 * 60, now: Date())

        XCTAssertTrue(FileManager.default.fileExists(atPath: freshDir.path),
                      "Fresh dir should survive the sweep")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleDir.path),
                       "Stale dir should be removed")
    }

    func testSweepOrphansNoopOnEmptyDir() throws {
        let root = try makeTempStagingRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // Should not throw, should not crash.
        ShareHandoff.sweepOrphans(in: root, maxAge: 60, now: Date())
    }

    func testSweepOrphansHandlesMissingRoot() {
        let nonexistent = FileManager.default.temporaryDirectory
            .appendingPathComponent("never-created-\(UUID().uuidString)")
        ShareHandoff.sweepOrphans(in: nonexistent, maxAge: 60, now: Date())
        // Just proving it doesn't crash.
    }

    // MARK: - Helpers

    private func makeTempStagingRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("iClawShareHandoffTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
