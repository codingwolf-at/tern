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

    init(ingestion: IngestionService, source: any CalendarSource = EventKitCalendarSource(), startSyncing: Bool = true,
         now: @escaping @Sendable () -> Date = { .now }) {
        service = CalendarSyncService(source: source, ingestion: ingestion, now: now, schedulesRefreshes: startSyncing)
        Task { [weak self, service] in
            for await status in service.statusUpdates {
                self?.sync = status
            }
        }
        if startSyncing {
            Task { [service] in await service.start() }
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

    func refresh() {
        Task { [service] in await service.refresh() }
    }
}
