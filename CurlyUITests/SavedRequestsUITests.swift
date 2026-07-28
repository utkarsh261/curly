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

    func testRequestKeyboardShortcutsUseVisibleOrderToggleHistoryAndWorkWithCollapsedSidebar() {
        let libraryFileURL = makeTemporaryLibraryFileURL()
        let app = launchPersistentApp(libraryFileURL: libraryFileURL)
        defer { app.terminate() }

        for index in 1...9 {
            if index > 1 {
                app.buttons["new-request-button"].firstMatch.click()
            }
            createCurrentRequest(
                name: "Request \(index)",
                url: "https://api.example.com/\(index)",
                in: app
            )
        }

        let urlField = app.textFields["url-input-field"].firstMatch
        urlField.click()
        app.typeKey("9", modifierFlags: .control)
        assertCurrentRequest(named: "Request 1", in: app)

        sidebarToggleButton(in: app).click()
        XCTAssertTrue(waitUntil(timeout: 3) {
            !app.buttons["new-request-button"].firstMatch.exists
        })

        urlField.click()
        app.typeKey("1", modifierFlags: .control)
        assertCurrentRequest(named: "Request 9", in: app)

        urlField.click()
        app.typeKey(.tab, modifierFlags: .control)
        assertCurrentRequest(named: "Request 1", in: app)

        app.typeKey(.tab, modifierFlags: .control)
        assertCurrentRequest(named: "Request 9", in: app)

        app.menuBars.menuBarItems["Workspace"].click()
        XCTAssertTrue(app.menuItems["Last Visited — Request 1"].firstMatch.waitForExistence(timeout: 2))
        XCTAssertTrue(app.menuItems["1 — Request 9"].firstMatch.exists)
        XCTAssertTrue(app.menuItems["9 — Request 1"].firstMatch.exists)
    }

    func testRequestKeyboardShortcutsWinFromEveryRequestEditor() {
        let libraryFileURL = makeTemporaryLibraryFileURL()
        let app = launchPersistentApp(libraryFileURL: libraryFileURL)
        defer { app.terminate() }

        createCurrentRequest(
            name: "Request A",
            url: "https://api.example.com/a",
            in: app
        )
        app.buttons["new-request-button"].firstMatch.click()
        createCurrentRequest(
            name: "Request B",
            url: "https://api.example.com/b",
            in: app
        )

        let requestScrollView = app.scrollViews["request-pane-scroll-view"].firstMatch
        XCTAssertTrue(requestScrollView.waitForExistence(timeout: 3))

        let addHeaderButton = app.buttons["add-header-button"].firstMatch
        XCTAssertTrue(addHeaderButton.waitForExistence(timeout: 3))
        addHeaderButton.click()

        let headerName = app.textFields.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "header-name-field-")
        ).firstMatch
        let headerValue = app.textFields.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "header-value-field-")
        ).firstMatch
        XCTAssertTrue(headerName.waitForExistence(timeout: 3))
        XCTAssertTrue(headerValue.waitForExistence(timeout: 3))

        assertBothNavigationShortcuts(
            from: app.textFields["url-input-field"].firstMatch,
            betweenFirstRequest: "Request B",
            andSecondRequest: "Request A",
            in: app
        )
        assertBothNavigationShortcuts(
            from: headerName,
            betweenFirstRequest: "Request B",
            andSecondRequest: "Request A",
            in: app
        )
        assertBothNavigationShortcuts(
            from: headerValue,
            betweenFirstRequest: "Request B",
            andSecondRequest: "Request A",
            in: app
        )

        let bodyEditor = app.textViews.firstMatch
        for _ in 0..<3 where !bodyEditor.isHittable {
            requestScrollView.swipeUp()
        }
        XCTAssertTrue(bodyEditor.waitForExistence(timeout: 3))
        XCTAssertTrue(bodyEditor.isHittable)
        assertBothNavigationShortcuts(
            from: bodyEditor,
            betweenFirstRequest: "Request B",
            andSecondRequest: "Request A",
            in: app
        )

        var scriptEditor = revealEnabledScriptEditor(in: app, requestScrollView: requestScrollView)
        scriptEditor.click()
        app.typeKey(.tab, modifierFlags: .control)
        assertCurrentRequest(named: "Request A", in: app)
        app.typeKey(.tab, modifierFlags: .control)
        assertCurrentRequest(named: "Request B", in: app)

        scriptEditor = revealEnabledScriptEditor(in: app, requestScrollView: requestScrollView)
        scriptEditor.click()
        app.typeKey("2", modifierFlags: .control)
        assertCurrentRequest(named: "Request A", in: app)
        app.typeKey("1", modifierFlags: .control)
        assertCurrentRequest(named: "Request B", in: app)
    }

    func testRequestKeyboardShortcutsDoNotNavigateBehindVariablesModal() {
        let libraryFileURL = makeTemporaryLibraryFileURL()
        let app = launchPersistentApp(libraryFileURL: libraryFileURL)
        defer { app.terminate() }

        createCurrentRequest(
            name: "Request A",
            url: "https://api.example.com/a",
            in: app
        )
        app.buttons["new-request-button"].firstMatch.click()
        createCurrentRequest(
            name: "Request B",
            url: "https://api.example.com/b",
            in: app
        )

        app.menuItems["Manage Variables…"].firstMatch.click()
        XCTAssertTrue(app.otherElements["variables-modal-overlay"].firstMatch.waitForExistence(timeout: 3))

        app.buttons["variables-request-add-button"].firstMatch.click()
        let draftNameField = app.textFields.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "variable-name-field-")
        ).firstMatch
        XCTAssertTrue(draftNameField.waitForExistence(timeout: 3))
        draftNameField.typeText("draft_for_request_b")

        app.typeKey(.tab, modifierFlags: .control)
        assertCurrentRequest(named: "Request B", in: app)
        XCTAssertTrue(app.otherElements["variables-modal-overlay"].firstMatch.exists)

        app.typeKey("2", modifierFlags: .control)
        assertCurrentRequest(named: "Request B", in: app)
        XCTAssertTrue(app.otherElements["variables-modal-overlay"].firstMatch.exists)
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

    private func createCurrentRequest(name: String, url: String, in app: XCUIApplication) {
        let nameField = app.textFields["request-name-field"].firstMatch
        let urlField = app.textFields["url-input-field"].firstMatch
        replaceText(name, in: nameField)
        replaceText(url, in: urlField)
        XCTAssertTrue(waitUntil(timeout: 3) {
            app.buttons["save-request-button"].firstMatch.isEnabled
        })
        app.buttons["save-request-button"].firstMatch.click()
        XCTAssertTrue(waitForSavedRequestNamed(name, in: app))
    }

    private func assertCurrentRequest(
        named name: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            waitUntil(timeout: 3) {
                app.textFields["request-name-field"].firstMatch.value as? String == name
            },
            "Expected \(name) to be selected.",
            file: file,
            line: line
        )
    }

    private func assertBothNavigationShortcuts(
        from editor: XCUIElement,
        betweenFirstRequest firstName: String,
        andSecondRequest secondName: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        selectRequest(named: secondName, in: app)
        selectRequest(named: firstName, in: app)
        XCTAssertTrue(editor.waitForExistence(timeout: 3), file: file, line: line)
        editor.click()
        app.typeKey(.tab, modifierFlags: .control)
        assertCurrentRequest(named: secondName, in: app, file: file, line: line)
        app.typeKey(.tab, modifierFlags: .control)
        assertCurrentRequest(named: firstName, in: app, file: file, line: line)

        XCTAssertTrue(editor.waitForExistence(timeout: 3), file: file, line: line)
        editor.click()
        app.typeKey("2", modifierFlags: .control)
        assertCurrentRequest(named: secondName, in: app, file: file, line: line)
        app.typeKey("1", modifierFlags: .control)
        assertCurrentRequest(named: firstName, in: app, file: file, line: line)
    }

    private func revealEnabledScriptEditor(
        in app: XCUIApplication,
        requestScrollView: XCUIElement
    ) -> XCUIElement {
        let scriptRow = app.buttons["request-accordion-post-response script"].firstMatch
        for _ in 0..<3 where !scriptRow.isHittable {
            requestScrollView.swipeUp()
        }
        XCTAssertTrue(scriptRow.waitForExistence(timeout: 3))

        let scriptCheckbox = app.checkBoxes["post-response-script-enabled"].firstMatch
        if !scriptCheckbox.exists {
            scriptRow.click()
        }
        for _ in 0..<3 where !scriptCheckbox.isHittable {
            requestScrollView.swipeUp()
        }
        XCTAssertTrue(scriptCheckbox.waitForExistence(timeout: 3))
        if (scriptCheckbox.value as? Int) != 1 {
            scriptCheckbox.click()
        }

        let scriptEditor = app.textViews["post-response-script-editor"].firstMatch
        for _ in 0..<3 where !scriptEditor.isHittable {
            requestScrollView.swipeUp()
        }
        XCTAssertTrue(scriptEditor.waitForExistence(timeout: 3))
        XCTAssertTrue(scriptEditor.isHittable)
        return scriptEditor
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
