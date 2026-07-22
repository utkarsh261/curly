import AppKit
import SwiftUI
import XCTest
@testable import Curly

final class JSONTextKitFoldingSpikeTests: XCTestCase {
    func testFoldedRangeHidesGlyphsWithoutMutatingSourceText() {
        let source = """
        {
          "user": {
            "name": "utk"
          }
        }
        """
        let storage = NSTextStorage(string: source)
        let layoutManager = JSONFoldingLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))

        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)

        let userObjectRange = (source as NSString).range(of: """
        {
            "name": "utk"
          }
        """)
        XCTAssertNotEqual(userObjectRange.location, NSNotFound)

        layoutManager.foldedRanges = [userObjectRange]
        layoutManager.ensureLayout(for: textContainer)

        let hiddenCharacterLocation = userObjectRange.location + 1
        let visibleOpenBraceLocation = userObjectRange.location
        let hiddenGlyphIndex = layoutManager.glyphIndexForCharacter(at: hiddenCharacterLocation)
        let openBraceGlyphIndex = layoutManager.glyphIndexForCharacter(at: visibleOpenBraceLocation)

        XCTAssertTrue(layoutManager.isHiddenFoldCharacter(at: hiddenCharacterLocation))
        XCTAssertEqual(layoutManager.propertyForGlyph(at: hiddenGlyphIndex), .null)
        XCTAssertNotEqual(layoutManager.propertyForGlyph(at: openBraceGlyphIndex), .null)
        XCTAssertEqual(storage.string, source)
    }

    @MainActor
    func testRulerViewCachesFoldStartLinesAndInvalidatesCacheCorrectly() {
        let source = """
        {
          "user": {
            "name": "utk"
          }
        }
        """
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        let textStorage = NSTextStorage(string: source)
        let layoutManager = JSONFoldingLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), textContainer: textContainer)
        scrollView.documentView = textView
        
        let ruler = JSONLineNumberRulerView(textView: textView)
        scrollView.verticalRulerView = ruler
        
        // Initially, the cache must be nil
        XCTAssertNil(ruler.cachedFoldStartLines)
        XCTAssertNil(ruler.cachedLineMap)
        
        // We push a graphics context to allow safe drawing without crashing
        let image = NSImage(size: NSSize(width: 52, height: 400))
        image.lockFocus()
        ruler.drawHashMarksAndLabels(in: NSRect(x: 0, y: 0, width: 52, height: 400))
        image.unlockFocus()
        
        // Now, cache should be populated
        XCTAssertNotNil(ruler.cachedFoldStartLines)
        XCTAssertNotNil(ruler.cachedLineMap)
        
        // Line 0 ({) and Line 1 ("user": {) should be in the fold start lines
        XCTAssertEqual(ruler.cachedFoldStartLines, Set([0, 1]))
        
        // Invalidation should reset it back to nil
        ruler.invalidateFoldCache()
        XCTAssertNil(ruler.cachedFoldStartLines)
        XCTAssertNil(ruler.cachedLineMap)
    }

    @MainActor
    func testDiagnosticHighlightsFullLineAndMarksRulerWithoutChangingTextOrSyntaxColors() throws {
        let source = """
        {
          "good": true,
          "bad" nope
        }
        """
        let harness = makeEditorHarness(source: source)
        let result = JSONValidator.validate(source)
        let diagnostic = try XCTUnwrap(result.diagnostic)
        let originalSelection = NSRange(location: 2, length: 0)
        harness.textView.setSelectedRange(originalSelection)
        let goodKeyLocation = (source as NSString).range(of: #""good""#).location
        let originalColor = harness.textView.textStorage?.attribute(.foregroundColor, at: goodKeyLocation, effectiveRange: nil) as? NSColor

        harness.coordinator.applyDiagnostic(diagnostic, to: harness.textView)

        let lineMap = JSONLineMap(text: source)
        let expectedLine = try XCTUnwrap(diagnostic.line).advanced(by: -1)
        XCTAssertEqual(harness.textView.diagnosticLineRange, lineMap.lineRange(forZeroBasedLine: expectedLine, in: source))
        XCTAssertNotNil(harness.textView.diagnosticHighlightRect())
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(harness.textView.diagnosticHighlightRect()).width, harness.textView.visibleRect.width)
        XCTAssertEqual(harness.ruler.diagnosticLineNumber, expectedLine)
        XCTAssertEqual(harness.ruler.diagnosticMarkerLineNumber, expectedLine)
        XCTAssertEqual(harness.textView.string, source)
        XCTAssertEqual(harness.textView.selectedRange(), originalSelection)
        XCTAssertEqual(
            harness.textView.textStorage?.attribute(.foregroundColor, at: goodKeyLocation, effectiveRange: nil) as? NSColor,
            originalColor
        )
        XCTAssertFalse(harness.textView.undoManager?.canUndo ?? false)

        harness.coordinator.applyDiagnostic(nil, to: harness.textView)
        XCTAssertNil(harness.textView.diagnosticLineRange)
        XCTAssertNil(harness.ruler.diagnosticLineNumber)
        XCTAssertNil(harness.ruler.diagnosticMarkerLineNumber)
    }

    @MainActor
    func testFoldedDiagnosticUsesVisibleAncestorMarkerAndRevealExpandsAndPlacesCaret() throws {
        let source = """
        {
          "outer": {
            "nested": {
              "bad" nope
            }
          }
        }
        """
        let analysis = SyntaxAnalysisResult.analyze(source)
        let outerFold = try XCTUnwrap(analysis.foldRanges.first(where: { $0.depth == 1 }))
        let harness = makeEditorHarness(source: source, foldedRanges: [outerFold.fullRange])
        let diagnostic = try XCTUnwrap(JSONValidator.validate(source).diagnostic)
        harness.layoutManager.foldedRanges = [outerFold.fullRange]

        harness.coordinator.applyDiagnostic(diagnostic, to: harness.textView)

        let lineMap = analysis.lineMap
        let outerLine = lineMap.lineNumber(at: outerFold.openTokenRange.location)
        XCTAssertNil(harness.textView.diagnosticLineRange)
        XCTAssertNil(harness.ruler.diagnosticLineNumber)
        XCTAssertEqual(harness.ruler.diagnosticMarkerLineNumber, outerLine)

        harness.coordinator.revealDiagnostic(diagnostic, in: harness.textView)

        XCTAssertTrue(harness.state.foldedRanges.isEmpty)
        XCTAssertTrue(harness.layoutManager.foldedRanges.isEmpty)
        XCTAssertEqual(harness.textView.selectedRange(), NSRange(location: try XCTUnwrap(diagnostic.range).location, length: 0))
        XCTAssertNotNil(harness.textView.diagnosticLineRange)
        XCTAssertEqual(harness.ruler.diagnosticLineNumber, try XCTUnwrap(diagnostic.line) - 1)
        XCTAssertEqual(harness.ruler.diagnosticMarkerLineNumber, try XCTUnwrap(diagnostic.line) - 1)
    }

    @MainActor
    func testReadOnlyHighlightingStylesOnlyTheViewportRange() throws {
        let middle = (0..<2_000).map { "  \"item\($0)\": \($0)," }.joined(separator: "\n")
        let source = "{\n  \"first\": true,\n\(middle)\n  \"last\": null\n}"
        let harness = makeEditorHarness(source: source, highlightsVisibleRangeOnly: true)
        let requestedRange = NSRange(location: 0, length: (source as NSString).range(of: "\"item5\"").location)

        harness.coordinator.applyHighlighting(
            to: harness.textView,
            using: harness.coordinator.latestAnalysis,
            visibleCharacterRange: requestedRange
        )

        let highlightedRange = try XCTUnwrap(harness.coordinator.highlightedRange)
        XCTAssertLessThan(NSMaxRange(highlightedRange), (source as NSString).length)
        XCTAssertEqual(
            harness.textView.textStorage?.attribute(
                .foregroundColor,
                at: (source as NSString).range(of: "\"first\"").location,
                effectiveRange: nil
            ) as? NSColor,
            NSColor.systemGreen
        )
        XCTAssertEqual(
            harness.textView.textStorage?.attribute(
                .foregroundColor,
                at: (source as NSString).range(of: "\"last\"").location,
                effectiveRange: nil
            ) as? NSColor,
            NSColor.labelColor
        )
    }

    @MainActor
    func testReadOnlyEditorSelectsViewportHighlightingMode() {
        let editor = JSONCodeEditorView(
            text: .constant(#"{"ok":true}"#),
            foldedRanges: .constant([]),
            isEditable: false,
            accessibilityIdentifier: "read-only-json",
            diagnostic: nil,
            revealDiagnosticGeneration: 0
        )

        XCTAssertTrue(editor.makeCoordinator().highlightsVisibleRangeOnly)
    }

    @MainActor
    private func makeEditorHarness(
        source: String,
        foldedRanges: [NSRange] = [],
        highlightsVisibleRangeOnly: Bool = false
    ) -> EditorHarness {
        let state = EditorState(text: source, foldedRanges: foldedRanges)
        let textBinding = Binding(
            get: { state.text },
            set: { state.text = $0 }
        )
        let foldedBinding = Binding(
            get: { state.foldedRanges },
            set: { state.foldedRanges = $0 }
        )
        let coordinator = JSONCodeEditorView.Coordinator(
            text: textBinding,
            foldedRanges: foldedBinding,
            highlightsVisibleRangeOnly: highlightsVisibleRangeOnly
        )
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        let textStorage = NSTextStorage(string: source)
        let layoutManager = JSONFoldingLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)

        let textView = JSONCodeTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 300), textContainer: textContainer)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.delegate = coordinator
        scrollView.documentView = textView
        let ruler = JSONLineNumberRulerView(textView: textView)
        scrollView.verticalRulerView = ruler

        coordinator.textView = textView
        coordinator.layoutManager = layoutManager
        coordinator.rulerView = ruler
        coordinator.latestAnalysis = SyntaxAnalysisResult.analyze(source)
        coordinator.applyHighlighting(to: textView, using: coordinator.latestAnalysis)
        layoutManager.ensureLayout(for: textContainer)

        return EditorHarness(
            state: state,
            coordinator: coordinator,
            textView: textView,
            layoutManager: layoutManager,
            ruler: ruler,
            scrollView: scrollView
        )
    }
}

@MainActor
private final class EditorState {
    var text: String
    var foldedRanges: [NSRange]

    init(text: String, foldedRanges: [NSRange]) {
        self.text = text
        self.foldedRanges = foldedRanges
    }
}

@MainActor
private struct EditorHarness {
    let state: EditorState
    let coordinator: JSONCodeEditorView.Coordinator
    let textView: JSONCodeTextView
    let layoutManager: JSONFoldingLayoutManager
    let ruler: JSONLineNumberRulerView
    let scrollView: NSScrollView
}
