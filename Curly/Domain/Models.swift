import Foundation

enum HTTPMethod: String, CaseIterable, Codable, Identifiable {
    case get = "GET"
    case head = "HEAD"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
    case options = "OPTIONS"

    var id: String { rawValue }
}

struct Header: Identifiable, Equatable, Codable {
    let id: UUID
    var name: String
    var value: String
    var isEnabled: Bool

    init(id: UUID = UUID(), name: String = "", value: String = "", isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.value = value
        self.isEnabled = isEnabled
    }
}

enum RequestBody: Equatable, Codable {
    case none
    case text(String)

    var textValue: String {
        switch self {
        case .none:
            return ""
        case .text(let text):
            return text
        }
    }
}

enum TLSCertificateVerification: String, Equatable, Codable {
    case systemDefault
    case disabled
}

struct Request: Equatable, Codable {
    var method: HTTPMethod
    var urlString: String
    var headers: [Header]
    var body: RequestBody
    var tlsCertificateVerification: TLSCertificateVerification

    init(
        method: HTTPMethod,
        urlString: String,
        headers: [Header],
        body: RequestBody,
        tlsCertificateVerification: TLSCertificateVerification = .systemDefault
    ) {
        self.method = method
        self.urlString = urlString
        self.headers = headers
        self.body = body
        self.tlsCertificateVerification = tlsCertificateVerification
    }

    private enum CodingKeys: String, CodingKey {
        case method
        case urlString
        case headers
        case body
        case tlsCertificateVerification
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        method = try container.decode(HTTPMethod.self, forKey: .method)
        urlString = try container.decode(String.self, forKey: .urlString)
        headers = try container.decode([Header].self, forKey: .headers)
        body = try container.decode(RequestBody.self, forKey: .body)
        tlsCertificateVerification = try container.decodeIfPresent(
            TLSCertificateVerification.self,
            forKey: .tlsCertificateVerification
        ) ?? .systemDefault
    }

    static let empty = Request(method: .get, urlString: "", headers: [], body: .none)

