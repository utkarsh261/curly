import AppKit
import Foundation

struct RequestLibraryDependencies {
    let savedRequests: SavedRequestRepository
    let drafts: RequestDraftRepository
    let hiddenDraft: HiddenNewDraftRepository
    let summaries: ExecutionSummaryRepository
    let selection: SessionSelectionRepository
    let workspaceFacade: WorkspaceRepositoryFacade
    let variables: VariableRepository
}

@MainActor
final class SessionCoordinator: ObservableObject {
    private struct RequestExecutionState {
        var lastExecutedRequest: LastExecutedRequest?
        var executionState: ExecutionState
        var visibleResponseState: VisibleResponseState?
        var postResponseScriptState: PostResponseScriptState
    }

    private let curlImporter: CurlImporting
    private let requestExecutor: RequestExecuting
    private let responseFormatter: ResponseFormatting
    private let scriptRunner: PostResponseScriptRunning
    private let requestLibrary: RequestLibraryDependencies?
    private var currentRunTask: Task<Void, Never>?
    private var scriptValidationTask: Task<Void, Never>?
    private var activeRunID: UUID?
    private var savedRequestsByID: [UUID: SavedRequest] = [:]
    private var draftsByRequestID: [UUID: RequestDraft] = [:]
    private var summariesByRequestID: [UUID: ExecutionSummary] = [:]
    private var variablesByID: [UUID: Variable] = [:]
    private var executionStatesByRequestID: [UUID: RequestExecutionState] = [:]
    private var hiddenNewDraft: HiddenNewDraft?
    private var selectedContext: SelectionContext = .hiddenNewDraft
    private var selectedSavedRequestID: UUID?
    private var draftRunSummaryForHiddenContext: ExecutionSummary?
    private var didCompleteInitialLibraryLoad = false
    private var pendingPersistenceTasks: [UUID: Task<Void, Never>] = [:]
    private var persistenceChain = Task { }

    // Global executed state tracker for Menu Bar Extra HUD
    @Published private(set) var globalLastExecutedRequestID: UUID?
    @Published private(set) var globalLastExecutedRequest: LastExecutedRequest?
    @Published private(set) var globalExecutionState: ExecutionState = .idle
    @Published private(set) var globalVisibleResponseState: VisibleResponseState?
    @Published private(set) var globalInlineMessage: InlineMessage?

    @Published private(set) var state: SessionState = .initial

    var hasCompletedInitialLibraryLoad: Bool {
        requestLibrary == nil || didCompleteInitialLibraryLoad
    }

    init(
        initialState: SessionState = .initial,
        curlImporter: CurlImporting = SimpleCurlImporter(),
        requestExecutor: RequestExecuting = URLSessionRequestExecutor(),
        responseFormatter: ResponseFormatting = DefaultResponseFormatter(),
        scriptRunner: PostResponseScriptRunning = QuickJSPostResponseScriptRunner(),
        requestLibrary: RequestLibraryDependencies? = nil
    ) {
        self.state = initialState
        self.globalExecutionState = initialState.executionState
        self.globalLastExecutedRequest = initialState.lastExecutedRequest
        self.globalVisibleResponseState = initialState.visibleResponseState
        self.globalLastExecutedRequestID = initialState.selectedSavedRequestID
        self.curlImporter = curlImporter
        self.requestExecutor = requestExecutor
        self.responseFormatter = responseFormatter
        self.scriptRunner = scriptRunner
        self.requestLibrary = requestLibrary
        if requestLibrary != nil {
            Task { await self.loadRequestLibraryState() }
        } else {
            refreshRequestListPresentation()
        }
    }

    func newWorkspace() {
        if requestLibrary != nil {
            createOrFocusHiddenNewDraft()
            return
        }
        cancelActiveRun()
        scriptValidationTask?.cancel()
        state.workspaceRequest = .empty
        state.workspaceName = "Untitled Request"
        state.requestAutomation = .none
        state.postResponseScriptState = .off
        state.requestEditorExpansion = .allExpanded
        state.lastExecutedRequest = nil
        state.executionState = .idle
        state.visibleResponseState = nil
        state.replaceConfirmationState = nil
        clearInlineMessage()
        refreshRequestListPresentation()
    }

    func setWindowVisible(_ isVisible: Bool) {
        state.isWindowVisible = isVisible
        if !isVisible {
            persistSelectionState()
        }
    }

    func requestWindowOpen() {
        state.isWindowVisible = true
    }

    func setLibraryCollapsed(_ isCollapsed: Bool) {
        guard state.isLibraryCollapsed != isCollapsed else {
            return
        }
        state.isLibraryCollapsed = isCollapsed
        persistSelectionState()
    }

    func toggleLibraryCollapsed() {
        setLibraryCollapsed(!state.isLibraryCollapsed)
    }

    func waitForPendingPersistence() async {
        while true {
            let tasks = Array(pendingPersistenceTasks.values)
            if tasks.isEmpty {
                return
            }
            for task in tasks {
                await task.value
            }
        }
    }

    func flushSelectionState() async {
        await waitForPendingPersistence()
        await persistSelectionStateNow()
    }

    func prepareForTermination() async {
        cancelActiveRun()
        scriptValidationTask?.cancel()
        scriptValidationTask = nil
        await flushSelectionState()
    }

    func setMethod(_ method: HTTPMethod) {
        guard state.workspaceRequest.method != method else { return }
        state.workspaceRequest.method = method
        clearInlineMessage()
        markResultStaleIfNeeded()
        persistDraftStateAfterEdit()
    }

    func setURL(_ url: String) {
        guard state.workspaceRequest.urlString != url else { return }
        state.workspaceRequest.urlString = url
        clearInlineMessage()
        markResultStaleIfNeeded()
        persistDraftStateAfterEdit()
    }

    func handleURLBarTextChange(_ text: String) {
        setURL(text)
    }

    func setBody(_ text: String) {
        let body: RequestBody = text.isEmpty ? .none : .text(text)
        guard state.workspaceRequest.body != body else { return }
        state.workspaceRequest.body = body
        clearInlineMessage()
        markResultStaleIfNeeded()
        persistDraftStateAfterEdit()
    }

    func setPostResponseScriptEnabled(_ isEnabled: Bool) {
        guard state.requestAutomation.postResponseScript.isEnabled != isEnabled else { return }
        state.requestAutomation.postResponseScript.isEnabled = isEnabled
        state.postResponseScriptState = isEnabled ? .ready : .off
        clearInlineMessage()
        persistDraftStateAfterEdit()
        if isEnabled {
            validateCurrentPostResponseScript()
        } else {
            scriptValidationTask?.cancel()
            scriptValidationTask = nil
        }
    }

    func setPostResponseScriptSource(_ source: String) {
        guard state.requestAutomation.postResponseScript.source != source else { return }
        state.requestAutomation.postResponseScript.source = source
        if state.requestAutomation.postResponseScript.isEnabled {
            if state.postResponseScriptState.status == .passed
                || state.postResponseScriptState.status == .failed
                || state.postResponseScriptState.status == .stale {
                state.postResponseScriptState.status = .stale
            } else if state.postResponseScriptState.status != .running {
                state.postResponseScriptState = .ready
            }
            validateCurrentPostResponseScript()
        }
        persistDraftStateAfterEdit()
    }

    func addHeader() {
        state.workspaceRequest.headers.append(Header())
        clearInlineMessage()
        markResultStaleIfNeeded()
        persistDraftStateAfterEdit()
    }

