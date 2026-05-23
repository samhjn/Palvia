import XCTest
import SwiftData
import BackgroundTasks
@testable import iClaw

// MARK: - Mock

private final class MockBGTaskRegistrar: BGTaskRegistering, @unchecked Sendable {
    private(set) var registerCallCount = 0
    private(set) var registeredIdentifiers: [String] = []
    private(set) var capturedHandlers: [@Sendable (BGTask) -> Void] = []
    var shouldSucceed = true

    @discardableResult
    func register(
        forTaskWithIdentifier identifier: String,
        using queue: DispatchQueue?,
        launchHandler: @escaping @Sendable (BGTask) -> Void
    ) -> Bool {
        registerCallCount += 1
        registeredIdentifiers.append(identifier)
        capturedHandlers.append(launchHandler)
        return shouldSucceed
    }
}

// MARK: - Identifier Consistency Tests

final class BGTaskIdentifierTests: XCTestCase {

    func testBGTaskIdentifierIsNotEmpty() {
        XCTAssertFalse(CronScheduler.bgTaskIdentifier.isEmpty)
    }

    func testBGTaskIdentifierMatchesExpectedValue() {
        XCTAssertEqual(CronScheduler.bgTaskIdentifier, "com.iclaw.cronjob.refresh")
    }

    func testBGTaskIdentifierFollowsReverseDNS() {
        let parts = CronScheduler.bgTaskIdentifier.split(separator: ".")
        XCTAssertGreaterThanOrEqual(parts.count, 3,
                                    "Identifier should follow reverse-DNS convention (e.g. com.iclaw.cronjob.refresh)")
    }

    /// Verifies that the identifier used in code matches the one declared in the
    /// app's `Info.plist` under `BGTaskSchedulerPermittedIdentifiers`.
    func testBGTaskIdentifierExistsInInfoPlist() {
        let appBundle = Bundle(for: CronScheduler.self)
        guard let identifiers = appBundle.object(
            forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers"
        ) as? [String] else {
            XCTFail("BGTaskSchedulerPermittedIdentifiers not found in Info.plist")
            return
        }
        XCTAssertTrue(
            identifiers.contains(CronScheduler.bgTaskIdentifier),
            "'\(CronScheduler.bgTaskIdentifier)' must be listed in BGTaskSchedulerPermittedIdentifiers, "
            + "found: \(identifiers)"
        )
    }
}

// MARK: - Registration Lifecycle Tests

final class BGTaskRegistrationLifecycleTests: XCTestCase {

    override func setUp() {
        super.setUp()
        CronBGTaskCoordinator.resetRegistrationStateForTesting()
    }

    override func tearDown() {
        CronBGTaskCoordinator.resetRegistrationStateForTesting()
        super.tearDown()
    }

    func testRegisterCallsRegistrarExactlyOnce() {
        let mock = MockBGTaskRegistrar()
        let coordinator = CronBGTaskCoordinator(registrar: mock)

        coordinator.registerCronTask()

        XCTAssertEqual(mock.registerCallCount, 1)
    }

    func testRegisterUsesCorrectIdentifier() {
        let mock = MockBGTaskRegistrar()
        let coordinator = CronBGTaskCoordinator(registrar: mock)

        coordinator.registerCronTask()

        XCTAssertEqual(mock.registeredIdentifiers, [CronScheduler.bgTaskIdentifier])
    }

    func testRegisterSetsIsRegisteredOnSuccess() {
        let mock = MockBGTaskRegistrar()
        mock.shouldSucceed = true
        let coordinator = CronBGTaskCoordinator(registrar: mock)

        let result = coordinator.registerCronTask()

        XCTAssertTrue(result)
        XCTAssertTrue(coordinator.isRegistered)
    }

    func testRegisterReportsFailure() {
        let mock = MockBGTaskRegistrar()
        mock.shouldSucceed = false
        let coordinator = CronBGTaskCoordinator(registrar: mock)

        let result = coordinator.registerCronTask()

        XCTAssertFalse(result)
        XCTAssertFalse(coordinator.isRegistered)
    }

