import XCTest
@testable import Curly

@MainActor
final class RequestLibraryCoordinatorTests: XCTestCase {
    func testSavingInvalidHiddenDraftCreatesSavedRequestButRunRemainsBlocked() async {
        let coordinator = makeCoordinator()
        await waitUntil { coordinator.state.selectedRequestContext == .saved }

        coordinator.setURL("localhost:3000")
        XCTAssertFalse(coordinator.state.canRun)

        coordinator.saveCurrentRequest()
        await waitUntil { coordinator.state.requestListItems.count == 1 }

        XCTAssertEqual(coordinator.state.requestListItems.count, 1)
        XCTAssertEqual(coordinator.state.selectedRequestContext, .saved)
        XCTAssertFalse(coordinator.state.canRun)
    }

    func testSwitchingSavedRequestsRestoresEachDraft() async {
        let coordinator = makeCoordinator()
        await waitUntil { coordinator.state.selectedRequestContext == .saved }

        coordinator.updateWorkspaceName("Req A")
        coordinator.setURL("https://api.example.com/a")
        coordinator.saveCurrentRequest()
        await waitUntil { coordinator.state.requestListItems.count == 1 }
        guard let requestAID = coordinator.state.selectedSavedRequestID else {
            XCTFail("Expected request A to be selected after save.")
            return
        }

        coordinator.createOrFocusHiddenNewDraft()
        await waitUntil { coordinator.state.requestListItems.count == 2 }
        coordinator.updateWorkspaceName("Req B")
        coordinator.setURL("https://api.example.com/b")
        coordinator.saveCurrentRequest()
        await waitUntil { coordinator.state.requestListItems.count == 2 }
        guard let requestBID = coordinator.state.selectedSavedRequestID else {
            XCTFail("Expected request B to be selected after save.")
            return
        }

        coordinator.selectSavedRequest(id: requestAID)
        coordinator.setURL("https://api.example.com/a-draft")
        XCTAssertTrue(coordinator.state.isCurrentRequestDirty)

        coordinator.selectSavedRequest(id: requestBID)
        coordinator.setURL("https://api.example.com/b-draft")
        XCTAssertTrue(coordinator.state.isCurrentRequestDirty)

        coordinator.selectSavedRequest(id: requestAID)
        XCTAssertEqual(coordinator.state.workspaceRequest.urlString, "https://api.example.com/a-draft")

        coordinator.selectSavedRequest(id: requestBID)
        XCTAssertEqual(coordinator.state.workspaceRequest.urlString, "https://api.example.com/b-draft")
    }

    func testRevertClearsDirtyDraftForSavedRequest() async {
        let coordinator = makeCoordinator()
        await waitUntil { coordinator.state.selectedRequestContext == .saved }

        coordinator.updateWorkspaceName("Req A")
        coordinator.setURL("https://api.example.com/a")
        coordinator.saveCurrentRequest()
        await waitUntil { coordinator.state.requestListItems.count == 1 }

        coordinator.setURL("https://api.example.com/a-edited")
        XCTAssertTrue(coordinator.state.isCurrentRequestDirty)
        XCTAssertTrue(coordinator.state.requestListItems.first?.isDirty == true)

        coordinator.revertCurrentRequestDraft()
        await waitUntil { coordinator.state.workspaceRequest.urlString == "https://api.example.com/a" }

        XCTAssertFalse(coordinator.state.isCurrentRequestDirty)
        XCTAssertEqual(coordinator.state.workspaceRequest.urlString, "https://api.example.com/a")
        XCTAssertTrue(coordinator.state.requestListItems.first?.isDirty == false)
    }

