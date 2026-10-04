import SwiftUI

/// Compact macOS notification status. Asks for permission only when the user presses Enable;
/// without it Tern keeps working, with in-app "New" markers and the badge.
struct NotificationConnectionView: View {
    let delivery: NotificationDelivery

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.caption2)
                    .foregroundStyle(tint)
                Text("Notifications")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer()
                actions
            }
            if let hint {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch delivery.authorization {
        case .notDetermined:
            Button("Enable…") { Task { await delivery.enable() } }
                .buttonStyle(.borderless)
                .font(.caption)
        case .denied, .unavailable:
            Button("Open Settings") { delivery.openSettings() }
                .buttonStyle(.borderless)
                .font(.caption)
        case .authorized:
            EmptyView()
        }
    }

    private var summary: String {
        switch delivery.authorization {
        case .notDetermined: "Not enabled"
        case .authorized: "Enabled"
        case .denied: "Off"
        case .unavailable: "Unavailable"
        }
    }

    private var hint: String? {
        switch delivery.authorization {
        case .notDetermined: "Only when it's your turn — the same moments that get a New marker."
        case .denied: "Turn on Tern under System Settings → Notifications. New markers still work."
        default: nil
        }
    }

    private var symbol: String {
        switch delivery.authorization {
        case .authorized: "circle.fill"
        case .notDetermined: "circle"
        case .denied, .unavailable: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch delivery.authorization {
        case .authorized: .green
        case .notDetermined: .secondary
        case .denied, .unavailable: .orange
        }
    }
}
