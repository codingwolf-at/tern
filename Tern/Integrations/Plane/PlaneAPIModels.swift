import Foundation

// Shapes of Plane API v2 responses Tern reads. Only fields Tern uses; descriptions,
// comments and project details are never requested.

struct PlaneUser: Codable, Sendable, Hashable {
    let id: String
    let displayName: String?
    let firstName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case firstName = "first_name"
    }

    var name: String { displayName ?? firstName ?? "Plane user" }
}

struct PlaneState: Codable, Sendable, Hashable {
    let id: String
    let name: String
    /// `backlog`, `unstarted`, `started`, `completed`, `cancelled`, `triage`.
    let group: String?
}

struct PlaneWorkItem: Codable, Sendable, Hashable {
    let id: String
    /// Human key, e.g. `WEB-9295`.
    let identifier: String?
    let name: String
    let stateID: String?
    /// Present when requested with `expand=state`.
    let state: PlaneState?
    let assigneeIDs: [String]?
    let projectID: String?
    let createdAt: Date
    let updatedAt: Date?
    let completedAt: Date?
    let archivedAt: Date?
    let isDraft: Bool?

    enum CodingKeys: String, CodingKey {
        case id, identifier, name, state
        case stateID = "state_id"
        case assigneeIDs = "assignee_ids"
        case projectID = "project_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case completedAt = "completed_at"
        case archivedAt = "archived_at"
        case isDraft = "is_draft"
    }

    init(
        id: String, identifier: String?, name: String, stateID: String?, state: PlaneState?, assigneeIDs: [String]?,
        projectID: String?, createdAt: Date, updatedAt: Date?, completedAt: Date? = nil, archivedAt: Date? = nil, isDraft: Bool? = false
    ) {
        self.id = id
        self.identifier = identifier
        self.name = name
        self.stateID = stateID
        self.state = state
        self.assigneeIDs = assigneeIDs
        self.projectID = projectID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.archivedAt = archivedAt
        self.isDraft = isDraft
    }

    /// `state` may come back as an expanded object or as a bare id.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        identifier = try container.decodeIfPresent(String.self, forKey: .identifier)
        name = try container.decode(String.self, forKey: .name)
        let expanded = try? container.decodeIfPresent(PlaneState.self, forKey: .state)
        state = expanded
        stateID = try container.decodeIfPresent(String.self, forKey: .stateID)
            ?? expanded?.id
            ?? (try? container.decodeIfPresent(String.self, forKey: .state))
        assigneeIDs = try container.decodeIfPresent([String].self, forKey: .assigneeIDs)
        projectID = try container.decodeIfPresent(String.self, forKey: .projectID)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        archivedAt = try container.decodeIfPresent(Date.self, forKey: .archivedAt)
        isDraft = try container.decodeIfPresent(Bool.self, forKey: .isDraft)
    }

    /// Changes whenever something Tern cares about may have changed.
    var fingerprint: String {
        [
            updatedAt.map { String($0.timeIntervalSince1970) } ?? "-",
            stateID ?? "-",
            (assigneeIDs ?? []).sorted().joined(separator: ","),
            archivedAt.map { String($0.timeIntervalSince1970) } ?? "-",
            name,
        ].joined(separator: "|")
    }
}

/// A page of work items. Plane v2 paginates by offset: `next` is the next offset, or null.
struct PlaneWorkItemPage: Codable, Sendable {
    let data: [PlaneWorkItem]
    let next: Int?
    let totalCount: Int?

    enum CodingKeys: String, CodingKey {
        case data, next
        case totalCount = "total_count"
    }

    init(data: [PlaneWorkItem], next: Int?, totalCount: Int?) {
        self.data = data
        self.next = next
        self.totalCount = totalCount
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        data = try container.decode([PlaneWorkItem].self, forKey: .data)
        totalCount = try container.decodeIfPresent(Int.self, forKey: .totalCount)
        if let offset = try? container.decodeIfPresent(Int.self, forKey: .next) {
            next = offset
        } else if let text = try? container.decodeIfPresent(String.self, forKey: .next) {
            next = Int(text)
        } else {
            next = nil
        }
    }
}

enum PlaneJSON {
    /// Plane timestamps carry microseconds (`2026-08-05T11:34:24.026442Z`), which the
    /// standard ISO 8601 strategy rejects.
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = parseDate(text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unrecognised date"))
            }
            return date
        }
        return decoder
    }()

    static func parseDate(_ text: String) -> Date? {
        // Keep at most millisecond precision, then parse with or without a fraction.
        let trimmed = text.replacing(/(\.\d{3})\d+/) { $0.output.1 }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return withFraction.date(from: trimmed) ?? plain.date(from: trimmed)
    }
}
