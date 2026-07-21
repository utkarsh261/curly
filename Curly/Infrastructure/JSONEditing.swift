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

struct JSONDiagnostic: Equatable, Sendable {
    var message: String
    var range: NSRange?
    var line: Int?
    var column: Int?

    var displayMessage: String {
        if let line, let column {
            return "Line \(line), column \(column) — \(message)"
        }
        if let line {
            return "Line \(line) — \(message)"
        }
        return message
    }

    static func located(message: String, text: String, range: NSRange) -> JSONDiagnostic {
        let source = text as NSString
        let safeLocation = min(max(0, range.location), source.length)
        let safeLength = min(max(0, range.length), source.length - safeLocation)
        let safeRange = NSRange(location: safeLocation, length: safeLength)
        let lineMap = JSONLineMap(text: text)
        let zeroBasedLine = lineMap.lineNumber(at: safeLocation)
        let lineStart = lineMap.lineStart(forZeroBasedLine: zeroBasedLine)
        let columnLocation: Int
        if safeLocation < source.length {
            columnLocation = source.rangeOfComposedCharacterSequence(at: safeLocation).location
        } else {
            columnLocation = safeLocation
        }
        let startIndex = String.Index(utf16Offset: lineStart, in: text)
        let locationIndex = String.Index(utf16Offset: columnLocation, in: text)
        let column = text[startIndex..<locationIndex].count + 1
        return JSONDiagnostic(
            message: message,
            range: safeRange,
            line: zeroBasedLine + 1,
            column: column
        )
    }

    static func unlocated(message: String) -> JSONDiagnostic {
        JSONDiagnostic(message: message, range: nil, line: nil, column: nil)
    }
}

struct JSONValidationResult: Equatable, Sendable {
    var diagnostic: JSONDiagnostic?

    var isValid: Bool { diagnostic == nil }
    var errorMessage: String? { diagnostic?.displayMessage }

    static let valid = JSONValidationResult(diagnostic: nil)

    static func invalid(_ diagnostic: JSONDiagnostic) -> JSONValidationResult {
        JSONValidationResult(diagnostic: diagnostic)
    }
}

enum JSONValidator {
    static func validate(_ text: String) -> JSONValidationResult {
        autoreleasepool {
            if let unterminatedCommentRange = JSONUnterminatedCommentDetector.range(in: text) {
                return .invalid(.located(
                    message: "Block comment is not closed.",
                    text: text,
                    range: unterminatedCommentRange
                ))
            }

            let stripped = JSONCommentStripper.stripComments(from: text)
            if stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .valid
            }

            if let trailingCommaRange = JSONTrailingCommaDetector.trailingCommaRange(in: text) {
                return .invalid(.located(
                    message: "Trailing commas are not allowed.",
                    text: text,
                    range: trailingCommaRange
                ))
            }

            guard let data = stripped.data(using: .utf8) else {
                return .invalid(.unlocated(message: "The JSON body is not valid UTF-8."))
            }

            do {
                _ = try JSONSerialization.jsonObject(with: data)
                return .valid
            } catch {
                if let diagnostic = JSONDiagnosticLocator.locateFirstError(in: text) {
                    return .invalid(diagnostic)
                }
                return .invalid(.unlocated(message: "JSON is invalid, but Curly could not determine the error location."))
            }
        }
    }
}

private enum JSONUnterminatedCommentDetector {
    static func range(in text: String) -> NSRange? {
        let source = text as NSString
        var index = 0
        var isInsideString = false
        var isEscaped = false

        while index < source.length {
            let current = source.character(at: index)
            if isInsideString {
                if current == 0x22, !isEscaped {
                    isInsideString = false
                }
                if current == 0x5C, !isEscaped {
                    isEscaped = true
                } else {
                    isEscaped = false
                }
                index += 1
                continue
            }

            if current == 0x22 {
                isInsideString = true
                index += 1
                continue
            }
            guard current == 0x2F, index + 1 < source.length else {
                index += 1
                continue
            }

            let next = source.character(at: index + 1)
            if next == 0x2F {
                index += 2
                while index < source.length {
                    let character = source.character(at: index)
                    if character == 0x0A || character == 0x0D { break }
                    index += 1
                }
            } else if next == 0x2A {
                let opener = index
                index += 2
                var foundCloser = false
                while index + 1 < source.length {
                    if source.character(at: index) == 0x2A, source.character(at: index + 1) == 0x2F {
                        index += 2
                        foundCloser = true
                        break
                    }
                    index += 1
                }
                if !foundCloser {
                    return NSRange(location: opener, length: 2)
                }
            } else {
                index += 1
            }
        }

        return nil
    }
}

