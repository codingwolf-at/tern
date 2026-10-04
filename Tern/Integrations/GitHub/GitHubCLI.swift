import Foundation

// Tern reaches GitHub only through the user's installed, authenticated GitHub CLI.
// Authentication stays inside `gh`: Tern never asks for, receives, stores or refreshes a
// token, and it never runs `gh auth token` or `gh auth status --show-token`.

/// Raw result of one `gh` invocation.
struct GitHubCLIOutput: Sendable, Hashable {
    let stdout: Data
    let stderr: String
    let exitCode: Int32
}

/// Runs `gh` with arguments and optional stdin. Tests substitute a fake.
protocol GitHubCLIRunner: Sendable {
    func run(_ arguments: [String], input: Data?) async throws(GitHubAPIError) -> GitHubCLIOutput
}

enum GitHubAPIError: Error, Equatable, Sendable {
    /// `gh` isn't installed (or can't be found).
    case cliNotFound
    /// `gh` has no working login for github.com (never logged in, logged out, or token rejected).
    case notAuthenticated
    case rateLimited(until: Date)
    case network(String)
    /// GitHub or `gh` reported an error.
    case api(String)
    /// `gh` succeeded but its output wasn't the expected JSON.
    case malformedOutput

    var summary: String {
        switch self {
        case .cliNotFound: "GitHub CLI not found"
        case .notAuthenticated: "GitHub CLI is not authenticated"
        case .rateLimited(let until): "Rate limited until \(until.formatted(date: .omitted, time: .shortened))"
        case .network(let reason): "Network: \(reason)"
        case .api(let message): "GitHub: \(message)"
        case .malformedOutput: "Unexpected output from GitHub CLI"
        }
    }
}

// MARK: - Locating gh

/// Finds the `gh` executable. Apps launched from Finder get a minimal PATH, so after PATH
/// this checks where Homebrew, MacPorts, Nix and manual installs put it.
struct GitHubCLILocator: Sendable {
    var environment: [String: String] = ProcessInfo.processInfo.environment
    var homeDirectory: String = NSHomeDirectory()
    var isExecutable: @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }

    var candidates: [String] {
        var paths: [String] = []
        if let override = environment["TERN_GH_PATH"], !override.isEmpty { paths.append(override) }
        for directory in (environment["PATH"] ?? "").split(separator: ":") where !directory.isEmpty {
            paths.append("\(directory)/gh")
        }
        paths += [
            "/opt/homebrew/bin/gh",
            "/usr/local/bin/gh",
            "\(homeDirectory)/.local/bin/gh",
            "\(homeDirectory)/bin/gh",
            "/opt/local/bin/gh",
            "\(homeDirectory)/.nix-profile/bin/gh",
            "/run/current-system/sw/bin/gh",
            "/nix/var/nix/profiles/default/bin/gh",
        ]
        var seen: Set<String> = []
        return paths.filter { seen.insert($0).inserted }
    }

    func locate() -> URL? {
        candidates.first(where: isExecutable).map { URL(fileURLWithPath: $0) }
    }
}

// MARK: - Running gh

/// Runs the real `gh` as a child process. Output is read concurrently with execution, so
/// large responses can't deadlock on a full pipe. Arguments and output are never logged.
struct ProcessGitHubCLIRunner: GitHubCLIRunner {
    var locator = GitHubCLILocator()
    var timeout: TimeInterval = 60

    func run(_ arguments: [String], input: Data?) async throws(GitHubAPIError) -> GitHubCLIOutput {
        guard let executable = locator.locate() else { throw .cliNotFound }
        return try await Self.execute(executable, arguments, input: input, environment: environment(for: executable), timeout: timeout)
    }

    /// The user's environment, plus settings that keep `gh` non-interactive and machine-readable.
    private func environment(for executable: URL) -> [String: String] {
        var environment = locator.environment
        let directory = executable.deletingLastPathComponent().path
        let path = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = path.split(separator: ":").contains(Substring(directory)) ? path : "\(directory):\(path)"
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["GH_NO_UPDATE_NOTIFIER"] = "1"
        environment["GH_SPINNER_DISABLED"] = "1"
        environment["NO_COLOR"] = "1"
        environment["CLICOLOR"] = "0"
        return environment
    }

    static func execute(
        _ executable: URL,
        _ arguments: [String],
        input: Data?,
        environment: [String: String],
        timeout: TimeInterval
    ) async throws(GitHubAPIError) -> GitHubCLIOutput {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        let stdout = Pipe(), stderr = Pipe(), stdin = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = stdin

        let exited = AsyncStream<Int32>.makeStream(bufferingPolicy: .bufferingNewest(1))
        process.terminationHandler = { exited.continuation.yield($0.terminationStatus); exited.continuation.finish() }
        do {
            try process.run()
        } catch {
            throw .cliNotFound
        }

        async let output = readToEnd(stdout.fileHandleForReading)
        async let errors = readToEnd(stderr.fileHandleForReading)
        DispatchQueue.global().async {
            if let input { try? stdin.fileHandleForWriting.write(contentsOf: input) }
            try? stdin.fileHandleForWriting.close()
        }
        let watchdog = Task {
            try await Task.sleep(for: .seconds(timeout))
            if process.isRunning { process.terminate() }
        }
        var status: Int32 = -1
        for await code in exited.stream { status = code }
        watchdog.cancel()

        let (out, err) = await (output, errors)
        if process.terminationReason == .uncaughtSignal && status == SIGTERM {
            throw .network("GitHub CLI timed out")
        }
        return GitHubCLIOutput(stdout: out, stderr: String(decoding: err, as: UTF8.self), exitCode: status)
    }

