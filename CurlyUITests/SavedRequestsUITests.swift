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
            let sidebar = app.buttons["new-request-button"].firstMatch
            XCTAssertTrue(sidebar.waitForExistence(timeout: 4))

            sidebarToggleButton(in: app).click()
            XCTAssertTrue(waitUntil(timeout: 3) { !sidebar.exists })
            app.terminate()
        }

        let collapsedRelaunch = launchPersistentApp(libraryFileURL: libraryFileURL)
        XCTAssertTrue(sidebarToggleButton(in: collapsedRelaunch).waitForExistence(timeout: 4))
        XCTAssertFalse(collapsedRelaunch.buttons["new-request-button"].firstMatch.exists)

        sidebarToggleButton(in: collapsedRelaunch).click()
        XCTAssertTrue(collapsedRelaunch.buttons["new-request-button"].firstMatch.waitForExistence(timeout: 3))
        collapsedRelaunch.terminate()

        let expandedRelaunch = launchPersistentApp(libraryFileURL: libraryFileURL)
        defer { expandedRelaunch.terminate() }
        XCTAssertTrue(sidebarToggleButton(in: expandedRelaunch).waitForExistence(timeout: 4))
        XCTAssertTrue(expandedRelaunch.buttons["new-request-button"].firstMatch.waitForExistence(timeout: 2))
    }

    private func launchPersistentApp(libraryFileURL: URL) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-test-mode",
            "--ui-test-enable-persistence",
            "--ui-test-library-id",
            libraryFileURL.deletingPathExtension().lastPathComponent
        ]
        app.launch()
        return app
    }

    private func makeTemporaryLibraryFileURL() -> URL {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Containers/com.example.Curly/Data/Library/Application Support/Curly/UITests",
                isDirectory: true
            )
        return directory.appendingPathComponent("\(UUID().uuidString).json")
    }

    private func replaceText(_ text: String, in element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 2), "Expected editable field to exist before typing.")
        element.click()
        element.typeKey("a", modifierFlags: .command)
        element.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        element.typeText(text)
    }

    private func waitForSavedRequestNamed(_ name: String, in app: XCUIApplication, timeout: TimeInterval = 3) -> Bool {
        waitUntil(timeout: timeout) { app.buttons[name].firstMatch.exists }
    }

    private func selectRequest(named name: String, in app: XCUIApplication) {
        let target = app.buttons[name].firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 3), "Expected saved request named \(name) to exist.")
        target.click()
    }

    private func sidebarToggleButton(in app: XCUIApplication) -> XCUIElement {
        app.toolbars.buttons["toggle-library-button"].firstMatch
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
