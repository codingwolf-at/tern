import Foundation
import Observation
import os

/// Receives Claude Code hook URLs and feeds them through the normal ingestion path.
/// It never notifies by itself; attention is decided by the engine and notification policy.
@MainActor
@Observable
final class ClaudeHookReceiver {
    /// Lightweight counters for diagnostics. Never holds payload contents.
    struct Activity: Equatable {
        var lastEvent: String?
        var lastEventAt: Date?
        var lastWorkstreamID: WorkstreamID?
        /// Where the last event came from: `owner/name` (or the folder) and branch. Never paths or content.
        var lastRepository: String?
        var lastBranch: String?
        var received = 0
        var rejected = 0
    }

    private(set) var activity = Activity()

    private let service: IngestionService
    private let now: @Sendable () -> Date
    private let logger = Logger(subsystem: "so.plane.tern", category: "claude-hooks")

    init(service: IngestionService, now: @escaping @Sendable () -> Date = { .now }) {
        self.service = service
        self.now = now
    }

    /// Handles a `tern://claude-hook` URL. Returns the ingestion report, or `nil` if the URL was
    /// rejected or carried no ownership signal.
    @discardableResult
    func handle(_ url: URL) async -> IngestReport? {
        let payload: ClaudeHookPayload
        do {
            payload = try ClaudeHookURL.decode(url)
        } catch {
            activity.rejected += 1
            logger.error("Rejected hook URL: \(String(describing: error), privacy: .public)")
            return nil
        }

        activity.received += 1
        activity.lastEvent = payload.hookEventName
        activity.lastEventAt = now()
        if let repository = payload.gitRemote ?? payload.gitRoot.map({ URL(fileURLWithPath: $0).lastPathComponent }) {
            activity.lastRepository = repository
        }
        if let branch = payload.gitBranch { activity.lastBranch = branch }

        guard let event = ClaudeHookNormalizer.normalize(payload, receivedAt: now()) else { return nil }
        do {
            try await service.start()
            let report = try await service.ingest([event], mode: .live)
            if report.accepted.contains(event.id),
               let workstream = await service.snapshot.workstreams.first(where: { $0.events.contains { $0.id == event.id } }) {
                activity.lastWorkstreamID = workstream.id
            }
            logger.debug("Ingested \(payload.hookEventName, privacy: .public): accepted \(report.accepted.count), duplicates \(report.duplicates.count)")
            return report
        } catch {
            logger.error("Ingesting hook event failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
