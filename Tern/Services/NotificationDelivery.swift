import AppKit
import Foundation
import Observation
import os
import UserNotifications

/// Whether macOS lets Tern show notifications.
enum NotificationAuthorization: Sendable, Equatable {
    /// Never asked. Tern asks only when the user presses Enable.
    case notDetermined
    case authorized
    case denied
    /// The notification system couldn't be reached.
    case unavailable
}

/// A notification as Tern hands it to macOS. Only identifiers in `subjectID`; no links.
struct NotificationRequest: Hashable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let body: String
    let category: String
    /// Groups a subject's notifications together in Notification Center.
    let thread: String
    let subjectID: String
}

/// The system notification center. `UNUserNotificationCenter` in the app; a fake in tests.
protocol UserNotificationCenter: Sendable {
    func authorization() async -> NotificationAuthorization
    /// Shows the system prompt the first time; afterwards returns the stored answer.
    func requestAuthorization() async throws -> Bool
    func add(_ request: NotificationRequest) async throws
}

/// Delivers notifications the attention pipeline has already decided on, and manages the
/// permission. It holds no rules about what deserves a notification — that is
/// `NotificationPolicy` and `PersistedState.surface`. Without permission it drops payloads;
/// the in-app "New" markers and the badge are unaffected.
@MainActor
@Observable
final class NotificationDelivery {
    enum Category {
        static let workstream = "tern.workstream"
        static let meeting = "tern.meeting"
        static let joinableMeeting = "tern.meeting.joinable"
    }

    enum Action {
        static let join = "tern.join"
    }

    private(set) var authorization: NotificationAuthorization = .notDetermined
    /// Requests handed to macOS this session, newest last (identifiers only, for diagnostics).
    private(set) var delivered: [String] = []

    private let center: any UserNotificationCenter
    private let logger = Logger(subsystem: "so.plane.tern", category: "notifications")

    /// Privacy & Security → Notifications.
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!

    init(center: any UserNotificationCenter) {
        self.center = center
    }

    /// Reads the current permission. Never prompts.
    func refresh() async {
        authorization = await center.authorization()
    }

    /// Shows the macOS prompt, only from a button the user pressed. Once answered, macOS won't
    /// prompt again; a denial has to be changed in System Settings.
    func enable() async {
        do {
            _ = try await center.requestAuthorization()
        } catch {
            logger.error("Notification permission request failed")
        }
        await refresh()
    }

    func openSettings() {
        NSWorkspace.shared.open(Self.settingsURL)
    }

    /// Posts one already-decided notification if macOS allows it. Re-reads the permission first,
    /// so enabling notifications in System Settings takes effect without a relaunch.
    func deliver(_ payload: NotificationPayload) async {
        await refresh()
        guard authorization == .authorized else { return }
        let category = switch payload.kind {
        case .workstream: Category.workstream
        case .meeting: Category.meeting
        case .joinableMeeting: Category.joinableMeeting
        }
        let request = NotificationRequest(id: payload.id, title: payload.title, subtitle: payload.subtitle, body: payload.body,
                                          category: category, thread: payload.subjectID.rawValue, subjectID: payload.subjectID.rawValue)
        do {
            try await center.add(request)
            delivered.append(request.id)
        } catch {
            // Never log the content; the identifier names only the subject.
            logger.error("Couldn't post a notification")
        }
    }
}

/// `UNUserNotificationCenter`, with Tern's two notification kinds and the Join action.
struct SystemNotificationCenter: UserNotificationCenter {
    init() {
        let join = UNNotificationAction(identifier: NotificationDelivery.Action.join, title: "Join meeting", options: [.foreground])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: NotificationDelivery.Category.workstream, actions: [], intentIdentifiers: []),
            UNNotificationCategory(identifier: NotificationDelivery.Category.meeting, actions: [], intentIdentifiers: []),
            UNNotificationCategory(identifier: NotificationDelivery.Category.joinableMeeting, actions: [join], intentIdentifiers: []),
        ])
    }

    func authorization() async -> NotificationAuthorization {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .notDetermined: .notDetermined
        case .authorized, .provisional, .ephemeral: .authorized
        case .denied: .denied
        @unknown default: .unavailable
        }
    }

    func requestAuthorization() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    func add(_ request: NotificationRequest) async throws {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.subtitle = request.subtitle
        content.body = request.body
        content.sound = .default
        content.categoryIdentifier = request.category
        content.threadIdentifier = request.thread
        content.userInfo = ["subjectID": request.subjectID]
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: request.id, content: content, trigger: nil))
    }
}

/// Receives clicks on Tern's notifications and shows banners while Tern is frontmost.
/// Clicking never changes a subject's state; it only brings Tern forward.
final class NotificationResponder: NSObject, UNUserNotificationCenterDelegate, Sendable {
    enum Response: Sendable {
        case open(SubjectID)
        case join(SubjectID)
    }

    private let handler: @MainActor @Sendable (Response) -> Void

    init(handler: @escaping @MainActor @Sendable (Response) -> Void) {
        self.handler = handler
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let raw = response.notification.request.content.userInfo["subjectID"] as? String else { return }
        let subject = SubjectID(rawValue: raw)
        let action = response.actionIdentifier
        await MainActor.run {
            handler(action == NotificationDelivery.Action.join ? .join(subject) : .open(subject))
        }
    }
}
