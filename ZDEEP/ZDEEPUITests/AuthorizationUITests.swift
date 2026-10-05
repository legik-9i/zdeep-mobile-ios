import XCTest

final class AuthorizationUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func test_cameraPermissionAndBackReturnToWelcome() {
        let app = launchAuthorizationFixture("denied")
        let scan = app.buttons["Сканировать QR-код"]
        XCTAssertTrue(scan.waitForExistence(timeout: 5))
        scan.tap()

        XCTAssertTrue(app.staticTexts["Доступ к камере запрещён"].waitForExistence(timeout: 5))
        app.buttons["Назад"].tap()

        XCTAssertTrue(app.staticTexts["Подключите ваш Zeekr"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Сканировать QR-код"].exists)
    }

    @MainActor
    func test_syntheticQrStartsSingleRegistrationAndCancelReturnsToWelcome() {
        let app = launchAuthorizationFixture("authorized")
        app.buttons["Сканировать QR-код"].tap()
        let scanResult = app.buttons["synthetic-scan-result"]
        XCTAssertTrue(scanResult.waitForExistence(timeout: 5))
        scanResult.tap()

        XCTAssertTrue(app.staticTexts["Загрузка"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["registration-count"].label, "pair 1 · complete 1")
        XCTAssertFalse(app.staticTexts["fixture.qr.car-token"].exists)
        app.buttons["Отмена"].tap()

        XCTAssertTrue(app.staticTexts["Подключите ваш Zeekr"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["reset-count"].label, "reset 1")
    }

    @MainActor
    func test_rebindDeclineKeepsRegistrationAndConfirmResetsOnce() {
        let app = launchAuthorizationFixture("registered")
        XCTAssertTrue(app.buttons["Перепривязать"].waitForExistence(timeout: 5))
        app.buttons["Перепривязать"].tap()
        XCTAssertTrue(app.alerts.buttons["Отмена"].waitForExistence(timeout: 3))
        app.alerts.buttons["Отмена"].tap()
        XCTAssertEqual(app.staticTexts["reset-count"].label, "reset 0")
        XCTAssertTrue(app.buttons["Перепривязать"].exists)

        app.buttons["Перепривязать"].tap()
        app.alerts.buttons["Перепривязать"].tap()

        XCTAssertTrue(app.staticTexts["Подключите ваш Zeekr"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["reset-count"].label, "reset 1")
    }

    @MainActor
    func test_coldRestoreLoadingCanCancelAndClearsStoredBinding() {
        let app = launchAuthorizationFixture("registered-loading")
        XCTAssertTrue(app.staticTexts["Загрузка"].waitForExistence(timeout: 5))
        let cancel = app.buttons["Отмена"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 3))
        cancel.tap()

        XCTAssertTrue(app.staticTexts["Подключите ваш Zeekr"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["reset-count"].label, "reset 1")
    }

    @MainActor
    private func launchAuthorizationFixture(_ scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--environment", "local", "--ui-test-authorization", scenario]
        app.launch()
        return app
    }
}
