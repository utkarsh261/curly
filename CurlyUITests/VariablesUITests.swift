import XCTest
import Foundation
import AppKit

@MainActor
final class VariablesUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testRunBlocksMissingVariableFromURLBeforeDispatch() throws {
        let app = launchWithStubExecutor()
        defer { app.terminate() }

        let urlField = app.textFields["url-input-field"].firstMatch
        XCTAssertTrue(urlField.waitForExistence(timeout: 5))
        replaceText("https://{{missing_host}}/users", in: urlField)

        XCTAssertTrue(app.buttons["run-button"].firstMatch.isEnabled)
        triggerRun(app)

        XCTAssertTrue(app.staticTexts["Request Issue"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Define missing_host before running this request."].firstMatch.waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["response-body-text"].firstMatch.exists)
    }

    func testURLBarRemainsEditableAfterVariableDisplayAppears() throws {
        let app = launchWithStubExecutor()
        defer { app.terminate() }

        let urlField = app.textFields["url-input-field"].firstMatch
        XCTAssertTrue(urlField.waitForExistence(timeout: 5))
        replaceText("https://{{base_url}}/users", in: urlField)

        app.typeKey(.tab, modifierFlags: [])
        XCTAssertTrue(waitUntil(timeout: 3) {
            (urlField.value as? String)?.contains("{{base_url}}") == true
        })

        replaceText("https://example.com", in: urlField)

        XCTAssertTrue(
            waitUntil(timeout: 3) {
                urlField.value as? String == "https://example.com"
            },
            "Expected URL field to be replaceable after variable rendering; actual value: \(urlField.value as? String ?? "<nil>")"
        )
    }

    func testStaleBadgeTracksVariableChangesAndClearsAfterRerun() throws {
        let app = launchWithStubExecutor()
        defer { app.terminate() }

        openVariablesModal(in: app)
        createVariable(name: "host", value: "example.com", addButton: "Add Global Variable", in: app)
        app.typeKey(.escape, modifierFlags: [])

        let urlField = app.textFields["url-input-field"].firstMatch
        replaceText("https://{{host}}/users", in: urlField)
        triggerRun(app)

        XCTAssertTrue(app.staticTexts["response-body-text"].firstMatch.waitForExistence(timeout: 3))
        let staleBadge = app.staticTexts["stale-response-badge"].firstMatch
        XCTAssertFalse(staleBadge.exists)

        openVariablesModal(in: app)
        let valueField = app.textFields.matching(NSPredicate(format: "value == %@", "example.com")).firstMatch
        valueField.click()
        valueField.typeKey("a", modifierFlags: .command)
        valueField.typeText("staging.example.com")
        XCTAssertTrue(
            app.textFields.matching(NSPredicate(format: "value == %@", "staging.example.com")).firstMatch
                .waitForExistence(timeout: 2)
        )
        app.typeKey(.tab, modifierFlags: [])
        app.typeKey(.escape, modifierFlags: [])

        XCTAssertTrue(staleBadge.waitForExistence(timeout: 3))

        triggerRun(app)
        XCTAssertTrue(waitUntil(timeout: 3) { !staleBadge.exists })
    }

    func testBackspaceAtEndOfURLVariableDeletesWholeToken() throws {
        let app = launchWithStubExecutor()
        defer { app.terminate() }

        let urlField = app.textFields["url-input-field"].firstMatch
        XCTAssertTrue(urlField.waitForExistence(timeout: 5))
        replaceText("https://example.com/{{auth}}", in: urlField)

        urlField.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])

