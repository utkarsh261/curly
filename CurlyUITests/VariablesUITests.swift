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
