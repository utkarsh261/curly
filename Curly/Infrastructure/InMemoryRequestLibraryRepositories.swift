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

actor InMemoryVariableRepository: VariableRepository {
    private var variablesByID: [UUID: Variable] = [:]

    func listVariables() async throws -> [Variable] {
        variablesByID.values.sorted {
            if $0.createdAt == $1.createdAt {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.createdAt < $1.createdAt
        }
    }

    func saveVariable(_ variable: Variable) async throws {
        variablesByID[variable.id] = variable
    }

    func deleteVariable(id: UUID) async throws {
        variablesByID[id] = nil
    }

    func deleteVariables(forRequestID requestID: UUID) async throws {
        variablesByID = variablesByID.filter { _, variable in
            !(variable.scope == .request && variable.requestID == requestID)
        }
    }

    func migrateVariables(from oldRequestID: UUID, to newRequestID: UUID) async throws {
        for (id, variable) in variablesByID where variable.scope == .request && variable.requestID == oldRequestID {
            var migrated = variable
            migrated.requestID = newRequestID
            variablesByID[id] = migrated
        }
    }

    func applyVariableBatch(_ batch: VariableBatch) async throws -> VariableBatchCommit {
        var candidate = variablesByID
        var changed: [Variable] = []

        for mutation in batch.mutations {
            if let existing = candidate.values.first(where: { $0.name == mutation.name }) {
                guard existing.scope == mutation.scope,
                      existing.requestID == mutation.requestID else {
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
        return VariableBatchCommit(changedVariables: changed)
    }
}

enum VariableBatchError: LocalizedError, Equatable {
    case scopeConflict(String)
    case missingRequestOwner

    var errorDescription: String? {
        switch self {
        case .scopeConflict(let name):
            return "Variable \(name) already exists in another scope."
        case .missingRequestOwner:
            return "A request-scoped variable needs a saved request or draft."
        }
    }
}

struct InMemoryWorkspaceRepositoryFacade: WorkspaceRepositoryFacade {
    let savedRequests: SavedRequestRepository
    let drafts: RequestDraftRepository
    let summaries: ExecutionSummaryRepository
    var variables: VariableRepository? = nil

    func deleteSavedRequestAndRelatedState(id: UUID) async throws {
        try await savedRequests.delete(id: id)
        try await drafts.deleteDraft(for: id)
        try await summaries.deleteSummary(for: id)
        try await variables?.deleteVariables(forRequestID: id)
    }
}
