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

        XCTAssertTrue(app.staticTexts["current-environment"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["open-webview"].exists)

        app.buttons["open-webview"].tap()
        XCTAssertTrue(app.buttons["close-webview"].waitForExistence(timeout: 2))
        app.buttons["close-webview"].tap()
        XCTAssertTrue(app.buttons["open-webview"].waitForExistence(timeout: 2))

        app.buttons["open-webview"].tap()
        XCTAssertTrue(app.buttons["close-webview"].waitForExistence(timeout: 2))
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
