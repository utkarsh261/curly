import Darwin
import Foundation

protocol RequestExecuting {
    func execute(_ request: PreparedHTTPRequest) async throws -> ExecutedResponse
}

struct PreparedHTTPHeader: Equatable, Sendable {
    var name: String
    var value: String
}

struct PreparedHTTPRequest: Equatable, @unchecked Sendable {
    var sourceRequest: Request
    var urlRequest: URLRequest
    var headers: [PreparedHTTPHeader]
    var bodyData: Data?
    var serverTrustPolicy: ServerTrustPolicy
}

protocol HTTPRequestPreparing: Sendable {
    func prepare(_ request: Request) throws -> PreparedHTTPRequest
}

struct DefaultHTTPRequestPreparer: HTTPRequestPreparing {
    private let allowsInsecureLoopbackTLS: @Sendable () -> Bool

    init(
        allowsInsecureLoopbackTLS: @escaping @Sendable () -> Bool = {
            UserDefaults.standard.bool(forKey: TLSVerificationPreferences.allowInsecureLoopbackHostsKey)
        }
    ) {
        self.allowsInsecureLoopbackTLS = allowsInsecureLoopbackTLS
    }

    func prepare(_ request: Request) throws -> PreparedHTTPRequest {
        guard request.isMinimallyValid else {
            throw ExecutionError.invalidRequest(
                request.lightweightValidationMessage ?? "The request is not runnable yet."
            )
        }
        guard let url = URL(string: request.urlString) else {
            throw ExecutionError.invalidRequest("The request URL is not valid.")
        }

        var effectiveHeadersByName: [String: PreparedHTTPHeader] = [:]
        for header in request.headers where header.isEnabled {
            let trimmedName = header.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else {
                continue
            }
            effectiveHeadersByName[trimmedName.lowercased()] = PreparedHTTPHeader(
                name: trimmedName,
                value: header.value
            )
        }
        let headers = effectiveHeadersByName.values.sorted {
            let lhsName = $0.name.lowercased()
            let rhsName = $1.name.lowercased()
            if lhsName == rhsName {
                return $0.name < $1.name
            }
            return lhsName < rhsName
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue
        for header in headers {
            urlRequest.setValue(header.value, forHTTPHeaderField: header.name)
        }

        let bodyData: Data?
        switch request.body {
        case .none:
            bodyData = nil
        case .text(let text):
            let bodyText = request.hasJSONContentType
                ? JSONCommentStripper.stripComments(from: text)
                : text
            bodyData = Data(bodyText.utf8)
            urlRequest.httpBody = bodyData
        }

        return PreparedHTTPRequest(
            sourceRequest: request,
            urlRequest: urlRequest,
            headers: headers,
            bodyData: bodyData,
            serverTrustPolicy: effectiveServerTrustPolicy(for: request)
        )
    }

    private func effectiveServerTrustPolicy(for request: Request) -> ServerTrustPolicy {
        if request.tlsCertificateVerification == .disabled {
            return .disabled
        }
        if allowsInsecureLoopbackTLS(),
           let host = URL(string: request.urlString)?.host,
           LoopbackHost.matches(host) {
            return .disabledForLoopbackHosts
        }
        return .systemDefault
    }
}

protocol CurlCommandRendering: Sendable {
    func render(_ request: PreparedHTTPRequest) -> String
}

struct DefaultCurlCommandRenderer: CurlCommandRendering {
    func render(_ request: PreparedHTTPRequest) -> String {
        let containsNUL = request.bodyData?.contains(0) == true
        var options: [String] = []

        if request.serverTrustPolicy != .systemDefault {
            options.append("--insecure")
        }
        if let methodOption = methodOption(for: request) {
            options.append(methodOption)
        }
        options.append("--url \(shellQuote(request.urlRequest.url?.absoluteString ?? request.sourceRequest.urlString))")

        let hasContentType = request.headers.contains {
            $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame
        }
        if request.bodyData != nil, !hasContentType {
            options.append("--header \(shellQuote("Content-Type:"))")
        }
        for header in request.headers {
            let value = header.value.isEmpty
                ? "\(header.name);"
                : "\(header.name): \(header.value)"
            options.append("--header \(shellQuote(value))")
        }

        if let bodyData = request.bodyData {
            if containsNUL {
                options.append("--data-binary @-")
            } else {
                let body = String(decoding: bodyData, as: UTF8.self)
                options.append("--data-raw \(shellQuote(body))")
            }
        }

        let curlLines = ["curl --location"] + options.map { "  \($0)" }
        guard containsNUL, let bodyData = request.bodyData else {
            return continued(curlLines)
        }

        let escapedBytes = bodyData.map { String(format: "\\%03o", $0) }.joined()
        let pipelineLines = [
            "printf '%b' '\(escapedBytes)' |",
            "  curl --location"
        ] + options.map { "    \($0)" }
        return continued(pipelineLines)
    }

