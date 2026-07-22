import AppKit
import Foundation
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

    func testRealPasteSimpleCurlParsesURLAndEnablesRun() throws {
        let app = launchEmptyApp()
        defer { app.terminate() }

        let urlField = app.textFields["url-input-field"].firstMatch
        paste("curl https://www.example.com", into: urlField)

        XCTAssertTrue(
            waitUntil(timeout: 3) {
                urlField.value as? String == "https://www.example.com"
            },
            "A real paste of a simple cURL should show the parsed URL, not the literal cURL command."
        )
        XCTAssertTrue(app.buttons["run-button"].firstMatch.isEnabled)
        XCTAssertFalse(app.staticTexts["Request Issue"].exists)
    }

    func testRealPasteMultilineCurlWithContinuationsParsesURLAndBody() throws {
        let app = launchEmptyApp()
        defer { app.terminate() }

        let urlField = app.textFields["url-input-field"].firstMatch
        paste(
            """
            curl -X PUT http://localhost:9999/put \\
              -H "Content-Type: text/plain" \\
              -d "some raw text body"
            """,
            into: urlField
        )

        let didImportMultilineCurl = waitUntil(timeout: 3) {
            urlField.value as? String == "http://localhost:9999/put"
        }
        XCTAssertTrue(
            didImportMultilineCurl,
            "A real paste of a multiline cURL should show the parsed URL, not \(String(describing: urlField.value))."
        )
        XCTAssertTrue(app.buttons["run-button"].firstMatch.isEnabled)
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

    func testLongURLCanBeHorizontallyScrolledWithMouseWithoutVisibleScrollbar() throws {
        let longURL = "https://example.com/" + String(repeating: "long-path-segment/", count: 20)
        let (app, urlField) = launchWithURLBarInput(longURL)
        defer { app.terminate() }

        urlField.click()
        urlField.typeKey(.leftArrow, modifierFlags: .command)
        urlField.scroll(byDeltaX: -500, deltaY: 0)
        urlField.typeText("X")

        XCTAssertEqual(
            urlField.value as? String,
            "X" + longURL,
            "Scrolling must keep a caret selection instead of selecting the entire URL."
        )

        urlField.typeKey("z", modifierFlags: .command)
        urlField.scroll(byDeltaX: -500, deltaY: 0)
        urlField.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5)).click()
        urlField.typeText("X")

        let editedURL = try XCTUnwrap(urlField.value as? String)
        let insertionLocation = (editedURL as NSString).range(of: "X").location
        XCTAssertGreaterThan(insertionLocation, 20, "Mouse scrolling should expose text beyond the URL field's leading edge.")
        XCTAssertEqual(urlField.descendants(matching: .scrollBar).count, 0)
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

    func testValidationFailureReplacesStatusAndPreservesPreviousResponse() throws {
        let (app, urlField) = launchWithURLBarInput(
            "https://example.com/success",
            usesStubExecutor: true
        )
        defer { app.terminate() }

        triggerRun(app)
        XCTAssertTrue(app.staticTexts["response-body-text"].firstMatch.waitForExistence(timeout: 5))

        let responseStatus = app.staticTexts["response-status-value"].firstMatch
        XCTAssertTrue(responseStatus.waitForExistence(timeout: 3))
        XCTAssertTrue(
            waitUntil(timeout: 3) { self.text(of: responseStatus) == "200" },
            "The successful request should display status 200."
        )

        paste("https://{{missingHost}}/users", into: urlField)
        triggerRun(app)

        XCTAssertTrue(app.staticTexts["Request Issue"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Define missingHost before running this request."].waitForExistence(timeout: 3))
        XCTAssertTrue(
            waitUntil(timeout: 3) { self.text(of: responseStatus) == "Failed" },
            "A validation failure should replace the previous HTTP status."
        )
        XCTAssertTrue(
            app.staticTexts["response-body-text"].firstMatch.waitForExistence(timeout: 3),
            "The previous response should remain inspectable after validation fails."
        )
        XCTAssertTrue(
            app.staticTexts["stale-response-badge"].firstMatch.waitForExistence(timeout: 3),
            "The preserved response should be marked stale."
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

    func testLocalServerJSONPostCurlRunsAndRendersResponseTree() async throws {
        let server = try await UITestLocalHTTPServer.start()
        defer { server.stop() }

        let (app, _) = launchWithURLBarInput(
            #"curl -X POST http://127.0.0.1:9999/post -H "Content-Type: application/json" -d '{"title": "hello", "count": 42}'"#
        )
        defer { app.terminate() }

        triggerRun(app)

        XCTAssertTrue(app.scrollViews["response-json-pretty"].waitForExistence(timeout: 5))
    }

    func testJSONServerErrorOpensInPrettyMode() async throws {
        let server = try await UITestLocalHTTPServer.start()
        defer { server.stop() }

        let (app, _) = launchWithURLBarInput("http://127.0.0.1:9999/status/500")
        defer { app.terminate() }

        triggerRun(app)

        XCTAssertTrue(
            app.scrollViews["response-json-pretty"].waitForExistence(timeout: 5),
            "A JSON response should open in Pretty mode even when the server returns an error status."
        )
        let responseStatus = app.staticTexts["response-status-value"].firstMatch
        XCTAssertTrue(responseStatus.waitForExistence(timeout: 3))
        XCTAssertEqual(text(of: responseStatus), "500")
    }

    func testSettingsToggleAllowsLoopbackTLSRequestEndToEnd() throws {
        let url = "https://localhost:9443/json"
        let (app, urlField) = launchWithURLBarInput(url)
        defer { app.terminate() }

        XCTAssertEqual(urlField.value as? String, url)
        triggerRun(app)

        XCTAssertTrue(
            app.staticTexts["Request Issue"].waitForExistence(timeout: 5),
            "The loopback TLS request should fail before the Settings override is enabled."
        )
        XCTAssertFalse(app.scrollViews["response-json-pretty"].exists)

        setLoopbackTLSVerificationBypass(true, in: app)
        triggerRun(app)

        XCTAssertTrue(
            app.scrollViews["response-json-pretty"].waitForExistence(timeout: 5),
            "The same loopback TLS request should render after enabling the Settings override."
        )
        XCTAssertFalse(app.staticTexts["Request Issue"].exists)
    }

    func testLocalServerPutRawTextCurlRunsAndRendersEchoedBody() async throws {
        let server = try await UITestLocalHTTPServer.start()
        defer { server.stop() }

        let (app, _) = launchWithURLBarInput(
            #"curl -X PUT http://127.0.0.1:9999/put -H "Content-Type: text/plain" -d "some raw text body""#
        )
        defer { app.terminate() }

        triggerRun(app)
        XCTAssertTrue(app.scrollViews["response-json-pretty"].waitForExistence(timeout: 5))
    }

    func testJSONBodyCompactDoesNotCrashOrMoveComments() throws {
        let (app, _) = launchWithURLBarInput(
            """
            curl -X POST https://api.example.com/users \\
              -H "Content-Type: application/json" \\
              -d '{"name":"utk"}'
            """
        )
        defer { app.terminate() }

        let compactButton = app.buttons["request-json-body-editor-compact"].firstMatch
        XCTAssertTrue(compactButton.waitForExistence(timeout: 3))
        compactButton.click()
        XCTAssertTrue(app.buttons["run-button"].firstMatch.exists)
    }

    func testInvalidJSONBodyShowsLocationNavigatesAndStillRuns() throws {
        let invalidBody = """
        {
          "good": true,
          "bad" nope
        }
        """
        let invalidCurl = """
        curl -X POST https://api.example.com/users \\
          -H "Content-Type: application/json" \\
          -d '\(invalidBody)'
        """
        let app = launchEmptyApp(usesStubExecutor: true)
        defer { app.terminate() }
        let urlField = app.textFields["url-input-field"].firstMatch
        paste(invalidCurl, into: urlField)
        XCTAssertTrue(
            waitUntil(timeout: 3) { urlField.value as? String == "https://api.example.com/users" },
            "The invalid body must not prevent the cURL request from importing."
        )

        let editor = app.textViews["request-json-body-editor-text-view"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 3), "The imported JSON body should use the JSON editor.")
        let validationBadge = app.staticTexts["request-json-body-editor-validation-badge"].firstMatch
        XCTAssertTrue(validationBadge.waitForExistence(timeout: 3))
        XCTAssertTrue(
            waitUntil(timeout: 4) { self.text(of: validationBadge).contains("Invalid JSON") },
            "Live validation should mark the imported body invalid after the debounce."
        )

        let formatButton = app.buttons["request-json-body-editor-format"].firstMatch
        let compactButton = app.buttons["request-json-body-editor-compact"].firstMatch
        XCTAssertTrue(formatButton.waitForExistence(timeout: 2))
        XCTAssertTrue(compactButton.waitForExistence(timeout: 2))

        let diagnostic = app.buttons["request-json-body-editor-diagnostic"].firstMatch
        XCTAssertTrue(diagnostic.waitForExistence(timeout: 4), "Invalid JSON should expose an inline diagnostic.")
        XCTAssertTrue(
            text(of: diagnostic).contains("Line 3, column 9 — Expected ':' after the object key."),
            "The diagnostic should identify the first syntax error in the original request body. Got: \(text(of: diagnostic))"
        )

        formatButton.click()
        XCTAssertTrue(diagnostic.exists, "Format should keep and navigate to an invalid JSON diagnostic.")
        compactButton.click()
        XCTAssertTrue(diagnostic.exists, "Compact should keep and navigate to an invalid JSON diagnostic.")

        XCTAssertTrue(app.buttons["run-button"].firstMatch.isEnabled, "Invalid JSON must not block request dispatch.")
        triggerRun(app)
        XCTAssertTrue(
            waitUntil(timeout: 5) {
                let response = app.staticTexts["response-body-text"].firstMatch
                return response.exists && self.text(of: response).contains("body=\(invalidBody)")
            },
            "The request should still reach the executor when its JSON body is invalid."
        )

        diagnostic.click()
        let validCurl = """
        curl -X POST https://api.example.com/users \\
          -H "Content-Type: application/json" \\
          -d '{"good":true,"bad":null}'
        """
        paste(validCurl, into: urlField)
        let replaceButton = app.sheets.buttons["Replace"].firstMatch.exists
            ? app.sheets.buttons["Replace"].firstMatch
            : app.dialogs.buttons["Replace"].firstMatch
        XCTAssertTrue(replaceButton.waitForExistence(timeout: 3))
        replaceButton.click()

        XCTAssertTrue(
            waitUntil(timeout: 4) { !diagnostic.exists },
            "Correcting the body should clear the stale inline diagnostic."
        )
        XCTAssertTrue(
            waitUntil(timeout: 4) { self.text(of: validationBadge).contains("Valid JSON") },
            "The corrected body should validate and no stale result should return."
        )
    }

    func testRapidJSONCorrectionCancelsStaleDiagnostic() throws {
        let app = launchEmptyApp(usesStubExecutor: true)
        defer { app.terminate() }
        let urlField = app.textFields["url-input-field"].firstMatch
        paste(
            """
            curl -X POST https://api.example.com/users \\
              -H "Content-Type: application/json" \\
              -d '{"initial" nope}'
            """,
            into: urlField
        )
        XCTAssertTrue(
            waitUntil(timeout: 3) { urlField.value as? String == "https://api.example.com/users" }
        )

        let editor = app.textViews["request-json-body-editor-text-view"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        let validationBadge = app.staticTexts["request-json-body-editor-validation-badge"].firstMatch
        XCTAssertTrue(validationBadge.waitForExistence(timeout: 3))
        let diagnostic = app.buttons["request-json-body-editor-diagnostic"].firstMatch
        XCTAssertTrue(diagnostic.waitForExistence(timeout: 4))
        diagnostic.click()

        replaceFocusedText(#"{"ready" nope}"#, app: app)
        let correctedBody = #"{"ready":{"nested":true}}"#
        replaceFocusedText(correctedBody, app: app)

        XCTAssertFalse(
            waitUntil(timeout: 1) { diagnostic.exists },
            "The cancelled validation must not publish a diagnostic for superseded text."
        )
        XCTAssertTrue(
            waitUntil(timeout: 3) { self.text(of: validationBadge).contains("Valid JSON") }
        )
        XCTAssertEqual(
            urlField.value as? String,
            "https://api.example.com/users",
            "JSON editor typing must not modify the URL field."
        )

        triggerRun(app)
        XCTAssertTrue(
            waitUntil(timeout: 5) {
                let response = app.staticTexts["response-body-text"].firstMatch
                return response.exists && self.text(of: response).contains("body=\(correctedBody)")
            },
            "The final nested JSON body should be the text that reaches the executor."
        )
    }

    func testReplacingJSONCurlWorkspaceDoesNotCrash() throws {
        let app = launchEmptyApp()
        defer { app.terminate() }

        let urlField = app.textFields["url-input-field"].firstMatch
        paste(
            """
            curl -X POST https://api.example.com/users \\
              -H "Content-Type: application/json" \\
              -d '{"name":"first"}'
            """,
            into: urlField
        )
        XCTAssertTrue(waitUntil(timeout: 3) { urlField.value as? String == "https://api.example.com/users" })

        paste(
            """
            curl -X POST https://api.example.com/projects \\
              -H "Content-Type: application/json" \\
              -d '{"name":"second"}'
            """,
            into: urlField
        )

        let replaceButton = app.sheets.buttons["Replace"].firstMatch.exists
            ? app.sheets.buttons["Replace"].firstMatch
            : app.dialogs.buttons["Replace"].firstMatch
        XCTAssertTrue(replaceButton.waitForExistence(timeout: 3))
        replaceButton.click()

        XCTAssertTrue(
            waitUntil(timeout: 3) {
                urlField.value as? String == "https://api.example.com/projects"
            }
        )
        XCTAssertTrue(app.buttons["run-button"].firstMatch.exists)
    }

    private func launchWithURLBarInput(
        _ input: String,
        usesStubExecutor: Bool = false,
        usesFailingExecutor: Bool = false
    ) -> (XCUIApplication, XCUIElement) {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-mode", "--ui-test-url-bar-input", input]
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

    private func launchEmptyApp(usesStubExecutor: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-mode"]
        if usesStubExecutor {
            app.launchArguments.append("--ui-test-stub-executor")
        }
        app.launch()

        let urlField = app.textFields["url-input-field"].firstMatch
        ensureMainWindowIsOpen(app: app, urlField: urlField)
        return app
    }

    private func paste(_ text: String, into element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 2), "Expected URL field to exist before typing.")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString(text, forType: .string), "Expected to prepare the cURL clipboard payload.")
        element.click()
        element.typeKey("a", modifierFlags: .command)
        element.typeKey("v", modifierFlags: .command)
    }

    private func replaceFocusedText(_ text: String, app: XCUIApplication) {
        app.typeKey("a", modifierFlags: .command)
        app.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString(text, forType: .string))
        app.typeKey("v", modifierFlags: .command)
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

        XCTFail("Could not find the Curly menu bar status item.")
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

    private func setLoopbackTLSVerificationBypass(_ enabled: Bool, in app: XCUIApplication) {
        app.activate()
        app.typeKey(",", modifierFlags: .command)

        let checkbox = app.checkBoxes["allow-insecure-loopback-tls-checkbox"].firstMatch
        XCTAssertTrue(checkbox.waitForExistence(timeout: 4), "The loopback TLS checkbox should exist in Settings.")
        if checkboxIsOn(checkbox) != enabled {
            checkbox.click()
        }
        XCTAssertTrue(
            waitUntil(timeout: 2) { self.checkboxIsOn(checkbox) == enabled },
            "The loopback TLS checkbox should be \(enabled ? "enabled" : "disabled")."
        )

        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.textFields["url-input-field"].firstMatch.waitForExistence(timeout: 3))
    }

    private func checkboxIsOn(_ checkbox: XCUIElement) -> Bool {
        if let number = checkbox.value as? NSNumber {
            return number.boolValue
        }
        guard let value = checkbox.value as? String else {
            return false
        }
        return ["1", "true", "on", "selected"].contains(value.lowercased())
    }

    private func text(of element: XCUIElement) -> String {
        if let value = element.value as? String, !value.isEmpty {
            return value
        }
        return element.label
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

@MainActor
private final class UITestLocalHTTPServer {
    private let process: Process?

    private init(process: Process?) {
        self.process = process
    }

    static func start() async throws -> UITestLocalHTTPServer {
        if await isReachable() {
            return UITestLocalHTTPServer(process: nil)
        }

        let scriptURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("CurlyTests/test_server.py")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [scriptURL.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if await isReachable() {
                return UITestLocalHTTPServer(process: process)
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        process.terminate()
        throw NSError(
            domain: "CurlyUITests.LocalHTTPTestServer",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Local test server did not become reachable on http://localhost:9999."]
        )
    }

    func stop() {
        guard let process, process.isRunning else { return }
        process.terminate()
    }

    private static func isReachable() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:9999/json") else {
            return false
        }

        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}
