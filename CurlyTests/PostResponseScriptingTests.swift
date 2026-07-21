import XCTest
@testable import Curly

final class PostResponseScriptingTests: XCTestCase {
    private let runner = QuickJSPostResponseScriptRunner()
    private let requestID = UUID(uuidString: "00000000-0000-0000-0000-000000000123")!

    func testValidationAcceptsValidSourceAndReportsSyntaxLocation() async {
        let validResult = await runner.validate(source: "const value = 1;")
        XCTAssertEqual(validResult, .valid)

        guard case .invalid(let diagnostic) = await runner.validate(source: "const = ;") else {
            return XCTFail("Expected invalid syntax")
        }
        XCTAssertFalse(diagnostic.message.isEmpty)
        XCTAssertNotNil(diagnostic.line)
    }

    func testResponseAPIAndVariableReadsStageStringWrites() async {
        let input = makeInput(
            body: #"{"token":"abc"}"#,
            statusCode: 201,
            headers: [ResponseHeader(name: "X-Request-ID", value: "request-42")],
            variables: [
                Variable(name: "base", value: "before", scope: .global),
                Variable(name: "local", value: "request-value", scope: .request, requestID: requestID),
                Variable(name: "other", value: "hidden", scope: .request, requestID: UUID())
            ],
            source: """
            const json = curly.response.json();
            curly.variables.global.set("token", json.token);
            curly.variables.request.set("summary", [
              curly.response.status,
              curly.response.ok,
              curly.response.header("x-request-id"),
              curly.variables.get("base"),
              curly.variables.request.get("local"),
              String(curly.variables.request.get("other")),
              curly.response.text() === curly.response.text()
            ].join("|"));
            """
        )

        let result = await runner.run(input)

        XCTAssertEqual(result.outcome, .passed)
        XCTAssertNil(result.diagnostic)
        XCTAssertEqual(result.writes, [
            ScriptVariableWrite(scope: .global, name: "token", value: "abc"),
            ScriptVariableWrite(scope: .request, name: "summary", value: "201|true|request-42|before|request-value|null|true")
        ])
    }

    func testNestedJSONValuesCanBeStoredWithoutManualStringConversion() async {
        let result = await runner.run(makeInput(
            body: #"{"result":{"items":[{"profile":{"id":42,"active":true,"name":"Alice"}}]}}"#,
            source: """
            const profile = curly.response.json().result.items[0].profile;
            curly.variables.global.set("user_id", profile.id);
            curly.variables.global.set("active", profile.active);
            curly.variables.global.set("name", profile.name);
            if (curly.variables.global.get("user_id") !== "42") throw new Error("staged number was not stored as a string");
            if (curly.variables.global.get("active") !== "true") throw new Error("staged boolean was not stored as a string");
            """
        ))

        XCTAssertEqual(result.outcome, .passed)
        XCTAssertEqual(result.writes, [
            ScriptVariableWrite(scope: .global, name: "user_id", value: "42"),
            ScriptVariableWrite(scope: .global, name: "active", value: "true"),
            ScriptVariableWrite(scope: .global, name: "name", value: "Alice")
        ])
    }

    func testStagedWriteIsVisibleToLaterReadsAndLastWriteWins() async {
        let result = await runner.run(makeInput(source: """
            curly.variables.global.set("token", "first");
            curly.variables.global.set("token", curly.variables.global.get("token") + "-second");
            """))

        XCTAssertEqual(result.outcome, .passed)
        XCTAssertEqual(result.writes, [ScriptVariableWrite(scope: .global, name: "token", value: "first-second")])
    }

    func testSameNameCannotBeStagedAcrossScopes() async {
        let result = await runner.run(makeInput(source: """
            curly.variables.global.set("token", "global");
            curly.variables.request.set("token", "request");
            """))

        XCTAssertEqual(result.outcome, .failed)
        XCTAssertTrue(result.writes.isEmpty)
        XCTAssertTrue(result.diagnostic?.message.contains("another scope") == true)
    }

    func testRuntimeFailureReturnsNoWrites() async {
        let result = await runner.run(makeInput(source: """
            curly.variables.global.set("mustNotCommit", "value");
            throw new Error("boom");
            """))

        XCTAssertEqual(result.outcome, .failed)
        XCTAssertTrue(result.writes.isEmpty)
        XCTAssertTrue(result.diagnostic?.message.contains("boom") == true)
        XCTAssertNotNil(result.diagnostic?.line)
    }

