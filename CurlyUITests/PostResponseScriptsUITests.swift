import AppKit
import XCTest

@MainActor
final class PostResponseScriptsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testRealEngineUpdatesGlobalVariableAndShowsPassedStatus() {
        let app = launchApp()
        defer { app.terminate() }

        configureRequest(in: app)
        configureScript(
            "curly.variables.global.set(\"captured_status\", String(curly.response.status)); console.log(\"stored\");",
            in: app
        )
        triggerRun(app)

        let status = app.descendants(matching: .any)["post-response-script-status"].firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil(timeout: 5) { self.text(of: status).contains("Passed") })
        XCTAssertTrue(app.staticTexts["response-status-value"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertEqual(text(of: app.staticTexts["response-status-value"].firstMatch), "200")
        XCTAssertTrue(app.descendants(matching: .any)["post-response-script-console"].firstMatch.exists)

        openVariables(in: app)
        XCTAssertTrue(app.textFields.matching(NSPredicate(format: "value == %@", "captured_status")).firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.textFields.matching(NSPredicate(format: "value == %@", "200")).firstMatch.waitForExistence(timeout: 3))
    }

    func testScriptFailureKeepsHTTPStatusAndDoesNotCommitStagedWrite() {
        let app = launchApp()
        defer { app.terminate() }

        configureRequest(in: app)
        configureScript(
            "curly.variables.global.set(\"must_not_exist\", \"value\"); throw new Error(\"intentional failure\");",
            in: app
        )
        triggerRun(app)

        let status = app.descendants(matching: .any)["post-response-script-status"].firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil(timeout: 5) { self.text(of: status).contains("Failed") })
        let responseStatus = app.staticTexts["response-status-value"].firstMatch
        XCTAssertTrue(responseStatus.waitForExistence(timeout: 3))
        XCTAssertEqual(text(of: responseStatus), "200")
        XCTAssertTrue(app.descendants(matching: .any)["post-response-script-diagnostic"].firstMatch.exists)

        openVariables(in: app)
        XCTAssertFalse(app.textFields.matching(NSPredicate(format: "value == %@", "must_not_exist")).firstMatch.exists)
    }

    func testNestedJSONResponseStoresStringNumberAndBooleanValues() {
        let app = launchApp()
        defer { app.terminate() }

        configureRequest(in: app, url: "http://127.0.0.1:9999/json/complex")
        configureScript(
            """
            const body = curly.response.json();
            curly.variables.global.set("deep_number", body.nested_object.level1.level2.level3.level4.number);
            curly.variables.global.set("first_score", body.array_of_objects[0].scores[1]);
            curly.variables.global.set("is_active", body.scalars.boolean_true);
            """,
            in: app
        )
        triggerRun(app)

        let status = app.descendants(matching: .any)["post-response-script-status"].firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil(timeout: 5) { self.text(of: status).contains("Passed") })
        XCTAssertEqual(text(of: app.staticTexts["response-status-value"].firstMatch), "200")

        openVariables(in: app)
        for expected in ["deep_number", "42", "first_score", "95", "is_active", "true"] {
            XCTAssertTrue(
                app.textFields.matching(NSPredicate(format: "value == %@", expected)).firstMatch.waitForExistence(timeout: 3),
                "Expected the variables modal to contain \(expected)."
            )
        }
    }

    func testRealPostScriptUpdatesLeafUsedByNestedHeaderOnNextRun() {
        let app = launchApp()
        defer { app.terminate() }

        openVariables(in: app)
        createVariable(name: "token", value: "before", in: app)
        createVariable(name: "authorization", value: "Bearer {{token}}", in: app)
        app.typeKey(.escape, modifierFlags: [])

        let urlField = app.textFields["url-input-field"].firstMatch
        replaceText(
            """
            curl -X POST http://127.0.0.1:9999/post \
              -H "Content-Type: application/json" \
              -H "Authorization: {{authorization}}" \
              -d '{"nextToken":"after"}'
            """,
            in: urlField
        )
        XCTAssertTrue(waitUntil(timeout: 3) {
            urlField.value as? String == "http://127.0.0.1:9999/post"
        })

        revealPostResponseScript(in: app)
        configureScript(
            """
            const body = curly.response.json();
            curly.variables.global.set("token", body.json.nextToken);
            """,
            in: app
        )
        triggerRun(app)

        let status = app.descendants(matching: .any)["post-response-script-status"].firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil(timeout: 5) { self.text(of: status).contains("Passed") })
        let responseEditor = app.textViews["response-json-pretty-text-view"].firstMatch
        XCTAssertTrue(responseEditor.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil(timeout: 5) {
            self.text(of: responseEditor).contains("Bearer before")
        })

        openVariables(in: app)
        XCTAssertTrue(
            app.textFields.matching(NSPredicate(format: "value == %@", "Bearer {{token}}"))
                .firstMatch.waitForExistence(timeout: 3)
        )
        XCTAssertTrue(
            app.textFields.matching(NSPredicate(format: "value == %@", "after"))
                .firstMatch.waitForExistence(timeout: 3)
        )
        app.typeKey(.escape, modifierFlags: [])

        triggerRun(app)
        XCTAssertTrue(waitUntil(timeout: 5) {
            self.text(of: responseEditor).contains("Bearer after")
        })
        XCTAssertTrue(waitUntil(timeout: 5) { self.text(of: status).contains("Passed") })
    }

    func testOpenVariableEditorAdoptsPostScriptWriteWithoutRestoringStaleValue() {
        let app = launchApp()
        defer { app.terminate() }

        openVariables(in: app)
        createVariable(name: "token", value: "before", in: app)
        app.typeKey(.escape, modifierFlags: [])

        configureRequest(in: app, url: "http://127.0.0.1:9999/delay/5")
        configureScript(
            #"curly.variables.global.set("token", "after");"#,
            in: app
        )
        triggerRun(app)
        openVariables(in: app)

        let beforeField = app.textFields.matching(NSPredicate(format: "value == %@", "before")).firstMatch
        XCTAssertTrue(beforeField.waitForExistence(timeout: 2))
        beforeField.click()
        let afterField = app.textFields.matching(NSPredicate(format: "value == %@", "after")).firstMatch
        XCTAssertTrue(
            afterField.waitForExistence(timeout: 8),
            "The open editor should adopt the script's committed value when it has no local edit."
        )
        app.typeKey(.tab, modifierFlags: [])
        app.typeKey(.escape, modifierFlags: [])

        openVariables(in: app)
        XCTAssertTrue(
            app.textFields.matching(NSPredicate(format: "value == %@", "after"))
                .firstMatch.waitForExistence(timeout: 3)
        )
        XCTAssertFalse(app.textFields.matching(NSPredicate(format: "value == %@", "before")).firstMatch.exists)
    }

    func testInvalidScriptPreventsDispatchAndShowsInlineDiagnostic() {
        let app = launchApp()
        defer { app.terminate() }

        configureRequest(in: app)
        configureScript("const = ;", in: app)
        triggerRun(app)

        let status = app.descendants(matching: .any)["post-response-script-status"].firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil(timeout: 5) { self.text(of: status).contains("Invalid") })
        XCTAssertTrue(app.descendants(matching: .any)["post-response-script-diagnostic"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["response-body-text"].firstMatch.exists)
    }

    func testDoubleClickSelectsOnlyJavaScriptMember() {
        let app = launchApp()
        defer { app.terminate() }

        configureRequest(in: app)
        let source = #"curly.variables.global.set("selection_probe", "value");"#
        configureScript(source, in: app)

        let editor = app.textViews["post-response-script-editor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 3))

        let font = NSFont.monospacedSystemFont(
            ofSize: NSFont.systemFontSize,
            weight: .regular
        )
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let prefixWidth = (#"curly.variables."# as NSString).size(withAttributes: attributes).width
        let memberWidth = ("global" as NSString).size(withAttributes: attributes).width
        let memberCenter = editor.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            .withOffset(CGVector(dx: 8 + prefixWidth + memberWidth / 2, dy: 16))

        memberCenter.doubleClick()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("request", forType: .string)
        editor.typeKey("v", modifierFlags: .command)

        XCTAssertTrue(
            waitUntil(timeout: 3) {
                self.text(of: editor) == #"curly.variables.request.set("selection_probe", "value");"#
            },
            "Double-clicking global should replace only that JavaScript member. Actual editor value: \(text(of: editor))"
        )
    }

    func testScriptAPIReferenceOpensFromCompactButton() {
        let app = launchApp()
        defer { app.terminate() }

        configureRequest(in: app)

        let apiButton = app.buttons["post-response-script-api-button"].firstMatch
        XCTAssertTrue(apiButton.waitForExistence(timeout: 3))
        XCTAssertFalse(app.descendants(matching: .any)["post-response-script-api-reference"].firstMatch.exists)

        apiButton.click()

        let reference = app.descendants(matching: .any)["post-response-script-api-reference"].firstMatch
        XCTAssertTrue(reference.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["curly.response.json()"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["curly.variables.global.set(name, value)"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["console.error(value)"].firstMatch.exists)
    }

    func testRevertingScriptClearsStaleUndoHistory() {
        let app = launchPersistentApp()
        defer { app.terminate() }

        configureRequest(in: app)
        replaceText("Undo Script", in: app.textFields["request-name-field"].firstMatch)
        let savedSource = #"console.log("saved");"#
        configureScript(savedSource, in: app)
        let saveButton = app.buttons["save-request-button"].firstMatch
        XCTAssertTrue(saveButton.waitForExistence(timeout: 3))
        XCTAssertTrue(waitUntil(timeout: 3) { saveButton.isEnabled })
        saveButton.click()

        let row = app.buttons["Undo Script"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        let editor = app.textViews["post-response-script-editor"].firstMatch
        replaceText(String(repeating: "x", count: 200), in: editor)
        row.rightClick()
        let revert = app.menuItems["Revert Draft"].firstMatch
        XCTAssertTrue(revert.waitForExistence(timeout: 3))
        revert.click()
        XCTAssertTrue(waitUntil(timeout: 3) { self.text(of: editor) == savedSource })

        editor.click()
        editor.typeKey("z", modifierFlags: .command)

        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertEqual(text(of: editor), savedSource)
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-mode"]
        app.launch()
        if !app.textFields["url-input-field"].firstMatch.waitForExistence(timeout: 5) {
            app.activate()
            app.typeKey("0", modifierFlags: .command)
        }
        return app
    }

    private func launchPersistentApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-test-mode",
            "--ui-test-enable-persistence",
            "--ui-test-library-id",
            UUID().uuidString
        ]
        app.launch()
        XCTAssertTrue(app.textFields["url-input-field"].firstMatch.waitForExistence(timeout: 5))
        return app
    }

    private func configureRequest(
        in app: XCUIApplication,
        url: String = "http://127.0.0.1:9999/json"
    ) {
        let urlField = app.textFields["url-input-field"].firstMatch
        replaceText(url, in: urlField)

        let bodyRow = app.buttons["request-accordion-body"].firstMatch
        XCTAssertTrue(bodyRow.waitForExistence(timeout: 3))
        bodyRow.click()

        let scriptRow = app.buttons["request-accordion-post-response script"].firstMatch
        XCTAssertTrue(scriptRow.waitForExistence(timeout: 3))
        if !scriptRow.isHittable {
            app.scrollViews.firstMatch.swipeUp()
        }
        scriptRow.click()
    }

    private func configureScript(_ source: String, in app: XCUIApplication) {
        let checkbox = app.checkBoxes["post-response-script-enabled"].firstMatch
        XCTAssertTrue(checkbox.waitForExistence(timeout: 3))
        checkbox.click()

        let editor = app.textViews["post-response-script-editor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["post-response-script-api-button"].firstMatch.exists)
        let requestScrollView = app.scrollViews["request-pane-scroll-view"].firstMatch
        for _ in 0..<3 where !editor.isHittable {
            requestScrollView.swipeUp()
        }
        XCTAssertTrue(editor.isHittable)
        replaceText(source, in: editor)
    }

    private func revealPostResponseScript(in app: XCUIApplication) {
        let checkbox = app.checkBoxes["post-response-script-enabled"].firstMatch
        if checkbox.exists {
            return
        }
        let row = app.buttons["request-accordion-post-response script"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        if !row.isHittable {
            app.scrollViews["request-pane-scroll-view"].firstMatch.swipeUp()
        }
        row.click()
        XCTAssertTrue(checkbox.waitForExistence(timeout: 3))
    }

    private func openVariables(in app: XCUIApplication) {
        let menuItem = app.menuItems["Manage Variables…"].firstMatch
        XCTAssertTrue(menuItem.waitForExistence(timeout: 3))
        menuItem.click()
        XCTAssertTrue(app.staticTexts["Variables"].firstMatch.waitForExistence(timeout: 3))
    }

    private func createVariable(name: String, value: String, in app: XCUIApplication) {
        let addButton = app.buttons["Add Global Variable"].firstMatch
        XCTAssertTrue(addButton.waitForExistence(timeout: 3))
        let nameFields = app.textFields.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "variable-name-field-")
        )
        let existingIdentifiers = Set(nameFields.allElementsBoundByIndex.map(\.identifier))
        addButton.click()
        XCTAssertTrue(waitUntil(timeout: 3) {
            nameFields.allElementsBoundByIndex.contains { !existingIdentifiers.contains($0.identifier) }
        })
        guard let nameField = nameFields.allElementsBoundByIndex.first(where: {
            !existingIdentifiers.contains($0.identifier)
        }) else {
            return XCTFail("Expected a variable draft.")
        }
        let valueIdentifier = nameField.identifier.replacingOccurrences(
            of: "variable-name-field-",
            with: "variable-value-field-"
        )
        let valueField = app.textFields[valueIdentifier].firstMatch
        nameField.click()
        nameField.typeText(name)
        valueField.click()
        valueField.typeText(value)
        app.typeKey(.tab, modifierFlags: [])
        XCTAssertTrue(
            app.textFields.matching(NSPredicate(format: "value == %@", name)).firstMatch
                .waitForExistence(timeout: 3)
        )
    }

    private func replaceText(_ text: String, in element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 3))
        element.click()
        element.typeKey("a", modifierFlags: .command)
        element.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        element.typeKey("v", modifierFlags: .command)
    }

    private func triggerRun(_ app: XCUIApplication) {
        app.activate()
        app.typeKey(.return, modifierFlags: .command)
    }

    private func text(of element: XCUIElement) -> String {
        if let value = element.value as? String, !value.isEmpty { return value }
        return element.label
    }

    private func waitUntil(timeout: TimeInterval, condition: @escaping () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return condition()
    }
}