    var isEffectivelyEmpty: Bool {
        urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        headers.isEmpty &&
        body.textValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func isURLOnlyDraft(matching text: String) -> Bool {
        method == .get &&
        urlString == text &&
        headers.isEmpty &&
        body.textValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var lightweightValidationMessage: String? {
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedURL.isEmpty {
            if headers.contains(where: { $0.isEnabled && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ||
                !body.textValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Enter a full http or https URL to make this request runnable."
            }
            return nil
        }

        guard let components = URLComponents(string: trimmedURL) else {
            return "The URL is not valid yet."
        }

        guard let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            return "Use an absolute http or https URL."
        }

        guard let host = components.host, !host.isEmpty else {
            return "The URL needs a host before it can run."
        }

        return nil
    }

    var isMinimallyValid: Bool {
        lightweightValidationMessage == nil && !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var containsVariableTemplateOpening: Bool {
        urlString.contains("{{") || headers.contains { header in
            header.isEnabled && (header.name.contains("{{") || header.value.contains("{{"))
        }
    }
}

enum VariableScope: String, Equatable, Codable, CaseIterable, Identifiable {
    case request
    case global

    var id: String { rawValue }
}

struct Variable: Identifiable, Equatable, Codable {
    let id: UUID
    var name: String
    var value: String
    var scope: VariableScope
    var requestID: UUID?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        value: String,
        scope: VariableScope,
        requestID: UUID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.value = value
        self.scope = scope
        self.requestID = requestID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    static func normalizedNameForStorage(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isValidName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first else {
            return false
        }
        guard isASCIILetter(first) || first == "_" else {
            return false
        }
        return name.unicodeScalars.dropFirst().allSatisfy { scalar in
            isASCIILetter(scalar) || isASCIIDigit(scalar) || scalar == "_" || scalar == "-"
        }
    }

    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
    }

    private static func isASCIIDigit(_ scalar: Unicode.Scalar) -> Bool {
        (48...57).contains(scalar.value)
    }
}

struct VariableLookup: Equatable {
    let variablesByName: [String: Variable]
    let duplicateNames: [String]

    init(variables: [Variable]) {
        var variablesByName: [String: Variable] = [:]
        var countsByName: [String: Int] = [:]

        for variable in variables {
            countsByName[variable.name, default: 0] += 1
            guard let existing = variablesByName[variable.name] else {
                variablesByName[variable.name] = variable
                continue
            }
            if Self.prefers(variable, over: existing) {
                variablesByName[variable.name] = variable
            }
        }

        self.variablesByName = variablesByName
        self.duplicateNames = countsByName.compactMap { name, count in
            count > 1 ? name : nil
        }
        .sorted()
    }

    private static func prefers(_ candidate: Variable, over existing: Variable) -> Bool {
        if candidate.updatedAt != existing.updatedAt {
            return candidate.updatedAt > existing.updatedAt
        }
        return candidate.id.uuidString > existing.id.uuidString
    }
}

enum VariableTokenStatus: Equatable {
    case resolved
    case missing
    case invalid
}

struct VariableToken: Equatable, Identifiable {
    var id: String { "\(range.location)-\(range.length)-\(rawText)" }
    var rawText: String
    var name: String?
    var range: NSRange
    var status: VariableTokenStatus
    var resolvedValue: String?
    var scope: VariableScope?
    var diagnostic: String? = nil
}

enum VariableTemplateSegment: Equatable, Identifiable {
    case text(String, NSRange)
    case token(VariableToken)

    var id: String {
        switch self {
        case .text(_, let range):
            return "text-\(range.location)-\(range.length)"
        case .token(let token):
            return "token-\(token.id)"
        }
    }
}

enum VariableExpansionIssue: Equatable, Hashable {
    case missing(name: String, path: [String])
    case invalidSyntax(token: String, path: [String])
    case cycle(path: [String])
    case depthExceeded(path: [String], limit: Int)
    case outputTooLarge(path: [String], limitBytes: Int)

    var diagnostic: String {
        switch self {
        case .missing(let name, let path):
            guard path.count > 1 else {
                return "\(name) is missing"
            }
            return "\(path.joined(separator: " → ")) refers to missing variable \(name)"
        case .invalidSyntax(let token, let path):
            let prefix = path.isEmpty ? "" : "\(path.joined(separator: " → ")): "
            return "\(prefix)\(token) has invalid syntax"
        case .cycle(let path):
            return "Circular variable reference: \(path.joined(separator: " → "))"
        case .depthExceeded(let path, let limit):
            return "Variable reference exceeds \(limit) levels: \(path.joined(separator: " → "))"
        case .outputTooLarge(let path, let limitBytes):
            let target = path.isEmpty ? "Expanded value" : path.joined(separator: " → ")
            return "\(target) exceeds the \(limitBytes / 1_024) KiB expanded-value limit"
        }
    }

    var missingName: String? {
        guard case .missing(let name, _) = self else { return nil }
        return name
    }

    var invalidToken: String? {
        guard case .invalidSyntax(let token, _) = self else { return nil }
        return token
    }

    var canonicalized: VariableExpansionIssue {
        guard case .cycle(let path) = self,
              path.count > 2,
              path.first == path.last else {
            return self
        }
        let members = Array(path.dropLast())
        let rotations = members.indices.map { index in
            Array(members[index...]) + Array(members[..<index])
        }
        guard let canonicalMembers = rotations.min(by: {
            $0.lexicographicallyPrecedes($1, by: <)
        }), let first = canonicalMembers.first else {
            return self
        }
        return .cycle(path: canonicalMembers + [first])
    }
}

struct VariableExpansion: Equatable {
    var value: String?
    var issues: [VariableExpansionIssue]
    var maximumDepth: Int
    var deepestPath: [String]
    var referencedVariableNames: Set<String>

    var isResolved: Bool {
        value != nil && issues.isEmpty
    }
}

struct VariableResolutionResult: Equatable {
    var resolvedRequest: Request?
    var urlTokens: [VariableToken]
    var headerValueTokensByHeaderID: [UUID: [VariableToken]]
    var referencedVariableNames: Set<String>
    var missingNames: [String]
    var invalidTokens: [String]
    var expansionIssues: [VariableExpansionIssue]
    var errorMessage: String?

    var hasErrors: Bool {
        errorMessage != nil || !missingNames.isEmpty || !invalidTokens.isEmpty
    }
}

enum VariableTemplateParser {
    enum Mode {
        case editing
        case execution
    }

    static func parse(_ text: String) -> [VariableTemplateSegment] {
        parse(text, variablesByName: [:])
    }

    static func parse(_ text: String, variables: [Variable]) -> [VariableTemplateSegment] {
        let variablesByName = VariableLookup(variables: variables).variablesByName
        let segments = parse(text, variablesByName: variablesByName)
        var resolver = VariableValueResolver(variablesByName: variablesByName)
        return resolver.decorateForPreview(segments)
    }

    static func parse(
        _ text: String,
        variablesByName: [String: Variable],
        mode: Mode = .editing
    ) -> [VariableTemplateSegment] {
        let source = text as NSString
        var segments: [VariableTemplateSegment] = []
        var cursor = 0

        while cursor < source.length {
            let searchRange = NSRange(location: cursor, length: source.length - cursor)
            let openRange = source.range(of: "{{", options: [], range: searchRange)

            guard openRange.location != NSNotFound else {
                appendTextIfNeeded(source.substring(with: searchRange), range: searchRange, to: &segments)
                break
            }

            if openRange.location > cursor {
                let textRange = NSRange(location: cursor, length: openRange.location - cursor)
                appendTextIfNeeded(source.substring(with: textRange), range: textRange, to: &segments)
            }

            let afterOpen = openRange.location + openRange.length
            let closingSearchRange = NSRange(location: afterOpen, length: source.length - afterOpen)
            let closeRange = source.range(of: "}}", options: [], range: closingSearchRange)

            guard closeRange.location != NSNotFound else {
                let remainderRange = NSRange(location: openRange.location, length: source.length - openRange.location)
                appendIncompleteSegment(source, range: remainderRange, mode: mode, to: &segments)
                break
            }

            let nestedOpenSearchRange = NSRange(location: afterOpen, length: closeRange.location - afterOpen)
            let nestedOpenRange = source.range(of: "{{", options: [], range: nestedOpenSearchRange)
            if nestedOpenRange.location != NSNotFound {
                let incompleteRange = NSRange(
                    location: openRange.location,
                    length: nestedOpenRange.location - openRange.location
                )
                appendIncompleteSegment(source, range: incompleteRange, mode: mode, to: &segments)
                cursor = nestedOpenRange.location
                continue
            }

            let tokenRange = NSRange(location: openRange.location, length: closeRange.location + closeRange.length - openRange.location)
            let contentRange = NSRange(location: afterOpen, length: closeRange.location - afterOpen)
            let rawText = source.substring(with: tokenRange)
            let name = source.substring(with: contentRange)

            if Variable.isValidName(name), let variable = variablesByName[name] {
                segments.append(.token(VariableToken(
                    rawText: rawText,
                    name: name,
                    range: tokenRange,
                    status: .resolved,
                    resolvedValue: variable.value,
                    scope: variable.scope
                )))
            } else if Variable.isValidName(name) {
                segments.append(.token(VariableToken(
                    rawText: rawText,
                    name: name,
                    range: tokenRange,
                    status: .missing,
                    resolvedValue: nil,
                    scope: nil
                )))
            } else {
                segments.append(.token(VariableToken(
                    rawText: rawText,
                    name: nil,
                    range: tokenRange,
                    status: .invalid,
                    resolvedValue: nil,
                    scope: nil
                )))
            }

            cursor = closeRange.location + closeRange.length
        }

        return segments
    }

    private static func appendTextIfNeeded(_ text: String, range: NSRange, to segments: inout [VariableTemplateSegment]) {
        guard !text.isEmpty else { return }
        segments.append(.text(text, range))
    }

    private static func appendIncompleteSegment(
        _ source: NSString,
        range: NSRange,
        mode: Mode,
        to segments: inout [VariableTemplateSegment]
    ) {
        let rawText = source.substring(with: range)
        guard mode == .execution else {
            appendTextIfNeeded(rawText, range: range, to: &segments)
            return
        }
        segments.append(.token(VariableToken(
            rawText: rawText,
            name: nil,
            range: range,
            status: .invalid,
            resolvedValue: nil,
            scope: nil
        )))
    }
}

struct VariableValueResolver {
    static let maximumDepth = 16
    static let maximumExpandedUTF8Bytes = 64 * 1_024

    private struct CacheEntry {
        var value: String
        var maximumDepth: Int
        var deepestPath: [String]
        var referencedVariableNames: Set<String>
    }

    private struct FailureCacheEntry {
        var issues: [VariableExpansionIssue]
        var maximumDepth: Int
        var deepestPath: [String]
        var referencedVariableNames: Set<String>
    }

    private let variablesByName: [String: Variable]
    private var resolvedCache: [String: CacheEntry] = [:]
    private var failedCache: [String: FailureCacheEntry] = [:]
    private(set) var maximumMaterializedUTF8Bytes = 0
    private(set) var uncachedResolutionCount = 0

    init(variablesByName: [String: Variable]) {
        self.variablesByName = variablesByName
    }

    mutating func decorateForPreview(_ segments: [VariableTemplateSegment]) -> [VariableTemplateSegment] {
        segments.map { segment in
            guard case .token(var token) = segment,
                  token.status == .resolved,
                  let name = token.name else {
                return segment
            }
            let expansion = resolveVariable(named: name)
            if let value = expansion.value, expansion.issues.isEmpty {
                token.resolvedValue = value
                token.diagnostic = nil
            } else {
                token.resolvedValue = nil
                token.status = expansion.issues.contains(where: { $0.missingName != nil }) ? .missing : .invalid
                token.diagnostic = expansion.issues.first?.diagnostic
            }
            return .token(token)
        }
    }

    mutating func expand(
        _ segments: [VariableTemplateSegment],
        enforceOutputLimit: Bool
    ) -> (
        segments: [VariableTemplateSegment],
        value: String?,
        issues: [VariableExpansionIssue],
        referencedVariableNames: Set<String>
    ) {
        var decorated: [VariableTemplateSegment] = []
        var issues: [VariableExpansionIssue] = []
        var rendered = ""
        var renderedUTF8Bytes = 0
        var referencedVariableNames: Set<String> = []
        let containsToken = segments.contains { segment in
            if case .token = segment { return true }
            return false
        }
        let shouldEnforceOutputLimit = enforceOutputLimit && containsToken
        var didExceedOutputLimit = false

        for segment in segments {
            switch segment {
            case .text(let text, let range):
                decorated.append(.text(text, range))
                if !didExceedOutputLimit,
                   !append(
                       text,
                       to: &rendered,
                       utf8ByteCount: &renderedUTF8Bytes,
                       enforceOutputLimit: shouldEnforceOutputLimit
                   ) {
                    didExceedOutputLimit = true
                    issues.append(.outputTooLarge(path: [], limitBytes: Self.maximumExpandedUTF8Bytes))
                }
            case .token(var token):
                guard token.status == .resolved, let name = token.name else {
                    let issue: VariableExpansionIssue
                    if token.status == .missing, let name = token.name {
                        referencedVariableNames.insert(name)
                        issue = .missing(name: name, path: [name])
                    } else {
                        issue = .invalidSyntax(token: token.rawText, path: [])
                    }
                    token.diagnostic = issue.diagnostic
                    decorated.append(.token(token))
                    issues.append(issue)
                    continue
                }

                referencedVariableNames.insert(name)
                let expansion = resolveVariable(named: name)
                referencedVariableNames.formUnion(expansion.referencedVariableNames)
                if let value = expansion.value, expansion.issues.isEmpty {
                    token.resolvedValue = value
                    token.diagnostic = nil
                    if !didExceedOutputLimit,
                       !append(
                           value,
                           to: &rendered,
                           utf8ByteCount: &renderedUTF8Bytes,
                           enforceOutputLimit: shouldEnforceOutputLimit
                       ) {
                        didExceedOutputLimit = true
                        issues.append(.outputTooLarge(path: [], limitBytes: Self.maximumExpandedUTF8Bytes))
                    }
                } else {
                    token.resolvedValue = nil
                    token.status = expansion.issues.contains(where: { $0.missingName != nil }) ? .missing : .invalid
                    token.diagnostic = expansion.issues.first?.diagnostic
                    issues.append(contentsOf: expansion.issues)
                }
                decorated.append(.token(token))
            }
        }

        issues = Self.uniqueIssues(issues)
        return (
            decorated,
            issues.isEmpty ? rendered : nil,
            issues,
            referencedVariableNames
        )
    }

    mutating func resolveVariable(named name: String) -> VariableExpansion {
        resolveVariable(named: name, stack: [])
    }

    private mutating func resolveVariable(named name: String, stack: [String]) -> VariableExpansion {
        if let cycleStart = stack.firstIndex(of: name) {
            return VariableExpansion(
                value: nil,
                issues: [.cycle(path: Array(stack[cycleStart...]) + [name])],
                maximumDepth: stack.count + 1,
                deepestPath: stack + [name],
                referencedVariableNames: [name]
            )
        }

        if stack.count >= Self.maximumDepth {
            let path = stack + [name]
            return VariableExpansion(
                value: nil,
                issues: [.depthExceeded(path: path, limit: Self.maximumDepth)],
                maximumDepth: path.count,
                deepestPath: path,
                referencedVariableNames: [name]
            )
        }

        if let cached = resolvedCache[name] {
            if stack.count + cached.maximumDepth > Self.maximumDepth {
                let allowedCount = max(0, Self.maximumDepth + 1 - stack.count)
                let path = stack + Array(cached.deepestPath.prefix(allowedCount))
                return VariableExpansion(
                    value: nil,
                    issues: [.depthExceeded(path: path, limit: Self.maximumDepth)],
                    maximumDepth: stack.count + cached.maximumDepth,
                    deepestPath: path,
                    referencedVariableNames: cached.referencedVariableNames
                )
            }
            return VariableExpansion(
                value: cached.value,
                issues: [],
                maximumDepth: cached.maximumDepth,
                deepestPath: cached.deepestPath,
                referencedVariableNames: cached.referencedVariableNames
            )
        }

        if let cached = failedCache[name],
           cached.referencedVariableNames.isDisjoint(with: stack) {
            if stack.count + cached.maximumDepth > Self.maximumDepth {
                let allowedCount = max(0, Self.maximumDepth + 1 - stack.count)
                let path = stack + Array(cached.deepestPath.prefix(allowedCount))
                return VariableExpansion(
                    value: nil,
                    issues: [.depthExceeded(path: path, limit: Self.maximumDepth)],
                    maximumDepth: stack.count + cached.maximumDepth,
                    deepestPath: path,
                    referencedVariableNames: cached.referencedVariableNames
                )
            }
            return VariableExpansion(
                value: nil,
                issues: cached.issues.map { Self.prefix(stack, to: $0) },
                maximumDepth: cached.maximumDepth,
                deepestPath: cached.deepestPath,
                referencedVariableNames: cached.referencedVariableNames
            )
        }

        uncachedResolutionCount += 1
        guard let variable = variablesByName[name] else {
            let path = stack + [name]
            return VariableExpansion(
                value: nil,
                issues: [.missing(name: name, path: path)],
                maximumDepth: path.count,
                deepestPath: path,
                referencedVariableNames: [name]
            )
        }

        let currentStack = stack + [name]
        let segments = VariableTemplateParser.parse(
            variable.value,
            variablesByName: variablesByName,
            mode: .execution
        )
        var rendered = ""
        var renderedUTF8Bytes = 0
        var didExceedOutputLimit = false
        var issues: [VariableExpansionIssue] = []
        var maximumDepth = 1
        var deepestPath = [name]
        var referencedVariableNames: Set<String> = [name]

        for segment in segments {
            switch segment {
            case .text(let text, _):
                if !didExceedOutputLimit,
                   !append(
                       text,
                       to: &rendered,
                       utf8ByteCount: &renderedUTF8Bytes,
                       enforceOutputLimit: true
                   ) {
                    didExceedOutputLimit = true
                    issues.append(.outputTooLarge(path: currentStack, limitBytes: Self.maximumExpandedUTF8Bytes))
                }
            case .token(let token):
                guard token.status == .resolved, let dependencyName = token.name else {
                    if token.status == .missing, let missingName = token.name {
                        referencedVariableNames.insert(missingName)
                        let path = currentStack + [missingName]
                        let relativePath = Array(path.dropFirst(stack.count))
                        if relativePath.count > maximumDepth {
                            maximumDepth = relativePath.count
                            deepestPath = relativePath
                        }
                        if path.count > Self.maximumDepth {
                            issues.append(.depthExceeded(path: path, limit: Self.maximumDepth))
                        } else {
                            issues.append(.missing(name: missingName, path: path))
                        }
                    } else {
                        issues.append(.invalidSyntax(token: token.rawText, path: currentStack))
                    }
                    continue
                }

                referencedVariableNames.insert(dependencyName)
                let dependency = resolveVariable(named: dependencyName, stack: currentStack)
                referencedVariableNames.formUnion(dependency.referencedVariableNames)
                if let value = dependency.value, dependency.issues.isEmpty {
                    if !didExceedOutputLimit,
                       !append(
                           value,
                           to: &rendered,
                           utf8ByteCount: &renderedUTF8Bytes,
                           enforceOutputLimit: true
                       ) {
                        didExceedOutputLimit = true
                        issues.append(.outputTooLarge(path: currentStack, limitBytes: Self.maximumExpandedUTF8Bytes))
                    }
                } else {
                    issues.append(contentsOf: dependency.issues)
                }
                let candidateDepth = 1 + dependency.maximumDepth
                if candidateDepth > maximumDepth {
                    maximumDepth = candidateDepth
                    deepestPath = [name] + dependency.deepestPath
                }
            }
        }

        issues = Self.uniqueIssues(issues)
        guard issues.isEmpty else {
            let expansion = VariableExpansion(
                value: nil,
                issues: issues,
                maximumDepth: maximumDepth,
                deepestPath: deepestPath,
                referencedVariableNames: referencedVariableNames
            )
            if issues.allSatisfy(Self.isContextIndependentFailure) {
                let relativeIssues = issues.map { Self.removingPrefix(stack, from: $0) }
                let cacheDepth = failureCacheDepthMetadata(
                    for: name,
                    issues: relativeIssues,
                    deepestPath: deepestPath
                )
                failedCache[name] = FailureCacheEntry(
                    issues: relativeIssues,
                    maximumDepth: cacheDepth.maximumDepth,
                    deepestPath: cacheDepth.deepestPath,
                    referencedVariableNames: referencedVariableNames
                )
            }
            return expansion
        }

        let entry = CacheEntry(
            value: rendered,
            maximumDepth: maximumDepth,
            deepestPath: deepestPath,
            referencedVariableNames: referencedVariableNames
        )
        resolvedCache[name] = entry
        return VariableExpansion(
            value: rendered,
            issues: [],
            maximumDepth: maximumDepth,
            deepestPath: deepestPath,
            referencedVariableNames: referencedVariableNames
        )
    }

    private static func uniqueIssues(_ issues: [VariableExpansionIssue]) -> [VariableExpansionIssue] {
        var seen: Set<VariableExpansionIssue> = []
        return issues.compactMap { issue in
            let canonical = issue.canonicalized
            return seen.insert(canonical).inserted ? canonical : nil
        }
    }

    private mutating func append(
        _ value: String,
        to rendered: inout String,
        utf8ByteCount: inout Int,
        enforceOutputLimit: Bool
    ) -> Bool {
        let valueUTF8Bytes = value.utf8.count
        if enforceOutputLimit,
           valueUTF8Bytes > Self.maximumExpandedUTF8Bytes - utf8ByteCount {
            return false
        }
        rendered.append(value)
        utf8ByteCount += valueUTF8Bytes
        maximumMaterializedUTF8Bytes = max(maximumMaterializedUTF8Bytes, utf8ByteCount)
        return true
    }

    private static func isContextIndependentFailure(_ issue: VariableExpansionIssue) -> Bool {
        switch issue {
        case .missing, .invalidSyntax, .outputTooLarge:
            return true
        case .cycle, .depthExceeded:
            return false
        }
    }

    private static func prefix(
        _ prefix: [String],
        to issue: VariableExpansionIssue
    ) -> VariableExpansionIssue {
        guard !prefix.isEmpty else { return issue }
        switch issue {
        case .missing(let name, let path):
            return .missing(name: name, path: prefix + path)
        case .invalidSyntax(let token, let path):
            return .invalidSyntax(token: token, path: prefix + path)
        case .cycle, .depthExceeded:
            return issue
        case .outputTooLarge(let path, let limitBytes):
            return .outputTooLarge(path: prefix + path, limitBytes: limitBytes)
        }
    }

    private static func removingPrefix(
        _ prefix: [String],
        from issue: VariableExpansionIssue
    ) -> VariableExpansionIssue {
        guard !prefix.isEmpty else { return issue }
        func relativePath(_ path: [String]) -> [String] {
            guard path.starts(with: prefix) else { return path }
            return Array(path.dropFirst(prefix.count))
        }
        switch issue {
        case .missing(let name, let path):
            return .missing(name: name, path: relativePath(path))
        case .invalidSyntax(let token, let path):
            return .invalidSyntax(token: token, path: relativePath(path))
        case .cycle, .depthExceeded:
            return issue
        case .outputTooLarge(let path, let limitBytes):
            return .outputTooLarge(path: relativePath(path), limitBytes: limitBytes)
        }
    }

    private func failureCacheDepthMetadata(
        for name: String,
        issues: [VariableExpansionIssue],
        deepestPath: [String]
    ) -> (maximumDepth: Int, deepestPath: [String]) {
        var candidatePaths = issues.compactMap(Self.path)
        candidatePaths.append(deepestPath)

        let relativePaths = candidatePaths.map { path -> [String] in
            let relativePath: ArraySlice<String>
            if let nameIndex = path.lastIndex(of: name) {
                relativePath = path[nameIndex...]
            } else {
                relativePath = [name][...]
            }
            return Array(relativePath)
        }
        let longestPath = relativePaths.max { lhs, rhs in
            if lhs.count != rhs.count {
                return lhs.count < rhs.count
            }
            return lhs.lexicographicallyPrecedes(rhs, by: <)
        }
        let resolvedPath = longestPath?.isEmpty == false ? longestPath! : [name]
        return (resolvedPath.count, resolvedPath)
    }

    private static func path(for issue: VariableExpansionIssue) -> [String]? {
        switch issue {
        case .missing(_, let path),
             .invalidSyntax(_, let path),
             .cycle(let path),
             .depthExceeded(let path, _),
             .outputTooLarge(let path, _):
            return path
        }
    }
}

enum VariableResolver {
    static func resolve(_ request: Request, variables: [Variable]) -> VariableResolutionResult {
        let variablesByName = VariableLookup(variables: variables).variablesByName
        var resolver = VariableValueResolver(variablesByName: variablesByName)
        let parsedURLSegments = VariableTemplateParser.parse(
            request.urlString,
            variablesByName: variablesByName,
            mode: .execution
        )
        let urlExpansion = resolver.expand(parsedURLSegments, enforceOutputLimit: true)
        let urlTokens = tokens(from: urlExpansion.segments)
        var expansionIssues = urlExpansion.issues
        var referencedVariableNames = urlExpansion.referencedVariableNames
        var resolvedHeaders: [Header] = []
        var headerValueTokensByHeaderID: [UUID: [VariableToken]] = [:]

        for header in request.headers {
            let parsedValueSegments = VariableTemplateParser.parse(
                header.value,
                variablesByName: variablesByName,
                mode: header.isEnabled ? .execution : .editing
            )
            let valueExpansion: (
                segments: [VariableTemplateSegment],
                value: String?,
                issues: [VariableExpansionIssue],
                referencedVariableNames: Set<String>
            )
            if header.isEnabled {
                valueExpansion = resolver.expand(parsedValueSegments, enforceOutputLimit: true)
            } else {
                valueExpansion = (
                    resolver.decorateForPreview(parsedValueSegments),
                    header.value,
                    [],
                    []
                )
            }
            let valueTokens = tokens(from: valueExpansion.segments)
            headerValueTokensByHeaderID[header.id] = valueTokens

            var resolvedHeader = header
            if header.isEnabled {
                expansionIssues.append(contentsOf: valueExpansion.issues)
                referencedVariableNames.formUnion(valueExpansion.referencedVariableNames)

                let nameSegments = VariableTemplateParser.parse(
                    header.name,
                    variablesByName: variablesByName,
                    mode: .execution
                )
                expansionIssues.append(contentsOf: tokens(from: nameSegments).map {
                    .invalidSyntax(token: $0.rawText, path: [])
                })
                if let resolvedValue = valueExpansion.value {
                    resolvedHeader.value = resolvedValue
                }
            }
            resolvedHeaders.append(resolvedHeader)
        }

        expansionIssues = uniqueIssues(expansionIssues)
        let missingNames = uniqueSorted(expansionIssues.compactMap(\.missingName))
        let invalidTokens = uniqueSorted(expansionIssues.compactMap(\.invalidToken))
        if !expansionIssues.isEmpty {
            return VariableResolutionResult(
                resolvedRequest: nil,
                urlTokens: urlTokens,
                headerValueTokensByHeaderID: headerValueTokensByHeaderID,
                referencedVariableNames: referencedVariableNames,
                missingNames: missingNames,
                invalidTokens: invalidTokens,
                expansionIssues: expansionIssues,
                errorMessage: expansionIssuesMessage(expansionIssues)
            )
        }

        let resolvedRequest = Request(
            method: request.method,
            urlString: urlExpansion.value ?? request.urlString,
            headers: resolvedHeaders,
            body: request.body,
            tlsCertificateVerification: request.tlsCertificateVerification
        )

        if let validationMessage = resolvedRequest.lightweightValidationMessage {
            return VariableResolutionResult(
                resolvedRequest: nil,
                urlTokens: urlTokens,
                headerValueTokensByHeaderID: headerValueTokensByHeaderID,
                referencedVariableNames: referencedVariableNames,
                missingNames: [],
                invalidTokens: [],
                expansionIssues: [],
                errorMessage: validationMessage
            )
        }

        return VariableResolutionResult(
            resolvedRequest: resolvedRequest,
            urlTokens: urlTokens,
            headerValueTokensByHeaderID: headerValueTokensByHeaderID,
            referencedVariableNames: referencedVariableNames,
            missingNames: [],
            invalidTokens: [],
            expansionIssues: [],
            errorMessage: nil
        )
    }

    private static func tokens(from segments: [VariableTemplateSegment]) -> [VariableToken] {
        segments.compactMap { segment in
            if case .token(let token) = segment {
                return token
            }
            return nil
        }
    }

    private static func uniqueSorted(_ values: [String]) -> [String] {
        Array(Set(values)).sorted()
    }

    private static func uniqueIssues(_ issues: [VariableExpansionIssue]) -> [VariableExpansionIssue] {
        var seen: Set<VariableExpansionIssue> = []
        return issues.compactMap { issue in
            let canonical = issue.canonicalized
            return seen.insert(canonical).inserted ? canonical : nil
        }
    }

    static func missingVariablesMessage(_ names: [String]) -> String {
        let displayNames = names.prefix(3)
        let joined: String
        if displayNames.count == 1 {
            joined = displayNames[0]
        } else if displayNames.count == 2 {
            joined = displayNames.joined(separator: " and ")
        } else {
            joined = displayNames.dropLast().joined(separator: ", ") + ", and " + displayNames.last!
        }
        let suffix = names.count > 3 ? " +\(names.count - 3) more" : ""
        return "Define \(joined)\(suffix) before running this request."
    }

    static func invalidSyntaxMessage(_ tokens: [String]) -> String {
        let examples = tokens.prefix(2).joined(separator: ", ")
        if examples.isEmpty {
            return "Fix invalid variable syntax. Use {{name}} with no spaces."
        }
        return "Fix invalid variable syntax. Use {{name}} with no spaces. Invalid: \(examples)"
    }

    static func expansionIssuesMessage(_ issues: [VariableExpansionIssue]) -> String {
        let invalid = uniqueSorted(issues.compactMap(\.invalidToken))
        let cycles = issues.compactMap { issue -> String? in
            guard case .cycle(let path) = issue else { return nil }
            return path.joined(separator: " → ")
        }
        let missing = uniqueSorted(issues.compactMap(\.missingName))
        let depths = issues.compactMap { issue -> String? in
            guard case .depthExceeded(let path, _) = issue else { return nil }
            return path.joined(separator: " → ")
        }
        let oversized = issues.compactMap { issue -> String? in
            guard case .outputTooLarge(let path, _) = issue else { return nil }
            return path.isEmpty ? "request field" : path.joined(separator: " → ")
        }

        if !invalid.isEmpty, cycles.isEmpty, missing.isEmpty, depths.isEmpty, oversized.isEmpty {
            return invalidSyntaxMessage(invalid)
        }
        if invalid.isEmpty, cycles.isEmpty, !missing.isEmpty, depths.isEmpty, oversized.isEmpty {
            return missingVariablesMessage(missing)
        }

        var groups: [String] = []
        appendIssueGroup(label: "Invalid", values: invalid, to: &groups)
        appendIssueGroup(label: "Circular", values: cycles, to: &groups)
        appendIssueGroup(label: "Missing", values: missing, to: &groups)
        appendIssueGroup(label: "Too deep", values: depths, to: &groups)
        appendIssueGroup(label: "Too large", values: oversized, to: &groups)
        return "Fix variable references before running. " + groups.joined(separator: ". ")
    }

    private static func appendIssueGroup(label: String, values: [String], to groups: inout [String]) {
        guard !values.isEmpty else { return }
        let unique = uniqueSorted(values)
        let displayed = unique.prefix(3).joined(separator: ", ")
        let suffix = unique.count > 3 ? " +\(unique.count - 3) more" : ""
        groups.append("\(label): \(displayed)\(suffix)")
    }
}

enum ExecutionState: Equatable {
    case idle
    case running
    case succeeded
    case failed
}

enum ResponseTone: Equatable {
    case neutral
    case success
    case warning
    case failure
}

struct ResponseHeader: Identifiable, Equatable, Codable {
    let id: UUID
    var name: String
    var value: String

    init(id: UUID = UUID(), name: String, value: String) {
        self.id = id
        self.name = name
        self.value = value
    }
}

struct ResponseSummary: Equatable {
    var statusCode: Int?
    var durationDescription: String?
    var sizeDescription: String?
    var timestampDescription: String?
    var tone: ResponseTone
}

enum ResponseViewMode: String, CaseIterable, Identifiable {
    case tree = "Pretty"
    case raw = "Raw"

    var id: String { rawValue }
}

indirect enum JSONValue: Equatable {
    case object([(String, JSONValue)])
    case array([JSONValue])
    case string(String)
    case number(String)
    case bool(Bool)
    case null

    var kindLabel: String {
        switch self {
        case .object(let pairs):
            return "Object (\(pairs.count))"
        case .array(let values):
            return "Array (\(values.count))"
        case .string(let value):
            return "\"\(value)\""
        case .number(let value):
            return value
        case .bool(let value):
            return value ? "true" : "false"
        case .null:
            return "null"
        }
    }

    static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case let (.object(leftPairs), .object(rightPairs)):
            guard leftPairs.count == rightPairs.count else { return false }
            return zip(leftPairs, rightPairs).allSatisfy { left, right in
                left.0 == right.0 && left.1 == right.1
            }
        case let (.array(leftValues), .array(rightValues)):
            return leftValues == rightValues
        case let (.string(leftValue), .string(rightValue)):
            return leftValue == rightValue
        case let (.number(leftValue), .number(rightValue)):
            return leftValue == rightValue
        case let (.bool(leftValue), .bool(rightValue)):
            return leftValue == rightValue
        case (.null, .null):
            return true
        default:
            return false
        }
    }
}

