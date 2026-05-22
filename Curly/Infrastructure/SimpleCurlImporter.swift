import Foundation

struct SimpleCurlImporter: CurlImporting {
    func parse(_ rawInput: String) throws -> CurlImportResult {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CurlImportError.emptyInput
        }

        let tokens = try ShellTokenizer.tokenize(Self.normalizeLineContinuations(in: trimmed))
        let command = try CurlCommandParser().parse(tokens)
        let request = try CurlRequestMapper().map(command)

        return CurlImportResult(
            request: request,
            warnings: command.warnings,
            sourceCurl: trimmed
        )
    }

    private static func normalizeLineContinuations(in input: String) -> String {
        var output = ""
        var index = input.startIndex

        while index < input.endIndex {
            if input[index] == "\\" {
                var lookahead = input.index(after: index)
                while lookahead < input.endIndex, input[lookahead] == " " || input[lookahead] == "\t" {
                    lookahead = input.index(after: lookahead)
                }

                if lookahead < input.endIndex, input[lookahead] == "\n" {
                    output.append(" ")
                    index = input.index(after: lookahead)
                    continue
                }

                if lookahead < input.endIndex, input[lookahead] == "\r" {
                    let afterCarriageReturn = input.index(after: lookahead)
                    if afterCarriageReturn < input.endIndex, input[afterCarriageReturn] == "\n" {
                        output.append(" ")
                        index = input.index(after: afterCarriageReturn)
                        continue
                    }
                }
            }

            output.append(input[index])
            index = input.index(after: index)
        }

        return output
    }
}

private struct CurlCommand {
    var method: HTTPMethod?
    var url: String?
    var headers: [Header] = []
    var bodyParts: [String] = []
    var usesDataBody = false
    var warnings: [String] = []

    mutating func setMethod(_ newMethod: HTTPMethod, source: String) {
        if let method, method != newMethod {
            warnings.append("Method from `\(source)` overrides earlier method \(method.rawValue).")
        }
        method = newMethod
    }

    mutating func appendHeader(name: String, value: String) {
        headers.append(Header(name: name, value: value, isEnabled: true))
    }
}

private struct CurlCommandParser {
    private let registry = CurlOptionRegistry()

    func parse(_ tokens: [String]) throws -> CurlCommand {
        guard tokens.first == "curl" else {
            throw CurlImportError.notCurl
        }

        var command = CurlCommand()
        var index = 1

        while index < tokens.count {
            let token = tokens[index]

            if token.hasPrefix("-") {
                let parsedOption = try parseOptionToken(token)
                guard let definition = registry.definition(named: parsedOption.name) else {
                    command.warnings.append("Ignored unsupported cURL flag `\(parsedOption.name)`.")
                    index += 1
                    continue
                }

                switch definition.arity {
                case .none:
                    try definition.behavior.apply(value: nil, token: parsedOption.name, command: &command)
                    index += 1
                case .requiredValue:
                    let value: String
                    if let attachedValue = parsedOption.attachedValue {
                        value = attachedValue
                    } else {
                        index += 1
                        guard index < tokens.count else {
                            throw CurlImportError.malformedInput("Missing value after \(parsedOption.name).")
                        }
                        value = tokens[index]
                    }
                    try definition.behavior.apply(value: value, token: parsedOption.name, command: &command)
                    index += 1
                }

                continue
            }

            if command.url == nil {
                command.url = token
            } else {
                throw CurlImportError.malformedInput("Unexpected extra token '\(token)'.")
            }
            index += 1
        }

        return command
    }

    private func parseOptionToken(_ token: String) throws -> ParsedCurlOption {
        if let separator = token.firstIndex(of: "="), token.hasPrefix("--") {
            let name = String(token[..<separator])
            let value = String(token[token.index(after: separator)...])
            return ParsedCurlOption(name: name, attachedValue: value)
        }

        for shortName in ["-X", "-H", "-d", "-A", "-b", "-u", "-F"] where token.hasPrefix(shortName) && token != shortName {
            let value = String(token.dropFirst(shortName.count))
            guard !value.isEmpty else {
                break
            }
            return ParsedCurlOption(name: shortName, attachedValue: value)
        }

        return ParsedCurlOption(name: token, attachedValue: nil)
    }
}

