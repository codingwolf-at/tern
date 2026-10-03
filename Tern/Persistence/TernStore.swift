import Foundation
import Synchronization

/// Storage boundary for `PersistedState`. Synchronous on purpose: the ingestion actor
/// calls it without suspending, so concurrent ingests cannot interleave a save.
protocol TernStore: Sendable {
    func load() throws -> PersistedState
    func save(_ state: PersistedState) throws
}

/// Keeps state in memory. Used by tests and the DEBUG mock scenario.
final class InMemoryTernStore: TernStore {
    private let state: Mutex<PersistedState>

    init(_ state: PersistedState = PersistedState()) {
        self.state = Mutex(state)
    }

    func load() -> PersistedState {
        state.withLock { $0 }
    }

    func save(_ newState: PersistedState) {
        state.withLock { $0 = newState }
    }
}

/// Stores state as a JSON file, written atomically.
struct JSONFileTernStore: TernStore {
    let url: URL

    /// `~/Library/Containers/<bundle>/Data/Library/Application Support/Tern/state.json` under the sandbox.
    static func defaultURL() throws -> URL {
        try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "Tern", directoryHint: .isDirectory)
            .appending(path: "state.json", directoryHint: .notDirectory)
    }

    func load() throws -> PersistedState {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return PersistedState()
        }
        let state = try JSONDecoder().decode(PersistedState.self, from: Data(contentsOf: url))
        guard state.version == PersistedState.currentVersion else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSDebugDescriptionErrorKey: "Unsupported state version \(state.version)"])
        }
        return state
    }

    func save(_ state: PersistedState) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
    }
}
