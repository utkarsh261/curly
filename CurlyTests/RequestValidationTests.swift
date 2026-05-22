import XCTest
@testable import Curly

final class RequestValidationTests: XCTestCase {
    func testRequiresHTTPOrHTTPSAbsoluteURL() {
        XCTAssertFalse(Request(method: .get, urlString: "foo", headers: [], body: .none).isMinimallyValid)
        XCTAssertFalse(Request(method: .get, urlString: "localhost:3000", headers: [], body: .none).isMinimallyValid)
        XCTAssertFalse(Request(method: .get, urlString: "http://", headers: [], body: .none).isMinimallyValid)
        XCTAssertTrue(Request(method: .get, urlString: "https://example.com", headers: [], body: .none).isMinimallyValid)
        XCTAssertTrue(Request(method: .head, urlString: "https://example.com", headers: [], body: .none).isMinimallyValid)
        XCTAssertTrue(Request(method: .options, urlString: "https://example.com", headers: [], body: .none).isMinimallyValid)
        XCTAssertTrue(Request(method: .get, urlString: "http://localhost:3000", headers: [], body: .none).isMinimallyValid)
    }

    func testSkipsEnabledHeadersWithoutNames() {
        let request = Request(
            method: .get,
            urlString: "https://example.com",
            headers: [Header(name: "", value: "token", isEnabled: true)],
            body: .none
        )

        XCTAssertTrue(request.isMinimallyValid)
        XCTAssertNil(request.lightweightValidationMessage)
    }

    func testLightweightValidationMessageExplainsCurrentEditingIssue() {
        XCTAssertEqual(
            Request(method: .get, urlString: "localhost:3000", headers: [], body: .none).lightweightValidationMessage,
            "Use an absolute http or https URL."
        )
    }
}
