import XCTest
import SwiftData
@testable import Pentia

/// Stress tests attempting to reproduce the SwiftData ModelContext crash:
///
///   ___BUG_IN_CLIENT_OF_LIBMALLOC_POINTER_BEING_FREED_WAS_NOT_ALLOCATED
///   in _NativeDictionary.copy() → ModelContext._registerObject
///
/// The crash occurs when `session.messages` (a lazy SwiftData relationship) is
/// accessed after messages have been deleted and the ModelContext's internal
/// registration dictionary encounters freed backing data during COW copy.
///
/// These tests use a SQLite-backed store (not in-memory) and enable MallocScribble
/// to maximize the chance of detecting use-after-free conditions.

private let testSchema = Schema([
    Agent.self, LLMProvider.self, Session.self, AgentConfig.self,
    CodeSnippet.self, CronJob.self, InstalledSkill.self, Skill.self,
    Message.self, SessionEmbedding.self
])

// MARK: - Helpers

private func makeSQLiteContainer() -> (ModelContainer, URL) {
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("iClawCrashTest_\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    let storeURL = tmpDir.appendingPathComponent("test.store")
    let config = ModelConfiguration(url: storeURL)
    let container = try! ModelContainer(for: testSchema, configurations: [config])
    return (container, tmpDir)
}

private func cleanup(tmpDir: URL) {
    try? FileManager.default.removeItem(at: tmpDir)
}

// MARK: - Test 1: Direct delete + relationship re-access on SQLite

@MainActor
final class ModelContextRegisterObjectCrashTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        setenv("MallocScribble", "1", 1)
        (container, tmpDir) = makeSQLiteContainer()
        context = ModelContext(container)
    }

    override func tearDown() {
        context = nil
        container = nil
        if let tmpDir { cleanup(tmpDir: tmpDir) }
        tmpDir = nil
        super.tearDown()
    }

    /// Stress the exact crash path: delete messages → save → re-access
    /// `session.messages` which triggers ModelContext._registerObject internally.
    ///
    /// With MallocScribble enabled, if the freed backing data is reused, the
    /// scribbled 0x55 bytes will cause the pointer check to fail.
    func testDeleteAndReaccessRelationshipRapidly() {
        let session = Session(title: "CrashTest")
        context.insert(session)

        // Seed with many messages to build up the internal registration dictionary
        var liveMessages: [Message] = []
        for i in 0..<30 {
            let msg = Message(role: i % 2 == 0 ? .user : .assistant,
                              content: "seed message \(i)")
            context.insert(msg)
            session.messages.append(msg)
            liveMessages.append(msg)
        }
        try! context.save()

        // Force initial relationship resolution
        _ = session.messages.count

        for round in 0..<200 {
            // Delete 1-3 random messages
            let deleteCount = min(Int.random(in: 1...3), liveMessages.count)
            guard deleteCount > 0, !liveMessages.isEmpty else { break }

            for _ in 0..<deleteCount {
                let idx = Int.random(in: 0..<liveMessages.count)
                let victim = liveMessages.remove(at: idx)
                session.messages.removeAll { $0.id == victim.id }
                context.delete(victim)
            }
            try! context.save()

            // Insert replacements (same count) to churn the allocator
            for j in 0..<deleteCount {
                let msg = Message(role: .assistant,
                                  content: "round \(round) replacement \(j)")
                context.insert(msg)
                session.messages.append(msg)
                liveMessages.append(msg)
            }
            try! context.save()

            // Access the relationship — this triggers the crash path:
            // session.messages.getter → _KKMDBackingData._modelsForIDs
            // → ModelContext._model(with:) → ModelContext._registerObject
            let fetchedCount = session.messages.count
            XCTAssertEqual(fetchedCount, liveMessages.count,
                "Round \(round): relationship count mismatch")

            // Also access individual message properties to force full fault resolution
            for msg in session.messages {
                _ = msg.content
            }
        }
    }

    /// Variant: delete ALL messages at once then re-access, creating maximum
    /// churn in the registration dictionary.
    func testBulkDeleteAndReinsert() {
        let session = Session(title: "BulkTest")
        context.insert(session)

        for round in 0..<50 {
            // Insert a batch
            var batch: [Message] = []
            for i in 0..<20 {
                let msg = Message(role: .user, content: "bulk \(round).\(i)")
                context.insert(msg)
                session.messages.append(msg)
                batch.append(msg)
            }
            try! context.save()

            // Force resolution
            _ = session.messages.map { $0.content }

            // Delete all
            for msg in batch {
                session.messages.removeAll { $0.id == msg.id }
                context.delete(msg)
            }
            try! context.save()

            // Immediately re-access (the dangerous pattern)
            let count = session.messages.count
            XCTAssertEqual(count, 0, "Round \(round): should be empty after bulk delete")

            // Access after deletion to trigger potential _registerObject on stale entries
            _ = session.messages.map { $0.content }
        }
    }
}

