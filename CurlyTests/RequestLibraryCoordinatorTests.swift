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

    func testLastVisitedRequestTogglesBetweenTheCurrentAndPreviousRequest() async throws {
        let coordinator = makeCoordinator()
        await waitUntil { coordinator.state.selectedRequestContext == .saved }

        let requestAID = try XCTUnwrap(coordinator.state.selectedSavedRequestID)
        coordinator.updateWorkspaceName("Request A")
        coordinator.saveCurrentRequest()

        coordinator.createOrFocusHiddenNewDraft()
        let requestBID = try XCTUnwrap(coordinator.state.selectedSavedRequestID)
        coordinator.updateWorkspaceName("Request B")
        coordinator.saveCurrentRequest()

        coordinator.createOrFocusHiddenNewDraft()
        let requestCID = try XCTUnwrap(coordinator.state.selectedSavedRequestID)
        coordinator.updateWorkspaceName("Request C")
        coordinator.saveCurrentRequest()

        XCTAssertNotEqual(requestAID, requestBID)
        XCTAssertNotEqual(requestBID, requestCID)
        XCTAssertEqual(coordinator.lastVisitedRequest?.id, requestBID)

        coordinator.selectLastVisitedRequest()
        XCTAssertEqual(coordinator.state.selectedSavedRequestID, requestBID)
        XCTAssertEqual(coordinator.lastVisitedRequest?.id, requestCID)

        coordinator.selectLastVisitedRequest()
        XCTAssertEqual(coordinator.state.selectedSavedRequestID, requestCID)
        XCTAssertEqual(coordinator.lastVisitedRequest?.id, requestBID)
    }

    func testVisibleRequestIndexSelectionUsesCurrentSidebarOrderAndRejectsInvalidIndexes() async throws {
        let coordinator = makeCoordinator()
        await waitUntil { coordinator.state.selectedRequestContext == .saved }

        coordinator.updateWorkspaceName("Request A")
        coordinator.saveCurrentRequest()
        coordinator.createOrFocusHiddenNewDraft()
        coordinator.updateWorkspaceName("Request B")
        coordinator.saveCurrentRequest()
        coordinator.createOrFocusHiddenNewDraft()
        coordinator.updateWorkspaceName("Request C")
        coordinator.saveCurrentRequest()

        let orderedIDs = coordinator.state.requestListItems.map(\.id)
        XCTAssertEqual(orderedIDs.count, 3)

        coordinator.selectVisibleRequest(at: 2)
        XCTAssertEqual(coordinator.state.selectedSavedRequestID, orderedIDs[2])

        coordinator.selectVisibleRequest(at: 0)
        XCTAssertEqual(coordinator.state.selectedSavedRequestID, orderedIDs[0])

        coordinator.selectVisibleRequest(at: -1)
        XCTAssertEqual(coordinator.state.selectedSavedRequestID, orderedIDs[0])

        coordinator.selectVisibleRequest(at: 3)
        XCTAssertEqual(coordinator.state.selectedSavedRequestID, orderedIDs[0])
    }

    func testVisibleRequestIndexSelectionIsLimitedToNineShortcuts() async throws {
        let coordinator = makeCoordinator()
        await waitUntil { coordinator.state.selectedRequestContext == .saved }

        for _ in 0..<9 {
            coordinator.createOrFocusHiddenNewDraft()
        }
        XCTAssertEqual(coordinator.state.requestListItems.count, 10)

        let selectedID = try XCTUnwrap(coordinator.state.selectedSavedRequestID)
        coordinator.selectVisibleRequest(at: 9)
        XCTAssertEqual(coordinator.state.selectedSavedRequestID, selectedID)

        coordinator.selectVisibleRequest(at: 8)
        XCTAssertEqual(
            coordinator.state.selectedSavedRequestID,
            coordinator.state.requestListItems[8].id
        )
    }

    func testReselectingCurrentRequestDoesNotReplaceLastVisitedRequest() async throws {
        let coordinator = makeCoordinator()
        await waitUntil { coordinator.state.selectedRequestContext == .saved }

        let requestAID = try XCTUnwrap(coordinator.state.selectedSavedRequestID)
        coordinator.createOrFocusHiddenNewDraft()
        let requestBID = try XCTUnwrap(coordinator.state.selectedSavedRequestID)

        coordinator.selectSavedRequest(id: requestBID)
        XCTAssertEqual(coordinator.lastVisitedRequest?.id, requestAID)

        coordinator.selectLastVisitedRequest()
        XCTAssertEqual(coordinator.state.selectedSavedRequestID, requestAID)
        XCTAssertEqual(coordinator.lastVisitedRequest?.id, requestBID)
    }

    func testDeletingLastVisitedRequestPrunesNavigationTarget() async throws {
        let coordinator = makeCoordinator()
        await waitUntil { coordinator.state.selectedRequestContext == .saved }

        let requestAID = try XCTUnwrap(coordinator.state.selectedSavedRequestID)
        coordinator.createOrFocusHiddenNewDraft()
        let requestBID = try XCTUnwrap(coordinator.state.selectedSavedRequestID)
        XCTAssertEqual(coordinator.lastVisitedRequest?.id, requestAID)

        coordinator.deleteSavedRequest(id: requestAID)
        await waitUntil { coordinator.state.requestListItems.count == 1 }

        XCTAssertEqual(coordinator.state.selectedSavedRequestID, requestBID)
        XCTAssertNil(coordinator.lastVisitedRequest)

        coordinator.selectLastVisitedRequest()
        XCTAssertEqual(coordinator.state.selectedSavedRequestID, requestBID)
    }

    func testInitialSelectionDoesNotCreateLastVisitedRequest() async {
        let coordinator = makeCoordinator()
        await waitUntil { coordinator.state.selectedRequestContext == .saved }

        let initiallySelectedID = coordinator.state.selectedSavedRequestID
        XCTAssertNil(coordinator.lastVisitedRequest)

        coordinator.selectLastVisitedRequest()
        XCTAssertEqual(coordinator.state.selectedSavedRequestID, initiallySelectedID)
    }

    func testKeyboardRequestNavigationIsBlockedWhileVariablesModalIsPresented() async throws {
        let coordinator = makeCoordinator()
        await waitUntil { coordinator.state.selectedRequestContext == .saved }

        coordinator.updateWorkspaceName("Request A")
        coordinator.saveCurrentRequest()
        coordinator.createOrFocusHiddenNewDraft()
        coordinator.updateWorkspaceName("Request B")
        coordinator.saveCurrentRequest()

        let requestBID = try XCTUnwrap(coordinator.state.selectedSavedRequestID)
        let requestAIndex = try XCTUnwrap(
            coordinator.state.requestListItems.firstIndex { $0.name == "Request A" }
        )
        coordinator.presentVariablesModal()

        coordinator.selectLastVisitedRequest()
        XCTAssertEqual(coordinator.state.selectedSavedRequestID, requestBID)

        coordinator.selectVisibleRequest(at: requestAIndex)
        XCTAssertEqual(coordinator.state.selectedSavedRequestID, requestBID)
    }

    func testKeyboardRequestNavigationIsBlockedDuringRequestReplacementConfirmation() async throws {
        let coordinator = makeCoordinator()
        await waitUntil { coordinator.state.selectedRequestContext == .saved }

        coordinator.updateWorkspaceName("Request A")
        coordinator.saveCurrentRequest()
        coordinator.createOrFocusHiddenNewDraft()
        coordinator.updateWorkspaceName("Request B")
        coordinator.setURL("https://current.example.com")
        coordinator.saveCurrentRequest()

        let requestBID = try XCTUnwrap(coordinator.state.selectedSavedRequestID)
        coordinator.handleURLBarPaste("curl https://replacement.example.com")
        XCTAssertNotNil(coordinator.state.replaceConfirmationState)

        coordinator.selectLastVisitedRequest()
        XCTAssertEqual(coordinator.state.selectedSavedRequestID, requestBID)
        XCTAssertNotNil(coordinator.state.replaceConfirmationState)
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
        await waitUntil { coordinator.hasCompletedInitialLibraryLoad }

        coordinator.updateWorkspaceName("Req A")
        coordinator.setURL("https://api.example.com/a")
        coordinator.saveCurrentRequest()
        await waitUntil { coordinator.state.requestListItems.count == 1 }

        guard let sourceID = coordinator.state.selectedSavedRequestID else {
            XCTFail("Expected source request to be selected.")
            return
        }

        coordinator.setURL("https://api.example.com/a-draft")
        coordinator.setPostResponseScriptEnabled(true)
        coordinator.setPostResponseScriptSource("curly.variables.global.set(\"copy\", \"yes\");")
        XCTAssertTrue(coordinator.state.isCurrentRequestDirty)

        coordinator.duplicateSelectedRequest()
        await waitUntil { coordinator.state.requestListItems.count == 2 }
        guard let duplicateID = coordinator.state.selectedSavedRequestID else {
            XCTFail("Expected duplicate to become selected.")
            return
        }
        XCTAssertNotEqual(sourceID, duplicateID)
        XCTAssertEqual(coordinator.state.workspaceRequest.urlString, "https://api.example.com/a-draft")
        XCTAssertEqual(
            coordinator.state.requestAutomation.postResponseScript,
            PostResponseScript(isEnabled: true, source: "curly.variables.global.set(\"copy\", \"yes\");")
        )
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
        XCTAssertNil(coordinator.lastVisitedRequest)

        coordinator.selectLastVisitedRequest()
        XCTAssertEqual(coordinator.state.selectedSavedRequestID, requestBID)
    }

    func testDuplicateBecomesCurrentAndRecordsItsSourceAsLastVisited() async throws {
        let coordinator = makeCoordinator()
        await waitUntil { coordinator.state.selectedRequestContext == .saved }

        let sourceID = try XCTUnwrap(coordinator.state.selectedSavedRequestID)
        coordinator.duplicateSelectedRequest()
        let duplicateID = try XCTUnwrap(coordinator.state.selectedSavedRequestID)

        XCTAssertNotEqual(duplicateID, sourceID)
        XCTAssertEqual(coordinator.lastVisitedRequest?.id, sourceID)

        coordinator.selectLastVisitedRequest()
        XCTAssertEqual(coordinator.state.selectedSavedRequestID, sourceID)
        XCTAssertEqual(coordinator.lastVisitedRequest?.id, duplicateID)
    }

    func testFileBackedPersistenceRestoresSavedRequestAndDraftAcrossCoordinatorRelaunch() async throws {
        let fileURL = makeTemporaryLibraryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        do {
            let coordinator = try makeFileBackedCoordinator(fileURL: fileURL)
            await waitUntil("initial library load") { coordinator.hasCompletedInitialLibraryLoad }

            coordinator.updateWorkspaceName("Persisted")
            coordinator.setURL("https://api.example.com/base")
            coordinator.setPostResponseScriptEnabled(true)
            coordinator.setPostResponseScriptSource("curly.variables.global.set(\"version\", \"saved\");")
            coordinator.saveCurrentRequest()
            await waitUntil("saved request creation") { coordinator.state.requestListItems.count == 1 }

            coordinator.setURL("https://api.example.com/draft")
            coordinator.setPostResponseScriptSource("curly.variables.global.set(\"version\", \"draft\");")
            XCTAssertTrue(coordinator.state.isCurrentRequestDirty)

            await coordinator.waitForPendingPersistence()
        }

        let relaunchedCoordinator = try makeFileBackedCoordinator(fileURL: fileURL)
        await waitUntil { relaunchedCoordinator.state.requestListItems.count == 1 }

        XCTAssertEqual(relaunchedCoordinator.state.selectedRequestContext, .saved)
        XCTAssertEqual(relaunchedCoordinator.state.workspaceName, "Persisted")
        XCTAssertEqual(relaunchedCoordinator.state.workspaceRequest.urlString, "https://api.example.com/draft")
        XCTAssertEqual(
            relaunchedCoordinator.state.requestAutomation.postResponseScript,
            PostResponseScript(isEnabled: true, source: "curly.variables.global.set(\"version\", \"draft\");")
        )
        XCTAssertNotEqual(relaunchedCoordinator.state.postResponseScriptState.status, .off)
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
        XCTAssertNil(relaunchedCoordinator.lastVisitedRequest)
    }

    func testFileBackedPersistenceRestoresCollapsedLibraryAcrossCoordinatorRelaunch() async throws {
        let fileURL = makeTemporaryLibraryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        do {
            let coordinator = try makeFileBackedCoordinator(fileURL: fileURL)
            await waitUntil("initial library load") { coordinator.hasCompletedInitialLibraryLoad }

            XCTAssertFalse(coordinator.state.isLibraryCollapsed)
            coordinator.setLibraryCollapsed(true)
            XCTAssertTrue(coordinator.state.isLibraryCollapsed)
            await coordinator.waitForPendingPersistence()
        }

        let relaunchedCoordinator = try makeFileBackedCoordinator(fileURL: fileURL)
        await waitUntil("reloaded library state") { relaunchedCoordinator.hasCompletedInitialLibraryLoad }

        XCTAssertTrue(relaunchedCoordinator.state.isLibraryCollapsed)
        relaunchedCoordinator.toggleLibraryCollapsed()
        XCTAssertFalse(relaunchedCoordinator.state.isLibraryCollapsed)
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

    func testReselectingCurrentRequestDoesNotCancelActiveExecution() async {
        let executor = CancellationTrackingRequestExecutor()
        let coordinator = makeCoordinator(requestExecutor: executor)
        await waitUntil { coordinator.state.selectedRequestContext == .saved }
        coordinator.setURL("https://example.com/slow")
        guard let selectedID = coordinator.state.selectedSavedRequestID else {
            return XCTFail("Expected a selected request")
        }

        coordinator.runCurrentRequest()
        await waitUntil { await executor.isWaiting }
        coordinator.selectSavedRequest(id: selectedID)
        try? await Task.sleep(for: .milliseconds(50))

        let cancellationCount = await executor.cancellationCount
        XCTAssertEqual(cancellationCount, 0)
        XCTAssertEqual(coordinator.state.executionState, .running)
        await executor.succeed()
        await waitUntil { coordinator.state.executionState == .succeeded }
    }

    func testCachedScriptResultSurvivesSelectionValidationDebounce() async {
        let executor = CancellationTrackingRequestExecutor()
        let coordinator = makeCoordinator(requestExecutor: executor)
        await waitUntil { coordinator.state.selectedRequestContext == .saved }
        coordinator.setURL("https://example.com/script")
        coordinator.setPostResponseScriptEnabled(true)
        coordinator.setPostResponseScriptSource(#"console.log("kept");"#)
        guard let firstID = coordinator.state.selectedSavedRequestID else {
            return XCTFail("Expected a selected request")
        }

        coordinator.runCurrentRequest()
        await waitUntil { await executor.isWaiting }
        await executor.succeed()
        await waitUntil { coordinator.state.postResponseScriptState.status == .passed }
        XCTAssertEqual(coordinator.state.postResponseScriptState.logs.first?.text, "kept")

        coordinator.createOrFocusHiddenNewDraft()
        await waitUntil { coordinator.state.selectedSavedRequestID != firstID }
        coordinator.selectSavedRequest(id: firstID)
        try? await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(coordinator.state.postResponseScriptState.status, .passed)
        XCTAssertEqual(coordinator.state.postResponseScriptState.logs.first?.text, "kept")
    }

    func testRevertAndDuplicateValidateInvalidSavedScripts() async {
        let coordinator = makeCoordinator()
        await waitUntil { coordinator.state.selectedRequestContext == .saved }
        coordinator.setPostResponseScriptEnabled(true)
        coordinator.setPostResponseScriptSource("const = ;")
        coordinator.saveCurrentRequest()
        coordinator.setPostResponseScriptSource("console.log('draft');")

        coordinator.revertCurrentRequestDraft()
        await waitUntil { coordinator.state.postResponseScriptState.status == .invalid }
        XCTAssertNotNil(coordinator.state.postResponseScriptState.diagnostic)

        coordinator.duplicateSelectedRequest()
        await waitUntil { coordinator.state.postResponseScriptState.status == .invalid }
        XCTAssertNotNil(coordinator.state.postResponseScriptState.diagnostic)
    }

    func testScriptBatchWaitsForEarlierVariablePersistence() async throws {
        let repository = OrderedVariableRepository()
        let initial = Variable(name: "token", value: "initial", scope: .global)
        try await repository.saveVariable(initial)
        let executor = CancellationTrackingRequestExecutor()
        let coordinator = makeCoordinator(
            requestExecutor: executor,
            scriptRunner: FixedWriteScriptRunner(),
            variables: repository
        )
        await waitUntil { coordinator.state.variables.count == 1 }
        await repository.delayNextSave()

        XCTAssertNotNil(coordinator.updateVariableValue(id: initial.id, value: "manual"))
        await waitUntil { await repository.isSaveBlocked }
        coordinator.setURL("https://example.com/order")
        coordinator.setPostResponseScriptEnabled(true)
        coordinator.setPostResponseScriptSource("write token")
        coordinator.runCurrentRequest()
        await waitUntil { await executor.isWaiting }
        await executor.succeed()
        try? await Task.sleep(for: .milliseconds(50))

        let batchCount = await repository.batchCount
        XCTAssertEqual(batchCount, 0)
        await repository.releaseSave()
        await waitUntil { coordinator.state.postResponseScriptState.status == .passed }
        let persistedValue = await repository.value(named: "token")
        XCTAssertEqual(persistedValue, "script")
    }

    private func makeCoordinator(
        requestExecutor: RequestExecuting = URLSessionRequestExecutor(),
        scriptRunner: PostResponseScriptRunning = QuickJSPostResponseScriptRunner(),
        variables: VariableRepository = InMemoryVariableRepository()
    ) -> SessionCoordinator {
        let saved = InMemorySavedRequestRepository()
        let drafts = InMemoryRequestDraftRepository()
        let hidden = InMemoryHiddenNewDraftRepository()
        let summaries = InMemoryExecutionSummaryRepository()
        let selection = InMemorySessionSelectionRepository()
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
        return SessionCoordinator(
            requestExecutor: requestExecutor,
            scriptRunner: scriptRunner,
            requestLibrary: dependencies
        )
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
        condition: @escaping @MainActor () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() {
                return
            }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let finalValue = await condition()
        XCTAssertTrue(finalValue, "Timed out waiting for \(description) after \(timeout) seconds.")
    }
}

private actor CancellationTrackingRequestExecutor: RequestExecuting {
    private var request: Request?
    private var continuation: CheckedContinuation<ExecutedResponse, Error>?
    private(set) var cancellationCount = 0

    var isWaiting: Bool { continuation != nil }

    func execute(_ request: Request) async throws -> ExecutedResponse {
        self.request = request
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    func succeed() {
        guard let request, let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: ExecutedResponse(
            request: request,
            statusCode: 200,
            headers: [],
            bodyData: Data(#"{"ok":true}"#.utf8),
            mimeType: "application/json",
            duration: 0.01,
            timestamp: Date()
        ))
    }

    private func cancel() {
        guard let continuation else { return }
        self.continuation = nil
        cancellationCount += 1
        continuation.resume(throwing: CancellationError())
    }
}

private struct FixedWriteScriptRunner: PostResponseScriptRunning {
    func validate(source: String) async -> ScriptValidationResult { .valid }

    func run(_ input: PostResponseScriptInput) async -> PostResponseScriptRunResult {
        PostResponseScriptRunResult(
            outcome: .passed,
            diagnostic: nil,
            durationMs: 1,
            writes: [ScriptVariableWrite(scope: .global, name: "token", value: "script")],
            logs: [],
            logsWereTruncated: false
        )
    }
}

private actor OrderedVariableRepository: VariableRepository {
    private var variablesByID: [UUID: Variable] = [:]
    private var shouldDelayNextSave = false
    private var saveContinuation: CheckedContinuation<Void, Never>?
    private(set) var batchCount = 0

    var isSaveBlocked: Bool { saveContinuation != nil }

    func delayNextSave() {
        shouldDelayNextSave = true
    }

    func releaseSave() {
        saveContinuation?.resume()
        saveContinuation = nil
    }

    func value(named name: String) -> String? {
        variablesByID.values.first { $0.name == name }?.value
    }

    func listVariables() async throws -> [Variable] { Array(variablesByID.values) }

    func saveVariable(_ variable: Variable) async throws {
        if shouldDelayNextSave {
            shouldDelayNextSave = false
            await withCheckedContinuation { continuation in
                saveContinuation = continuation
            }
        }
        variablesByID[variable.id] = variable
    }

    func deleteVariable(id: UUID) async throws { variablesByID[id] = nil }

    func deleteVariables(forRequestID requestID: UUID) async throws {
        variablesByID = variablesByID.filter { $0.value.requestID != requestID }
    }

    func migrateVariables(from oldRequestID: UUID, to newRequestID: UUID) async throws {
        for (id, variable) in variablesByID where variable.requestID == oldRequestID {
            var migrated = variable
            migrated.requestID = newRequestID
            variablesByID[id] = migrated
        }
    }

    func applyVariableBatch(_ batch: VariableBatch) async throws -> VariableBatchCommit {
        batchCount += 1
        var changed: [Variable] = []
        for mutation in batch.mutations {
            if var existing = variablesByID.values.first(where: { $0.name == mutation.name }) {
                existing.value = mutation.value
                existing.updatedAt = batch.committedAt
                variablesByID[existing.id] = existing
                changed.append(existing)
            }
        }
        return VariableBatchCommit(changedVariables: changed)
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