    func testDuplicateUsesCurrentDraftAndKeepsSourceDirty() async {
        let coordinator = makeCoordinator()
        await waitUntil { coordinator.state.selectedRequestContext == .saved }

        coordinator.updateWorkspaceName("Req A")
        coordinator.setURL("https://api.example.com/a")
        coordinator.saveCurrentRequest()
        await waitUntil { coordinator.state.requestListItems.count == 1 }

        guard let sourceID = coordinator.state.selectedSavedRequestID else {
            XCTFail("Expected source request to be selected.")
            return
        }

        coordinator.setURL("https://api.example.com/a-draft")
        XCTAssertTrue(coordinator.state.isCurrentRequestDirty)

        coordinator.duplicateSelectedRequest()
        await waitUntil { coordinator.state.requestListItems.count == 2 }
        guard let duplicateID = coordinator.state.selectedSavedRequestID else {
            XCTFail("Expected duplicate to become selected.")
            return
        }
        XCTAssertNotEqual(sourceID, duplicateID)
        XCTAssertEqual(coordinator.state.workspaceRequest.urlString, "https://api.example.com/a-draft")
        XCTAssertFalse(coordinator.state.isCurrentRequestDirty)

        let sourceRow = coordinator.state.requestListItems.first { $0.id == sourceID }
        XCTAssertEqual(sourceRow?.isDirty, true)
    }

    func testDeleteSelectedRequestFallsBackToRemainingSavedRequest() async {
        let coordinator = makeCoordinator()
        await waitUntil { coordinator.state.selectedRequestContext == .saved }

        coordinator.updateWorkspaceName("Req A")
        coordinator.setURL("https://api.example.com/a")
        coordinator.saveCurrentRequest()
        await waitUntil { coordinator.state.requestListItems.count == 1 }
        guard let requestAID = coordinator.state.selectedSavedRequestID else {
            XCTFail("Expected request A.")
            return
        }

        coordinator.createOrFocusHiddenNewDraft()
        await waitUntil { coordinator.state.requestListItems.count == 2 }
        coordinator.updateWorkspaceName("Req B")
        coordinator.setURL("https://api.example.com/b")
        coordinator.saveCurrentRequest()
        await waitUntil { coordinator.state.requestListItems.count == 2 }
        guard let requestBID = coordinator.state.selectedSavedRequestID else {
            XCTFail("Expected request B.")
            return
        }

        coordinator.selectSavedRequest(id: requestAID)
        coordinator.deleteSavedRequest(id: requestAID)
        await waitUntil { coordinator.state.requestListItems.count == 1 }

        XCTAssertEqual(coordinator.state.selectedSavedRequestID, requestBID)
        XCTAssertEqual(coordinator.state.selectedRequestContext, .saved)
    }

    func testFileBackedPersistenceRestoresSavedRequestAndDraftAcrossCoordinatorRelaunch() async throws {
        let fileURL = makeTemporaryLibraryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        do {
            let coordinator = try makeFileBackedCoordinator(fileURL: fileURL)
            await waitUntil("initial library load") { coordinator.hasCompletedInitialLibraryLoad }

            coordinator.updateWorkspaceName("Persisted")
            coordinator.setURL("https://api.example.com/base")
            coordinator.saveCurrentRequest()
            await waitUntil("saved request creation") { coordinator.state.requestListItems.count == 1 }

            coordinator.setURL("https://api.example.com/draft")
            XCTAssertTrue(coordinator.state.isCurrentRequestDirty)

            await coordinator.waitForPendingPersistence()
        }

        let relaunchedCoordinator = try makeFileBackedCoordinator(fileURL: fileURL)
        await waitUntil { relaunchedCoordinator.state.requestListItems.count == 1 }

        XCTAssertEqual(relaunchedCoordinator.state.selectedRequestContext, .saved)
        XCTAssertEqual(relaunchedCoordinator.state.workspaceName, "Persisted")
        XCTAssertEqual(relaunchedCoordinator.state.workspaceRequest.urlString, "https://api.example.com/draft")
        XCTAssertTrue(relaunchedCoordinator.state.isCurrentRequestDirty)
    }