enum JSONTrailingCommaDetector {
    static func trailingCommaRange(in text: String) -> NSRange? {
        autoreleasepool {
            var previousSignificantToken: JSONToken?

            for token in JSONLexer.tokenize(text) {
                switch token.kind {
                case .whitespace, .lineComment, .blockComment:
                    continue
                case .rightBrace, .rightBracket:
                    if previousSignificantToken?.kind == .comma {
                        return previousSignificantToken?.range
                    }
                    previousSignificantToken = token
                default:
                    previousSignificantToken = token
                }
            }

            return nil
        }
    }
}

private struct JSONDiagnosticLocator {
    private static let maximumDepth = 256
    private static let cancellationCheckInterval = 4_096

    private enum FrameState {
        case objectKeyOrEnd
        case objectKeyAfterComma(commaLocation: Int)
        case objectColon
        case objectValue
        case objectCommaOrEnd
        case arrayValueOrEnd
        case arrayValueAfterComma(commaLocation: Int)
        case arrayCommaOrEnd
    }

    private struct Frame {
        var openerLocation: Int
        var state: FrameState
    }

    private let text: String
    private let source: NSString
    private var index = 0
    private var advancesUntilCancellationCheck = cancellationCheckInterval
    private var frames: [Frame] = []
    private var diagnostic: JSONDiagnostic?
    private var isUnavailable = false

    private init(text: String) {
        self.text = text
        self.source = text as NSString
        frames.reserveCapacity(Self.maximumDepth)
    }

    static func locateFirstError(in text: String) -> JSONDiagnostic? {
        var locator = JSONDiagnosticLocator(text: text)
        return locator.locate()
    }

    private mutating func locate() -> JSONDiagnostic? {
        guard skipTrivia(), index < source.length else {
            return diagnostic
        }

        guard startValue() else {
            return isUnavailable ? nil : diagnostic
        }

        while !frames.isEmpty, diagnostic == nil, !isUnavailable {
            guard skipTrivia() else { break }
            guard !frames.isEmpty else { break }

            let frameIndex = frames.count - 1
            let frame = frames[frameIndex]
            if index >= source.length {
                failUnclosedContainer(frame)
                break
            }

            switch frame.state {
            case .objectKeyOrEnd:
                if character(at: index) == 0x7D {
                    closeCurrentContainer()
                } else {
                    parseObjectKey(frameIndex: frameIndex)
                }

            case .objectKeyAfterComma(let commaLocation):
                if character(at: index) == 0x7D {
                    fail("Trailing commas are not allowed.", at: commaLocation)
                } else {
                    parseObjectKey(frameIndex: frameIndex)
                }

            case .objectColon:
                guard character(at: index) == 0x3A else {
                    fail("Expected ':' after the object key.", at: index)
                    break
                }
                advance()
                frames[frameIndex].state = .objectValue

            case .objectValue:
                frames[frameIndex].state = .objectCommaOrEnd
                if !startValue(), diagnostic == nil, !isUnavailable {
                    fail("Expected a JSON value.", at: index)
                }

            case .objectCommaOrEnd:
                switch character(at: index) {
                case 0x2C:
                    let commaLocation = index
                    advance()
                    frames[frameIndex].state = .objectKeyAfterComma(commaLocation: commaLocation)
                case 0x7D:
                    closeCurrentContainer()
                default:
                    fail("Expected ',' or '}' after the object value.", at: index)
                }

            case .arrayValueOrEnd:
                if character(at: index) == 0x5D {
                    closeCurrentContainer()
                } else {
                    frames[frameIndex].state = .arrayCommaOrEnd
                    if !startValue(), diagnostic == nil, !isUnavailable {
                        fail("Expected a JSON value.", at: index)
                    }
                }

            case .arrayValueAfterComma(let commaLocation):
                if character(at: index) == 0x5D {
                    fail("Trailing commas are not allowed.", at: commaLocation)
                } else {
                    frames[frameIndex].state = .arrayCommaOrEnd
                    if !startValue(), diagnostic == nil, !isUnavailable {
                        fail("Expected a JSON value.", at: index)
                    }
                }

            case .arrayCommaOrEnd:
                switch character(at: index) {
                case 0x2C:
                    let commaLocation = index
                    advance()
                    frames[frameIndex].state = .arrayValueAfterComma(commaLocation: commaLocation)
                case 0x5D:
                    closeCurrentContainer()
                default:
                    fail("Expected ',' or ']' after the array value.", at: index)
                }
            }
        }

        guard diagnostic == nil, !isUnavailable else {
            return isUnavailable ? nil : diagnostic
        }

        guard skipTrivia() else {
            return isUnavailable ? nil : diagnostic
        }
        if index < source.length {
            fail("Unexpected content after the top-level JSON value.", at: index)
        }
        return diagnostic
    }

