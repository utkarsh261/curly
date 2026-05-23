import Foundation

struct FileRequestLibraryContainer: Codable {
    var savedRequests: [SavedRequest]
    var drafts: [RequestDraft]
    var hiddenNewDraft: HiddenNewDraft?
    var summaries: [ExecutionSummary]
    var sessionSelection: SessionSelection?
}

actor FileRequestLibraryRepositories: SavedRequestRepository, RequestDraftRepository, HiddenNewDraftRepository, ExecutionSummaryRepository, SessionSelectionRepository, WorkspaceRepositoryFacade {
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
        return folder.appendingPathComponent("request-library.json")
    }

    private static func ensureParentDirectoryExists(for fileURL: URL) throws {
        let directory = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
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
}
