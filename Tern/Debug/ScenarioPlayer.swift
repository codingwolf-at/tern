#if DEBUG
import Foundation
import Observation
import os

/// Debug-only driver that plays the mock scenario into the ingestion service,
/// standing in for real integrations.
@MainActor
@Observable
final class ScenarioPlayer {
    let scenario: MockScenario
    /// How many events of the featured script have been ingested.
    private(set) var step = 0

    private let service: IngestionService
    private let logger = Logger(subsystem: "so.plane.tern", category: "scenario")

    init(service: IngestionService, scenario: MockScenario = MockScenario()) {
        self.service = service
        self.scenario = scenario
    }

    var length: Int { scenario.avatarMigrationScript.count }

    /// Imports the scenario silently, then plays the final event live so the panel
    /// opens on a fresh "back with you" transition.
    func seed() async {
        do {
            try await scenario.seed(into: service, liveTail: 1)
            step = length - 1
            await stepForward()
        } catch {
            logger.error("Seeding mock scenario failed: \(error)")
        }
    }

    func stepForward() async {
        guard step < length else { return }
        let event = scenario.avatarMigrationScript[step]
        step += 1
        do {
            try await service.ingest([event], mode: .live)
        } catch {
            logger.error("Ingesting scripted event failed: \(error)")
        }
    }

    func stepBackward() async {
        guard step > 0 else { return }
        await replay(to: step - 1)
    }

    func restart() async {
        await replay(to: 0)
    }

    private func replay(to target: Int) async {
        step = target
        do {
            try await service.debugReplaceHistory(
                of: MockScenario.avatarMigrationID,
                with: Array(scenario.avatarMigrationScript.prefix(target))
            )
        } catch {
            logger.error("Replaying scenario failed: \(error)")
        }
    }
}
#endif