    private mutating func parseObjectKey(frameIndex: Int) {
        guard character(at: index) == 0x22 else {
            fail("Expected a quoted object key.", at: index)
            return
        }
        guard parseString() else { return }
        frames[frameIndex].state = .objectColon
    }

    private mutating func startValue() -> Bool {
        guard skipTrivia(), index < source.length else {
            return false
        }

        switch character(at: index) {
        case 0x7B:
            return openContainer(state: .objectKeyOrEnd)
        case 0x5B:
            return openContainer(state: .arrayValueOrEnd)
        case 0x22:
            return parseString()
        case 0x74:
            return parseLiteral("true")
        case 0x66:
            return parseLiteral("false")
        case 0x6E:
            return parseLiteral("null")
        case 0x2D, 0x30...0x39:
            return parseNumber()
        case 0x7D:
            fail("Unexpected closing '}'.", at: index)
        case 0x5D:
            fail("Unexpected closing ']'.", at: index)
        default:
            fail("Expected a JSON value.", at: index)
        }
        return false
    }

    private mutating func openContainer(state: FrameState) -> Bool {
        guard frames.count < Self.maximumDepth else {
            isUnavailable = true
            return false
        }
        let openerLocation = index
        advance()
        frames.append(Frame(openerLocation: openerLocation, state: state))
        return true
    }

    private mutating func closeCurrentContainer() {
        advance()
        frames.removeLast()
    }

    private mutating func failUnclosedContainer(_ frame: Frame) {
        switch frame.state {
        case .objectKeyOrEnd, .objectKeyAfterComma, .objectColon, .objectValue, .objectCommaOrEnd:
            fail("Object is not closed.", at: frame.openerLocation)
        case .arrayValueOrEnd, .arrayValueAfterComma, .arrayCommaOrEnd:
            fail("Array is not closed.", at: frame.openerLocation)
        }
    }

    private mutating func parseString() -> Bool {
        let openerLocation = index
        advance()

        while index < source.length, diagnostic == nil, !isUnavailable {
            let current = character(at: index)
            switch current {
            case 0x22:
                advance()
                return true
            case 0x5C:
                advance()
                guard index < source.length else {
                    fail("String is not closed.", at: openerLocation)
                    return false
                }
                let escaped = character(at: index)
                if escaped == 0x75 {
                    advance()
                    for _ in 0..<4 {
                        guard index < source.length, isHexDigit(character(at: index)) else {
                            fail("Expected four hexadecimal digits after '\\u'.", at: index)
                            return false
                        }
                        advance()
                    }
                } else if [0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74].contains(escaped) {
                    advance()
                } else {
                    fail("Invalid string escape sequence.", at: index)
                    return false
                }
            case 0x00...0x1F:
                fail("Strings cannot contain unescaped control characters.", at: index)
                return false
            default:
                advance()
            }
        }

        if diagnostic == nil, !isUnavailable {
            fail("String is not closed.", at: openerLocation)
        }
        return false
    }

