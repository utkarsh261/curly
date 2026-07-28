import XCTest
@testable import Curly

@MainActor
final class SessionCoordinatorTests: XCTestCase {
    func testInitialStateStartsEmptyAndIdle() {
        let coordinator = SessionCoordinator()

        XCTAssertEqual(coordinator.state.workspaceRequest, .empty)
        XCTAssertNil(coordinator.state.lastExecutedRequest)
        XCTAssertEqual(coordinator.state.executionState, .idle)
        XCTAssertNil(coordinator.state.visibleResponseState)
        XCTAssertNil(coordinator.state.replaceConfirmationState)
        XCTAssertNil(coordinator.state.inlineErrorMessage)
        XCTAssertTrue(coordinator.state.isWindowVisible)
    }

    func testNewWorkspaceResetsSessionState() {
        let populatedState = SessionState(
            workspaceRequest: Request(
                method: .post,
                urlString: "https://example.com",
                headers: [Header(name: "Authorization", value: "Bearer token")],
                body: .text("{\"ok\":true}")
            ),
            lastExecutedRequest: LastExecutedRequest(
                request: Request(method: .get, urlString: "https://api.example.com", headers: [], body: .none)
            ),
            executionState: .failed,
            visibleResponseState: VisibleResponseState(
                summary: ResponseSummary(
                    statusCode: 500,
                    durationDescription: "100 ms",
                    sizeDescription: "1 KB",
                    timestampDescription: "now",
                    tone: .failure
                ),
                body: ResponseBody(
                    headerText: "X-Test: 1",
                    bodyText: "oops",
                    isPreviewable: true,
                    rawData: Data("oops".utf8),
                    mimeType: "text/plain",
                    jsonValue: nil,
                    exportFilename: "oops.txt"
                ),
                selectedMode: .raw,
                isStale: true
            ),
            replaceConfirmationState: ReplaceConfirmationState(
                rawInput: "curl https://replacement.example.com",
                candidateRequest: Request(method: .get, urlString: "https://replacement.example.com", headers: [], body: .none)
            ),
            inlineErrorMessage: "something failed",
            isWindowVisible: false
        )

        let coordinator = SessionCoordinator(initialState: populatedState)
        coordinator.newWorkspace()

        XCTAssertEqual(coordinator.state.workspaceRequest, .empty)
        XCTAssertNil(coordinator.state.lastExecutedRequest)
        XCTAssertEqual(coordinator.state.executionState, .idle)
        XCTAssertNil(coordinator.state.visibleResponseState)
        XCTAssertNil(coordinator.state.replaceConfirmationState)
        XCTAssertNil(coordinator.state.inlineErrorMessage)
        XCTAssertFalse(coordinator.state.isWindowVisible)
    }

    func testRequestWindowOpenMarksWindowVisible() {
        let coordinator = SessionCoordinator()
        coordinator.setWindowVisible(false)

        coordinator.requestWindowOpen()

        XCTAssertTrue(coordinator.state.isWindowVisible)
    }

    func testRequestEditorStartsWithHeadersAndBodyExpanded() {
        let coordinator = SessionCoordinator()

        XCTAssertTrue(coordinator.state.requestEditorExpansion.headersExpanded)
        XCTAssertTrue(coordinator.state.requestEditorExpansion.bodyExpanded)
    }

    func testRequestEditorToggleKeepsSectionsIndependent() {
        let coordinator = SessionCoordinator()
        XCTAssertTrue(coordinator.state.requestEditorExpansion.headersExpanded)
        XCTAssertTrue(coordinator.state.requestEditorExpansion.bodyExpanded)

        coordinator.toggleRequestEditorSection(.headers)
        XCTAssertFalse(coordinator.state.requestEditorExpansion.headersExpanded)
        XCTAssertTrue(coordinator.state.requestEditorExpansion.bodyExpanded)

        coordinator.toggleRequestEditorSection(.headers)
        XCTAssertTrue(coordinator.state.requestEditorExpansion.headersExpanded)
        XCTAssertTrue(coordinator.state.requestEditorExpansion.bodyExpanded)

        coordinator.toggleRequestEditorSection(.body)
        XCTAssertTrue(coordinator.state.requestEditorExpansion.headersExpanded)
        XCTAssertFalse(coordinator.state.requestEditorExpansion.bodyExpanded)
    }

    func testNewWorkspaceResetsRequestEditorExpansion() {
        let coordinator = SessionCoordinator()
        coordinator.toggleRequestEditorSection(.body)
        XCTAssertFalse(coordinator.state.requestEditorExpansion.bodyExpanded)

        coordinator.newWorkspace()

        XCTAssertEqual(coordinator.state.requestEditorExpansion, .allExpanded)
    }

    func testEmptyWorkspaceCurlPasteImportsImmediately() {
        let coordinator = SessionCoordinator()

        coordinator.handleURLBarPaste("curl https://example.com -X POST -H 'Accept: application/json' -d '{\"ok\":true}'")

        XCTAssertEqual(coordinator.state.workspaceRequest.method, .post)
        XCTAssertEqual(coordinator.state.workspaceRequest.urlString, "https://example.com")
        XCTAssertEqual(coordinator.state.workspaceRequest.headers.count, 2)
        XCTAssertEqual(coordinator.state.workspaceRequest.headers[0].name, "Accept")
        XCTAssertEqual(coordinator.state.workspaceRequest.headers[0].value, "application/json")
        XCTAssertEqual(coordinator.state.workspaceRequest.headers[1].name, "Content-Type")
        XCTAssertEqual(coordinator.state.workspaceRequest.headers[1].value, "application/x-www-form-urlencoded")
        XCTAssertEqual(coordinator.state.workspaceRequest.body, .text("{\"ok\":true}"))
        XCTAssertNil(coordinator.state.replaceConfirmationState)
        XCTAssertNil(coordinator.state.inlineErrorMessage)
    }

    func testURLBarTextChangeDoesNotParseCurlWhileTyping() {
        let coordinator = SessionCoordinator()

        coordinator.handleURLBarTextChange("curl https://www.example.com")

        XCTAssertEqual(coordinator.state.workspaceRequest.method, .get)
        XCTAssertEqual(coordinator.state.workspaceRequest.urlString, "curl https://www.example.com")
        XCTAssertEqual(coordinator.state.workspaceRequest.headers, [])
        XCTAssertEqual(coordinator.state.workspaceRequest.body, .none)
        XCTAssertNil(coordinator.state.replaceConfirmationState)
        XCTAssertNil(coordinator.state.inlineErrorMessage)
        XCTAssertFalse(coordinator.state.canRun)
    }

    func testURLBarPasteParsesSimpleCurl() {
        let coordinator = SessionCoordinator()

        coordinator.handleURLBarPaste("curl https://www.example.com")

        XCTAssertEqual(coordinator.state.workspaceRequest.urlString, "https://www.example.com")
        XCTAssertNil(coordinator.state.requestIssueMessage)
        XCTAssertTrue(coordinator.state.canRun)
    }

    func testURLBarPasteParsesCurlWhenCurrentURLIsTheTypedCurlDraft() {
        let coordinator = SessionCoordinator()
        coordinator.handleURLBarTextChange("curl https://www.example.com")

        coordinator.handleURLBarPaste("curl https://www.example.com")

        XCTAssertEqual(coordinator.state.workspaceRequest.urlString, "https://www.example.com")
        XCTAssertNil(coordinator.state.replaceConfirmationState)
        XCTAssertNil(coordinator.state.requestIssueMessage)
        XCTAssertTrue(coordinator.state.canRun)
    }

    func testNonEmptyWorkspaceCurlPasteStagesReplacementConfirmation() {
        let coordinator = SessionCoordinator()
        coordinator.setURL("https://current.example.com")

        coordinator.handleURLBarPaste("curl https://replacement.example.com")

        XCTAssertEqual(coordinator.state.workspaceRequest.urlString, "https://current.example.com")
        XCTAssertEqual(coordinator.state.replaceConfirmationState?.candidateRequest.urlString, "https://replacement.example.com")
        XCTAssertNil(coordinator.state.inlineErrorMessage)
    }

