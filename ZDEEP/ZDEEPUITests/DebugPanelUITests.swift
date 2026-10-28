import XCTest

final class DebugPanelUITests: XCTestCase {
    @MainActor
    func test_dragOnlyMovesButtonAndTapOpensPanelAfterMoving() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--environment", "local", "--ui-test-empty-binding"]
        app.launch()
        let button = app.buttons["debug-button"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        let originalFrame = button.frame
        let start = button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: -120, dy: 160)))

        XCTAssertFalse(app.buttons["close-debug-panel"].exists)
        XCTAssertGreaterThan(button.frame.midY, originalFrame.midY + 80)
        button.tap()
        XCTAssertTrue(app.buttons["close-debug-panel"].waitForExistence(timeout: 3))
        app.buttons["close-debug-panel"].tap()
        button.tap()
        XCTAssertTrue(app.buttons["close-debug-panel"].waitForExistence(timeout: 3))
    }

    @MainActor
    func test_debug_panel_shows_preparedWebWithoutRevealingIt() {
        let app = XCUIApplication()
        app.launchArguments = ["--environment", "local", "--ui-test-empty-binding"]
        app.launch()

        let debugButton = app.buttons["debug-button"]
        XCTAssertTrue(debugButton.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Подключите ваш Zeekr"].exists)
        XCTAssertFalse(app.staticTexts["current-environment"].exists)
        debugButton.tap()
        XCTAssertTrue(app.descendants(matching: .any)["environment-picker"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["reset-client-data"].exists)
        XCTAssertTrue(app.buttons["close-webview"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Подключите ваш Zeekr"].exists)
        XCTAssertTrue(app.webViews.firstMatch.exists)
        XCTAssertFalse(app.webViews.firstMatch.isHittable)
        XCTAssertTrue(app.descendants(matching: .any)["js-input"].exists)
        app.buttons["close-webview"].tap()
        XCTAssertTrue(app.staticTexts["Подключите ваш Zeekr"].waitForExistence(timeout: 3))
        XCTAssertTrue(debugButton.exists)
    }

    @MainActor
    func test_debug_panel_remains_available_while_loading_and_after_navigation_error() {
        let app = XCUIApplication()
        app.launchArguments = ["--environment", "local", "--ui-test-empty-binding", "--web-url", "http://127.0.0.1:1"]
        app.launch()
        DebugPanelTestActions.openWebView(app)

        XCTAssertTrue(app.buttons["reload-webview"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Подключите ваш Zeekr"].exists)
        XCTAssertTrue(app.webViews.firstMatch.exists)
        XCTAssertFalse(app.webViews.firstMatch.isHittable)
        XCTAssertTrue(app.buttons["reset-client-data"].waitForExistence(timeout: 3))
        app.swipeUp()
        XCTAssertFalse(app.buttons["execute-js"].isEnabled)
        app.buttons["close-debug-panel"].tap()
        XCTAssertTrue(app.staticTexts["Подключите ваш Zeekr"].exists)
    }

    @MainActor
    func test_js_result_policy_is_explicit_and_initial_result_is_not_saved() {
        let app = XCUIApplication()
        app.launchArguments = ["--environment", "local", "--ui-test-empty-binding"]
        app.launch()
        app.buttons["debug-button"].tap()
        app.swipeUp()

        XCTAssertTrue(app.staticTexts["Результаты JS показываются только здесь и автоматически не сохраняются."].exists)
        XCTAssertTrue(app.staticTexts["Результат появится здесь"].exists)
    }

}

enum DebugPanelTestActions {
    static func openWebView(_ app: XCUIApplication) {
        app.buttons["debug-button"].tap()
        let openButton = app.buttons["open-webview"]
        if openButton.waitForExistence(timeout: 1) {
            openButton.tap()
            app.buttons["debug-button"].tap()
        }
        let state = app.descendants(matching: .any)["webview-state"]
        XCTAssertTrue(state.waitForExistence(timeout: 5))
        let prepared = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@ OR label CONTAINS %@", "Подготовлен", "Загрузка", "Ошибка"),
            object: state
        )
        XCTAssertEqual(XCTWaiter.wait(for: [prepared], timeout: 10), .completed)
        XCTAssertTrue(app.staticTexts["Подключите ваш Zeekr"].exists)
        XCTAssertTrue(app.webViews.firstMatch.exists)
        XCTAssertFalse(app.webViews.firstMatch.isHittable)
    }

    static func closeWebView(_ app: XCUIApplication) {
        if !app.buttons["close-webview"].exists { app.buttons["debug-button"].tap() }
        let closeButton = app.buttons["close-webview"]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 3))
        closeButton.tap()
    }

    static func assertWebViewOpen(_ app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["Подключите ваш Zeekr"].exists)
        XCTAssertTrue(app.buttons["close-webview"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.webViews.firstMatch.exists)
        XCTAssertFalse(app.webViews.firstMatch.isHittable)
    }
}
