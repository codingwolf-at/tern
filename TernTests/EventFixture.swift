import Foundation
@testable import Tern

/// Builds a workstream history one event at a time, a minute apart, from a fixed origin.
/// Every event gets a stable, sequential ID.
struct EventFixture {
    static let workstreamID = WorkstreamID("test-workstream")
    static let reference = ExternalReference.planeItem("TEST-1")
    static let origin = Date(timeIntervalSince1970: 1_800_000_000)

    private(set) var observed: [ObservedEvent] = []
    private var clock = EventFixture.origin

    var events: [WorkEvent] {
        observed.map { $0.linked(to: Self.workstreamID) }
    }

    @discardableResult
    mutating func add(
        _ kind: WorkEventKind,
        from source: EventSource,
        _ metadata: [MetadataKey: String] = [:]
    ) -> ObservedEvent {
        clock = clock.addingTimeInterval(60)
        let event = Self.event(kind, from: source, id: "e\(observed.count + 1)", at: clock, metadata)
        observed.append(event)
        return event
    }

    static func event(
        _ kind: WorkEventKind,
        from source: EventSource,
        id: String,
        at timestamp: Date,
        _ metadata: [MetadataKey: String] = [:]
    ) -> ObservedEvent {
        ObservedEvent(
            id: EventID(source, "test", id),
            source: source,
            kind: kind,
            timestamp: timestamp,
            metadata: metadata,
            references: [reference]
        )
    }

    static func claude(_ session: String = "s1") -> [MetadataKey: String] {
        [.agentName: "Claude Code", .agentSessionID: session]
    }
}

/// A started service over an in-memory store, with the fixture's workstream registered.
func makeService(store: InMemoryTernStore = InMemoryTernStore()) async throws -> IngestionService {
    let service = IngestionService(store: store, now: { EventFixture.origin }, scoping: .ignoringContexts)
    try await service.start()
    try await service.register(EventFixture.workstreamID, title: "Test", references: [EventFixture.reference])
    return service
}

extension IngestionService {
    func workstream(_ id: WorkstreamID = EventFixture.workstreamID) -> Workstream? {
        snapshot.workstreams.first { $0.id == id }
    }
}
