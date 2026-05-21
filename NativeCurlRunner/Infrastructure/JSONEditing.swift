import Foundation

enum JSONTokenKind: Equatable {
    case leftBrace
    case rightBrace
    case leftBracket
    case rightBracket
    case colon
    case comma
    case string
    case number
    case boolLiteral
    case nullLiteral
    case lineComment
    case blockComment
    case whitespace
    case other
}

struct JSONToken: Equatable {
    var kind: JSONTokenKind
    var range: NSRange
}

enum JSONLexer {
    static func tokenize(_ text: String) -> [JSONToken] {
        let source = text as NSString
        var tokens: [JSONToken] = []
        var index = 0

        while index < source.length {
            let char = source.character(at: index)

            switch char {
            case 0x7B:
                tokens.append(JSONToken(kind: .leftBrace, range: NSRange(location: index, length: 1)))
                index += 1
            case 0x7D:
                tokens.append(JSONToken(kind: .rightBrace, range: NSRange(location: index, length: 1)))
                index += 1
            case 0x5B:
                tokens.append(JSONToken(kind: .leftBracket, range: NSRange(location: index, length: 1)))
                index += 1
            case 0x5D:
                tokens.append(JSONToken(kind: .rightBracket, range: NSRange(location: index, length: 1)))
                index += 1
            case 0x3A:
                tokens.append(JSONToken(kind: .colon, range: NSRange(location: index, length: 1)))
                index += 1
            case 0x2C:
                tokens.append(JSONToken(kind: .comma, range: NSRange(location: index, length: 1)))
                index += 1
            case 0x22:
                let start = index
                index += 1
                var isEscaped = false
                while index < source.length {
                    let current = source.character(at: index)
                    if current == 0x22 && !isEscaped {
                        index += 1
                        break
                    }
                    if current == 0x5C && !isEscaped {
                        isEscaped = true
                    } else {
                        isEscaped = false
                    }
                    index += 1
                }
                tokens.append(JSONToken(kind: .string, range: NSRange(location: start, length: index - start)))
            case 0x2F where index + 1 < source.length && source.character(at: index + 1) == 0x2F:
                let start = index
                index += 2
                while index < source.length {
                    let current = source.character(at: index)
                    if current == 0x0A || current == 0x0D {
                        break
                    }
                    index += 1
                }
                tokens.append(JSONToken(kind: .lineComment, range: NSRange(location: start, length: index - start)))
            case 0x2F where index + 1 < source.length && source.character(at: index + 1) == 0x2A:
                let start = index
                index += 2
                while index + 1 < source.length {
                    if source.character(at: index) == 0x2A && source.character(at: index + 1) == 0x2F {
                        index += 2
                        break
                    }
                    index += 1
                }
                tokens.append(JSONToken(kind: .blockComment, range: NSRange(location: start, length: index - start)))
            case 0x20, 0x09, 0x0A, 0x0D:
                let start = index
                index += 1
                while index < source.length {
                    switch source.character(at: index) {
                    case 0x20, 0x09, 0x0A, 0x0D:
                        index += 1
                    default:
                        break
                    }
                    if index < source.length {
                        let current = source.character(at: index)
                        if current != 0x20, current != 0x09, current != 0x0A, current != 0x0D {
                            break
                        }
                    }
                }
                tokens.append(JSONToken(kind: .whitespace, range: NSRange(location: start, length: index - start)))
            case 0x2D, 0x30...0x39:
                let start = index
                index += 1
                while index < source.length, isNumberContinuation(source.character(at: index)) {
                    index += 1
                }
                tokens.append(JSONToken(kind: .number, range: NSRange(location: start, length: index - start)))
            case 0x74 where index + 3 < source.length &&
                source.character(at: index + 1) == 0x72 &&
                source.character(at: index + 2) == 0x75 &&
                source.character(at: index + 3) == 0x65:
                tokens.append(JSONToken(kind: .boolLiteral, range: NSRange(location: index, length: 4)))
                index += 4
            case 0x66 where index + 4 < source.length &&
                source.character(at: index + 1) == 0x61 &&
                source.character(at: index + 2) == 0x6C &&
                source.character(at: index + 3) == 0x73 &&
                source.character(at: index + 4) == 0x65:
                tokens.append(JSONToken(kind: .boolLiteral, range: NSRange(location: index, length: 5)))
                index += 5
            case 0x6E where index + 3 < source.length &&
                source.character(at: index + 1) == 0x75 &&
                source.character(at: index + 2) == 0x6C &&
                source.character(at: index + 3) == 0x6C:
                tokens.append(JSONToken(kind: .nullLiteral, range: NSRange(location: index, length: 4)))
                index += 4
            default:
                tokens.append(JSONToken(kind: .other, range: NSRange(location: index, length: 1)))
                index += 1
            }
        }

        return tokens
    }