    private mutating func parseLiteral(_ literal: String) -> Bool {
        let start = index
        for expected in literal.utf16 {
            guard skipDeletedComments(), index < source.length, character(at: index) == expected else {
                if diagnostic == nil, !isUnavailable {
                    fail("Invalid JSON literal.", at: start)
                }
                return false
            }
            advance()
        }
        return true
    }

    private mutating func parseNumber() -> Bool {
        let start = index
        if logicalCharacter() == 0x2D {
            advance()
            guard let next = logicalCharacter(), isDigit(next) else {
                fail("Expected a digit after '-'.", at: start)
                return false
            }
        }

        guard let first = logicalCharacter() else {
            fail("Invalid JSON number.", at: start)
            return false
        }
        if first == 0x30 {
            advance()
            if let next = logicalCharacter(), isDigit(next) {
                fail("Numbers cannot contain leading zeroes.", at: index)
                return false
            }
        } else if isDigitOneThroughNine(first) {
            repeat {
                advance()
            } while logicalCharacter().map(isDigit) == true
        } else {
            fail("Invalid JSON number.", at: start)
            return false
        }

        if logicalCharacter() == 0x2E {
            let decimalLocation = index
            advance()
            guard logicalCharacter().map(isDigit) == true else {
                fail("Expected a digit after the decimal point.", at: decimalLocation)
                return false
            }
            repeat {
                advance()
            } while logicalCharacter().map(isDigit) == true
        }

        if let exponent = logicalCharacter(), exponent == 0x65 || exponent == 0x45 {
            let exponentLocation = index
            advance()
            if let sign = logicalCharacter(), sign == 0x2B || sign == 0x2D {
                advance()
            }
            guard logicalCharacter().map(isDigit) == true else {
                fail("Expected a digit in the exponent.", at: exponentLocation)
                return false
            }
            repeat {
                advance()
            } while logicalCharacter().map(isDigit) == true
        }

        return true
    }

    private mutating func logicalCharacter() -> unichar? {
        guard skipDeletedComments(), index < source.length else { return nil }
        return character(at: index)
    }

    private mutating func skipTrivia() -> Bool {
        while index < source.length, diagnostic == nil, !isUnavailable {
            guard skipDeletedComments() else { return false }
            guard index < source.length else { return true }
            switch character(at: index) {
            case 0x20, 0x09, 0x0A, 0x0D:
                advance()
            default:
                return true
            }
        }
        return diagnostic == nil && !isUnavailable
    }

    private mutating func skipDeletedComments() -> Bool {
        while index + 1 < source.length,
              character(at: index) == 0x2F,
              diagnostic == nil,
              !isUnavailable {
            let next = character(at: index + 1)
            if next == 0x2F {
                advance(2)
                while index < source.length {
                    let current = character(at: index)
                    if current == 0x0A || current == 0x0D { break }
                    advance()
                }
            } else if next == 0x2A {
                let openerLocation = index
                advance(2)
                var foundCloser = false
                while index + 1 < source.length {
                    if character(at: index) == 0x2A, character(at: index + 1) == 0x2F {
                        advance(2)
                        foundCloser = true
                        break
                    }
                    advance()
                }
                guard foundCloser else {
                    fail("Block comment is not closed.", at: openerLocation, length: 2)
                    return false
                }
            } else {
                return true
            }
        }
        return diagnostic == nil && !isUnavailable
    }

    private func character(at location: Int) -> unichar {
        source.character(at: location)
    }