struct ResponseBody: Equatable {
    var headerText: String
    var bodyText: String
    var isPreviewable: Bool
    var rawData: Data
    var mimeType: String?
    var jsonValue: JSONValue?
    var exportFilename: String
}

struct VisibleResponseState: Equatable {
    var summary: ResponseSummary
    var body: ResponseBody
    var selectedMode: ResponseViewMode
    var isStale: Bool
}

struct LastExecutedRequest: Equatable {
    var request: Request
}

enum CurlPreviewContent: Equatable {
    case loading
    case command(String)
    case error(String)
}

struct CurlPreviewState: Equatable {
    var id: UUID
    var content: CurlPreviewContent
}

struct ExecutedResponse: Equatable {
    var request: Request
    var statusCode: Int
    var headers: [ResponseHeader]
    var bodyData: Data
    var mimeType: String?
    var duration: TimeInterval
    var timestamp: Date
}

enum ExecutionError: LocalizedError, Equatable {
    case invalidRequest(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest(let message):
            return message
        case .transport(let message):
            return message
        }
    }
}

struct ReplaceConfirmationState: Equatable {
    var rawInput: String
    var candidateRequest: Request
    var candidateWarnings: [String]
    var sourceCurl: String?

    init(
        rawInput: String,
        candidateRequest: Request,
        candidateWarnings: [String] = [],
        sourceCurl: String? = nil
    ) {
        self.rawInput = rawInput
        self.candidateRequest = candidateRequest
        self.candidateWarnings = candidateWarnings
        self.sourceCurl = sourceCurl
    }
}

