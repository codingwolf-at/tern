import Foundation

/// The network boundary for GitHub. Tests substitute a stub.
protocol GitHubHTTP: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionGitHubHTTP: GitHubHTTP {
    let session: URLSession

    init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

enum GitHubAPIError: Error, Equatable, Sendable {
    /// Token missing, revoked or expired.
    case unauthorized
    case rateLimited(until: Date)
    case network(String)
    case server(status: Int)
    case graphQL([String])
    case decoding

    var summary: String {
        switch self {
        case .unauthorized: "Not authorized"
        case .rateLimited(let until): "Rate limited until \(until.formatted(date: .omitted, time: .shortened))"
        case .network(let reason): "Network: \(reason)"
        case .server(let status): "GitHub error \(status)"
        case .graphQL(let messages): "GitHub: \(messages.first ?? "query failed")"
        case .decoding: "Unexpected response from GitHub"
        }
    }
}

/// Read-only GraphQL client.
struct GitHubClient: Sendable {
    static let endpoint = URL(string: "https://api.github.com/graphql")!

    let http: any GitHubHTTP
    let now: @Sendable () -> Date

    /// Sends a query. Returns decoded data together with any partial errors GitHub reported.
    func query<Payload: Decodable & Sendable>(
        _ document: String,
        variables: [String: GraphQLValue],
        token: String,
        as: Payload.Type
    ) async throws(GitHubAPIError) -> (Payload, [GitHubGraphQLError]) {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Tern", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        do {
            request.httpBody = try JSONEncoder().encode(GraphQLBody(query: document, variables: variables))
        } catch {
            throw .decoding
        }

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await http.send(request)
        } catch let error as URLError {
            throw .network(error.code == .notConnectedToInternet ? "offline" : "\(error.code.rawValue)")
        } catch {
            throw .network("unavailable")
        }

        switch response.statusCode {
        case 200: break
        case 401: throw .unauthorized
        case 403, 429:
            if let until = rateLimitReset(response) { throw .rateLimited(until: until) }
            throw .server(status: response.statusCode)
        default: throw .server(status: response.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let body = try? decoder.decode(GitHubGraphQLResponse<Payload>.self, from: data) else { throw .decoding }
        let errors = body.errors ?? []
        if errors.contains(where: { $0.type == "RATE_LIMITED" }) {
            throw .rateLimited(until: rateLimitReset(response) ?? now().addingTimeInterval(15 * 60))
        }
        guard let payload = body.data else { throw .graphQL(errors.map(\.message)) }
        return (payload, errors)
    }

    private func rateLimitReset(_ response: HTTPURLResponse) -> Date? {
        if let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) {
            return now().addingTimeInterval(retryAfter)
        }
        if response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0",
           let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(TimeInterval.init) {
            return Date(timeIntervalSince1970: reset)
        }
        return nil
    }
}

/// JSON values for GraphQL variables.
enum GraphQLValue: Encodable, Sendable, Hashable {
    case string(String)
    case strings([String])

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .strings(let values): try container.encode(values)
        }
    }
}

private struct GraphQLBody: Encodable {
    let query: String
    let variables: [String: GraphQLValue]
}