private struct ParsedCurlOption {
    var name: String
    var attachedValue: String?
}

private struct CurlOptionRegistry {
    private let definitions: [CurlOptionDefinition]

    init() {
        definitions = [
            CurlOptionDefinition(names: ["-X", "--request"], arity: .requiredValue, behavior: .requestMethod),
            CurlOptionDefinition(names: ["-H", "--header"], arity: .requiredValue, behavior: .header),
            CurlOptionDefinition(names: ["-d", "--data", "--data-raw", "--data-binary", "--data-ascii", "--data-urlencode"], arity: .requiredValue, behavior: .body),
            CurlOptionDefinition(names: ["--json"], arity: .requiredValue, behavior: .jsonBody),
            CurlOptionDefinition(names: ["--url"], arity: .requiredValue, behavior: .url),
            CurlOptionDefinition(names: ["-A", "--user-agent"], arity: .requiredValue, behavior: .headerValue(name: "User-Agent")),
            CurlOptionDefinition(names: ["-b", "--cookie"], arity: .requiredValue, behavior: .cookie),
            CurlOptionDefinition(names: ["-c", "--cookie-jar"], arity: .requiredValue, behavior: .warnValue("Cookie jar files are not represented yet.")),
            CurlOptionDefinition(names: ["-u", "--user"], arity: .requiredValue, behavior: .basicAuth),
            CurlOptionDefinition(names: ["-I", "--head"], arity: .none, behavior: .head),
            CurlOptionDefinition(names: ["-L", "--location"], arity: .none, behavior: .warn("Redirect-following from `--location` is not represented yet.")),
            CurlOptionDefinition(names: ["-i", "--include"], arity: .none, behavior: .warn("Ignored terminal output flag `-i`.")),
            CurlOptionDefinition(names: ["-w", "--write-out"], arity: .requiredValue, behavior: .warnValue("Ignored terminal write-out flag.")),
            CurlOptionDefinition(names: ["-v", "--verbose"], arity: .none, behavior: .warn("Ignored terminal output flag `-v`.")),
            CurlOptionDefinition(names: ["-s", "--silent"], arity: .none, behavior: .warn("Ignored terminal output flag `-s`.")),
            CurlOptionDefinition(names: ["--fail", "--fail-with-body"], arity: .none, behavior: .warn("Ignored terminal failure handling flag.")),
            CurlOptionDefinition(names: ["--compressed"], arity: .none, behavior: .ignore),
            CurlOptionDefinition(names: ["-F", "--form", "--form-string"], arity: .requiredValue, behavior: .multipartForm),
            CurlOptionDefinition(names: ["-o", "--output", "-D", "--dump-header"], arity: .requiredValue, behavior: .warnValue("Ignored file output flag.")),
            CurlOptionDefinition(names: ["-O", "--remote-name"], arity: .none, behavior: .warn("Ignored file output flag.")),
            CurlOptionDefinition(names: ["--proxy", "-x", "--proxy-user", "--proxy-header"], arity: .requiredValue, behavior: .warnValue("Proxy options are not represented yet.")),
            CurlOptionDefinition(names: ["--cacert", "--cert", "--key", "--cert-type", "--key-type"], arity: .requiredValue, behavior: .warnValue("TLS client options are not represented yet.")),
            CurlOptionDefinition(names: ["--connect-timeout", "--max-time", "--retry"], arity: .requiredValue, behavior: .warnValue("Request timing/retry options are not represented yet.")),
            CurlOptionDefinition(names: ["--http1.1", "--http2", "--http3", "--insecure", "-k", "--no-progress-meter", "--progress-bar"], arity: .none, behavior: .warn("Ignored transport/display flag."))
        ]
    }

    func definition(named name: String) -> CurlOptionDefinition? {
        definitions.first { $0.names.contains(name) }
    }
}

private struct CurlOptionDefinition {
    var names: Set<String>
    var arity: CurlOptionArity
    var behavior: CurlOptionBehavior
}

private enum CurlOptionArity {
    case none
    case requiredValue
}

private enum CurlOptionBehavior {
    case requestMethod
    case header
    case body
    case jsonBody
    case url
    case headerValue(name: String)
    case cookie
    case basicAuth
    case head
    case multipartForm
    case ignore
    case warn(String)
    case warnValue(String)

