import XCTest

extension XCUIElement {
    /// Tap the element once it becomes available, failing the test if it doesn't appear.
    func tapWhenReady(timeout: TimeInterval = 5, file: StaticString = #file, line: UInt = #line) {
        guard waitForExistence(timeout: timeout) else {
            XCTFail("Element \(identifier) did not appear within \(timeout)s", file: file, line: line)
            return
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