    func testNonEmptyWorkspaceCurlPasteStagesReplacementWarnings() {
        let coordinator = SessionCoordinator()
        coordinator.setURL("https://current.example.com")

        coordinator.handleURLBarPaste("curl --location https://replacement.example.com")

        XCTAssertEqual(coordinator.state.workspaceRequest.urlString, "https://current.example.com")
        XCTAssertEqual(coordinator.state.replaceConfirmationState?.candidateRequest.urlString, "https://replacement.example.com")
        XCTAssertEqual(coordinator.state.replaceConfirmationState?.candidateWarnings, ["Redirect-following from `--location` is not represented yet."])
        XCTAssertNil(coordinator.state.requestIssueMessage)
    }

    func testCancelReplacementLeavesWorkspaceUntouched() {
        let coordinator = SessionCoordinator()
        coordinator.setURL("https://current.example.com")

        coordinator.handleURLBarPaste("curl https://replacement.example.com")
        coordinator.cancelWorkspaceReplacement()

        XCTAssertEqual(coordinator.state.workspaceRequest.urlString, "https://current.example.com")
        XCTAssertNil(coordinator.state.replaceConfirmationState)
        XCTAssertNil(coordinator.state.requestIssueMessage)
    }

    func testPlainURLPasteUpdatesWorkspaceURLWithoutStagingReplacement() {
        let coordinator = SessionCoordinator()

        coordinator.handleURLBarPaste("https://example.com/users")

        XCTAssertEqual(coordinator.state.workspaceRequest.urlString, "https://example.com/users")
        XCTAssertNil(coordinator.state.replaceConfirmationState)
    }

    func testConfirmReplacementUpdatesWorkspaceAndMarksVisibleResponseStale() {
        let responseState = VisibleResponseState(
            summary: ResponseSummary(
                statusCode: 200,
                durationDescription: "20 ms",
                sizeDescription: "512 B",
                timestampDescription: "now",
                tone: .success
            ),
            body: ResponseBody(
                headerText: "",
                bodyText: "{\"ok\":true}",
                isPreviewable: true,
                rawData: Data("{\"ok\":true}".utf8),
                mimeType: "application/json",
                jsonValue: .object([("ok", .bool(true))]),
                exportFilename: "response.json"
            ),
            selectedMode: .tree,
            isStale: false
        )
        let initialState = SessionState(
            workspaceRequest: Request(method: .get, urlString: "https://current.example.com", headers: [], body: .none),
            lastExecutedRequest: nil,
            executionState: .idle,
            visibleResponseState: responseState,
            replaceConfirmationState: nil,
            inlineErrorMessage: nil,
            isWindowVisible: true
        )
        let coordinator = SessionCoordinator(initialState: initialState)

        coordinator.handleURLBarPaste("curl https://replacement.example.com -X POST")
        coordinator.confirmWorkspaceReplacement()

        XCTAssertEqual(coordinator.state.workspaceRequest.urlString, "https://replacement.example.com")
        XCTAssertEqual(coordinator.state.workspaceRequest.method, .post)
        XCTAssertNil(coordinator.state.replaceConfirmationState)
        XCTAssertEqual(coordinator.state.visibleResponseState?.isStale, true)
        XCTAssertEqual(coordinator.state.requestEditorExpansion, .allExpanded)
    }

    func testConfirmReplacementAppliesImportWarning() {
        let coordinator = SessionCoordinator()
        coordinator.setURL("https://current.example.com")

        coordinator.handleURLBarPaste("curl --location https://replacement.example.com")
        coordinator.confirmWorkspaceReplacement()

        XCTAssertEqual(coordinator.state.workspaceRequest.urlString, "https://replacement.example.com")
        XCTAssertEqual(coordinator.state.requestIssueSeverity, .warning)
        XCTAssertEqual(coordinator.state.requestIssueMessage, "Redirect-following from `--location` is not represented yet.")
        XCTAssertTrue(coordinator.state.canRun)
    }

    func testCurlImportReplacesOnlyRequestAndPreservesPostResponseScript() {
        let coordinator = SessionCoordinator()
        coordinator.setURL("https://before.example.com")
        coordinator.setPostResponseScriptEnabled(true)
        coordinator.setPostResponseScriptSource("curly.variables.global.set(\"token\", \"kept\");")

        coordinator.handleURLBarPaste("curl https://after.example.com")
        coordinator.confirmWorkspaceReplacement()

        XCTAssertEqual(coordinator.state.workspaceRequest.urlString, "https://after.example.com")
        XCTAssertEqual(
            coordinator.state.requestAutomation.postResponseScript,
            PostResponseScript(isEnabled: true, source: "curly.variables.global.set(\"token\", \"kept\");")
        )
    }

    func testWarningClearsWhenRequestIsEdited() {
        let coordinator = SessionCoordinator()

        coordinator.handleURLBarPaste("curl --location https://example.com")
        XCTAssertEqual(coordinator.state.requestIssueSeverity, .warning)

        coordinator.setURL("https://edited.example.com")

        XCTAssertNil(coordinator.state.requestIssueMessage)
    }

    func testVariableAwareRequestIssueClearsWhenTemplatedURLIsFixed() {
        let coordinator = SessionCoordinator()
        XCTAssertNotNil(coordinator.createVariable(name: "port", value: "9999", scope: .global))
        XCTAssertNotNil(coordinator.createVariable(name: "auth", value: "token", scope: .global))

        coordinator.setURL("http://localhost:{{/post?a={{auth}}")
        XCTAssertNil(coordinator.currentRequestIssueMessage)
        coordinator.runCurrentRequest()
        XCTAssertEqual(
            coordinator.currentRequestIssueMessage,
            "Fix invalid variable syntax. Use {{name}} with no spaces. Invalid: {{/post?a="
        )

        coordinator.setURL("http://localhost:{{port}}/post?a={{auth}}")

        XCTAssertNil(coordinator.currentRequestIssueMessage)
        XCTAssertEqual(
            coordinator.resolveCurrentRequestForRun().resolvedRequest?.urlString,
            "http://localhost:9999/post?a=token"
        )
    }

    func testVariableIssueAppearsOnlyAfterRunAttempt() {
        let coordinator = SessionCoordinator()
        coordinator.setURL("https://{{host}}/users")

        XCTAssertNil(coordinator.currentRequestIssueMessage)

        coordinator.runCurrentRequest()

        XCTAssertEqual(coordinator.currentRequestIssueMessage, "Define host before running this request.")
    }

    func testDisabledHeaderTemplateDoesNotHideLiveURLValidation() {
        let coordinator = SessionCoordinator()
        coordinator.setURL("not-a-url")
        coordinator.addHeader()
        guard let header = coordinator.state.workspaceRequest.headers.last else {
            XCTFail("Expected a header row.")
            return
        }
        coordinator.updateHeader(id: header.id, name: "X-Ignored", value: "{{unfinished", isEnabled: false)

        XCTAssertEqual(coordinator.currentRequestIssueMessage, "Use an absolute http or https URL.")
    }

    func testPlainInvalidURLKeepsLiveValidationMessage() {
        let coordinator = SessionCoordinator()
        coordinator.setURL("localhost:9999")

        XCTAssertEqual(coordinator.currentRequestIssueMessage, "Use an absolute http or https URL.")
    }

    func testCreatingMissingVariableClearsPreviousRunIssue() {
        let coordinator = SessionCoordinator()
        coordinator.setURL("https://{{host}}/users")
        coordinator.runCurrentRequest()

        XCTAssertEqual(coordinator.currentRequestIssueMessage, "Define host before running this request.")

        XCTAssertNotNil(coordinator.createVariable(name: "host", value: "example.com", scope: .global))

        XCTAssertNil(coordinator.currentRequestIssueMessage)
        XCTAssertEqual(coordinator.state.executionState, .failed)
    }