    func updateHeader(id: UUID, name: String? = nil, value: String? = nil, isEnabled: Bool? = nil) {
        guard let index = state.workspaceRequest.headers.firstIndex(where: { $0.id == id }) else {
            return
        }

        if let name {
            state.workspaceRequest.headers[index].name = name
        }
        if let value {
            state.workspaceRequest.headers[index].value = value
        }
        if let isEnabled {
            state.workspaceRequest.headers[index].isEnabled = isEnabled
        }

        clearInlineMessage()
        markResultStaleIfNeeded()
        persistDraftStateAfterEdit()
    }

    func removeHeader(id: UUID) {
        state.workspaceRequest.headers.removeAll { $0.id == id }
        clearInlineMessage()
        markResultStaleIfNeeded()
        persistDraftStateAfterEdit()
    }

    func toggleRequestEditorSection(_ section: RequestEditorSection) {
        state.requestEditorExpansion.toggle(section)
    }

    func setResponseMode(_ mode: ResponseViewMode) {
        guard var visibleResponseState = state.visibleResponseState else {
            return
        }

        visibleResponseState.selectedMode = mode
        state.visibleResponseState = visibleResponseState
    }

    func handleURLBarPaste(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.looksLikeCurlCommand(trimmed) else {
            setURL(text)
            return
        }

        do {
            let importResult = try curlImporter.parse(trimmed)

            if state.workspaceRequest.isEffectivelyEmpty || state.workspaceRequest.isURLOnlyDraft(matching: text) {
                applyImportedResult(importResult)
            } else {
                state.replaceConfirmationState = ReplaceConfirmationState(
                    rawInput: trimmed,
                    candidateRequest: importResult.request,
                    candidateWarnings: importResult.warnings,
                    sourceCurl: importResult.sourceCurl
                )
                clearInlineMessage()
            }
        } catch let error as CurlImportError {
            setInlineError(error.localizedDescription)
        } catch {
            setInlineError(error.localizedDescription)
        }
    }

    private static func looksLikeCurlCommand(_ text: String) -> Bool {
        text == "curl" || text.hasPrefix("curl ") || text.hasPrefix("curl\t") || text.hasPrefix("curl\n")
    }

    func confirmWorkspaceReplacement() {
        guard let replacement = state.replaceConfirmationState else { return }
        applyImportedRequest(replacement.candidateRequest)
        setInlineWarnings(replacement.candidateWarnings)
        state.replaceConfirmationState = nil
    }

    func cancelWorkspaceReplacement() {
        state.replaceConfirmationState = nil
        clearInlineMessage()
    }

    func runCurrentRequest() {
        let result = resolveCurrentRequestForRun()
        guard let resolvedRequest = result.resolvedRequest else {
            recordPreflightFailure(result.errorMessage ?? "The request is not runnable yet.")
            return
        }
        startExecution(
            using: resolvedRequest,
            automation: state.requestAutomation,
            variables: listVariablesForCurrentContext(),
            variableOwnerID: currentVariableOwnerID()
        )
    }

    func rerunLastRequest() {
        guard let requestID = globalLastExecutedRequestID else {
            guard let request = globalLastExecutedRequest?.request else { return }
            startExecution(
                using: request,
                automation: state.requestAutomation,
                variables: listVariablesForCurrentContext(),
                variableOwnerID: currentVariableOwnerID()
            )
            return
        }
        selectSavedRequest(id: requestID)
        runCurrentRequest()
    }

    func presentVariablesModal() {
        state.isVariablesModalPresented = true
    }

    func dismissVariablesModal() {
        state.isVariablesModalPresented = false
    }

    func listVariablesForCurrentContext() -> [Variable] {
        let ownerID = currentVariableOwnerID()
        return variablesByID.values
            .filter { variable in
                variable.scope == .global || (variable.scope == .request && variable.requestID == ownerID)
            }
            .sorted {
                if $0.createdAt == $1.createdAt {
                    return $0.id.uuidString < $1.id.uuidString
                }
                return $0.createdAt < $1.createdAt
            }
    }

    @discardableResult
    func createVariable(name: String, value: String, scope: VariableScope) -> Variable? {
        let normalizedName = Variable.normalizedNameForStorage(name)
        guard Variable.isValidName(normalizedName), !variablesByID.values.contains(where: { $0.name == normalizedName }) else {
            return nil
        }
        let requestID: UUID?
        if scope == .request {
            requestID = ensureCurrentVariableOwnerID()
        } else {
            requestID = nil
        }
        guard scope == .global || requestID != nil else {
            return nil
        }
        let now = Date()
        let variable = Variable(
            name: normalizedName,
            value: value,
            scope: scope,
            requestID: requestID,
            createdAt: now,
            updatedAt: now
        )
        variablesByID[variable.id] = variable
        clearInlineMessage()
        refreshVariablesPresentation()
        markResultStaleIfNeeded()
        persistVariable(variable)
        return variable
    }

    @discardableResult
    func updateVariable(id: UUID, name: String, value: String) -> Variable? {
        guard var variable = variablesByID[id] else { return nil }
        let normalizedName = Variable.normalizedNameForStorage(name)
        guard Variable.isValidName(normalizedName) else { return nil }
        guard !variablesByID.values.contains(where: { $0.id != id && $0.name == normalizedName }) else {
            return nil
        }
        variable.name = normalizedName
        variable.value = value
        variable.updatedAt = Date()
        variablesByID[id] = variable
        clearInlineMessage()
        refreshVariablesPresentation()
        markResultStaleIfNeeded()
        persistVariable(variable)
        return variable
    }

    @discardableResult
    func updateVariableValue(id: UUID, value: String) -> Variable? {
        guard let variable = variablesByID[id] else { return nil }
        return updateVariable(id: id, name: variable.name, value: value)
    }

    func deleteVariable(id: UUID) {
        variablesByID[id] = nil
        clearInlineMessage()
        refreshVariablesPresentation()
        markResultStaleIfNeeded()
        guard let requestLibrary else { return }
        enqueuePersistenceTask(errorPrefix: "Failed to delete variable") {
            try await requestLibrary.variables.deleteVariable(id: id)
        }
    }

    func resolveCurrentRequestForRun() -> VariableResolutionResult {
        VariableResolver.resolve(state.workspaceRequest, variables: listVariablesForCurrentContext())
    }

    var currentRequestIssueMessage: String? {
        if let inlineMessage = state.inlineMessage {
            return inlineMessage.text
        }
        guard !state.workspaceRequest.containsVariableTemplateOpening else {
            return nil
        }
        return state.workspaceRequest.lightweightValidationMessage
    }

    var currentRequestIssueSeverity: InlineMessageSeverity {
        state.inlineMessage?.severity ?? .error
    }

    func updateWorkspaceName(_ name: String) {
        guard state.workspaceName != name else { return }
        state.workspaceName = name
        persistDraftStateAfterEdit()
    }

    func createOrFocusHiddenNewDraft() {
        guard let requestLibrary else {
            newWorkspace()
            return
        }
        
        cancelActiveRun()
        cacheCurrentResponseState()
        
        let newID = UUID()
        let newRequest = SavedRequest(
            id: newID,
            name: "New Request",
            request: .empty,
            createdAt: Date(),
            updatedAt: Date(),
            lastEditedAt: Date(),
            nameWasManuallyEdited: false
        )
        savedRequestsByID[newID] = newRequest
        enqueuePersistenceTask(errorPrefix: "Failed to create new request") {
            try await requestLibrary.savedRequests.upsert(newRequest)
        }
        
        selectedContext = .saved
        selectedSavedRequestID = newID
        applySelectedRequestSnapshot()
        
        loadCachedResponseState(for: newID)
        
        persistSelectionState()
        refreshRequestListPresentation()
    }