    private static func readToEnd(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: (try? handle.readToEnd()) ?? Data())
            }
        }
    }
}

// MARK: - GitHub through gh

/// Who `gh` is logged in as on github.com. Never contains token material.
struct GitHubAuthStatus: Sendable, Hashable {
    let host: String
    let login: String?
    let isAuthenticated: Bool
    /// Where `gh` keeps the credential (`keyring`, `GH_TOKEN`, …) — a label, not the token.
    let tokenSource: String?
}

/// Read-only GitHub access via `gh api` and `gh auth status`.
struct GitHubCLI: Sendable {
    static let host = "github.com"

    let runner: any GitHubCLIRunner
    let now: @Sendable () -> Date

    init(runner: any GitHubCLIRunner = ProcessGitHubCLIRunner(), now: @escaping @Sendable () -> Date = { .now }) {
        self.runner = runner
        self.now = now
    }

    /// Runs a GraphQL query with `gh api graphql`, sending the request body on stdin.
    /// Returns decoded data with any partial errors GitHub reported alongside it.
    func graphQL<Payload: Decodable & Sendable>(
        _ document: String,
        variables: [String: GraphQLValue],
        as: Payload.Type
    ) async throws(GitHubAPIError) -> (Payload, [GitHubGraphQLError]) {
        let body: Data
        do {
            body = try JSONEncoder().encode(GraphQLBody(query: document, variables: variables))
        } catch {
            throw .malformedOutput
        }
        let output = try await runner.run(["api", "graphql", "--hostname", Self.host, "--input", "-"], input: body)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // `gh` exits non-zero when GitHub returns partial errors, but stdout still holds the data.
        if let response = try? decoder.decode(GitHubGraphQLResponse<Payload>.self, from: output.stdout) {
            let errors = response.errors ?? []
            if errors.contains(where: { $0.type == "RATE_LIMITED" }) {
                throw .rateLimited(until: now().addingTimeInterval(15 * 60))
            }
            if let data = response.data { return (data, errors) }
            if !errors.isEmpty { throw .api(errors[0].message) }
        }
        throw Self.classify(output, now: now())
    }

    /// The active github.com account according to `gh auth status`.
    func authStatus() async throws(GitHubAPIError) -> GitHubAuthStatus {
        let output = try await runner.run(["auth", "status", "--active", "--hostname", Self.host, "--json", "hosts"], input: nil)
        struct Response: Decodable {
            struct Account: Decodable {
                let state: String?
                let active: Bool?
                let login: String?
                let tokenSource: String?
            }
            let hosts: [String: [Account]]
        }
        guard output.exitCode == 0 || output.exitCode == 1,
              let response = try? JSONDecoder().decode(Response.self, from: output.stdout)
        else { throw Self.classify(output, now: now()) }
        let account = response.hosts[Self.host]?.first { $0.active ?? true }
        let authenticated = account?.state == "success" && !(account?.login ?? "").isEmpty
        return GitHubAuthStatus(
            host: Self.host,
            login: authenticated ? account?.login : nil,
            isAuthenticated: authenticated,
            tokenSource: account?.tokenSource
        )
    }

    /// Maps a failed `gh` run to an error, from its exit status and stderr.
    static func classify(_ output: GitHubCLIOutput, now: Date) -> GitHubAPIError {
        let message = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = message.lowercased()
        if output.exitCode == 0 { return .malformedOutput }
        if output.exitCode == 4 || lowered.contains("gh auth login") || lowered.contains("(http 401)") || lowered.contains("bad credentials") {
            return .notAuthenticated
        }
        if lowered.contains("rate limit") {
            return .rateLimited(until: now.addingTimeInterval(15 * 60))
        }
        let networkSignals = ["dial tcp", "no such host", "timeout", "connection refused", "network is unreachable", "tls handshake", "error connecting"]
        if networkSignals.contains(where: lowered.contains) {
            return .network(lowered.contains("timeout") ? "timed out" : "unreachable")
        }
        // First line only, without the `gh:` prefix; stderr never carries tokens, but keep it short.
        let firstLine = message.split(separator: "\n").first.map(String.init) ?? "exit \(output.exitCode)"
        let cleaned = firstLine.hasPrefix("gh: ") ? String(firstLine.dropFirst(4)) : firstLine
        return .api(redacted(String(cleaned.prefix(160))))
    }

    /// Masks anything shaped like a GitHub token (`ghp_…`, `gho_…`, `github_pat_…`).
    static func redacted(_ text: String) -> String {
        text.replacing(/(gh[opsur]_|github_pat_)[A-Za-z0-9_]+/) { $0.output.1 + "<redacted>" }
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