    func testMalformedCurlLeavesWorkspaceUntouchedAndSetsInlineError() {
        let coordinator = SessionCoordinator()
        coordinator.setURL("https://current.example.com")

        coordinator.handleURLBarPaste("curl https://example.com -H 'Authorization'")

        XCTAssertEqual(coordinator.state.workspaceRequest.urlString, "https://current.example.com")
        XCTAssertNil(coordinator.state.replaceConfirmationState)
        XCTAssertEqual(
            coordinator.state.inlineErrorMessage,
            "The cURL command could not be parsed: Header 'Authorization' is missing ':'."
        )
    }

    func testInvalidRunFailsValidationWithoutDispatch() async {
        let executor = StubRequestExecutor(mode: .pending)
        let coordinator = SessionCoordinator(
            requestExecutor: executor,
            responseFormatter: StubResponseFormatter()
        )
        coordinator.setURL("localhost:3000")

        coordinator.runCurrentRequest()
        await Task.yield()

        XCTAssertEqual(coordinator.state.executionState, .failed)
        XCTAssertEqual(coordinator.state.inlineErrorMessage, "Use an absolute http or https URL.")
        let count = await executor.invocations.count
        XCTAssertEqual(count, 0)
    }

    func testRunUsesFrozenSnapshotAndMarksResponseStaleIfWorkspaceChanges() async {
        let executor = StubRequestExecutor(mode: .pending)
        let formatter = StubResponseFormatter()
        let coordinator = SessionCoordinator(
            requestExecutor: executor,
            responseFormatter: formatter
        )
        coordinator.setURL("https://example.com/users")

        coordinator.runCurrentRequest()
        await waitUntil { await executor.invocationCount == 1 }
        coordinator.setURL("https://example.com/other")

        let request = await executor.invocations[0]
        await executor.resumeSuccess(
            ExecutedResponse(
                request: request,
                statusCode: 200,
                headers: [ResponseHeader(name: "Content-Type", value: "application/json")],
                bodyData: Data("{\"ok\":true}".utf8),
                mimeType: "application/json",
                duration: 0.05,
                timestamp: Date(timeIntervalSince1970: 100)
            )
        )
        await waitUntil { coordinator.state.executionState == .succeeded }

        XCTAssertEqual(request.urlString, "https://example.com/users")
        XCTAssertEqual(coordinator.state.executionState, .succeeded)
        XCTAssertEqual(coordinator.state.visibleResponseState?.isStale, true)
        XCTAssertEqual(coordinator.state.lastExecutedRequest?.request.urlString, "https://example.com/users")
    }

    func testVariableBackedResponseBecomesStaleWhenValueChangesAndFreshAfterRerun() async {
        let executor = StubRequestExecutor(mode: .pending)
        let coordinator = SessionCoordinator(
            requestExecutor: executor,
            responseFormatter: StubResponseFormatter()
        )
        coordinator.setURL("https://{{host}}/users")
        let variable = try! XCTUnwrap(coordinator.createVariable(name: "host", value: "example.com", scope: .global))

        coordinator.runCurrentRequest()
        await waitUntil { await executor.invocationCount == 1 }
        let firstRequest = await executor.invocations[0]
        await executor.resumeSuccess(
            ExecutedResponse(
                request: firstRequest,
                statusCode: 200,
                headers: [],
                bodyData: Data("ok".utf8),
                mimeType: "text/plain",
                duration: 0.01,
                timestamp: Date(timeIntervalSince1970: 100)
            )
        )
        await waitUntil { coordinator.state.executionState == .succeeded }

        XCTAssertEqual(firstRequest.urlString, "https://example.com/users")
        XCTAssertEqual(coordinator.state.visibleResponseState?.isStale, false)

        coordinator.updateVariableValue(id: variable.id, value: "staging.example.com")
        XCTAssertEqual(coordinator.state.visibleResponseState?.isStale, true)

        coordinator.runCurrentRequest()
        await waitUntil { await executor.invocationCount == 2 }
        let secondRequest = await executor.invocations[1]
        await executor.resumeSuccess(
            ExecutedResponse(
                request: secondRequest,
                statusCode: 200,
                headers: [],
                bodyData: Data("ok".utf8),
                mimeType: "text/plain",
                duration: 0.01,
                timestamp: Date(timeIntervalSince1970: 101)
            )
        )
        await waitUntil { coordinator.state.executionState == .succeeded }

        XCTAssertEqual(secondRequest.urlString, "https://staging.example.com/users")
        XCTAssertEqual(coordinator.state.visibleResponseState?.isStale, false)
    }

    func testDuplicateRunWhileRunningIsIgnored() async {
        let executor = StubRequestExecutor(mode: .pending)
        let coordinator = SessionCoordinator(
            requestExecutor: executor,
            responseFormatter: StubResponseFormatter()
        )
        coordinator.setURL("https://example.com/slow")

        coordinator.runCurrentRequest()
        coordinator.runCurrentRequest()
        await waitUntil { await executor.invocationCount >= 1 }

        let count = await executor.invocationCount
        XCTAssertEqual(count, 1)
    }

    func testRerunUsesLastExecutedSnapshotInsteadOfEditedWorkspace() async {
        let executor = StubRequestExecutor(mode: .pending)
        let formatter = StubResponseFormatter()
        let coordinator = SessionCoordinator(
            requestExecutor: executor,
            responseFormatter: formatter
        )
        coordinator.setURL("https://example.com/original")

        coordinator.runCurrentRequest()
        await waitUntil { await executor.invocationCount == 1 }
        let firstRequest = await executor.invocations[0]
        await executor.resumeSuccess(
            ExecutedResponse(
                request: firstRequest,
                statusCode: 200,
                headers: [],
                bodyData: Data("ok".utf8),
                mimeType: "text/plain",
                duration: 0.01,
                timestamp: Date(timeIntervalSince1970: 100)
            )
        )
        await waitUntil { coordinator.state.executionState == .succeeded }

        coordinator.setURL("https://example.com/edited")
        coordinator.rerunLastRequest()
        await waitUntil { await executor.invocationCount == 2 }

        let invocations = await executor.invocations
        XCTAssertEqual(invocations.count, 2)
        XCTAssertEqual(invocations[1].urlString, "https://example.com/original")
    }

    func testNewJSONResponseOpensInPrettyModeAfterPreviousResponseWasSetToRaw() async {
        let executor = StubRequestExecutor(mode: .pending)
        let coordinator = SessionCoordinator(
            requestExecutor: executor,
            responseFormatter: JSONAwareStubResponseFormatter()
        )
        coordinator.setURL("https://example.com/first")

        coordinator.runCurrentRequest()
        await waitUntil { await executor.invocationCount == 1 }
        var request = await executor.invocations[0]
        await executor.resumeSuccess(
            ExecutedResponse(
                request: request,
                statusCode: 200,
                headers: [ResponseHeader(name: "Content-Type", value: "application/json")],
                bodyData: Data("{\"ok\":true}".utf8),
                mimeType: "application/json",
                duration: 0.01,
                timestamp: Date(timeIntervalSince1970: 100)
            )
        )
        await waitUntil { coordinator.state.executionState == .succeeded }
        coordinator.setResponseMode(.raw)

        coordinator.setURL("https://example.com/second")
        coordinator.runCurrentRequest()
        await waitUntil { await executor.invocationCount == 2 }
        request = await executor.invocations[1]
        await executor.resumeSuccess(
            ExecutedResponse(
                request: request,
                statusCode: 500,
                headers: [ResponseHeader(name: "Content-Type", value: "application/json")],
                bodyData: Data("{\"error\":\"server failure\"}".utf8),
                mimeType: "application/json",
                duration: 0.01,
                timestamp: Date(timeIntervalSince1970: 101)
            )
        )
        await waitUntil { coordinator.state.visibleResponseState?.summary.statusCode == 500 }

        XCTAssertNotNil(coordinator.state.responseJSONValue)
        XCTAssertEqual(coordinator.state.currentResponseMode, .tree)
    }

