import XCTest
@testable import Curly

final class SimpleCurlImporterTests: XCTestCase {
    private let importer = SimpleCurlImporter()

    func testParsesURLOnlyCurl() throws {
        let result = try importer.parse("curl https://example.com")
        let request = result.request

        XCTAssertEqual(request.method, .get)
        XCTAssertEqual(request.urlString, "https://example.com")
        XCTAssertEqual(request.headers, [])
        XCTAssertEqual(request.body, .none)
        XCTAssertEqual(result.warnings, [])
        XCTAssertEqual(result.sourceCurl, "curl https://example.com")
    }

    func testParsesMultilineCurlWithBackslashContinuations() throws {
        let request = try importer.parse(
            """
            curl -X POST https://example.com \\
                 -H "Content-Type: application/json" \\
                 -d '{"name": "John Doe", "email": "john@example.com"}'
            """
        ).request

        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.urlString, "https://example.com")
        XCTAssertEqual(request.headers.map(\.name), ["Content-Type"])
        XCTAssertEqual(request.headers.map(\.value), ["application/json"])
        XCTAssertEqual(request.body, .text("{\"name\": \"John Doe\", \"email\": \"john@example.com\"}"))
    }

    func testParsesMultilineCurlWithWhitespaceAfterBackslashContinuations() throws {
        let request = try importer.parse("curl -X PUT http://localhost:9999/put \\  \n  -H \"Content-Type: text/plain\" \\ \n  -d \"some raw text body\"").request

        XCTAssertEqual(request.method, .put)
        XCTAssertEqual(request.urlString, "http://localhost:9999/put")
        XCTAssertEqual(request.headers.map(\.name), ["Content-Type"])
        XCTAssertEqual(request.headers.map(\.value), ["text/plain"])
        XCTAssertEqual(request.body, .text("some raw text body"))
    }

    func testInfersPostWhenBodyExistsWithoutExplicitMethod() throws {
        let request = try importer.parse("curl https://example.com --data '{\"name\":\"utk\"}'").request

        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.body, .text("{\"name\":\"utk\"}"))
        XCTAssertEqual(request.headers.map(\.name), ["Content-Type"])
        XCTAssertEqual(request.headers.map(\.value), ["application/x-www-form-urlencoded"])
    }

    func testParsesExplicitMethod() throws {
        let request = try importer.parse("curl https://example.com --request PATCH").request

        XCTAssertEqual(request.method, .patch)
    }

    func testParsesOptionsMethod() throws {
        let request = try importer.parse("curl -X OPTIONS https://example.com/anything").request

        XCTAssertEqual(request.method, .options)
    }

    func testPreservesRepeatedHeaderOrder() throws {
        let request = try importer.parse("curl https://example.com -H 'X-One: 1' -H 'X-Two: 2'").request

        XCTAssertEqual(request.headers.map(\.name), ["X-One", "X-Two"])
        XCTAssertEqual(request.headers.map(\.value), ["1", "2"])
    }

    func testImportsMultipartFormAsUsableRequestWithWarning() throws {
        let result = try importer.parse("curl https://example.com -F 'file=@demo.txt'")

        XCTAssertEqual(result.request.method, .post)
        XCTAssertEqual(result.request.urlString, "https://example.com")
        XCTAssertEqual(result.request.body, .none)
        XCTAssertEqual(result.warnings, ["Multipart form data is not represented yet."])
    }

    func testRejectsMalformedHeader() {
        XCTAssertThrowsError(try importer.parse("curl https://example.com -H 'Authorization'")) { error in
            XCTAssertEqual(error as? CurlImportError, .malformedInput("Header 'Authorization' is missing ':'."))
        }
    }

    func testParsesHeadFlag() throws {
        let request = try importer.parse("curl -I https://example.com").request

        XCTAssertEqual(request.method, .head)
        XCTAssertEqual(request.urlString, "https://example.com")
    }

    func testParsesLongFlagEqualsValues() throws {
        let request = try importer.parse("curl --request=PUT --url=https://example.com/users --header='Accept: application/json'").request

        XCTAssertEqual(request.method, .put)
        XCTAssertEqual(request.urlString, "https://example.com/users")
        XCTAssertEqual(request.headers.map(\.name), ["Accept"])
        XCTAssertEqual(request.headers.map(\.value), ["application/json"])
    }

    func testParsesAttachedShortFlagValues() throws {
        let request = try importer.parse("curl -XPOST -HAccept:application/json -d'{\"ok\":true}' https://example.com").request

        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.headers.map(\.name), ["Accept", "Content-Type"])
        XCTAssertEqual(request.headers.map(\.value), ["application/json", "application/x-www-form-urlencoded"])
        XCTAssertEqual(request.body, .text("{\"ok\":true}"))
    }

    func testLocationImportsWithWarning() throws {
        let result = try importer.parse("curl --location https://example.com")

        XCTAssertEqual(result.request.urlString, "https://example.com")
        XCTAssertEqual(result.warnings, ["Redirect-following from `--location` is not represented yet."])
    }

    func testCompressedDoesNotWarn() throws {
        let result = try importer.parse("curl --compressed https://example.com")

        XCTAssertEqual(result.request.urlString, "https://example.com")
        XCTAssertEqual(result.warnings, [])
    }

    func testTerminalDisplayFlagsWarn() throws {
        let result = try importer.parse("curl -v -i -s --fail https://example.com")

        XCTAssertEqual(result.request.urlString, "https://example.com")
        XCTAssertEqual(
            result.warnings,
            [
                "Ignored terminal output flag `-v`.",
                "Ignored terminal output flag `-i`.",
                "Ignored terminal output flag `-s`.",
                "Ignored terminal failure handling flag."
            ]
        )
    }

    func testBasicAuthConvertsToAuthorizationHeader() throws {
        let request = try importer.parse("curl -u user:pass https://example.com").request

        XCTAssertEqual(request.headers.map(\.name), ["Authorization"])
        XCTAssertEqual(request.headers.map(\.value), ["Basic dXNlcjpwYXNz"])
    }

    func testCookieConvertsToHeader() throws {
        let request = try importer.parse("curl -b 'a=1; b=2' https://example.com").request

        XCTAssertEqual(request.headers.map(\.name), ["Cookie"])
        XCTAssertEqual(request.headers.map(\.value), ["a=1; b=2"])
    }

    func testCookieFileWarnsAndDoesNotBecomeURL() throws {
        let result = try importer.parse("curl -b /tmp/cookies.txt https://example.com/cookies")

        XCTAssertEqual(result.request.urlString, "https://example.com/cookies")
        XCTAssertEqual(result.request.headers, [])
        XCTAssertEqual(result.warnings, ["Cookie files are not represented yet."])
    }

    func testCookieJarFlagConsumesValueAndWarns() throws {
        let result = try importer.parse("curl -c /tmp/cookies.txt https://example.com/cookies/set?session=abc")

        XCTAssertEqual(result.request.urlString, "https://example.com/cookies/set?session=abc")
        XCTAssertEqual(result.warnings, ["Cookie jar files are not represented yet."])
    }

    func testWriteOutFlagConsumesValueAndWarns() throws {
        let result = try importer.parse("curl -w '\\nHTTP %{http_code}\\n' https://example.com/status/418")

        XCTAssertEqual(result.request.urlString, "https://example.com/status/418")
        XCTAssertEqual(result.warnings, ["Ignored terminal write-out flag."])
    }

    func testFileBackedBodyWarnsAndLeavesBodyEmpty() throws {
        let result = try importer.parse("curl https://example.com -d @body.json")

        XCTAssertEqual(result.request.body, .none)
        XCTAssertEqual(result.warnings, ["File-backed request bodies are not represented yet."])
    }

    func testRejectsShellVariables() {
        XCTAssertThrowsError(try importer.parse("curl https://example.com -H \"Authorization: Bearer $TOKEN\"")) { error in
            XCTAssertEqual(error as? CurlImportError, .unsupportedSyntax("Shell variables and command substitution are not supported in cURL import yet."))
        }
    }

    func testJsonFlagAddsJSONHeadersAndBody() throws {
        let request = try importer.parse("curl --json '{\"ok\":true}' https://example.com").request

        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.headers.map(\.name), ["Content-Type", "Accept"])
        XCTAssertEqual(request.headers.map(\.value), ["application/json", "application/json"])
        XCTAssertEqual(request.body, .text("{\"ok\":true}"))
    }
}
