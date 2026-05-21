import XCTest
@testable import NativeCurlRunner

final class JSONEditingTests: XCTestCase {
    func testLexerTreatsCommentMarkersInsideStringsAsStringContent() {
        let text = #"{"url":"https://example.com/a//b","glob":"/* not a comment */"} // real"#

        let tokens = JSONLexer.tokenize(text)

        XCTAssertEqual(tokens.filter { $0.kind == .string }.count, 4)
        XCTAssertEqual(tokens.filter { $0.kind == .lineComment }.count, 1)
    }

    func testCommentStripperRemovesCommentsOutsideStringsOnly() {
        let text = """
        {
          // keep url untouched
          "url": "https://example.com/a//b",
          "note": "/* still text */",
          /* remove block */
          "ok": true
        }
        """

        let stripped = JSONCommentStripper.stripComments(from: text)

        XCTAssertTrue(stripped.contains(#""https://example.com/a//b""#))
        XCTAssertTrue(stripped.contains(#""/* still text */""#))
        XCTAssertFalse(stripped.contains("keep url untouched"))
        XCTAssertFalse(stripped.contains("remove block"))
    }

    func testValidatorAcceptsCommentsButRejectsTrailingCommas() {
        let valid = """
        {
          // comment
          "name": "utk"
        }
        """
        let invalid = """
        {
          "name": "utk",
        }
        """

        XCTAssertTrue(JSONValidator.validate(valid).isValid)
        XCTAssertFalse(JSONValidator.validate(invalid).isValid)
    }

    func testFoldRangesIgnoreBracesInsideStringsAndComments() {
        let text = """
        {
          "template": "{not a block}",
          // [not an array]
          "items": [
            {
              "id": 1
            }
          ]
        }
        """

        let folds = JSONFoldIndex.foldRanges(in: text)

        XCTAssertEqual(folds.map(\.kind), [.object, .array, .object])
        XCTAssertEqual(folds.map(\.kind.placeholder), ["{...}", "[...]", "{...}"])
    }

    func testFoldRangesOnlyIncludeMultilineContainers() {
        let text = """
        {
          "inline": {"a": 1},
          "multi": {
            "b": 2
          }
        }
        """

        let folds = JSONFoldIndex.foldRanges(in: text)

        XCTAssertEqual(folds.count, 2)
        XCTAssertEqual(folds.map(\.kind), [.object, .object])
    }

    func testFormatKeepsFullLineCommentsAtTheirOriginalRelativePosition() throws {
        let text = """
        {
          // auth payload
          "user":{"name":"utk"}
        }
        """

        let formatted = try JSONFormatter.format(text)

        XCTAssertFalse(formatted.hasPrefix("// auth payload"))
        XCTAssertTrue(formatted.contains("{\n  // auth payload\n"))
        XCTAssertTrue(formatted.contains(#"  "user" : {"#))
        XCTAssertTrue(formatted.contains(#"    "name" : "utk""#))
    }

    func testCompactKeepsFullLineCommentsAtTheirOriginalRelativePosition() throws {
        let text = """
        {
          // auth payload
          "user": {
            "name": "utk"
          }
        }
        """

        let compacted = try JSONFormatter.compact(text)

        XCTAssertEqual(
            compacted,
            text
        )
    }
}