// MARK: - Test 2: Deferred dispatch interleaved with mutations

@MainActor
final class DeferredLoadInterleavingCrashTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        setenv("MallocScribble", "1", 1)
        (container, tmpDir) = makeSQLiteContainer()
        context = ModelContext(container)
    }

    override func tearDown() {
        context = nil
        container = nil
        if let tmpDir { cleanup(tmpDir: tmpDir) }
        tmpDir = nil
        super.tearDown()
    }

    /// Simulates the real crash scenario:
    /// 1. Schedule a deferred access to session.messages (like loadMessages does)
    /// 2. Before the deferred block fires, mutate the ModelContext (delete + insert + save)
    /// 3. The deferred block fires and accesses the relationship
    ///
    /// This mimics the interleaving between DispatchQueue.main.async (loadMessages)
    /// and @MainActor Task (generateResponse) during await suspension points.
    func testDeferredAccessAfterMutations() async {
        let session = Session(title: "InterleavingTest")
        context.insert(session)

        var liveMessages: [Message] = []
        for i in 0..<20 {
            let msg = Message(role: i % 2 == 0 ? .user : .assistant,
                              content: "initial \(i)")
            context.insert(msg)
            session.messages.append(msg)
            liveMessages.append(msg)
        }
        try! context.save()

        for round in 0..<100 {
            // Step 1: Schedule a deferred relationship access
            // (mirrors loadMessages's DispatchQueue.main.async)
            let deferredExpectation = XCTestExpectation(description: "deferred \(round)")
            var deferredResult: [String?] = []

            DispatchQueue.main.async { [session] in
                deferredResult = session.messages.map { $0.content }
                deferredExpectation.fulfill()
            }

            // Step 2: Mutate before the deferred block fires
            // (mirrors generateResponse doing insert/delete/save between awaits)
            if liveMessages.count >= 3 {
                for _ in 0..<2 {
                    let idx = Int.random(in: 0..<liveMessages.count)
                    let victim = liveMessages.remove(at: idx)
                    session.messages.removeAll { $0.id == victim.id }
                    context.delete(victim)
                }
            }

            let newMsg = Message(role: .assistant,
                                 content: "interleaved \(round)")
            context.insert(newMsg)
            session.messages.append(newMsg)
            liveMessages.append(newMsg)
            try! context.save()

            // Step 3: Let the deferred block fire
            await fulfillment(of: [deferredExpectation], timeout: 2.0)

            // If we reach here, no crash — verify consistency
            XCTAssertEqual(deferredResult.count, liveMessages.count,
                "Round \(round): deferred access should see \(liveMessages.count) messages, got \(deferredResult.count)")
        }
    }

    /// Rapid-fire scheduling: many deferred dispatches pile up while mutations happen.
    func testMultipleDeferredDispatchesWithMutations() async {
        let session = Session(title: "RapidDeferred")
        context.insert(session)

        for i in 0..<15 {
            let msg = Message(role: .user, content: "base \(i)")
            context.insert(msg)
            session.messages.append(msg)
        }
        try! context.save()

        var expectations: [XCTestExpectation] = []

        for round in 0..<50 {
            // Schedule multiple deferred reads
            let exp = XCTestExpectation(description: "batch \(round)")
            DispatchQueue.main.async { [session] in
                for _ in 0..<3 {
                    _ = session.messages.count
                    _ = session.messages.map { $0.content }
                }
                exp.fulfill()
            }
            expectations.append(exp)

            // Mutate between dispatches
            let msg = Message(role: .assistant, content: "rapid \(round)")
            context.insert(msg)
            session.messages.append(msg)
            try! context.save()

            if round % 5 == 0, let victim = session.messages.first {
                session.messages.removeAll { $0.id == victim.id }
                context.delete(victim)
                try! context.save()
            }
        }

        await fulfillment(of: expectations, timeout: 10.0)
    }
}

