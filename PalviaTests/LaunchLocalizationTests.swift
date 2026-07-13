import XCTest
@testable import Palvia

final class LaunchLocalizationTests: XCTestCase {
    func testLaunchTaskStringsResolveFromLocalizationTables() {
        let values = [
            L10n.Launch.protectedDataTitle,
            L10n.Launch.protectedDataMessage,
            L10n.Launch.cleaningUp,
            L10n.Launch.buildingIndex,
            L10n.Launch.progressStatus("Indexing", "50%")
        ]

        for value in values {
            XCTAssertFalse(value.isEmpty)
            XCTAssertFalse(value.hasPrefix("launch."), "Missing localization for \(value)")
        }
    }

    func testLaunchProgressStatusIncludesDescriptionAndProgress() {
        let status = L10n.Launch.progressStatus("Building search index", "50%")
        XCTAssertTrue(status.contains("Building search index"))
        XCTAssertTrue(status.contains("50%"))
    }
}
