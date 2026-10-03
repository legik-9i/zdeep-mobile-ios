import XCTest

final class DebugPanelUITests: XCTestCase {
    @MainActor
    func test_debug_panel_is_available_on_welcome_and_after_webview_closes() {
        let app = XCUIApplication()
        app.launchArguments = ["--environment", "local"]
        app.launch()

        let debugButton = app.buttons["debug-button"]
        XCTAssertTrue(debugButton.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["welcome-environment-picker"].exists)
        debugButton.tap()
        XCTAssertTrue(app.descendants(matching: .any)["environment-picker"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["reset-client-data"].exists)
        app.buttons["close-debug-panel"].tap()

        app.buttons["open-webview"].tap()
        XCTAssertTrue(app.buttons["close-webview"].waitForExistence(timeout: 3))
        XCTAssertTrue(debugButton.exists)
        debugButton.tap()
        XCTAssertTrue(app.buttons["reload-webview"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["js-input"].exists)
        app.buttons["close-debug-panel"].tap()

        app.buttons["close-webview"].tap()
        XCTAssertTrue(app.buttons["open-webview"].waitForExistence(timeout: 3))
        XCTAssertTrue(debugButton.exists)
    }

    @MainActor
    func test_debug_panel_remains_available_while_loading_and_after_navigation_error() {
        let app = XCUIApplication()
        app.launchArguments = ["--environment", "local", "--web-url", "http://127.0.0.1:1"]
        app.launch()
        app.buttons["open-webview"].tap()

        let debugButton = app.buttons["debug-button"]
        XCTAssertTrue(debugButton.waitForExistence(timeout: 3))
        debugButton.tap()
        XCTAssertTrue(app.buttons["reload-webview"].waitForExistence(timeout: 3))
        app.buttons["close-debug-panel"].tap()

        debugButton.tap()
        XCTAssertTrue(app.descendants(matching: .any)["webview-error"].waitForExistence(timeout: 15))
        let state = app.descendants(matching: .any)["webview-state"]
        let showsErrorState = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Ошибка"), object: state)
        XCTAssertEqual(XCTWaiter.wait(for: [showsErrorState], timeout: 5), .completed)
        XCTAssertTrue(app.buttons["reset-client-data"].waitForExistence(timeout: 3))
        app.buttons["close-debug-panel"].tap()
        app.buttons["close-webview"].tap()
        XCTAssertTrue(debugButton.exists)
    }

    @MainActor
    func test_js_result_policy_is_explicit_and_initial_result_is_not_saved() {
        let app = XCUIApplication()
        app.launchArguments = ["--environment", "local"]
        app.launch()
        app.buttons["debug-button"].tap()

        XCTAssertTrue(app.staticTexts["Результаты JS показываются только здесь и автоматически не сохраняются."].exists)
        XCTAssertTrue(app.staticTexts["Результат появится здесь"].exists)
    }

    @MainActor
    func test_js_result_clears_after_active_session_is_reset() {
        let app = XCUIApplication()
        app.launchArguments = ["--environment", "local"]
        app.launch()
        app.buttons["open-webview"].tap()
        XCTAssertTrue(app.buttons["close-webview"].waitForExistence(timeout: 3))
        app.buttons["debug-button"].tap()

        let result = app.descendants(matching: .any)["js-result"]
        XCTAssertTrue(result.waitForExistence(timeout: 3))
        app.buttons["execute-js"].tap()
        let hasResult = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label != %@", "Результат появится здесь"),
            object: result
        )
        XCTAssertEqual(XCTWaiter.wait(for: [hasResult], timeout: 15), .completed)

        app.buttons["reset-client-data"].tap()
        let hasPlaceholder = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Результат появится здесь"),
            object: result
        )
        XCTAssertEqual(XCTWaiter.wait(for: [hasPlaceholder], timeout: 5), .completed)
    }

    @MainActor
    func test_top_level_string_js_result_renders_without_crashing() {
        let app = XCUIApplication()
        app.launchArguments = ["--environment", "local"]
        app.launch()
        app.buttons["open-webview"].tap()
        XCTAssertTrue(app.buttons["close-webview"].waitForExistence(timeout: 3))
        app.buttons["debug-button"].tap()

        let result = app.descendants(matching: .any)["js-result"]
        XCTAssertTrue(result.waitForExistence(timeout: 3))
        app.buttons["execute-js"].tap()
        let showsStringResult = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label != %@", "Результат появится здесь"),
            object: result
        )
        XCTAssertEqual(XCTWaiter.wait(for: [showsStringResult], timeout: 15), .completed)
        XCTAssertTrue(app.exists)

        app.buttons["close-debug-panel"].tap()
        app.buttons["close-webview"].tap()
    }
}
