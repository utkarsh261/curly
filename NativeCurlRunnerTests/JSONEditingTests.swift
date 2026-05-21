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

    func testLexerHandlesBooleansAndNullLiteralsAndEdgeCases() {
        // Test standard literals
        let tokens1 = JSONLexer.tokenize("true false null")
        XCTAssertEqual(tokens1.count, 5) // true, space, false, space, null
        XCTAssertEqual(tokens1[0].kind, .boolLiteral)
        XCTAssertEqual(tokens1[0].range, NSRange(location: 0, length: 4))
        XCTAssertEqual(tokens1[2].kind, .boolLiteral)
        XCTAssertEqual(tokens1[2].range, NSRange(location: 5, length: 5))
        XCTAssertEqual(tokens1[4].kind, .nullLiteral)
        XCTAssertEqual(tokens1[4].range, NSRange(location: 11, length: 4))

        // Test boundary / prefix edge cases (none of these should match as literals, but as individual chars / others)
        let tokens2 = JSONLexer.tokenize("tru fals nul")
        // "tru" -> 't', 'r', 'u' (each as .other)
        XCTAssertEqual(tokens2.filter { $0.kind == .boolLiteral || $0.kind == .nullLiteral }.count, 0)

        // Test trailing characters (prefix scanning behavior of the lexer)
        let tokens3 = JSONLexer.tokenize("truea falseb nullc")
        XCTAssertEqual(tokens3.count, 8)
        XCTAssertEqual(tokens3[0].kind, .boolLiteral)
        XCTAssertEqual(tokens3[0].range, NSRange(location: 0, length: 4))
        XCTAssertEqual(tokens3[1].kind, .other)
        XCTAssertEqual(tokens3[3].kind, .boolLiteral)
        XCTAssertEqual(tokens3[3].range, NSRange(location: 6, length: 5))
        XCTAssertEqual(tokens3[4].kind, .other)
        XCTAssertEqual(tokens3[6].kind, .nullLiteral)
        XCTAssertEqual(tokens3[6].range, NSRange(location: 13, length: 4))
        XCTAssertEqual(tokens3[7].kind, .other)

        // Test literals inside strings (should be treated as string content only)
        let tokens4 = JSONLexer.tokenize(##"{"a": true, "b": "true"}"##)
        // Expected string tokens: "a", "true" (under "b")
        XCTAssertEqual(tokens4.filter { $0.kind == .string }.count, 3) // "a", "b", "true"
        XCTAssertEqual(tokens4.filter { $0.kind == .boolLiteral }.count, 1) // the unquoted true
    }
}