// MARK: - Test 3: Parallel TaskGroup stress (simulating sub-agent pattern)

@MainActor
final class ParallelTaskGroupModelContextCrashTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        setenv("MallocScribble", "1", 1)
        (container, tmpDir) = makeSQLiteContainer()
        context = ModelContext(container)
    }

    override func tearDown() {
        context = nil
        container = nil
        if let tmpDir { cleanup(tmpDir: tmpDir) }
        tmpDir = nil
        super.tearDown()
    }

    /// Simulates the withTaskGroup pattern in processToolCalls where multiple
    /// message_sub_agent calls operate on the same ModelContext concurrently:
    ///
    /// ```swift
    /// await withTaskGroup(...) { group in
    ///     for (_, toolCall) in parallelBatch {
    ///         group.addTask { @MainActor in
    ///             let result = await fnRouter.execute(toolCall: toolCall)
    ///             return ...
    ///         }
    ///     }
    /// }
    /// ```
    ///
    /// Each task does modelContext.insert + session.messages.append + save,
    /// interleaving at await points.
    func testParallelTaskGroupWithSharedModelContext() async {
        // Create parent session
        let parentSession = Session(title: "Parent")
        context.insert(parentSession)

        // Create multiple "sub-agent" sessions sharing the same ModelContext
        var subSessions: [Session] = []
        for i in 0..<5 {
            let sub = Session(title: "SubAgent\(i)")
            context.insert(sub)
            subSessions.append(sub)
        }
        try! context.save()

        // Seed parent with messages
        for i in 0..<10 {
            let msg = Message(role: .user, content: "parent msg \(i)")
            context.insert(msg)
            parentSession.messages.append(msg)
        }
        try! context.save()

        for round in 0..<30 {
            // Parallel group: multiple sub-agents insert messages simultaneously
            await withTaskGroup(of: Void.self) { group in
                for (idx, subSession) in subSessions.enumerated() {
                    group.addTask { @MainActor [context] in
                        let msg = Message(role: .assistant,
                                          content: "sub\(idx) round\(round)")
                        context!.insert(msg)
                        subSession.messages.append(msg)
                        try? context!.save()

                        // Simulate work (creates interleaving opportunity)
                        await Task.yield()

                        let toolMsg = Message(role: .tool,
                                             content: "tool result \(idx).\(round)",
                                             toolCallId: "tc_\(idx)_\(round)")
                        context!.insert(toolMsg)
                        subSession.messages.append(toolMsg)
                        try? context!.save()
                    }
                }
            }

            // After parallel work, parent session accesses its relationship
            // (mirrors loadMessages being called after processToolCalls returns)
            let parentCount = parentSession.messages.count
            XCTAssertEqual(parentCount, 10,
                "Round \(round): parent messages should remain 10, got \(parentCount)")

            // Also force resolution of sub-session relationships
            for sub in subSessions {
                _ = sub.messages.map { $0.content }
            }
        }
    }

    /// More aggressive variant: parallel mutations + deletions + relationship reads.
    func testParallelMutationsWithCrossSessionReads() async {
        let sessions: [Session] = (0..<4).map { i in
            let s = Session(title: "Session\(i)")
            context.insert(s)
            for j in 0..<10 {
                let msg = Message(role: .user, content: "s\(i)m\(j)")
                context.insert(msg)
                s.messages.append(msg)
            }
            return s
        }
        try! context.save()

        for round in 0..<50 {
            await withTaskGroup(of: Void.self) { group in
                // Writers: each task mutates a different session
                for (idx, session) in sessions.enumerated() {
                    group.addTask { @MainActor [context] in
                        // Delete one message
                        if let victim = session.messages.first {
                            session.messages.removeAll { $0.id == victim.id }
                            context!.delete(victim)
                        }
                        // Insert a new one
                        let msg = Message(role: .assistant,
                                          content: "new \(idx).\(round)")
                        context!.insert(msg)
                        session.messages.append(msg)
                        try? context!.save()

                        await Task.yield()
                    }
                }

                // Reader: concurrently reads all sessions' relationships
                group.addTask { @MainActor [context = self.context!, sessions] in
                    for session in sessions {
                        _ = session.messages.count
                        _ = session.messages.map { $0.content }
                    }
                }
            }
        }

        // Final consistency check
        for session in sessions {
            XCTAssertGreaterThan(session.messages.count, 0,
                "\(session.title) should have messages")
        }
    }
}

