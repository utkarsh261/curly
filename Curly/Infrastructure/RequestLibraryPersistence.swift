import Foundation

protocol SavedRequestRepository: Sendable {
    func list() async throws -> [SavedRequest]
    func get(id: UUID) async throws -> SavedRequest?
    func upsert(_ request: SavedRequest) async throws
    func delete(id: UUID) async throws
}

protocol RequestDraftRepository: Sendable {
    func draft(for requestID: UUID) async throws -> RequestDraft?
    func saveDraft(_ draft: RequestDraft) async throws
    func deleteDraft(for requestID: UUID) async throws
    func listDirtyRequestIDs() async throws -> Set<UUID>
}

protocol HiddenNewDraftRepository: Sendable {
    func hiddenDraft() async throws -> HiddenNewDraft?
    func saveHiddenDraft(_ draft: HiddenNewDraft) async throws
    func deleteHiddenDraft() async throws
}

protocol ExecutionSummaryRepository: Sendable {
    func summary(for requestID: UUID) async throws -> ExecutionSummary?
    func saveSummary(_ summary: ExecutionSummary) async throws
    func deleteSummary(for requestID: UUID) async throws
}

protocol SessionSelectionRepository: Sendable {
    func selection() async throws -> SessionSelection?
    func saveSelection(_ selection: SessionSelection) async throws
}

protocol WorkspaceRepositoryFacade: Sendable {
    func deleteSavedRequestAndRelatedState(id: UUID) async throws
}

protocol VariableRepository: Sendable {
    func listVariables() async throws -> [Variable]
    func saveVariable(_ variable: Variable) async throws
    func deleteVariable(id: UUID) async throws
    func deleteVariables(forRequestID requestID: UUID) async throws
    func migrateVariables(from oldRequestID: UUID, to newRequestID: UUID) async throws
}
