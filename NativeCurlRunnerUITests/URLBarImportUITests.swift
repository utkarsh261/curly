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

    private func launchWithURLBarInput(_ input: String) -> (XCUIApplication, XCUIElement) {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-url-bar-input", input]
        app.launch()

        let urlField = app.textFields["url-input-field"].firstMatch
        XCTAssertTrue(urlField.waitForExistence(timeout: 5), "The request composer URL field should exist.")
        return (app, urlField)
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
