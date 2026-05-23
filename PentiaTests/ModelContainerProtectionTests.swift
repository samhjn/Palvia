import XCTest
@testable import iClaw

/// Regression coverage for the iOS-18 background-launch crash where the
/// SwiftData store sat at the iOS default `.complete` protection class,
/// and a Shortcuts automation triggered before the user unlocked the
/// device deadlocked `pread()` on the encrypted WAL — RunningBoard then
/// killed the process with `0xdead10cc`.
///
/// `iClawModelContainer.applyStoreProtection(at:)` lowers the protection
/// to `.completeUntilFirstUserAuthentication` for the `.sqlite`,
/// `.sqlite-wal`, and `.sqlite-shm` files (and their parent directory) so
/// background-launched code can still read the store after the device has
/// been unlocked at least once since boot.
final class ModelContainerProtectionTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("iClawProtection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        super.tearDown()
    }

    /// Files present at call time must end up at the configured protection
    /// level. The simulator does not enforce file protection at the
    /// filesystem layer, so `attributesOfItem` may return `nil` for the
    /// protection key — in that case we skip the assertion rather than fail
    /// for a host-environment quirk.
    func testApplyStoreProtectionTagsAllStoreFiles() throws {
        let storeURL = tempDir.appendingPathComponent("store.sqlite")
        let walURL = URL(fileURLWithPath: storeURL.path + "-wal")
        let shmURL = URL(fileURLWithPath: storeURL.path + "-shm")
        for url in [storeURL, walURL, shmURL] {
            XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data()))
        }

        iClawModelContainer.applyStoreProtection(at: storeURL)

        for url in [storeURL, walURL, shmURL] {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            if let protection = attrs[.protectionKey] as? FileProtectionType {
                XCTAssertEqual(
                    protection,
                    iClawModelContainer.storeProtectionLevel,
                    "\(url.lastPathComponent) protection should be downgraded"
                )
            }
        }
    }

    /// Helper must tolerate missing sidecars — first-launch shape, where the
    /// `.sqlite` exists but `-wal` / `-shm` haven't been created yet.
    func testApplyStoreProtectionSkipsMissingFiles() {
        let storeURL = tempDir.appendingPathComponent("only-main.sqlite")
        XCTAssertTrue(FileManager.default.createFile(atPath: storeURL.path, contents: Data()))

        // No -wal / -shm. Must not throw or crash.
        iClawModelContainer.applyStoreProtection(at: storeURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path))
    }

    /// The configured class must be at most `.completeUntilFirstUserAuthentication`.
    /// `.complete` is what triggered the crash; anything stricter would
    /// re-introduce the deadlock under lock.
    func testProtectionLevelIsBackgroundLaunchSafe() {
        let level = iClawModelContainer.storeProtectionLevel
        XCTAssertTrue(
            level == .completeUntilFirstUserAuthentication
            || level == .completeUnlessOpen
            || level == FileProtectionType.none,
            "Protection level \(level.rawValue) is not safe for background launches "
            + "after first unlock — would re-introduce 0xdead10cc."
        )
    }
}
