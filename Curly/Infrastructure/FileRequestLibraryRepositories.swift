import Foundation

struct FileRequestLibraryContainer: Codable, Equatable {
    var savedRequests: [SavedRequest]
    var drafts: [RequestDraft]
    var hiddenNewDraft: HiddenNewDraft?
    var summaries: [ExecutionSummary]
    var sessionSelection: SessionSelection?
    var variables: [Variable]

    init(
        savedRequests: [SavedRequest],
        drafts: [RequestDraft],
        hiddenNewDraft: HiddenNewDraft?,
        summaries: [ExecutionSummary],
        sessionSelection: SessionSelection?,
        variables: [Variable] = []
    ) {
        self.savedRequests = savedRequests
        self.drafts = drafts
        self.hiddenNewDraft = hiddenNewDraft
        self.summaries = summaries
        self.sessionSelection = sessionSelection
        self.variables = variables
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.savedRequests = try container.decodeIfPresent([SavedRequest].self, forKey: .savedRequests) ?? []
        self.drafts = try container.decodeIfPresent([RequestDraft].self, forKey: .drafts) ?? []
        self.hiddenNewDraft = try container.decodeIfPresent(HiddenNewDraft.self, forKey: .hiddenNewDraft)
        self.summaries = try container.decodeIfPresent([ExecutionSummary].self, forKey: .summaries) ?? []
        self.sessionSelection = try container.decodeIfPresent(SessionSelection.self, forKey: .sessionSelection)
        self.variables = try container.decodeIfPresent([Variable].self, forKey: .variables) ?? []
    }
}

