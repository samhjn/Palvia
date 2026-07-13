import SwiftUI
import SwiftData
import BackgroundTasks

private struct ProtectedDataUnavailableView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(L10n.Launch.protectedDataTitle)
                .font(.headline)
            Text(L10n.Launch.protectedDataMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}

@main
struct PalviaApp: App {
    @State private var modelContainer: ModelContainer?
    @State private var cronScheduler: CronScheduler?
    @State private var launchTaskManager: LaunchTaskManager?
    @State private var showMigrationResetAlert: Bool
    @State private var sessionRouter = PendingSessionRouter()
    private let bgTaskCoordinator: CronBGTaskCoordinator
    private let keepAliveManager = BackgroundKeepAliveManager()
    /// Store URL that needs to be deleted if the user confirms a migration reset.
    private static var pendingStoreURL: URL?
    /// Process-wide flag: SwiftUI re-creates the `App` struct on every body
    /// re-evaluation, so heavy/side-effecting launch work must not repeat or
    /// it cascades through SwiftData observation back into view invalidation.
    /// Not `private` so unit tests can observe via `@testable import Palvia`.
    internal static var didRunOneTimeLaunchTasks = false
    /// Captured once on first init so view body can decide whether to show
    /// the migration alert without re-reading static state across re-inits.
    internal static var initialMigrationFailed: Bool?
    /// Tally of how many times `init()` has executed in this process. SwiftUI
    /// is allowed to recreate the App struct, but a runaway count points at a
    /// re-entrancy storm (the launch-crash class). DEBUG-only trip-wire.
    internal static var initCallCount = 0
    /// Soft cap before we shout. Real apps see init re-runs in the single
    /// digits across normal scene-phase changes; anything above this is
    /// pathological.
    internal static let initCallCountWarnThreshold = 32

    init() {
        Self.installExceptionHandler()

        if let prior = CrashDiagnostics.consume() {
            print("[PalviaApp] Prior NSException recovered: \(prior.name) @ \(prior.source) — \(prior.reason) (\(prior.timestamp))")
        }

        let launchStore = PalviaModelContainer.resolveLaunchStore()
        let initialContainer = launchStore.container
        _modelContainer = State(initialValue: initialContainer)
        _launchTaskManager = State(initialValue: initialContainer.map { LaunchTaskManager(container: $0) })

        let migrationFailed = Self.captureMigrationFailure(from: launchStore)
        _showMigrationResetAlert = State(initialValue: migrationFailed)

        let coordinator = CronBGTaskCoordinator()
        coordinator.registerCronTask()
        bgTaskCoordinator = coordinator

        Self.runStoreReadyLaunchTasksIfNeeded(container: initialContainer)

        Self.initCallCount += 1
        #if DEBUG
        if Self.initCallCount == Self.initCallCountWarnThreshold {
            assertionFailure(
                "PalviaApp.init() ran \(Self.initCallCount) times — runaway re-entrancy. "
                + "Likely cause: a side effect inside init() / View body / Scene modifier "
                + "is mutating observed state and re-triggering body evaluation. See "
                + "scripts/lint_app_init_side_effects.sh."
            )
        }
        #endif
    }

    /// Run `work` exactly once per process. Extracted so unit tests can verify
    /// the latch behaviour without instantiating the App struct.
    static func runOneTimeLaunchTasksIfNeeded(_ work: () -> Void) {
        guard !didRunOneTimeLaunchTasks else { return }
        didRunOneTimeLaunchTasks = true
        work()
    }

    static func runOneTimeLaunchTasksIfNeeded(
        container: ModelContainer?,
        _ work: (ModelContainer) -> Void
    ) {
        guard let container else { return }
        runOneTimeLaunchTasksIfNeeded {
            work(container)
        }
    }

    private static func captureMigrationFailure(from launchStore: PalviaModelContainer.LaunchStoreState) -> Bool {
        guard launchStore.container != nil else { return false }
        if let captured = initialMigrationFailed {
            return captured
        }

        let failedURL = launchStore.failedStoreURL
        let migrationFailed = (failedURL != nil)
        initialMigrationFailed = migrationFailed
        if let failedURL {
            print("[PalviaApp] ModelContainer migration failed. Awaiting user confirmation before reset.")
            pendingStoreURL = failedURL
        }
        return migrationFailed
    }

