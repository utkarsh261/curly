import XCTest
@testable import Curly

final class ResponseFormatterTests: XCTestCase {
    private let formatter = DefaultResponseFormatter()

    func testFormatsJSONResponseIntoTreeMode() async {
        let response = makeResponse(
            statusCode: 200,
            headers: [ResponseHeader(name: "Content-Type", value: "application/json")],
            body: Data("{\"user\":{\"name\":\"utk\"},\"items\":[1,2]}".utf8),
            mimeType: "application/json"
        )

        let formatted = await formatter.format(response)

        XCTAssertEqual(formatted.selectedMode, .tree)
        XCTAssertEqual(formatted.summary.tone, .success)
        XCTAssertNotNil(formatted.body.jsonValue)
        XCTAssertTrue(formatted.body.isPreviewable)
        if case let .object(pairs)? = formatted.body.jsonValue {
            XCTAssertEqual(Set(pairs.map(\.0)), Set(["user", "items"]))
        } else {
            XCTFail("Expected JSON object")
        }
    }

    func testFormatsRawTextWithHeadersIncluded() async {
        let response = makeResponse(
            statusCode: 404,
            headers: [ResponseHeader(name: "Content-Type", value: "text/plain"), ResponseHeader(name: "X-Trace", value: "abc123")],
            body: Data("missing".utf8),
            mimeType: "text/plain"
        )

        let formatted = await formatter.format(response)

        XCTAssertEqual(formatted.selectedMode, .raw)
        XCTAssertEqual(formatted.summary.tone, .warning)
        XCTAssertEqual(formatted.body.headerText, "Content-Type: text/plain\nX-Trace: abc123")
        XCTAssertEqual(formatted.body.bodyText, "missing")
    }

    func testFormatsJSONServerErrorIntoTreeMode() async {
        let response = makeResponse(
            statusCode: 500,
            headers: [ResponseHeader(name: "Content-Type", value: "application/problem+json")],
            body: Data("{\"error\":{\"code\":\"internal_error\"}}".utf8),
            mimeType: "application/problem+json"
        )

        let formatted = await formatter.format(response)

        XCTAssertEqual(formatted.selectedMode, .tree)
        XCTAssertEqual(formatted.summary.tone, .failure)
        XCTAssertNotNil(formatted.body.jsonValue)
    }

    func testFormatsBinaryResponseAsNonPreviewable() async {
        let response = makeResponse(
            statusCode: 500,
            headers: [ResponseHeader(name: "Content-Type", value: "application/octet-stream")],
            body: Data([0xFF, 0xD8, 0x00, 0x01]),
            mimeType: "application/octet-stream"
        )

        let formatted = await formatter.format(response)

        XCTAssertFalse(formatted.body.isPreviewable)
        XCTAssertNil(formatted.body.jsonValue)
        XCTAssertEqual(formatted.summary.tone, .failure)
        XCTAssertTrue(formatted.body.bodyText.contains("Binary response body"))
    }

    private func makeResponse(
        statusCode: Int,
        headers: [ResponseHeader],
        body: Data,
        mimeType: String?
    ) -> ExecutedResponse {
        ExecutedResponse(
            request: Request(method: .get, urlString: "https://example.com/users", headers: [], body: .none),
            statusCode: statusCode,
            headers: headers,
            bodyData: body,
            mimeType: mimeType,
            duration: 0.123,
            timestamp: Date(timeIntervalSince1970: 100)
        )
    }
}