enum InlineMessageSeverity: Equatable {
    case warning
    case error
}

struct InlineMessage: Equatable {
    var severity: InlineMessageSeverity
    var text: String
}

enum RequestEditorSection: Equatable {
    case headers
    case body
    case postResponseScript
}

struct RequestEditorExpansionState: Equatable {
    var headersExpanded: Bool
    var bodyExpanded: Bool
    var postResponseScriptExpanded: Bool

    static let allExpanded = RequestEditorExpansionState(
        headersExpanded: true,
        bodyExpanded: true,
        postResponseScriptExpanded: false
    )

    mutating func toggle(_ section: RequestEditorSection) {
        switch section {
        case .headers:
            headersExpanded.toggle()
        case .body:
            bodyExpanded.toggle()
        case .postResponseScript:
            postResponseScriptExpanded.toggle()
        }
    }
}

enum PostResponseScriptStatus: Equatable {
    case off
    case ready
    case invalid
    case running
    case passed
    case failed
    case stale
}

struct PostResponseScriptState: Equatable {
    var status: PostResponseScriptStatus
    var diagnostic: ScriptDiagnostic?
    var logs: [ScriptLogEntry]
    var durationMs: Int?
    var changedVariableCount: Int

    static let off = PostResponseScriptState(
        status: .off,
        diagnostic: nil,
        logs: [],
        durationMs: nil,
        changedVariableCount: 0
    )

