#if DEBUG
import SwiftUI

/// Debug-only GitHub sync status.
struct GitHubDiagnosticsView: View {
    let account: GitHubAccount

    private var sync: GitHubSyncService.Status { account.sync }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 6, height: 6)
                    Text("GitHub")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(phase)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    if account.login != nil {
                        Button("Sync") { account.syncNow() }
                            .buttonStyle(.borderless)
                            .font(.caption2)
                    }
                }
                Text("Last sync \(sync.lastSync.map { Age.compact(since: $0, now: context.date) } ?? "never") · \(sync.repositories) repos · \(sync.authoredOpen) authored · \(sync.reviewRequests) review requests")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text("Last error: \(sync.lastError ?? "none")")
                    .font(.caption2)
                    .foregroundStyle(sync.lastError == nil ? Color.secondary.opacity(0.6) : .orange)
                    .lineLimit(2)
            }
        }
    }

    private var phase: String {
        switch sync.phase {
        case .idle: account.login == nil ? "Disconnected" : "Connected"
        case .syncing: "Syncing…"
        case .unauthorized: "Unauthorized"
        case .rateLimited(let until): "Rate limited until \(until.formatted(date: .omitted, time: .shortened))"
        case .failing: "Retrying"
        }
    }

    private var dotColor: Color {
        switch sync.phase {
        case .idle: account.login == nil ? .secondary.opacity(0.5) : .green
        case .syncing: .blue
        case .unauthorized, .failing: .orange
        case .rateLimited: .yellow
        }
    }
}
#endif
