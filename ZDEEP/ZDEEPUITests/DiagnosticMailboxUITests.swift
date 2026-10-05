import XCTest

final class DiagnosticMailboxUITests: XCTestCase {
    @MainActor
    func test_mailbox_opt_in_keeps_welcome_visible_with_prepared_hidden_webview() {
        let app = XCUIApplication()
        app.launchArguments = ["--environment", "local", "--ui-test-empty-binding", "--usb-diagnostics"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Подключите ваш Zeekr"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["current-environment"].exists)
        app.buttons["debug-button"].tap()
        let state = app.descendants(matching: .any)["webview-state"]
        XCTAssertTrue(state.waitForExistence(timeout: 3))
        let prepared = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", "Подготовлен", "Загрузка"),
            object: state
        )
        XCTAssertEqual(XCTWaiter.wait(for: [prepared], timeout: 10), .completed)
        XCTAssertTrue(app.staticTexts["Подключите ваш Zeekr"].exists)
        XCTAssertTrue(app.webViews.firstMatch.exists)
        XCTAssertFalse(app.webViews.firstMatch.isHittable)
    }

    @MainActor
    func test_explicit_diagnostic_cli_open_flag_does_not_reveal_local_webview() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--environment", "local",
            "--ui-test-empty-binding",
            "--usb-diagnostics",
            "--usb-diagnostics-open-webview",
        ]
        app.launch()

        app.buttons["debug-button"].tap()
        let state = app.descendants(matching: .any)["webview-state"]
        XCTAssertTrue(state.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Подключите ваш Zeekr"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.webViews.firstMatch.exists)
        XCTAssertFalse(app.webViews.firstMatch.isHittable)
        XCTAssertTrue(app.buttons["close-webview"].exists)
    }
}
