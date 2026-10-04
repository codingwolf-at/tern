import Foundation
import Testing
@testable import Tern

/// The installer script, run against throwaway settings files.
@Suite("Claude hook installer", .serialized)
struct ClaudeHookInstallerTests {
    private let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "scripts/install-claude-hooks.sh")
    private let directory = FileManager.default.temporaryDirectory.appending(path: "tern-installer-\(UUID().uuidString)")

    private var settings: URL { directory.appending(path: "settings.json") }

    private let existing = """
    {"theme":"dark","hooks":{"Stop":[{"hooks":[{"type":"command","command":"node statusbar.js stop"}]}],"PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"node statusbar.js pre"}]}]}}
    """

    @discardableResult
    private func run(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path] + arguments + ["--settings", settings.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    private func load() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
    }

    private func commands(_ json: [String: Any], _ event: String) -> [String] {
        let groups = (json["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? []
        return groups.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
    }

    private func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try existing.write(to: settings, atomically: true, encoding: .utf8)
    }

    private var app: String { Bundle.main.bundleURL.path }

    @Test("Install adds only Tern's hooks and keeps everything else")
    func install() throws {
        try prepare()
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try run(["install", "--app", app])
        #expect(result.status == 0)
        let json = try load()
        #expect(json["theme"] as? String == "dark")
        #expect(commands(json, "Stop").first == "node statusbar.js stop")
        #expect(commands(json, "PreToolUse") == ["node statusbar.js pre"])
        for event in ["SessionStart", "UserPromptSubmit", "Notification", "PostToolUse", "Stop", "StopFailure", "SessionEnd"] {
            #expect(commands(json, event).filter { $0.contains("tern-hook") }.count == 1, "\(event)")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.contains("tern-backup") })
    }

    @Test("A dry run changes nothing; installing twice is idempotent")
    func dryRunAndIdempotent() throws {
        try prepare()
        defer { try? FileManager.default.removeItem(at: directory) }
        try run(["install", "--app", app, "--dry-run"])
        #expect(try String(contentsOf: settings, encoding: .utf8) == existing)

        try run(["install", "--app", app])
        let once = try Data(contentsOf: settings)
        let second = try run(["install", "--app", app])
        #expect(second.output.contains("already up to date"))
        #expect(try Data(contentsOf: settings) == once)
    }

    @Test("Uninstall removes only Tern's hooks")
    func uninstall() throws {
        try prepare()
        defer { try? FileManager.default.removeItem(at: directory) }
        try run(["install", "--app", app])
        try run(["uninstall"])
        let json = try load()
        let original = try JSONSerialization.jsonObject(with: Data(existing.utf8)) as! [String: Any]
        #expect(NSDictionary(dictionary: json).isEqual(to: original))
    }
}

/// Real-flow behaviour of Claude sessions inside an existing Plane + GitHub workstream.
@Suite("Claude real flow")
struct ClaudeRealFlowTests {
    private func claude(_ event: String, seq: Int, prompt: String = "p1", notification: String? = nil, error: String? = nil) throws -> ObservedEvent {
        try #require(ClaudeHookNormalizer.normalize(ClaudeHookPayload(
            hookEventName: event, sessionID: "real-1", promptID: prompt, cwd: "/Users/me/plane-ee", notificationType: notification,
            error: error, sequence: seq, timestampMilliseconds: Int64(GH.at(Double(100 + seq)).timeIntervalSince1970 * 1000),
            gitRoot: "/Users/me/plane-ee", gitRemote: "acme/web", gitBranch: "fix/WEB-9295-chevron"
        ), receivedAt: GH.t0))
    }

    /// WEB-9295 tracked in Plane, with an approved PR on its branch, imported as history.
    private func workstream() async throws -> IngestionService {
        let service = IngestionService(store: InMemoryTernStore(), now: { GH.t0 })
        try await service.start()
        try await service.ingest(PL.events(PL.item()) + GH.events(GH.pr(head: "fix/WEB-9295-chevron", headSHA: "sha1",
                                     reviews: [GH.review(1, "APPROVED", by: "sarah", at: GH.at(5), on: "sha1")])), mode: .historyImport)
        return service
    }

    private func only(_ service: IngestionService) async throws -> Workstream {
        let workstreams = await service.snapshot.workstreams
        #expect(workstreams.count == 1, "Plane, PR and session should be one workstream")
        return try #require(workstreams.first)
    }

    @Test("A session on the item's repository and branch joins its Plane + PR workstream")
    func joins() async throws {
        let service = try await workstream()
        try await service.ingest([try claude("SessionStart", seq: 1), try claude("UserPromptSubmit", seq: 2)])
        let ws = try await only(service)
        #expect(ws.planeItem?.identifier == "WEB-9295")
        #expect(ws.pullRequest?.number == 421)
        #expect(ws.agentSessions.map(\.id) == ["claude:real-1"])
        #expect(ws.nextOwner == .agent)
        #expect(ws.attention == .silent)
        #expect(ws.nextAction?.title != "Merge")
    }

    @Test("Working is silent; finishing hands back once; duplicates and replays don't re-notify")
    func handoff() async throws {
        let service = try await workstream()
        let working = try await service.ingest([try claude("UserPromptSubmit", seq: 1)])
        #expect(working.notifications.isEmpty)

        let stop = try claude("Stop", seq: 2)
        let finished = try await service.ingest([stop])
        #expect(finished.notifications.map(\.headline) == ["Claude finished"])
        let ws = try await only(service)
        #expect(ws.nextOwner == .me)
        #expect(ws.nextAction?.title == "Review Claude's changes")

        #expect(try await service.ingest([stop]).notifications.isEmpty)
        #expect(try await service.ingest([try claude("UserPromptSubmit", seq: 1), stop]).notifications.isEmpty)
    }

    @Test("Coming back to an already-shown state after an agent turn isn't news")
    func noRenotifyAfterAgentRoundTrip() async throws {
        let service = try await workstream()
        #expect(try await only(service).nextAction?.title == "Merge")
        try await service.ingest([try claude("UserPromptSubmit", seq: 1)])
        // The session ends without a Stop (seen in practice with `claude -p`): back to the same approval.
        let ended = try await service.ingest([try claude("SessionEnd", seq: 2)])
        #expect(try await only(service).nextAction?.title == "Merge")
        #expect(ended.notifications.isEmpty)
    }

    @Test("A failed turn is high and notifies; needs input is high")
    func failureAndInput() async throws {
        let service = try await workstream()
        try await service.ingest([try claude("UserPromptSubmit", seq: 1)])
        let failed = try await service.ingest([try claude("StopFailure", seq: 2, error: "authentication_failed")])
        #expect(failed.notifications.first?.attention == .high)
        #expect(try await only(service).status.detail == "Authentication failed")

        try await service.ingest([try claude("UserPromptSubmit", seq: 3, prompt: "p2"),
                                  try claude("Notification", seq: 4, prompt: "p2", notification: "permission_prompt")])
        let ws = try await only(service)
        #expect(ws.attention == .high)
        #expect(ws.evaluation.decision.reason == .agentNeedsInput)
    }
}