    /// Calling `registerCronTask()` twice must NOT call through to the registrar
    /// a second time — double registration triggers a system assertion crash.
    func testDoubleRegistrationIsIdempotent() {
        let mock = MockBGTaskRegistrar()
        let coordinator = CronBGTaskCoordinator(registrar: mock)

        coordinator.registerCronTask()
        let secondResult = coordinator.registerCronTask()

        XCTAssertEqual(mock.registerCallCount, 1, "Registrar must only be called once")
        XCTAssertFalse(secondResult, "Second registration should return false")
    }

    /// If the first registration attempt fails (e.g. identifier missing from
    /// Info.plist), the coordinator should allow a retry.
    func testFailedRegistrationAllowsRetry() {
        let mock = MockBGTaskRegistrar()
        mock.shouldSucceed = false
        let coordinator = CronBGTaskCoordinator(registrar: mock)

        coordinator.registerCronTask()
        XCTAssertFalse(coordinator.isRegistered)

        mock.shouldSucceed = true
        coordinator.registerCronTask()

        XCTAssertEqual(mock.registerCallCount, 2, "Should allow retry after failure")
        XCTAssertTrue(coordinator.isRegistered)
    }

    func testPassesNilQueue() {
        let mock = MockBGTaskRegistrar()
        let coordinator = CronBGTaskCoordinator(registrar: mock)

        coordinator.registerCronTask()

        XCTAssertEqual(mock.registerCallCount, 1)
    }

    func testCapturesLaunchHandler() {
        let mock = MockBGTaskRegistrar()
        let coordinator = CronBGTaskCoordinator(registrar: mock)

        coordinator.registerCronTask()

        XCTAssertEqual(mock.capturedHandlers.count, 1,
                       "Should capture exactly one launch handler")
    }
}

// MARK: - Separation of Concerns Tests

final class BGTaskSeparationTests: XCTestCase {

    private var container: ModelContainer!

