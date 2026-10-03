import Foundation
import Observation

/// UI-facing state. Owns the store and engine and exposes workstreams grouped by whose turn it is.
@MainActor
@Observable
final class AppModel {
    private(set) var workstreams: [Workstream] = []
    /// How many events of the featured scenario have been played.
    private(set) var scenarioStep: Int

    let scenario: MockScenario
    private let engine = AttentionEngine()
    private let store: any WorkstreamStore

    init(scenario: MockScenario = MockScenario()) {
        self.scenario = scenario
        self.scenarioStep = scenario.avatarMigrationScript.count
        self.store = InMemoryWorkstreamStore()
        Task { await load() }
    }

    var scenarioLength: Int { scenario.avatarMigrationScript.count }

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

    // MARK: - Loading

    func load() async {
        if await store.loadAll().isEmpty {
            var featured = scenario.avatarMigrationShell
            featured.events = scenario.avatarMigrationScript
            for workstream in [featured] + scenario.otherWorkstreams {
                await store.save(engine.rebuild(workstream))
            }
        }
        workstreams = await store.loadAll()
    }

    // MARK: - Scenario playback

    /// Plays the next scripted event through the engine, as a live integration would.
    func stepForward() {
        guard scenarioStep < scenarioLength, let current = featured else { return }
        let event = scenario.avatarMigrationScript[scenarioStep]
        scenarioStep += 1
        commit(engine.ingest(event, into: current))
    }

    func stepBackward() {
        guard scenarioStep > 0 else { return }
        replay(to: scenarioStep - 1)
    }

    func restartScenario() {
        replay(to: 0)
    }

    private var featured: Workstream? {
        workstreams.first { $0.id == MockScenario.avatarMigrationID }
    }

    private func replay(to step: Int) {
        guard var current = featured else { return }
        scenarioStep = step
        current.events = Array(scenario.avatarMigrationScript.prefix(step))
        current.calendarContext = nil
        commit(engine.rebuild(current))
    }

    private func commit(_ workstream: Workstream) {
        if let index = workstreams.firstIndex(where: { $0.id == workstream.id }) {
            workstreams[index] = workstream
        }
        Task { await store.save(workstream) }
    }
}
