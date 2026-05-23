import Foundation

struct EditableRequestSnapshot: Equatable, Codable {
    var name: String
    var request: Request
}

struct SavedRequest: Equatable, Codable, Identifiable {
    var id: UUID
    var name: String
    var request: Request
    var createdAt: Date
    var updatedAt: Date
    var lastEditedAt: Date
    var nameWasManuallyEdited: Bool
}

struct RequestDraft: Equatable, Codable {
    var requestID: UUID
    var snapshot: EditableRequestSnapshot
    var lastEditedAt: Date
    var baseSavedUpdatedAt: Date
    var draftBaseOutdated: Bool
}

struct HiddenNewDraft: Equatable, Codable {
    var id: UUID
    var snapshot: EditableRequestSnapshot
    var nameWasManuallyEdited: Bool
    var lastEditedAt: Date
}

struct ExecutionSummary: Equatable, Codable {
    var requestID: UUID
    var statusCode: Int?
    var durationMs: Int?
    var sizeBytes: Int?
    var lastRunAt: Date?
    var lastRunSource: LastRunSource
}

enum LastRunSource: String, Equatable, Codable {
    case saved
    case draft
}

struct SessionSelection: Equatable, Codable {
    var selectedSavedRequestID: UUID?
    var selectedContext: SelectionContext
    var isLibraryCollapsed: Bool?
    var updatedAt: Date

    init(
        selectedSavedRequestID: UUID?,
        selectedContext: SelectionContext,
        isLibraryCollapsed: Bool? = nil,
        updatedAt: Date
    ) {
        self.selectedSavedRequestID = selectedSavedRequestID
        self.selectedContext = selectedContext
        self.isLibraryCollapsed = isLibraryCollapsed
        self.updatedAt = updatedAt
    }
}

enum SelectionContext: String, Equatable, Codable {
    case saved
    case hiddenNewDraft
}

struct RequestListItem: Equatable, Identifiable {
    var id: UUID
    var name: String
    var method: HTTPMethod
    var urlPreview: String
    var lastEditedAt: Date
    var isDirty: Bool
    var lastSummary: ExecutionSummary?
}
