import Foundation
@testable import Tern

enum PL {
    static let me = "user-me"
    static let workspace = try! PlaneWorkspace(slug: "plane")
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    static let todo = PlaneState(id: "s-todo", name: "Todo", group: "unstarted")
    static let inProgress = PlaneState(id: "s-progress", name: "In Progress", group: "started")
    static let inReview = PlaneState(id: "s-review", name: "In Review", group: "started")
    static let done = PlaneState(id: "s-done", name: "Done", group: "completed")

    static func item(
        _ identifier: String = "WEB-9295",
        id: String? = nil,
        name: String = "Customer property chevron",
        state: PlaneState = inProgress,
        assignees: [String] = [me],
        created: Date = at(0),
        updated: Date = at(1),
        archived: Date? = nil
    ) -> PlaneWorkItem {
        PlaneWorkItem(
            id: id ?? "item-\(identifier)", identifier: identifier, name: name, stateID: state.id, state: state,
            assigneeIDs: assignees, projectID: "project-web", createdAt: created, updatedAt: updated, archivedAt: archived
        )
    }

    static func events(_ item: PlaneWorkItem) -> [ObservedEvent] {
        PlaneNormalizer(workspace: workspace, userID: me).events(for: item)
    }
}

/// A fake Plane API v2 serving `users/me`, the workspace work-item list and lookups by identifier.
final class PlaneStub: PlaneHTTP, @unchecked Sendable {
    struct State {
        var token = "plane_api_valid_test_token"
        var items: [PlaneWorkItem] = []
        var failure: Failure?
        var listRequests = 0
        var lookups: [String] = []
        var lastAPIKey: String?
    }

    enum Failure {
        case status(Int, body: String = "{}", headers: [String: String] = [:])
        case offline
        case malformed
    }

    private let lock = NSLock()
    private var state = State()

    func update(_ body: (inout State) -> Void) { lock.withLock { body(&state) } }
    func read<T>(_ body: (State) -> T) -> T { lock.withLock { body(state) } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let key = request.value(forHTTPHeaderField: "X-API-Key")
        update { $0.lastAPIKey = key }
        let snapshot = read { $0 }
        func respond(_ code: Int, _ body: Data, _ headers: [String: String] = [:]) -> (Data, HTTPURLResponse) {
            (body, HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: headers)!)
        }
        switch snapshot.failure {
        case .offline: throw URLError(.notConnectedToInternet)
        case .malformed: return respond(200, Data("<html>".utf8))
        case .status(let code, let body, let headers): return respond(code, Data(body.utf8), headers)
        case nil: break
        }
        guard key == snapshot.token else {
            return respond(401, Data(#"{"type":"unauthorized","code":"unauthorized","detail":"Authentication credentials were not valid."}"#.utf8))
        }
        guard request.httpMethod == nil || request.httpMethod == "GET" else { return respond(405, Data()) }

        let path = url.path()
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        if path == "/api/v2/users/me/" {
            return respond(200, Data(#"{"id":"\#(PL.me)","display_name":"Atul","first_name":"Atul","email":"atul@example.com"}"#.utf8))
        }
        if path == "/api/v2/workspaces/plane/work-items/" {
            update { $0.listRequests += 1 }
            let groups = Set((query["state_group__in"] ?? "").split(separator: ",").map(String.init))
            let mine = snapshot.items.filter {
                ($0.assigneeIDs ?? []).contains(query["assignee_id"] ?? "") && groups.contains($0.state?.group ?? "") && $0.archivedAt == nil
            }
            return respond(200, try Self.encode(PlaneWorkItemPage(data: mine, next: nil, totalCount: mine.count)))
        }
        if path.hasPrefix("/api/v2/workspaces/plane/work-items/") {
            let identifier = String(path.dropFirst("/api/v2/workspaces/plane/work-items/".count).dropLast())
            update { $0.lookups.append(identifier) }
            guard let item = snapshot.items.first(where: { $0.identifier == identifier && $0.archivedAt == nil }) else {
                return respond(404, Data(#"{"type":"not_found","code":"not_found"}"#.utf8))
            }
            return respond(200, try Self.encode(item))
        }
        return respond(404, Data())
    }

    /// Encodes dates the way Plane does: microsecond precision, UTC.
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date).replacingOccurrences(of: "Z", with: "123Z"))
        }
        return try encoder.encode(value)
    }
}

final class InMemoryPlaneCredentials: PlaneCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String: String] = [:]

    init(_ tokens: [String: String] = [:]) { self.tokens = tokens }

    func token(for workspace: String) -> String? { lock.withLock { tokens[workspace] } }
    func save(_ token: String, for workspace: String) { lock.withLock { tokens[workspace] = token } }
    func delete(for workspace: String) { lock.withLock { _ = tokens.removeValue(forKey: workspace) } }
    var all: [String: String] { lock.withLock { tokens } }
}

/// Plane sync wired to the stub and an in-memory ingestion service.
struct PlaneHarness {
    let plane = PlaneStub()
    let credentials: InMemoryPlaneCredentials
    let store = InMemoryTernStore()
    let ingestion: IngestionService
    let sync: PlaneSyncService

    init(token: String? = "plane_api_valid_test_token") async throws {
        credentials = InMemoryPlaneCredentials(token.map { ["plane": $0] } ?? [:])
        ingestion = IngestionService(store: store, now: { PL.t0 }, scoping: .ignoringContexts)
        try await ingestion.start()
        sync = PlaneSyncService(credentials: credentials, http: plane, ingestion: ingestion, now: { PL.at(60) })
        await sync.configure(PL.workspace)
    }

    func workstream(_ identifier: String = "WEB-9295") async -> Workstream? {
        await ingestion.snapshot.workstreams.first { $0.planeItem?.identifier == identifier }
    }
}