    private static func runStoreReadyLaunchTasksIfNeeded(container: ModelContainer?) {
        // Heavy launch tasks: run exactly once per process. SwiftUI calls
        // `init()` on every body re-evaluation, and SwiftData writes from
        // these helpers invalidate observers, which can recurse back into
        // body evaluation and trip a Swift runtime trap on iOS 17.0.
        runOneTimeLaunchTasksIfNeeded(container: container) { modelContainer in
            #if DEBUG
            if PalviaModelContainer.shouldSeedMarkdown {
                seedMarkdownTestData(in: modelContainer)
            }
            if PalviaModelContainer.shouldSeedHeavyMarkdown {
                seedHeavyMarkdownTestData(in: modelContainer)
            }
            if PalviaModelContainer.shouldSimulateStreaming {
                seedStreamingTestData(in: modelContainer)
            }
            #endif
            resetStaleActiveSessions(in: modelContainer)
            // Publish the root-agent snapshot for the Share Extension and sweep
            // any abandoned share-staging directories from earlier sessions.
            refreshAgentSnapshot(in: modelContainer)
            ShareHandoff.sweepOrphans()
            // MetricKit catches Swift runtime traps and signal crashes that
            // bypass the NSException handler. Log any payloads delivered
            // since the previous launch, then register for future ones.
            for rec in CrashDiagnostics.consumeMetrics() {
                print("[PalviaApp] Prior MetricKit crash: signal=\(rec.signal ?? -1) "
                      + "exceptionType=\(rec.exceptionType ?? -1) "
                      + "termination=\(rec.terminationReason ?? "nil") "
                      + "build=\(rec.appVersion) os=\(rec.osVersion) at=\(rec.timestamp)")
            }
            CrashMetricsSubscriber.shared.start()
        }
    }

    #if DEBUG
    /// Test-only: reset the process-wide flags so a unit test can observe a
    /// fresh first-launch state. Mirrors the pattern in
    /// `CronBGTaskCoordinator.resetRegistrationStateForTesting()`.
    static func resetLaunchStateForTesting() {
        didRunOneTimeLaunchTasks = false
        initialMigrationFailed = nil
        initCallCount = 0
    }
    #endif

    /// Publish a read-only snapshot of root agents to the App Group so the
    /// Share Extension can list them without touching SwiftData.
    private static func refreshAgentSnapshot(in container: ModelContainer) {
        let context = ModelContext(container)
        AgentSnapshotExporter.export(context: context)
    }

    /// Delete the on-disk store files and terminate so the next launch starts fresh.
    private static func performStoreReset() {
        guard let storeURL = pendingStoreURL else { return }
        for url in PalviaModelContainer.storeFileURLs(for: storeURL) {
            try? FileManager.default.removeItem(at: url)
        }
        print("[PalviaApp] Store files deleted by user. Restarting.")
        Darwin.exit(0)
    }

    private static func installExceptionHandler() {
        NSSetUncaughtExceptionHandler { exception in
            // Persist `name`/`reason` so the next launch can log the trigger.
            // Running inside the uncaught-handler must stay short — the process
            // is about to terminate regardless of what we do here.
            CrashDiagnostics.record(
                source: "UncaughtExceptionHandler",
                name: exception.name.rawValue,
                reason: exception.reason ?? "nil"
            )
            print("""
            [PalviaApp] Uncaught NSException: \(exception.name.rawValue)
            Reason: \(exception.reason ?? "unknown")
            User Info: \(exception.userInfo ?? [:])
            Stack:
            \(exception.callStackSymbols.joined(separator: "\n"))
            """)
        }
    }

