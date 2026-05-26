import XCTest
@testable import Curly

final class RequestLibraryPersistenceTests: XCTestCase {
    func testSavedRequestListIsOrderedByLastEditedDescending() async throws {
        let repository = InMemorySavedRequestRepository()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let oldest = SavedRequest(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "Old",
            request: Request(method: .get, urlString: "https://old.example.com", headers: [], body: .none),
            createdAt: now,
            updatedAt: now,
            lastEditedAt: now.addingTimeInterval(-300),
            nameWasManuallyEdited: false
        )
        let newest = SavedRequest(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            name: "New",
            request: Request(method: .post, urlString: "https://new.example.com", headers: [], body: .none),
            createdAt: now,
            updatedAt: now,
            lastEditedAt: now.addingTimeInterval(200),
            nameWasManuallyEdited: false
        )

        try await repository.upsert(oldest)
        try await repository.upsert(newest)

        let list = try await repository.list()
        XCTAssertEqual(list.map(\.id), [newest.id, oldest.id])
    }

    func testRequestDraftCRUDAndDirtyIDs() async throws {
        let repository = InMemoryRequestDraftRepository()
        let requestID = UUID()
        let baseDate = Date(timeIntervalSince1970: 1_700_000_100)
        let snapshot = EditableRequestSnapshot(
            name: "Users",
            request: Request(method: .get, urlString: "https://example.com/users", headers: [], body: .none)
        )
        let draft = RequestDraft(
            requestID: requestID,
            snapshot: snapshot,
            lastEditedAt: baseDate,
            baseSavedUpdatedAt: baseDate,
            draftBaseOutdated: false
        )

        try await repository.saveDraft(draft)
        let loadedDraft = try await repository.draft(for: requestID)
        let dirtyIDs = try await repository.listDirtyRequestIDs()
        XCTAssertEqual(loadedDraft, draft)
        XCTAssertEqual(dirtyIDs, Set([requestID]))

        try await repository.deleteDraft(for: requestID)
        let deletedDraft = try await repository.draft(for: requestID)
        let dirtyAfterDelete = try await repository.listDirtyRequestIDs()
        XCTAssertNil(deletedDraft)
        XCTAssertEqual(dirtyAfterDelete, [])
    }

    func testHiddenNewDraftRepositoryKeepsSingleRecord() async throws {
        let repository = InMemoryHiddenNewDraftRepository()
        let baseDate = Date(timeIntervalSince1970: 1_700_000_200)
        let first = HiddenNewDraft(
            id: UUID(),
            snapshot: EditableRequestSnapshot(
                name: "First",
                request: Request(method: .get, urlString: "https://first.example.com", headers: [], body: .none)
            ),
            nameWasManuallyEdited: false,
            lastEditedAt: baseDate
        )
        let second = HiddenNewDraft(
            id: UUID(),
            snapshot: EditableRequestSnapshot(
                name: "Second",
                request: Request(method: .post, urlString: "https://second.example.com", headers: [], body: .text("{}"))
            ),
            nameWasManuallyEdited: true,
            lastEditedAt: baseDate.addingTimeInterval(10)
        )

        try await repository.saveHiddenDraft(first)
        try await repository.saveHiddenDraft(second)

        let loaded = try await repository.hiddenDraft()
        XCTAssertEqual(loaded, second)

        try await repository.deleteHiddenDraft()
        let deleted = try await repository.hiddenDraft()
        XCTAssertNil(deleted)
    }

    func testExecutionSummaryCRUD() async throws {
        let repository = InMemoryExecutionSummaryRepository()
        let requestID = UUID()
        let summary = ExecutionSummary(
            requestID: requestID,
            statusCode: 204,
            durationMs: 12,
            sizeBytes: 120,
            lastRunAt: Date(timeIntervalSince1970: 1_700_000_300),
            lastRunSource: .draft
        )

        try await repository.saveSummary(summary)
        let loadedSummary = try await repository.summary(for: requestID)
        XCTAssertEqual(loadedSummary, summary)

        try await repository.deleteSummary(for: requestID)
        let deletedSummary = try await repository.summary(for: requestID)
        XCTAssertNil(deletedSummary)
    }

    func testSessionSelectionCRUD() async throws {
        let repository = InMemorySessionSelectionRepository()
        let selection = SessionSelection(
            selectedSavedRequestID: UUID(),
            selectedContext: .saved,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_400)
        )

