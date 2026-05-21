import Foundation

protocol RequestExecuting {
    func execute(_ request: Request) async throws -> ExecutedResponse
}

protocol HTTPTransporting {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionHTTPTransport: HTTPTransporting {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ExecutionError.transport("The server did not return an HTTP response.")
        }
        return (data, httpResponse)
    }
}

struct URLSessionRequestExecutor: RequestExecuting {
    private let transport: HTTPTransporting
    private let now: () -> Date

    init(
        transport: HTTPTransporting = URLSessionHTTPTransport(),
        now: @escaping () -> Date = Date.init
    ) {
        self.transport = transport
        self.now = now
    }

    func execute(_ request: Request) async throws -> ExecutedResponse {
        guard request.isMinimallyValid else {
            throw ExecutionError.invalidRequest(request.lightweightValidationMessage ?? "The request is not runnable yet.")
        }

        let urlRequest = try buildURLRequest(from: request)
        let start = now()

        do {
            let (bodyData, httpResponse) = try await transport.send(urlRequest)
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

    private func buildURLRequest(from request: Request) throws -> URLRequest {
        guard let url = URL(string: request.urlString) else {
            throw ExecutionError.invalidRequest("The request URL is not valid.")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue

        for header in request.headers where header.isEnabled {
            let trimmedName = header.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else {
                throw ExecutionError.invalidRequest("Enabled header rows need a header name.")
            }
            urlRequest.setValue(header.value, forHTTPHeaderField: trimmedName)
        }

        switch request.body {
        case .none:
            break
        case .text(let text):
            urlRequest.httpBody = text.data(using: .utf8)
        }

        return urlRequest
    }
}
