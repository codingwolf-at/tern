import Foundation
import Testing
@testable import Tern

/// Drives the real `tern-hook` helper embedded in the app bundle with Claude Code–shaped
/// payloads, then hands the URL it produces to the app exactly as Launch Services would.
@Suite("Claude hook end to end", .serialized)
@MainActor
struct ClaudeHookEndToEndTests {
    let stateDirectory = FileManager.default.temporaryDirectory.appending(path: "tern-hook-\(UUID().uuidString)")

    private var helper: URL {
        Bundle.main.bundleURL.appending(path: "Contents/Helpers/tern-hook")
    }

    /// Runs the helper with `json` on stdin; returns the URL it would open, if any.
    private func runHelper(_ json: String) throws -> URL? {
        let process = Process()
        process.executableURL = helper
        process.environment = ["TERN_HOOK_PRINT": "1", "TERN_HOOK_STATE_DIR": stateDirectory.path, "PATH": ""]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(Data(json.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : URL(string: text)
    }

    private func hook(_ event: String, _ extra: String = "") -> String {
        #"{"session_id":"e2e-1","transcript_path":"/Users/me/.claude/projects/secret.jsonl","cwd":"/tmp/tern e2e/ü","prompt_id":"p1","hook_event_name":"\#(event)"\#(extra)}"#
    }

    @Test("Helper → URL → app → engine → UI model")
    func fullPipeline() async throws {
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        #expect(FileManager.default.isExecutableFile(atPath: helper.path))

        let service = IngestionService(store: InMemoryTernStore())
        let model = AppModel(service: service)

        // Sensitive fields never leave the helper.
        let start = try #require(try runHelper(hook("UserPromptSubmit", #","prompt":"my secret prompt","permission_mode":"default""#)))
        let forwarded = try ClaudeHookURL.decode(start)
        #expect(forwarded.sequence == 1)
        #expect(forwarded.cwd == "/tmp/tern e2e/ü")
        let raw = String(decoding: ClaudeHookURL.base64URLDecoded(URLComponents(url: start, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "p" }!.value!)!, as: UTF8.self)
        #expect(!raw.contains("secret"))
        #expect(!raw.contains("transcript"))

        await model.claudeHooks.handle(start)
        try await waitUntil { model.waiting.first?.status.headline == "Claude working" }

        // No PostToolUse is forwarded until an input request is outstanding.
        #expect(try runHelper(hook("PostToolUse", #","tool_name":"Bash""#)) == nil)

        let permission = try #require(try runHelper(hook("Notification", #","notification_type":"permission_prompt","message":"Claude needs your permission to use Bash""#)))
        await model.claudeHooks.handle(permission)
        try await waitUntil { model.backWithYou.first?.status.headline == "Claude needs your input" }
        #expect(model.backWithYou.first?.attention == .high)
        #expect(model.backWithYou.first?.title == "ü")

        let resumed = try #require(try runHelper(hook("PostToolUse", #","tool_name":"Bash""#)))
        await model.claudeHooks.handle(resumed)
        try await waitUntil { model.backWithYou.isEmpty && model.waiting.first?.nextOwner == .agent }

        let stop = try #require(try runHelper(hook("Stop", #","last_assistant_message":"secret answer""#)))
        await model.claudeHooks.handle(stop)
        try await waitUntil { model.backWithYou.first?.status.headline == "Claude finished" }

        // Re-delivery of the same URL changes nothing.
        let report = await model.claudeHooks.handle(stop)
        #expect(report?.duplicates.count == 1)
        #expect(model.claudeHooks.activity.received == 5)
        #expect(model.claudeHooks.activity.lastEvent == "Stop")
    }

    @Test("URLs opened before the app is ready are delivered in order")
    func routerBuffersUntilReady() async throws {
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let service = IngestionService(store: InMemoryTernStore())
        let model = AppModel(service: service)
        let urls = try [hook("UserPromptSubmit"), hook("Stop")].map { try #require(try runHelper($0)) }

        let router = OpenURLRouter()
        router.open(urls)
        router.start { await model.claudeHooks.handle($0) }

        try await waitUntil { model.backWithYou.first?.status.headline == "Claude finished" }
        #expect(model.claudeHooks.activity.received == 2)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}