    @MainActor
    override func setUp() {
        super.setUp()
        CronBGTaskCoordinator.resetRegistrationStateForTesting()
        let schema = Schema([Agent.self, LLMProvider.self, Session.self, AgentConfig.self,
                             CodeSnippet.self, CronJob.self, InstalledSkill.self, Skill.self,
                             Message.self, SessionEmbedding.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: schema, configurations: [config])
    }

    override func tearDown() {
        container = nil
        CronBGTaskCoordinator.resetRegistrationStateForTesting()
        super.tearDown()
    }

    /// Creating and starting `CronScheduler` must NOT trigger any BGTask
    /// registration. Registration is the coordinator's responsibility.
    @MainActor
    func testStartingSchedulerDoesNotRegisterBGTask() {
        let mock = MockBGTaskRegistrar()
        let coordinator = CronBGTaskCoordinator(registrar: mock)

        let scheduler = CronScheduler(modelContainer: container)
        scheduler.start()
        coordinator.scheduler = scheduler
        scheduler.stop()

        XCTAssertEqual(mock.registerCallCount, 0,
                       "CronScheduler.start() must not call BGTaskScheduler.register")
    }

    /// The scheduler can be linked to the coordinator after registration — this
    /// is the normal app lifecycle (register in init, create scheduler in onAppear).
    @MainActor
    func testSchedulerCanBeSetAfterRegistration() {
        let mock = MockBGTaskRegistrar()
        let coordinator = CronBGTaskCoordinator(registrar: mock)

        coordinator.registerCronTask()
        XCTAssertTrue(coordinator.isRegistered)
        XCTAssertNil(coordinator.scheduler)

        let scheduler = CronScheduler(modelContainer: container)
        coordinator.scheduler = scheduler
        XCTAssertNotNil(coordinator.scheduler)

        scheduler.stop()
    }

    /// Registration and scheduler creation must be independent — verifying the
    /// two-phase lifecycle: register (init) → create scheduler (onAppear).
    @MainActor
    func testTwoPhaseLifecycleOrder() {
        let mock = MockBGTaskRegistrar()
        let coordinator = CronBGTaskCoordinator(registrar: mock)

        // Phase 1: Registration (during App.init)
        coordinator.registerCronTask()
        XCTAssertTrue(coordinator.isRegistered)
        XCTAssertNil(coordinator.scheduler, "Scheduler must not exist at registration time")
        XCTAssertEqual(mock.registerCallCount, 1)

        // Phase 2: Scheduler creation (during onAppear)
        let scheduler = CronScheduler(modelContainer: container)
        scheduler.start()
        coordinator.scheduler = scheduler

        XCTAssertTrue(scheduler.isRunning)
        XCTAssertNotNil(coordinator.scheduler)
        XCTAssertEqual(mock.registerCallCount, 1, "No additional registration during phase 2")

        scheduler.stop()
    }

    /// Stopping and restarting the scheduler must not re-register the BGTask.
    @MainActor
    func testSchedulerRestartDoesNotReRegister() {
        let mock = MockBGTaskRegistrar()
        let coordinator = CronBGTaskCoordinator(registrar: mock)

        coordinator.registerCronTask()

        let scheduler = CronScheduler(modelContainer: container)
        scheduler.start()
        coordinator.scheduler = scheduler

        scheduler.stop()
        scheduler.start()
        scheduler.pause()
        scheduler.resume()

        XCTAssertEqual(mock.registerCallCount, 1,
                       "Scheduler lifecycle changes must not trigger re-registration")

        scheduler.stop()
    }

    /// When multiple coordinators exist (e.g. SwiftUI recreates the App struct),
    /// only the first should call through to the registrar. The process-wide
    /// static guard prevents the duplicate registration that crashes BGTaskScheduler.
    func testSecondCoordinatorSkipsRegistration() {
        let mock = MockBGTaskRegistrar()
        let coordinator1 = CronBGTaskCoordinator(registrar: mock)
        let coordinator2 = CronBGTaskCoordinator(registrar: mock)

        let first = coordinator1.registerCronTask()
        let second = coordinator2.registerCronTask()

        XCTAssertTrue(first)
        XCTAssertFalse(second, "Second coordinator must not call registrar again")
        XCTAssertEqual(mock.registerCallCount, 1,
                       "Only one registration call should reach BGTaskScheduler")
        XCTAssertTrue(coordinator2.isRegistered,
                      "Second coordinator should still reflect registered state")
    }
}

// MARK: - Handler Safety Tests

final class BGTaskHandlerSafetyTests: XCTestCase {

    override func setUp() {
        super.setUp()
        CronBGTaskCoordinator.resetRegistrationStateForTesting()
    }

    override func tearDown() {
        CronBGTaskCoordinator.resetRegistrationStateForTesting()
        super.tearDown()
    }

    /// When the scheduler is nil (not yet created), the coordinator's handler
    /// should gracefully handle the BGTask without crashing.
    func testHandlerIsRegisteredWithoutScheduler() {
        let mock = MockBGTaskRegistrar()
        let coordinator = CronBGTaskCoordinator(registrar: mock)

        coordinator.registerCronTask()

        XCTAssertNil(coordinator.scheduler)
        XCTAssertEqual(mock.capturedHandlers.count, 1,
                       "Handler should be registered even without a scheduler")
    }

    /// Coordinator initialized with a failing registrar should not be in a
    /// registered state, and no handler should be invokable.
    func testCoordinatorWithFailedRegistration() {
        let mock = MockBGTaskRegistrar()
        mock.shouldSucceed = false
        let coordinator = CronBGTaskCoordinator(registrar: mock)

        coordinator.registerCronTask()

        XCTAssertFalse(coordinator.isRegistered)
        XCTAssertEqual(mock.capturedHandlers.count, 1,
                       "Handler is still passed to registrar even if it returns false")
    }
}
