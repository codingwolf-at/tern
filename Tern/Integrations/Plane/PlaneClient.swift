import Foundation

/// Where a Plane workspace lives: an API base URL and a workspace slug, kept separate.
/// Plane Cloud's API is `https://api.plane.so`; a self-hosted instance serves the API and the
/// web app from its own host.
struct PlaneWorkspace: Codable, Sendable, Hashable {
    let slug: String
    let apiBase: URL
    let webBase: URL

    static let cloudAPI = URL(string: "https://api.plane.so")!
    static let cloudWeb = URL(string: "https://app.plane.so")!

    enum InputError: Error, Equatable {
        case slugIsURL
        case invalidSlug
        case invalidAPIBase
        /// The Plane web app's address was given where the API's belongs.
        case webAppURL

        var message: String {
            switch self {
            case .slugIsURL: "Enter just the workspace slug, e.g. plane"
            case .invalidSlug: "Workspace slug can only use letters, numbers, - and _"
            case .invalidAPIBase: "API URL must look like https://api.plane.so"
            case .webAppURL: "That's the Plane web app. The API is https://api.plane.so"
            }
        }
    }

    /// - Parameters:
    ///   - slug: the workspace slug, e.g. `plane` (from `app.plane.so/plane/…`).
    ///   - api: the API base URL; Plane Cloud by default.
    init(slug input: String, api apiInput: String = PlaneWorkspace.cloudAPI.absoluteString) throws(InputError) {
        let slug = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if slug.contains("/") || slug.contains(":") { throw .slugIsURL }
        guard slug.range(of: #"^[A-Za-z0-9][A-Za-z0-9_-]*$"#, options: .regularExpression) != nil else { throw .invalidSlug }

        let trimmedAPI = apiInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let api = URL(string: trimmedAPI.hasSuffix("/") ? String(trimmedAPI.dropLast()) : trimmedAPI),
              let host = api.host(), let scheme = api.scheme
        else { throw .invalidAPIBase }
        if host == "app.plane.so" { throw .webAppURL }
        guard scheme == "https" || (scheme == "http" && (host == "localhost" || host == "127.0.0.1")),
              api.path().isEmpty || api.path() == "/",
              api.query() == nil
        else { throw .invalidAPIBase }

        self.slug = slug
        if host == "api.plane.so" {
            apiBase = Self.cloudAPI
            webBase = Self.cloudWeb
        } else {
            apiBase = URL(string: "\(scheme)://\(host)\(api.port.map { ":\($0)" } ?? "")")!
            webBase = apiBase
        }
    }

    func itemURL(_ identifier: String) -> URL {
        webBase.appending(path: "\(slug)/browse/\(identifier)/")
    }
}

/// The network boundary for Plane. Tests substitute a stub.
protocol PlaneHTTP: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionPlaneHTTP: PlaneHTTP {
    let session = URLSession(configuration: .ephemeral)

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

enum PlaneAPIError: Error, Equatable, Sendable {
    case notConnected
    /// The token is invalid, expired or revoked.
    case invalidCredentials
    /// The workspace doesn't exist or this account can't see it.
    case workspaceUnavailable
    case rateLimited(until: Date)
    case network(String)
    case server(Int)
    case malformedResponse

    var summary: String {
        switch self {
        case .notConnected: "Not connected"
        case .invalidCredentials: "Plane rejected the token"
        case .workspaceUnavailable: "Workspace not found or not accessible"
        case .rateLimited(let until): "Rate limited until \(until.formatted(date: .omitted, time: .shortened))"
        case .network(let reason): "Network: \(reason)"
        case .server(let status): "Plane error \(status)"
        case .malformedResponse: "Unexpected response from Plane"
        }
    }
}

/// Read-only Plane API v2 client. Every request is a GET.
struct PlaneClient: Sendable {
    let workspace: PlaneWorkspace
    let token: String
    let http: any PlaneHTTP
    let now: @Sendable () -> Date

    static let openStateGroups = "backlog,unstarted,started"
    /// Only fields the v2 API accepts in `fields`; an unknown name is a 400.
    /// (`updated_at` and `completed_at` are not requestable.)
    static let itemFields = "id,identifier,name,state_id,assignee_ids,project_id,created_at,archived_at,is_draft"
    static let pageSize = 100
    static let maximumPages = 5

    func me() async throws(PlaneAPIError) -> PlaneUser {
        try await get(["api", "v2", "users", "me"], query: [], as: PlaneUser.self)
    }

    /// Open work items assigned to `userID`, most recently updated first.
    func openItems(assignedTo userID: String) async throws(PlaneAPIError) -> [PlaneWorkItem] {
        var items: [PlaneWorkItem] = []
        var offset: Int? = 0
        var pages = 0
        while let current = offset, pages < Self.maximumPages {
            let page = try await get(["api", "v2", "workspaces", workspace.slug, "work-items"], query: [
                ("assignee_id", userID),
                ("state_group__in", Self.openStateGroups),
                ("expand", "state"),
                ("fields", Self.itemFields),
                ("per_page", String(Self.pageSize)),
                ("offset", String(current)),
            ], as: PlaneWorkItemPage.self)
            items += page.data
            pages += 1
            offset = page.data.isEmpty ? nil : page.next
        }
        return items
    }

    /// One work item by identifier; `nil` if it was deleted, archived or is no longer visible.
    func item(_ identifier: String) async throws(PlaneAPIError) -> PlaneWorkItem? {
        do {
            return try await get(["api", "v2", "workspaces", workspace.slug, "work-items", identifier], query: [
                ("expand", "state"),
                ("fields", Self.itemFields),
            ], as: PlaneWorkItem.self)
        } catch .workspaceUnavailable {
            return nil
        }
    }

    private func get<T: Decodable>(_ path: [String], query: [(String, String)], as: T.Type) async throws(PlaneAPIError) -> T {
        guard !token.isEmpty else { throw .notConnected }
        var url = workspace.apiBase
        for component in path { url.append(path: component) }
        url.append(path: "", directoryHint: .isDirectory)
        if !query.isEmpty { url.append(queryItems: query.map { URLQueryItem(name: $0.0, value: $0.1) }) }

        var request = URLRequest(url: url)
        request.setValue(token, forHTTPHeaderField: "X-API-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Tern", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await http.send(request)
        } catch let error as URLError {
            throw .network(error.code == .notConnectedToInternet ? "offline" : "unreachable")
        } catch {
            throw .network("unreachable")
        }

        switch response.statusCode {
        case 200..<300:
            break
        case 401:
            throw .invalidCredentials
        case 403:
            // v1-style endpoints answer 403 for a bad token; v2 uses 403 for missing access.
            let body = String(decoding: data.prefix(512), as: UTF8.self).lowercased()
            throw body.contains("token") && body.contains("not valid") ? .invalidCredentials : .workspaceUnavailable
        case 404:
            throw .workspaceUnavailable
        case 429:
            let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
            throw .rateLimited(until: reset ?? now().addingTimeInterval(60))
        default:
            throw .server(response.statusCode)
        }
        do {
            return try PlaneJSON.decoder.decode(T.self, from: data)
        } catch {
            throw .malformedResponse
        }
    }
}
