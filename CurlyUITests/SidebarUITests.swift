import XCTest

@MainActor
final class SidebarUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSidebarIsDiscoverableAndExpandedByDefault() {
        let app = launchApp()
        defer { app.terminate() }

        XCTAssertTrue(sidebarToggle(in: app).waitForExistence(timeout: 4))
        XCTAssertTrue(sidebar(in: app).waitForExistence(timeout: 4))
        let toolbarFrame = app.toolbars.firstMatch.frame
        XCTAssertTrue(
            app.buttons.matching(identifier: "toggle-library-button").allElementsBoundByIndex.allSatisfy {
                toolbarFrame.intersects($0.frame)
            }
        )
    }

    func testTitlebarButtonCollapsesAndRestoresSplitSidebar() {
        let app = launchApp()
        defer { app.terminate() }

        let requestPane = app.textFields["url-input-field"].firstMatch
        XCTAssertTrue(requestPane.waitForExistence(timeout: 4))
        XCTAssertTrue(sidebar(in: app).waitForExistence(timeout: 4))
        let expandedRequestMinimumX = requestPane.frame.minX

        sidebarToggle(in: app).click()

        XCTAssertTrue(waitUntil { !self.sidebar(in: app).exists })
        XCTAssertFalse(app.buttons["new-request-button"].firstMatch.exists)
        let collapsedRequestMinimumX = app.textFields["url-input-field"].firstMatch.frame.minX
        XCTAssertLessThan(collapsedRequestMinimumX, expandedRequestMinimumX - 150)
        XCTAssertEqual(
            expandedRequestMinimumX - collapsedRequestMinimumX,
            220,
            accuracy: 4,
            "The expanded sidebar should use the compact 220pt width."
        )
        XCTAssertTrue(sidebarToggle(in: app).exists)

        sidebarToggle(in: app).click()

        XCTAssertTrue(sidebar(in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["new-request-button"].firstMatch.exists)
        XCTAssertTrue(waitUntil {
            app.textFields["url-input-field"].firstMatch.frame.minX > collapsedRequestMinimumX + 150
        })
        XCTAssertEqual(
            app.textFields["url-input-field"].firstMatch.frame.minX,
            expandedRequestMinimumX,
            accuracy: 2,
            "Reopening the sidebar should restore the same compact width."
        )
    }

    func testViewMenuCollapsesAndRestoresSidebar() {
        let app = launchApp()
        defer { app.terminate() }

        XCTAssertTrue(sidebar(in: app).waitForExistence(timeout: 4))
        selectViewMenuItem(named: "Hide Sidebar", in: app)
        XCTAssertTrue(waitUntil { !self.sidebar(in: app).exists })

        selectViewMenuItem(named: "Show Sidebar", in: app)
        XCTAssertTrue(sidebar(in: app).waitForExistence(timeout: 3))
    }

    func testSidebarKeyboardShortcutTogglesBothDirections() {
        let app = launchApp()
        defer { app.terminate() }

        XCTAssertTrue(sidebar(in: app).waitForExistence(timeout: 4))
        app.typeKey("s", modifierFlags: [.command, .control])
        XCTAssertTrue(waitUntil { !self.sidebar(in: app).exists })

        app.typeKey("s", modifierFlags: [.command, .control])
        XCTAssertTrue(sidebar(in: app).waitForExistence(timeout: 3))
    }

    func testHoveringAtLeftWindowEdgeDoesNotRevealCollapsedSidebar() {
        let app = launchApp()
        defer { app.terminate() }

        XCTAssertTrue(sidebar(in: app).waitForExistence(timeout: 4))
        sidebarToggle(in: app).click()
        XCTAssertTrue(waitUntil { !self.sidebar(in: app).exists })

        let leftEdge = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.002, dy: 0.5))
        leftEdge.hover()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        XCTAssertFalse(sidebar(in: app).exists)
        XCTAssertFalse(app.buttons["new-request-button"].firstMatch.exists)
        XCTAssertTrue(sidebarToggle(in: app).exists)
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-mode"]
        app.launch()
        return app
    }

    private func sidebar(in app: XCUIApplication) -> XCUIElement {
        app.buttons["new-request-button"].firstMatch
    }

    private func sidebarToggle(in app: XCUIApplication) -> XCUIElement {
        app.toolbars.buttons["toggle-library-button"].firstMatch
    }

    private func selectViewMenuItem(named name: String, in app: XCUIApplication) {
        let viewMenu = app.menuBars.menuBarItems["View"].firstMatch
        XCTAssertTrue(viewMenu.waitForExistence(timeout: 2))
        viewMenu.click()

        let menuItem = app.menuItems[name].firstMatch
        XCTAssertTrue(menuItem.waitForExistence(timeout: 2), "Expected View menu item named \(name).")
        menuItem.click()
    }

    private func waitUntil(timeout: TimeInterval = 3, condition: @escaping () -> Bool) -> Bool {
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
