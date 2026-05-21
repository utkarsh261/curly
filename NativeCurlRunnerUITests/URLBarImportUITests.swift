import XCTest

@MainActor
final class URLBarImportUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testURLBarSimpleCurlInputParsesURLAndEnablesRun() throws {
        let (app, urlField) = launchWithURLBarInput("curl https://www.example.com")

        XCTAssertTrue(
            waitUntil(timeout: 3) {
                urlField.value as? String == "https://www.example.com"
            },
            "Pasting a simple cURL should replace the request composer text with the parsed URL."
        )

        let runButton = app.buttons["run-button"].firstMatch
        XCTAssertTrue(runButton.waitForExistence(timeout: 2), "Run button should exist.")
        XCTAssertTrue(runButton.isEnabled, "Run should be enabled after a valid cURL import.")
        XCTAssertFalse(app.staticTexts["Request Issue"].exists, "A valid cURL import should not show a request issue.")
    }

    func testURLBarPlainURLInputKeepsURLAndEnablesRun() throws {
        let (app, urlField) = launchWithURLBarInput("https://www.example.com")

        XCTAssertTrue(
            waitUntil(timeout: 3) {
                urlField.value as? String == "https://www.example.com"
            },
            "Pasting a plain URL should keep the URL in the request composer field."
        )

        let runButton = app.buttons["run-button"].firstMatch
        XCTAssertTrue(runButton.waitForExistence(timeout: 2), "Run button should exist.")
        XCTAssertTrue(runButton.isEnabled, "Run should be enabled after entering a valid URL.")
    }

    func testImportedCurlHeadersAreUsedWhenRunningRequest() throws {
        let (app, _) = launchWithURLBarInput(
            "curl https://api.example.com/users -H 'Accept: application/json' -H 'X-Trace: abc123'",
            usesStubExecutor: true
        )

        let runButton = app.buttons["run-button"].firstMatch
        XCTAssertTrue(runButton.waitForExistence(timeout: 2), "Run button should exist.")
        XCTAssertTrue(runButton.isEnabled, "Run should be enabled after importing a valid cURL.")
        triggerRun(app)

        let responseBody = app.staticTexts["response-body-text"].firstMatch
        XCTAssertTrue(responseBody.waitForExistence(timeout: 5), "Response body should render after the request completes.")
        XCTAssertTrue(
            waitUntil(timeout: 5) {
                (responseBody.value as? String)?.contains("Accept=application/json") == true ||
                    responseBody.label.contains("Accept=application/json")
            },
            "The response should reflect the imported Accept header sent by the executor."
        )
        XCTAssertTrue(
            waitUntil(timeout: 5) {
                (responseBody.value as? String)?.contains("X-Trace=abc123") == true ||
                    responseBody.label.contains("X-Trace=abc123")
            },
            "The response should reflect the imported X-Trace header sent by the executor."
        )
    }

    func testHeadCurlImportsAndRunsAsHead() throws {
        let (app, urlField) = launchWithURLBarInput(
            "curl -I https://www.example.com",
            usesStubExecutor: true
        )

        XCTAssertTrue(
            waitUntil(timeout: 3) {
                urlField.value as? String == "https://www.example.com"
            },
            "Pasting a HEAD cURL should populate the parsed URL."
        )

        let runButton = app.buttons["run-button"].firstMatch
        XCTAssertTrue(runButton.waitForExistence(timeout: 2))
        XCTAssertTrue(runButton.isEnabled)
        triggerRun(app)

        let responseBody = app.staticTexts["response-body-text"].firstMatch
        XCTAssertTrue(responseBody.waitForExistence(timeout: 5))
        XCTAssertTrue(
            waitUntil(timeout: 5) {
                responseBody.label.contains("method=HEAD") ||
                    (responseBody.value as? String)?.contains("method=HEAD") == true
            },
            "The stub executor response should show that the imported request ran as HEAD."
        )
    }

    func testLocationCurlImportsWithWarningAndRunEnabled() throws {
        let (app, urlField) = launchWithURLBarInput("curl --location https://www.example.com")

        XCTAssertTrue(
            waitUntil(timeout: 3) {
                urlField.value as? String == "https://www.example.com"
            },
            "Pasting a --location cURL should populate the parsed URL."
        )

        XCTAssertTrue(app.staticTexts["Request Warning"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Redirect-following from `--location` is not represented yet."].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["run-button"].firstMatch.isEnabled)
    }

    func testEmptyStartupDisablesRunAndMenuBarRerun() throws {
        let app = launchEmptyApp()

        XCTAssertFalse(app.buttons["run-button"].firstMatch.isEnabled)
        openMenuBarExtra(app: app)
        XCTAssertFalse(menuElement("Rerun Last Request", app: app).isEnabled)
    }

    func testMenuBarShowsFailureSummaryAndRerunAvailability() throws {
        let (app, _) = launchWithURLBarInput(
            "curl https://api.example.com/failing",
            usesStubExecutor: true,
            usesFailingExecutor: true
        )

        triggerRun(app)
        XCTAssertTrue(
            waitUntil(timeout: 5) {
                app.staticTexts["Request Issue"].exists
            },
            "Transport failure should be shown inline."
        )

        openMenuBarExtra(app: app)
        XCTAssertTrue(menuElement("UI test transport failure", app: app).waitForExistence(timeout: 3))
        XCTAssertTrue(menuElement("Rerun Last Request", app: app).isEnabled)
    }

    func testMenuBarEndToEndRerunAndClearSession() throws {
        let (app, urlField) = launchWithURLBarInput(
            "curl https://api.example.com/users -H 'X-Trace: abc123'",
            usesStubExecutor: true
        )

        triggerRun(app)
        let responseBody = app.staticTexts["response-body-text"].firstMatch
        XCTAssertTrue(responseBody.waitForExistence(timeout: 5))
        XCTAssertTrue(responseBody.label.contains("X-Trace=abc123") || (responseBody.value as? String)?.contains("X-Trace=abc123") == true)

        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(waitUntil(timeout: 3) { app.windows.count == 0 }, "Closing the window should leave the app running.")

        openMenuBarExtra(app: app)
        menuElement("Open Window", app: app).click()
        ensureMainWindowIsOpen(app: app, urlField: urlField)
        XCTAssertEqual(urlField.value as? String, "https://api.example.com/users")

        openMenuBarExtra(app: app)
        menuElement("Rerun Last Request", app: app).click()
        XCTAssertTrue(responseBody.waitForExistence(timeout: 5))

        openMenuBarExtra(app: app)
        menuElement("Clear Workspace", app: app).click()
        XCTAssertTrue(
            waitUntil(timeout: 3) {
                (urlField.value as? String)?.isEmpty == true
            },
            "New Workspace from the menu bar should clear the request URL."
        )
        XCTAssertFalse(app.buttons["run-button"].firstMatch.isEnabled)
    }

    private func launchWithURLBarInput(
        _ input: String,
        usesStubExecutor: Bool = false,
        usesFailingExecutor: Bool = false
    ) -> (XCUIApplication, XCUIElement) {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-url-bar-input", input]
        if usesStubExecutor {
            app.launchArguments.append("--ui-test-stub-executor")
        }
        if usesFailingExecutor {
            app.launchArguments.append("--ui-test-stub-failure")
        }
        app.launch()

        let urlField = app.textFields["url-input-field"].firstMatch
        ensureMainWindowIsOpen(app: app, urlField: urlField)
        return (app, urlField)
    }

    private func launchEmptyApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()

        let urlField = app.textFields["url-input-field"].firstMatch
        ensureMainWindowIsOpen(app: app, urlField: urlField)
        return app
    }

    private func openMenuBarExtra(app: XCUIApplication) {
        let systemUIServer = XCUIApplication(bundleIdentifier: "com.apple.systemuiserver")
        let candidates = [
            app.menuBars.statusItems["menu-bar-status-item"].firstMatch,
            systemUIServer.menuBars.statusItems["menu-bar-status-item"].firstMatch,
            app.menuBars.statusItems["Idle"].firstMatch,
            app.menuBars.statusItems["Ready"].firstMatch,
            app.menuBars.statusItems["Status 200"].firstMatch,
            app.menuBars.statusItems["Failed"].firstMatch,
            systemUIServer.menuBars.statusItems["Idle"].firstMatch,
            systemUIServer.menuBars.statusItems["Ready"].firstMatch,
            systemUIServer.menuBars.statusItems["Status 200"].firstMatch,
            systemUIServer.menuBars.statusItems["Failed"].firstMatch
        ]

        for candidate in candidates where candidate.waitForExistence(timeout: 0.5) {
            candidate.click()
            return
        }

        XCTFail("Could not find the NativeCurlRunner menu bar status item.")
    }

    private func menuElement(_ title: String, app: XCUIApplication) -> XCUIElement {
        let systemUIServer = XCUIApplication(bundleIdentifier: "com.apple.systemuiserver")
        let candidates = [
            app.buttons[title].firstMatch,
            app.menuItems[title].firstMatch,
            app.staticTexts[title].firstMatch,
            systemUIServer.buttons[title].firstMatch,
            systemUIServer.menuItems[title].firstMatch,
            systemUIServer.staticTexts[title].firstMatch
        ]

        for candidate in candidates where candidate.exists {
            return candidate
        }

        return candidates[0]
    }

    private func triggerRun(_ app: XCUIApplication) {
        let runButton = app.buttons["run-button"].firstMatch
        XCTAssertTrue(runButton.waitForExistence(timeout: 2), "Run button should exist before triggering the request.")
        XCTAssertTrue(runButton.isEnabled, "Run button should be enabled before triggering the request.")
        app.activate()
        app.typeKey(.return, modifierFlags: .command)
    }

    private func ensureMainWindowIsOpen(app: XCUIApplication, urlField: XCUIElement) {
        if urlField.waitForExistence(timeout: 5) {
            return
        }

        app.activate()
        app.typeKey("0", modifierFlags: .command)
        XCTAssertTrue(urlField.waitForExistence(timeout: 5), "The request composer URL field should exist.")
    }

    private func waitUntil(timeout: TimeInterval, condition: @escaping () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return condition()
    }
}
