import XCTest
import Foundation

@MainActor
final class SavedRequestsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testMultipleSavedRequestsRestoreTheirOwnDraftsWhenSwitching() throws {
        let libraryFileURL = makeTemporaryLibraryFileURL()
        let app = launchPersistentApp(libraryFileURL: libraryFileURL)
        defer { app.terminate() }

        let urlField = app.textFields["url-input-field"].firstMatch
        XCTAssertTrue(urlField.waitForExistence(timeout: 4))

        let nameField = app.textFields["request-name-field"].firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 2))

        replaceText("Req A", in: nameField)
        replaceText("https://api.example.com/a", in: urlField)
        XCTAssertTrue(waitUntil(timeout: 3) { (urlField.value as? String) == "https://api.example.com/a" })
        XCTAssertTrue(waitUntil(timeout: 3) { app.buttons["save-request-button"].firstMatch.isEnabled })
        app.buttons["save-request-button"].firstMatch.click()
        XCTAssertTrue(waitForSavedRequestNamed("Req A", in: app))

        app.buttons["new-request-button"].firstMatch.click()
        replaceText("Req B", in: nameField)
        replaceText("https://api.example.com/b", in: urlField)
        XCTAssertTrue(waitUntil(timeout: 3) { (urlField.value as? String) == "https://api.example.com/b" })
        XCTAssertTrue(waitUntil(timeout: 3) { app.buttons["save-request-button"].firstMatch.isEnabled })
        app.buttons["save-request-button"].firstMatch.click()
        XCTAssertTrue(waitForSavedRequestNamed("Req B", in: app))

        selectRequest(named: "Req A", in: app)
        replaceText("https://api.example.com/a-draft", in: urlField)

        selectRequest(named: "Req B", in: app)
        replaceText("https://api.example.com/b-draft", in: urlField)

        selectRequest(named: "Req A", in: app)
        XCTAssertTrue(waitUntil(timeout: 3) {
            urlField.value as? String == "https://api.example.com/a-draft"
        })

        selectRequest(named: "Req B", in: app)
        XCTAssertTrue(waitUntil(timeout: 3) {
            urlField.value as? String == "https://api.example.com/b-draft"
        })
    }

    func testDraftPersistsAcrossRelaunchForSavedRequest() throws {
        let libraryFileURL = makeTemporaryLibraryFileURL()

        do {
            let app = launchPersistentApp(libraryFileURL: libraryFileURL)
            let urlField = app.textFields["url-input-field"].firstMatch
            XCTAssertTrue(urlField.waitForExistence(timeout: 4))

            let nameField = app.textFields["request-name-field"].firstMatch
            XCTAssertTrue(nameField.waitForExistence(timeout: 2))

            replaceText("Req Persist", in: nameField)
            replaceText("https://api.example.com/base", in: urlField)
            XCTAssertTrue(waitUntil(timeout: 3) { (urlField.value as? String) == "https://api.example.com/base" })
            XCTAssertTrue(waitUntil(timeout: 3) { app.buttons["save-request-button"].firstMatch.isEnabled })
            app.buttons["save-request-button"].firstMatch.click()
            XCTAssertTrue(waitForSavedRequestNamed("Req Persist", in: app))

            replaceText("https://api.example.com/draft", in: urlField)
            app.terminate()
        }

        let relaunchedApp = launchPersistentApp(libraryFileURL: libraryFileURL)
        defer { relaunchedApp.terminate() }

        let relaunchedURLField = relaunchedApp.textFields["url-input-field"].firstMatch
        XCTAssertTrue(relaunchedURLField.waitForExistence(timeout: 4))
        XCTAssertTrue(waitForSavedRequestNamed("Req Persist", in: relaunchedApp))

        XCTAssertTrue(waitUntil(timeout: 3) {
            relaunchedURLField.value as? String == "https://api.example.com/draft"
        })
    }

    func testSidebarCollapseStatePersistsAcrossRelaunch() throws {
        let libraryFileURL = makeTemporaryLibraryFileURL()

        do {
            let app = launchPersistentApp(libraryFileURL: libraryFileURL)
            let collapseButton = app.buttons["toggle-library-button"].firstMatch
            XCTAssertTrue(collapseButton.waitForExistence(timeout: 4))
            collapseButton.click()
            XCTAssertTrue(app.buttons["expand-library-button"].firstMatch.waitForExistence(timeout: 3))
            Thread.sleep(forTimeInterval: 1.0)
            app.terminate()
        }

        let relaunchedApp = launchPersistentApp(libraryFileURL: libraryFileURL)
        defer { relaunchedApp.terminate() }
        XCTAssertTrue(relaunchedApp.buttons["expand-library-button"].firstMatch.waitForExistence(timeout: 4))
    }

    private func launchPersistentApp(libraryFileURL: URL) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-test-mode",
            "--ui-test-enable-persistence",
            "--ui-test-library-file",
            libraryFileURL.path
        ]
        app.launch()
        return app
    }

    private func makeTemporaryLibraryFileURL() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("curly-uitests", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("\(UUID().uuidString).json")
        try? FileManager.default.removeItem(at: fileURL)
        return fileURL
    }

    private func replaceText(_ text: String, in element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 2), "Expected editable field to exist before typing.")
        element.click()
        element.typeKey("a", modifierFlags: .command)
        element.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        element.typeText(text)
    }

    private func waitForSavedRequestNamed(_ name: String, in app: XCUIApplication, timeout: TimeInterval = 3) -> Bool {
        waitUntil(timeout: timeout) { app.staticTexts[name].firstMatch.exists }
    }

    private func selectRequest(named name: String, in app: XCUIApplication) {
        let target = app.staticTexts[name].firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 3), "Expected saved request named \(name) to exist.")
        target.click()
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
