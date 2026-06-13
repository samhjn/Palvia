import XCTest

extension XCUIElement {
    /// Tap the element once it becomes available, failing the test if it doesn't appear.
    ///
    /// Waits for both existence and hittability before tapping. SwiftUI tab-bar
    /// and toolbar buttons frequently report `exists == true` while still
    /// animating in, during which a `tap()` is silently dropped — the source of
    /// flaky "element not found" / "alert never appeared" failures downstream
    /// when the tap that should have triggered navigation or a sheet is lost.
    func tapWhenReady(timeout: TimeInterval = 10, file: StaticString = #file, line: UInt = #line) {
        guard waitForExistence(timeout: timeout) else {
            XCTFail("Element \(identifier) did not appear within \(timeout)s", file: file, line: line)
            return
        }
        if !isHittable {
            _ = waitUntilHittable(timeout: timeout)
        }
        tap()
    }

    /// Wait until the element's `isHittable` property becomes true.
    func waitUntilHittable(timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "isHittable == true")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        return result == .completed
    }

    /// Type text into the element after tapping it, clearing existing content first.
    func clearAndTypeText(_ text: String) {
        tap()
        guard let currentValue = value as? String, !currentValue.isEmpty else {
            typeText(text)
            return
        }
        let deleteString = String(repeating: XCUIKeyboardKey.delete.rawValue, count: currentValue.count)
        typeText(deleteString)
        typeText(text)
    }
}