    func testTreeModeFallsBackToRawForNonJSONResponse() async {
        let executor = StubRequestExecutor(mode: .pending)
        let coordinator = SessionCoordinator(
            requestExecutor: executor,
            responseFormatter: JSONAwareStubResponseFormatter()
        )
        coordinator.setURL("https://example.com/json")

        coordinator.runCurrentRequest()
        await waitUntil { await executor.invocationCount == 1 }
        var request = await executor.invocations[0]
        await executor.resumeSuccess(
            ExecutedResponse(
                request: request,
                statusCode: 200,
                headers: [ResponseHeader(name: "Content-Type", value: "application/json")],
                bodyData: Data("{\"ok\":true}".utf8),
                mimeType: "application/json",
                duration: 0.01,
                timestamp: Date(timeIntervalSince1970: 100)
            )
        )
        await waitUntil { coordinator.state.executionState == .succeeded }
        XCTAssertEqual(coordinator.state.currentResponseMode, .tree)

        coordinator.setURL("https://example.com/text")
        coordinator.runCurrentRequest()
        await waitUntil { await executor.invocationCount == 2 }
        request = await executor.invocations[1]
        await executor.resumeSuccess(
            ExecutedResponse(
                request: request,
                statusCode: 200,
                headers: [ResponseHeader(name: "Content-Type", value: "text/plain")],
                bodyData: Data("ok".utf8),
                mimeType: "text/plain",
                duration: 0.01,
                timestamp: Date(timeIntervalSince1970: 101)
            )
        )
        await waitUntil { coordinator.state.visibleResponseState?.body.bodyText == "ok" }

        XCTAssertEqual(coordinator.state.currentResponseMode, .raw)
    }

    func testRerunIsUnavailableBeforeFirstDispatchAndWhileRunning() async {
        let executor = StubRequestExecutor(mode: .pending)
        let coordinator = SessionCoordinator(
            requestExecutor: executor,
            responseFormatter: StubResponseFormatter()
        )

        XCTAssertFalse(coordinator.state.canRerun)

        coordinator.setURL("https://example.com/slow")
        coordinator.runCurrentRequest()
        await waitUntil { await executor.isWaitingForResponse }

        XCTAssertFalse(coordinator.state.canRerun)

        let countBeforeRerun = await executor.invocationCount
        coordinator.rerunLastRequest()
        let countAfterRerun = await executor.invocationCount
        XCTAssertEqual(countAfterRerun, countBeforeRerun)

        let request = await executor.invocations[0]
        await executor.resumeSuccess(
            ExecutedResponse(
                request: request,
                statusCode: 200,
                headers: [],
                bodyData: Data("ok".utf8),
                mimeType: "text/plain",
                duration: 0.01,
                timestamp: Date(timeIntervalSince1970: 100)
            )
        )
    }

    func testTransportFailureKeepsLastExecutedSnapshotAvailableForRerun() async {
        let executor = StubRequestExecutor(mode: .pending)
        let coordinator = SessionCoordinator(
            requestExecutor: executor,
            responseFormatter: StubResponseFormatter()
        )
        coordinator.setURL("https://example.com/failing")

        coordinator.runCurrentRequest()
        await waitUntil { await executor.invocationCount == 1 }
        await executor.resumeFailure(ExecutionError.transport("offline"))
        await waitUntil { coordinator.state.executionState == .failed }

        XCTAssertEqual(coordinator.state.inlineErrorMessage, "offline")
        XCTAssertEqual(coordinator.state.lastExecutedRequest?.request.urlString, "https://example.com/failing")
        XCTAssertTrue(coordinator.state.canRerun)
        XCTAssertEqual(coordinator.state.statusTitle, "Failed")
        XCTAssertEqual(coordinator.state.statusSubtitle, "offline")
    }

    func testValidationFailureAfterSuccessReplacesStatusAndPreservesPreviousResponse() async {
        let executor = StubRequestExecutor(mode: .pending)
        let coordinator = SessionCoordinator(
            requestExecutor: executor,
            responseFormatter: StubResponseFormatter()
        )
        coordinator.setURL("https://example.com/success")
        coordinator.runCurrentRequest()
        await waitUntil { await executor.invocationCount == 1 }
        let request = await executor.invocations[0]
        await executor.resumeSuccess(
            ExecutedResponse(
                request: request,
                statusCode: 200,
                headers: [],
                bodyData: Data("ok".utf8),
                mimeType: "text/plain",
                duration: 0.01,
                timestamp: Date()
            )
        )
        await waitUntil { coordinator.state.executionState == .succeeded }
        XCTAssertEqual(coordinator.state.responseSummaryStatusValue, "200")

        coordinator.setURL("https://{{missingHost}}/users")
        coordinator.runCurrentRequest()

        XCTAssertEqual(coordinator.state.executionState, .failed)
        XCTAssertEqual(coordinator.currentRequestIssueMessage, "Define missingHost before running this request.")
        XCTAssertEqual(coordinator.state.visibleResponseState?.body.bodyText, "ok")
        XCTAssertEqual(coordinator.state.visibleResponseState?.isStale, true)
        XCTAssertEqual(coordinator.globalVisibleResponseState?.body.bodyText, "ok")
        XCTAssertEqual(coordinator.state.responseSummaryStatusValue, "Failed")
        XCTAssertEqual(coordinator.state.responseTone, .failure)
        let invocationCount = await executor.invocationCount
        XCTAssertEqual(invocationCount, 1)
    }

    func testWindowCloseAndOpenPreservesSessionState() async {
        let executor = StubRequestExecutor(mode: .pending)
        let coordinator = SessionCoordinator(
            requestExecutor: executor,
            responseFormatter: StubResponseFormatter()
        )
        coordinator.setURL("https://example.com/users")
        coordinator.runCurrentRequest()
        await waitUntil { await executor.invocationCount == 1 }
        let request = await executor.invocations[0]
        await executor.resumeSuccess(
            ExecutedResponse(
                request: request,
                statusCode: 200,
                headers: [ResponseHeader(name: "Content-Type", value: "text/plain")],
                bodyData: Data("ok".utf8),
                mimeType: "text/plain",
                duration: 0.01,
                timestamp: Date(timeIntervalSince1970: 100)
            )
        )
        await waitUntil { coordinator.state.executionState == .succeeded }

        coordinator.setWindowVisible(false)
        coordinator.requestWindowOpen()

        XCTAssertTrue(coordinator.state.isWindowVisible)
        XCTAssertEqual(coordinator.state.workspaceRequest.urlString, "https://example.com/users")
        XCTAssertEqual(coordinator.state.visibleResponseState?.body.bodyText, "ok")
        XCTAssertEqual(coordinator.state.lastExecutedRequest?.request.urlString, "https://example.com/users")
        XCTAssertTrue(coordinator.state.canRerun)
    }

