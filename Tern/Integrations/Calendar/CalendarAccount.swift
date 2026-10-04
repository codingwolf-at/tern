import AppKit
import Foundation
import Observation

/// UI-facing Calendar access: permission state, the calendars available to classify, and a
/// way to grant access. Reading and evaluating meetings happens in `CalendarSyncService`.
@MainActor
@Observable
final class CalendarAccount {
    private(set) var sync = CalendarSyncService.Status()
    let service: CalendarSyncService

    /// Privacy & Security → Calendars.
    static let privacySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!

    /// Reading starts when the app model calls `service.start()`, once ingestion is ready.
    /// `schedulesRefreshes` is off in tests, which refresh by hand with an injected clock.
    init(ingestion: IngestionService, source: any CalendarSource = EventKitCalendarSource(), schedulesRefreshes: Bool = true,
         now: @escaping @Sendable () -> Date = { .now }) {
        service = CalendarSyncService(source: source, ingestion: ingestion, now: now, schedulesRefreshes: schedulesRefreshes)
        Task { [weak self, service] in
            for await status in service.statusUpdates {
                self?.sync = status
            }
        }
    }

    var authorization: CalendarAuthorization { sync.authorization }
    var calendars: [CalendarInfo] { sync.calendars }

    /// Shows the macOS prompt. Only ever called from a button the user pressed.
    func requestAccess() {
        Task { [service] in await service.requestAccess() }
    }

    func openPrivacySettings() {
        NSWorkspace.shared.open(Self.privacySettingsURL)
    }

    /// Reads Calendar again: on opening the panel (which also notices access granted in System
    /// Settings) and from the Refresh button. Never asks for access.
    func refresh() {
        Task { [service] in await service.refresh() }
    }
}