    private mutating func advance(_ amount: Int = 1) {
        index = min(source.length, index + amount)
        advancesUntilCancellationCheck -= amount
        if advancesUntilCancellationCheck <= 0 {
            advancesUntilCancellationCheck = Self.cancellationCheckInterval
            if withUnsafeCurrentTask(body: { $0?.isCancelled == true }) {
                isUnavailable = true
            }
        }
    }

    private mutating func fail(_ message: String, at location: Int, length: Int = 1) {
        guard diagnostic == nil, !isUnavailable else { return }
        diagnostic = .located(
            message: message,
            text: text,
            range: NSRange(location: min(max(0, location), source.length), length: min(length, max(0, source.length - location)))
        )
    }

    private func isDigit(_ character: unichar) -> Bool {
        character >= 0x30 && character <= 0x39
    }

    private func isDigitOneThroughNine(_ character: unichar) -> Bool {
        character >= 0x31 && character <= 0x39
    }

    private func isHexDigit(_ character: unichar) -> Bool {
        (character >= 0x30 && character <= 0x39) ||
            (character >= 0x41 && character <= 0x46) ||
            (character >= 0x61 && character <= 0x66)
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
    static func foldRanges(in text: String, tokens: [JSONToken]? = nil, lineMap: JSONLineMap? = nil) -> [JSONFoldRange] {
        let resolvedLineMap = lineMap ?? JSONLineMap(text: text)
        let resolvedTokens = tokens ?? JSONLexer.tokenize(text)
        var stack: [(kind: JSONFoldKind, tokenRange: NSRange)] = []
        var ranges: [JSONFoldRange] = []

        for token in resolvedTokens {
            switch token.kind {
            case .leftBrace:
                stack.append((kind: .object, tokenRange: token.range))
            case .leftBracket:
                stack.append((kind: .array, tokenRange: token.range))
            case .rightBrace:
                appendRangeIfMatched(kind: .object, closeRange: token.range, lineMap: resolvedLineMap, stack: &stack, ranges: &ranges)
            case .rightBracket:
                appendRangeIfMatched(kind: .array, closeRange: token.range, lineMap: resolvedLineMap, stack: &stack, ranges: &ranges)
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

struct JSONLineMap: Equatable {
    private let lineStarts: [Int]

    init(text: String) {
        let source = text as NSString
        var starts = [0]
        var index = 0
        while index < source.length {
            let char = source.character(at: index)
            if char == 0x0D {
                if index + 1 < source.length, source.character(at: index + 1) == 0x0A {
                    index += 1
                }
                starts.append(index + 1)
            } else if char == 0x0A {
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

    func lineStart(forZeroBasedLine line: Int) -> Int {
        guard !lineStarts.isEmpty else { return 0 }
        return lineStarts[min(max(0, line), lineStarts.count - 1)]
    }

    func lineRange(forZeroBasedLine line: Int, in text: String) -> NSRange {
        let source = text as NSString
        let start = lineStart(forZeroBasedLine: line)
        let nextStart = line + 1 < lineStarts.count ? lineStarts[line + 1] : source.length
        var end = nextStart
        while end > start {
            let previous = source.character(at: end - 1)
            guard previous == 0x0A || previous == 0x0D else { break }
            end -= 1
        }
        return NSRange(location: start, length: end - start)
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
            if stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
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

struct SyntaxAnalysisResult: Equatable {
    let text: String
    let tokens: [JSONToken]
    let lineMap: JSONLineMap
    let foldRanges: [JSONFoldRange]

    static func analyze(_ text: String) -> SyntaxAnalysisResult {
        let tokens = JSONLexer.tokenize(text)
        let lineMap = JSONLineMap(text: text)
        let foldRanges = JSONFoldIndex.foldRanges(in: text, tokens: tokens, lineMap: lineMap)
        return SyntaxAnalysisResult(text: text, tokens: tokens, lineMap: lineMap, foldRanges: foldRanges)
    }

    static let empty = SyntaxAnalysisResult(
        text: "",
        tokens: [],
        lineMap: JSONLineMap(text: ""),
        foldRanges: []
    )
}
