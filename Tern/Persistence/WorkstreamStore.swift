/// Storage boundary for workstreams and their event history.
/// Phase 1 keeps everything in memory; a durable store can conform later without
/// touching the domain or engine.
protocol WorkstreamStore: Sendable {
    func loadAll() async -> [Workstream]
    func save(_ workstream: Workstream) async
}

actor InMemoryWorkstreamStore: WorkstreamStore {
    private var order: [WorkstreamID] = []
    private var storage: [WorkstreamID: Workstream] = [:]

    init(_ workstreams: [Workstream] = []) {
        for workstream in workstreams {
            order.append(workstream.id)
            storage[workstream.id] = workstream
        }
    }

    func loadAll() -> [Workstream] {
        order.compactMap { storage[$0] }
    }

    func save(_ workstream: Workstream) {
        if storage[workstream.id] == nil {
            order.append(workstream.id)
        }
        storage[workstream.id] = workstream
    }
}