    func selectSavedRequest(id: UUID) {
        guard requestLibrary != nil else {
            return
        }
        guard savedRequestsByID[id] != nil else { return }
        
        cancelActiveRun()
        cacheCurrentResponseState()
        
        selectedContext = .saved
        selectedSavedRequestID = id
        applySelectedRequestSnapshot()
        
        loadCachedResponseState(for: id)
        
        persistSelectionState()
        refreshRequestListPresentation()
    }

    func saveCurrentRequest() {
        guard let requestLibrary else { return }
        let now = Date()
        let snapshot = EditableRequestSnapshot(
            name: normalizedWorkspaceName(),
            request: state.workspaceRequest,
            automation: state.requestAutomation
        )

        switch selectedContext {
        case .saved:
            guard let selectedSavedRequestID, let existing = savedRequestsByID[selectedSavedRequestID] else { return }
            var updated = existing
            updated.name = snapshot.name
            updated.request = snapshot.request
            updated.automation = snapshot.automation
            updated.updatedAt = now
            updated.lastEditedAt = now
            updated.nameWasManuallyEdited = true
            let updatedRequest = updated
            savedRequestsByID[updatedRequest.id] = updatedRequest
            draftsByRequestID[updatedRequest.id] = nil
            enqueuePersistenceTask(errorPrefix: "Failed to save request") {
                try await requestLibrary.savedRequests.upsert(updatedRequest)
                try await requestLibrary.drafts.deleteDraft(for: updatedRequest.id)
            }
            refreshRequestListPresentation()
        case .hiddenNewDraft:
            let hiddenDraftID = hiddenNewDraft?.id
            let newSaved = SavedRequest(
                id: UUID(),
                name: snapshot.name,
                request: snapshot.request,
                createdAt: now,
                updatedAt: now,
                lastEditedAt: now,
                nameWasManuallyEdited: true,
                automation: snapshot.automation
            )
            savedRequestsByID[newSaved.id] = newSaved
            hiddenNewDraft = nil
            selectedContext = .saved
            selectedSavedRequestID = newSaved.id
            state.workspaceName = newSaved.name
            let pendingSummary = draftRunSummaryForHiddenContext
            enqueuePersistenceTask(errorPrefix: "Failed to save request") {
                try await requestLibrary.savedRequests.upsert(newSaved)
                try await requestLibrary.hiddenDraft.deleteHiddenDraft()
                if let hiddenDraftID {
                    try await requestLibrary.variables.migrateVariables(from: hiddenDraftID, to: newSaved.id)
                }
                if let pending = pendingSummary {
                    var attached = pending
                    attached.requestID = newSaved.id
                    try await requestLibrary.summaries.saveSummary(attached)
                    await MainActor.run {
                        self.summariesByRequestID[newSaved.id] = attached
                        self.draftRunSummaryForHiddenContext = nil
                    }
                }
            }
            if let hiddenDraftID {
                migrateCachedVariables(from: hiddenDraftID, to: newSaved.id)
            }
            refreshRequestListPresentation()
            persistSelectionState()
        }
    }

    func revertCurrentRequestDraft() {
        guard selectedContext == .saved, let selectedSavedRequestID else { return }
        revertSavedRequestDraft(id: selectedSavedRequestID)
    }

    func deleteCurrentRequest() {
        guard let selectedSavedRequestID else { return }
        deleteSavedRequest(id: selectedSavedRequestID)
    }

    func deleteSavedRequest(id: UUID) {
        guard let requestLibrary else { return }
        if selectedSavedRequestID == id || globalLastExecutedRequestID == id {
            cancelActiveRun()
        }
        savedRequestsByID[id] = nil
        draftsByRequestID[id] = nil
        summariesByRequestID[id] = nil
        executionStatesByRequestID[id] = nil
        if selectedSavedRequestID == id {
            selectedSavedRequestID = nil
            selectNextContextAfterDelete()
        }
        if globalLastExecutedRequestID == id {
            globalLastExecutedRequestID = nil
            globalLastExecutedRequest = nil
            globalExecutionState = .idle
            globalVisibleResponseState = nil
            globalInlineMessage = nil
        }
        enqueuePersistenceTask(errorPrefix: "Failed to delete request") {
            try await requestLibrary.workspaceFacade.deleteSavedRequestAndRelatedState(id: id)
        }
        variablesByID = variablesByID.filter { _, variable in
            !(variable.scope == .request && variable.requestID == id)
        }
        refreshVariablesPresentation()
        refreshRequestListPresentation()
    }

    func duplicateSelectedRequest() {
        guard selectedContext == .saved, let sourceID = selectedSavedRequestID, let source = effectiveSnapshotForSavedRequest(id: sourceID) else { return }
        duplicateSavedRequest(snapshot: source)
    }

    func duplicateSavedRequest(id: UUID) {
        guard let source = effectiveSnapshotForSavedRequest(id: id) else { return }
        duplicateSavedRequest(snapshot: source)
    }

    func revertSavedRequestDraft(id: UUID) {
        guard let requestLibrary else { return }
        guard let saved = savedRequestsByID[id] else { return }
        draftsByRequestID[id] = nil
        if selectedContext == .saved, selectedSavedRequestID == id {
            state.workspaceRequest = saved.request
            state.workspaceName = saved.name
            state.requestAutomation = saved.automation
            state.postResponseScriptState = saved.automation.postResponseScript.isEnabled ? .ready : .off
            clearInlineMessage()
        }
        enqueuePersistenceTask(errorPrefix: "Failed to revert draft") {
            try await requestLibrary.drafts.deleteDraft(for: id)
        }
        refreshRequestListPresentation()
    }

    private func duplicateSavedRequest(snapshot source: EditableRequestSnapshot) {
        guard let requestLibrary else { return }
        cacheCurrentResponseState()
        let now = Date()
        let duplicate = SavedRequest(
            id: UUID(),
            name: nextDuplicateName(for: source.name),
            request: source.request,
            createdAt: now,
            updatedAt: now,
            lastEditedAt: now,
            nameWasManuallyEdited: false,
            automation: source.automation
        )
        savedRequestsByID[duplicate.id] = duplicate
        selectedSavedRequestID = duplicate.id
        selectedContext = .saved
        state.workspaceRequest = duplicate.request
        state.workspaceName = duplicate.name
        state.requestAutomation = duplicate.automation
        state.postResponseScriptState = duplicate.automation.postResponseScript.isEnabled ? .ready : .off
        enqueuePersistenceTask(errorPrefix: "Failed to duplicate request") {
            try await requestLibrary.savedRequests.upsert(duplicate)
        }
        refreshRequestListPresentation()
        persistSelectionState()
    }

    func exportVisibleResponseBody() {
        guard let body = state.visibleResponseState?.body else {
            return
        }

        let savePanel = NSSavePanel()
        savePanel.nameFieldStringValue = body.exportFilename
        savePanel.canCreateDirectories = true
        savePanel.isExtensionHidden = false

        guard savePanel.runModal() == .OK, let url = savePanel.url else {
            return
        }

        do {
            try body.rawData.write(to: url)
            clearInlineMessage()
        } catch {
            setInlineError("Could not export the response body: \(error.localizedDescription)")
        }
    }

