import AppKit
import Foundation

@MainActor
final class SessionCoordinator: ObservableObject {
    private let curlImporter: CurlImporting
    private let requestExecutor: RequestExecuting
    private let responseFormatter: ResponseFormatting
    private var currentRunTask: Task<Void, Never>?

    @Published private(set) var state: SessionState = .initial

    init(
        initialState: SessionState = .initial,
        curlImporter: CurlImporting = SimpleCurlImporter(),
        requestExecutor: RequestExecuting = URLSessionRequestExecutor(),
        responseFormatter: ResponseFormatting = DefaultResponseFormatter()
    ) {
        self.state = initialState
        self.curlImporter = curlImporter
        self.requestExecutor = requestExecutor
        self.responseFormatter = responseFormatter
    }

    func newWorkspace() {
        currentRunTask?.cancel()
        currentRunTask = nil
        state.workspaceRequest = .empty
        state.lastExecutedRequest = nil
        state.executionState = .idle
        state.visibleResponseState = nil
        state.replaceConfirmationState = nil
        clearInlineMessage()
    }

    func setWindowVisible(_ isVisible: Bool) {
        state.isWindowVisible = isVisible
    }

    func requestWindowOpen() {
        state.isWindowVisible = true
    }

    func setMethod(_ method: HTTPMethod) {
        state.workspaceRequest.method = method
        clearInlineMessage()
        markResultStaleIfNeeded()
    }

    func setURL(_ url: String) {
        state.workspaceRequest.urlString = url
        clearInlineMessage()
        markResultStaleIfNeeded()
    }

    func handleURLBarTextChange(_ text: String) {
        setURL(text)
    }

    func setBody(_ text: String) {
        state.workspaceRequest.body = text.isEmpty ? .none : .text(text)
        clearInlineMessage()
        markResultStaleIfNeeded()
    }

    func addHeader() {
        state.workspaceRequest.headers.append(Header())
        clearInlineMessage()
        markResultStaleIfNeeded()
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
    }

    func removeHeader(id: UUID) {
        state.workspaceRequest.headers.removeAll { $0.id == id }
        clearInlineMessage()
        markResultStaleIfNeeded()
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
        guard trimmed.hasPrefix("curl ") else {
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

        currentRunTask = Task { [requestExecutor, responseFormatter] in
            do {
                let executedResponse = try await requestExecutor.execute(request)
                let formattedResponse = await responseFormatter.format(executedResponse)
                await MainActor.run {
                    var visibleResponseState = formattedResponse
                    visibleResponseState.isStale = self.state.workspaceRequest != request
                    self.state.visibleResponseState = visibleResponseState
                    self.state.executionState = .succeeded
                    self.clearInlineMessage()
                    self.currentRunTask = nil
                }
            } catch let error as ExecutionError {
                await MainActor.run {
                    self.state.executionState = .failed
                    self.setInlineError(error.localizedDescription)
                    self.currentRunTask = nil
                }
            } catch {
                await MainActor.run {
                    self.state.executionState = .failed
                    self.setInlineError(error.localizedDescription)
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
        markResultStaleIfNeeded()
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
}