    func testGlobalExecutionStateCorrectlyTracksLastExecutedAcrossNavigation() async {
        let executor = StubRequestExecutor(mode: .pending)
        let coordinator = SessionCoordinator(
            requestExecutor: executor,
            responseFormatter: StubResponseFormatter()
        )
        
        // 1. Initially HUD should be idle
        XCTAssertEqual(coordinator.globalExecutionState, .idle)
        XCTAssertNil(coordinator.globalLastExecutedRequestID)
        XCTAssertNil(coordinator.globalLastExecutedRequest)
        XCTAssertFalse(coordinator.hudCanRerun)
        
        // 2. Select and run Request 1
        coordinator.setURL("https://example.com/request1")
        coordinator.runCurrentRequest()
        await waitUntil { await executor.invocationCount == 1 }
        
        XCTAssertEqual(coordinator.globalExecutionState, .running)
        
        let request1 = await executor.invocations[0]
        await executor.resumeSuccess(
            ExecutedResponse(
                request: request1,
                statusCode: 200,
                headers: [],
                bodyData: Data("response1".utf8),
                mimeType: "text/plain",
                duration: 0.05,
                timestamp: Date()
            )
        )
        await waitUntil { coordinator.globalExecutionState == .succeeded }
        
        XCTAssertEqual(coordinator.globalExecutionState, .succeeded)
        XCTAssertEqual(coordinator.globalVisibleResponseState?.summary.statusCode, 200)
        XCTAssertTrue(coordinator.hudCanRerun)
        
        // 3. Navigate away to Request 2 (change URL to simulate editing or new draft)
        coordinator.setURL("https://example.com/request2")
        // Since workspace request changed, active state might become stale/idle,
        // but global HUD point of reference MUST remain Request 1!
        XCTAssertEqual(coordinator.globalExecutionState, .succeeded)
        XCTAssertEqual(coordinator.globalVisibleResponseState?.summary.statusCode, 200)
        XCTAssertTrue(coordinator.hudCanRerun)
        XCTAssertEqual(coordinator.hudStatusTitle, "Status 200")
        
        // 4. Retrigger from HUD (rerun last request) should switch back/rerun request 1
        coordinator.rerunLastRequest()
        await waitUntil { await executor.invocationCount == 2 }
        
        let rerunRequest = await executor.invocations[1]
        XCTAssertEqual(rerunRequest.urlString, "https://example.com/request1")
        
        // Resume second execution
        await executor.resumeSuccess(
            ExecutedResponse(
                request: rerunRequest,
                statusCode: 200,
                headers: [],
                bodyData: Data("response1".utf8),
                mimeType: "text/plain",
                duration: 0.05,
                timestamp: Date()
            )
        )
    }

    func testRunResolvesVariablesWithoutMutatingWorkspaceRequest() async {
        let executor = StubRequestExecutor(mode: .pending)
        let coordinator = SessionCoordinator(requestExecutor: executor)
        coordinator.setURL("https://{{base_url}}/users/{{user_id}}")
        coordinator.addHeader()
        let headerID = coordinator.state.workspaceRequest.headers[0].id
        coordinator.updateHeader(id: headerID, name: "Authorization", value: "Bearer {{token}}")
        XCTAssertNotNil(coordinator.createVariable(name: "base_url", value: "example.com", scope: .global))
        XCTAssertNotNil(coordinator.createVariable(name: "user_id", value: "42", scope: .global))
        XCTAssertNotNil(coordinator.createVariable(name: "token", value: "abc", scope: .global))

        coordinator.runCurrentRequest()
        await waitUntil { await executor.invocationCount == 1 }

        let sent = await executor.invocations[0]
        XCTAssertEqual(sent.urlString, "https://example.com/users/42")
        XCTAssertEqual(sent.headers.first?.value, "Bearer abc")
        XCTAssertEqual(coordinator.state.workspaceRequest.urlString, "https://{{base_url}}/users/{{user_id}}")
        XCTAssertEqual(coordinator.state.workspaceRequest.headers.first?.value, "Bearer {{token}}")

        await executor.resumeSuccess(
            ExecutedResponse(
                request: sent,
                statusCode: 200,
                headers: [],
                bodyData: Data("ok".utf8),
                mimeType: "text/plain",
                duration: 0.05,
                timestamp: Date()
            )
        )
    }

    func testRunRecursivelyResolvesHeaderWithoutMutatingWorkspaceOrVariables() async {
        let executor = StubRequestExecutor(mode: .pending)
        let coordinator = SessionCoordinator(requestExecutor: executor)
        coordinator.setURL("https://example.com/users")
        coordinator.addHeader()
        let headerID = coordinator.state.workspaceRequest.headers[0].id
        coordinator.updateHeader(id: headerID, name: "Authorization", value: "{{authorization}}")
        XCTAssertNotNil(coordinator.createVariable(name: "scheme", value: "Bearer", scope: .global))
        XCTAssertNotNil(coordinator.createVariable(name: "token", value: "abc", scope: .global))
        XCTAssertNotNil(coordinator.createVariable(
            name: "authorization",
            value: "{{scheme}} {{token}}",
            scope: .global
        ))

        coordinator.runCurrentRequest()
        await waitUntil { await executor.invocationCount == 1 }

        let sent = await executor.invocations[0]
        XCTAssertEqual(sent.headers.first?.value, "Bearer abc")
        XCTAssertEqual(coordinator.state.workspaceRequest.headers.first?.value, "{{authorization}}")
        XCTAssertEqual(
            coordinator.listVariablesForCurrentContext().first(where: { $0.name == "authorization" })?.value,
            "{{scheme}} {{token}}"
        )
        await executor.resumeFailure(ExecutionError.transport("test complete"))
    }

    func testTransitiveVariableChangeMarksResponseStaleOnlyWhenEffectiveRequestChanges() async {
        let executor = StubRequestExecutor(mode: .pending)
        let coordinator = SessionCoordinator(
            requestExecutor: executor,
            responseFormatter: StubResponseFormatter()
        )
        coordinator.setURL("https://example.com")
        coordinator.addHeader()
        let headerID = coordinator.state.workspaceRequest.headers[0].id
        coordinator.updateHeader(id: headerID, name: "Authorization", value: "{{authorization}}")
        let token = try! XCTUnwrap(coordinator.createVariable(name: "token", value: "before", scope: .global))
        let wrapper = try! XCTUnwrap(coordinator.createVariable(
            name: "authorization",
            value: "Bearer {{token}}",
            scope: .global
        ))

        coordinator.runCurrentRequest()
        await waitUntil { await executor.invocationCount == 1 }
        let request = await executor.invocations[0]
        await executor.resumeSuccess(ExecutedResponse(
            request: request,
            statusCode: 200,
            headers: [],
            bodyData: Data("ok".utf8),
            mimeType: "text/plain",
            duration: 0.01,
            timestamp: Date()
        ))
        await waitUntil { coordinator.state.executionState == .succeeded }
        XCTAssertEqual(coordinator.state.visibleResponseState?.isStale, false)

        coordinator.updateVariableValue(id: wrapper.id, value: "Bearer {{token}}")
        XCTAssertEqual(coordinator.state.visibleResponseState?.isStale, false)

        coordinator.updateVariableValue(id: token.id, value: "after")
        XCTAssertEqual(coordinator.state.visibleResponseState?.isStale, true)
    }

    func testRunBlocksMissingVariableWithoutExecutorInvocation() async {
        let executor = StubRequestExecutor(mode: .pending)
        let coordinator = SessionCoordinator(requestExecutor: executor)
        coordinator.setURL("https://{{base_url}}/users")

        coordinator.runCurrentRequest()

        let invocationCount = await executor.invocationCount
        XCTAssertEqual(invocationCount, 0)
        XCTAssertEqual(coordinator.state.executionState, .failed)
        XCTAssertEqual(coordinator.state.inlineErrorMessage, "Define base_url before running this request.")
    }

    func testVariablesModalPresentationAndCRUD() {
        let coordinator = SessionCoordinator()

        XCTAssertFalse(coordinator.state.isVariablesModalPresented)
        coordinator.presentVariablesModal()
        XCTAssertTrue(coordinator.state.isVariablesModalPresented)

        let requestVariable = coordinator.createVariable(name: " user_id ", value: "42", scope: .request)
        let globalVariable = coordinator.createVariable(name: "base_url", value: "https://api.example.com", scope: .global)
        XCTAssertEqual(requestVariable?.name, "user_id")
        XCTAssertEqual(globalVariable?.scope, .global)
        XCTAssertEqual(coordinator.listVariablesForCurrentContext().map(\.name).sorted(), ["base_url", "user_id"])

        XCTAssertNil(coordinator.createVariable(name: "base_url", value: "duplicate", scope: .request))
        XCTAssertNil(coordinator.createVariable(name: "bad name", value: "x", scope: .global))

        guard let requestVariable else {
            XCTFail("Expected request variable to be created.")
            return
        }
        XCTAssertNotNil(coordinator.updateVariable(id: requestVariable.id, name: "account_id", value: "acct_123"))
        XCTAssertEqual(coordinator.listVariablesForCurrentContext().map(\.name).sorted(), ["account_id", "base_url"])

        coordinator.deleteVariable(id: requestVariable.id)
        XCTAssertEqual(coordinator.listVariablesForCurrentContext().map(\.name), ["base_url"])

        coordinator.dismissVariablesModal()
        XCTAssertFalse(coordinator.state.isVariablesModalPresented)
    }

