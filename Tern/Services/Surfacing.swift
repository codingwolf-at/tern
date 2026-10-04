import Foundation

/// The one path from an attention subject's current transition to what the user is shown,
/// shared by workstreams and meetings:
///
///     subject → context → transition → NotificationPolicy → shown-transition record → notification record
///
/// Pure bookkeeping over `PersistedState`; the caller decides what a subject's transition is.
extension PersistedState {
    /// Records `transition` as the one shown for `subject` and returns a notification record
    /// when it is news. Live subjects outside the active context, or snoozed in it, are left
    /// untouched — neither notified nor recorded as seen — so their own context decides later,
    /// or the snooze's end does (see `IngestionService.expireSnoozes`). A history import records
    /// transitions as shown without notifying.
    mutating func surface(
        _ transition: AttentionTransition,
        of subject: SubjectID,
        in context: SubjectContext,
        headline: String,
        mode: IngestMode,
        isContextScoped: Bool,
        at date: Date
    ) -> NotificationRecord? {
        if mode == .live, isContextScoped, !context.isIn(activeContext) { return nil }
        if mode == .live, snoozes.active(for: subject, in: context, at: date) != nil { return nil }

        let previous = shownTransitions.first { $0.subjectID == subject }
        let isNews = mode == .live
            && NotificationPolicy.shouldNotify(transition, lastShown: previous?.transition)
            && !(previous?.seen.contains(transition.fingerprint) ?? false)

        if previous?.transition != transition {
            let seen = (previous?.seen ?? []).filter { $0 != transition.fingerprint } + [transition.fingerprint]
            shownTransitions.removeAll { $0.subjectID == subject }
            shownTransitions.append(ShownTransition(subjectID: subject, transition: transition, seen: Array(seen.suffix(ShownTransition.seenLimit))))
        }
        guard isNews else { return nil }
        let record = NotificationRecord(subjectID: subject, fingerprint: transition.fingerprint, headline: headline,
                                        attention: transition.attention, createdAt: date)
        notifications.append(record)
        notifications = Array(notifications.suffix(Self.notificationHistoryLimit))
        return record
    }

    /// Whether `transition` has been surfaced as a notification for `subject`.
    func wasNotified(_ transition: AttentionTransition, of subject: SubjectID) -> Bool {
        notifications.contains { $0.subjectID == subject && $0.fingerprint == transition.fingerprint }
    }
}