        try await repository.saveSelection(selection)
        let loadedSelection = try await repository.selection()
        XCTAssertEqual(loadedSelection, selection)
    }

    func testFacadeDeleteRemovesSavedRequestAndAssociatedDraftAndSummary() async throws {
        let savedRepository = InMemorySavedRequestRepository()
        let draftRepository = InMemoryRequestDraftRepository()
        let summaryRepository = InMemoryExecutionSummaryRepository()
        let facade = InMemoryWorkspaceRepositoryFacade(
            savedRequests: savedRepository,
            drafts: draftRepository,
            summaries: summaryRepository
        )

        let requestID = UUID()
        let timestamp = Date(timeIntervalSince1970: 1_700_000_500)
        let saved = SavedRequest(
            id: requestID,
            name: "Delete Me",
            request: Request(method: .get, urlString: "https://delete.example.com", headers: [], body: .none),
            createdAt: timestamp,
            updatedAt: timestamp,
            lastEditedAt: timestamp,
            nameWasManuallyEdited: false
        )
        let draft = RequestDraft(
            requestID: requestID,
            snapshot: EditableRequestSnapshot(name: saved.name, request: saved.request),
            lastEditedAt: timestamp,
            baseSavedUpdatedAt: timestamp,
            draftBaseOutdated: false
        )
        let summary = ExecutionSummary(
            requestID: requestID,
            statusCode: 200,
            durationMs: 1,
            sizeBytes: 1,
            lastRunAt: timestamp,
            lastRunSource: .saved
        )

        try await savedRepository.upsert(saved)
        try await draftRepository.saveDraft(draft)
        try await summaryRepository.saveSummary(summary)

        try await facade.deleteSavedRequestAndRelatedState(id: requestID)

        let savedAfterDelete = try await savedRepository.get(id: requestID)
        let draftAfterDelete = try await draftRepository.draft(for: requestID)
        let summaryAfterDelete = try await summaryRepository.summary(for: requestID)
        XCTAssertNil(savedAfterDelete)
        XCTAssertNil(draftAfterDelete)
        XCTAssertNil(summaryAfterDelete)
    }

    func testFileStoreMigrationMergesLegacyRequestsAndDropsGeneratedPlaceholder() throws {
        let placeholder = SavedRequest(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
            name: "New Request",
            request: Request(method: .get, urlString: "", headers: [], body: .none),
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 10),
            lastEditedAt: Date(timeIntervalSince1970: 10),
            nameWasManuallyEdited: false
        )
        let legacyRequest = SavedRequest(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000020")!,
            name: "Users",
            request: Request(method: .get, urlString: "https://example.com/users", headers: [], body: .none),
            createdAt: Date(timeIntervalSince1970: 20),
            updatedAt: Date(timeIntervalSince1970: 20),
            lastEditedAt: Date(timeIntervalSince1970: 20),
            nameWasManuallyEdited: true
        )
        let primary = FileRequestLibraryContainer(
            savedRequests: [placeholder],
            drafts: [],
            hiddenNewDraft: nil,
            summaries: [],
            sessionSelection: nil
        )
        let legacy = FileRequestLibraryContainer(
            savedRequests: [legacyRequest],
            drafts: [],
            hiddenNewDraft: nil,
            summaries: [],
            sessionSelection: nil
        )

        let merged = FileRequestLibraryRepositories.mergeForMigration(primary: primary, legacy: legacy)

        XCTAssertEqual(merged.savedRequests, [legacyRequest])
    }

    func testFileStoreMigrationKeepsNewerSavedRequestOnConflict() throws {
        let requestID = UUID(uuidString: "00000000-0000-0000-0000-000000000030")!
        let older = SavedRequest(
            id: requestID,
            name: "Older",
            request: Request(method: .get, urlString: "https://old.example.com", headers: [], body: .none),
            createdAt: Date(timeIntervalSince1970: 30),
            updatedAt: Date(timeIntervalSince1970: 30),
            lastEditedAt: Date(timeIntervalSince1970: 30),
            nameWasManuallyEdited: true
        )
        let newer = SavedRequest(
            id: requestID,
            name: "Newer",
            request: Request(method: .post, urlString: "https://new.example.com", headers: [], body: .text("{}")),
            createdAt: Date(timeIntervalSince1970: 30),
            updatedAt: Date(timeIntervalSince1970: 40),
            lastEditedAt: Date(timeIntervalSince1970: 40),
            nameWasManuallyEdited: true
        )
        let primary = FileRequestLibraryContainer(
            savedRequests: [newer],
            drafts: [],
            hiddenNewDraft: nil,
            summaries: [],
            sessionSelection: nil
        )
        let legacy = FileRequestLibraryContainer(
            savedRequests: [older],
            drafts: [],
            hiddenNewDraft: nil,
            summaries: [],
            sessionSelection: nil
        )

        let merged = FileRequestLibraryRepositories.mergeForMigration(primary: primary, legacy: legacy)

        XCTAssertEqual(merged.savedRequests, [newer])
    }
}