    func testFileBackedPersistenceRestoresLastSelectedRequestAcrossRelaunch() async throws {
        let fileURL = makeTemporaryLibraryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let firstID: UUID
        let secondID: UUID
        do {
            let coordinator = try makeFileBackedCoordinator(fileURL: fileURL)
            await waitUntil { coordinator.state.selectedRequestContext == .saved }

            coordinator.updateWorkspaceName("First")
            coordinator.setURL("https://api.example.com/first")
            coordinator.saveCurrentRequest()
            await waitUntil { coordinator.state.requestListItems.count == 1 }
            firstID = try XCTUnwrap(coordinator.state.selectedSavedRequestID)

            coordinator.createOrFocusHiddenNewDraft()
            coordinator.updateWorkspaceName("Second")
            coordinator.setURL("https://api.example.com/second")
            coordinator.saveCurrentRequest()
            await waitUntil { coordinator.state.requestListItems.count == 2 }
            secondID = try XCTUnwrap(coordinator.state.selectedSavedRequestID)

            coordinator.selectSavedRequest(id: firstID)
            await coordinator.flushSelectionState()
        }

        let relaunchedCoordinator = try makeFileBackedCoordinator(fileURL: fileURL)
        await waitUntil { relaunchedCoordinator.state.requestListItems.count == 2 }

        XCTAssertNotEqual(firstID, secondID)
        XCTAssertEqual(relaunchedCoordinator.state.selectedSavedRequestID, firstID)
        XCTAssertEqual(relaunchedCoordinator.state.workspaceName, "First")
        XCTAssertEqual(relaunchedCoordinator.state.workspaceRequest.urlString, "https://api.example.com/first")
    }

