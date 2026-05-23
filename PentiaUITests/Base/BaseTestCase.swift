import XCTest

class BaseTestCase: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += [LaunchArguments.uiTesting]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    /// Wait until the tab bar is visible, indicating the app has finished launching.
    func waitForAppReady(timeout: TimeInterval = 10) {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: timeout), "App did not finish launching in \(timeout)s")
    }
}
