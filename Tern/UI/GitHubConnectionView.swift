import SwiftUI

/// Compact GitHub status. Authentication belongs to the GitHub CLI, so there's no sign-in
/// here — only what's wrong and the command that fixes it.
struct GitHubConnectionView: View {
    let account: GitHubAccount

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.caption2)
                    .foregroundStyle(tint)
                Text("GitHub")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer()
                Button("Refresh") { account.refresh() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var summary: String {
        switch account.state {
        case .checking: "Checking GitHub CLI…"
        case .connected(let login): "Connected through GitHub CLI · @\(login)"
        case .cliUnavailable: "GitHub CLI unavailable"
        case .notAuthenticated: "GitHub CLI is not authenticated"
        case .rateLimited(let until): "Rate limited until \(until.formatted(date: .omitted, time: .shortened))"
        case .failing(let reason): reason
        }
    }

    private var hint: String? {
        switch account.state {
        case .cliUnavailable: "Install it with: brew install gh"
        case .notAuthenticated: "Run: gh auth login"
        default: nil
        }
    }

    private var symbol: String {
        switch account.state {
        case .connected: "circle.fill"
        case .checking: "circle"
        default: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch account.state {
        case .connected: TernColor.success
        case .checking: .secondary
        default: TernColor.warning
        }
    }
}