    func testInvalidPostResponseScriptBlocksHTTPRequest() async {
        let executor = StubRequestExecutor(mode: .pending)
        let coordinator = SessionCoordinator(
            requestExecutor: executor,
            responseFormatter: StubResponseFormatter()
        )
        coordinator.setURL("https://example.com/data")
        coordinator.setPostResponseScriptEnabled(true)
        coordinator.setPostResponseScriptSource("const = ;")

        coordinator.runCurrentRequest()

        await waitUntil { coordinator.state.executionState == .failed }
        let invocationCount = await executor.invocationCount
        XCTAssertEqual(invocationCount, 0)
        XCTAssertEqual(coordinator.state.postResponseScriptState.status, .invalid)
        XCTAssertNotNil(coordinator.state.postResponseScriptState.diagnostic)
        XCTAssertNil(coordinator.state.visibleResponseState)
        XCTAssertNil(coordinator.globalLastExecutedRequest)
    }

    func testInvalidScriptDoesNotReplaceLastSuccessfullyDispatchedRequest() async {
        let executor = StubRequestExecutor(mode: .pending)
        let coordinator = SessionCoordinator(
            requestExecutor: executor,
            responseFormatter: StubResponseFormatter()
        )
        coordinator.setURL("https://example.com/first")
        coordinator.runCurrentRequest()
        await waitUntil { await executor.invocationCount == 1 }
        let first = await executor.invocations[0]
        await executor.resumeSuccess(ExecutedResponse(
            request: first,
            statusCode: 200,
            headers: [],
            bodyData: Data(),
            mimeType: nil,
            duration: 0.01,
            timestamp: Date()
        ))
        await waitUntil { coordinator.state.executionState == .succeeded }

        coordinator.setURL("https://example.com/invalid")
        coordinator.setPostResponseScriptEnabled(true)
        coordinator.setPostResponseScriptSource("const = ;")
        coordinator.runCurrentRequest()
        await waitUntil { coordinator.state.postResponseScriptState.status == .invalid }

        let invocationCount = await executor.invocationCount
        XCTAssertEqual(invocationCount, 1)
        XCTAssertEqual(coordinator.globalLastExecutedRequest?.request.urlString, "https://example.com/first")
    }

