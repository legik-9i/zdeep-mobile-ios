//
//  ZDEEPUITests.swift
//  ZDEEPUITests
//
//  Created by Олег on 02.10.2026.
//

import XCTest

final class ZDEEPUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testWelcomeScreenOpensClosesAndReopensSession() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--environment", "local"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Подключите ваш Zeekr"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Сканировать QR-код"].exists)
        XCTAssertFalse(app.staticTexts["current-environment"].exists)
        XCTAssertFalse(app.staticTexts["Hello, world3!"].exists)

        DebugPanelTestActions.openWebView(app)
        XCTAssertTrue(app.buttons["debug-button"].waitForExistence(timeout: 3))
        DebugPanelTestActions.closeWebView(app)
        XCTAssertTrue(app.staticTexts["Подключите ваш Zeekr"].waitForExistence(timeout: 3))

        DebugPanelTestActions.openWebView(app)
        XCTAssertTrue(app.buttons["debug-button"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testTestEnvironmentWelcomeScreenDoesNotLoadWebUntilOpened() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--environment", "test"]
        app.launch()

        let welcomeTitle = app.staticTexts["Подключите ваш Zeekr"]
        XCTAssertTrue(welcomeTitle.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["open-webview"].exists)
        XCTAssertFalse(app.buttons["close-webview"].exists)
        app.buttons["debug-button"].tap()
        let webViewState = app.descendants(matching: .any)["webview-state"]
        XCTAssertTrue(webViewState.waitForExistence(timeout: 3))
        XCTAssertTrue(webViewState.label.contains("Закрыт"))
        XCTAssertTrue(app.buttons["test"].isSelected)
        app.buttons["close-debug-panel"].tap()

        DebugPanelTestActions.openWebView(app)
        XCTAssertTrue(app.buttons["debug-button"].waitForExistence(timeout: 3))
        DebugPanelTestActions.closeWebView(app)
        XCTAssertTrue(welcomeTitle.waitForExistence(timeout: 3))

        DebugPanelTestActions.openWebView(app)
        XCTAssertTrue(app.buttons["debug-button"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testAccessibilityTextSizeKeepsWelcomeActionsReachable() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--environment", "local",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launch()

        XCTAssertTrue(app.staticTexts["Подключите ваш Zeekr"].waitForExistence(timeout: 5))
        app.swipeUp()

        let scanButton = app.buttons["Сканировать QR-код"]
        let helpButton = app.buttons["Как подключить автомобиль"]
        XCTAssertTrue(scanButton.waitForExistence(timeout: 3))
        XCTAssertTrue(helpButton.waitForExistence(timeout: 3))
        XCTAssertTrue(scanButton.isHittable)
        XCTAssertTrue(helpButton.isHittable)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "welcome-accessibility-actions"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
