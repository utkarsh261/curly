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
            await waitUntil { coordinator.state.selectedRequestContext == .saved }

            coordinator.updateWorkspaceName("Persisted")
            coordinator.setURL("https://api.example.com/base")
            coordinator.saveCurrentRequest()
            await waitUntil { coordinator.state.requestListItems.count == 1 }

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
        let facade = InMemoryWorkspaceRepositoryFacade(savedRequests: saved, drafts: drafts, summaries: summaries)
        let dependencies = RequestLibraryDependencies(
            savedRequests: saved,
            drafts: drafts,
            hiddenDraft: hidden,
            summaries: summaries,
            selection: selection,
            workspaceFacade: facade
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
            workspaceFacade: repositories
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
        XCTAssertTrue(condition(), "Condition timed out after \(timeout) seconds.")
    }
}