    func testPostResponseScriptCommitsVariablesAfterHTTPResponse() async {
        let executor = StubRequestExecutor(mode: .pending)
        let coordinator = SessionCoordinator(
            requestExecutor: executor,
            responseFormatter: StubResponseFormatter()
        )
        coordinator.setURL("https://example.com/token")
        coordinator.setPostResponseScriptEnabled(true)
        coordinator.setPostResponseScriptSource("""
            const body = curly.response.json();
            curly.variables.global.set("token", body.token);
            console.log("saved", body.token);
            """)

        coordinator.runCurrentRequest()
        await waitUntil { await executor.invocationCount == 1 }
        let request = await executor.invocations[0]
        await executor.resumeSuccess(ExecutedResponse(
            request: request,
            statusCode: 201,
            headers: [ResponseHeader(name: "Content-Type", value: "application/json")],
            bodyData: Data(#"{"token":"next"}"#.utf8),
            mimeType: "application/json",
            duration: 0.02,
            timestamp: Date()
        ))

        await waitUntil {
            let status = coordinator.state.postResponseScriptState.status
            return status == .passed || status == .failed || status == .invalid
        }
        XCTAssertEqual(
            coordinator.state.postResponseScriptState.status,
            .passed,
            [
                coordinator.state.postResponseScriptState.diagnostic?.message ?? "No diagnostic",
                coordinator.state.postResponseScriptState.logs.map(\.text).joined(separator: " | ")
            ].joined(separator: " — ")
        )
        XCTAssertEqual(coordinator.state.executionState, .succeeded)
        XCTAssertEqual(coordinator.state.responseSummaryStatusValue, "201")
        XCTAssertEqual(coordinator.listVariablesForCurrentContext().first(where: { $0.name == "token" })?.value, "next")
        XCTAssertEqual(coordinator.state.postResponseScriptState.changedVariableCount, 1)
        XCTAssertTrue(coordinator.state.postResponseScriptState.logs.first?.text.contains("saved next") == true)
    }

    func testScriptVariableWriteMarksResponseStaleWhenItChangesRequestResolution() async {
        let executor = StubRequestExecutor(mode: .pending)
        let coordinator = SessionCoordinator(
            requestExecutor: executor,
            responseFormatter: StubResponseFormatter()
        )
        XCTAssertNotNil(coordinator.createVariable(name: "token", value: "before", scope: .global))
        coordinator.setURL("https://example.com/items?token={{token}}")
        coordinator.setPostResponseScriptEnabled(true)
        coordinator.setPostResponseScriptSource(#"curly.variables.global.set("token", "after");"#)

        coordinator.runCurrentRequest()
        await waitUntil { await executor.invocationCount == 1 }
        let request = await executor.invocations[0]
        await executor.resumeSuccess(ExecutedResponse(
            request: request,
            statusCode: 200,
            headers: [],
            bodyData: Data(),
            mimeType: nil,
            duration: 0.01,
            timestamp: Date()
        ))
        await waitUntil { coordinator.state.postResponseScriptState.status == .passed }

        XCTAssertEqual(request.urlString, "https://example.com/items?token=before")
        XCTAssertEqual(coordinator.state.visibleResponseState?.isStale, true)
    }

    func testRequestScopedScriptWriteWorksWithoutPersistenceAndPreservesWorkspace() async {
        let executor = StubRequestExecutor(mode: .pending)
        let coordinator = SessionCoordinator(
            requestExecutor: executor,
            responseFormatter: StubResponseFormatter()
        )
        coordinator.setURL("https://example.com/no-storage")
        coordinator.setPostResponseScriptEnabled(true)
        coordinator.setPostResponseScriptSource(#"curly.variables.request.set("token", "value");"#)

        coordinator.runCurrentRequest()
        await waitUntil { await executor.invocationCount == 1 }
        let request = await executor.invocations[0]
        await executor.resumeSuccess(ExecutedResponse(
            request: request,
            statusCode: 200,
            headers: [],
            bodyData: Data(),
            mimeType: nil,
            duration: 0.01,
            timestamp: Date()
        ))
        await waitUntil { coordinator.state.postResponseScriptState.status == .passed }

        XCTAssertEqual(coordinator.state.workspaceRequest.urlString, "https://example.com/no-storage")
        let variable = coordinator.listVariablesForCurrentContext().first { $0.name == "token" }
        XCTAssertEqual(variable?.scope, .request)
        XCTAssertEqual(variable?.value, "value")
        XCTAssertNotNil(variable?.requestID)
    }

    func testHUDKeepsLastRunScriptFailureAfterWorkspaceReset() async {
        let executor = StubRequestExecutor(mode: .pending)
        let coordinator = SessionCoordinator(
            requestExecutor: executor,
            responseFormatter: StubResponseFormatter()
        )
        coordinator.setURL("https://example.com/failing-script")
        coordinator.setPostResponseScriptEnabled(true)
        coordinator.setPostResponseScriptSource(#"throw new Error("boom");"#)

        coordinator.runCurrentRequest()
        await waitUntil { await executor.invocationCount == 1 }
        let request = await executor.invocations[0]
        await executor.resumeSuccess(ExecutedResponse(
            request: request,
            statusCode: 200,
            headers: [],
            bodyData: Data(),
            mimeType: nil,
            duration: 0.01,
            timestamp: Date()
        ))
        await waitUntil { coordinator.state.postResponseScriptState.status == .failed }
        coordinator.newWorkspace()

        XCTAssertEqual(coordinator.hudStatusTitle, "Status 200")
        XCTAssertEqual(coordinator.hudStatusSubtitle, "Response received. Post-response script failed.")
    }

    func testScriptUpdatedGlobalVariableIsResolvedByNextRequest() async {
        let executor = StubRequestExecutor(mode: .pending)
        let coordinator = SessionCoordinator(
            requestExecutor: executor,
            responseFormatter: StubResponseFormatter()
        )
        coordinator.setURL("https://example.com/session")
        coordinator.setPostResponseScriptEnabled(true)
        coordinator.setPostResponseScriptSource(
            "curly.variables.global.set(\"session_id\", curly.response.json().sessionID);"
        )

        coordinator.runCurrentRequest()
        await waitUntil { await executor.invocationCount == 1 }
        let firstRequest = await executor.invocations[0]
        await executor.resumeSuccess(ExecutedResponse(
            request: firstRequest,
            statusCode: 200,
            headers: [],
            bodyData: Data(#"{"sessionID":"abc-123"}"#.utf8),
            mimeType: "application/json",
            duration: 0.01,
            timestamp: Date()
        ))
        await waitUntil { coordinator.state.postResponseScriptState.status == .passed }

        coordinator.setPostResponseScriptEnabled(false)
        coordinator.setURL("https://example.com/sessions/{{session_id}}")
        coordinator.runCurrentRequest()
        await waitUntil { await executor.invocationCount == 2 }

        let secondRequest = await executor.invocations[1]
        XCTAssertEqual(secondRequest.urlString, "https://example.com/sessions/abc-123")
        await executor.resumeFailure(ExecutionError.transport("test complete"))
    }

    func testScriptUpdatedLeafIsRecursivelyResolvedInHeaderOnNextRun() async {
        let executor = StubRequestExecutor(mode: .pending)
        let coordinator = SessionCoordinator(
            requestExecutor: executor,
            responseFormatter: StubResponseFormatter()
        )
        coordinator.setURL("https://example.com/session")
        coordinator.addHeader()
        let headerID = coordinator.state.workspaceRequest.headers[0].id
        coordinator.updateHeader(id: headerID, name: "Authorization", value: "{{authorization}}")
        XCTAssertNotNil(coordinator.createVariable(name: "token", value: "before", scope: .global))
        XCTAssertNotNil(coordinator.createVariable(
            name: "authorization",
            value: "Bearer {{token}}",
            scope: .global
        ))
        coordinator.setPostResponseScriptEnabled(true)
        coordinator.setPostResponseScriptSource(
            "curly.variables.global.set(\"token\", curly.response.json().nextToken);"
        )

        coordinator.runCurrentRequest()
        await waitUntil { await executor.invocationCount == 1 }
        let firstRequest = await executor.invocations[0]
        XCTAssertEqual(firstRequest.headers.first?.value, "Bearer before")
        await executor.resumeSuccess(ExecutedResponse(
            request: firstRequest,
            statusCode: 200,
            headers: [],
            bodyData: Data(#"{"nextToken":"after"}"#.utf8),
            mimeType: "application/json",
            duration: 0.01,
            timestamp: Date()
        ))
        await waitUntil { coordinator.state.postResponseScriptState.status == .passed }

        XCTAssertEqual(
            coordinator.listVariablesForCurrentContext().first(where: { $0.name == "authorization" })?.value,
            "Bearer {{token}}"
        )
        XCTAssertEqual(
            coordinator.listVariablesForCurrentContext().first(where: { $0.name == "token" })?.value,
            "after"
        )
        XCTAssertEqual(coordinator.state.visibleResponseState?.isStale, true)

        coordinator.setPostResponseScriptEnabled(false)
        coordinator.runCurrentRequest()
        await waitUntil { await executor.invocationCount == 2 }
        let secondRequest = await executor.invocations[1]
        XCTAssertEqual(secondRequest.headers.first?.value, "Bearer after")
        await executor.resumeFailure(ExecutionError.transport("test complete"))
    }

    func testRerunOfUnsavedRequestKeepsPostResponseAutomation() async {
        let executor = StubRequestExecutor(mode: .pending)
        let scriptRunner = RecordingScriptRunner()
        let coordinator = SessionCoordinator(
            requestExecutor: executor,
            responseFormatter: StubResponseFormatter(),
            scriptRunner: scriptRunner
        )
        coordinator.setURL("https://example.com/rerun-script")
        coordinator.setPostResponseScriptEnabled(true)
        coordinator.setPostResponseScriptSource("console.log(\"rerun\");")

        coordinator.runCurrentRequest()
        await waitUntil { await executor.invocationCount == 1 }
        let firstRequest = await executor.invocations[0]
        await executor.resumeSuccess(ExecutedResponse(
            request: firstRequest,
            statusCode: 200,
            headers: [],
            bodyData: Data(),
            mimeType: nil,
            duration: 0.01,
            timestamp: Date()
        ))
        await waitUntil {
            await scriptRunner.runCount == 1 && coordinator.state.postResponseScriptState.status == .passed
        }

        coordinator.rerunLastRequest()
        await waitUntil { await executor.invocationCount == 2 }
        let rerunRequest = await executor.invocations[1]
        await executor.resumeSuccess(ExecutedResponse(
            request: rerunRequest,
            statusCode: 200,
            headers: [],
            bodyData: Data(),
            mimeType: nil,
            duration: 0.01,
            timestamp: Date()
        ))

        await waitUntil { await scriptRunner.runCount == 2 }
        XCTAssertEqual(rerunRequest.urlString, "https://example.com/rerun-script")
    }

    func testScriptFailureRollsBackWritesAndPreservesHTTPStatus() async {
        let executor = StubRequestExecutor(mode: .pending)
        let coordinator = SessionCoordinator(
            requestExecutor: executor,
            responseFormatter: StubResponseFormatter()
        )
        XCTAssertNotNil(coordinator.createVariable(name: "token", value: "before", scope: .global))
        coordinator.setURL("https://example.com/token")
        coordinator.setPostResponseScriptEnabled(true)
        coordinator.setPostResponseScriptSource("""
            curly.variables.global.set("token", "after");
            throw new Error("do not commit");
            """)

        coordinator.runCurrentRequest()
        await waitUntil { await executor.invocationCount == 1 }
        let request = await executor.invocations[0]
        await executor.resumeSuccess(ExecutedResponse(
            request: request,
            statusCode: 422,
            headers: [],
            bodyData: Data("error".utf8),
            mimeType: "text/plain",
            duration: 0.02,
            timestamp: Date()
        ))

        await waitUntil { coordinator.state.postResponseScriptState.status == .failed }
        XCTAssertEqual(coordinator.state.executionState, .succeeded)
        XCTAssertEqual(coordinator.state.responseSummaryStatusValue, "422")
        XCTAssertEqual(coordinator.state.visibleResponseState?.summary.statusCode, 422)
        XCTAssertEqual(coordinator.listVariablesForCurrentContext().first(where: { $0.name == "token" })?.value, "before")
        XCTAssertTrue(coordinator.state.postResponseScriptState.diagnostic?.message.contains("do not commit") == true)
    }

    func testTransportFailureDoesNotExecutePostResponseScript() async {
        let executor = StubRequestExecutor(mode: .pending)
        let scriptRunner = RecordingScriptRunner()
        let coordinator = SessionCoordinator(
            requestExecutor: executor,
            responseFormatter: StubResponseFormatter(),
            scriptRunner: scriptRunner
        )
        coordinator.setURL("https://example.com/failure")
        coordinator.setPostResponseScriptEnabled(true)
        coordinator.setPostResponseScriptSource("curly.variables.global.set(\"token\", \"x\");")

        coordinator.runCurrentRequest()
        await waitUntil { await executor.invocationCount == 1 }
        await executor.resumeFailure(ExecutionError.transport("offline"))
        await waitUntil { coordinator.state.executionState == .failed }

        let runCount = await scriptRunner.runCount
        XCTAssertEqual(runCount, 0)
        XCTAssertEqual(coordinator.state.postResponseScriptState.status, .ready)
        XCTAssertEqual(coordinator.state.inlineErrorMessage, "offline")
    }

    func testEditingScriptDuringRunUsesCapturedSourceAndMarksResultStale() async {
        let executor = StubRequestExecutor(mode: .pending)
        let scriptRunner = ControlledScriptRunner()
        let coordinator = SessionCoordinator(
            requestExecutor: executor,
            responseFormatter: StubResponseFormatter(),
            scriptRunner: scriptRunner
        )
        coordinator.setURL("https://example.com/stale-script")
        coordinator.setPostResponseScriptEnabled(true)
        coordinator.setPostResponseScriptSource("curly.variables.global.set(\"source\", \"captured\");")

        coordinator.runCurrentRequest()
        await waitUntil { await executor.invocationCount == 1 }
        let request = await executor.invocations[0]
        await executor.resumeSuccess(ExecutedResponse(
            request: request,
            statusCode: 200,
            headers: [],
            bodyData: Data(),
            mimeType: nil,
            duration: 0.01,
            timestamp: Date()
        ))
        await waitUntil { await scriptRunner.runCount == 1 }

        coordinator.setPostResponseScriptSource("curly.variables.global.set(\"source\", \"edited\");")
        await scriptRunner.resume(.passed(writes: [
            ScriptVariableWrite(scope: .global, name: "source", value: "captured")
        ]))

        await waitUntil { coordinator.state.postResponseScriptState.status == .stale }
        XCTAssertEqual(coordinator.state.executionState, .succeeded)
        XCTAssertEqual(coordinator.state.responseSummaryStatusValue, "200")
        XCTAssertEqual(coordinator.listVariablesForCurrentContext().first { $0.name == "source" }?.value, "captured")

        coordinator.setPostResponseScriptSource("console.log(\"edited again\");")
        try? await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(coordinator.state.postResponseScriptState.status, .stale)
    }

    func testStartingNewWorkspaceCancelsRunningScriptWithoutCommittingWrites() async {
        let executor = StubRequestExecutor(mode: .pending)
        let scriptRunner = ControlledScriptRunner()
        let coordinator = SessionCoordinator(
            requestExecutor: executor,
            responseFormatter: StubResponseFormatter(),
            scriptRunner: scriptRunner
        )
        coordinator.setURL("https://example.com/cancel-script")
        coordinator.setPostResponseScriptEnabled(true)
        coordinator.setPostResponseScriptSource("curly.variables.global.set(\"cancelled\", \"no\");")

        coordinator.runCurrentRequest()
        await waitUntil { await executor.invocationCount == 1 }
        let request = await executor.invocations[0]
        await executor.resumeSuccess(ExecutedResponse(
            request: request,
            statusCode: 200,
            headers: [],
            bodyData: Data(),
            mimeType: nil,
            duration: 0.01,
            timestamp: Date()
        ))
        await waitUntil { await scriptRunner.runCount == 1 }

        coordinator.newWorkspace()

        await waitUntil { await scriptRunner.cancellationCount == 1 }
        XCTAssertEqual(coordinator.state.workspaceRequest, .empty)
        XCTAssertEqual(coordinator.state.postResponseScriptState.status, .off)
        XCTAssertNil(coordinator.listVariablesForCurrentContext().first { $0.name == "cancelled" })
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: @escaping @MainActor () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition not met within \(timeout) seconds")
    }
}

private actor RecordingScriptRunner: PostResponseScriptRunning {
    private(set) var runCount = 0

    func validate(source: String) async -> ScriptValidationResult {
        .valid
    }

    func run(_ input: PostResponseScriptInput) async -> PostResponseScriptRunResult {
        runCount += 1
        return PostResponseScriptRunResult(
            outcome: .passed,
            diagnostic: nil,
            durationMs: 0,
            writes: [],
            logs: [],
            logsWereTruncated: false
        )
    }
}

private actor ControlledScriptRunner: PostResponseScriptRunning {
    enum Completion {
        case passed(writes: [ScriptVariableWrite])
    }

    private(set) var runCount = 0
    private(set) var cancellationCount = 0
    private var continuation: CheckedContinuation<PostResponseScriptRunResult, Never>?

    func validate(source: String) async -> ScriptValidationResult {
        .valid
    }

    func run(_ input: PostResponseScriptInput) async -> PostResponseScriptRunResult {
        runCount += 1
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        } onCancel: {
            Task { await self.cancelPendingRun() }
        }
    }

    func resume(_ completion: Completion) {
        guard let continuation else { return }
        self.continuation = nil
        switch completion {
        case .passed(let writes):
            continuation.resume(returning: PostResponseScriptRunResult(
                outcome: .passed,
                diagnostic: nil,
                durationMs: 1,
                writes: writes,
                logs: [],
                logsWereTruncated: false
            ))
        }
    }

    private func cancelPendingRun() {
        guard let continuation else { return }
        self.continuation = nil
        cancellationCount += 1
        continuation.resume(returning: PostResponseScriptRunResult(
            outcome: .cancelled,
            diagnostic: nil,
            durationMs: 0,
            writes: [],
            logs: [],
            logsWereTruncated: false
        ))
    }
}

private actor StubRequestExecutor: RequestExecuting {
    enum Mode {
        case pending
    }

    private(set) var invocations: [Request] = []
    private var continuation: CheckedContinuation<ExecutedResponse, Error>?
    private var mode: Mode

    init(mode: Mode) {
        self.mode = mode
    }

    func execute(_ request: Request) async throws -> ExecutedResponse {
        invocations.append(request)
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resumeSuccess(_ response: ExecutedResponse) {
        continuation?.resume(returning: response)
        continuation = nil
    }

    func resumeFailure(_ error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    var invocationCount: Int {
        invocations.count
    }

    var isWaitingForResponse: Bool {
        continuation != nil
    }
}

private struct StubResponseFormatter: ResponseFormatting {
    func format(_ response: ExecutedResponse) async -> VisibleResponseState {
        VisibleResponseState(
            summary: ResponseSummary(
                statusCode: response.statusCode,
                durationDescription: "50 ms",
                sizeDescription: "9 B",
                timestampDescription: "12:00:00 PM",
                tone: response.statusCode >= 500 ? .failure : .success
            ),
            body: ResponseBody(
                headerText: response.headers.map { "\($0.name): \($0.value)" }.joined(separator: "\n"),
                bodyText: String(data: response.bodyData, encoding: .utf8) ?? "",
                isPreviewable: true,
                rawData: response.bodyData,
                mimeType: response.mimeType,
                jsonValue: nil,
                exportFilename: "response.txt"
            ),
            selectedMode: .raw,
            isStale: false
        )
    }
}

private struct JSONAwareStubResponseFormatter: ResponseFormatting {
    func format(_ response: ExecutedResponse) async -> VisibleResponseState {
        let isJSON = response.mimeType?.localizedCaseInsensitiveContains("json") == true
        return VisibleResponseState(
            summary: ResponseSummary(
                statusCode: response.statusCode,
                durationDescription: "10 ms",
                sizeDescription: "\(response.bodyData.count) B",
                timestampDescription: "12:00:00 PM",
                tone: .success
            ),
            body: ResponseBody(
                headerText: response.headers.map { "\($0.name): \($0.value)" }.joined(separator: "\n"),
                bodyText: String(data: response.bodyData, encoding: .utf8) ?? "",
                isPreviewable: true,
                rawData: response.bodyData,
                mimeType: response.mimeType,
                jsonValue: isJSON ? .object([("ok", .bool(true))]) : nil,
                exportFilename: "response.txt"
            ),
            selectedMode: isJSON ? .tree : .raw,
            isStale: false
        )
    }
}
