import XCTest
@testable import iClaw

/// Regression coverage for the iOS-17.0 launch-crash class: SwiftUI
/// re-creates the `App` struct on every body re-evaluation, so any
/// side-effecting work that lives in `App.init()` must be guarded so it
/// runs exactly once per process. The crash signature was
/// `EXC_BREAKPOINT brk 1` deep inside libswiftCore; the proximate cause
/// was unguarded SwiftData saves + UserDefaults writes + filesystem
/// sweeps in `iClawApp.init()` cascading through observation back into
/// body evaluation.
///
/// These tests exercise the latch directly (no real ModelContainer / no
/// real BGTaskScheduler), so they're cheap and version-independent.
final class AppLaunchIdempotencyTests: XCTestCase {

    override func setUp() {
        super.setUp()
        iClawApp.resetLaunchStateForTesting()
    }

    override func tearDown() {
        iClawApp.resetLaunchStateForTesting()
        super.tearDown()
    }

    func testWorkRunsOnFirstCall() {
        var count = 0
        iClawApp.runOneTimeLaunchTasksIfNeeded { count += 1 }
        XCTAssertEqual(count, 1)
        XCTAssertTrue(iClawApp.didRunOneTimeLaunchTasks)
    }

    /// SwiftUI may instantiate `iClawApp` many times per process. The
    /// gated work must run on the first call only.
    func testWorkDoesNotRepeatAcrossManyInits() {
        var count = 0
        for _ in 0..<50 {
            iClawApp.runOneTimeLaunchTasksIfNeeded { count += 1 }
        }
        XCTAssertEqual(count, 1, "Latch must hold across many init re-runs")
    }

    /// After explicit reset (test-only / never in production), the latch
    /// re-arms — proving the flag is the actual gate.
    func testResetReArmsLatch() {
        var count = 0
        iClawApp.runOneTimeLaunchTasksIfNeeded { count += 1 }
        iClawApp.resetLaunchStateForTesting()
        iClawApp.runOneTimeLaunchTasksIfNeeded { count += 1 }
        XCTAssertEqual(count, 2)
    }

    /// The latch must NOT swallow throws/precondition failures from the
    /// work block — those bugs need to surface to the developer, not be
    /// hidden by the guard. We can't easily test `fatalError`, but we
    /// can verify the closure is called (we already do that above) and
    /// that the flag is set before the work runs (so a crash inside the
    /// work block doesn't cause an infinite re-launch loop on next
    /// process start, since process start resets statics anyway).
    func testFlagIsSetBeforeWorkRuns() {
        var observedFlagDuringWork: Bool?
        iClawApp.runOneTimeLaunchTasksIfNeeded {
            observedFlagDuringWork = iClawApp.didRunOneTimeLaunchTasks
        }
        XCTAssertEqual(observedFlagDuringWork, true,
                       "Flag must be set before work runs so a re-entrant call from "
                       + "inside the work block becomes a no-op rather than recursing.")
    }

    /// Re-entrant call from inside the work block is a no-op. Proves the
    /// guard catches the AttributeGraph cascade scenario directly.
    func testReentrantCallIsNoop() {
        var outerCount = 0
        var innerCount = 0
        iClawApp.runOneTimeLaunchTasksIfNeeded {
            outerCount += 1
            // Simulate SwiftUI re-entering init() during the work block.
            iClawApp.runOneTimeLaunchTasksIfNeeded {
                innerCount += 1
            }
        }
        XCTAssertEqual(outerCount, 1)
        XCTAssertEqual(innerCount, 0, "Re-entrant call must not run the work block")
    }
}