    private func methodOption(for request: PreparedHTTPRequest) -> String? {
        let hasBody = request.bodyData != nil
        switch (request.sourceRequest.method, hasBody) {
        case (.get, false):
            return nil
        case (.head, false):
            return "--head"
        case (.post, true):
            return nil
        default:
            return "--request \(request.sourceRequest.method.rawValue)"
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func continued(_ lines: [String]) -> String {
        lines.enumerated().map { index, line in
            index == lines.indices.last ? line : "\(line) \\"
        }
        .joined(separator: "\n")
    }
}

protocol HTTPTransporting {
    func send(
        _ request: URLRequest,
        serverTrustPolicy: ServerTrustPolicy
    ) async throws -> (Data, HTTPURLResponse)
}

enum ServerTrustPolicy: Equatable {
    case systemDefault
    case disabled
    case disabledForLoopbackHosts
}

enum TLSVerificationPreferences {
    static let allowInsecureLoopbackHostsKey = "security.allowInsecureLoopbackTLS"
}

final class URLSessionHTTPTransport: HTTPTransporting, @unchecked Sendable {
    private let disabledVerificationSession: URLSession
    private let loopbackVerificationSession: URLSession

    init() {
        disabledVerificationSession = URLSession(
            configuration: .default,
            delegate: ServerTrustURLSessionDelegate(policy: .disabled),
            delegateQueue: nil
        )
        loopbackVerificationSession = URLSession(
            configuration: .default,
            delegate: ServerTrustURLSessionDelegate(policy: .disabledForLoopbackHosts),
            delegateQueue: nil
        )
    }

    deinit {
        disabledVerificationSession.invalidateAndCancel()
        loopbackVerificationSession.invalidateAndCancel()
    }

    func send(
        _ request: URLRequest,
        serverTrustPolicy: ServerTrustPolicy
    ) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse

        switch serverTrustPolicy {
        case .systemDefault:
            (data, response) = try await URLSession.shared.data(for: request)
        case .disabled:
            (data, response) = try await disabledVerificationSession.data(for: request)
        case .disabledForLoopbackHosts:
            (data, response) = try await loopbackVerificationSession.data(for: request)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ExecutionError.transport("The server did not return an HTTP response.")
        }
        return (data, httpResponse)
    }
}

private final class ServerTrustURLSessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let policy: ServerTrustPolicy

    init(policy: ServerTrustPolicy) {
        self.policy = policy
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let shouldDisableVerification: Bool
        switch policy {
        case .systemDefault:
            shouldDisableVerification = false
        case .disabled:
            shouldDisableVerification = true
        case .disabledForLoopbackHosts:
            shouldDisableVerification = LoopbackHost.matches(challenge.protectionSpace.host)
        }

        guard shouldDisableVerification else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        completionHandler(.useCredential, URLCredential(trust: serverTrust))
    }
}

enum LoopbackHost {
    static func matches(_ rawHost: String) -> Bool {
        let host = rawHost
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()

        if host == "localhost" || host.hasSuffix(".localhost") {
            return true
        }

        var ipv4Address = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &ipv4Address) }) == 1 {
            return UInt32(bigEndian: ipv4Address.s_addr) >> 24 == 127
        }

        var ipv6Address = in6_addr()
        guard host.withCString({ inet_pton(AF_INET6, $0, &ipv6Address) }) == 1 else {
            return false
        }
        return withUnsafeBytes(of: ipv6Address) { bytes in
            bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
        }
    }
}

struct URLSessionRequestExecutor: RequestExecuting {
    private let transport: HTTPTransporting
    private let now: () -> Date
    private let requestPreparer: HTTPRequestPreparing

    init(
        transport: HTTPTransporting = URLSessionHTTPTransport(),
        now: @escaping () -> Date = Date.init,
        allowsInsecureLoopbackTLS: @escaping @Sendable () -> Bool = {
            UserDefaults.standard.bool(forKey: TLSVerificationPreferences.allowInsecureLoopbackHostsKey)
        }
    ) {
        self.transport = transport
        self.now = now
        self.requestPreparer = DefaultHTTPRequestPreparer(
            allowsInsecureLoopbackTLS: allowsInsecureLoopbackTLS
        )
    }

    func execute(_ request: PreparedHTTPRequest) async throws -> ExecutedResponse {
        let start = now()

        do {
            let (bodyData, httpResponse) = try await transport.send(
                request.urlRequest,
                serverTrustPolicy: request.serverTrustPolicy
            )
            let end = now()
            let headers = httpResponse.allHeaderFields
                .map { ResponseHeader(name: String(describing: $0.key), value: String(describing: $0.value)) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            return ExecutedResponse(
                request: request.sourceRequest,
                statusCode: httpResponse.statusCode,
                headers: headers,
                bodyData: bodyData,
                mimeType: httpResponse.mimeType ?? httpResponse.value(forHTTPHeaderField: "Content-Type"),
                duration: end.timeIntervalSince(start),
                timestamp: end
            )
        } catch let error as ExecutionError {
            throw error
        } catch {
            throw ExecutionError.transport(error.localizedDescription)
        }
    }

    func execute(_ request: Request) async throws -> ExecutedResponse {
        try await execute(requestPreparer.prepare(request))
    }
}

extension Request {
    var hasJSONContentType: Bool {
        headers.last(where: { header in
            header.isEnabled &&
            header.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare("Content-Type") == .orderedSame
        })?.value.localizedCaseInsensitiveContains("json") == true
    }
}