    private func startExecution(
        using request: Request,
        automation: RequestAutomation,
        variables: [Variable],
        variableOwnerID: UUID?
    ) {
        guard currentRunTask == nil, state.executionState != .running else {
            return
        }

        guard request.isMinimallyValid else {
            recordPreflightFailure(request.lightweightValidationMessage ?? "The request is not runnable yet.")
            return
        }

        let runID = UUID()
        activeRunID = runID
        scriptValidationTask?.cancel()
        scriptValidationTask = nil
        state.executionState = .running
        state.postResponseScriptState = automation.postResponseScript.isEnabled ? .ready : .off
        clearInlineMessage()
        state.lastExecutedRequest = LastExecutedRequest(request: request)
        
        globalExecutionState = .running
        globalInlineMessage = nil
        globalLastExecutedRequest = LastExecutedRequest(request: request)
        globalLastExecutedRequestID = selectedSavedRequestID
        globalVisibleResponseState = nil
        
        let previousResponseMode = state.visibleResponseState?.selectedMode
        let runningRequestID = selectedSavedRequestID

        currentRunTask = Task { [requestExecutor, responseFormatter, scriptRunner] in
            if automation.postResponseScript.isEnabled {
                let validation = await scriptRunner.validate(source: automation.postResponseScript.source)
                guard !Task.isCancelled, self.activeRunID == runID else { return }
                switch validation {
                case .valid:
                    break
                case .invalid(let diagnostic), .failed(let diagnostic):
                    self.recordScriptPreflightFailure(diagnostic, runID: runID, request: request, requestID: runningRequestID)
                    return
                case .cancelled:
                    self.finishCancelledRun(runID: runID)
                    return
                }
            }

            do {
                let executedResponse = try await requestExecutor.execute(request)
                guard !Task.isCancelled, self.activeRunID == runID else { return }
                let formattedResponse = await responseFormatter.format(executedResponse)
                guard !Task.isCancelled, self.activeRunID == runID else { return }
                var visibleResponseState = formattedResponse
                if let previousResponseMode, previousResponseMode == .raw || visibleResponseState.body.jsonValue != nil {
                    visibleResponseState.selectedMode = previousResponseMode
                }
                visibleResponseState.isStale = self.currentRequestDiffers(from: request)
                self.publishHTTPResponse(
                    visibleResponseState,
                    executedResponse: executedResponse,
                    request: request,
                    requestID: runningRequestID,
                    scriptIsEnabled: automation.postResponseScript.isEnabled
                )

                guard automation.postResponseScript.isEnabled else {
                    self.finishRun(runID: runID)
                    return
                }

                self.updateScriptState(.init(status: .running, diagnostic: nil, logs: [], durationMs: nil, changedVariableCount: 0), requestID: runningRequestID)
                let scriptResult = await scriptRunner.run(PostResponseScriptInput(
                    response: executedResponse,
                    variables: variables,
                    currentRequestID: variableOwnerID,
                    source: automation.postResponseScript.source
                ))
                guard !Task.isCancelled, self.activeRunID == runID else { return }
                await self.finishScript(
                    result: scriptResult,
                    requestID: runningRequestID,
                    variableOwnerID: variableOwnerID,
                    capturedScript: automation.postResponseScript,
                    runID: runID
                )
            } catch let error as ExecutionError {
                guard !Task.isCancelled, self.activeRunID == runID else { return }
                self.recordTransportFailure(error.localizedDescription, request: request, requestID: runningRequestID)
                self.finishRun(runID: runID)
            } catch {
                guard !Task.isCancelled, self.activeRunID == runID else { return }
                self.recordTransportFailure(error.localizedDescription, request: request, requestID: runningRequestID)
                self.finishRun(runID: runID)
            }
        }
    }

    private func publishHTTPResponse(
        _ formattedResponse: VisibleResponseState,
        executedResponse: ExecutedResponse,
        request: Request,
        requestID: UUID?,
        scriptIsEnabled: Bool
    ) {
        let scriptState = scriptIsEnabled
            ? PostResponseScriptState(status: .running, diagnostic: nil, logs: [], durationMs: nil, changedVariableCount: 0)
            : .off
        let executionState = RequestExecutionState(
            lastExecutedRequest: LastExecutedRequest(request: request),
            executionState: .succeeded,
            visibleResponseState: formattedResponse,
            postResponseScriptState: scriptState
        )
        if let requestID {
            executionStatesByRequestID[requestID] = executionState
        }
        globalExecutionState = .succeeded
        globalVisibleResponseState = formattedResponse
        globalInlineMessage = nil
        if selectedSavedRequestID == requestID {
            state.visibleResponseState = formattedResponse
            state.executionState = .succeeded
            state.postResponseScriptState = scriptState
            clearInlineMessage()
        }
        if let requestID {
            recordExecutionSummary(
                for: requestID,
                statusCode: executedResponse.statusCode,
                duration: executedResponse.duration,
                sizeBytes: executedResponse.bodyData.count
            )
        }
    }

    private func finishScript(
        result: PostResponseScriptRunResult,
        requestID: UUID?,
        variableOwnerID: UUID?,
        capturedScript: PostResponseScript,
        runID: UUID
    ) async {
        switch result.outcome {
        case .passed:
            do {
                let changedVariables = try await commitScriptWrites(result.writes, requestID: variableOwnerID)
                guard !Task.isCancelled, activeRunID == runID else { return }
                for variable in changedVariables {
                    variablesByID[variable.id] = variable
                }
                refreshVariablesPresentation()
                let currentScript = state.requestAutomation.postResponseScript
                let isStale = currentScript != capturedScript
                let displayedStatus: PostResponseScriptStatus = currentScript.isEnabled
                    ? (isStale ? .stale : .passed)
                    : .off
                updateScriptState(
                    PostResponseScriptState(
                        status: displayedStatus,
                        diagnostic: nil,
                        logs: result.logs,
                        durationMs: result.durationMs,
                        changedVariableCount: changedVariables.count
                    ),
                    requestID: requestID
                )
            } catch {
                guard activeRunID == runID else { return }
                let currentScript = state.requestAutomation.postResponseScript
                let displayedStatus: PostResponseScriptStatus = !currentScript.isEnabled
                    ? .off
                    : (currentScript != capturedScript ? .stale : .failed)
                updateScriptState(
                    PostResponseScriptState(
                        status: displayedStatus,
                        diagnostic: ScriptDiagnostic(
                            message: "Variable changes were not saved: \(error.localizedDescription)",
                            line: nil,
                            column: nil
                        ),
                        logs: result.logs,
                        durationMs: result.durationMs,
                        changedVariableCount: 0
                    ),
                    requestID: requestID
                )
            }
        case .invalid, .failed, .timedOut:
            let fallback: String
            switch result.outcome {
            case .invalid: fallback = "The post-response script is invalid."
            case .timedOut: fallback = "The post-response script exceeded the 1 second limit."
            default: fallback = "The post-response script failed."
            }
            let currentScript = state.requestAutomation.postResponseScript
            let resultStatus: PostResponseScriptStatus = result.outcome == .invalid ? .invalid : .failed
            let displayedStatus: PostResponseScriptStatus = !currentScript.isEnabled
                ? .off
                : (currentScript != capturedScript ? .stale : resultStatus)
            updateScriptState(
                PostResponseScriptState(
                    status: displayedStatus,
                    diagnostic: result.diagnostic ?? ScriptDiagnostic(message: fallback, line: nil, column: nil),
                    logs: result.logs,
                    durationMs: result.durationMs,
                    changedVariableCount: 0
                ),
                requestID: requestID
            )
        case .cancelled:
            finishCancelledRun(runID: runID)
            return
        }
        finishRun(runID: runID)
    }

