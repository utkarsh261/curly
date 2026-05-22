import XCTest
@testable import Curly

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

    func testJSONContentTypeStripsCommentsBeforeSendingBody() async throws {
        let transport = StubTransport(
            result: .success(
                (
                    Data("{\"ok\":true}".utf8),
                    makeHTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"])
                )
            )
        )
        let executor = URLSessionRequestExecutor(transport: transport)
        let request = Request(
            method: .post,
            urlString: "https://example.com/users",
            headers: [Header(name: "Content-Type", value: "application/json")],
            body: .text(
                """
                {
                  // local note
                  "name": "utk"
                }
                """
            )
        )

        _ = try await executor.execute(request)

        let sent = await transport.capturedRequest
        XCTAssertEqual(
            String(data: sent?.httpBody ?? Data(), encoding: .utf8),
            """
            {
              
              "name": "utk"
            }
            """
        )
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

    func testDocumentedLocalServerCurlExamplesImportRunAndRender() async throws {
        let server = try await LocalHTTPTestServer.start()
        defer { server.stop() }

        let importer = SimpleCurlImporter()
        let executor = URLSessionRequestExecutor()
        let formatter = DefaultResponseFormatter()

        let examples: [LocalServerCurlExample] = [
            LocalServerCurlExample(
                name: "GET with query params",
                curl: #"curl "http://localhost:9999/get?name=alice&age=30&active=true""#,
                expectedStatus: 200,
                expectedFragments: [#""method" : "GET""#, #""name" : "alice""#, #""age" : "30""#]
            ),
            LocalServerCurlExample(
                name: "POST with JSON body",
                curl: """
                curl -X POST http://localhost:9999/post \\
                  -H "Content-Type: application/json" \\
                  -d '{"title": "hello", "count": 42}'
                """,
                expectedStatus: 200,
                expectedFragments: [#""method" : "POST""#, #""title" : "hello""#, #""count" : 42"#]
            ),
            LocalServerCurlExample(
                name: "POST form urlencoded",
                curl: #"curl -d "username=jane&password=secret123" http://localhost:9999/form"#,
                expectedStatus: 200,
                expectedFragments: [#""method" : "POST""#, #""username" : "jane""#, #""password" : "secret123""#]
            ),
            LocalServerCurlExample(
                name: "PUT with raw text body",
                curl: """
                curl -X PUT http://localhost:9999/put \\
                  -H "Content-Type: text/plain" \\
                  -d "some raw text body"
                """,
                expectedStatus: 200,
                expectedFragments: [#""method" : "PUT""#, #""data" : "some raw text body""#, #""Content-Type" : "text\/plain""#]
            ),
            LocalServerCurlExample(
                name: "DELETE",
                curl: #"curl -X DELETE http://localhost:9999/delete"#,
                expectedStatus: 200,
                expectedFragments: [#""method" : "DELETE""#, #""path" : "\/delete""#]
            ),
            LocalServerCurlExample(
                name: "PATCH with JSON body",
                curl: """
                curl -X PATCH http://localhost:9999/patch \\
                  -H "Content-Type: application/json" \\
                  -d '{"status": "updated"}'
                """,
                expectedStatus: 200,
                expectedFragments: [#""method" : "PATCH""#, #""status" : "updated""#]
            ),
            LocalServerCurlExample(
                name: "Custom headers",
                curl: """
                curl -H "Authorization: Bearer my-token" \\
                  -H "X-Custom-Header: value" \\
                  http://localhost:9999/headers
                """,
                expectedStatus: 200,
                expectedFragments: [#""Authorization" : "Bearer my-token""#, #""X-Custom-Header" : "value""#]
            ),
            LocalServerCurlExample(
                name: "Basic auth",
                curl: #"curl -u admin:secret http://localhost:9999/basic-auth/admin/secret"#,
                expectedStatus: 200,
                expectedFragments: [#""authenticated" : true"#, #""user" : "admin""#]
            ),
            LocalServerCurlExample(
                name: "Bearer token auth",
                curl: #"curl -H "Authorization: Bearer my-secret-token" http://localhost:9999/bearer"#,
                expectedStatus: 200,
                expectedFragments: [#""authenticated" : true"#, #""token" : "my-secret-token""#]
            ),
            LocalServerCurlExample(
                name: "API key",
                curl: #"curl "http://localhost:9999/api-key?key=secret123""#,
                expectedStatus: 200,
                expectedFragments: [#""authenticated" : true"#, #""key" : "secret123""#]
            ),
            LocalServerCurlExample(
                name: "Follow redirects",
                curl: #"curl -L http://localhost:9999/redirect/3"#,
                expectedStatus: 200,
                expectedFragments: [#""method" : "GET""#, #""path" : "\/get""#],
                expectedWarnings: ["Redirect-following from `--location` is not represented yet."]
            ),
            LocalServerCurlExample(
                name: "File upload warning",
                curl: #"curl -F "file=@test_server.py" http://localhost:9999/upload"#,
                expectedStatus: 200,
                expectedFragments: [#""method" : "POST""#, #""path" : "\/upload""#],
                expectedWarnings: ["Multipart form data is not represented yet."]
            ),
            LocalServerCurlExample(
                name: "Cookie jar warning",
                curl: #"curl -c /tmp/cookies.txt http://localhost:9999/cookies/set?session=abc"#,
                expectedStatus: 200,
                expectedFragments: [#""session" : "abc""#],
                expectedWarnings: ["Cookie jar files are not represented yet."]
            ),
            LocalServerCurlExample(
                name: "Cookie file warning",
                curl: #"curl -b /tmp/cookies.txt http://localhost:9999/cookies"#,
                expectedStatus: 200,
                expectedFragments: [#""cookies" : {"#],
                expectedWarnings: ["Cookie files are not represented yet."]
            ),
            LocalServerCurlExample(
                name: "Custom status with write-out warning",
                curl: #"curl -w "\nHTTP %{http_code}\n" http://localhost:9999/status/418"#,
                expectedStatus: 418,
                expectedFragments: [#""code" : 418"#, #""method" : "GET""#],
                expectedWarnings: ["Ignored terminal write-out flag."]
            ),
            LocalServerCurlExample(
                name: "Timeout flag warning",
                curl: #"curl --max-time 1 http://localhost:9999/delay/5"#,
                expectedStatus: 200,
                expectedFragments: [#""delayed" : 5"#],
                expectedWarnings: ["Request timing/retry options are not represented yet."]
            ),
            LocalServerCurlExample(
                name: "Response headers with include warning",
                curl: #"curl -i http://localhost:9999/response-headers?X-Custom=hello"#,
                expectedStatus: 200,
                expectedFragments: [#""X-Custom" : "hello""#],
                expectedWarnings: ["Ignored terminal output flag `-i`."]
            ),
            LocalServerCurlExample(
                name: "Stream",
                curl: #"curl http://localhost:9999/stream/5"#,
                expectedStatus: 200,
                expectedFragments: [#""id": 4"#, "line 5"]
            ),
            LocalServerCurlExample(
                name: "Complex JSON",
                curl: #"curl http://localhost:9999/json/complex"#,
                expectedStatus: 200,
                expectedFragments: ["Complex JSON Test Payload", "array_of_objects", "deeply nested at depth 5"]
            ),
            LocalServerCurlExample(
                name: "OPTIONS",
                curl: #"curl -X OPTIONS http://localhost:9999/anything"#,
                expectedStatus: 200,
                expectedFragments: [#""method" : "OPTIONS""#, #""path" : "\/anything""#]
            )
        ]

        for example in examples {
            let importResult = try importer.parse(example.curl)
            XCTAssertEqual(importResult.warnings, example.expectedWarnings, example.name)
            XCTAssertTrue(importResult.request.isMinimallyValid, example.name)

            let response = try await executor.execute(importResult.request)
            XCTAssertEqual(response.statusCode, example.expectedStatus, example.name)

            let rendered = await formatter.format(response)
            let renderedText = rendered.body.headerText + "\n" + rendered.body.bodyText
            for fragment in example.expectedFragments {
                XCTAssertTrue(
                    renderedText.contains(fragment),
                    "\(example.name) response did not contain expected fragment \(fragment).\nResponse:\n\(renderedText)"
                )
            }
        }
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

private struct LocalServerCurlExample {
    var name: String
    var curl: String
    var expectedStatus: Int
    var expectedFragments: [String]
    var expectedWarnings: [String] = []
}

private final class LocalHTTPTestServer {
    private let process: Process?

    private init(process: Process?) {
        self.process = process
    }

    static func start() async throws -> LocalHTTPTestServer {
        if await isReachable() {
            return LocalHTTPTestServer(process: nil)
        }

        let scriptURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("test_server.py")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [scriptURL.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if await isReachable() {
                return LocalHTTPTestServer(process: process)
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        process.terminate()
        throw XCTSkip("Local test server did not become reachable on http://localhost:9999.")
    }

    func stop() {
        guard let process, process.isRunning else { return }
        process.terminate()
    }

    private static func isReachable() async -> Bool {
        guard let url = URL(string: "http://localhost:9999/json") else {
            return false
        }

        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
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