    static let ready = PostResponseScriptState(
        status: .ready,
        diagnostic: nil,
        logs: [],
        durationMs: nil,
        changedVariableCount: 0
    )
}

struct SessionState: Equatable {
    var workspaceRequest: Request
    var workspaceName: String
    var requestAutomation: RequestAutomation
    var postResponseScriptState: PostResponseScriptState
    var requestListItems: [RequestListItem]
    var isLibraryCollapsed: Bool
    var selectedSavedRequestID: UUID?
    var selectedRequestContext: SelectionContext
    var isCurrentRequestDirty: Bool
    var canSaveCurrentRequest: Bool
    var canRevertCurrentRequest: Bool
    var canDiscardHiddenNewDraft: Bool
    var persistenceWarningMessage: String?
    var lastExecutedRequest: LastExecutedRequest?
    var executionState: ExecutionState
    var visibleResponseState: VisibleResponseState?
    var replaceConfirmationState: ReplaceConfirmationState?
    var inlineMessage: InlineMessage?
    var isWindowVisible: Bool
    var requestEditorExpansion: RequestEditorExpansionState
    var variables: [Variable]
    var isVariablesModalPresented: Bool
    var curlPreviewState: CurlPreviewState?

    init(
        workspaceRequest: Request,
        workspaceName: String = "Untitled Request",
        requestAutomation: RequestAutomation = .none,
        postResponseScriptState: PostResponseScriptState = .off,
        requestListItems: [RequestListItem] = [],
        isLibraryCollapsed: Bool = false,
        selectedSavedRequestID: UUID? = nil,
        selectedRequestContext: SelectionContext = .hiddenNewDraft,
        isCurrentRequestDirty: Bool = false,
        canSaveCurrentRequest: Bool = false,
        canRevertCurrentRequest: Bool = false,
        canDiscardHiddenNewDraft: Bool = false,
        persistenceWarningMessage: String? = nil,
        lastExecutedRequest: LastExecutedRequest?,
        executionState: ExecutionState,
        visibleResponseState: VisibleResponseState?,
        replaceConfirmationState: ReplaceConfirmationState?,
        inlineMessage: InlineMessage? = nil,
        inlineErrorMessage: String? = nil,
        isWindowVisible: Bool,
        requestEditorExpansion: RequestEditorExpansionState = .allExpanded,
        variables: [Variable] = [],
        isVariablesModalPresented: Bool = false,
        curlPreviewState: CurlPreviewState? = nil
    ) {
        self.workspaceRequest = workspaceRequest
        self.workspaceName = workspaceName
        self.requestAutomation = requestAutomation
        self.postResponseScriptState = postResponseScriptState
        self.requestListItems = requestListItems
        self.isLibraryCollapsed = isLibraryCollapsed
        self.selectedSavedRequestID = selectedSavedRequestID
        self.selectedRequestContext = selectedRequestContext
        self.isCurrentRequestDirty = isCurrentRequestDirty
        self.canSaveCurrentRequest = canSaveCurrentRequest
        self.canRevertCurrentRequest = canRevertCurrentRequest
        self.canDiscardHiddenNewDraft = canDiscardHiddenNewDraft
        self.persistenceWarningMessage = persistenceWarningMessage
        self.lastExecutedRequest = lastExecutedRequest
        self.executionState = executionState
        self.visibleResponseState = visibleResponseState
        self.replaceConfirmationState = replaceConfirmationState
        self.inlineMessage = inlineMessage ?? inlineErrorMessage.map { InlineMessage(severity: .error, text: $0) }
        self.isWindowVisible = isWindowVisible
        self.requestEditorExpansion = requestEditorExpansion
        self.variables = variables
        self.isVariablesModalPresented = isVariablesModalPresented
        self.curlPreviewState = curlPreviewState
    }

