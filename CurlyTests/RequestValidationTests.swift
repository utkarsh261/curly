import AppKit
import XCTest
@testable import Curly

final class RequestValidationTests: XCTestCase {
    @MainActor
    func testURLFieldEditorKeepsVariableColorWhenSelectionChanges() throws {
        let variable = Variable(name: "host", value: "example.com", scope: .global)
        let text = "https://{{host}}/" + String(repeating: "long-path/", count: 20)
        let textField = PasteAwareTextField()
        textField.variables = [variable]
        let editor = URLTokenFieldEditor()
        editor.string = text
        textField.prepareFieldEditor(editor)
        let tokenRange = try XCTUnwrap(URLTokenEditingPolicy.tokenRanges(in: text).first)

        XCTAssertEqual(editor.textStorage?.attribute(.foregroundColor, at: tokenRange.location, effectiveRange: nil) as? NSColor, .controlAccentColor)

        editor.setSelectedRange(NSRange(location: NSMaxRange(tokenRange) + 1, length: 0))

        XCTAssertEqual(editor.textStorage?.attribute(.foregroundColor, at: tokenRange.location, effectiveRange: nil) as? NSColor, .controlAccentColor)
    }

    @MainActor
    func testSharedVariableFieldEditorColorsNestedResolutionBeforeDispatch() throws {
        let authorization = Variable(
            name: "authorization",
            value: "Bearer {{token}}",
            scope: .global
        )
        let editor = URLTokenFieldEditor()
        editor.string = "{{authorization}}"
        let tokenRange = try XCTUnwrap(URLTokenEditingPolicy.tokenRanges(in: editor.string).first)
        let textField = PasteAwareTextField()

        textField.variables = [
            authorization,
            Variable(name: "token", value: "abc", scope: .global)
        ]
        textField.prepareFieldEditor(editor)
        XCTAssertEqual(
            editor.textStorage?.attribute(.foregroundColor, at: tokenRange.location, effectiveRange: nil) as? NSColor,
            .controlAccentColor
        )

        textField.variables = [authorization]
        textField.prepareFieldEditor(editor)
        XCTAssertEqual(
            editor.textStorage?.attribute(.foregroundColor, at: tokenRange.location, effectiveRange: nil) as? NSColor,
            .systemRed
        )
    }

