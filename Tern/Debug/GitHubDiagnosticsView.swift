#if DEBUG
import SwiftUI

/// Debug-only GitHub CLI and sync status. Shows no credentials, environment or headers.
struct GitHubDiagnosticsView: View {
    let account: GitHubAccount

    private var sync: GitHubSyncService.Status { account.sync }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            VStack(alignment: .leading, spacing: 2) {
                Text("GitHub CLI \(yesNo(sync.isCLIAvailable, yes: "available", no: "missing")) · authenticated \(yesNo(sync.isAuthenticated, yes: "yes", no: "no")) · \(sync.login.map { "@\($0)" } ?? "no account") on \(sync.host)")
                Text("Last sync \(sync.lastSync.map { Age.compact(since: $0, now: context.date) } ?? "never") · \(sync.repositories) repos · \(sync.authoredOpen) authored · \(sync.reviewRequests) review requests")
                Text("Last error: \(sync.lastError ?? "none")")
                    .foregroundStyle(sync.lastError == nil ? Color.secondary.opacity(0.6) : TernColor.warning)
                    .lineLimit(2)
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }

    private func yesNo(_ value: Bool?, yes: String, no: String) -> String {
        value.map { $0 ? yes : no } ?? "?"
    }
}
#endif
