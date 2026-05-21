import XCTest
@testable import NativeCurlRunner

final class SimpleCurlImporterTests: XCTestCase {
    private let importer = SimpleCurlImporter()

    func testParsesURLOnlyCurl() throws {
        let request = try importer.parse("curl https://example.com")

        XCTAssertEqual(request.method, .get)
        XCTAssertEqual(request.urlString, "https://example.com")
        XCTAssertEqual(request.headers, [])
        XCTAssertEqual(request.body, .none)
    }

    func testParsesMultilineCurlWithBackslashContinuations() throws {
        let request = try importer.parse(
            """
            curl -X POST https://example.com \\
                 -H "Content-Type: application/json" \\
                 -d '{"name": "John Doe", "email": "john@example.com"}'
            """
        )

        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.urlString, "https://example.com")
        XCTAssertEqual(request.headers.map(\.name), ["Content-Type"])
        XCTAssertEqual(request.headers.map(\.value), ["application/json"])
        XCTAssertEqual(request.body, .text("{\"name\": \"John Doe\", \"email\": \"john@example.com\"}"))
    }

    func testInfersPostWhenBodyExistsWithoutExplicitMethod() throws {
        let request = try importer.parse("curl https://example.com --data '{\"name\":\"utk\"}'")

        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.body, .text("{\"name\":\"utk\"}"))
    }

    func testParsesExplicitMethod() throws {
        let request = try importer.parse("curl https://example.com --request PATCH")

        XCTAssertEqual(request.method, .patch)
    }

    func testPreservesRepeatedHeaderOrder() throws {
        let request = try importer.parse("curl https://example.com -H 'X-One: 1' -H 'X-Two: 2'")

        XCTAssertEqual(request.headers.map(\.name), ["X-One", "X-Two"])
        XCTAssertEqual(request.headers.map(\.value), ["1", "2"])
    }

    func testRejectsUnsupportedFlags() {
        XCTAssertThrowsError(try importer.parse("curl https://example.com -F 'file=@demo.txt'")) { error in
            XCTAssertEqual(error as? CurlImportError, .unsupportedSyntax("Flag -F is not supported in v0.1."))
        }
    }

    func testRejectsMalformedHeader() {
        XCTAssertThrowsError(try importer.parse("curl https://example.com -H 'Authorization'")) { error in
            XCTAssertEqual(error as? CurlImportError, .malformedInput("Header 'Authorization' is missing ':'."))
        }
    }
}