    private func commitScriptWrites(_ writes: [ScriptVariableWrite], requestID: UUID?) async throws -> [Variable] {
        guard !writes.isEmpty else { return [] }
        let mutations = try writes.map { write -> VariableBatch.SetMutation in
            if write.scope == .request, requestID == nil {
                throw VariableBatchError.missingRequestOwner
            }
            return VariableBatch.SetMutation(
                scope: write.scope,
                name: write.name,
                value: write.value,
                requestID: write.scope == .request ? requestID : nil
            )
        }
        let batch = VariableBatch(mutations: mutations, committedAt: Date())
        if let requestLibrary {
            return try await requestLibrary.variables.applyVariableBatch(batch).changedVariables
        }

        var candidate = variablesByID
        var changed: [Variable] = []
        for mutation in mutations {
            if let existing = candidate.values.first(where: { $0.name == mutation.name }) {
                guard existing.scope == mutation.scope, existing.requestID == mutation.requestID else {
                    throw VariableBatchError.scopeConflict(mutation.name)
                }
                guard existing.value != mutation.value else { continue }
                var updated = existing
                updated.value = mutation.value
                updated.updatedAt = batch.committedAt
                candidate[updated.id] = updated
                changed.append(updated)
            } else {
                let created = Variable(
                    name: mutation.name,
                    value: mutation.value,
                    scope: mutation.scope,
                    requestID: mutation.requestID,
                    createdAt: batch.committedAt,
                    updatedAt: batch.committedAt
                )
                candidate[created.id] = created
                changed.append(created)
            }
        }
        variablesByID = candidate
        return changed
    }

    private func updateScriptState(_ scriptState: PostResponseScriptState, requestID: UUID?) {
        if let requestID, var cached = executionStatesByRequestID[requestID] {
            cached.postResponseScriptState = scriptState
            executionStatesByRequestID[requestID] = cached
        }
        if selectedSavedRequestID == requestID {
            state.postResponseScriptState = scriptState
        }
    }

    private func recordScriptPreflightFailure(
        _ diagnostic: ScriptDiagnostic,
        runID: UUID,
        request: Request,
        requestID: UUID?
    ) {
        let scriptState = PostResponseScriptState(
            status: .invalid,
            diagnostic: diagnostic,
            logs: [],
            durationMs: nil,
            changedVariableCount: 0
        )
        state.executionState = .failed
        state.postResponseScriptState = scriptState
        globalExecutionState = .failed
        globalInlineMessage = InlineMessage(severity: .error, text: "Post-response script is invalid.")
        if let requestID {
            executionStatesByRequestID[requestID] = RequestExecutionState(
                lastExecutedRequest: state.lastExecutedRequest,
                executionState: .failed,
                visibleResponseState: state.visibleResponseState,
                postResponseScriptState: scriptState
            )
        }
        finishRun(runID: runID)
    }

    private func recordTransportFailure(_ message: String, request: Request, requestID: UUID?) {
        let scriptState = state.requestAutomation.postResponseScript.isEnabled ? PostResponseScriptState.ready : .off
        let executionState = RequestExecutionState(
            lastExecutedRequest: LastExecutedRequest(request: request),
            executionState: .failed,
            visibleResponseState: nil,
            postResponseScriptState: scriptState
        )
        if let requestID {
            executionStatesByRequestID[requestID] = executionState
        }
        globalExecutionState = .failed
        globalVisibleResponseState = nil
        globalInlineMessage = InlineMessage(severity: .error, text: message)
        if selectedSavedRequestID == requestID {
            state.executionState = .failed
            state.postResponseScriptState = scriptState
            setInlineError(message)
        }
    }

    private func finishRun(runID: UUID) {
        guard activeRunID == runID else { return }
        activeRunID = nil
        currentRunTask = nil
    }

    private func finishCancelledRun(runID: UUID) {
        guard activeRunID == runID else { return }
        if state.executionState == .running {
            state.executionState = state.visibleResponseState == nil ? .idle : .succeeded
        }
        if state.postResponseScriptState.status == .running {
            state.postResponseScriptState = .ready
        }
        finishRun(runID: runID)
    }

    private func cancelActiveRun() {
        let wasRunning = currentRunTask != nil
        activeRunID = nil
        currentRunTask?.cancel()
        currentRunTask = nil
        guard wasRunning else { return }
        if state.executionState == .running {
            state.executionState = state.visibleResponseState == nil ? .idle : .succeeded
        }
        if state.postResponseScriptState.status == .running {
            state.postResponseScriptState = .ready
        }
        if globalExecutionState == .running {
            globalExecutionState = globalVisibleResponseState == nil ? .idle : .succeeded
        }
    }

    private func validateCurrentPostResponseScript() {
        scriptValidationTask?.cancel()
        guard state.requestAutomation.postResponseScript.isEnabled else { return }
        let source = state.requestAutomation.postResponseScript.source
        let requestID = selectedSavedRequestID
        let priorStatus = state.postResponseScriptState.status
        scriptValidationTask = Task { [scriptRunner] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            let result = await scriptRunner.validate(source: source)
            guard !Task.isCancelled,
                  self.selectedSavedRequestID == requestID,
                  self.state.requestAutomation.postResponseScript.source == source else { return }
            switch result {
            case .valid:
                if priorStatus != .stale {
                    self.state.postResponseScriptState = .ready
                }
            case .invalid(let diagnostic), .failed(let diagnostic):
                self.state.postResponseScriptState = PostResponseScriptState(
                    status: .invalid,
                    diagnostic: diagnostic,
                    logs: [],
                    durationMs: nil,
                    changedVariableCount: 0
                )
            case .cancelled:
                break
            }
            self.scriptValidationTask = nil
        }
    }

    private func recordPreflightFailure(_ message: String) {
        state.executionState = .failed
        setInlineError(message)
        globalExecutionState = .failed
        globalInlineMessage = InlineMessage(severity: .error, text: message)

        if let selectedSavedRequestID {
            executionStatesByRequestID[selectedSavedRequestID] = RequestExecutionState(
                lastExecutedRequest: state.lastExecutedRequest,
                executionState: .failed,
                visibleResponseState: state.visibleResponseState,
                postResponseScriptState: state.postResponseScriptState
            )
        }
    }

    private func markResultStaleIfNeeded() {
        guard var visibleResponseState = state.visibleResponseState else {
            return
        }

        guard let lastExecutedRequest = state.lastExecutedRequest?.request else {
            visibleResponseState.isStale = true
            state.visibleResponseState = visibleResponseState
            return
        }

        visibleResponseState.isStale = currentRequestDiffers(from: lastExecutedRequest)
        state.visibleResponseState = visibleResponseState
        if state.requestAutomation.postResponseScript.isEnabled,
           (state.postResponseScriptState.status == .passed || state.postResponseScriptState.status == .failed) {
            state.postResponseScriptState.status = .stale
        }
    }

    private func currentRequestDiffers(from executedRequest: Request) -> Bool {
        resolveCurrentRequestForRun().resolvedRequest != executedRequest
    }

    private func applyImportedRequest(_ request: Request) {
        state.workspaceRequest = request
        state.requestEditorExpansion = .allExpanded
        let currentName = state.workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        if currentName.isEmpty || currentName == "New Request" || currentName == "Untitled Request" {
            state.workspaceName = generatedName(for: request)
        }
        markResultStaleIfNeeded()
        persistDraftStateAfterEdit()
    }

