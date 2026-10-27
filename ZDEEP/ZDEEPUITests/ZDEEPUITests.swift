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
    func testWelcomeScreenRemainsVisibleAcrossPreparedWebSessionLifecycle() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--environment", "local", "--ui-test-empty-binding"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Подключите ваш Zeekr"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Сканировать QR-код"].exists)
        XCTAssertFalse(app.staticTexts["current-environment"].exists)
        XCTAssertFalse(app.staticTexts["Hello, world3!"].exists)

        DebugPanelTestActions.openWebView(app)
        DebugPanelTestActions.assertWebViewOpen(app)
        DebugPanelTestActions.closeWebView(app)
        XCTAssertTrue(app.staticTexts["Подключите ваш Zeekr"].waitForExistence(timeout: 3))

        DebugPanelTestActions.openWebView(app)
        DebugPanelTestActions.assertWebViewOpen(app)
    }

    @MainActor
    func testLocalEnvironmentWelcomeRemainsVisibleWithPreparedHiddenWeb() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--environment", "local", "--ui-test-empty-binding"]
        app.launch()

        let welcomeTitle = app.staticTexts["Подключите ваш Zeekr"]
        XCTAssertTrue(welcomeTitle.waitForExistence(timeout: 5))
        app.buttons["debug-button"].tap()
        let webViewState = app.descendants(matching: .any)["webview-state"]
        XCTAssertTrue(webViewState.waitForExistence(timeout: 3))
        let prepared = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", "Подготовлен", "Загрузка"),
            object: webViewState
        )
        XCTAssertEqual(XCTWaiter.wait(for: [prepared], timeout: 10), .completed)
        XCTAssertTrue(app.staticTexts["Подключите ваш Zeekr"].exists)
        let hiddenWebView = app.webViews.firstMatch
        XCTAssertTrue(hiddenWebView.exists)
        XCTAssertFalse(hiddenWebView.isHittable)
        XCTAssertTrue(app.buttons["local"].isSelected)
        app.buttons["close-debug-panel"].tap()
    }

    @MainActor
    func testAccessibilityTextSizeKeepsWelcomeActionsReachable() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--environment", "local",
            "--ui-test-empty-binding",
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
    func testWelcomeHelpOpensAboutAndDismissesAfterLoadFailure() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--environment", "local",
            "--ui-test-empty-binding",
            "--web-url", "http://127.0.0.1:1",
        ]
        app.launch()

        XCTAssertTrue(app.buttons["Как подключить автомобиль"].waitForExistence(timeout: 10))
        app.buttons["Как подключить автомобиль"].tap()

        let loadError = app.staticTexts["Не удалось загрузить страницу"]
        XCTAssertTrue(loadError.waitForExistence(timeout: 10))

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).press(
            forDuration: 0.1,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
        )
        XCTAssertTrue(loadError.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Как подключить автомобиль"].isHittable)
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