    @MainActor
    func testURLFieldEditorScrollsHorizontallyWithoutChangingTextOrSelection() {
        let clipView = NSClipView(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        let editor = URLTokenFieldEditor(frame: NSRect(x: 0, y: 0, width: 1_000, height: 24))
        editor.string = "https://example.com/" + String(repeating: "long-path/", count: 20)
        editor.setSelectedRange(NSRange(location: 8, length: 4))
        clipView.documentView = editor

        editor.scrollHorizontally(deltaX: -120, deltaY: 0, hasPreciseDeltas: true)

        XCTAssertEqual(editor.visibleRect.minX, 120, accuracy: 0.5)
        XCTAssertEqual(editor.string, "https://example.com/" + String(repeating: "long-path/", count: 20))
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 8, length: 4))
    }

    @MainActor
    func testURLFieldEditorMapsMouseWheelToHorizontalMovementAndClampsBounds() {
        let clipView = NSClipView(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        let editor = URLTokenFieldEditor(frame: NSRect(x: 0, y: 0, width: 500, height: 24))
        clipView.documentView = editor

        editor.scrollHorizontally(deltaX: 0, deltaY: -30, hasPreciseDeltas: true)
        XCTAssertEqual(editor.visibleRect.minX, 30, accuracy: 0.5)

        editor.scrollHorizontally(deltaX: 0, deltaY: -1_000, hasPreciseDeltas: true)
        XCTAssertEqual(editor.visibleRect.minX, 300, accuracy: 0.5)

        editor.scrollHorizontally(deltaX: 0, deltaY: 1_000, hasPreciseDeltas: true)
        XCTAssertEqual(editor.visibleRect.minX, 0, accuracy: 0.5)
    }

    func testMissingAndInvalidVariableTokensUseErrorColor() {
        XCTAssertEqual(VariableTokenPalette.nsColor(for: .missing), .systemRed)
        XCTAssertEqual(VariableTokenPalette.nsColor(for: .invalid), .systemRed)
        XCTAssertEqual(VariableTokenPalette.nsColor(for: .resolved), .controlAccentColor)
    }

    func testVariableTemplateFieldAccessibilityDescribesLiveNestedResolution() {
        let token = Variable(name: "token", value: "abc", scope: .global)
        let authorization = Variable(
            name: "authorization",
            value: "Bearer {{token}}",
            scope: .global
        )

        XCTAssertEqual(
            VariableTemplateFieldAccessibility.description(
                text: "{{authorization}}",
                variables: [token, authorization]
            ),
            "Recognized variable authorization. Resolves to Bearer abc."
        )
        XCTAssertEqual(
            VariableTemplateFieldAccessibility.description(
                text: "Bearer {{token}}",
                variables: [authorization]
            ),
            "Missing variable token."
        )
    }

    func testVariableTokenToolTipsShowFullyResolvedNestedValuesAndDiagnostics() throws {
        let token = Variable(name: "token", value: "abc", scope: .global)
        let authorization = Variable(
            name: "authorization",
            value: "Bearer {{token}}",
            scope: .global
        )

        let resolved = try XCTUnwrap(
            VariableTemplateTokenToolTips.items(
                text: "{{authorization}}",
                variables: [token, authorization]
            ).first
        )
        XCTAssertEqual(resolved.range, NSRange(location: 0, length: 17))
        guard case .resolved(let name, let value) = resolved.content else {
            XCTFail("Expected a lightweight resolved tooltip payload.")
            return
        }
        XCTAssertEqual(name, "authorization")
        XCTAssertEqual(value, "Bearer abc")
        XCTAssertEqual(resolved.text, "authorization resolves to:\nBearer abc")

        let missing = try XCTUnwrap(
            VariableTemplateTokenToolTips.items(
                text: "{{authorization}}",
                variables: [authorization]
            ).first
        )
        XCTAssertEqual(missing.text, "authorization → token refers to missing variable token")

        let invalid = try XCTUnwrap(
            VariableTemplateTokenToolTips.items(
                text: "{{not valid}}",
                variables: []
            ).first
        )
        XCTAssertEqual(invalid.text, "{{not valid}} has invalid syntax")
    }

    @MainActor
    func testVariableTokenToolTipLayoutWrapsMultilineAndLongValuesAfterAShortDelay() {
        let singleLineSize = VariableTokenToolTipLayout.panelSize(
            for: "token resolves to abc"
        )
        let multilineSize = VariableTokenToolTipLayout.panelSize(
            for: "payload resolves to {\n  \"token\": \"abc\",\n  \"enabled\": true\n}"
        )
        let wrappedSize = VariableTokenToolTipLayout.panelSize(
            for: "payload resolves to " + String(repeating: "a readable long value ", count: 20)
        )
        let unbrokenValueSize = VariableTokenToolTipLayout.panelSize(
            for: "token resolves to " + String(repeating: "abcdef123456", count: 40)
        )
        let oversizedText = (0..<40).map { "line-\($0)" }.joined(separator: "\n")
        let visibleOversizedText = VariableTokenToolTipLayout.visibleText(for: oversizedText)

        let wrappingTextView = VariableTokenToolTipLayout.makeTextView(
            for: visibleOversizedText
        )
        wrappingTextView.frame = NSRect(
            origin: .zero,
            size: NSSize(
                width: VariableTokenToolTipLayout.maximumTextWidth,
                height: VariableTokenToolTipLayout.maximumTextHeight
            )
        )
        guard let layoutManager = wrappingTextView.layoutManager,
              let textContainer = wrappingTextView.textContainer else {
            XCTFail("Expected the tooltip text view to have a TextKit layout stack.")
            return
        }
        layoutManager.ensureLayout(for: textContainer)
        var renderedLineCount = 0
        var glyphIndex = 0
        while glyphIndex < layoutManager.numberOfGlyphs {
            var lineRange = NSRange()
            layoutManager.lineFragmentRect(
                forGlyphAt: glyphIndex,
                effectiveRange: &lineRange
            )
            renderedLineCount += 1
            glyphIndex = NSMaxRange(lineRange)
        }

        XCTAssertEqual(VariableTokenToolTipLayout.presentationDelay, 0.8, accuracy: 0.001)
        XCTAssertGreaterThan(multilineSize.height, singleLineSize.height)
        XCTAssertGreaterThan(wrappedSize.height, singleLineSize.height)
        XCTAssertGreaterThan(unbrokenValueSize.height, singleLineSize.height)
        XCTAssertGreaterThan(renderedLineCount, 1)
        XCTAssertTrue(visibleOversizedText.hasSuffix(VariableTokenToolTipLayout.truncationNotice))
        XCTAssertFalse(visibleOversizedText.contains("line-39"))
        XCTAssertLessThanOrEqual(
            ceil(layoutManager.usedRect(for: textContainer).height),
            VariableTokenToolTipLayout.maximumTextHeight
        )
        XCTAssertEqual(wrappingTextView.textContainer?.lineBreakMode, .byCharWrapping)
        XCTAssertFalse(wrappingTextView.isEditable)
        XCTAssertFalse(wrappingTextView.isSelectable)
        XCTAssertLessThanOrEqual(multilineSize.width, VariableTokenToolTipLayout.maximumPanelWidth)
        XCTAssertLessThanOrEqual(wrappedSize.width, VariableTokenToolTipLayout.maximumPanelWidth)
        XCTAssertLessThanOrEqual(unbrokenValueSize.width, VariableTokenToolTipLayout.maximumPanelWidth)
    }

    @MainActor
    func testSharedVariableFieldEditorAttachesToolTipOnlyToEachToken() throws {
        let variables = [
            Variable(name: "host", value: "api.example.com", scope: .global),
            Variable(name: "token", value: "abc", scope: .global),
            Variable(name: "authorization", value: "Bearer {{token}}", scope: .global)
        ]
        let editor = URLTokenFieldEditor()
        editor.string = "https://{{host}}/{{authorization}}"
        let textField = PasteAwareTextField()
        textField.variables = variables

        textField.prepareFieldEditor(editor)

        XCTAssertNil(editor.variableToolTip(atCharacterIndex: 0))
        XCTAssertEqual(
            editor.variableToolTip(atCharacterIndex: 8)?.text,
            "host resolves to:\napi.example.com"
        )
        XCTAssertNil(editor.variableToolTip(atCharacterIndex: 16))
        XCTAssertEqual(
            editor.variableToolTip(atCharacterIndex: 18)?.text,
            "authorization resolves to:\nBearer abc"
        )
    }

    @MainActor
    func testVariableToolTipGeometryRejectsBlankSpaceAndMiddleTruncation() throws {
        let variables = [
            Variable(name: "first", value: "one", scope: .global),
            Variable(name: "second", value: "two", scope: .global)
        ]
        let text = "prefix-{{first}}-middle-{{second}}-suffix"
        let items = VariableTemplateTokenToolTips.items(text: text, variables: variables)
        XCTAssertEqual(items.count, 2)

        let attributedText = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedSystemFont(
                    ofSize: NSFont.systemFontSize,
                    weight: .regular
                )
            ]
        )
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byTruncatingMiddle
        attributedText.addAttribute(
            .paragraphStyle,
            value: paragraphStyle,
            range: NSRange(location: 0, length: attributedText.length)
        )
        let textStorage = NSTextStorage(attributedString: attributedText)
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(containerSize: NSSize(width: 150, height: 20))
        textContainer.lineFragmentPadding = 0
        textContainer.maximumNumberOfLines = 1
        textContainer.lineBreakMode = .byTruncatingMiddle
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: textContainer)

        for item in items {
            XCTAssertNil(
                VariableTokenHoverGeometry.visibleGlyphRect(
                    for: item.range,
                    layoutManager: layoutManager,
                    textContainer: textContainer
                ),
                "A partially or fully elided variable must not claim the ellipsis hover region."
            )
        }

        let visibleText = "{{first}}"
        let visibleStorage = NSTextStorage(
            attributedString: NSAttributedString(
                string: visibleText,
                attributes: [
                    .font: NSFont.monospacedSystemFont(
                        ofSize: NSFont.systemFontSize,
                        weight: .regular
                    )
                ]
            )
        )
        let visibleLayoutManager = NSLayoutManager()
        let visibleContainer = NSTextContainer(containerSize: NSSize(width: 500, height: 20))
        visibleContainer.lineFragmentPadding = 0
        visibleLayoutManager.addTextContainer(visibleContainer)
        visibleStorage.addLayoutManager(visibleLayoutManager)
        visibleLayoutManager.ensureLayout(for: visibleContainer)
        let tokenRect = try XCTUnwrap(
            VariableTokenHoverGeometry.visibleGlyphRect(
                for: NSRange(location: 0, length: (visibleText as NSString).length),
                layoutManager: visibleLayoutManager,
                textContainer: visibleContainer
            )
        )
        XCTAssertTrue(
            VariableTokenHoverGeometry.containsHorizontally(
                NSPoint(x: tokenRect.midX, y: tokenRect.maxY + 4),
                in: tokenRect
            ),
            "Single-line field padding must not prevent a horizontal token hit."
        )
        XCTAssertFalse(
            VariableTokenHoverGeometry.containsHorizontally(
                NSPoint(x: 490, y: tokenRect.midY),
                in: tokenRect
            )
        )
    }

    @MainActor
    func testActiveFieldEditorHitsTokenButRejectsTrailingBlankSpace() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 40),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let editor = URLTokenFieldEditor(frame: NSRect(x: 0, y: 0, width: 500, height: 24))
        editor.string = "{{token}}"
        let textField = PasteAwareTextField()
        textField.variables = [Variable(name: "token", value: "abc", scope: .global)]
        textField.prepareFieldEditor(editor)
        window.contentView = editor
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editor)
        defer {
            window.orderOut(nil)
        }

        var hoveredItem: VariableTemplateTokenToolTip?
        editor.onVariableTokenHover = { item, _ in
            hoveredItem = item
        }
        let tokenRect = try XCTUnwrap(
            VariableTokenHoverGeometry.visibleGlyphRect(
                for: NSRange(location: 0, length: 9),
                layoutManager: try XCTUnwrap(editor.layoutManager),
                textContainer: try XCTUnwrap(editor.textContainer)
            )
        )
        let tokenPoint = NSPoint(
            x: editor.textContainerOrigin.x + tokenRect.midX,
            y: editor.textContainerOrigin.y + tokenRect.midY
        )
        let tokenEvent = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .mouseMoved,
                location: editor.convert(tokenPoint, to: nil),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 0,
                pressure: 0
            )
        )

        editor.mouseMoved(with: tokenEvent)
        XCTAssertEqual(hoveredItem?.text, "token resolves to:\nabc")

        let blankPoint = NSPoint(x: editor.bounds.maxX - 5, y: tokenPoint.y)
        let blankEvent = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .mouseMoved,
                location: editor.convert(blankPoint, to: nil),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 2,
                clickCount: 0,
                pressure: 0
            )
        )
        editor.mouseMoved(with: blankEvent)
        XCTAssertNil(hoveredItem)
    }

    func testRepeatedVariableToolTipsKeepDistinctHoverIdentity() {
        let items = VariableTemplateTokenToolTips.items(
            text: "{{token}}/{{token}}",
            variables: [Variable(name: "token", value: "abc", scope: .global)]
        )

        XCTAssertEqual(items.count, 2)
        XCTAssertNotEqual(items[0], items[1])
        XCTAssertEqual(items[0].text, items[1].text)
    }

    func testVariablesModalHeightFitsContentWithinCompactBounds() {
        XCTAssertEqual(VariableModalMetrics.height(contentHeight: 280, availableHeight: 900), 360)
        XCTAssertEqual(VariableModalMetrics.height(contentHeight: 486, availableHeight: 900), 486)
        XCTAssertEqual(VariableModalMetrics.height(contentHeight: 900, availableHeight: 900), 600)
        XCTAssertEqual(VariableModalMetrics.height(contentHeight: 540, availableHeight: 480), 480)
    }

    func testRequiresHTTPOrHTTPSAbsoluteURL() {
        XCTAssertFalse(Request(method: .get, urlString: "foo", headers: [], body: .none).isMinimallyValid)
        XCTAssertFalse(Request(method: .get, urlString: "localhost:3000", headers: [], body: .none).isMinimallyValid)
        XCTAssertFalse(Request(method: .get, urlString: "http://", headers: [], body: .none).isMinimallyValid)
        XCTAssertTrue(Request(method: .get, urlString: "https://example.com", headers: [], body: .none).isMinimallyValid)
        XCTAssertTrue(Request(method: .head, urlString: "https://example.com", headers: [], body: .none).isMinimallyValid)
        XCTAssertTrue(Request(method: .options, urlString: "https://example.com", headers: [], body: .none).isMinimallyValid)
        XCTAssertTrue(Request(method: .get, urlString: "http://localhost:3000", headers: [], body: .none).isMinimallyValid)
    }

    func testOlderEncodedRequestDefaultsToSystemCertificateVerification() throws {
        let original = Request(
            method: .get,
            urlString: "https://example.com",
            headers: [],
            body: .none,
            tlsCertificateVerification: .disabled
        )
        let encoded = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "tlsCertificateVerification")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(Request.self, from: legacyData)

        XCTAssertEqual(decoded.tlsCertificateVerification, .systemDefault)
    }

    func testRequestCertificateVerificationPolicyRoundTrips() throws {
        let request = Request(
            method: .get,
            urlString: "https://example.com",
            headers: [],
            body: .none,
            tlsCertificateVerification: .disabled
        )

        let decoded = try JSONDecoder().decode(Request.self, from: JSONEncoder().encode(request))

        XCTAssertEqual(decoded, request)
    }

    func testVariableResolutionPreservesHiddenCertificateVerificationPolicy() throws {
        let request = Request(
            method: .get,
            urlString: "https://{{host}}",
            headers: [],
            body: .none,
            tlsCertificateVerification: .disabled
        )
        let variable = Variable(name: "host", value: "localhost:9443", scope: .global)

        let resolution = VariableResolver.resolve(request, variables: [variable])

        XCTAssertEqual(resolution.resolvedRequest?.tlsCertificateVerification, .disabled)
    }

    func testSkipsEnabledHeadersWithoutNames() {
        let request = Request(
            method: .get,
            urlString: "https://example.com",
            headers: [Header(name: "", value: "token", isEnabled: true)],
            body: .none
        )

        XCTAssertTrue(request.isMinimallyValid)
        XCTAssertNil(request.lightweightValidationMessage)
    }

    func testLightweightValidationMessageExplainsCurrentEditingIssue() {
        XCTAssertEqual(
            Request(method: .get, urlString: "localhost:3000", headers: [], body: .none).lightweightValidationMessage,
            "Use an absolute http or https URL."
        )
    }

    func testVariableNameValidationUsesStrictSyntax() {
        XCTAssertTrue(Variable.isValidName("base_url"))
        XCTAssertTrue(Variable.isValidName("_token"))
        XCTAssertTrue(Variable.isValidName("tenant-id"))
        XCTAssertFalse(Variable.isValidName(""))
        XCTAssertFalse(Variable.isValidName(" user_id "))
        XCTAssertFalse(Variable.isValidName("user id"))
        XCTAssertFalse(Variable.isValidName("123_id"))
        XCTAssertFalse(Variable.isValidName("tøken"))
        XCTAssertFalse(Variable.isValidName("变量"))
    }

    func testVariableParserUsesNewestDuplicateWithoutCrashing() {
        let older = Variable(
            name: "host",
            value: "old.example.com",
            scope: .global,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let newer = Variable(
            name: "host",
            value: "new.example.com",
            scope: .global,
            createdAt: Date(timeIntervalSince1970: 2),
            updatedAt: Date(timeIntervalSince1970: 2)
        )

        let tokens = VariableTemplateParser.parse("https://{{host}}", variables: [older, newer]).compactMap { segment -> VariableToken? in
            guard case .token(let token) = segment else { return nil }
            return token
        }

        XCTAssertEqual(tokens.first?.resolvedValue, "new.example.com")
        XCTAssertEqual(VariableLookup(variables: [older, newer]).duplicateNames, ["host"])
    }

    func testVariableParserFindsResolvedMissingAndInvalidTokens() {
        let variable = Variable(
            name: "base_url",
            value: "example.com",
            scope: .global,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )

        let segments = VariableTemplateParser.parse(
            "https://{{base_url}}/{{user_id}}/{{ user id }}",
            variables: [variable]
        )
        let tokens = segments.compactMap { segment -> VariableToken? in
            if case .token(let token) = segment { return token }
            return nil
        }

        XCTAssertEqual(tokens.map(\.status), [.resolved, .missing, .invalid])
        XCTAssertEqual(tokens[0].name, "base_url")
        XCTAssertEqual(tokens[0].resolvedValue, "example.com")
        XCTAssertEqual(tokens[1].name, "user_id")
        XCTAssertEqual(tokens[2].rawText, "{{ user id }}")
    }

    func testURLTokenEditingPolicyTreatsVariablesAsAtomicRanges() {
        let text = "http://x/{{auth}}/z"
        let tokenRange = NSRange(location: 9, length: 8)

        XCTAssertEqual(URLTokenEditingPolicy.tokenRanges(in: text), [tokenRange])
        XCTAssertEqual(
            URLTokenEditingPolicy.adjustedSelectionRange(
                NSRange(location: 11, length: 0),
                previousSelection: NSRange(location: 9, length: 0),
                in: text
            ),
            NSRange(location: 17, length: 0)
        )
        XCTAssertEqual(
            URLTokenEditingPolicy.adjustedSelectionRange(
                NSRange(location: 15, length: 0),
                previousSelection: NSRange(location: 17, length: 0),
                in: text
            ),
            NSRange(location: 9, length: 0)
        )
        XCTAssertEqual(URLTokenEditingPolicy.tokenRangeBeforeOrContainingCaret(17, in: text), tokenRange)
        XCTAssertEqual(URLTokenEditingPolicy.tokenRangeBeforeOrContainingCaret(16, in: text), tokenRange)
        XCTAssertEqual(URLTokenEditingPolicy.tokenRangeAfterOrContainingCaret(9, in: text), tokenRange)
        XCTAssertEqual(URLTokenEditingPolicy.tokenRangeAfterOrContainingCaret(10, in: text), tokenRange)
        XCTAssertEqual(
            URLTokenEditingPolicy.expandedRangeIncludingTokens(NSRange(location: 12, length: 1), in: text),
            tokenRange
        )
        XCTAssertEqual(
            URLTokenEditingPolicy.expandedRangeIncludingTokens(NSRange(location: 16, length: 1), in: text),
            tokenRange,
            "Backspace fallback inside a token must delete the entire token, not a single brace."
        )
        XCTAssertEqual(
            URLTokenEditingPolicy.correctedTextAfterAtomicTokenEdit(
                previousText: text,
                currentText: "http://x/{{auth}/z"
            )?.text,
            "http://x//z",
            "If AppKit applies a one-character token deletion first, the next normalization pass must delete the whole token."
        )
        XCTAssertEqual(
            URLTokenEditingPolicy.expandedRangeIncludingTokens(NSRange(location: 17, length: 0), in: text),
            NSRange(location: 17, length: 0),
            "Typing immediately after a token must not replace the token."
        )
    }

    func testURLTokenEditingPolicyIgnoresIncompleteVariablesUntilClosed() {
        XCTAssertEqual(URLTokenEditingPolicy.tokenRanges(in: "http://x/{{auth"), [])
        XCTAssertEqual(URLTokenEditingPolicy.tokenRanges(in: "http://x/{{auth}/z"), [])
    }

    func testIncompleteOpeningDoesNotConsumeLaterCompleteVariable() {
        let text = "http://localhost:{{/post?a={{auth}}"
        let source = text as NSString
        let authRange = source.range(of: "{{auth}}")
        let incompleteCaret = source.range(of: "{{/post").location + 2

        XCTAssertEqual(URLTokenEditingPolicy.tokenRanges(in: text), [authRange])
        XCTAssertEqual(
            URLTokenEditingPolicy.adjustedSelectionRange(
                NSRange(location: incompleteCaret, length: 0),
                previousSelection: NSRange(location: incompleteCaret - 1, length: 0),
                in: text
            ),
            NSRange(location: incompleteCaret, length: 0),
            "The caret must remain editable beside an incomplete opening instead of jumping to the later token."
        )
    }

    func testVariableResolverResolvesURLAndEnabledHeaderValues() {
        let tokenHeader = Header(name: "Authorization", value: "Bearer {{token}}", isEnabled: true)
        let request = Request(
            method: .get,
            urlString: "https://{{base_url}}/users/{{user_id}}",
            headers: [tokenHeader],
            body: .text(#"{"id":"{{literal_body}}"}"#)
        )
        let variables = [
            Variable(name: "base_url", value: "example.com", scope: .request, requestID: UUID()),
            Variable(name: "user_id", value: "42", scope: .request, requestID: UUID()),
            Variable(name: "token", value: "abc", scope: .global)
        ]

        let result = VariableResolver.resolve(request, variables: variables)

        XCTAssertEqual(result.resolvedRequest?.urlString, "https://example.com/users/42")
        XCTAssertEqual(result.resolvedRequest?.headers.first?.value, "Bearer abc")
        XCTAssertEqual(result.resolvedRequest?.body, .text(#"{"id":"{{literal_body}}"}"#))
        XCTAssertEqual(request.urlString, "https://{{base_url}}/users/{{user_id}}")
    }

    func testVariableResolverBlocksMissingEnabledHeaderButIgnoresDisabledHeader() {
        let enabled = Header(name: "Authorization", value: "Bearer {{token}}", isEnabled: true)
        let disabled = Header(name: "X-Debug", value: "{{debug_token}}", isEnabled: false)
        let request = Request(
            method: .get,
            urlString: "https://example.com",
            headers: [enabled, disabled],
            body: .none
        )

        let missingEnabled = VariableResolver.resolve(request, variables: [])

        XCTAssertNil(missingEnabled.resolvedRequest)
        XCTAssertEqual(missingEnabled.missingNames, ["token"])

        let resolved = VariableResolver.resolve(
            Request(method: .get, urlString: "https://example.com", headers: [disabled], body: .none),
            variables: []
        )

        XCTAssertEqual(resolved.resolvedRequest?.urlString, "https://example.com")
        XCTAssertEqual(resolved.headerValueTokensByHeaderID[disabled.id]?.first?.status, .missing)
    }

    func testVariableResolverGroupsInvalidSyntaxAndMissingVariables() {
        let request = Request(
            method: .get,
            urlString: "https://{{ base_url }}/{{user_id}}",
            headers: [],
            body: .none
        )

        let result = VariableResolver.resolve(request, variables: [])

        XCTAssertNil(result.resolvedRequest)
        XCTAssertEqual(result.invalidTokens, ["{{ base_url }}"])
        XCTAssertEqual(result.missingNames, ["user_id"])
        XCTAssertEqual(
            result.errorMessage,
            "Fix variable references before running. Invalid: {{ base_url }}. Missing: user_id"
        )
    }

    func testVariableResolverRejectsTemplatesInEnabledHeaderNames() {
        let request = Request(
            method: .get,
            urlString: "https://example.com",
            headers: [Header(name: "X-{{tenant}}", value: "value", isEnabled: true)],
            body: .none
        )
        let variable = Variable(name: "tenant", value: "acme", scope: .global)

        let result = VariableResolver.resolve(request, variables: [variable])

        XCTAssertNil(result.resolvedRequest)
        XCTAssertEqual(result.invalidTokens, ["{{tenant}}"])
    }

    func testVariableResolverRejectsUnterminatedEnabledHeaderValue() {
        let request = Request(
            method: .get,
            urlString: "https://example.com",
            headers: [Header(name: "Authorization", value: "Bearer {{token", isEnabled: true)],
            body: .none
        )

        let result = VariableResolver.resolve(request, variables: [])

        XCTAssertNil(result.resolvedRequest)
        XCTAssertEqual(result.invalidTokens, ["{{token"])

        let emptyToken = VariableResolver.resolve(
            Request(
                method: .get,
                urlString: "https://example.com",
                headers: [Header(name: "X-Template", value: "{{", isEnabled: true)],
                body: .none
            ),
            variables: []
        )
        XCTAssertNil(emptyToken.resolvedRequest)
        XCTAssertEqual(emptyToken.invalidTokens, ["{{"])
    }

    func testVariableResolverIgnoresTemplatesInDisabledHeaders() {
        let disabled = Header(name: "X-{{tenant}}", value: "Bearer {{token", isEnabled: false)
        let request = Request(method: .get, urlString: "https://example.com", headers: [disabled], body: .none)

        let result = VariableResolver.resolve(request, variables: [])

        XCTAssertEqual(result.resolvedRequest?.headers, [disabled])
        XCTAssertNil(result.errorMessage)
    }

    func testVariableResolverRecursivelyResolvesURLAndHeaderValues() {
        let header = Header(name: "Authorization", value: "{{authorization}}", isEnabled: true)
        let request = Request(
            method: .get,
            urlString: "{{base_url}}/users",
            headers: [header],
            body: .none
        )
        let variables = [
            Variable(name: "scheme", value: "https", scope: .global),
            Variable(name: "host", value: "example.com", scope: .global),
            Variable(name: "base_url", value: "{{scheme}}://{{host}}", scope: .global),
            Variable(name: "token", value: "abc", scope: .global),
            Variable(name: "authorization", value: "Bearer {{token}}", scope: .global)
        ]

        let result = VariableResolver.resolve(request, variables: variables)

        XCTAssertEqual(result.resolvedRequest?.urlString, "https://example.com/users")
        XCTAssertEqual(result.resolvedRequest?.headers.first?.value, "Bearer abc")
        XCTAssertEqual(result.urlTokens.first?.resolvedValue, "https://example.com")
        XCTAssertEqual(result.headerValueTokensByHeaderID[header.id]?.first?.resolvedValue, "Bearer abc")
        XCTAssertEqual(
            result.referencedVariableNames,
            Set(["authorization", "base_url", "host", "scheme", "token"])
        )
        XCTAssertEqual(request.urlString, "{{base_url}}/users")
        XCTAssertEqual(request.headers.first?.value, "{{authorization}}")
    }

    func testVariableResolverReportsMissingNestedLeafAndDependencyContext() {
        let request = Request(method: .get, urlString: "https://example.com", headers: [
            Header(name: "Authorization", value: "{{authorization}}")
        ], body: .none)
        let variables = [
            Variable(name: "authorization", value: "Bearer {{token}}", scope: .global)
        ]

        let result = VariableResolver.resolve(request, variables: variables)

        XCTAssertNil(result.resolvedRequest)
        XCTAssertEqual(result.missingNames, ["token"])
        XCTAssertEqual(result.errorMessage, "Define token before running this request.")
        XCTAssertEqual(
            result.expansionIssues,
            [.missing(name: "token", path: ["authorization", "token"])]
        )
        XCTAssertEqual(result.headerValueTokensByHeaderID.values.first?.first?.status, .missing)
        XCTAssertEqual(
            result.headerValueTokensByHeaderID.values.first?.first?.diagnostic,
            "authorization → token refers to missing variable token"
        )
    }

    func testVariableResolverReportsSelfAndIndirectCycles() {
        let selfCycle = VariableResolver.resolve(
            Request(method: .get, urlString: "https://example.com/{{self_ref}}", headers: [], body: .none),
            variables: [Variable(name: "self_ref", value: "{{self_ref}}", scope: .global)]
        )
        XCTAssertEqual(
            selfCycle.expansionIssues,
            [.cycle(path: ["self_ref", "self_ref"])]
        )
        XCTAssertEqual(
            selfCycle.errorMessage,
            "Fix variable references before running. Circular: self_ref → self_ref"
        )

        let indirectCycle = VariableResolver.resolve(
            Request(method: .get, urlString: "https://example.com/{{a}}", headers: [], body: .none),
            variables: [
                Variable(name: "a", value: "{{b}}", scope: .global),
                Variable(name: "b", value: "{{c}}", scope: .global),
                Variable(name: "c", value: "{{a}}", scope: .global)
            ]
        )
        XCTAssertEqual(
            indirectCycle.expansionIssues,
            [.cycle(path: ["a", "b", "c", "a"])]
        )

        let repeatedCycle = VariableResolver.resolve(
            Request(method: .get, urlString: "https://example.com/{{b}}/{{a}}", headers: [], body: .none),
            variables: [
                Variable(name: "a", value: "{{b}}", scope: .global),
                Variable(name: "b", value: "{{a}}", scope: .global)
            ]
        )
        XCTAssertEqual(
            repeatedCycle.expansionIssues,
            [.cycle(path: ["a", "b", "a"])],
            "Rotations of the same logical cycle must consume only one diagnostic slot."
        )
    }

    func testVariableResolverUsesNewestDuplicateInsideNestedExpansion() {
        let older = Variable(
            name: "token",
            value: "old",
            scope: .global,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let newer = Variable(
            name: "token",
            value: "new",
            scope: .global,
            createdAt: Date(timeIntervalSince1970: 2),
            updatedAt: Date(timeIntervalSince1970: 2)
        )
        let authorization = Variable(
            name: "authorization",
            value: "Bearer {{token}}",
            scope: .global
        )
        let request = Request(
            method: .get,
            urlString: "https://example.com",
            headers: [Header(name: "Authorization", value: "{{authorization}}")],
            body: .none
        )

        let result = VariableResolver.resolve(
            request,
            variables: [authorization, older, newer]
        )

        XCTAssertEqual(result.resolvedRequest?.headers.first?.value, "Bearer new")
    }

    func testVariableResolverRejectsInvalidSyntaxInsideNestedValue() {
        let request = Request(
            method: .get,
            urlString: "https://example.com",
            headers: [Header(name: "Authorization", value: "{{authorization}}")],
            body: .none
        )
        let result = VariableResolver.resolve(request, variables: [
            Variable(
                name: "authorization",
                value: "Bearer {{ token }} and {{unfinished",
                scope: .global
            )
        ])

        XCTAssertNil(result.resolvedRequest)
        XCTAssertEqual(result.invalidTokens, ["{{ token }}", "{{unfinished"])
        XCTAssertEqual(
            result.expansionIssues,
            [
                .invalidSyntax(token: "{{ token }}", path: ["authorization"]),
                .invalidSyntax(token: "{{unfinished", path: ["authorization"])
            ]
        )
    }

    func testVariableResolverLimitsEachDiagnosticCategoryToThreeExamples() {
        let request = Request(
            method: .get,
            urlString: "https://example.com/{{a}}/{{b}}/{{c}}/{{d}}",
            headers: [Header(name: "X-Invalid", value: "{{ bad1 }}{{ bad2 }}{{ bad3 }}{{ bad4 }}")],
            body: .none
        )

        let result = VariableResolver.resolve(request, variables: [])

        XCTAssertEqual(
            result.errorMessage,
            "Fix variable references before running. " +
                "Invalid: {{ bad1 }}, {{ bad2 }}, {{ bad3 }} +1 more. " +
                "Missing: a, b, c +1 more"
        )
    }

    func testVariableResolverOnlyValidatesReachableChains() {
        let request = Request(
            method: .get,
            urlString: "https://{{host}}",
            headers: [Header(name: "X-Disabled", value: "{{bad}}", isEnabled: false)],
            body: .none
        )
        let variables = [
            Variable(name: "host", value: "example.com", scope: .global),
            Variable(name: "bad", value: "{{missing}}", scope: .global),
            Variable(name: "cycle", value: "{{cycle}}", scope: .global)
        ]

        let result = VariableResolver.resolve(request, variables: variables)

        XCTAssertEqual(result.resolvedRequest?.urlString, "https://example.com")
        XCTAssertNil(result.errorMessage)
    }

    func testVariableResolverEnforcesSixteenLevelDepthLimit() {
        func variables(count: Int) -> [Variable] {
            (1...count).map { index in
                Variable(
                    name: "v\(index)",
                    value: index == count ? "done" : "{{v\(index + 1)}}",
                    scope: .global
                )
            }
        }
        let request = Request(method: .get, urlString: "https://example.com/{{v1}}", headers: [], body: .none)

        XCTAssertEqual(
            VariableResolver.resolve(request, variables: variables(count: 16)).resolvedRequest?.urlString,
            "https://example.com/done"
        )

        let tooDeep = VariableResolver.resolve(request, variables: variables(count: 17))
        XCTAssertNil(tooDeep.resolvedRequest)
        guard case .depthExceeded(let path, let limit) = tooDeep.expansionIssues.first else {
            return XCTFail("Expected a depth error")
        }
        XCTAssertEqual(limit, 16)
        XCTAssertEqual(path, (1...17).map { "v\($0)" })
    }

    func testVariableResolverEnforcesExpandedUTF8ByteLimit() {
        let request = Request(method: .get, urlString: "https://example.com", headers: [
            Header(name: "X-Large", value: "{{large}}")
        ], body: .none)

        let atLimit = VariableResolver.resolve(request, variables: [
            Variable(name: "large", value: String(repeating: "x", count: 64 * 1_024), scope: .global)
        ])
        XCTAssertEqual(atLimit.resolvedRequest?.headers.first?.value.utf8.count, 64 * 1_024)

        let overLimit = VariableResolver.resolve(request, variables: [
            Variable(name: "large", value: String(repeating: "é", count: 32 * 1_024 + 1), scope: .global)
        ])
        XCTAssertNil(overLimit.resolvedRequest)
        XCTAssertEqual(
            overLimit.expansionIssues,
            [.outputTooLarge(path: ["large"], limitBytes: 64 * 1_024)]
        )
    }

    func testVariableResolverStopsMaterializingAtExpandedUTF8ByteLimit() {
        let leaf = Variable(
            name: "leaf",
            value: String(repeating: "x", count: VariableValueResolver.maximumExpandedUTF8Bytes),
            scope: .global
        )
        let amplified = Variable(
            name: "amplified",
            value: String(repeating: "{{leaf}}", count: 128),
            scope: .global
        )
        var resolver = VariableValueResolver(
            variablesByName: VariableLookup(variables: [leaf, amplified]).variablesByName
        )

        let expansion = resolver.resolveVariable(named: "amplified")

        XCTAssertEqual(
            expansion.issues,
            [.outputTooLarge(path: ["amplified"], limitBytes: VariableValueResolver.maximumExpandedUTF8Bytes)]
        )
        XCTAssertLessThanOrEqual(
            resolver.maximumMaterializedUTF8Bytes,
            VariableValueResolver.maximumExpandedUTF8Bytes,
            "The resolver must reject amplification before allocating the complete expanded value."
        )
    }

    func testVariableResolverMemoizesRepeatedContextIndependentFailures() {
        let invalidLeaf = Variable(name: "invalid_leaf", value: "{{missing}}", scope: .global)
        let fanOut = Variable(
            name: "fan_out",
            value: String(repeating: "{{invalid_leaf}}", count: 250),
            scope: .global
        )
        var resolver = VariableValueResolver(
            variablesByName: VariableLookup(variables: [invalidLeaf, fanOut]).variablesByName
        )

        let expansion = resolver.resolveVariable(named: "fan_out")

        XCTAssertEqual(
            expansion.issues,
            [.missing(name: "missing", path: ["fan_out", "invalid_leaf", "missing"])]
        )
        XCTAssertEqual(
            resolver.uncachedResolutionCount,
            2,
            "The failed leaf should be evaluated once and reused for every sibling reference."
        )
    }

    func testFailureCacheRebasesDepthForNearLimitReuse() {
        var variables = [
            Variable(name: "bad", value: "{{missing}}", scope: .global),
            Variable(name: "warmup", value: "{{bad}}", scope: .global)
        ]
        variables.append(contentsOf: (1...14).map { index in
            Variable(
                name: "v\(index)",
                value: index == 14 ? "{{bad}}" : "{{v\(index + 1)}}",
                scope: .global
            )
        })
        variables.append(Variable(name: "v0", value: "{{v1}}", scope: .global))
        var resolver = VariableValueResolver(
            variablesByName: VariableLookup(variables: variables).variablesByName
        )

        XCTAssertEqual(
            resolver.resolveVariable(named: "warmup").issues,
            [.missing(name: "missing", path: ["warmup", "bad", "missing"])]
        )
        XCTAssertEqual(
            resolver.resolveVariable(named: "v1").issues,
            [.missing(
                name: "missing",
                path: (1...14).map { "v\($0)" } + ["bad", "missing"]
            )],
            "The missing reference at level sixteen must still report the cached missing leaf."
        )
        XCTAssertEqual(
            resolver.resolveVariable(named: "v0").issues,
            [.depthExceeded(
                path: ["v0"] + (1...14).map { "v\($0)" } + ["bad", "missing"],
                limit: VariableValueResolver.maximumDepth
            )],
            "The missing reference at level seventeen must report depth before reusing the cached failure."
        )
    }

    func testVariableResolverTracksReachableNamesButExcludesDisabledHeaders() {
        let request = Request(
            method: .get,
            urlString: "https://{{base}}",
            headers: [
                Header(name: "Authorization", value: "{{authorization}}"),
                Header(name: "X-Disabled", value: "{{ignored}}", isEnabled: false)
            ],
            body: .none
        )
        let result = VariableResolver.resolve(request, variables: [
            Variable(name: "base", value: "{{host}}", scope: .global),
            Variable(name: "host", value: "example.com", scope: .global),
            Variable(name: "authorization", value: "Bearer {{token}}", scope: .global),
            Variable(name: "token", value: "abc", scope: .global),
            Variable(name: "ignored", value: "{{also_ignored}}", scope: .global),
            Variable(name: "also_ignored", value: "value", scope: .global)
        ])

        XCTAssertEqual(
            result.referencedVariableNames,
            Set(["authorization", "base", "host", "token"])
        )
    }

    func testVariableResolverPreservesWhitespaceEmptyValuesAndLiteralBody() {
        let request = Request(
            method: .post,
            urlString: "https://example.com",
            headers: [
                Header(name: "X-Whitespace", value: "prefix{{spaced}}suffix"),
                Header(name: "X-Empty", value: "{{empty}}")
            ],
            body: .text(#"{"token":"{{spaced}}"}"#)
        )
        let result = VariableResolver.resolve(request, variables: [
            Variable(name: "spaced", value: " value ", scope: .global),
            Variable(name: "empty", value: "", scope: .global)
        ])

        XCTAssertEqual(result.resolvedRequest?.headers[0].value, "prefix value suffix")
        XCTAssertEqual(result.resolvedRequest?.headers[1].value, "")
        XCTAssertEqual(result.resolvedRequest?.body, .text(#"{"token":"{{spaced}}"}"#))
    }

    func testVariablePreviewUsesFinalNestedValueAndDiagnostic() {
        let valid = VariableTemplateParser.parse("{{authorization}}", variables: [
            Variable(name: "authorization", value: "Bearer {{token}}", scope: .global),
            Variable(name: "token", value: "abc", scope: .global)
        ])
        guard case .token(let resolvedToken) = valid.first else {
            return XCTFail("Expected token")
        }
        XCTAssertEqual(resolvedToken.status, .resolved)
        XCTAssertEqual(resolvedToken.resolvedValue, "Bearer abc")
        XCTAssertNil(resolvedToken.diagnostic)

        let invalid = VariableTemplateParser.parse("{{authorization}}", variables: [
            Variable(name: "authorization", value: "Bearer {{missing}}", scope: .global)
        ])
        guard case .token(let invalidToken) = invalid.first else {
            return XCTFail("Expected token")
        }
        XCTAssertEqual(invalidToken.status, .missing)
        XCTAssertEqual(invalidToken.diagnostic, "authorization → missing refers to missing variable missing")
    }
}
