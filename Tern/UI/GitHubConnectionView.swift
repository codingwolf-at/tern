import SwiftUI

/// One compact row: GitHub connection state and the single action that fits it.
struct GitHubConnectionView: View {
    let account: GitHubAccount

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("GitHub")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer()
                actions
            }
            if case .authorizing(let code, let url) = account.state {
                HStack(spacing: 6) {
                    Text(code)
                        .font(.system(.callout, design: .monospaced).weight(.semibold))
                        .textSelection(.enabled)
                    Text("copied · enter it at")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Link(url.host() ?? "github.com", destination: url)
                        .font(.caption)
                }
            }
            if let error = account.connectError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var statusText: String {
        switch account.state {
        case .unconfigured: "No GitHub App configured in this build"
        case .disconnected: "Not connected"
        case .requestingCode: "Contacting GitHub…"
        case .authorizing: "Waiting for approval"
        case .connected(let login): login.map { "Connected as @\($0)" } ?? "Connected"
        case .needsReconnect: "Access expired"
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch account.state {
        case .unconfigured:
            EmptyView()
        case .disconnected, .needsReconnect:
            Button("Connect GitHub") { account.connect() }
                .buttonStyle(.borderless)
                .font(.caption)
        case .requestingCode, .authorizing:
            Button("Cancel") { account.cancel() }
                .buttonStyle(.borderless)
                .font(.caption)
        case .connected:
            Button("Disconnect") { account.disconnect() }
                .buttonStyle(.borderless)
                .font(.caption)
                .help("Removes Tern's token from this Mac. Revoke access on GitHub under Settings → Applications.")
        }
    }
}
