import XCTest
@testable import Curly

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

    func testValidatorLocatesMissingObjectSeparatorsAtUnexpectedToken() throws {
        let missingComma = """
        {
          "a": 1
          "b": 2
        }
        """
        let commaDiagnostic = try XCTUnwrap(JSONValidator.validate(missingComma).diagnostic)
        XCTAssertEqual(commaDiagnostic.line, 3)
        XCTAssertEqual(commaDiagnostic.column, 3)
        XCTAssertEqual(commaDiagnostic.message, "Expected ',' or '}' after the object value.")

        let missingColon = """
        {
          "a" 1
        }
        """
        let colonDiagnostic = try XCTUnwrap(JSONValidator.validate(missingColon).diagnostic)
        XCTAssertEqual(colonDiagnostic.line, 2)
        XCTAssertEqual(colonDiagnostic.column, 7)
        XCTAssertEqual(colonDiagnostic.message, "Expected ':' after the object key.")
    }

    func testValidatorLocatesMalformedValuesNumbersAndEscapes() throws {
        let literal = try XCTUnwrap(JSONValidator.validate(#"{"value": nope}"#).diagnostic)
        XCTAssertEqual(literal.range, NSRange(location: 10, length: 1))
        XCTAssertEqual(literal.message, "Invalid JSON literal.")

        let number = try XCTUnwrap(JSONValidator.validate(#"{"value": 01}"#).diagnostic)
        XCTAssertEqual(number.range, NSRange(location: 11, length: 1))
        XCTAssertEqual(number.message, "Numbers cannot contain leading zeroes.")

        let escape = try XCTUnwrap(JSONValidator.validate(#"{"value": "\x"}"#).diagnostic)
        XCTAssertEqual(escape.range, NSRange(location: 12, length: 1))
        XCTAssertEqual(escape.message, "Invalid string escape sequence.")
    }

    func testValidatorPointsUnfinishedConstructsAtTheirOpeningToken() throws {
        let object = try XCTUnwrap(JSONValidator.validate("{\n  \"value\": 1").diagnostic)
        XCTAssertEqual(object.range, NSRange(location: 0, length: 1))
        XCTAssertEqual(object.message, "Object is not closed.")

        let array = try XCTUnwrap(JSONValidator.validate("[1, 2").diagnostic)
        XCTAssertEqual(array.range, NSRange(location: 0, length: 1))
        XCTAssertEqual(array.message, "Array is not closed.")

        let string = try XCTUnwrap(JSONValidator.validate(#"{"value": "unfinished}"#).diagnostic)
        XCTAssertEqual(string.range, NSRange(location: 10, length: 1))
        XCTAssertEqual(string.message, "String is not closed.")

        let comment = try XCTUnwrap(JSONValidator.validate("{\n  /* unfinished\n  \"value\": 1\n}").diagnostic)
        XCTAssertEqual(comment.range, NSRange(location: 4, length: 2))
        XCTAssertEqual(comment.line, 2)
        XCTAssertEqual(comment.column, 3)
        XCTAssertEqual(comment.message, "Block comment is not closed.")
    }

    func testValidatorLocatesTrailingCommasAndMismatchedContainers() throws {
        let object = try XCTUnwrap(JSONValidator.validate(#"{"value": 1,}"#).diagnostic)
        XCTAssertEqual(object.range, NSRange(location: 11, length: 1))
        XCTAssertEqual(object.message, "Trailing commas are not allowed.")

        let array = try XCTUnwrap(JSONValidator.validate("[1, 2,]").diagnostic)
        XCTAssertEqual(array.range, NSRange(location: 5, length: 1))

        let mismatch = try XCTUnwrap(JSONValidator.validate(#"{"value": 1]"#).diagnostic)
        XCTAssertEqual(mismatch.range, NSRange(location: 11, length: 1))
        XCTAssertEqual(mismatch.message, "Expected ',' or '}' after the object value.")
    }

    func testValidatorLocatesUnexpectedContentAfterRootValue() throws {
        let result = JSONValidator.validate(#"{"ok": true} false"#)
        let diagnostic = try XCTUnwrap(result.diagnostic)

        XCTAssertEqual(diagnostic.range, NSRange(location: 13, length: 1))
        XCTAssertEqual(diagnostic.message, "Unexpected content after the top-level JSON value.")
    }

    func testDiagnosticLocationsUseOriginalCommentedUnicodeSource() throws {
        let source = """

        {
          /* 😊 comment */
          "emoji": "😊",
          "bad" nope
        }
        """
        let diagnostic = try XCTUnwrap(JSONValidator.validate(source).diagnostic)

        XCTAssertEqual(diagnostic.line, 5)
        XCTAssertEqual(diagnostic.column, 9)
        XCTAssertEqual((source as NSString).substring(with: try XCTUnwrap(diagnostic.range)), "n")
    }

    func testDiagnosticColumnsCountTabsAndEmojiAsSingleVisibleCharacters() throws {
        let source = "{\r\n\t\"emoji\": \"😊\",\r\n\t\"bad\" nope\r\n}"
        let diagnostic = try XCTUnwrap(JSONValidator.validate(source).diagnostic)

        XCTAssertEqual(diagnostic.line, 3)
        XCTAssertEqual(diagnostic.column, 8)
        XCTAssertEqual(diagnostic.displayMessage, "Line 3, column 8 — Expected ':' after the object key.")
    }

    func testDiagnosticColumnNormalizesAnOffsetInsideAComposedCharacter() {
        let diagnostic = JSONDiagnostic.located(
            message: "Test diagnostic.",
            text: "😊x",
            range: NSRange(location: 1, length: 1)
        )

        XCTAssertEqual(diagnostic.line, 1)
        XCTAssertEqual(diagnostic.column, 1)
    }

    func testValidatorPreservesCommentDeletionSemanticsAndAllowsCommentOnlyBodies() throws {
        XCTAssertTrue(JSONValidator.validate(#"{"value": tr/* join */ue}"#).isValid)
        XCTAssertTrue(JSONValidator.validate(#"{"value": "/* text, not comment */"}"#).isValid)
        XCTAssertTrue(JSONValidator.validate("  // comment\n/* another */\n").isValid)
        XCTAssertEqual(try JSONFormatter.format("  // comment\n/* another */\n"), "  // comment\n/* another */\n")
        XCTAssertEqual(try JSONFormatter.compact("  // comment\n/* another */\n"), "  // comment\n/* another */\n")
    }

    func testLocatorFallsBackWithoutLocationPastNestingLimit() throws {
        let source = String(repeating: "[", count: 257) + "invalid" + String(repeating: "]", count: 257)
        let diagnostic = try XCTUnwrap(JSONValidator.validate(source).diagnostic)

        XCTAssertNil(diagnostic.range)
        XCTAssertNil(diagnostic.line)
        XCTAssertNil(diagnostic.column)
        XCTAssertEqual(diagnostic.message, "JSON is invalid, but Curly could not determine the error location.")
    }

    func testLocatorHandlesLargeInvalidBodyWithoutLosingLocation() throws {
        let leadingWhitespace = String(repeating: " ", count: 1_000_000)
        let source = leadingWhitespace + #"{"value": nope}"#
        let diagnostic = try XCTUnwrap(JSONValidator.validate(source).diagnostic)

        XCTAssertEqual(diagnostic.range?.location, leadingWhitespace.utf16.count + 10)
        XCTAssertEqual(diagnostic.message, "Invalid JSON literal.")
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

    func testConsolidatedAnalysisMatchesDiscreteParsing() {
        let text = """
        {
          "stringVal": "hello",
          "numberVal": 123.45,
          "boolVal": true,
          "nullVal": null,
          "arrayVal": [
            {
              "nested": {}
            }
          ]
        }
        """
        
        // 1. Run consolidated analysis
        let analysis = SyntaxAnalysisResult.analyze(text)
        
        // 2. Run discrete parsing
        let expectedTokens = JSONLexer.tokenize(text)
        let expectedLineMap = JSONLineMap(text: text)
        let expectedFoldRanges = JSONFoldIndex.foldRanges(in: text)
        
        // 3. Assert exact equality
        XCTAssertEqual(analysis.tokens, expectedTokens, "Consolidated tokens should perfectly match discrete tokens")
        XCTAssertEqual(analysis.lineMap, expectedLineMap, "Consolidated line map should perfectly match discrete line map")
        XCTAssertEqual(analysis.foldRanges, expectedFoldRanges, "Consolidated fold ranges should perfectly match discrete fold ranges")
    }
    
    func testFoldRangesConsumesPrecalculatedInputs() {
        let text = """
        {
          "arr": [1, 2, 3],
          "obj": {
            "key": "val"
          }
        }
        """
        
        let tokens = JSONLexer.tokenize(text)
        let lineMap = JSONLineMap(text: text)
        
        // Pass precalculated inputs
        let foldRangesWithInputs = JSONFoldIndex.foldRanges(in: text, tokens: tokens, lineMap: lineMap)
        
        // Pass no precalculated inputs
        let foldRangesWithoutInputs = JSONFoldIndex.foldRanges(in: text)
        
        XCTAssertEqual(foldRangesWithInputs, foldRangesWithoutInputs, "Passing precalculated inputs should produce identical results")
    }

    func testLineMapLineNumberLookup() {
        let text = "line0\nline1\nline2\nline3\n"
        let lineMap = JSONLineMap(text: text)
        
        // Test exact character locations
        XCTAssertEqual(lineMap.lineNumber(at: 0), 0) // 'l' of line0
        XCTAssertEqual(lineMap.lineNumber(at: 5), 0) // '\n'
        XCTAssertEqual(lineMap.lineNumber(at: 6), 1) // 'l' of line1
        XCTAssertEqual(lineMap.lineNumber(at: 11), 1) // '\n'
        XCTAssertEqual(lineMap.lineNumber(at: 12), 2) // 'l' of line2
        XCTAssertEqual(lineMap.lineNumber(at: 17), 2) // '\n'
        XCTAssertEqual(lineMap.lineNumber(at: 18), 3) // 'l' of line3
    }
}
