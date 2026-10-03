import Foundation
import Observation
import os

/// UI-facing state. Mirrors snapshots published by `IngestionService` and groups
/// workstreams by whose turn it is. It does not ingest or evaluate anything itself.
@MainActor
@Observable
final class AppModel {
    private(set) var workstreams: [Workstream] = []
    private(set) var errorMessage: String?

    #if DEBUG
    /// Present only when running the mock scenario.
    let scenarioPlayer: ScenarioPlayer?
    #endif

    private let service: IngestionService
    private let logger = Logger(subsystem: "so.plane.tern", category: "app")

    #if DEBUG
    init(service: IngestionService, scenarioPlayer: ScenarioPlayer? = nil) {
        self.service = service
        self.scenarioPlayer = scenarioPlayer
        observe()
    }
    #else
    init(service: IngestionService) {
        self.service = service
        observe()
    }
    #endif

    /// DEBUG builds run the in-memory mock scenario; release builds load persisted state.
    static func makeDefault() -> AppModel {
        #if DEBUG
        let service = IngestionService(store: InMemoryTernStore())
        return AppModel(service: service, scenarioPlayer: ScenarioPlayer(service: service))
        #else
        do {
            return AppModel(service: IngestionService(store: JSONFileTernStore(url: try JSONFileTernStore.defaultURL())))
        } catch {
            let model = AppModel(service: IngestionService(store: InMemoryTernStore()))
            model.report(error)
            return model
        }
        #endif
    }

    // MARK: - Groupings

    /// Workstreams where the next action is mine, loudest and most recent first.
    var backWithYou: [Workstream] {
        workstreams
            .filter { $0.nextOwner == .me && $0.state != .complete }
            .sorted { lhs, rhs in
                if lhs.attention != rhs.attention { return lhs.attention > rhs.attention }
                return (lhs.lastMeaningfulChange ?? .distantPast) > (rhs.lastMeaningfulChange ?? .distantPast)
            }
    }

    /// Workstreams someone or something else is moving forward.
    var waiting: [Workstream] {
        workstreams
            .filter { $0.nextOwner != .me && $0.state != .complete }
            .sorted { ($0.lastMeaningfulChange ?? .distantPast) > ($1.lastMeaningfulChange ?? .distantPast) }
    }

    var done: [Workstream] {
        workstreams.filter { $0.state == .complete }
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
            }
        }
    }

    private func report(_ error: any Error) {
        logger.error("Tern failed to load state: \(error)")
        errorMessage = "Couldn't load saved state"
    }
}
