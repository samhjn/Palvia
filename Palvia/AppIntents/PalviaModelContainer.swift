import Foundation
import SwiftData

/// Single source of truth for the app's SwiftData `ModelContainer`.
///
/// Both `PalviaApp` (main process, foreground) and the App Intents
/// (background execution triggered by Shortcuts automations) resolve the
/// same container via `shared`, so cron writes from either path observe
/// identical state without a second store file.
///
/// `static let` is initialized exactly once with `dispatch_once` semantics,
/// so concurrent readers see a consistent instance.
enum PalviaModelContainer {
    enum LaunchStoreState {
        case persistent(ModelContainer)
        case migrationFallback(ModelContainer, failedStoreURL: URL)
        case protectedDataUnavailable

        var container: ModelContainer? {
            switch self {
            case .persistent(let container),
                 .migrationFallback(let container, _):
                return container
            case .protectedDataUnavailable:
                return nil
            }
        }

        var failedStoreURL: URL? {
            switch self {
            case .migrationFallback(_, let url):
                return url
            case .persistent, .protectedDataUnavailable:
                return nil
            }
        }
    }

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
    /// error), this records the URL of the failed store so `PalviaApp` can
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
    static let shouldSeedHeavyMarkdown = ProcessInfo.processInfo.arguments.contains("--uitesting-seed-heavy-markdown")
    static let shouldSeedLargeLuaPreview = ProcessInfo.processInfo.arguments.contains("--uitesting-seed-large-lua-preview")
    static let shouldSimulateStreaming = ProcessInfo.processInfo.arguments.contains("--uitesting-simulate-streaming")

    static let shared: ModelContainer = {
        if isUITesting {
            do {
                return try makeInMemoryContainer()
            } catch {
                fatalError("Failed to create in-memory ModelContainer for UI testing: \(error)")
            }
        }

        switch resolveStore(protectedDataAvailable: true) {
        case .persistent(let container):
            return container
        case .migrationFallback(let container, let failedURL):
            migrationFailedStoreURL = failedURL
            return container
        case .protectedDataUnavailable:
            fatalError("PalviaModelContainer.shared requested while protected data is unavailable")
        }
    }()

    @MainActor
    static func resolveLaunchStore() -> LaunchStoreState {
        if isUITesting {
            return .persistent(shared)
        }
        guard ProtectedDataAvailability.isAvailable else {
            return .protectedDataUnavailable
        }

        let container = shared
        if let failedURL = migrationFailedStoreURL {
            return .migrationFallback(container, failedStoreURL: failedURL)
        }
        return .persistent(container)
    }

    static func resolveStore(
        protectedDataAvailable: Bool,
        openPersistentStore: (ModelConfiguration) throws -> ModelContainer = openPersistentStore(configuration:),
        openInMemoryStore: () throws -> ModelContainer = makeInMemoryContainer,
        applyProtection: (URL) -> Void = applyStoreProtection(at:)
    ) -> LaunchStoreState {
        guard protectedDataAvailable else {
            return .protectedDataUnavailable
        }

        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        // Lower protection on the store directory before opening, so any
        // sidecar files SwiftData creates (.sqlite-wal, .sqlite-shm) inherit
        // the relaxed level.
        applyProtection(config.url)

        do {
            let container = try openPersistentStore(config)
            // Re-apply after open: if the store / WAL / SHM were created
            // during `ModelContainer.init`, they took the directory's level
            // at that instant — set it explicitly per-file to be sure.
            applyProtection(config.url)
            return .persistent(container)
        } catch {
            print("[PalviaModelContainer] Primary container construction failed: \(error). Falling back to in-memory.")
            do {
                let container = try openInMemoryStore()
                return .migrationFallback(container, failedStoreURL: config.url)
            } catch {
                fatalError("Failed to create in-memory ModelContainer: \(error)")
            }
        }
    }

    private static func openPersistentStore(configuration: ModelConfiguration) throws -> ModelContainer {
        try ModelContainer(for: schema, configurations: [configuration])
    }

    private static func makeInMemoryContainer() throws -> ModelContainer {
        let fallback = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [fallback])
    }

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
        let candidates = [storeURL.deletingLastPathComponent()] + storeFileURLs(for: storeURL)
        for url in candidates {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                try FileManager.default.setAttributes(
                    [.protectionKey: level],
                    ofItemAtPath: url.path
                )
            } catch {
                print("[PalviaModelContainer] Failed to set protection on \(url.lastPathComponent): \(error)")
            }
        }
    }

    static func storeFileURLs(for storeURL: URL) -> [URL] {
        [
            storeURL,
            URL(fileURLWithPath: storeURL.path + "-wal"),
            URL(fileURLWithPath: storeURL.path + "-shm"),
        ]
    }
}
