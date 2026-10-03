import Foundation
@testable import Tern

/// Builds a workstream history one event at a time, a minute apart, from a fixed origin.
struct EventFixture {
    let workstreamID = WorkstreamID("test-workstream")
    private(set) var events: [WorkEvent] = []
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    @discardableResult
    mutating func add(
        _ kind: WorkEventKind,
        from source: EventSource,
        _ metadata: [MetadataKey: String] = [:]
    ) -> WorkEvent {
        clock = clock.addingTimeInterval(60)
        let event = WorkEvent(
            workstreamID: workstreamID,
            source: source,
            kind: kind,
            timestamp: clock,
            metadata: Dictionary(uniqueKeysWithValues: metadata.map { ($0.key.rawValue, $0.value) })
        )
        events.append(event)
        return event
    }

    var workstream: Workstream {
        Workstream(id: workstreamID, title: "Test", events: events)
    }

    static let claude: [MetadataKey: String] = [.agentName: "Claude Code", .agentSessionID: "s1"]
}