    static let initial = SessionState(
        workspaceRequest: .empty,
        workspaceName: "Untitled Request",
        requestAutomation: .none,
        postResponseScriptState: .off,
        requestListItems: [],
        isLibraryCollapsed: false,
        selectedSavedRequestID: nil,
        selectedRequestContext: .hiddenNewDraft,
        isCurrentRequestDirty: false,
        canSaveCurrentRequest: false,
        canRevertCurrentRequest: false,
        canDiscardHiddenNewDraft: false,
        persistenceWarningMessage: nil,
        lastExecutedRequest: nil,
        executionState: .idle,
        visibleResponseState: nil,
        replaceConfirmationState: nil,
        isWindowVisible: true,
        requestEditorExpansion: .allExpanded,
        variables: [],
        isVariablesModalPresented: false,
        curlPreviewState: nil
    )

    var requestIssueMessage: String? {
        inlineMessage?.text ?? workspaceRequest.lightweightValidationMessage
    }

    var requestIssueSeverity: InlineMessageSeverity {
        inlineMessage?.severity ?? .error
    }

    var inlineErrorMessage: String? {
        guard inlineMessage?.severity == .error else {
            return nil
        }
        return inlineMessage?.text
    }

    var canRun: Bool {
        guard executionState != .running, postResponseScriptState.status != .running else {
            return false
        }
        let trimmedURL = workspaceRequest.urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else {
            return false
        }
        return workspaceRequest.isMinimallyValid || trimmedURL.contains("{{")
    }