    func testInitialNoOpBindingWriteDoesNotBlockSelectionRestore() async throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_001_000)
        let persisted = SavedRequest(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000001000")!,
            name: "Persisted",
            request: Request(method: .get, urlString: "https://api.example.com/persisted", headers: [], body: .none),
            createdAt: timestamp,
            updatedAt: timestamp,
            lastEditedAt: timestamp,
            nameWasManuallyEdited: true
        )
        let saved = DelayedSavedRequestRepository(savedRequests: [persisted])
        let drafts = InMemoryRequestDraftRepository()
        let hidden = InMemoryHiddenNewDraftRepository()
        let summaries = InMemoryExecutionSummaryRepository()
        let selection = InMemorySessionSelectionRepository()
        let variables = InMemoryVariableRepository()
        try await selection.saveSelection(
            SessionSelection(
                selectedSavedRequestID: persisted.id,
                selectedContext: .saved,
                updatedAt: timestamp
            )
        )
        let facade = InMemoryWorkspaceRepositoryFacade(savedRequests: saved, drafts: drafts, summaries: summaries, variables: variables)
        let dependencies = RequestLibraryDependencies(
            savedRequests: saved,
            drafts: drafts,
            hiddenDraft: hidden,
            summaries: summaries,
            selection: selection,
            workspaceFacade: facade,
            variables: variables
        )

        let coordinator = SessionCoordinator(requestLibrary: dependencies)
        coordinator.updateWorkspaceName("Untitled Request")
        await saved.release()
        await waitUntil { coordinator.state.selectedSavedRequestID == persisted.id }

        XCTAssertEqual(coordinator.state.workspaceName, "Persisted")
        XCTAssertEqual(coordinator.state.workspaceRequest.urlString, "https://api.example.com/persisted")
    }

    func testVariableLoadPreservesDuplicateNamesAndSurfacesWarning() async throws {
        let saved = InMemorySavedRequestRepository()
        let drafts = InMemoryRequestDraftRepository()
        let hidden = InMemoryHiddenNewDraftRepository()
        let summaries = InMemoryExecutionSummaryRepository()
        let selection = InMemorySessionSelectionRepository()
        let variables = InMemoryVariableRepository()
        let older = Variable(
            name: "host",
            value: "old.example.com",
            scope: .global,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let newer = Variable(
            name: "host",
            value: "new.example.com",
            scope: .global,
            createdAt: Date(timeIntervalSince1970: 2),
            updatedAt: Date(timeIntervalSince1970: 2)
        )
        try await variables.saveVariable(older)
        try await variables.saveVariable(newer)
        let facade = InMemoryWorkspaceRepositoryFacade(
            savedRequests: saved,
            drafts: drafts,
            summaries: summaries,
            variables: variables
        )
        let coordinator = SessionCoordinator(requestLibrary: RequestLibraryDependencies(
            savedRequests: saved,
            drafts: drafts,
            hiddenDraft: hidden,
            summaries: summaries,
            selection: selection,
            workspaceFacade: facade,
            variables: variables
        ))

        await waitUntil { coordinator.state.variables.count == 2 }
        coordinator.setURL("https://{{host}}")

        XCTAssertEqual(coordinator.state.variables.map(\.id), [older.id, newer.id])
        XCTAssertEqual(
            coordinator.state.persistenceWarningMessage,
            "Duplicate variable names were found in local storage: host. The newest value is used until the duplicate is renamed or deleted."
        )
        XCTAssertEqual(
            coordinator.resolveCurrentRequestForRun().resolvedRequest?.urlString,
            "https://new.example.com"
        )
    }

    func testRequestVariablesMigrateOnSavePersistAndDeleteWithOwner() async throws {
        let fileURL = makeTemporaryLibraryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let hiddenDraftID = UUID()
        let seededRepositories = try FileRequestLibraryRepositories(fileURL: fileURL)
        try await seededRepositories.saveHiddenDraft(HiddenNewDraft(
            id: hiddenDraftID,
            snapshot: EditableRequestSnapshot(name: "Variable owner", request: .empty),
            nameWasManuallyEdited: true,
            lastEditedAt: Date()
        ))
        try await seededRepositories.saveSelection(SessionSelection(
            selectedSavedRequestID: nil,
            selectedContext: .hiddenNewDraft,
            updatedAt: Date()
        ))

        let savedRequestID: UUID
        do {
            let coordinator = try makeFileBackedCoordinator(fileURL: fileURL)
            await waitUntil("initial variable library load") { coordinator.hasCompletedInitialLibraryLoad }
            XCTAssertEqual(coordinator.state.selectedRequestContext, .hiddenNewDraft)

            let requestVariable = try XCTUnwrap(
                coordinator.createVariable(name: "account_id", value: "42", scope: .request)
            )
            let globalVariable = try XCTUnwrap(
                coordinator.createVariable(name: "api_host", value: "example.com", scope: .global)
            )
            XCTAssertEqual(requestVariable.requestID, hiddenDraftID)
            XCTAssertNil(globalVariable.requestID)

            coordinator.updateWorkspaceName("Variable owner")
            coordinator.setURL("https://{{api_host}}/accounts/{{account_id}}")
            coordinator.saveCurrentRequest()
            await waitUntil("variable owner request save") { coordinator.state.requestListItems.count == 2 }
            savedRequestID = try XCTUnwrap(coordinator.state.selectedSavedRequestID)
            await coordinator.waitForPendingPersistence()

            let migrated = try XCTUnwrap(
                coordinator.listVariablesForCurrentContext().first { $0.id == requestVariable.id }
            )
            XCTAssertEqual(migrated.requestID, savedRequestID)
        }

        do {
            let coordinator = try makeFileBackedCoordinator(fileURL: fileURL)
            await waitUntil("variable reload") { coordinator.state.variables.count == 2 }

            XCTAssertEqual(coordinator.state.variables.map(\.name).sorted(), ["account_id", "api_host"])
            XCTAssertEqual(
                coordinator.state.variables.first { $0.name == "account_id" }?.requestID,
                savedRequestID
            )

            coordinator.deleteSavedRequest(id: savedRequestID)
            await waitUntil("saved request deletion") {
                !coordinator.state.requestListItems.contains { $0.id == savedRequestID }
            }
            await coordinator.waitForPendingPersistence()
            XCTAssertEqual(coordinator.state.variables.map(\.name), ["api_host"])
        }

        let relaunched = try makeFileBackedCoordinator(fileURL: fileURL)
        await waitUntil("deleted variable remains absent after reload") { relaunched.state.variables.count == 1 }
        XCTAssertEqual(relaunched.state.variables.map(\.name), ["api_host"])
        XCTAssertEqual(relaunched.state.variables.first?.scope, .global)
    }

    func testSelectSavedRequestUpdatesSelectedSavedRequestIDInPublishedState() async {
        let coordinator = makeCoordinator()
        await waitUntil { coordinator.state.selectedRequestContext == .saved }

        coordinator.updateWorkspaceName("Req A")
        coordinator.setURL("https://api.example.com/a")
        coordinator.saveCurrentRequest()
        await waitUntil { coordinator.state.requestListItems.count == 1 }
        guard let requestAID = coordinator.state.selectedSavedRequestID else {
            XCTFail("Expected request A to be selected.")
            return
        }

        coordinator.createOrFocusHiddenNewDraft()
        await waitUntil { coordinator.state.requestListItems.count == 2 }
        guard let requestBID = coordinator.state.selectedSavedRequestID else {
            XCTFail("Expected request B to be selected.")
            return
        }
        XCTAssertNotEqual(requestAID, requestBID)

        coordinator.selectSavedRequest(id: requestAID)
        XCTAssertEqual(coordinator.state.selectedSavedRequestID, requestAID)
    }

    private func makeCoordinator() -> SessionCoordinator {
        let saved = InMemorySavedRequestRepository()
        let drafts = InMemoryRequestDraftRepository()
        let hidden = InMemoryHiddenNewDraftRepository()
        let summaries = InMemoryExecutionSummaryRepository()
        let selection = InMemorySessionSelectionRepository()
        let variables = InMemoryVariableRepository()
        let facade = InMemoryWorkspaceRepositoryFacade(savedRequests: saved, drafts: drafts, summaries: summaries, variables: variables)
        let dependencies = RequestLibraryDependencies(
            savedRequests: saved,
            drafts: drafts,
            hiddenDraft: hidden,
            summaries: summaries,
            selection: selection,
            workspaceFacade: facade,
            variables: variables
        )
        return SessionCoordinator(requestLibrary: dependencies)
    }

    private func makeFileBackedCoordinator(fileURL: URL) throws -> SessionCoordinator {
        let repositories = try FileRequestLibraryRepositories(fileURL: fileURL)
        let dependencies = RequestLibraryDependencies(
            savedRequests: repositories,
            drafts: repositories,
            hiddenDraft: repositories,
            summaries: repositories,
            selection: repositories,
            workspaceFacade: repositories,
            variables: repositories
        )
        return SessionCoordinator(requestLibrary: dependencies)
    }

    private func makeTemporaryLibraryFileURL() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("curly-unit-tests", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("\(UUID().uuidString).json")
        try? FileManager.default.removeItem(at: fileURL)
        return fileURL
    }

    private func waitUntil(
        _ description: String = "condition",
        timeout: TimeInterval = 2.0,
        condition: @escaping () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(condition(), "Timed out waiting for \(description) after \(timeout) seconds.")
    }
}

private actor DelayedSavedRequestRepository: SavedRequestRepository {
    private let savedRequests: [SavedRequest]
    private var shouldDelayList = true
    private var continuation: CheckedContinuation<Void, Never>?

    init(savedRequests: [SavedRequest]) {
        self.savedRequests = savedRequests
    }

    func release() {
        shouldDelayList = false
        continuation?.resume()
        continuation = nil
    }

    func list() async throws -> [SavedRequest] {
        if shouldDelayList {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
        return savedRequests
    }

    func get(id: UUID) async throws -> SavedRequest? {
        savedRequests.first { $0.id == id }
    }

    func upsert(_ request: SavedRequest) async throws {}

    func delete(id: UUID) async throws {}
}
