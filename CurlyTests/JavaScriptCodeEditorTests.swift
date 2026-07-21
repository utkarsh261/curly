import AppKit
import XCTest
@testable import Curly

@MainActor
final class JavaScriptCodeEditorTests: XCTestCase {
    func testDoubleClickSelectionStopsAtMemberAccessBoundaries() {
        let source = #"curly.variables.global.set("token", "value")"#
        let textView = makeTextView(source)

        let selection = wordSelection(in: textView, inside: "global")

        XCTAssertEqual((source as NSString).substring(with: selection), "global")
    }

    func testDoubleClickSelectionKeepsJavaScriptIdentifierCharactersTogether() {
        let source = "const $session_token2 = café42;"
        let textView = makeTextView(source)

        XCTAssertEqual(
            (source as NSString).substring(with: wordSelection(in: textView, inside: "$session_token2")),
            "$session_token2"
        )
        XCTAssertEqual(
            (source as NSString).substring(with: wordSelection(in: textView, inside: "café42")),
            "café42"
        )
    }

    func testReplacingSelectedMemberPreservesRestOfScript() {
        let source = #"curly.variables.global.set("token", "value")"#
        let textView = makeTextView(source)
        let selection = wordSelection(in: textView, inside: "global")

        textView.insertText("request", replacementRange: selection)

        XCTAssertEqual(textView.string, #"curly.variables.request.set("token", "value")"#)
    }

    func testProgrammaticReplacementClearsUndoHistoryBeforeRangesBecomeStale() {
        let textView = UndoManagedTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
        textView.string = "a"
        textView.allowsUndo = true
        guard let undoManager = textView.undoManager else {
            return XCTFail("Expected an undo manager")
        }
        undoManager.registerUndo(withTarget: textView) { target in
            target.string = "a"
        }
        XCTAssertTrue(undoManager.canUndo)

        JavaScriptCodeEditorView.replaceContents(of: textView, with: "b")

        XCTAssertEqual(textView.string, "b")
        XCTAssertFalse(undoManager.canUndo)
        undoManager.undo()
        XCTAssertEqual(textView.string, "b")
    }

    private func makeTextView(_ source: String) -> JavaScriptTextView {
        let textView = JavaScriptTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
        textView.string = source
        return textView
    }

    private func wordSelection(in textView: JavaScriptTextView, inside token: String) -> NSRange {
        let tokenRange = (textView.string as NSString).range(of: token)
        XCTAssertNotEqual(tokenRange.location, NSNotFound)
        return textView.selectionRange(
            forProposedRange: NSRange(location: tokenRange.location + tokenRange.length / 2, length: 0),
            granularity: .selectByWord
        )
    }
}

private final class UndoManagedTextView: NSTextView {
    private let managedUndoManager = UndoManager()

    override var undoManager: UndoManager? { managedUndoManager }
}
