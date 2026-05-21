import XCTest
@testable import NativeCurlRunner

final class RequestExecutorTests: XCTestCase {
    func testExecutesMinimallyValidRequest() async throws {
        let transport = StubTransport(
            result: .success(
                (
                    Data("{\"ok\":true}".utf8),
                    makeHTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"])
                )
            )
        )
        let executor = URLSessionRequestExecutor(
            transport: transport,
            now: FixedDateSource.dates([
                Date(timeIntervalSince1970: 100),
                Date(timeIntervalSince1970: 100.12)
            ])
        )

        let request = Request(method: .post, urlString: "https://example.com/users", headers: [Header(name: "Accept", value: "application/json")], body: .text("{\"name\":\"utk\"}"))
        let response = try await executor.execute(request)

        XCTAssertEqual(response.request, request)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.mimeType, "application/json")
        XCTAssertEqual(response.bodyData, Data("{\"ok\":true}".utf8))
        XCTAssertEqual(response.headers.map(\.name), ["Content-Type"])
        XCTAssertEqual(response.duration, 0.12, accuracy: 0.0001)
        let sent = await transport.capturedRequest
        XCTAssertEqual(sent?.httpMethod, "POST")
        XCTAssertEqual(sent?.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(sent?.httpBody, Data("{\"name\":\"utk\"}".utf8))
    }

    func testInvalidRequestFailsWithoutDispatch() async {
        let transport = StubTransport(result: .failure(ExecutionError.transport("unused")))
        let executor = URLSessionRequestExecutor(transport: transport)
        let invalid = Request(method: .get, urlString: "localhost:3000", headers: [], body: .none)

        do {
            _ = try await executor.execute(invalid)
            XCTFail("Expected validation failure")
        } catch let error as ExecutionError {
            XCTAssertEqual(error, .invalidRequest("Use an absolute http or https URL."))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let count = await transport.invocationCount
        XCTAssertEqual(count, 0)
    }

    func testNon2xxResponseStillReturnsExecutedResponse() async throws {
        let transport = StubTransport(
            result: .success(
                (
                    Data("fail".utf8),
                    makeHTTPResponse(statusCode: 503, headers: ["Content-Type": "text/plain"])
                )
            )
        )
        let executor = URLSessionRequestExecutor(transport: transport)
        let request = Request(method: .get, urlString: "https://example.com/health", headers: [], body: .none)

        let response = try await executor.execute(request)

        XCTAssertEqual(response.statusCode, 503)
        XCTAssertEqual(response.bodyData, Data("fail".utf8))
    }

    func testHeadRequestUsesHeadMethod() async throws {
        let transport = StubTransport(
            result: .success(
                (
                    Data(),
                    makeHTTPResponse(statusCode: 200, headers: [:])
                )
            )
        )
        let executor = URLSessionRequestExecutor(transport: transport)
        let request = Request(method: .head, urlString: "https://example.com", headers: [], body: .none)

        _ = try await executor.execute(request)

        let sent = await transport.capturedRequest
        XCTAssertEqual(sent?.httpMethod, "HEAD")
    }

    private func makeHTTPResponse(statusCode: Int, headers: [String: String]) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://example.com")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: headers
        )!
    }
}

private actor StubTransport: HTTPTransporting {
    let result: Result<(Data, HTTPURLResponse), Error>
    private(set) var capturedRequest: URLRequest?
    private(set) var invocationCount = 0

    init(result: Result<(Data, HTTPURLResponse), Error>) {
        self.result = result
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        invocationCount += 1
        capturedRequest = request
        return try result.get()
    }
}

private enum FixedDateSource {
    static func dates(_ dates: [Date]) -> () -> Date {
        let storage = LockedDates(dates)
        return {
            storage.next()
        }
    }
}

private final class LockedDates: @unchecked Sendable {
    private let lock = NSLock()
    private var dates: [Date]

    init(_ dates: [Date]) {
        self.dates = dates
    }

    func next() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return dates.removeFirst()
    }
}