    var canRerun: Bool {
        executionState != .running && lastExecutedRequest != nil
    }

    var statusTitle: String {
        switch executionState {
        case .idle:
            return lastExecutedRequest == nil ? "Idle" : "Ready"
        case .running:
            return "Running"
        case .succeeded:
            if let statusCode = visibleResponseState?.summary.statusCode {
                return "Status \(statusCode)"
            }
            return "Succeeded"
        case .failed:
            return "Failed"
        }
    }

    var statusSubtitle: String {
        switch executionState {
        case .idle:
            return lastExecutedRequest == nil ? "No request has run in this session." : "Last executed request is available to rerun."
        case .running:
            return "The current request is in flight."
        case .succeeded:
            return "Last request completed."
        case .failed:
            return inlineMessage?.text ?? "Last request failed."
        }
    }

    var statusTone: ResponseTone {
        if executionState == .running {
            return .neutral
        }
        if executionState == .failed {
            return .failure
        }
        return visibleResponseState?.summary.tone ?? .neutral
    }

    var statusIconName: String {
        switch statusTone {
        case .neutral:
            if executionState == .running {
                return "arrow.triangle.2.circlepath.circle"
            }
            if executionState == .failed {
                return "exclamationmark.triangle"
            }
            return "bolt.horizontal.circle"
        case .success:
            return "checkmark.circle"
        case .warning:
            return "exclamationmark.circle"
        case .failure:
            return "xmark.circle"
        }
    }

