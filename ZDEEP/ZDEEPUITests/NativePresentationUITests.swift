import XCTest

final class NativePresentationUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func test_initialRegistrationError_exposesOnlyStartOver() {
        let app = launchFixture("initial")

        XCTAssertTrue(app.staticTexts["Ошибка подключения"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Сервер отклонил запрос (HTTP 503)."].exists)
        XCTAssertTrue(app.buttons["Начать сначала"].exists)
        XCTAssertFalse(app.buttons["Повторить"].exists)
        XCTAssertFalse(app.buttons["Отвязать автомобиль"].exists)
    }

    @MainActor
    func test_registeredError_showsRetryAndRebindWithAccessibleConfirmation() {
        let app = launchFixture("registered")

        XCTAssertTrue(app.buttons["Повторить"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Доступ к автомобилю запрещён. CAR_ACCESS_DENIED"].exists)
        XCTAssertEqual(app.staticTexts["diagnostic-line"].label, "Код: NT · HTTP_403 · D8E15186")
        XCTAssertEqual(app.staticTexts["http-status"].label, "HTTP 403")
        let rebind = app.buttons["Отвязать автомобиль"]
        XCTAssertTrue(rebind.exists)
        XCTAssertTrue(rebind.isHittable)
        rebind.tap()

        let confirmation = "Привязка на этом телефоне будет удалена. Для входа потребуется снова отсканировать QR-код машины"
        XCTAssertTrue(app.alerts.staticTexts[confirmation].waitForExistence(timeout: 3))
        XCTAssertTrue(app.alerts.buttons["Отмена"].exists)
        XCTAssertTrue(app.alerts.buttons["Отвязать автомобиль"].exists)
    }

    @MainActor
    func test_unknownServerCode_isPreservedAndRussianMessageIsVisible() {
        let app = launchFixture("unknown")

        XCTAssertTrue(app.staticTexts["Сервер отклонил запрос. UNKNOWN_SERVER_FAILURE_CODE"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Raw error body that must never be shown"].exists)
        XCTAssertEqual(app.staticTexts["diagnostic-line"].label, "Код: NT · HTTP_503 · D8E15186")
    }

    @MainActor
    func test_missingServerCode_showsGenericRussianExplanationAndHttpDiagnostic() {
        let app = launchFixture("missing-code")

        XCTAssertTrue(app.staticTexts["Сервер отклонил запрос (HTTP 503)."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Raw response body must never be shown"].exists)
        XCTAssertEqual(app.staticTexts["diagnostic-line"].label, "Код: NT · HTTP_503 · D8E15186")
    }

    @MainActor
    func test_restoreReset_requiresConfirmationAndSupportsDynamicType() {
        let app = launchFixture(
            "restore",
            extraArguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        )

        XCTAssertTrue(app.staticTexts["Ошибка подключения"].waitForExistence(timeout: 5))
        let retry = app.buttons["Повторить"]
        let diagnostic = app.staticTexts["diagnostic-line"]
        let status = app.staticTexts["http-status"]
        let version = app.staticTexts["app-version"]
        XCTAssertTrue(diagnostic.waitForExistence(timeout: 5))
        XCTAssertTrue(diagnostic.label.contains("Код: NT · HTTP_503 · D8E15186"))
        XCTAssertEqual(status.label, "HTTP 503")
        XCTAssertFalse(version.label.isEmpty)
        let reset = app.buttons["Сбросить авторизацию"]
        if !diagnostic.isHittable || !status.isHittable || !version.isHittable { app.swipeUp() }
        XCTAssertTrue(diagnostic.isHittable)
        XCTAssertTrue(status.isHittable)
        XCTAssertTrue(version.isHittable)
        if !retry.isHittable || !reset.isHittable { app.swipeUp() }
        XCTAssertTrue(retry.isHittable)
        XCTAssertTrue(reset.isHittable)
        reset.tap()

        let confirmation = "Привязка на этом телефоне будет удалена. Для входа потребуется снова отсканировать QR-код машины"
        XCTAssertTrue(app.alerts.staticTexts[confirmation].waitForExistence(timeout: 3))
        XCTAssertTrue(app.alerts.buttons["Сбросить авторизацию"].exists)
    }

    @MainActor
    func test_deniedCameraPermissionOffersSettingsAndBack() {
        let app = launchFixture("camera-denied")

        XCTAssertTrue(app.staticTexts["Доступ к камере запрещён"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Открыть настройки"].exists)
        XCTAssertTrue(app.buttons["Назад"].exists)
    }

    @MainActor
    func test_restrictedCameraPermissionExplainsRestrictionWithoutSettingsAction() {
        let app = launchFixture("camera-restricted")

        XCTAssertTrue(app.staticTexts["Доступ к камере ограничен"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Изменить это ограничение можно в настройках устройства или с помощью администратора."].exists)
        XCTAssertFalse(app.buttons["Открыть настройки"].exists)
        XCTAssertTrue(app.buttons["Назад"].exists)
    }

    @MainActor
    private func launchFixture(_ fixture: String, extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--environment", "local", "--ui-test-presentation", fixture] + extraArguments
        app.launch()
        return app
    }
}
