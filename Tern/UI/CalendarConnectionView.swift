import SwiftUI

/// Compact Calendar status: asks for access only when the user presses the button, explains a
/// denial once, and lets each calendar be filed under Personal or Professional.
struct CalendarConnectionView: View {
    let account: CalendarAccount
    let rules: ContextRules
    let classify: (TernContext?, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.caption2)
                    .foregroundStyle(tint)
                Text("Calendar")
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
            if account.authorization == .granted, !account.calendars.isEmpty {
                calendarList
            }
        }
    }

    private var unclassified: [CalendarInfo] {
        account.calendars.filter { rules.calendars[$0.id] == nil }
    }

    /// Every calendar with its context. Unclassified ones play no part until filed.
    private var calendarList: some View {
        DisclosureGroup {
            ForEach(account.calendars) { calendar in
                HStack(spacing: 6) {
                    Text(calendar.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let source = calendar.account {
                        Text(source)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Menu(rules.calendars[calendar.id]?.title ?? "Unclassified") {
                        ForEach(TernContext.allCases, id: \.self) { context in
                            Button { classify(context, calendar.id) } label: {
                                if rules.calendars[calendar.id] == context { Label(context.title, systemImage: "checkmark") } else { Text(context.title) }
                            }
                        }
                        if rules.calendars[calendar.id] != nil {
                            Button("Unclassified") { classify(nil, calendar.id) }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .font(.caption)
                }
            }
        } label: {
            Text(unclassified.isEmpty ? "CALENDARS · \(account.calendars.count)" : "UNCLASSIFIED CALENDARS · \(unclassified.count)")
                .font(.caption2.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
                .help("Only Personal and Professional calendars are read. Unclassified calendars are ignored.")
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch account.authorization {
        case .notDetermined:
            Button("Allow access…") { account.requestAccess() }
                .buttonStyle(.borderless)
                .font(.caption)
        case .denied:
            Button("Open Settings") { account.openPrivacySettings() }
                .buttonStyle(.borderless)
                .font(.caption)
        case .granted:
            Button("Refresh") { account.refresh() }
                .buttonStyle(.borderless)
                .font(.caption)
        case .restricted:
            EmptyView()
        }
    }

    private var summary: String {
        let total = account.calendars.count
        return switch account.authorization {
        case .notDetermined: "Access required"
        case .denied: "Access off"
        case .restricted: "Access restricted on this Mac"
        case .granted where account.sync.lastError != nil: account.sync.lastError ?? ""
        case .granted where total == 0: "No calendars"
        case .granted: "\(total - unclassified.count) of \(total) calendar\(total == 1 ? "" : "s") in use"
        }
    }

    private var hint: String? {
        switch account.authorization {
        case .notDetermined: "Tern reads upcoming meetings, read-only, to tell you when one is about to start."
        case .denied: "Turn on Tern under Privacy & Security → Calendars. Everything else works without it."
        case .granted where !account.calendars.isEmpty && unclassified.count == account.calendars.count:
            "Mark a calendar Personal or Professional to see its meetings."
        default: nil
        }
    }

    private var symbol: String {
        switch account.authorization {
        case .granted where account.sync.lastError == nil: "circle.fill"
        case .notDetermined: "circle"
        default: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch account.authorization {
        case .granted where account.sync.lastError == nil: .green
        case .notDetermined: .secondary
        default: .orange
        }
    }
}