    private static func isNumberContinuation(_ character: unichar) -> Bool {
        switch character {
        case 0x30...0x39, 0x2E, 0x65, 0x45, 0x2B, 0x2D:
            return true
        default:
            return false
        }
    }
}

enum JSONCommentStripper {
    static func stripComments(from text: String) -> String {
        autoreleasepool {
            let mutable = NSMutableString(string: text)
            for token in JSONLexer.tokenize(text).reversed() where token.kind == .lineComment || token.kind == .blockComment {
                mutable.deleteCharacters(in: token.range)
            }
            return mutable as String
        }
    }
}

struct JSONValidationResult: Equatable {
    var isValid: Bool
    var errorMessage: String?
}

enum JSONValidator {
    static func validate(_ text: String) -> JSONValidationResult {
        autoreleasepool {
            if JSONTrailingCommaDetector.hasTrailingComma(in: text) {
                return JSONValidationResult(isValid: false, errorMessage: "JSON cannot contain trailing commas.")
            }

            let stripped = JSONCommentStripper.stripComments(from: text)
            guard let data = stripped.data(using: .utf8) else {
                return JSONValidationResult(isValid: false, errorMessage: "The JSON body is not valid UTF-8.")
            }

            do {
                _ = try JSONSerialization.jsonObject(with: data)
                return JSONValidationResult(isValid: true, errorMessage: nil)
            } catch {
                return JSONValidationResult(isValid: false, errorMessage: error.localizedDescription)
            }
        }
    }
}

enum JSONTrailingCommaDetector {
    static func hasTrailingComma(in text: String) -> Bool {
        autoreleasepool {
            var previousSignificantToken: JSONToken?

            for token in JSONLexer.tokenize(text) {
                switch token.kind {
                case .whitespace, .lineComment, .blockComment:
                    continue
                case .rightBrace, .rightBracket:
                    if previousSignificantToken?.kind == .comma {
                        return true
                    }
                    previousSignificantToken = token
                default:
                    previousSignificantToken = token
                }
            }

            return false
        }
    }
}

enum JSONFoldKind: Equatable {
    case object
    case array

    var placeholder: String {
        switch self {
        case .object:
            return "{...}"
        case .array:
            return "[...]"
        }
    }
}

struct JSONFoldRange: Equatable {
    var kind: JSONFoldKind
    var fullRange: NSRange
    var openTokenRange: NSRange
    var closeTokenRange: NSRange
    var depth: Int
}

enum JSONFoldIndex {
    static func foldRanges(in text: String) -> [JSONFoldRange] {
        let lineMap = JSONLineMap(text: text)
        var stack: [(kind: JSONFoldKind, tokenRange: NSRange)] = []
        var ranges: [JSONFoldRange] = []

        for token in JSONLexer.tokenize(text) {
            switch token.kind {
            case .leftBrace:
                stack.append((kind: .object, tokenRange: token.range))
            case .leftBracket:
                stack.append((kind: .array, tokenRange: token.range))
            case .rightBrace:
                appendRangeIfMatched(kind: .object, closeRange: token.range, lineMap: lineMap, stack: &stack, ranges: &ranges)
            case .rightBracket:
                appendRangeIfMatched(kind: .array, closeRange: token.range, lineMap: lineMap, stack: &stack, ranges: &ranges)
            default:
                continue
            }
        }

        return ranges.sorted { $0.fullRange.location < $1.fullRange.location }
    }

