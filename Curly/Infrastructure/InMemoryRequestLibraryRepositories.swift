import Foundation

actor InMemorySavedRequestRepository: SavedRequestRepository {
    private var requestsByID: [UUID: SavedRequest] = [:]

    func list() async throws -> [SavedRequest] {
        requestsByID.values.sorted {
            if $0.lastEditedAt == $1.lastEditedAt {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.lastEditedAt > $1.lastEditedAt
        }
    }

    func get(id: UUID) async throws -> SavedRequest? {
        requestsByID[id]
    }

    func upsert(_ request: SavedRequest) async throws {
        requestsByID[request.id] = request
    }

    func delete(id: UUID) async throws {
        requestsByID[id] = nil
    }
}

actor InMemoryRequestDraftRepository: RequestDraftRepository {
    private var draftsByRequestID: [UUID: RequestDraft] = [:]

    func draft(for requestID: UUID) async throws -> RequestDraft? {
        draftsByRequestID[requestID]
    }

    func saveDraft(_ draft: RequestDraft) async throws {
        draftsByRequestID[draft.requestID] = draft
    }

    func deleteDraft(for requestID: UUID) async throws {
        draftsByRequestID[requestID] = nil
    }

    func listDirtyRequestIDs() async throws -> Set<UUID> {
        Set(draftsByRequestID.keys)
    }
}

actor InMemoryHiddenNewDraftRepository: HiddenNewDraftRepository {
    private var draft: HiddenNewDraft?

    func hiddenDraft() async throws -> HiddenNewDraft? {
        draft
    }

    func saveHiddenDraft(_ draft: HiddenNewDraft) async throws {
        self.draft = draft
    }

    func deleteHiddenDraft() async throws {
        draft = nil
    }
}

actor InMemoryExecutionSummaryRepository: ExecutionSummaryRepository {
    private var summariesByRequestID: [UUID: ExecutionSummary] = [:]

    func summary(for requestID: UUID) async throws -> ExecutionSummary? {
        summariesByRequestID[requestID]
    }

    func saveSummary(_ summary: ExecutionSummary) async throws {
        summariesByRequestID[summary.requestID] = summary
    }

    func deleteSummary(for requestID: UUID) async throws {
        summariesByRequestID[requestID] = nil
    }
}

actor InMemorySessionSelectionRepository: SessionSelectionRepository {
    private var selection: SessionSelection?

    func selection() async throws -> SessionSelection? {
        selection
    }

    func saveSelection(_ selection: SessionSelection) async throws {
        self.selection = selection
    }
}

struct InMemoryWorkspaceRepositoryFacade: WorkspaceRepositoryFacade {
    let savedRequests: SavedRequestRepository
    let drafts: RequestDraftRepository
    let summaries: ExecutionSummaryRepository

    func deleteSavedRequestAndRelatedState(id: UUID) async throws {
        try await savedRequests.delete(id: id)
        try await drafts.deleteDraft(for: id)
        try await summaries.deleteSummary(for: id)
    }
}
