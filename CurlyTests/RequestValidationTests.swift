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

    func testVariableResolverBlocksInvalidSyntaxBeforeMissingVariables() {
        let request = Request(
            method: .get,
            urlString: "https://{{ base_url }}/{{user_id}}",
            headers: [],
            body: .none
        )

        let result = VariableResolver.resolve(request, variables: [])

        XCTAssertNil(result.resolvedRequest)
        XCTAssertEqual(result.invalidTokens, ["{{ base_url }}"])
        XCTAssertEqual(result.missingNames, [])
        XCTAssertEqual(result.errorMessage, "Fix invalid variable syntax. Use {{name}} with no spaces. Invalid: {{ base_url }}")
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
    }

    func testVariableResolverIgnoresTemplatesInDisabledHeaders() {
        let disabled = Header(name: "X-{{tenant}}", value: "Bearer {{token", isEnabled: false)
        let request = Request(method: .get, urlString: "https://example.com", headers: [disabled], body: .none)

        let result = VariableResolver.resolve(request, variables: [])

        XCTAssertEqual(result.resolvedRequest?.headers, [disabled])
        XCTAssertNil(result.errorMessage)
    }

    func testVariableResolverDoesNotResolveRecursively() {
        let request = Request(method: .get, urlString: "https://{{base_url}}/users", headers: [], body: .none)
        let variables = [
            Variable(name: "base_url", value: "{{host}}", scope: .global),
            Variable(name: "host", value: "example.com", scope: .global)
        ]

        let result = VariableResolver.resolve(request, variables: variables)

        XCTAssertNil(result.resolvedRequest)
        XCTAssertEqual(result.errorMessage, "The URL is not valid yet.")
    }
}
