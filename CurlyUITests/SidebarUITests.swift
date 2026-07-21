import AppKit
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

    func testScrolledRequestContentStaysOutOfTitlebarInBothSidebarStates() {
        let app = launchApp()
        defer { app.terminate() }

        let toolbar = app.toolbars.firstMatch
        let requestScrollView = app.scrollViews["request-pane-scroll-view"].firstMatch
        XCTAssertTrue(toolbar.waitForExistence(timeout: 4))
        XCTAssertTrue(requestScrollView.waitForExistence(timeout: 4))
        assertRequestViewport(requestScrollView, staysBelow: toolbar)

        let scriptSection = app.buttons["request-accordion-post-response script"].firstMatch
        XCTAssertTrue(scriptSection.waitForExistence(timeout: 3))
        scriptSection.click()
        XCTAssertTrue(app.buttons["post-response-script-api-button"].firstMatch.waitForExistence(timeout: 3))

        assertScrolling(requestScrollView, doesNotChange: toolbar, in: app)

        sidebarToggle(in: app).click()
        XCTAssertTrue(waitUntil { !self.sidebar(in: app).exists })
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        assertRequestViewport(requestScrollView, staysBelow: toolbar)
        assertScrolling(requestScrollView, doesNotChange: toolbar, in: app)
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

    func testSettingsExposeLoopbackTLSPreference() {
        let app = launchApp()
        defer { app.terminate() }

        app.activate()
        app.typeKey(",", modifierFlags: .command)

        let checkbox = app.checkBoxes["allow-insecure-loopback-tls-checkbox"].firstMatch
        XCTAssertTrue(
            checkbox.waitForExistence(timeout: 4),
            "Curly Settings should expose the app-wide loopback TLS preference."
        )
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

    private func assertRequestViewport(
        _ requestScrollView: XCUIElement,
        staysBelow toolbar: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertGreaterThanOrEqual(
            requestScrollView.frame.minY,
            toolbar.frame.maxY - 1,
            "The request scroll viewport \(requestScrollView.frame) must not extend beneath the titlebar toolbar \(toolbar.frame).",
            file: file,
            line: line
        )
    }

    private func assertScrolling(
        _ requestScrollView: XCUIElement,
        doesNotChange toolbar: XCUIElement,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let toolbarButtonMaxX = app.toolbars.buttons["toggle-library-button"].firstMatch.frame.maxX
        let sampleMinX = max(requestScrollView.frame.minX + 20, toolbarButtonMaxX + 20)
        let titlebarSampleRect = CGRect(
            x: sampleMinX,
            y: toolbar.frame.minY + 2,
            width: requestScrollView.frame.maxX - sampleMinX - 20,
            height: toolbar.frame.height - 4
        )
        let beforeScroll = app.screenshot().image
        requestScrollView.scroll(byDeltaX: 0, deltaY: -70)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        let afterScroll = app.screenshot().image
        let screenFrame = CGRect(
            origin: .zero,
            size: NSScreen.main?.frame.size ?? beforeScroll.size
        )
        let changedFraction = changedPixelFraction(
            between: beforeScroll,
            and: afterScroll,
            in: titlebarSampleRect,
            relativeTo: screenFrame
        )
        XCTAssertLessThan(
            changedFraction,
            0.01,
            "Scrolling changed \(changedFraction * 100)% of the request titlebar pixels; request content is leaking outside its viewport.",
            file: file,
            line: line
        )
    }

    private func changedPixelFraction(
        between before: NSImage,
        and after: NSImage,
        in screenRect: CGRect,
        relativeTo screenFrame: CGRect
    ) -> Double {
        guard let beforeData = before.tiffRepresentation,
              let afterData = after.tiffRepresentation,
              let beforeBitmap = NSBitmapImageRep(data: beforeData),
              let afterBitmap = NSBitmapImageRep(data: afterData),
              beforeBitmap.pixelsWide == afterBitmap.pixelsWide,
              beforeBitmap.pixelsHigh == afterBitmap.pixelsHigh,
              screenFrame.width > 0,
              screenFrame.height > 0 else {
            XCTFail("Unable to compare matching titlebar screenshots. Before: \(before.size), after: \(after.size), screen: \(screenFrame).")
            return 1
        }

        let pixelWidth = beforeBitmap.pixelsWide
        let pixelHeight = beforeBitmap.pixelsHigh
        let xScale = CGFloat(pixelWidth) / screenFrame.width
        let yScale = CGFloat(pixelHeight) / screenFrame.height
        let localRect = screenRect.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
        let minX = max(0, Int((localRect.minX * xScale).rounded(.down)))
        let maxX = min(pixelWidth, Int((localRect.maxX * xScale).rounded(.up)))
        let minYFromTop = max(0, Int((localRect.minY * yScale).rounded(.down)))
        let maxYFromTop = min(pixelHeight, Int((localRect.maxY * yScale).rounded(.up)))

        var compared = 0
        var changed = 0
        for yFromTop in stride(from: minYFromTop, to: maxYFromTop, by: 2) {
            let bitmapY = yFromTop
            for x in stride(from: minX, to: maxX, by: 2) {
                guard let beforeColor = beforeBitmap.colorAt(x: x, y: bitmapY)?.usingColorSpace(.deviceRGB),
                      let afterColor = afterBitmap.colorAt(x: x, y: bitmapY)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                compared += 1
                let maximumDifference = max(
                    abs(beforeColor.redComponent - afterColor.redComponent),
                    max(
                        abs(beforeColor.greenComponent - afterColor.greenComponent),
                        abs(beforeColor.blueComponent - afterColor.blueComponent)
                    )
                )
                if maximumDifference > 0.04 {
                    changed += 1
                }
            }
        }

        guard compared > 0 else {
            XCTFail("The titlebar screenshot sample was empty.")
            return 1
        }
        return Double(changed) / Double(compared)
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
