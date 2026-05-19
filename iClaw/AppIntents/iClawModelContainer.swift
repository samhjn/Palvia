import Foundation
import SwiftData

/// Single source of truth for the app's SwiftData `ModelContainer`.
///
/// Both `iClawApp` (main process, foreground) and the App Intents
/// (background execution triggered by Shortcuts automations) resolve the
/// same container via `shared`, so cron writes from either path observe
/// identical state without a second store file.
///
/// `static let` is initialized exactly once with `dispatch_once` semantics,
/// so concurrent readers see a consistent instance.
enum iClawModelContainer {
    static let schema = Schema([
        Agent.self,
        AgentConfig.self,
        Session.self,
        Message.self,
        LLMProvider.self,
        CodeSnippet.self,
        CronJob.self,
        Skill.self,
        InstalledSkill.self,
        SessionEmbedding.self,
    ])

    /// When the on-disk store fails to open (typically a SwiftData migration
    /// error), this records the URL of the failed store so `iClawApp` can
    /// offer the user a reset-and-restart. `nil` on success.
    private(set) static var migrationFailedStoreURL: URL?

    /// Data-protection class applied to the SQLite store + WAL + SHM. We use
    /// `.completeUntilFirstUserAuthentication` instead of the iOS default so
    /// that a Shortcuts automation triggered on a locked device (after the
    /// user has already unlocked once since boot — the common case) can read
    /// the store without blocking on encrypted IO.
    ///
    /// Without this, iOS-18 background launches via App Intents block in
    /// `pread()` on the WAL header, the launch watchdog fires, and
    /// RunningBoard kills the process with `0xdead10cc`.
    static let storeProtectionLevel: FileProtectionType = .completeUntilFirstUserAuthentication

    static let isUITesting = ProcessInfo.processInfo.arguments.contains("--uitesting")
    static let shouldSeedMarkdown = ProcessInfo.processInfo.arguments.contains("--uitesting-seed-markdown")
    static let shouldSimulateStreaming = ProcessInfo.processInfo.arguments.contains("--uitesting-simulate-streaming")

    static let shared: ModelContainer = {
        if isUITesting {
            let memoryConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            do {
                return try ModelContainer(for: schema, configurations: [memoryConfig])
            } catch {
                fatalError("Failed to create in-memory ModelContainer for UI testing: \(error)")
            }
        }

        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        // Lower protection on the store directory before opening, so any
        // sidecar files SwiftData creates (.sqlite-wal, .sqlite-shm) inherit
        // the relaxed level.
        applyStoreProtection(at: config.url)

        do {
            let container = try ModelContainer(for: schema, configurations: [config])
            // Re-apply after open: if the store / WAL / SHM were created
            // during `ModelContainer.init`, they took the directory's level
            // at that instant — set it explicitly per-file to be sure.
            applyStoreProtection(at: config.url)
            return container
        } catch {
            print("[iClawModelContainer] Primary container construction failed: \(error). Falling back to in-memory.")
            migrationFailedStoreURL = config.url
            let fallback = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            do {
                return try ModelContainer(for: schema, configurations: [fallback])
            } catch {
                fatalError("Failed to create in-memory ModelContainer: \(error)")
            }
        }
    }()

    /// Apply the chosen protection class to the store directory and to the
    /// `.sqlite` / `.sqlite-wal` / `.sqlite-shm` files if they exist. Missing
    /// files are skipped silently — this runs both before and after opening
    /// the container, and which files exist depends on whether SwiftData has
    /// already initialized the WAL.
    ///
    /// Uses `FileManager.setAttributes(_:ofItemAtPath:)` because
    /// `URLResourceValues.fileProtection` is read-only — there is no URL-based
    /// setter for the protection class.
    static func applyStoreProtection(at storeURL: URL) {
        let level = storeProtectionLevel
        let candidates: [URL] = [
            storeURL.deletingLastPathComponent(),
            storeURL,
            URL(fileURLWithPath: storeURL.path + "-wal"),
            URL(fileURLWithPath: storeURL.path + "-shm"),
        ]
        for url in candidates {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                try FileManager.default.setAttributes(
                    [.protectionKey: level],
                    ofItemAtPath: url.path
                )
            } catch {
                print("[iClawModelContainer] Failed to set protection on \(url.lastPathComponent): \(error)")
            }
        }
    }
}