    func testPrimitiveThrownValuesProduceUsefulDiagnostics() async {
        for (source, expected) in [
            (#"throw "boom";"#, "boom"),
            ("throw 42;", "42"),
            ("throw null;", "null")
        ] {
            let result = await runner.run(makeInput(source: source))
            XCTAssertEqual(result.outcome, .failed)
            XCTAssertEqual(result.diagnostic?.message, expected)
        }
    }

    func testDuplicateInputVariablesUseNewestValueLikeRequestInterpolation() async {
        let older = Variable(
            name: "token",
            value: "old",
            scope: .global,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let newer = Variable(
            name: "token",
            value: "new",
            scope: .global,
            createdAt: Date(timeIntervalSince1970: 2),
            updatedAt: Date(timeIntervalSince1970: 2)
        )
        let result = await runner.run(makeInput(
            variables: [older, newer],
            source: #"curly.variables.global.set("observed", curly.variables.get("token"));"#
        ))

        XCTAssertEqual(result.outcome, .passed)
        XCTAssertEqual(result.writes, [
            ScriptVariableWrite(scope: .global, name: "observed", value: "new")
        ])
    }

    func testOversizedJSONBodyIsRejectedBeforeRuntimeAllocation() async {
        let body = "{\"padding\":\"" + String(repeating: "x", count: 8 * 1_024 * 1_024) + "\"}"

        let result = await runner.run(makeInput(body: body, source: "curly.response.json();"))

        XCTAssertEqual(result.outcome, .failed)
        XCTAssertTrue(result.writes.isEmpty)
        XCTAssertTrue(result.diagnostic?.message.contains("8 MiB") == true)
        XCTAssertEqual(CQJSLiveRuntimeCount(), 0)
    }

    func testComplexValuesMissingArgumentsAndInvalidVariableNamesAreRejected() async {
        for source in [
            "curly.variables.global.set(\"token\", [1, 2]);",
            "curly.variables.global.set(\"token\", { value: 1 });",
            "curly.variables.global.set(\"token\", null);",
            "curly.variables.global.set(\"token\", undefined);"
        ] {
            let complexValue = await runner.run(makeInput(source: source))
            XCTAssertEqual(complexValue.outcome, .failed)
            XCTAssertTrue(complexValue.writes.isEmpty)
            XCTAssertTrue(complexValue.diagnostic?.message.contains("string, number, or boolean") == true)
        }

        let missingValue = await runner.run(makeInput(source: "curly.variables.global.set(\"token\");"))
        XCTAssertEqual(missingValue.outcome, .failed)
        XCTAssertTrue(missingValue.writes.isEmpty)
        XCTAssertTrue(missingValue.diagnostic?.message.contains("set(name, value)") == true)

        let invalidName = await runner.run(makeInput(source: "curly.variables.global.set(\"not valid\", \"x\");"))
        XCTAssertEqual(invalidName.outcome, .failed)
        XCTAssertTrue(invalidName.writes.isEmpty)
        XCTAssertTrue(invalidName.diagnostic?.message.contains("Invalid variable name") == true)
    }

    func testMissingAndInvalidResponseDataHaveDefinedBehavior() async {
        let missing = await runner.run(makeInput(source: """
            if (curly.variables.get("missing") !== null) throw new Error("missing was not null");
            if (curly.response.header("missing") !== null) throw new Error("header was not null");
            """))
        XCTAssertEqual(missing.outcome, .passed)

        let invalidJSON = await runner.run(makeInput(body: "not-json", source: "curly.response.json();"))
        XCTAssertEqual(invalidJSON.outcome, .failed)
        XCTAssertTrue(invalidJSON.writes.isEmpty)

        var binary = makeInput(source: "curly.response.text();")
        binary.response.bodyData = Data([0xC3, 0x28])
        let invalidUTF8 = await runner.run(binary)
        XCTAssertEqual(invalidUTF8.outcome, .failed)
        XCTAssertTrue(invalidUTF8.diagnostic?.message.contains("UTF-8") == true)
    }

    func testSmallJSONBodyWithoutHeadersOrVariablesHasStableStorage() async {
        let result = await runner.run(makeInput(
            body: #"{"token":"next"}"#,
            source: """
            console.log(curly.response.text());
            curly.variables.global.set("token", curly.response.json().token);
            """
        ))
        XCTAssertEqual(result.outcome, .passed, result.diagnostic?.message ?? "No diagnostic")
        XCTAssertEqual(result.writes, [ScriptVariableWrite(scope: .global, name: "token", value: "next")])
    }

    func testConsoleCapturesLevelsAndBoundsOutput() async {
        let result = await runner.run(makeInput(source: """
            console.log("value", { nested: [1, true, null] });
            console.warn("warning");
            console.error("error");
            for (let i = 0; i < 60; i++) console.log(i);
            """))

        XCTAssertEqual(result.outcome, .passed)
        XCTAssertEqual(result.logs.first?.level, .info)
        XCTAssertTrue(result.logs.first?.text.contains("nested") == true)
        XCTAssertEqual(result.logs.dropFirst().first?.level, .warning)
        XCTAssertEqual(result.logs.dropFirst(2).first?.level, .error)
        XCTAssertEqual(result.logs.count, 50)
        XCTAssertTrue(result.logsWereTruncated)
        XCTAssertTrue(result.logs.allSatisfy { $0.text.utf8.count <= 2_048 })
    }

    func testUnsupportedAsyncAndHostGlobalsAreAbsentWhileEvalRemainsAvailable() async {
        let result = await runner.run(makeInput(source: """
            const absent = [typeof Promise, typeof fetch, typeof XMLHttpRequest, typeof require, typeof process];
            if (absent.some(value => value !== "undefined")) throw new Error(absent.join(","));
            if (eval("1 + 2") !== 3) throw new Error("eval unavailable");
            """))
        XCTAssertEqual(result.outcome, .passed)
    }

    func testSourceAndValueLimitsAreEnforced() async {
        let oversizedSource = String(repeating: " ", count: 65_537)
        guard case .invalid(let diagnostic) = await runner.validate(source: oversizedSource) else {
            return XCTFail("Expected oversized source to be invalid")
        }
        XCTAssertTrue(diagnostic.message.contains("64 KiB"))

        let result = await runner.run(makeInput(source: "curly.variables.global.set(\"large\", \"x\".repeat(65537));"))
        XCTAssertEqual(result.outcome, .failed)
        XCTAssertTrue(result.writes.isEmpty)
        XCTAssertTrue(result.diagnostic?.message.contains("64 KiB") == true)
    }

    func testInfiniteLoopTimesOutAndReleasesRuntime() async {
        XCTAssertEqual(CQJSLiveRuntimeCount(), 0)
        let result = await runner.run(makeInput(source: "while (true) {}"))
        XCTAssertEqual(result.outcome, .timedOut)
        XCTAssertTrue(result.writes.isEmpty)
        XCTAssertLessThan(result.durationMs, 2_500)
        XCTAssertEqual(CQJSLiveRuntimeCount(), 0)
    }

    func testHeapAndStackLimitsFailSafelyAndReleaseRuntime() async {
        XCTAssertEqual(CQJSLiveRuntimeCount(), 0)
        let heapResult = await runner.run(makeInput(source: """
            const values = [];
            while (true) values.push("x".repeat(4096));
            """))
        XCTAssertEqual(heapResult.outcome, .failed)
        XCTAssertTrue(heapResult.writes.isEmpty)
        XCTAssertEqual(CQJSLiveRuntimeCount(), 0)

        let stackResult = await runner.run(makeInput(source: """
            function recurse() { return recurse(); }
            recurse();
            """))
        XCTAssertEqual(stackResult.outcome, .failed)
        XCTAssertTrue(stackResult.writes.isEmpty)
        XCTAssertEqual(CQJSLiveRuntimeCount(), 0)
    }

    func testTaskCancellationInterruptsExecutionAndReleasesRuntime() async {
        XCTAssertEqual(CQJSLiveRuntimeCount(), 0)
        let runner = self.runner
        let input = makeInput(source: "while (true) {}")
        let task = Task { await runner.run(input) }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result.outcome, .cancelled)
        XCTAssertTrue(result.writes.isEmpty)
        XCTAssertEqual(CQJSLiveRuntimeCount(), 0)
    }

    private func makeInput(
        body: String = #"{"value":1}"#,
        statusCode: Int = 200,
        headers: [ResponseHeader] = [],
        variables: [Variable] = [],
        source: String
    ) -> PostResponseScriptInput {
        PostResponseScriptInput(
            response: ExecutedResponse(
                request: Request(method: .get, urlString: "https://example.com", headers: [], body: .none),
                statusCode: statusCode,
                headers: headers,
                bodyData: Data(body.utf8),
                mimeType: "application/json",
                duration: 0.125,
                timestamp: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            variables: variables,
            currentRequestID: requestID,
            source: source
        )
    }
}
