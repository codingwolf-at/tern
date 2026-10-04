#if DEBUG
import SwiftUI

/// Debug-only Plane sync status and declined associations. Shows no credentials.
struct PlaneDiagnosticsView: View {
    let account: PlaneAccount
    let unresolved: [AssociationIssue]

    private var sync: PlaneSyncService.Status { account.sync }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            VStack(alignment: .leading, spacing: 2) {
                Text("Plane \(phase) · workspace \(sync.workspace ?? "none") · last sync \(sync.lastSync.map { Age.compact(since: $0, now: context.date) } ?? "never")")
                Text("\(sync.activeItems) active items · \(sync.linkedWorkstreams) linked workstreams · \(unresolved.count) unresolved associations")
                ForEach(Array(unresolved.suffix(3).enumerated()), id: \.offset) { _, issue in
                    Text("\(issue.kind.rawValue): \(issue.references.map(\.value).joined(separator: ", ")) → \(issue.workstreams.map(\.rawValue).joined(separator: " | "))")
                        .lineLimit(1)
                        .foregroundStyle(.orange)
                }
                if let error = sync.lastError {
                    Text("Last error: \(error)").foregroundStyle(.orange)
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }

    private var phase: String {
        switch sync.phase {
        case .notConfigured: "not connected"
        case .missingToken: "no token"
        case .idle: "connected"
        case .syncing: "syncing"
        case .invalidCredentials: "token rejected"
        case .workspaceUnavailable: "workspace unavailable"
        case .rateLimited: "rate limited"
        case .failing: "retrying"
        }
    }
}
#endif