    func apply(value: String?, token: String, command: inout CurlCommand) throws {
        switch self {
        case .requestMethod:
            guard let value else { return }
            guard let method = HTTPMethod(rawValue: value.uppercased()) else {
                throw CurlImportError.unsupportedSyntax("Unsupported HTTP method \(value).")
            }
            command.setMethod(method, source: token)

        case .header:
            guard let value else { return }
            try appendHeader(value, command: &command)

        case .body:
            guard let value else { return }
            guard !value.hasPrefix("@") else {
                command.warnings.append("File-backed request bodies are not represented yet.")
                return
            }
            command.usesDataBody = true
            command.bodyParts.append(value)

        case .jsonBody:
            guard let value else { return }
            guard !value.hasPrefix("@") else {
                command.warnings.append("File-backed request bodies are not represented yet.")
                return
            }
            if !command.headers.contains(where: { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }) {
                command.appendHeader(name: "Content-Type", value: "application/json")
            }
            if !command.headers.contains(where: { $0.name.caseInsensitiveCompare("Accept") == .orderedSame }) {
                command.appendHeader(name: "Accept", value: "application/json")
            }
            command.bodyParts.append(value)

        case .url:
            guard let value else { return }
            if command.url == nil {
                command.url = value
            } else if command.url != value {
                command.warnings.append("URL from `--url` overrides earlier URL.")
                command.url = value
            }

        case .headerValue(let name):
            guard let value else { return }
            command.appendHeader(name: name, value: value)

        case .cookie:
            guard let value else { return }
            guard value.contains("=") else {
                command.warnings.append("Cookie files are not represented yet.")
                return
            }
            command.appendHeader(name: "Cookie", value: value)

        case .basicAuth:
            guard let value else { return }
            guard value.contains(":") else {
                throw CurlImportError.unsupportedSyntax("Auth shorthand without ':' is not supported yet.")
            }
            let encoded = Data(value.utf8).base64EncodedString()
            command.appendHeader(name: "Authorization", value: "Basic \(encoded)")

        case .head:
            command.setMethod(.head, source: token)

        case .multipartForm:
            if command.method == nil {
                command.setMethod(.post, source: token)
            }
            command.warnings.append("Multipart form data is not represented yet.")

        case .ignore:
            return

        case .warn(let warning):
            command.warnings.append(warning)

        case .warnValue(let warning):
            command.warnings.append(warning)
        }
    }

    private func appendHeader(_ rawHeader: String, command: inout CurlCommand) throws {
        guard let separator = rawHeader.firstIndex(of: ":") else {
            throw CurlImportError.malformedInput("Header '\(rawHeader)' is missing ':'.")
        }

        let name = String(rawHeader[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
        let value = String(rawHeader[rawHeader.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw CurlImportError.malformedInput("Header name is empty.")
        }
        command.appendHeader(name: name, value: value)
    }
}

private struct CurlRequestMapper {
    func map(_ command: CurlCommand) throws -> Request {
        guard let url = command.url else {
            throw CurlImportError.missingURL
        }

        let body = command.bodyParts.isEmpty ? nil : command.bodyParts.joined(separator: "&")
        var headers = command.headers
        if body != nil,
           command.usesDataBody,
           !headers.contains(where: { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }) {
            headers.append(Header(name: "Content-Type", value: "application/x-www-form-urlencoded"))
        }

        return Request(
            method: command.method ?? (body == nil ? .get : .post),
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
                    try appendShellCharacter(escaped, to: &current)
                } else {
                    if quote != "'", character == "$" || character == "`" {
                        throw CurlImportError.unsupportedSyntax("Shell variables and command substitution are not supported in cURL import yet.")
                    }
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
                        try appendShellCharacter(nextCharacter, to: &current)
                    }
                    continue
                }
                current.append(escaped)
            case "$", "`":
                throw CurlImportError.unsupportedSyntax("Shell variables and command substitution are not supported in cURL import yet.")
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

    private static func appendShellCharacter(_ character: Character, to current: inout String) throws {
        if character == "$" || character == "`" {
            throw CurlImportError.unsupportedSyntax("Shell variables and command substitution are not supported in cURL import yet.")
        }
        current.append(character)
    }
}