        XCTAssertTrue(
            waitUntil(timeout: 3) {
                urlField.value as? String == "https://example.com/"
            },
            "Expected backspace next to a URL variable to delete the whole token; actual value: \(urlField.value as? String ?? "<nil>")"
        )
    }

    func testCanCreateVariableInMiddleBeforeExistingVariable() throws {
        let app = launchWithStubExecutor()
        defer { app.terminate() }

        let urlField = app.textFields["url-input-field"].firstMatch
        XCTAssertTrue(urlField.waitForExistence(timeout: 5))
        replaceText("http://localhost:9999/post?a={{auth}}", in: urlField)

        urlField.typeKey(.leftArrow, modifierFlags: [])
        for _ in 0..<8 {
            urlField.typeKey(.leftArrow, modifierFlags: [])
        }
        for _ in 0..<4 {
            urlField.typeKey(.leftArrow, modifierFlags: .shift)
        }
        urlField.typeText("{{")

        XCTAssertTrue(waitUntil(timeout: 3) {
            urlField.value as? String == "http://localhost:{{/post?a={{auth}}"
        })

        urlField.typeText("port}}")

        XCTAssertTrue(
            waitUntil(timeout: 3) {
                urlField.value as? String == "http://localhost:{{port}}/post?a={{auth}}"
            },
            "Expected the incomplete opening to remain editable before the existing auth variable; actual value: \(urlField.value as? String ?? "<nil>")"
        )
    }

    func testVariablesModalSupportsGlobalVariableCRUD() throws {
        let app = launchWithStubExecutor()
        defer { app.terminate() }

        openVariablesModal(in: app)

        XCTAssertTrue(app.staticTexts["Request"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Global"].firstMatch.exists)

        let addButton = app.buttons["Add Global Variable"].firstMatch
        XCTAssertTrue(addButton.waitForExistence(timeout: 2))
        addButton.click()

        XCTAssertFalse(addButton.isEnabled, "Only one unsaved row should be allowed per section.")
        let draftNameField = variableFields(named: "variable-name-field-", in: app).firstMatch
        let draftValueField = variableFields(named: "variable-value-field-", in: app).firstMatch
        XCTAssertTrue(draftNameField.waitForExistence(timeout: 2))
        XCTAssertTrue(draftValueField.waitForExistence(timeout: 2))

        draftNameField.click()
        draftNameField.typeText("api_host")
        draftValueField.click()
        draftValueField.typeText("https://example.com")
        draftValueField.typeKey(.return, modifierFlags: [])

        let savedNameField = app.textFields.matching(NSPredicate(format: "value == %@", "api_host")).firstMatch
        let savedValueField = app.textFields.matching(NSPredicate(format: "value == %@", "https://example.com")).firstMatch
        XCTAssertTrue(savedNameField.waitForExistence(timeout: 2))
        XCTAssertTrue(savedValueField.waitForExistence(timeout: 2))
        XCTAssertTrue(addButton.isEnabled)

        savedNameField.click()
        savedNameField.typeKey("a", modifierFlags: .command)
        savedNameField.typeText("service_host")
        savedValueField.click()
        XCTAssertTrue(app.textFields.matching(NSPredicate(format: "value == %@", "service_host")).firstMatch.waitForExistence(timeout: 2))

        let deleteButton = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "variable-delete-button-"))
            .firstMatch
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 2))
        deleteButton.click()
        let deleteConfirmations = app.buttons.matching(NSPredicate(format: "label == %@", "Delete"))
        XCTAssertTrue(waitUntil(timeout: 2) {
            deleteConfirmations.allElementsBoundByIndex.contains { $0.isHittable }
        })
        let confirmDelete = try XCTUnwrap(deleteConfirmations.allElementsBoundByIndex.first { $0.isHittable })
        confirmDelete.click()

        XCTAssertTrue(waitUntil(timeout: 2) {
            !app.textFields.matching(NSPredicate(format: "value == %@", "service_host")).firstMatch.exists
        })
    }

    func testVariablesModalShowsInlineValidationAndKeepsDraftEditable() throws {
        let app = launchWithStubExecutor()
        defer { app.terminate() }

        openVariablesModal(in: app)
        app.buttons["Add Request Variable"].firstMatch.click()

        let nameField = variableFields(named: "variable-name-field-", in: app).firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 2))
        nameField.click()
        nameField.typeText("bad name")
        nameField.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(app.staticTexts["variable-validation-message"].firstMatch.waitForExistence(timeout: 2))
        XCTAssertTrue(nameField.exists)
        XCTAssertFalse(app.buttons["Add Request Variable"].firstMatch.isEnabled)
    }

    func testVariablesModalUsesCompactAlignedTableLayout() throws {
        let app = launchWithStubExecutor()
        defer { app.terminate() }

        openVariablesModal(in: app)

        let title = app.staticTexts["Variables"].firstMatch
        let subtitle = app.staticTexts["Changes save automatically."].firstMatch
        let requestAdd = app.buttons["Add Request Variable"].firstMatch
        let globalAdd = app.buttons["Add Global Variable"].firstMatch
        let emptyGlobal = app.staticTexts["No global variables"].firstMatch
        XCTAssertTrue(title.exists)
        XCTAssertTrue(subtitle.exists)
        XCTAssertTrue(requestAdd.exists)
        XCTAssertTrue(globalAdd.exists)
        XCTAssertTrue(emptyGlobal.exists)

        XCTAssertEqual(requestAdd.frame.maxX, globalAdd.frame.maxX, accuracy: 2)
        XCTAssertLessThan(emptyGlobal.frame.maxY - title.frame.minY, 360)

        requestAdd.click()
        let nameField = variableFields(named: "variable-name-field-", in: app).firstMatch
        let valueField = variableFields(named: "variable-value-field-", in: app).firstMatch
        let deleteButton = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "variable-delete-button-"))
            .firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 2))
        XCTAssertTrue(valueField.waitForExistence(timeout: 2))
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 2))

        XCTAssertEqual(nameField.frame.minY, valueField.frame.minY, accuracy: 1)
        XCTAssertLessThanOrEqual(nameField.frame.height, 24)
        XCTAssertGreaterThan(valueField.frame.width, nameField.frame.width * 1.5)
        XCTAssertLessThan(deleteButton.frame.width, 44)

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Variables compact table"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testVariablesModalExpandsToShowTypicalFiveRowSetWithoutClipping() throws {
        let app = launchWithStubExecutor()
        defer { app.terminate() }

        openVariablesModal(in: app)
        createVariable(name: "auth", value: "some_auth", addButton: "Add Request Variable", in: app)
        createVariable(name: "global_var", value: "global_value", addButton: "Add Global Variable", in: app)
        createVariable(name: "port", value: "9999", addButton: "Add Global Variable", in: app)
        createVariable(name: "localhost", value: "localhost", addButton: "Add Global Variable", in: app)
        createVariable(name: "version", value: "v1", addButton: "Add Global Variable", in: app)

        let lastValueField = app.textFields.matching(NSPredicate(format: "value == %@", "v1")).firstMatch
        let modalScrollView = app.scrollViews["variables-modal-overlay"].firstMatch
        XCTAssertTrue(lastValueField.waitForExistence(timeout: 2))
        XCTAssertTrue(modalScrollView.waitForExistence(timeout: 2))
        XCTAssertLessThanOrEqual(lastValueField.frame.maxY, modalScrollView.frame.maxY - 8)

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Variables five row table"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func launchWithStubExecutor() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-mode", "--ui-test-stub-executor"]
        app.launch()
        if !app.textFields["url-input-field"].firstMatch.waitForExistence(timeout: 5) {
            app.activate()
            app.typeKey("0", modifierFlags: .command)
        }
        return app
    }

    private func openVariablesModal(in app: XCUIApplication) {
        let manageVariables = app.menuItems["Manage Variables…"].firstMatch
        XCTAssertTrue(manageVariables.waitForExistence(timeout: 2))
        manageVariables.click()
        XCTAssertTrue(app.staticTexts["Variables"].firstMatch.waitForExistence(timeout: 3))
    }

    private func variableFields(named prefix: String, in app: XCUIApplication) -> XCUIElementQuery {
        app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
    }

    private func createVariable(name: String, value: String, addButton: String, in app: XCUIApplication) {
        let button = app.buttons[addButton].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 2))
        let nameFields = variableFields(named: "variable-name-field-", in: app)
        let existingIdentifiers = Set(nameFields.allElementsBoundByIndex.map(\.identifier))
        button.click()

        XCTAssertTrue(waitUntil(timeout: 2) {
            nameFields.allElementsBoundByIndex.contains { !existingIdentifiers.contains($0.identifier) }
        })
        guard let draftNameField = nameFields.allElementsBoundByIndex.first(where: {
            !existingIdentifiers.contains($0.identifier)
        }) else {
            XCTFail("Expected a newly inserted variable name field.")
            return
        }
        let valueIdentifier = draftNameField.identifier.replacingOccurrences(
            of: "variable-name-field-",
            with: "variable-value-field-"
        )
        let draftValueField = app.textFields[valueIdentifier].firstMatch
        XCTAssertTrue(draftValueField.waitForExistence(timeout: 2))
        draftNameField.click()
        draftNameField.typeText(name)
        draftValueField.click()
        draftValueField.typeText(value)
        app.typeKey(.tab, modifierFlags: [])
        XCTAssertTrue(app.textFields.matching(NSPredicate(format: "value == %@", name)).firstMatch.waitForExistence(timeout: 2))
    }

    private func replaceText(_ text: String, in element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 2), "Expected editable field to exist before typing.")
        element.click()
        element.typeKey("a", modifierFlags: .command)
        element.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        element.typeKey("v", modifierFlags: .command)
    }

    private func triggerRun(_ app: XCUIApplication) {
        let runButton = app.buttons["run-button"].firstMatch
        XCTAssertTrue(runButton.waitForExistence(timeout: 2))
        XCTAssertTrue(runButton.isEnabled)
        app.activate()
        app.typeKey(.return, modifierFlags: .command)
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
