import Foundation

struct PostResponseScript: Equatable, Codable {
    var isEnabled: Bool
    var source: String

    static let disabled = PostResponseScript(isEnabled: false, source: "")
}

struct RequestAutomation: Equatable, Codable {
    var postResponseScript: PostResponseScript

    static let none = RequestAutomation(postResponseScript: .disabled)
}

struct EditableRequestSnapshot: Equatable, Codable {
    var name: String
    var request: Request
    var automation: RequestAutomation

    init(name: String, request: Request, automation: RequestAutomation = .none) {
        self.name = name
        self.request = request
        self.automation = automation
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case request
        case automation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        request = try container.decode(Request.self, forKey: .request)
        automation = try container.decodeIfPresent(RequestAutomation.self, forKey: .automation) ?? .none
    }
}

struct SavedRequest: Equatable, Codable, Identifiable {
    var id: UUID
    var name: String
    var request: Request
    var createdAt: Date
    var updatedAt: Date
    var lastEditedAt: Date
    var nameWasManuallyEdited: Bool
    var automation: RequestAutomation

    init(
        id: UUID,
        name: String,
        request: Request,
        createdAt: Date,
        updatedAt: Date,
        lastEditedAt: Date,
        nameWasManuallyEdited: Bool,
        automation: RequestAutomation = .none
    ) {
        self.id = id
        self.name = name
        self.request = request
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastEditedAt = lastEditedAt
        self.nameWasManuallyEdited = nameWasManuallyEdited
        self.automation = automation
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case request
        case createdAt
        case updatedAt
        case lastEditedAt
        case nameWasManuallyEdited
        case automation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        request = try container.decode(Request.self, forKey: .request)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        lastEditedAt = try container.decode(Date.self, forKey: .lastEditedAt)
        nameWasManuallyEdited = try container.decode(Bool.self, forKey: .nameWasManuallyEdited)
        automation = try container.decodeIfPresent(RequestAutomation.self, forKey: .automation) ?? .none
    }
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
