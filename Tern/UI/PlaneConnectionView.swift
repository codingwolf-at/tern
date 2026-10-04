import SwiftUI

/// Compact Plane status, with an inline form to connect a workspace using a personal access token.
struct PlaneConnectionView: View {
    let account: PlaneAccount

    @State private var isEditing = false
    @State private var workspace = ""
    @State private var api = PlaneWorkspace.cloudAPI.absoluteString
    @State private var token = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.caption2)
                    .foregroundStyle(tint)
                Text("Plane")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer()
                actions
            }
            if let buildHint {
                Text(buildHint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if isEditing || needsCredentials {
                form
            }
            if let error = account.connectError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(TernColor.critical)
            }
        }
        .onChange(of: account.state) { _, state in
            if case .connected = state { isEditing = false; token = "" }
        }
    }

    private var needsCredentials: Bool {
        switch account.state {
        case .invalidCredentials, .missingToken: true
        default: false
        }
    }

    /// Debug and Release keep separate Plane tokens, so a Debug build starts disconnected even
    /// when the installed Tern is connected.
    private var buildHint: String? {
        guard BuildEnvironment.current == .debug else { return nil }
        switch account.state {
        case .notConnected, .missingToken: return "This Debug build keeps its own Plane token, separate from the installed Tern. Connect once here; it stays across relaunches."
        default: return nil
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("Workspace") {
                TextField("slug, e.g. plane", text: $workspace)
            }
            LabeledContent("API") {
                TextField("https://api.plane.so", text: $api)
            }
            LabeledContent("Token") {
                SecureField("Personal access token", text: $token)
            }
            HStack {
                Text("Slug is the part after app.plane.so/. Change API only for self-hosted Plane. Token: Profile settings → Personal access tokens; stored in your Keychain.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Connect") { account.connect(workspace: workspace, api: api, token: token) }
                    .disabled(workspace.isEmpty || token.isEmpty || account.state == .connecting)
            }
        }
        .textFieldStyle(.roundedBorder)
        .font(.caption)
    }

    private var summary: String {
        switch account.state {
        case .notConnected: "Not connected"
        case .missingToken(let workspace): "No saved token for \(workspace)"
        case .connecting: "Connecting…"
        case .connected(let workspace, _) where isRetrying: "\(workspace) · can't reach Plane, retrying"
        case .connected(let workspace, let user): "\(workspace)\(user.map { " · \($0)" } ?? "")"
        case .invalidCredentials(let workspace): "Token for \(workspace) was rejected"
        case .workspaceUnavailable(let workspace): "Can't access \(workspace)"
        case .problem(let reason): reason
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch account.state {
        case .notConnected:
            Button(isEditing ? "Cancel" : "Connect…") { isEditing.toggle() }
                .buttonStyle(.borderless)
                .font(.caption)
        case .connecting:
            ProgressView().controlSize(.mini)
        case .missingToken:
            Button("Disconnect") { account.disconnect() }
                .buttonStyle(.borderless)
                .font(.caption)
        case .connected, .problem, .workspaceUnavailable, .invalidCredentials:
            Button("Refresh") { account.refresh() }
                .buttonStyle(.borderless)
                .font(.caption)
            Button("Disconnect") { account.disconnect() }
                .buttonStyle(.borderless)
                .font(.caption)
        }
    }

    private var symbol: String {
        switch account.state {
        case .connected where !isRetrying: "circle.fill"
        case .notConnected, .connecting: "circle"
        default: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch account.state {
        case .connected where !isRetrying: TernColor.success
        case .notConnected, .connecting: .secondary
        default: TernColor.warning
        }
    }

    /// Connected before, but the latest sync failed for a temporary reason. The token stays.
    private var isRetrying: Bool {
        account.sync.phase == .failing
    }
}