    private static func appendRangeIfMatched(
        kind: JSONFoldKind,
        closeRange: NSRange,
        lineMap: JSONLineMap,
        stack: inout [(kind: JSONFoldKind, tokenRange: NSRange)],
        ranges: inout [JSONFoldRange]
    ) {
        guard let matchIndex = stack.lastIndex(where: { $0.kind == kind }) else {
            return
        }

        let open = stack.remove(at: matchIndex)
        let fullRange = NSRange(
            location: open.tokenRange.location,
            length: closeRange.location + closeRange.length - open.tokenRange.location
        )

        guard lineMap.lineNumber(at: open.tokenRange.location) != lineMap.lineNumber(at: closeRange.location) else {
            return
        }

        ranges.append(JSONFoldRange(kind: kind, fullRange: fullRange, openTokenRange: open.tokenRange, closeTokenRange: closeRange, depth: stack.count))
    }
}

struct JSONLineMap {
    private let lineStarts: [Int]

    init(text: String) {
        let source = text as NSString
        var starts = [0]
        var index = 0
        while index < source.length {
            let char = source.character(at: index)
            if char == 0x0A {
                starts.append(index + 1)
            }
            index += 1
        }
        lineStarts = starts
    }

    func lineNumber(at location: Int) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if lineStarts[mid] <= location {
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return max(0, high)
    }
}

enum JSONFormatter {
    static func format(_ text: String, indentation: Int = 2) throws -> String {
        try transform(text, indentation: indentation, style: .pretty)
    }

    static func compact(_ text: String) throws -> String {
        try transform(text, indentation: 0, style: .compact)
    }

    private enum Style {
        case pretty
        case compact
    }

    private enum FormattingError: LocalizedError {
        case invalidJSON(String)

        var errorDescription: String? {
            switch self {
            case .invalidJSON(let message):
                return message
            }
        }
    }

    private static func transform(_ text: String, indentation: Int, style: Style) throws -> String {
        try autoreleasepool {
            let validation = JSONValidator.validate(text)
            guard validation.isValid else {
                throw FormattingError.invalidJSON(validation.errorMessage ?? "The JSON body is invalid.")
            }

            let commentLines = fullLineCommentPlacements(in: text)
            let stripped = JSONCommentStripper.stripComments(from: text)
            guard let data = stripped.data(using: .utf8) else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }

            let object = try JSONSerialization.jsonObject(with: data)
            let output: String
            switch style {
            case .pretty:
                output = try renderPretty(object, indentation: indentation)
            case .compact:
                output = commentLines.isEmpty ? try renderCompact(object) : text
            }

            guard !commentLines.isEmpty else {
                return output
            }

            switch style {
            case .pretty:
                return insertCommentLines(commentLines, into: output)
            case .compact:
                return output
            }
        }
    }

    private struct CommentLinePlacement {
        var originalLineIndex: Int
        var text: String
    }

    private static func fullLineCommentPlacements(in text: String) -> [CommentLinePlacement] {
        text.components(separatedBy: .newlines)
            .enumerated()
            .compactMap { lineIndex, line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("//") || (trimmed.hasPrefix("/*") && trimmed.hasSuffix("*/")) else {
                    return nil
                }
                return CommentLinePlacement(originalLineIndex: lineIndex, text: line)
            }
    }

    private static func insertCommentLines(_ commentLines: [CommentLinePlacement], into formattedJSON: String) -> String {
        var lines = formattedJSON.components(separatedBy: "\n")
        for commentLine in commentLines.sorted(by: { $0.originalLineIndex < $1.originalLineIndex }) {
            let insertionIndex = min(commentLine.originalLineIndex, lines.count)
            lines.insert(commentLine.text, at: insertionIndex)
        }
        return lines.joined(separator: "\n")
    }

    private static func renderPretty(_ object: Any, indentation: Int) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
        let string = String(data: data, encoding: .utf8) ?? ""
        guard indentation != 2 else {
            return string
        }
        let requestedIndentation = String(repeating: " ", count: indentation)
        return string
            .components(separatedBy: "\n")
            .map { line -> String in
                let leadingSpaces = line.prefix { $0 == " " }.count
                let level = leadingSpaces / 2
                return String(repeating: requestedIndentation, count: level) + line.dropFirst(leadingSpaces)
            }
            .joined(separator: "\n")
    }

    private static func renderCompact(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        return String(data: data, encoding: .utf8) ?? ""
    }

}
