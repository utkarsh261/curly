import Darwin
import Foundation

protocol RequestExecuting {
    func execute(_ request: Request) async throws -> ExecutedResponse
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
    private let allowsInsecureLoopbackTLS: @Sendable () -> Bool

    init(
        transport: HTTPTransporting = URLSessionHTTPTransport(),
        now: @escaping () -> Date = Date.init,
        allowsInsecureLoopbackTLS: @escaping @Sendable () -> Bool = {
            UserDefaults.standard.bool(forKey: TLSVerificationPreferences.allowInsecureLoopbackHostsKey)
        }
    ) {
        self.transport = transport
        self.now = now
        self.allowsInsecureLoopbackTLS = allowsInsecureLoopbackTLS
    }

    func execute(_ request: Request) async throws -> ExecutedResponse {
        guard request.isMinimallyValid else {
            throw ExecutionError.invalidRequest(request.lightweightValidationMessage ?? "The request is not runnable yet.")
        }

        let urlRequest = try buildURLRequest(from: request)
        let start = now()

        do {
            let (bodyData, httpResponse) = try await transport.send(
                urlRequest,
                serverTrustPolicy: effectiveServerTrustPolicy(for: request)
            )
            let end = now()
            let headers = httpResponse.allHeaderFields
                .map { ResponseHeader(name: String(describing: $0.key), value: String(describing: $0.value)) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            return ExecutedResponse(
                request: request,
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

    private func buildURLRequest(from request: Request) throws -> URLRequest {
        guard let url = URL(string: request.urlString) else {
            throw ExecutionError.invalidRequest("The request URL is not valid.")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue

        for header in request.headers where header.isEnabled {
            let trimmedName = header.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else {
                continue
            }
            urlRequest.setValue(header.value, forHTTPHeaderField: trimmedName)
        }

        switch request.body {
        case .none:
            break
        case .text(let text):
            let bodyText = request.hasJSONContentType ? JSONCommentStripper.stripComments(from: text) : text
            urlRequest.httpBody = bodyText.data(using: .utf8)
        }

        return urlRequest
    }
}

private extension Request {
    var hasJSONContentType: Bool {
        headers.contains { header in
            header.isEnabled &&
            header.name.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare("Content-Type") == .orderedSame &&
            header.value.localizedCaseInsensitiveContains("json")
        }
    }
}
