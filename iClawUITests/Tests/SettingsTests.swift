import XCTest

final class SettingsTests: BaseTestCase {

    func test_settings_displaysCorrectly() {
        waitForAppReady()
        let tabBar = TabBarPage(app: app)
        let settings = tabBar.switchToSettings()

        settings.verifyIsDisplayed()
        settings.verifyAddProviderButtonExists()
    }

    func test_settings_aboutRowExists() {
        waitForAppReady()
        let tabBar = TabBarPage(app: app)
        let settings = tabBar.switchToSettings()

        settings.verifyAboutRowExists()
    }

    func test_settings_togglesExist() {
        waitForAppReady()
        let tabBar = TabBarPage(app: app)
        let settings = tabBar.switchToSettings()

        settings.verifyTogglesExist()
    }

    func test_settings_tapAbout_navigatesToAboutView() {
        waitForAppReady()
        let tabBar = TabBarPage(app: app)
        let settings = tabBar.switchToSettings()

        settings.tapAbout()

        let backButton = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(backButton.waitForExistence(timeout: 5), "Should navigate to About view")
    }

    func test_settings_addProviderButton_showsSheet() {
        waitForAppReady()
        let tabBar = TabBarPage(app: app)
        let settings = tabBar.switchToSettings()

        settings.tapAddProvider()

        let sheet = app.navigationBars.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "Provider edit sheet should appear")
    }
}
