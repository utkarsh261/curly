import AppKit
import Foundation

struct RequestLibraryDependencies {
    let savedRequests: SavedRequestRepository
    let drafts: RequestDraftRepository
    let hiddenDraft: HiddenNewDraftRepository
    let summaries: ExecutionSummaryRepository
    let selection: SessionSelectionRepository
    let workspaceFacade: WorkspaceRepositoryFacade
}

@MainActor
final class SessionCoordinator: ObservableObject {
    private struct RequestExecutionState {
        var lastExecutedRequest: LastExecutedRequest?
        var executionState: ExecutionState
        var visibleResponseState: VisibleResponseState?
    }

    private let curlImporter: CurlImporting
    private let requestExecutor: RequestExecuting
    private let responseFormatter: ResponseFormatting
    private let requestLibrary: RequestLibraryDependencies?
    private var currentRunTask: Task<Void, Never>?
    private var savedRequestsByID: [UUID: SavedRequest] = [:]
    private var draftsByRequestID: [UUID: RequestDraft] = [:]
    private var summariesByRequestID: [UUID: ExecutionSummary] = [:]
    private var executionStatesByRequestID: [UUID: RequestExecutionState] = [:]
    private var hiddenNewDraft: HiddenNewDraft?
    private var selectedContext: SelectionContext = .hiddenNewDraft
    private var selectedSavedRequestID: UUID?
    private var draftRunSummaryForHiddenContext: ExecutionSummary?
    private var didCompleteInitialLibraryLoad = false
    private var hasLocalLibraryMutationsBeforeInitialLoad = false
    private var pendingPersistenceTasks: [UUID: Task<Void, Never>] = [:]
    private var persistenceChain = Task { }

    @Published private(set) var state: SessionState = .initial

    init(
        initialState: SessionState = .initial,
        curlImporter: CurlImporting = SimpleCurlImporter(),
        requestExecutor: RequestExecuting = URLSessionRequestExecutor(),
        responseFormatter: ResponseFormatting = DefaultResponseFormatter(),
        requestLibrary: RequestLibraryDependencies? = nil
    ) {
        self.state = initialState
        self.curlImporter = curlImporter
        self.requestExecutor = requestExecutor
        self.responseFormatter = responseFormatter
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
        currentRunTask?.cancel()
        currentRunTask = nil
        state.workspaceRequest = .empty
        state.workspaceName = "Untitled Request"
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
    }

    func requestWindowOpen() {
        state.isWindowVisible = true
    }

