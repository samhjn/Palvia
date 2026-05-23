import XCTest
@testable import iClaw

final class ObjCExceptionCatcherTests: XCTestCase {

    func testCatchesRaisedNSException() {
        let caught = ObjCExceptionCatcher.catching {
            NSException(
                name: .internalInconsistencyException,
                reason: "test reason",
                userInfo: nil
            ).raise()
        }
        XCTAssertNotNil(caught)
        XCTAssertEqual(caught?.name.rawValue, NSExceptionName.internalInconsistencyException.rawValue)
        XCTAssertEqual(caught?.reason, "test reason")
    }

    func testReturnsNilWhenBlockDoesNotRaise() {
        var ran = false
        let caught = ObjCExceptionCatcher.catching {
            ran = true
        }
        XCTAssertNil(caught)
        XCTAssertTrue(ran)
    }

    func testCrashDiagnosticsRoundTrip() {
        let key = "iClaw.lastNSException"
        UserDefaults.standard.removeObject(forKey: key)

        CrashDiagnostics.record(source: "unit-test", name: "TestException", reason: "unit")
        let record = CrashDiagnostics.consume()

        XCTAssertNotNil(record)
        XCTAssertEqual(record?.source, "unit-test")
        XCTAssertEqual(record?.name, "TestException")
        XCTAssertEqual(record?.reason, "unit")

        // consume() must clear the stored record.
        XCTAssertNil(CrashDiagnostics.consume())
    }
}
