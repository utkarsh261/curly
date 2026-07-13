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
        XCTAssertEqual(coordinator.currentRequestIssueMessage, "The URL is not valid yet.")

        coordinator.setURL("http://localhost:{{port}}/post?a={{auth}}")

        XCTAssertNil(coordinator.currentRequestIssueMessage)
        XCTAssertEqual(
            coordinator.resolveCurrentRequestForRun().resolvedRequest?.urlString,
            "http://localhost:9999/post?a=token"
        )
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

    func testRunPreservesRawResponseModeAcrossJSONResponses() async {
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
                statusCode: 200,
                headers: [ResponseHeader(name: "Content-Type", value: "application/json")],
                bodyData: Data("{\"next\":true}".utf8),
                mimeType: "application/json",
                duration: 0.01,
                timestamp: Date(timeIntervalSince1970: 101)
            )
        )
        await waitUntil { coordinator.state.visibleResponseState?.body.bodyText == "{\"next\":true}" }

        XCTAssertEqual(coordinator.state.currentResponseMode, .raw)
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
