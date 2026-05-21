import Foundation

struct SimpleCurlImporter: CurlImporting {
    func parse(_ rawInput: String) throws -> Request {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CurlImportError.emptyInput
        }

        let tokens = try ShellTokenizer.tokenize(trimmed)
        guard tokens.first == "curl" else {
            throw CurlImportError.notCurl
        }

        var method: HTTPMethod?
        var headers: [Header] = []
        var body: String?
        var url: String?
        var index = 1

        while index < tokens.count {
            let token = tokens[index]
            switch token {
            case "-X", "--request":
                index += 1
                guard index < tokens.count else {
                    throw CurlImportError.malformedInput("Missing method after \(token).")
                }
                guard let parsedMethod = HTTPMethod(rawValue: tokens[index].uppercased()) else {
                    throw CurlImportError.unsupportedSyntax("Unsupported HTTP method \(tokens[index]).")
                }
                method = parsedMethod

            case "-H", "--header":
                index += 1
                guard index < tokens.count else {
                    throw CurlImportError.malformedInput("Missing header after \(token).")
                }
                let rawHeader = tokens[index]
                guard let separator = rawHeader.firstIndex(of: ":") else {
                    throw CurlImportError.malformedInput("Header '\(rawHeader)' is missing ':'.")
                }

                let name = String(rawHeader[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
                let value = String(rawHeader[rawHeader.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                headers.append(Header(name: name, value: value, isEnabled: true))

            case "-d", "--data", "--data-raw", "--data-binary", "--data-ascii":
                index += 1
                guard index < tokens.count else {
                    throw CurlImportError.malformedInput("Missing body after \(token).")
                }
                let candidate = tokens[index]
                if candidate.hasPrefix("@") {
                    throw CurlImportError.unsupportedSyntax("File-backed request bodies are not supported in v0.1.")
                }
                body = candidate

            case "-u", "--user":
                throw CurlImportError.unsupportedSyntax("Auth shorthand is not supported in v0.1. Use explicit headers.")

            default:
                if token.hasPrefix("-") {
                    throw CurlImportError.unsupportedSyntax("Flag \(token) is not supported in v0.1.")
                }

                if url == nil {
                    url = token
                } else {
                    throw CurlImportError.malformedInput("Unexpected extra token '\(token)'.")
                }
            }

            index += 1
        }

        guard let url else {
            throw CurlImportError.missingURL
        }

        return Request(
            method: method ?? (body == nil ? .get : .post),
            urlString: url,
            headers: headers,
            body: body.map(RequestBody.text) ?? .none
        )
    }
}

private enum ShellTokenizer {
    static func tokenize(_ input: String) throws -> [String] {
        var tokens: [String] = []
        var current = ""
        var activeQuote: Character?
        var iterator = input.makeIterator()

        while let character = iterator.next() {
            if let quote = activeQuote {
                if character == quote {
                    activeQuote = nil
                } else if character == "\\" && quote == "\"" {
                    guard let escaped = iterator.next() else {
                        throw CurlImportError.malformedInput("Trailing escape sequence.")
                    }
                    current.append(escaped)
                } else {
                    current.append(character)
                }
                continue
            }

            switch character {
            case "\"", "'":
                activeQuote = character
            case " ", "\t", "\n":
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            case "\\":
                guard let escaped = iterator.next() else {
                    throw CurlImportError.malformedInput("Trailing escape sequence.")
                }
                if escaped == "\n" {
                    continue
                }
                if escaped == "\r" {
                    if let nextCharacter = iterator.next(), nextCharacter != "\n" {
                        current.append(nextCharacter)
                    }
                    continue
                }
                current.append(escaped)
            default:
                current.append(character)
            }
        }

        if activeQuote != nil {
            throw CurlImportError.malformedInput("Unterminated quoted string.")
        }

        if !current.isEmpty {
            tokens.append(current)
        }

        return tokens
    }
}
