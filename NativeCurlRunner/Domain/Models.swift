import Foundation

enum HTTPMethod: String, CaseIterable, Codable, Identifiable {
    case get = "GET"
    case head = "HEAD"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"

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

struct Request: Equatable, Codable {
    var method: HTTPMethod
    var urlString: String
    var headers: [Header]
    var body: RequestBody

    static let empty = Request(method: .get, urlString: "", headers: [], body: .none)

    var isEffectivelyEmpty: Bool {
        urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
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

        if headers.contains(where: { $0.isEnabled && $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return "Enabled header rows need a header name."
        }

        return nil
    }

    var isMinimallyValid: Bool {
        lightweightValidationMessage == nil && !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
    case tree = "Tree"
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

struct SessionState: Equatable {
    var workspaceRequest: Request
    var lastExecutedRequest: LastExecutedRequest?
    var executionState: ExecutionState
    var visibleResponseState: VisibleResponseState?
    var replaceConfirmationState: ReplaceConfirmationState?
    var inlineMessage: InlineMessage?
    var isWindowVisible: Bool

    init(
        workspaceRequest: Request,
        lastExecutedRequest: LastExecutedRequest?,
        executionState: ExecutionState,
        visibleResponseState: VisibleResponseState?,
        replaceConfirmationState: ReplaceConfirmationState?,
        inlineMessage: InlineMessage? = nil,
        inlineErrorMessage: String? = nil,
        isWindowVisible: Bool
    ) {
        self.workspaceRequest = workspaceRequest
        self.lastExecutedRequest = lastExecutedRequest
        self.executionState = executionState
        self.visibleResponseState = visibleResponseState
        self.replaceConfirmationState = replaceConfirmationState
        self.inlineMessage = inlineMessage ?? inlineErrorMessage.map { InlineMessage(severity: .error, text: $0) }
        self.isWindowVisible = isWindowVisible
    }

    static let initial = SessionState(
        workspaceRequest: .empty,
        lastExecutedRequest: nil,
        executionState: .idle,
        visibleResponseState: nil,
        replaceConfirmationState: nil,
        isWindowVisible: true
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
        executionState != .running && workspaceRequest.isMinimallyValid
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
        visibleResponseState?.summary.tone ?? statusTone
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