    func setLibraryCollapsed(_ isCollapsed: Bool) {
        markLocalMutationDuringInitialLoadIfNeeded()
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

    func setMethod(_ method: HTTPMethod) {
        markLocalMutationDuringInitialLoadIfNeeded()
        state.workspaceRequest.method = method
        clearInlineMessage()
        markResultStaleIfNeeded()
        persistDraftStateAfterEdit()
    }

    func setURL(_ url: String) {
        markLocalMutationDuringInitialLoadIfNeeded()
        state.workspaceRequest.urlString = url
        clearInlineMessage()
        markResultStaleIfNeeded()
        persistDraftStateAfterEdit()
    }

    func handleURLBarTextChange(_ text: String) {
        setURL(text)
    }

    func setBody(_ text: String) {
        markLocalMutationDuringInitialLoadIfNeeded()
        state.workspaceRequest.body = text.isEmpty ? .none : .text(text)
        clearInlineMessage()
        markResultStaleIfNeeded()
        persistDraftStateAfterEdit()
    }

    func addHeader() {
        markLocalMutationDuringInitialLoadIfNeeded()
        state.workspaceRequest.headers.append(Header())
        clearInlineMessage()
        markResultStaleIfNeeded()
        persistDraftStateAfterEdit()
    }

    func updateHeader(id: UUID, name: String? = nil, value: String? = nil, isEnabled: Bool? = nil) {
        markLocalMutationDuringInitialLoadIfNeeded()
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
        markLocalMutationDuringInitialLoadIfNeeded()
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

            if state.workspaceRequest.isEffectivelyEmpty {
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
        startExecution(using: state.workspaceRequest)
    }

    func rerunLastRequest() {
        guard let request = state.lastExecutedRequest?.request else {
            return
        }
        startExecution(using: request)
    }

    func updateWorkspaceName(_ name: String) {
        markLocalMutationDuringInitialLoadIfNeeded()
        state.workspaceName = name
        persistDraftStateAfterEdit()
    }

    func createOrFocusHiddenNewDraft() {
        markLocalMutationDuringInitialLoadIfNeeded()
        guard let requestLibrary else {
            newWorkspace()
            return
        }
        
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
        markLocalMutationDuringInitialLoadIfNeeded()
        guard requestLibrary != nil else {
            return
        }
        guard savedRequestsByID[id] != nil else { return }
        
        cacheCurrentResponseState()
        
        selectedContext = .saved
        selectedSavedRequestID = id
        applySelectedRequestSnapshot()
        
        loadCachedResponseState(for: id)
        
        persistSelectionState()
        refreshRequestListPresentation()
    }

    func saveCurrentRequest() {
        markLocalMutationDuringInitialLoadIfNeeded()
        guard let requestLibrary else { return }
        let now = Date()
        let snapshot = EditableRequestSnapshot(name: normalizedWorkspaceName(), request: state.workspaceRequest)

        switch selectedContext {
        case .saved:
            guard let selectedSavedRequestID, let existing = savedRequestsByID[selectedSavedRequestID] else { return }
            var updated = existing
            updated.name = snapshot.name
            updated.request = snapshot.request
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
            let newSaved = SavedRequest(
                id: UUID(),
                name: snapshot.name,
                request: snapshot.request,
                createdAt: now,
                updatedAt: now,
                lastEditedAt: now,
                nameWasManuallyEdited: true
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
            refreshRequestListPresentation()
            persistSelectionState()
        }
    }

    func revertCurrentRequestDraft() {
        markLocalMutationDuringInitialLoadIfNeeded()
        guard selectedContext == .saved, let selectedSavedRequestID else { return }
        revertSavedRequestDraft(id: selectedSavedRequestID)
    }

    func deleteCurrentRequest() {
        guard let selectedSavedRequestID else { return }
        deleteSavedRequest(id: selectedSavedRequestID)
    }

    func deleteSavedRequest(id: UUID) {
        markLocalMutationDuringInitialLoadIfNeeded()
        guard let requestLibrary else { return }
        savedRequestsByID[id] = nil
        draftsByRequestID[id] = nil
        summariesByRequestID[id] = nil
        executionStatesByRequestID[id] = nil
        if selectedSavedRequestID == id {
            selectedSavedRequestID = nil
            selectNextContextAfterDelete()
        }
        enqueuePersistenceTask(errorPrefix: "Failed to delete request") {
            try await requestLibrary.workspaceFacade.deleteSavedRequestAndRelatedState(id: id)
        }
        refreshRequestListPresentation()
    }

    func duplicateSelectedRequest() {
        markLocalMutationDuringInitialLoadIfNeeded()
        guard selectedContext == .saved, let sourceID = selectedSavedRequestID, let source = effectiveSnapshotForSavedRequest(id: sourceID) else { return }
        duplicateSavedRequest(snapshot: source)
    }

    func duplicateSavedRequest(id: UUID) {
        markLocalMutationDuringInitialLoadIfNeeded()
        guard let source = effectiveSnapshotForSavedRequest(id: id) else { return }
        duplicateSavedRequest(snapshot: source)
    }

    func revertSavedRequestDraft(id: UUID) {
        markLocalMutationDuringInitialLoadIfNeeded()
        guard let requestLibrary else { return }
        guard let saved = savedRequestsByID[id] else { return }
        draftsByRequestID[id] = nil
        if selectedContext == .saved, selectedSavedRequestID == id {
            state.workspaceRequest = saved.request
            state.workspaceName = saved.name
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
            nameWasManuallyEdited: false
        )
        savedRequestsByID[duplicate.id] = duplicate
        selectedSavedRequestID = duplicate.id
        selectedContext = .saved
        state.workspaceRequest = duplicate.request
        state.workspaceName = duplicate.name
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

    private func startExecution(using request: Request) {
        guard currentRunTask == nil, state.executionState != .running else {
            return
        }

        guard request.isMinimallyValid else {
            state.executionState = .failed
            setInlineError(request.lightweightValidationMessage ?? "The request is not runnable yet.")
            return
        }

        state.executionState = .running
        clearInlineMessage()
        state.lastExecutedRequest = LastExecutedRequest(request: request)
        let previousResponseMode = state.visibleResponseState?.selectedMode
        let runningRequestID = selectedSavedRequestID

        currentRunTask = Task { [requestExecutor, responseFormatter] in
            do {
                let executedResponse = try await requestExecutor.execute(request)
                let formattedResponse = await responseFormatter.format(executedResponse)
                await MainActor.run {
                    var visibleResponseState = formattedResponse
                    if let previousResponseMode, previousResponseMode == .raw || visibleResponseState.body.jsonValue != nil {
                        visibleResponseState.selectedMode = previousResponseMode
                    }
                    visibleResponseState.isStale = self.state.workspaceRequest != request
                    
                    let execState = RequestExecutionState(
                        lastExecutedRequest: LastExecutedRequest(request: request),
                        executionState: .succeeded,
                        visibleResponseState: visibleResponseState
                    )
                    
                    if let runningRequestID {
                        self.executionStatesByRequestID[runningRequestID] = execState
                    }
                    
                    if self.selectedSavedRequestID == runningRequestID {
                        self.state.visibleResponseState = visibleResponseState
                        self.state.executionState = .succeeded
                        self.clearInlineMessage()
                    }
                    
                    if let runningRequestID {
                        self.recordExecutionSummary(
                            for: runningRequestID,
                            statusCode: executedResponse.statusCode,
                            duration: executedResponse.duration,
                            sizeBytes: executedResponse.bodyData.count
                        )
                    }
                    self.currentRunTask = nil
                }
            } catch let error as ExecutionError {
                await MainActor.run {
                    let execState = RequestExecutionState(
                        lastExecutedRequest: LastExecutedRequest(request: request),
                        executionState: .failed,
                        visibleResponseState: nil
                    )
                    if let runningRequestID {
                        self.executionStatesByRequestID[runningRequestID] = execState
                    }
                    
                    if self.selectedSavedRequestID == runningRequestID {
                        self.state.executionState = .failed
                        self.setInlineError(error.localizedDescription)
                    }
                    self.currentRunTask = nil
                }
            } catch {
                await MainActor.run {
                    let execState = RequestExecutionState(
                        lastExecutedRequest: LastExecutedRequest(request: request),
                        executionState: .failed,
                        visibleResponseState: nil
                    )
                    if let runningRequestID {
                        self.executionStatesByRequestID[runningRequestID] = execState
                    }
                    
                    if self.selectedSavedRequestID == runningRequestID {
                        self.state.executionState = .failed
                        self.setInlineError(error.localizedDescription)
                    }
                    self.currentRunTask = nil
                }
            }
        }
    }

    private func markResultStaleIfNeeded() {
        guard var visibleResponseState = state.visibleResponseState else {
            return
        }

        visibleResponseState.isStale = true
        state.visibleResponseState = visibleResponseState
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
            for request in savedList {
                if let draft = try await requestLibrary.drafts.draft(for: request.id) {
                    loadedDrafts[request.id] = draft
                }
                if let summary = try await requestLibrary.summaries.summary(for: request.id) {
                    summariesByRequestID[request.id] = summary
                }
            }
            let hiddenDraft = try await requestLibrary.hiddenDraft.hiddenDraft()
            let selection = try await requestLibrary.selection.selection()
            await MainActor.run {
                if self.didCompleteInitialLibraryLoad {
                    return
                }
                if self.hasLocalLibraryMutationsBeforeInitialLoad {
                    self.didCompleteInitialLibraryLoad = true
                    self.refreshRequestListPresentation()
                    return
                }
                self.savedRequestsByID = Dictionary(uniqueKeysWithValues: savedList.map { ($0.id, $0) })
                self.draftsByRequestID = loadedDrafts
                self.hiddenNewDraft = hiddenDraft
                self.restoreSelection(selection)
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

    private func markLocalMutationDuringInitialLoadIfNeeded() {
        guard requestLibrary != nil, !didCompleteInitialLibraryLoad else {
            return
        }
        hasLocalLibraryMutationsBeforeInitialLoad = true
    }

    private func restoreSelection(_ persisted: SessionSelection?) {
        state.isLibraryCollapsed = persisted?.isLibraryCollapsed ?? state.isLibraryCollapsed

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
        return EditableRequestSnapshot(name: saved.name, request: saved.request)
    }

    private func applySelectedRequestSnapshot() {
        switch selectedContext {
        case .saved:
            guard let selectedSavedRequestID,
                  let snapshot = effectiveSnapshotForSavedRequest(id: selectedSavedRequestID) else { return }
            state.workspaceRequest = snapshot.request
            state.workspaceName = snapshot.name
            state.requestEditorExpansion = .allExpanded
        case .hiddenNewDraft:
            let snapshot = hiddenNewDraft?.snapshot ?? EditableRequestSnapshot(name: "Untitled Request", request: .empty)
            state.workspaceRequest = snapshot.request
            state.workspaceName = snapshot.name
            state.requestEditorExpansion = .allExpanded
        }
    }

    private func persistSelectionState() {
        guard let requestLibrary else { return }
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

    private func persistDraftStateAfterEdit() {
        guard let requestLibrary else {
            refreshRequestListPresentation()
            return
        }
        let snapshot = EditableRequestSnapshot(name: normalizedWorkspaceName(), request: state.workspaceRequest)
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
                isDirty = draft.snapshot.name != saved.name || draft.snapshot.request != saved.request
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
                return draft.snapshot.name != saved.name || draft.snapshot.request != saved.request
            }
            return false
        case .hiddenNewDraft:
            return !state.workspaceRequest.isEffectivelyEmpty || !state.workspaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func currentSaveEnabled() -> Bool {
        switch selectedContext {
        case .saved:
            return state.isCurrentRequestDirty
        case .hiddenNewDraft:
            return !state.workspaceRequest.isEffectivelyEmpty
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
                Task { @MainActor in
                    self?.pendingPersistenceTasks[taskID] = nil
                }
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
            visibleResponseState: state.visibleResponseState
        )
    }

    private func loadCachedResponseState(for id: UUID) {
        let cached = executionStatesByRequestID[id] ?? RequestExecutionState(
            lastExecutedRequest: nil,
            executionState: .idle,
            visibleResponseState: nil
        )
        state.lastExecutedRequest = cached.lastExecutedRequest
        state.executionState = cached.executionState
        state.visibleResponseState = cached.visibleResponseState
    }
}
