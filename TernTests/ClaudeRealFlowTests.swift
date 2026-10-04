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
    private func run(_ arguments: [String], home: URL? = nil) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path] + arguments + ["--settings", settings.path]
        if let home {
            process.environment = ProcessInfo.processInfo.environment.merging(["HOME": home.path]) { _, new in new }
        }
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

    /// A stand-in installed Tern.app with a working helper.
    private func makeApp(at url: URL, bundleID: String = "so.plane.tern") throws -> String {
        let helpers = url.appending(path: "Contents/Helpers")
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": bundleID]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: url.appending(path: "Contents/Info.plist"))
        let helper = helpers.appending(path: "tern-hook")
        try "#!/bin/sh\necho tern-hook 1\n".write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        return url.path
    }

    private var app: String { get throws { try makeApp(at: directory.appending(path: "Applications/Tern.app")) } }

    @Test("Install adds only Tern's hooks and keeps everything else")
    func install() throws {
        try prepare()
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try run(["install", "--app", try app])
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

    @Test("Hooks point at the helper inside the installed app")
    func stableHelperPath() throws {
        try prepare()
        defer { try? FileManager.default.removeItem(at: directory) }
        let installed = try app
        #expect(try run(["install", "--app", installed]).status == 0)
        let expected = "'\(installed)/Contents/Helpers/tern-hook'"
        for event in ["SessionStart", "UserPromptSubmit", "Stop", "StopFailure", "SessionEnd"] {
            #expect(commands(try load(), event).filter { $0.contains("tern-hook") } == [expected], "\(event)")
        }
        let status = try run(["status"])
        #expect(status.output.contains("\(installed)/Contents/Helpers/tern-hook (ok)"))
    }

    @Test("Without --app, only an installed Tern.app is used, never a build folder")
    func usesInstalledApp() throws {
        try prepare()
        defer { try? FileManager.default.removeItem(at: directory) }
        let home = directory.appending(path: "home")
        let installed = try makeApp(at: home.appending(path: "Applications/Tern.app"))
        #expect(try run(["install"], home: home).status == 0)
        let command = try #require(commands(try load(), "Stop").first { $0.contains("tern-hook") })
        #expect(command == "'\(installed)/Contents/Helpers/tern-hook'" || command == "'/Applications/Tern.app/Contents/Helpers/tern-hook'")
        #expect(!command.contains("DerivedData"))
    }

    @Test("Upgrading: reinstalling replaces Tern's entries in place and status flags a missing app")
    func reinstallAndMissing() throws {
        try prepare()
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = try makeApp(at: directory.appending(path: "Old/Tern.app"))
        let new = try app
        try run(["install", "--app", old])
        try run(["install", "--app", new])
        let json = try load()
        #expect(commands(json, "Stop") == ["node statusbar.js stop", "'\(new)/Contents/Helpers/tern-hook'"])

        try FileManager.default.removeItem(atPath: new)
        #expect(try run(["status"]).output.contains("(missing"))
        let reinstall = try run(["install", "--app", new])
        #expect(reinstall.status != 0)
        #expect(reinstall.output.contains("No app at"))
    }

    @Test("Build outputs and Debug builds are refused")
    func refusesDevAndDebugApps() throws {
        try prepare()
        defer { try? FileManager.default.removeItem(at: directory) }
        let derived = try makeApp(at: directory.appending(path: "DerivedData/Build/Products/Release/Tern.app"))
        let refused = try run(["install", "--app", derived])
        #expect(refused.status != 0)
        #expect(refused.output.contains("build output"))
        #expect(try run(["install", "--app", derived, "--allow-dev-path"]).status == 0)

        let debug = try makeApp(at: directory.appending(path: "Debug/Tern.app"), bundleID: "so.plane.tern.debug")
        let debugResult = try run(["install", "--app", debug])
        #expect(debugResult.status != 0)
        #expect(debugResult.output.contains("not the Release build"))
        #expect(!(try String(contentsOf: settings, encoding: .utf8)).contains("Debug/Tern.app"))
    }

    @Test("A dry run changes nothing; installing twice is idempotent")
    func dryRunAndIdempotent() throws {
        try prepare()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try app
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
        try run(["install", "--app", try app])
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
        // A second Stop for the same turn (a Stop hook let Claude continue) isn't a new outcome.
        let again = try await service.ingest([try claude("Stop", seq: 3)])
        #expect(again.notifications.isEmpty)
        #expect(try await only(service).evaluation.transition == ws.evaluation.transition)
    }

    @Test("SessionStart → prompt → Stop, twice, then close: one 'finished' per turn, never the approval again")
    func successfulTurns() async throws {
        let service = try await workstream()
        var headlines: [String] = []
        headlines += try await service.ingest([try claude("SessionStart", seq: 1), try claude("UserPromptSubmit", seq: 2)]).notifications.map(\.headline)
        #expect(try await only(service).nextOwner == .agent)
        headlines += try await service.ingest([try claude("Stop", seq: 3)]).notifications.map(\.headline)
        var ws = try await only(service)
        #expect(ws.nextOwner == .me)
        #expect(ws.attention == .medium)
        #expect(ws.agentSessions.first?.status == .completed)

        headlines += try await service.ingest([try claude("UserPromptSubmit", seq: 4, prompt: "p2")]).notifications.map(\.headline)
        #expect(try await only(service).attention == .silent)
        headlines += try await service.ingest([try claude("Stop", seq: 5, prompt: "p2")]).notifications.map(\.headline)
        #expect(headlines == ["Claude finished", "Claude finished"])

        // Closing the session means its output was seen: back to the PR's own next step, quietly.
        let closed = try await service.ingest([try claude("SessionEnd", seq: 6, prompt: "p2")])
        #expect(closed.notifications.isEmpty)
        ws = try await only(service)
        #expect(ws.nextAction?.title == "Merge")
        #expect(ws.attention == .medium)
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

/// Debug and Release builds must never compete for the real hooks' events.
@Suite("Build identity")
struct BuildIdentityTests {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    private var schemes: [String] {
        let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
        return types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
    }

    @Test("The Debug build has its own bundle ID and scheme, so it can't take tern://")
    func debugIsIsolated() {
        #expect(Bundle.main.bundleIdentifier == "so.plane.tern.debug")
        #expect(schemes == ["tern-debug"])
        #expect(ClaudeHookURL.scheme == "tern-debug")
    }

    @Test("Release keeps the production bundle ID and tern:// scheme")
    func releaseIsProduction() throws {
        let project = try String(contentsOf: root.appending(path: "Tern.xcodeproj/project.pbxproj"), encoding: .utf8)
        // The app target's Release configuration is the one that names the production scheme.
        let release = try #require(project.components(separatedBy: "isa = XCBuildConfiguration;")
            .first { $0.contains("PRODUCT_BUNDLE_IDENTIFIER = so.plane.tern;") })
        #expect(release.contains("TERN_URL_SCHEME = tern;"))
        #expect(release.contains("name = Release;"))
        let plist = try String(contentsOf: root.appending(path: "Config/Tern-Info.plist"), encoding: .utf8)
        #expect(plist.contains("$(TERN_URL_SCHEME)"))
    }

    @Test("The embedded helper delivers to its own app and speaks that build's scheme")
    func helperTargetsItsOwnApp() throws {
        let helper = Bundle.main.bundleURL.appending(path: "Contents/Helpers/tern-hook")
        #expect(try run(helper, ["--print-target"]) == Bundle.main.bundleURL.resolvingSymlinksInPath().path)

        let payload = #"{"hook_event_name":"Stop","session_id":"identity-test","cwd":"/tmp"}"#
        let state = FileManager.default.temporaryDirectory.appending(path: "tern-hook-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: state) }
        let url = try run(helper, [], input: payload, environment: ["TERN_HOOK_PRINT": "1", "TERN_HOOK_STATE_DIR": state.path])
        #expect(url.hasPrefix("tern-debug://claude-hook?"))
    }

    private func run(_ executable: URL, _ arguments: [String], input: String = "", environment: [String: String] = [:]) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        return String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