actor FileRequestLibraryRepositories: SavedRequestRepository, RequestDraftRepository, HiddenNewDraftRepository, ExecutionSummaryRepository, SessionSelectionRepository, WorkspaceRepositoryFacade, VariableRepository {
    private let fileURL: URL
    private var container: FileRequestLibraryContainer
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileURL: URL) throws {
        self.fileURL = fileURL
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.encoder.dateEncodingStrategy = .millisecondsSince1970
        self.decoder.dateDecodingStrategy = .millisecondsSince1970
        self.container = FileRequestLibraryContainer(savedRequests: [], drafts: [], hiddenNewDraft: nil, summaries: [], sessionSelection: nil)
        try Self.ensureParentDirectoryExists(for: fileURL)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            if !data.isEmpty {
                self.container = try decoder.decode(FileRequestLibraryContainer.self, from: data)
            }
        } else {
            let data = try encoder.encode(container)
            try data.write(to: fileURL, options: .atomic)
        }
    }

    static func defaultFileURL() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let folder = appSupport.appendingPathComponent("Curly", isDirectory: true)
        if !FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let fileURL = folder.appendingPathComponent("request-library.json")
        try migrateLegacyStoreIfNeeded(to: fileURL)
        return fileURL
    }

    static func mergeForMigration(
        primary: FileRequestLibraryContainer,
        legacy: FileRequestLibraryContainer
    ) -> FileRequestLibraryContainer {
        var merged = primary

        for savedRequest in legacy.savedRequests {
            if let index = merged.savedRequests.firstIndex(where: { $0.id == savedRequest.id }) {
                let existing = merged.savedRequests[index]
                if savedRequest.lastEditedAt > existing.lastEditedAt || savedRequest.updatedAt > existing.updatedAt {
                    merged.savedRequests[index] = savedRequest
                }
            } else {
                merged.savedRequests.append(savedRequest)
            }
        }

        for draft in legacy.drafts {
            if let index = merged.drafts.firstIndex(where: { $0.requestID == draft.requestID }) {
                if draft.lastEditedAt > merged.drafts[index].lastEditedAt {
                    merged.drafts[index] = draft
                }
            } else {
                merged.drafts.append(draft)
            }
        }

        if let legacyHiddenDraft = legacy.hiddenNewDraft {
            if let currentHiddenDraft = merged.hiddenNewDraft {
                if legacyHiddenDraft.lastEditedAt > currentHiddenDraft.lastEditedAt {
                    merged.hiddenNewDraft = legacyHiddenDraft
                }
            } else {
                merged.hiddenNewDraft = legacyHiddenDraft
            }
        }

        for summary in legacy.summaries {
            if let index = merged.summaries.firstIndex(where: { $0.requestID == summary.requestID }) {
                if summary.isNewer(than: merged.summaries[index]) {
                    merged.summaries[index] = summary
                }
            } else {
                merged.summaries.append(summary)
            }
        }

        for variable in legacy.variables {
            if let index = merged.variables.firstIndex(where: { $0.id == variable.id }) {
                if variable.updatedAt > merged.variables[index].updatedAt {
                    merged.variables[index] = variable
                }
            } else {
                merged.variables.append(variable)
            }
        }

        if let legacySelection = legacy.sessionSelection {
            if let currentSelection = merged.sessionSelection {
                if legacySelection.updatedAt > currentSelection.updatedAt {
                    merged.sessionSelection = legacySelection
                }
            } else {
                merged.sessionSelection = legacySelection
            }
        }

        let realSavedRequests = merged.savedRequests.filter { !$0.isGeneratedPlaceholder }
        if !realSavedRequests.isEmpty {
            merged.savedRequests = realSavedRequests
        }

        merged.savedRequests.sort {
            if $0.lastEditedAt == $1.lastEditedAt {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.lastEditedAt > $1.lastEditedAt
        }
        merged.drafts.sort { $0.requestID.uuidString < $1.requestID.uuidString }
        merged.summaries.sort { $0.requestID.uuidString < $1.requestID.uuidString }
        merged.variables.sort {
            if $0.createdAt == $1.createdAt {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.createdAt < $1.createdAt
        }

        return merged
    }

    private static func ensureParentDirectoryExists(for fileURL: URL) throws {
        let directory = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    private static func migrateLegacyStoreIfNeeded(to primaryURL: URL) throws {
        let legacyURLs = legacyStoreURLs(excluding: primaryURL)
        guard !legacyURLs.isEmpty else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970

        var primary = try loadContainerIfPresent(at: primaryURL, decoder: decoder)
            ?? FileRequestLibraryContainer(savedRequests: [], drafts: [], hiddenNewDraft: nil, summaries: [], sessionSelection: nil)
        let originalPrimary = primary

        for legacyURL in legacyURLs {
            guard let legacy = try? loadContainerIfPresent(at: legacyURL, decoder: decoder) else {
                continue
            }
            primary = mergeForMigration(primary: primary, legacy: legacy)
        }

        guard primary != originalPrimary else { return }
        try ensureParentDirectoryExists(for: primaryURL)
        let data = try encoder.encode(primary)
        try data.write(to: primaryURL, options: .atomic)
    }

    private static func legacyStoreURLs(excluding primaryURL: URL) -> [URL] {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            return []
        }

        let homeURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let candidates = [
            homeURL
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Containers", isDirectory: true)
                .appendingPathComponent(bundleIdentifier, isDirectory: true)
                .appendingPathComponent("Data", isDirectory: true)
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("Curly", isDirectory: true)
                .appendingPathComponent("request-library.json"),
            homeURL
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("Curly", isDirectory: true)
                .appendingPathComponent("request-library.json")
        ]

        let primaryPath = primaryURL.standardizedFileURL.path
        return candidates.filter { $0.standardizedFileURL.path != primaryPath }
    }

    private static func loadContainerIfPresent(at fileURL: URL, decoder: JSONDecoder) throws -> FileRequestLibraryContainer? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else {
            return nil
        }
        return try decoder.decode(FileRequestLibraryContainer.self, from: data)
    }

    private func persist() throws {
        let data = try encoder.encode(container)
        try data.write(to: fileURL, options: .atomic)
    }

    func list() async throws -> [SavedRequest] {
        container.savedRequests.sorted {
            if $0.lastEditedAt == $1.lastEditedAt {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.lastEditedAt > $1.lastEditedAt
        }
    }

    func get(id: UUID) async throws -> SavedRequest? {
        container.savedRequests.first(where: { $0.id == id })
    }

    func upsert(_ request: SavedRequest) async throws {
        if let index = container.savedRequests.firstIndex(where: { $0.id == request.id }) {
            container.savedRequests[index] = request
        } else {
            container.savedRequests.append(request)
        }
        try persist()
    }

    func delete(id: UUID) async throws {
        container.savedRequests.removeAll { $0.id == id }
        container.drafts.removeAll { $0.requestID == id }
        container.summaries.removeAll { $0.requestID == id }
        container.variables.removeAll { $0.scope == .request && $0.requestID == id }
        if container.sessionSelection?.selectedSavedRequestID == id {
            container.sessionSelection = nil
        }
        try persist()
    }

    func draft(for requestID: UUID) async throws -> RequestDraft? {
        container.drafts.first(where: { $0.requestID == requestID })
    }

    func saveDraft(_ draft: RequestDraft) async throws {
        if let index = container.drafts.firstIndex(where: { $0.requestID == draft.requestID }) {
            container.drafts[index] = draft
        } else {
            container.drafts.append(draft)
        }
        try persist()
    }

    func deleteDraft(for requestID: UUID) async throws {
        container.drafts.removeAll { $0.requestID == requestID }
        try persist()
    }

    func listDirtyRequestIDs() async throws -> Set<UUID> {
        Set(container.drafts.map(\.requestID))
    }

    func hiddenDraft() async throws -> HiddenNewDraft? {
        container.hiddenNewDraft
    }

    func saveHiddenDraft(_ draft: HiddenNewDraft) async throws {
        container.hiddenNewDraft = draft
        try persist()
    }

    func deleteHiddenDraft() async throws {
        container.hiddenNewDraft = nil
        try persist()
    }

    func summary(for requestID: UUID) async throws -> ExecutionSummary? {
        container.summaries.first(where: { $0.requestID == requestID })
    }

    func saveSummary(_ summary: ExecutionSummary) async throws {
        if let index = container.summaries.firstIndex(where: { $0.requestID == summary.requestID }) {
            container.summaries[index] = summary
        } else {
            container.summaries.append(summary)
        }
        try persist()
    }

    func deleteSummary(for requestID: UUID) async throws {
        container.summaries.removeAll { $0.requestID == requestID }
        try persist()
    }

    func selection() async throws -> SessionSelection? {
        container.sessionSelection
    }

    func saveSelection(_ selection: SessionSelection) async throws {
        container.sessionSelection = selection
        try persist()
    }

    func deleteSavedRequestAndRelatedState(id: UUID) async throws {
        try await delete(id: id)
    }

    func listVariables() async throws -> [Variable] {
        container.variables.sorted {
            if $0.createdAt == $1.createdAt {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.createdAt < $1.createdAt
        }
    }

    func saveVariable(_ variable: Variable) async throws {
        if let index = container.variables.firstIndex(where: { $0.id == variable.id }) {
            container.variables[index] = variable
        } else {
            container.variables.append(variable)
        }
        try persist()
    }

    func deleteVariable(id: UUID) async throws {
        container.variables.removeAll { $0.id == id }
        try persist()
    }

    func deleteVariables(forRequestID requestID: UUID) async throws {
        container.variables.removeAll { $0.scope == .request && $0.requestID == requestID }
        try persist()
    }

    func migrateVariables(from oldRequestID: UUID, to newRequestID: UUID) async throws {
        for index in container.variables.indices where container.variables[index].scope == .request && container.variables[index].requestID == oldRequestID {
            container.variables[index].requestID = newRequestID
        }
        try persist()
    }

    func applyVariableBatch(_ batch: VariableBatch) async throws -> VariableBatchCommit {
        var candidate = container
        var changed: [Variable] = []

        for mutation in batch.mutations {
            if let index = candidate.variables.firstIndex(where: { $0.name == mutation.name }) {
                let existing = candidate.variables[index]
                guard existing.scope == mutation.scope,
                      existing.requestID == mutation.requestID else {
                    throw VariableBatchError.scopeConflict(mutation.name)
                }
                guard existing.value != mutation.value else { continue }
                var updated = existing
                updated.value = mutation.value
                updated.updatedAt = batch.committedAt
                candidate.variables[index] = updated
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
                candidate.variables.append(created)
                changed.append(created)
            }
        }

        let data = try encoder.encode(candidate)
        try data.write(to: fileURL, options: .atomic)
        container = candidate
        return VariableBatchCommit(changedVariables: changed)
    }
}

private extension ExecutionSummary {
    func isNewer(than other: ExecutionSummary) -> Bool {
        switch (lastRunAt, other.lastRunAt) {
        case let (current?, previous?):
            return current > previous
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            return false
        }
    }
}

private extension SavedRequest {
    var isGeneratedPlaceholder: Bool {
        name == "New Request"
            && request.method == .get
            && request.urlString.isEmpty
            && request.headers.isEmpty
            && request.body == .none
            && !nameWasManuallyEdited
    }
}
