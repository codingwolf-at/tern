import Foundation

/// Converts Plane work items into domain `ObservedEvent`s.
///
/// A work item is the identity of its workstream: its events carry the item's own reference,
/// so a pull request or Claude session that named the item (`fix/WEB-9295-…`) is found and
/// joined. Plane state is recorded as Plane state only; it never decides ownership.
///
/// | Event                 | ID                                                   |
/// |-----------------------|------------------------------------------------------|
/// | Item seen             | `plane:item:<workspace>:<item-id>:created`           |
/// | State / assignment    | `plane:item:<workspace>:<item-id>:state:<state-id>:<assigned>:<updated-at>` |
/// | Archived or removed   | `plane:item:<workspace>:<item-id>:removed`           |
struct PlaneNormalizer: Sendable {
    let workspace: PlaneWorkspace
    let userID: String

    func events(for item: PlaneWorkItem) -> [ObservedEvent] {
        guard let identifier = item.identifier?.uppercased() else { return [] }
        let assignedToMe = (item.assigneeIDs ?? []).contains(userID)
        var state: [MetadataKey: String] = [.assignedToMe: String(assignedToMe), .planeItemID: item.id]
        if let name = item.state?.name { state[.stateName] = name }
        if let group = item.state?.group { state[.stateGroup] = group }

        var events = [
            event(item, identifier, "created", .planeItemCreated, at: item.createdAt, state),
            event(item, identifier, "state:\(item.stateID ?? "-"):\(assignedToMe ? 1 : 0):\(stamp(item.updatedAt ?? item.createdAt))",
                  .planeItemStateChanged, at: item.updatedAt ?? item.createdAt, state),
        ]
        if let archived = item.archivedAt {
            events.append(event(item, identifier, "removed", .planeItemRemoved, at: archived, [.planeItemID: item.id]))
        }
        return events
    }

    /// The item is gone (deleted, archived or no longer visible to this account).
    func removed(itemID: String, identifier: String, title: String?, at date: Date) -> ObservedEvent {
        let reference = ExternalReference.planeItem(identifier)
        return ObservedEvent(
            id: EventID(.plane, "item", workspace.slug, itemID, "removed"),
            source: .plane,
            kind: .planeItemRemoved,
            timestamp: date,
            metadata: [.planeItemID: itemID],
            references: [reference],
            allowsNewWorkstream: false
        )
    }

    private func event(_ item: PlaneWorkItem, _ identifier: String, _ change: String, _ kind: WorkEventKind, at date: Date, _ metadata: [MetadataKey: String]) -> ObservedEvent {
        let reference = ExternalReference.planeItem(identifier)
        let url = workspace.itemURL(identifier)
        var metadata = metadata
        metadata[.title] = item.name
        return ObservedEvent(
            id: EventID(.plane, "item", workspace.slug, item.id, change),
            source: .plane,
            kind: kind,
            timestamp: date,
            metadata: metadata,
            references: [reference],
            suggestedTitle: item.name,
            workstreamKey: reference,
            planeItem: PlaneItemReference(identifier: identifier, title: item.name, url: url)
        )
    }

    private func stamp(_ date: Date) -> String {
        String(Int(date.timeIntervalSince1970 * 1000))
    }
}
