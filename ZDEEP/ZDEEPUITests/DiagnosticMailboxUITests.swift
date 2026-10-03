import XCTest

final class DiagnosticMailboxUITests: XCTestCase {
    @MainActor
    func test_mailbox_opt_in_keeps_welcome_screen_lazy_without_open_flag() {
        let app = XCUIApplication()
        app.launchArguments = ["--environment", "local", "--usb-diagnostics"]
        app.launch()

        XCTAssertTrue(app.buttons["open-webview"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["close-webview"].exists)
    }

    @MainActor
    func test_explicit_diagnostic_cli_open_flag_opens_local_webview() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--environment", "local",
            "--usb-diagnostics",
            "--usb-diagnostics-open-webview",
        ]
        app.launch()

        XCTAssertTrue(app.buttons["close-webview"].waitForExistence(timeout: 5))
    }
}
