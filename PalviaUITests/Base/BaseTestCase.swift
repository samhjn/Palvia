import XCTest

class BaseTestCase: XCTestCase {
    var app: XCUIApplication!
    private static var launchMarker: URL? = {
        guard let token = ProcessInfo.processInfo.environment["PALVIA_LAUNCH_PROBE"],
              UUID(uuidString: token) != nil else { return nil }
        return FileManager.default.temporaryDirectory.appendingPathComponent("palvia-launch-\(token).started")
    }()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += [LaunchArguments.uiTesting]
        let marker = BaseTestCase.launchMarker
        BaseTestCase.launchMarker = nil
        if let marker {
            try? name.write(to: marker, atomically: true, encoding: .utf8)
        }
        app.launch()
        if let marker {
            let returned = marker.deletingPathExtension().appendingPathExtension("returned")
            try? name.write(to: returned, atomically: true, encoding: .utf8)
        }
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