    var currentResponseMode: ResponseViewMode {
        visibleResponseState?.selectedMode ?? .tree
    }

    var hasVisibleResponse: Bool {
        visibleResponseState != nil
    }

    var canExportResponseBody: Bool {
        visibleResponseState != nil
    }

    var responseSummaryStatusValue: String {
        if executionState == .running {
            return "Running"
        }
        if executionState == .failed {
            return "Failed"
        }
        if let statusCode = visibleResponseState?.summary.statusCode {
            return "\(statusCode)"
        }
        return "--"
    }

    var responseSummaryDurationValue: String {
        visibleResponseState?.summary.durationDescription ?? "--"
    }

    var responseSummarySizeValue: String {
        visibleResponseState?.summary.sizeDescription ?? "--"
    }

    var responseSummaryTimestampValue: String {
        visibleResponseState?.summary.timestampDescription ?? "--"
    }

    var responseTone: ResponseTone {
        if executionState == .running {
            return .neutral
        }
        if executionState == .failed {
            return .failure
        }
        return visibleResponseState?.summary.tone ?? statusTone
    }

    var responseIsStale: Bool {
        visibleResponseState?.isStale ?? false
    }

    var responseJSONValue: JSONValue? {
        visibleResponseState?.body.jsonValue
    }

    var responseBodyHeaderText: String {
        visibleResponseState?.body.headerText ?? ""
    }

    var responseBodyText: String {
        visibleResponseState?.body.bodyText ?? ""
    }

    var responseBodyIsPreviewable: Bool {
        visibleResponseState?.body.isPreviewable ?? false
    }

    var responseMimeType: String? {
        visibleResponseState?.body.mimeType
    }

    var responseExportFilename: String? {
        visibleResponseState?.body.exportFilename
    }

    var responseHeaderAndBodyText: String {
        guard let body = visibleResponseState?.body else {
            return ""
        }

        if body.headerText.isEmpty {
            return body.bodyText
        }

        if body.bodyText.isEmpty {
            return body.headerText
        }

        return body.headerText + "\n\n" + body.bodyText
    }

    var responsePlaceholderTitle: String {
        switch executionState {
        case .idle:
            return "Response workspace is ready"
        case .running:
            return "Request is running"
        case .succeeded:
            return "Response received"
        case .failed:
            return "Request failed"
        }
    }

    var responsePlaceholderMessage: String {
        switch executionState {
        case .idle:
            return "Run a request to inspect the response body, headers, and JSON tree."
        case .running:
            return "The request is in flight. This view will update when the response arrives."
        case .succeeded:
            return "Switch between tree and raw modes to inspect the last response."
        case .failed:
            return inlineMessage?.text ?? "The last request failed before a response could be rendered."
        }
    }
}