    /// Sessions stuck in `isActive` from a previous crash or force-quit can never
    /// have a live agent loop. Reset them so they don't block new interactions.
    private static func resetStaleActiveSessions(in container: ModelContainer) {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<Session>(
            predicate: #Predicate<Session> { $0.isActive == true }
        )
        guard let stale = SafeFetch.perform(context, descriptor), !stale.isEmpty else { return }
        for session in stale {
            session.isActive = false
        }
        try? context.save()
        print("[PalviaApp] Reset \(stale.count) stale active session(s).")
    }

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            appContent
                .onOpenURL { url in
                    handleDeepLink(url)
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)) { _ in
                    loadPersistentStoreIfPossible()
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                    loadPersistentStoreIfPossible()
                    cronScheduler?.rescheduleAll()
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                    cronScheduler?.scheduleBackgroundTask()
                }
                .alert(L10n.Migration.alertTitle, isPresented: $showMigrationResetAlert) {
                    Button(L10n.Migration.resetAndRestart, role: .destructive) {
                        Self.performStoreReset()
                    }
                    Button(L10n.Migration.exitApp, role: .cancel) {
                        Darwin.exit(0)
                    }
                } message: {
                    Text(L10n.Migration.alertMessage)
                }
        }
        .environment(sessionRouter)
        .environment(\.keepAliveManager, keepAliveManager)
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                cronScheduler?.pause()
                keepAliveManager.activate()
            case .active:
                loadPersistentStoreIfPossible()
                cronScheduler?.resume()
                keepAliveManager.onReturnToForeground()
                // Pick up any share-extension handoffs that couldn't open
                // the host app via deep link (iOS 18 disabled the legacy
                // openURL: responder-chain trick).
                if let modelContainer {
                    ShareHandoff.processPending(modelContainer: modelContainer, router: sessionRouter)
                }
            default:
                break
            }
        }
    }

    @ViewBuilder
    private var appContent: some View {
        if let modelContainer, let launchTaskManager {
            ContentView()
                .modelContainer(modelContainer)
                .launchTaskOverlay(manager: launchTaskManager)
                .onAppear {
                    launchTaskManager.runAll()
                    startCronScheduler()
                    ShareHandoff.processPending(modelContainer: modelContainer, router: sessionRouter)
                }
        } else {
            ProtectedDataUnavailableView()
                .onAppear {
                    loadPersistentStoreIfPossible()
                }
        }
    }

    @MainActor
    private func loadPersistentStoreIfPossible() {
        guard modelContainer == nil else { return }
        let launchStore = PalviaModelContainer.resolveLaunchStore()
        guard let container = launchStore.container else { return }

        modelContainer = container
        launchTaskManager = LaunchTaskManager(container: container)
        showMigrationResetAlert = Self.captureMigrationFailure(from: launchStore)

        Self.runStoreReadyLaunchTasksIfNeeded(container: container)
    }

    private func startCronScheduler() {
        guard cronScheduler == nil else { return }
        guard let modelContainer else { return }
        let scheduler = CronScheduler(modelContainer: modelContainer)
        scheduler.keepAliveManager = keepAliveManager
        scheduler.start()
        cronScheduler = scheduler
        bgTaskCoordinator.scheduler = scheduler
        ChatViewModel.keepAliveManager = keepAliveManager
    }

    // MARK: - Deep Link Handling

    /// Handles URL schemes:
    /// - `palvia://cron/trigger/{jobId}` / `palvia://cron/run-due` — cron triggers
    /// - `palvia://session/new?agentId=...&handoffId=...` — Share Extension handoff
    /// - `agentfile://<agentId>/<filename>` — in-app file preview
    private func handleDeepLink(_ url: URL) {
        if url.scheme == "agentfile" {
            handleAgentFileLink(url)
            return
        }

        guard ["iclaw", "palvia"].contains((url.scheme ?? "").lowercased()) else { return }

        if ShareHandoff.isHandoffURL(url) {
            Task { @MainActor in
                loadPersistentStoreIfPossible()
                guard let modelContainer else { return }
                ShareHandoff.apply(url: url, modelContainer: modelContainer, router: sessionRouter)
            }
            return
        }

        let pathComponents = url.pathComponents.filter { $0 != "/" }
        let host = url.host ?? ""

        // Normalize: palvia://cron/trigger/{id} or palvia://cron/run-due
        let fullPath = ([host] + pathComponents).joined(separator: "/")

        if fullPath.hasPrefix("cron/trigger/") {
            let jobIdStr = fullPath.replacingOccurrences(of: "cron/trigger/", with: "")
            if let jobId = UUID(uuidString: jobIdStr) {
                triggerCronJob(id: jobId)
            }
        } else if fullPath == "cron/run-due" {
            triggerAllDueJobs()
        }
    }

    private static let htmlExtensions: Set<String> = ["html", "htm"]

    private func handleAgentFileLink(_ url: URL) {
        let ref = url.absoluteString
        guard let (agentId, filename) = AgentFileManager.parseFileReference(ref) else { return }
        let ext = (filename as NSString).pathExtension.lowercased()
        let imageExts: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tiff", "tif"]

        if imageExts.contains(ext) {
            if let data = AgentFileManager.shared.loadImageData(from: ref),
               let image = UIImage(data: data) {
                ImagePreviewCoordinator.shared.show(image)
            }
        } else if Self.htmlExtensions.contains(ext) {
            let fileURL = AgentFileManager.shared.fileURL(agentId: agentId, name: filename)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
            Task { @MainActor in
                await BrowserService.shared.loadAgentFile(fileURL: fileURL, agentId: agentId)
            }
        } else if TextFilePreviewCoordinator.textExtensions.contains(ext) {
            if let data = try? AgentFileManager.shared.readFile(agentId: agentId, name: filename),
               let text = String(data: data, encoding: .utf8) {
                TextFilePreviewCoordinator.shared.show(content: text, filename: filename)
            }
        } else {
            let fileURL = AgentFileManager.shared.fileURL(agentId: agentId, name: filename)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
            let activityVC = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let rootVC = windowScene.windows.first?.rootViewController {
                rootVC.present(activityVC, animated: true)
            }
        }
    }

    private func triggerCronJob(id: UUID) {
        Task { @MainActor in
            await cronScheduler?.runManualJob(jobId: id)
        }
    }

    private func triggerAllDueJobs() {
        Task { @MainActor in
            await cronScheduler?.runDueJobsNow()
        }
    }
}