// MARK: - Test 4: True concurrent access (data race reproduction)

/// Verifies that when all ModelContext access is properly serialized on MainActor
/// (as the production code now does after the @MainActor fix), no crash occurs.
///
/// Before the fix, ChatViewModel lacked @MainActor isolation, allowing potential
/// off-main-thread access to Session.messages which caused:
///   EXC_BAD_ACCESS in ModelContext._registerObject → _NativeDictionary.copy()
@MainActor
final class MainActorIsolatedAccessTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        setenv("MallocScribble", "1", 1)
        (container, tmpDir) = makeSQLiteContainer()
        context = ModelContext(container)
    }

    override func tearDown() {
        context = nil
        container = nil
        if let tmpDir { cleanup(tmpDir: tmpDir) }
        tmpDir = nil
        super.tearDown()
    }

    /// Simulates the post-fix code path: all ModelContext operations (insert,
    /// delete, save, relationship access) happen on MainActor via Task, never
    /// via raw DispatchQueue.global().
    ///
    /// This mirrors the fixed ChatViewModel where loadMessages uses
    /// `Task { ... }` (inheriting @MainActor) instead of DispatchQueue.main.async,
    /// and all mutations in generateResponse/processToolCalls are @MainActor.
    func testAllAccessOnMainActorDoesNotCrash() async {
        let session = Session(title: "FixedPath")
        context.insert(session)

        for i in 0..<20 {
            let msg = Message(role: .user, content: "msg \(i)")
            context.insert(msg)
            session.messages.append(msg)
        }
        try! context.save()

        let iterations = 500

        for i in 0..<iterations {
            let msg = Message(role: .assistant, content: "response \(i)")
            context.insert(msg)
            session.messages.append(msg)

            if i % 5 == 0, let victim = session.messages.first {
                session.messages.removeAll { $0.id == victim.id }
                context.delete(victim)
            }

            if i % 3 == 0 {
                try? context.save()
            }

            // Yield to simulate async suspension points in generateResponse
            await Task.yield()

            // Read relationship (as loadMessages does via Task on MainActor)
            _ = session.messages.count
            _ = session.messages.map { $0.content }
        }

        try? context.save()
        XCTAssertGreaterThan(session.messages.count, 0)
    }

    /// Simulates the fixed loadMessages path using ChatViewModel directly.
    /// The VM is now @MainActor, so loadMessages' Task inherits MainActor
    /// isolation and all access is serialized.
    func testChatViewModelLoadMessagesAfterMutationsDoesNotCrash() async {
        let session = Session(title: "VMTest")
        context.insert(session)

        for i in 0..<10 {
            let msg = Message(role: .user, content: "seed \(i)")
            context.insert(msg)
            session.messages.append(msg)
        }
        try! context.save()

        let vm = ChatViewModel(session: session, modelContext: context)
        vm.loadMessages(immediate: true)
        XCTAssertEqual(vm.messages.count, 10)

        for round in 0..<200 {
            // Mutate (simulating generateResponse)
            let newMsg = Message(role: .assistant, content: "gen \(round)")
            context.insert(newMsg)
            session.messages.append(newMsg)

            if round % 7 == 0, let victim = session.messages.first {
                session.messages.removeAll { $0.id == victim.id }
                context.delete(victim)
            }

            try? context.save()

            // Deferred load (now Task-based, MainActor-isolated)
            vm.loadMessages(immediate: false)

            await Task.yield()
        }

        // Final immediate load to sync
        vm.loadMessages(immediate: true)
        XCTAssertGreaterThan(vm.messages.count, 0)
    }

    /// Simulates the parallel TaskGroup sub-agent pattern with all tasks
    /// properly isolated to MainActor. No background thread access.
    func testParallelSubAgentTaskGroupOnMainActorDoesNotCrash() async {
        let parentSession = Session(title: "Parent")
        context.insert(parentSession)

        var subSessions: [Session] = []
        for i in 0..<5 {
            let sub = Session(title: "Sub\(i)")
            context.insert(sub)
            subSessions.append(sub)
        }

        for i in 0..<10 {
            let msg = Message(role: .user, content: "parent \(i)")
            context.insert(msg)
            parentSession.messages.append(msg)
        }
        try! context.save()

        for round in 0..<30 {
            await withTaskGroup(of: Void.self) { group in
                for (idx, subSession) in subSessions.enumerated() {
                    group.addTask { @MainActor [context = self.context!] in
                        let msg = Message(role: .assistant,
                                          content: "sub\(idx) r\(round)")
                        context.insert(msg)
                        subSession.messages.append(msg)
                        try? context.save()

                        await Task.yield()

                        let toolMsg = Message(role: .tool,
                                             content: "tool \(idx).\(round)",
                                             toolCallId: "tc_\(idx)_\(round)")
                        context.insert(toolMsg)
                        subSession.messages.append(toolMsg)
                        try? context.save()
                    }
                }
            }

            // Parent reads its relationship after sub-agent work
            XCTAssertEqual(parentSession.messages.count, 10)
            for sub in subSessions {
                _ = sub.messages.map { $0.content }
            }
        }
    }
}

