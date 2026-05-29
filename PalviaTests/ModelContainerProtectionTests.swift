import XCTest
import SwiftData
@testable import Palvia

/// Regression coverage for the iOS-18 background-launch crash where the
/// SwiftData store sat at the iOS default `.complete` protection class,
/// and a Shortcuts automation triggered before the user unlocked the
/// device deadlocked `pread()` on the encrypted WAL — RunningBoard then
/// killed the process with `0xdead10cc`.
///
/// `PalviaModelContainer.applyStoreProtection(at:)` lowers the protection
/// to `.completeUntilFirstUserAuthentication` for the `.sqlite`,
/// `.sqlite-wal`, and `.sqlite-shm` files (and their parent directory) so
/// background-launched code can still read the store after the device has
/// been unlocked at least once since boot.
final class ModelContainerProtectionTests: XCTestCase {

    private var tempDir: URL!
    private enum TestError: Error {
        case persistentStoreOpened
        case inMemoryStoreOpened
    }

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PalviaProtection-\(UUID().uuidString)", isDirectory: true)
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

        PalviaModelContainer.applyStoreProtection(at: storeURL)

        for url in [storeURL, walURL, shmURL] {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            if let protection = attrs[.protectionKey] as? FileProtectionType {
                XCTAssertEqual(
                    protection,
                    PalviaModelContainer.storeProtectionLevel,
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
        PalviaModelContainer.applyStoreProtection(at: storeURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path))
    }

    /// The configured class must be at most `.completeUntilFirstUserAuthentication`.
    /// `.complete` is what triggered the crash; anything stricter would
    /// re-introduce the deadlock under lock.
    func testProtectionLevelIsBackgroundLaunchSafe() {
        let level = PalviaModelContainer.storeProtectionLevel
        XCTAssertTrue(
            level == .completeUntilFirstUserAuthentication
            || level == .completeUnlessOpen
            || level == FileProtectionType.none,
            "Protection level \(level.rawValue) is not safe for background launches "
            + "after first unlock — would re-introduce 0xdead10cc."
        )
    }

    /// Reproduces the crash shape from the stack trace: the app process is
    /// launched while protected data is unavailable, before AppIntent.perform()
    /// can run its own guard. The launch resolver must not open SQLite or even
    /// run the protection pass, because either path can touch encrypted store
    /// files before first unlock.
    func testResolveStoreDoesNotTouchSQLiteWhenProtectedDataUnavailable() {
        var didOpenPersistentStore = false
        var didOpenInMemoryStore = false
        var protectedURLs: [URL] = []

        let state = PalviaModelContainer.resolveStore(
            protectedDataAvailable: false,
            openPersistentStore: { _ in
                didOpenPersistentStore = true
                throw TestError.persistentStoreOpened
            },
            openInMemoryStore: {
                didOpenInMemoryStore = true
                throw TestError.inMemoryStoreOpened
            },
            applyProtection: { protectedURLs.append($0) }
        )

        guard case .protectedDataUnavailable = state else {
            return XCTFail("Expected protected-data-unavailable state, got \(state)")
        }
        XCTAssertFalse(didOpenPersistentStore, "Must not open the SQLite store before protected data is available")
        XCTAssertFalse(didOpenInMemoryStore, "Must not poison this process with a fallback container before first unlock")
        XCTAssertTrue(protectedURLs.isEmpty, "Must not touch store paths before protected data is available")
    }

    func testResolveStoreAppliesProtectionAroundPersistentOpenWhenDataAvailable() throws {
        var didOpenPersistentStore = false
        var didOpenInMemoryStore = false
        var protectedURLs: [URL] = []

        let state = PalviaModelContainer.resolveStore(
            protectedDataAvailable: true,
            openPersistentStore: { _ in
                didOpenPersistentStore = true
                return try Self.makeInMemoryContainer()
            },
            openInMemoryStore: {
                didOpenInMemoryStore = true
                return try Self.makeInMemoryContainer()
            },
            applyProtection: { protectedURLs.append($0) }
        )

        guard case .persistent = state else {
            return XCTFail("Expected persistent container state, got \(state)")
        }
        XCTAssertTrue(didOpenPersistentStore)
        XCTAssertFalse(didOpenInMemoryStore)
        XCTAssertEqual(protectedURLs.count, 2, "Protection should run before and after opening the store")
        XCTAssertEqual(protectedURLs.first, protectedURLs.last)
    }

    func testStoreFileURLsUseSQLiteSidecarNames() {
        let storeURL = tempDir.appendingPathComponent("store.sqlite")
        let urls = PalviaModelContainer.storeFileURLs(for: storeURL)
        XCTAssertEqual(urls.map(\.lastPathComponent), [
            "store.sqlite",
            "store.sqlite-wal",
            "store.sqlite-shm",
        ])
    }

    private static func makeInMemoryContainer() throws -> ModelContainer {
        let config = ModelConfiguration(schema: PalviaModelContainer.schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: PalviaModelContainer.schema, configurations: [config])
    }
}
