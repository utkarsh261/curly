import XCTest
@testable import NativeCurlRunner

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

    func testRejectsEnabledHeadersWithoutNames() {
        let invalid = Request(
            method: .get,
            urlString: "https://example.com",
            headers: [Header(name: "", value: "token", isEnabled: true)],
            body: .none
        )
        let validDisabled = Request(
            method: .get,
            urlString: "https://example.com",
            headers: [Header(name: "", value: "token", isEnabled: false)],
            body: .none
        )

        XCTAssertFalse(invalid.isMinimallyValid)
        XCTAssertTrue(validDisabled.isMinimallyValid)
    }

    func testLightweightValidationMessageExplainsCurrentEditingIssue() {
        XCTAssertEqual(
            Request(method: .get, urlString: "localhost:3000", headers: [], body: .none).lightweightValidationMessage,
            "Use an absolute http or https URL."
        )
        XCTAssertEqual(
            Request(
                method: .get,
                urlString: "https://example.com",
                headers: [Header(name: "", value: "token", isEnabled: true)],
                body: .none
            ).lightweightValidationMessage,
            "Enabled header rows need a header name."
        )
    }
}