// MARK: - Crash Root-Cause Demonstration (deliberately unsafe)

/// These tests deliberately violate SwiftData's thread-safety contract to
/// PROVE that concurrent ModelContext access is the root cause of the crash.
/// They are disabled by default (prefixed with `disabled_`) because they
/// crash the test process intentionally.
///
/// To run them manually, rename by removing the `disabled_` prefix.
@MainActor
final class ConcurrentAccessCrashDemoTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        setenv("MallocScribble", "1", 1)
        (container, tmpDir) = makeSQLiteContainer()
        context = ModelContext(container)
    }

    override func tearDown() {
        context = nil
        container = nil
        if let tmpDir { cleanup(tmpDir: tmpDir) }
        tmpDir = nil
        super.tearDown()
    }

    /// CRASHES INTENTIONALLY. Demonstrates the root cause by reading
    /// session.messages from a background thread while the main thread writes.
    /// Produces the same EXC_BAD_ACCESS / POINTER_BEING_FREED crash signature.
    func disabled_testConcurrentReadWriteCrashesProcess() async {
        let session = Session(title: "RaceTest")
        context.insert(session)

        for i in 0..<20 {
            let msg = Message(role: .user, content: "race msg \(i)")
            context.insert(msg)
            session.messages.append(msg)
        }
        try! context.save()

        let capturedContext = context!
        let capturedSession = session
        let iterations = 500
        let readerDone = XCTestExpectation(description: "reader done")

        DispatchQueue.global(qos: .userInitiated).async {
            for _ in 0..<iterations {
                _ = capturedSession.messages.count
                _ = capturedSession.messages.map { $0.content }
                if Bool.random() { usleep(100) }
            }
            readerDone.fulfill()
        }

        for i in 0..<iterations {
            let msg = Message(role: .assistant, content: "concurrent \(i)")
            capturedContext.insert(msg)
            session.messages.append(msg)

            if i % 5 == 0, let victim = session.messages.first {
                session.messages.removeAll { $0.id == victim.id }
                capturedContext.delete(victim)
            }
            if i % 3 == 0 { try? capturedContext.save() }
            await Task.yield()
        }
        try? capturedContext.save()

        await fulfillment(of: [readerDone], timeout: 30.0)
    }
}
