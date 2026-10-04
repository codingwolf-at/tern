import Foundation
import Observation
import os

/// UI-facing state. Mirrors snapshots published by `IngestionService` and groups
/// workstreams by whose turn it is. It does not ingest or evaluate anything itself.
@MainActor
@Observable
final class AppModel {
    private(set) var workstreams: [Workstream] = []
    /// Associations Tern declined to make (diagnostics only).
    private(set) var unresolvedAssociations: [AssociationIssue] = []
    private(set) var errorMessage: String?
    /// Entry point for Claude Code hook events. Owned here so diagnostics can observe it.
    let claudeHooks: ClaudeHookReceiver
    /// GitHub connection and sync status; `nil` when GitHub isn't part of this model (tests).
    let github: GitHubAccount?
    /// Plane connection and sync status; `nil` when Plane isn't part of this model (tests).
    let plane: PlaneAccount?

    #if DEBUG
    /// Present only when running the mock scenario.
    let scenarioPlayer: ScenarioPlayer?
    #endif

    private let service: IngestionService
    private let logger = Logger(subsystem: "so.plane.tern", category: "app")

    #if DEBUG
    init(service: IngestionService, github: GitHubAccount? = nil, plane: PlaneAccount? = nil, scenarioPlayer: ScenarioPlayer? = nil) {
        self.service = service
        self.claudeHooks = ClaudeHookReceiver(service: service)
        self.github = github
        self.plane = plane
        self.scenarioPlayer = scenarioPlayer
        observe()
    }
    #else
    init(service: IngestionService, github: GitHubAccount? = nil, plane: PlaneAccount? = nil) {
        self.service = service
        self.claudeHooks = ClaudeHookReceiver(service: service)
        self.github = github
        self.plane = plane
        observe()
    }
    #endif

    /// DEBUG builds run in memory with the mock scenario (set `TERN_MOCK=0` to start empty and
    /// see only real Claude Code sessions); release builds load persisted state.
    static func makeDefault() -> AppModel {
        // Import progress now lives in the persisted state; drop the old build-shared marker.
        UserDefaults.standard.removeObject(forKey: "github.importedLogins")
        #if DEBUG
        let service = IngestionService(store: InMemoryTernStore())
        let useMock = ProcessInfo.processInfo.environment["TERN_MOCK"] != "0"
        return AppModel(
            service: service,
            github: GitHubAccount(ingestion: service),
            plane: PlaneAccount(ingestion: service),
            scenarioPlayer: useMock ? ScenarioPlayer(service: service) : nil
        )
        #else
        do {
            let service = IngestionService(store: JSONFileTernStore(url: try JSONFileTernStore.defaultURL()))
            return AppModel(service: service, github: GitHubAccount(ingestion: service), plane: PlaneAccount(ingestion: service))
        } catch {
            let model = AppModel(service: IngestionService(store: InMemoryTernStore()))
            model.report(error)
            return model
        }
        #endif
    }

    // MARK: - Queue

    /// At most this many items interrupt at the top of the panel.
    static let needsYouLimit = 3
    /// Waiting items shown before the rest collapse.
    static let waitingLimit = 4

    private(set) var importance: [String: RepositoryImportance] = [:]
    /// The clock used for recency and "today"; injectable for tests.
    var now: @Sendable () -> Date = { .now }

    func importance(of workstream: Workstream) -> RepositoryImportance {
        workstream.repositoryKey.flatMap { importance[$0] } ?? .normal
    }

    func priority(of workstream: Workstream) -> Priority {
        PriorityModel.priority(of: workstream, importance: importance(of: workstream), now: now())
    }

    private func ranked(_ workstreams: [Workstream]) -> [Workstream] {
        PriorityModel.ranked(workstreams, importance: importance(of:), now: now())
    }

    /// Everything that warrants an interruption, best first. Muted repositories never interrupt.
    var attentionQueue: [Workstream] {
        ranked(workstreams.filter { $0.needsAttentionNow && importance(of: $0) != .muted })
    }

    /// The few things worth dealing with now.
    var needsYou: [Workstream] {
        Array(attentionQueue.prefix(Self.needsYouLimit))
    }

    /// Lower-priority items that would also warrant attention, kept out of the way.
    var more: [Workstream] {
        Array(attentionQueue.dropFirst(Self.needsYouLimit))
            + ranked(workstreams.filter { $0.needsAttentionNow && importance(of: $0) == .muted })
    }

    /// Someone else (a reviewer, CI, an author) owes the next step.
    var waiting: [Workstream] {
        ranked(workstreams.filter { [.reviewer, .ci, .external].contains($0.nextOwner) && $0.state != .complete })
    }

    /// An agent is working on it right now.
    var active: [Workstream] {
        ranked(workstreams.filter { $0.nextOwner == .agent && $0.state != .complete })
    }

    /// Yours, but nothing to interrupt for: drafts, PRs without reviewers, planned items
    /// nobody has started.
    var yourWork: [Workstream] {
        ranked(workstreams.filter { workstream in
            guard workstream.state != .complete else { return false }
            if workstream.nextOwner == .none { return true }
            return workstream.nextOwner == .me && !workstream.needsAttentionNow
        })
    }

    /// Finished today. Older completed work stays in history but out of the panel.
    var doneToday: [Workstream] {
        let calendar = Calendar.current
        let today = now()
        return workstreams.filter { workstream in
            guard workstream.state == .complete, let changed = workstream.lastMeaningfulChange else { return false }
            return calendar.isDate(changed, inSameDayAs: today)
        }
    }

    /// Marks how much a repository matters. Saved with Tern's state.
    func setImportance(_ value: RepositoryImportance, for workstream: Workstream) {
        guard let repository = workstream.pullRequest?.repository else { return }
        Task { [service] in try? await service.setImportance(value, forRepository: repository) }
    }

    // MARK: - Service

    private func observe() {
        Task { [weak self, service] in
            do {
                try await service.start()
            } catch {
                self?.report(error)
                return
            }
            #if DEBUG
            await self?.scenarioPlayer?.seed()
            #endif
            for await snapshot in service.updates {
                guard let self else { return }
                self.workstreams = snapshot.workstreams
                self.unresolvedAssociations = snapshot.unresolvedAssociations
                self.importance = snapshot.repositoryImportance
            }
        }
    }

    private func report(_ error: any Error) {
        logger.error("Tern failed to load state: \(error)")
        errorMessage = "Couldn't load saved state"
    }
}