    private func applyImportedResult(_ result: CurlImportResult) {
        applyImportedRequest(result.request)
        setInlineWarnings(result.warnings)
    }

    private func setInlineWarnings(_ warnings: [String]) {
        if warnings.isEmpty {
            clearInlineMessage()
        } else {
            state.inlineMessage = InlineMessage(severity: .warning, text: warnings.joined(separator: "\n"))
        }
    }

    private func setInlineError(_ message: String) {
        state.inlineMessage = InlineMessage(severity: .error, text: message)
    }

    private func clearInlineMessage() {
        state.inlineMessage = nil
    }

    private func recordExecutionSummary(for id: UUID, statusCode: Int, duration: TimeInterval, sizeBytes: Int) {
        guard let requestLibrary else { return }
        let summary = ExecutionSummary(
            requestID: id,
            statusCode: statusCode,
            durationMs: Int(duration * 1000.0),
            sizeBytes: sizeBytes,
            lastRunAt: Date(),
            lastRunSource: .saved
        )

        summariesByRequestID[id] = summary
        enqueuePersistenceTask(errorPrefix: "Failed to persist run summary") {
            try await requestLibrary.summaries.saveSummary(summary)
        }
        refreshRequestListPresentation()
    }

    private func loadRequestLibraryState() async {
        guard let requestLibrary else { return }
        do {
            var savedList = try await requestLibrary.savedRequests.list()
            if savedList.isEmpty {
                let initialRequest = SavedRequest(
                    id: UUID(),
                    name: "New Request",
                    request: .empty,
                    createdAt: Date(),
                    updatedAt: Date(),
                    lastEditedAt: Date(),
                    nameWasManuallyEdited: false
                )
                try await requestLibrary.savedRequests.upsert(initialRequest)
                savedList = [initialRequest]
            }
            var loadedDrafts: [UUID: RequestDraft] = [:]
            var loadedSummaries: [UUID: ExecutionSummary] = [:]
            var loadedExecutionStates: [UUID: RequestExecutionState] = [:]
            let loadedVariables = try await requestLibrary.variables.listVariables()
            for request in savedList {
                if let draft = try await requestLibrary.drafts.draft(for: request.id) {
                    loadedDrafts[request.id] = draft
                }
                if let summary = try await requestLibrary.summaries.summary(for: request.id) {
                    loadedSummaries[request.id] = summary
                    
                    let statusCode = summary.statusCode ?? 200
                    let durationMs = summary.durationMs ?? 0
                    let sizeBytes = summary.sizeBytes ?? 0
                    let lastRunAt = summary.lastRunAt ?? Date()
                    
                    let responseTone: ResponseTone
                    if statusCode >= 200 && statusCode < 300 {
                        responseTone = .success
                    } else if statusCode >= 300 && statusCode < 400 {
                        responseTone = .warning
                    } else {
                        responseTone = .failure
                    }
                    
                    let respSummary = ResponseSummary(
                        statusCode: statusCode,
                        durationDescription: "\(durationMs)ms",
                        sizeDescription: ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file),
                        timestampDescription: RelativeDateTimeFormatter().localizedString(for: lastRunAt, relativeTo: Date()),
                        tone: responseTone
                    )
                    
                    let dummyBody = ResponseBody(
                        headerText: "",
                        bodyText: "",
                        isPreviewable: false,
                        rawData: Data(),
                        mimeType: nil,
                        jsonValue: nil,
                        exportFilename: "response"
                    )
                    
                    let visibleState = VisibleResponseState(
                        summary: respSummary,
                        body: dummyBody,
                        selectedMode: .raw,
                        isStale: false
                    )
                    
                    let effectiveSnapshot = loadedDrafts[request.id]?.snapshot
                        ?? EditableRequestSnapshot(name: request.name, request: request.request, automation: request.automation)
                    loadedExecutionStates[request.id] = RequestExecutionState(
                        lastExecutedRequest: LastExecutedRequest(request: effectiveSnapshot.request),
                        executionState: .succeeded,
                        visibleResponseState: visibleState,
                        postResponseScriptState: effectiveSnapshot.automation.postResponseScript.isEnabled ? .ready : .off
                    )
                }
            }
            
            var globalLastID: UUID?
            var globalLastReq: LastExecutedRequest?
            var globalExecState: ExecutionState = .idle
            var globalVisibleState: VisibleResponseState?
            
            if let mostRecentSummary = loadedSummaries.values.max(by: { ($0.lastRunAt ?? Date.distantPast) < ($1.lastRunAt ?? Date.distantPast) }),
               let matchedRequest = savedList.first(where: { $0.id == mostRecentSummary.requestID }) {
                globalLastID = mostRecentSummary.requestID
                let targetRequest = loadedDrafts[mostRecentSummary.requestID]?.snapshot.request ?? matchedRequest.request
                globalLastReq = LastExecutedRequest(request: targetRequest)
                globalExecState = .succeeded
                globalVisibleState = loadedExecutionStates[mostRecentSummary.requestID]?.visibleResponseState
            }
            
            let hiddenDraft = try await requestLibrary.hiddenDraft.hiddenDraft()
            let selection = try await requestLibrary.selection.selection()
            await MainActor.run {
                if self.didCompleteInitialLibraryLoad {
                    return
                }
                self.savedRequestsByID = Dictionary(uniqueKeysWithValues: savedList.map { ($0.id, $0) })
                self.draftsByRequestID = loadedDrafts
                self.summariesByRequestID = loadedSummaries
                self.variablesByID = loadedVariables.reduce(into: [:]) { result, variable in
                    guard let existing = result[variable.id] else {
                        result[variable.id] = variable
                        return
                    }
                    if variable.updatedAt > existing.updatedAt {
                        result[variable.id] = variable
                    }
                }
                self.refreshVariablesPresentation()
                let duplicateNames = VariableLookup(variables: loadedVariables).duplicateNames
                if !duplicateNames.isEmpty {
                    self.state.persistenceWarningMessage = Self.duplicateVariableWarning(names: duplicateNames)
                }
                self.executionStatesByRequestID = loadedExecutionStates
                self.hiddenNewDraft = hiddenDraft
                self.restoreSelection(selection)
                
                if let globalLastID {
                    self.globalLastExecutedRequestID = globalLastID
                    self.globalLastExecutedRequest = globalLastReq
                    self.globalExecutionState = globalExecState
                    self.globalVisibleResponseState = globalVisibleState
                } else {
                    self.globalLastExecutedRequestID = self.selectedSavedRequestID
                    self.globalLastExecutedRequest = self.state.lastExecutedRequest
                    self.globalExecutionState = self.state.executionState
                    self.globalVisibleResponseState = self.state.visibleResponseState
                }
                
                self.globalInlineMessage = self.state.inlineMessage
                self.refreshRequestListPresentation()
                self.didCompleteInitialLibraryLoad = true
            }
        } catch {
            await MainActor.run {
                self.didCompleteInitialLibraryLoad = true
                state.persistenceWarningMessage = "Local persistence is unavailable. Changes will not survive relaunch until storage is repaired."
                state.workspaceRequest = .empty
                state.workspaceName = "Untitled Request"
                selectedContext = .hiddenNewDraft
                selectedSavedRequestID = nil
                refreshRequestListPresentation()
            }
        }
    }

    private func restoreSelection(_ persisted: SessionSelection?) {
        state.isLibraryCollapsed = persisted?.isLibraryCollapsed ?? state.isLibraryCollapsed

        if persisted?.selectedContext == .hiddenNewDraft, hiddenNewDraft != nil {
            selectedContext = .hiddenNewDraft
            selectedSavedRequestID = nil
            applySelectedRequestSnapshot()
            return
        }

        if !savedRequestsByID.isEmpty {
            if let persisted,
               persisted.selectedContext == .saved,
               let persistedSavedID = persisted.selectedSavedRequestID,
               savedRequestsByID[persistedSavedID] != nil {
                selectedContext = .saved
                selectedSavedRequestID = persistedSavedID
                applySelectedRequestSnapshot()
                loadCachedResponseState(for: persistedSavedID)
                return
            }

            if let persistedSavedID = persisted?.selectedSavedRequestID,
               savedRequestsByID[persistedSavedID] != nil {
                selectedContext = .saved
                selectedSavedRequestID = persistedSavedID
                applySelectedRequestSnapshot()
                loadCachedResponseState(for: persistedSavedID)
                return
            }

            if let mostRecentlyEdited = savedRequestsByID.values.max(by: { $0.lastEditedAt < $1.lastEditedAt }) {
                selectedContext = .saved
                selectedSavedRequestID = mostRecentlyEdited.id
                applySelectedRequestSnapshot()
                loadCachedResponseState(for: mostRecentlyEdited.id)
                return
            }
        }
    }

    private func normalizedWorkspaceName() -> String {
        let trimmed = state.workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return generatedName(for: state.workspaceRequest)
        }
        return trimmed
    }

    private func generatedName(for request: Request) -> String {
        let trimmed = request.urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              let host = components.host else {
            return "Untitled Request"
        }
        let path = components.path.isEmpty ? "" : components.path
        return "\(request.method.rawValue) \(host)\(path)"
    }

    private func effectiveSnapshotForSavedRequest(id: UUID) -> EditableRequestSnapshot? {
        if let draft = draftsByRequestID[id] {
            return draft.snapshot
        }
        guard let saved = savedRequestsByID[id] else { return nil }
        return EditableRequestSnapshot(name: saved.name, request: saved.request, automation: saved.automation)
    }

    private func applySelectedRequestSnapshot() {
        switch selectedContext {
        case .saved:
            guard let selectedSavedRequestID,
                  let snapshot = effectiveSnapshotForSavedRequest(id: selectedSavedRequestID) else { return }
            state.workspaceRequest = snapshot.request
            state.workspaceName = snapshot.name
            state.requestAutomation = snapshot.automation
            state.requestEditorExpansion = .allExpanded
            state.postResponseScriptState = snapshot.automation.postResponseScript.isEnabled ? .ready : .off
            validateCurrentPostResponseScript()
        case .hiddenNewDraft:
            let snapshot = hiddenNewDraft?.snapshot ?? EditableRequestSnapshot(name: "Untitled Request", request: .empty)
            state.workspaceRequest = snapshot.request
            state.workspaceName = snapshot.name
            state.requestAutomation = snapshot.automation
            state.requestEditorExpansion = .allExpanded
            state.postResponseScriptState = snapshot.automation.postResponseScript.isEnabled ? .ready : .off
            validateCurrentPostResponseScript()
        }
    }

    private func persistSelectionState() {
        guard didCompleteInitialLibraryLoad, let requestLibrary else { return }
        let selection = SessionSelection(
            selectedSavedRequestID: selectedSavedRequestID,
            selectedContext: selectedContext,
            isLibraryCollapsed: state.isLibraryCollapsed,
            updatedAt: Date()
        )
        enqueuePersistenceTask(errorPrefix: "Failed to persist selection") {
            try await requestLibrary.selection.saveSelection(selection)
        }
    }

    private func persistSelectionStateNow() async {
        guard didCompleteInitialLibraryLoad, let requestLibrary else { return }
        let selection = SessionSelection(
            selectedSavedRequestID: selectedSavedRequestID,
            selectedContext: selectedContext,
            isLibraryCollapsed: state.isLibraryCollapsed,
            updatedAt: Date()
        )
        do {
            try await requestLibrary.selection.saveSelection(selection)
        } catch {
            setInlineError("Failed to persist selection: \(error.localizedDescription)")
        }
    }

    private func currentVariableOwnerID() -> UUID? {
        switch selectedContext {
        case .saved:
            return selectedSavedRequestID
        case .hiddenNewDraft:
            return hiddenNewDraft?.id
        }
    }

    private func ensureCurrentVariableOwnerID() -> UUID? {
        if let current = currentVariableOwnerID() {
            return current
        }
        selectHiddenNewDraft(createIfMissing: true)
        return hiddenNewDraft?.id
    }

    private func persistVariable(_ variable: Variable) {
        guard let requestLibrary else { return }
        enqueuePersistenceTask(errorPrefix: "Failed to persist variable") {
            try await requestLibrary.variables.saveVariable(variable)
        }
    }

    private func migrateCachedVariables(from oldRequestID: UUID, to newRequestID: UUID) {
        for (id, variable) in variablesByID where variable.scope == .request && variable.requestID == oldRequestID {
            var migrated = variable
            migrated.requestID = newRequestID
            variablesByID[id] = migrated
        }
        refreshVariablesPresentation()
    }

    private func refreshVariablesPresentation() {
        state.variables = variablesByID.values.sorted {
            if $0.createdAt == $1.createdAt {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.createdAt < $1.createdAt
        }
    }

    private static func duplicateVariableWarning(names: [String]) -> String {
        let listedNames = names.joined(separator: ", ")
        return "Duplicate variable names were found in local storage: \(listedNames). The newest value is used until the duplicate is renamed or deleted."
    }

    private func persistDraftStateAfterEdit() {
        guard let requestLibrary else {
            refreshRequestListPresentation()
            return
        }
        let snapshot = EditableRequestSnapshot(
            name: normalizedWorkspaceName(),
            request: state.workspaceRequest,
            automation: state.requestAutomation
        )
        let now = Date()
        switch selectedContext {
        case .saved:
            guard let selectedSavedRequestID, let saved = savedRequestsByID[selectedSavedRequestID] else {
                refreshRequestListPresentation()
                return
            }
            let draft = RequestDraft(
                requestID: selectedSavedRequestID,
                snapshot: snapshot,
                lastEditedAt: now,
                baseSavedUpdatedAt: saved.updatedAt,
                draftBaseOutdated: false
            )
            draftsByRequestID[selectedSavedRequestID] = draft
            enqueuePersistenceTask(errorPrefix: "Failed to persist draft") {
                try await requestLibrary.drafts.saveDraft(draft)
            }
        case .hiddenNewDraft:
            let draft = HiddenNewDraft(
                id: hiddenNewDraft?.id ?? UUID(),
                snapshot: snapshot,
                nameWasManuallyEdited: true,
                lastEditedAt: now
            )
            hiddenNewDraft = draft
            enqueuePersistenceTask(errorPrefix: "Failed to persist draft") {
                try await requestLibrary.hiddenDraft.saveHiddenDraft(draft)
            }
        }
        refreshRequestListPresentation()
    }

    private func selectHiddenNewDraft(createIfMissing: Bool) {
        selectedContext = .hiddenNewDraft
        selectedSavedRequestID = nil
        if hiddenNewDraft == nil && createIfMissing {
            let draft = HiddenNewDraft(
                id: UUID(),
                snapshot: EditableRequestSnapshot(name: "Untitled Request", request: .empty),
                nameWasManuallyEdited: false,
                lastEditedAt: Date()
            )
            hiddenNewDraft = draft
            if let requestLibrary {
                enqueuePersistenceTask {
                    try await requestLibrary.hiddenDraft.saveHiddenDraft(draft)
                }
            }
        }
        applySelectedRequestSnapshot()
        persistSelectionState()
        refreshRequestListPresentation()
    }

    private func selectNextContextAfterDelete() {
        let orderedIDs = savedRequestsByID.values.sorted { $0.lastEditedAt > $1.lastEditedAt }.map(\.id)
        if let next = orderedIDs.first {
            selectedContext = .saved
            selectedSavedRequestID = next
            applySelectedRequestSnapshot()
            persistSelectionState()
            return
        }
        createOrFocusHiddenNewDraft()
    }

    private func refreshRequestListPresentation() {
        let items: [RequestListItem] = savedRequestsByID.values.map { saved in
            let isDirty: Bool
            let method: HTTPMethod
            let name: String
            let urlString: String
            
            if let draft = draftsByRequestID[saved.id] {
                isDirty = draft.snapshot.name != saved.name
                    || draft.snapshot.request != saved.request
                    || draft.snapshot.automation != saved.automation
                name = draft.snapshot.name
                method = draft.snapshot.request.method
                urlString = draft.snapshot.request.urlString
            } else {
                isDirty = false
                name = saved.name
                method = saved.request.method
                urlString = saved.request.urlString
            }
            
            return RequestListItem(
                id: saved.id,
                name: name,
                method: method,
                urlPreview: requestPreview(for: urlString),
                lastEditedAt: saved.lastEditedAt,
                isDirty: isDirty,
                lastSummary: summariesByRequestID[saved.id]
            )
        }
        .sorted {
            if $0.lastEditedAt == $1.lastEditedAt {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.lastEditedAt > $1.lastEditedAt
        }

        state.requestListItems = items
        state.selectedSavedRequestID = selectedSavedRequestID
        state.selectedRequestContext = selectedContext
        state.isCurrentRequestDirty = currentDirtyState()
        state.canSaveCurrentRequest = currentSaveEnabled()
        state.canRevertCurrentRequest = selectedContext == .saved && state.isCurrentRequestDirty
        state.canDiscardHiddenNewDraft = selectedContext == .hiddenNewDraft && !state.workspaceRequest.isEffectivelyEmpty
    }

    private func currentDirtyState() -> Bool {
        switch selectedContext {
        case .saved:
            guard let selectedSavedRequestID,
                  let saved = savedRequestsByID[selectedSavedRequestID] else { return false }
            if let draft = draftsByRequestID[selectedSavedRequestID] {
                return draft.snapshot.name != saved.name
                    || draft.snapshot.request != saved.request
                    || draft.snapshot.automation != saved.automation
            }
            return false
        case .hiddenNewDraft:
            return !state.workspaceRequest.isEffectivelyEmpty
                || state.requestAutomation != .none
                || !state.workspaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func currentSaveEnabled() -> Bool {
        switch selectedContext {
        case .saved:
            return state.isCurrentRequestDirty
        case .hiddenNewDraft:
            return !state.workspaceRequest.isEffectivelyEmpty || state.requestAutomation != .none
        }
    }

    private func requestPreview(for urlString: String) -> String {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "No URL" }
        if let components = URLComponents(string: trimmed), let host = components.host {
            var preview = host
            if !components.path.isEmpty { preview += components.path }
            if let query = components.percentEncodedQuery, !query.isEmpty { preview += "?\(query)" }
            return preview
        }
        return trimmed
    }

    private func nextDuplicateName(for source: String) -> String {
        var candidate = source.hasSuffix("Copy") ? "\(source) 2" : "\(source) Copy"
        let existing = Set(savedRequestsByID.values.map(\.name))
        var index = 3
        while existing.contains(candidate) {
            candidate = "\(source) \(index)"
            index += 1
        }
        return candidate
    }

    private func enqueuePersistenceTask(
        errorPrefix: String? = nil,
        _ operation: @escaping @Sendable () async throws -> Void
    ) {
        let taskID = UUID()
        let previousChain = persistenceChain
        
        let task = Task { [weak self] in
            _ = await previousChain.result

            defer {
                self?.pendingPersistenceTasks[taskID] = nil
            }

            do {
                try await operation()
            } catch {
                guard let self, let errorPrefix else {
                    return
                }
                await MainActor.run {
                    self.setInlineError("\(errorPrefix): \(error.localizedDescription)")
                }
            }
        }
        pendingPersistenceTasks[taskID] = task
        persistenceChain = Task {
            _ = await task.result
        }
    }

    private func cacheCurrentResponseState() {
        guard let selectedSavedRequestID else { return }
        executionStatesByRequestID[selectedSavedRequestID] = RequestExecutionState(
            lastExecutedRequest: state.lastExecutedRequest,
            executionState: state.executionState,
            visibleResponseState: state.visibleResponseState,
            postResponseScriptState: state.postResponseScriptState
        )
    }

    private func loadCachedResponseState(for id: UUID) {
        let cached = executionStatesByRequestID[id] ?? RequestExecutionState(
            lastExecutedRequest: nil,
            executionState: .idle,
            visibleResponseState: nil,
            postResponseScriptState: state.requestAutomation.postResponseScript.isEnabled ? .ready : .off
        )
        state.lastExecutedRequest = cached.lastExecutedRequest
        state.executionState = cached.executionState
        state.visibleResponseState = cached.visibleResponseState
        state.postResponseScriptState = cached.postResponseScriptState
    }

    // Computed HUD properties mapping to global states
    var hudStatusTitle: String {
        switch globalExecutionState {
        case .idle:
            return globalLastExecutedRequest == nil ? "Idle" : "Ready"
        case .running:
            return "Running"
        case .succeeded:
            if let statusCode = globalVisibleResponseState?.summary.statusCode {
                return "Status \(statusCode)"
            }
            return "Succeeded"
        case .failed:
            return "Failed"
        }
    }

    var hudStatusSubtitle: String {
        switch globalExecutionState {
        case .idle:
            return globalLastExecutedRequest == nil ? "No request has run in this session." : "Last executed request is available to rerun."
        case .running:
            return "The current request is in flight."
        case .succeeded:
            if currentRunTask != nil, state.postResponseScriptState.status == .running {
                return "Response received. Post-response script is running."
            }
            if state.postResponseScriptState.status == .failed || state.postResponseScriptState.status == .invalid {
                return "Response received. Post-response script failed."
            }
            return "Last request completed."
        case .failed:
            return globalInlineMessage?.text ?? "Last request failed."
        }
    }

    var hudStatusTone: ResponseTone {
        if globalExecutionState == .running {
            return .neutral
        }
        if globalExecutionState == .failed {
            return .failure
        }
        return globalVisibleResponseState?.summary.tone ?? .neutral
    }

    var hudStatusIconName: String {
        switch hudStatusTone {
        case .neutral:
            if globalExecutionState == .running {
                return "arrow.triangle.2.circlepath.circle"
            }
            if globalExecutionState == .failed {
                return "exclamationmark.triangle"
            }
            return "bolt.horizontal.circle"
        case .success:
            return "checkmark.circle"
        case .warning:
            return "exclamationmark.circle"
        case .failure:
            return "xmark.circle"
        }
    }

    var hudCanRerun: Bool {
        globalExecutionState != .running && currentRunTask == nil && globalLastExecutedRequest != nil
    }
}
