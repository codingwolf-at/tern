import Foundation
import Testing
@testable import Tern

private let t0: Int64 = 1_800_000_000_000

private func payload(
    _ event: String,
    session: String = "sess-a",
    seq: Int,
    prompt: String? = "prompt-1",
    branch: String? = "feat/avatar-migration",
    root: String? = "/Users/me/Code/plane",
    cwd: String? = "/Users/me/Code/plane",
    notification: String? = nil,
    message: String? = nil,
    error: String? = nil
) -> ClaudeHookPayload {
    ClaudeHookPayload(
        hookEventName: event,
        sessionID: session,
        promptID: prompt,
        cwd: cwd,
        source: event == "SessionStart" ? "startup" : nil,
        notificationType: notification,
        message: message,
        reason: event == "SessionEnd" ? "prompt_input_exit" : nil,
        error: error,
        sequence: seq,
        timestampMilliseconds: t0 + Int64(seq) * 1000,
        gitRoot: root,
        gitBranch: branch
    )
}

@Suite("Claude hook normalization")
struct ClaudeHookNormalizationTests {
    let received = Date(timeIntervalSince1970: 1_700_000_000)

    private func normalize(_ payload: ClaudeHookPayload) throws -> ObservedEvent {
        try #require(ClaudeHookNormalizer.normalize(payload, receivedAt: received))
    }

    @Test("SessionStart registers the session in its branch's workstream")
    func sessionStart() throws {
        let event = try normalize(payload("SessionStart", seq: 1, prompt: nil))
        #expect(event.kind == .agentSessionOpened)
        #expect(event.source == .agent)
        #expect(event.references == [
            .agentSession(provider: "claude", id: "sess-a"),
            .branch("feat/avatar-migration", repository: "/Users/me/Code/plane"),
        ])
        #expect(event.workstreamKey == .branch("feat/avatar-migration", repository: "/Users/me/Code/plane"))
        #expect(event.suggestedTitle == "Avatar migration")
        #expect(event.metadata["agentName"] == "Claude Code")
        #expect(event.metadata["agentSessionID"] == "claude:sess-a")
        #expect(event.timestamp == Date(timeIntervalSince1970: 1_800_000_001))
    }

    @Test("UserPromptSubmit starts a turn and is identified by its prompt")
    func promptSubmit() throws {
        let event = try normalize(payload("UserPromptSubmit", seq: 2, prompt: "p-42"))
        #expect(event.kind == .agentStarted)
        #expect(event.id == EventID(rawValue: "agent:claude:sess-a:UserPromptSubmit:p-42"))
    }

    @Test("Input-request notifications become needs-input; reminders are dropped")
    func notifications() throws {
        let permission = try normalize(payload("Notification", seq: 3, notification: "permission_prompt", message: "Claude needs your permission to use Bash"))
        #expect(permission.kind == .agentNeedsInput)
        #expect(permission.metadata["prompt"] == "Claude needs your permission to use Bash")

        #expect(try normalize(payload("Notification", seq: 4, notification: "elicitation_dialog")).kind == .agentNeedsInput)
        #expect(try normalize(payload("Notification", seq: 5, notification: "elicitation_complete")).kind == .agentResumed)
        #expect(ClaudeHookNormalizer.normalize(payload("Notification", seq: 6, notification: "idle_prompt"), receivedAt: received) == nil)
        #expect(ClaudeHookNormalizer.normalize(payload("Notification", seq: 7, notification: "auth_success"), receivedAt: received) == nil)
    }

    @Test("Stop ends the turn, not the session")
    func stop() throws {
        let event = try normalize(payload("Stop", seq: 8))
        #expect(event.kind == .agentCompleted)
        #expect(event.allowsNewWorkstream)
    }

    @Test("StopFailure is a failed turn, reading Claude Code's `error` field")
    func stopFailure() throws {
        let event = try normalize(payload("StopFailure", seq: 9, error: "authentication_failed"))
        #expect(event.kind == .agentFailed)
        #expect(event.metadata["reason"] == "Authentication failed")

        let documented = ClaudeHookPayload(hookEventName: "StopFailure", sessionID: "s", errorType: "rate_limit", sequence: 1)
        #expect(try normalize(documented).metadata["reason"] == "Hit a rate limit")
    }

    @Test("SessionEnd closes the session and may not start a workstream")
    func sessionEnd() throws {
        let event = try normalize(payload("SessionEnd", seq: 10, branch: nil, root: nil))
        #expect(event.kind == .agentSessionEnded)
        #expect(event.allowsNewWorkstream == false)
    }

    @Test("PostToolUse forwarded after an input request means the session resumed")
    func resumed() throws {
        #expect(try normalize(payload("PostToolUse", seq: 11)).kind == .agentResumed)
    }

    @Test("Unknown hooks and payloads without a session are ignored")
    func ignored() {
        #expect(ClaudeHookNormalizer.normalize(payload("PreCompact", seq: 1), receivedAt: received) == nil)
        #expect(ClaudeHookNormalizer.normalize(payload("Stop", session: "///", seq: 1), receivedAt: received) == nil)
    }

    @Test("Without git, the working directory identifies the workstream")
    func workingDirectory() throws {
        let event = try normalize(payload("SessionStart", seq: 1, branch: nil, root: nil, cwd: "/Users/me/scratch notes"))
        #expect(event.references.last == .workingDirectory("/Users/me/scratch notes"))
        #expect(event.suggestedTitle == "scratch notes")
    }

    @Test("Workstream titles come from the branch, or the repository on trunk")
    func titles() {
        #expect(ClaudeHookNormalizer.title(branch: "feat/avatar-migration", repository: "plane") == "Avatar migration")
        #expect(ClaudeHookNormalizer.title(branch: "fix_login_bug", repository: "plane") == "Fix login bug")
        #expect(ClaudeHookNormalizer.title(branch: "main", repository: "plane") == "plane")
    }
}

@Suite("Claude hook identity and transport")
struct ClaudeHookTransportTests {
    @Test("The same hook payload always produces the same event ID")
    func stableID() throws {
        let p = payload("Stop", seq: 7)
        let a = try #require(ClaudeHookNormalizer.normalize(p, receivedAt: .now))
        let b = try #require(ClaudeHookNormalizer.normalize(p, receivedAt: .distantFuture))
        #expect(a.id == b.id)
        #expect(a.id == EventID(rawValue: "agent:claude:sess-a:Stop:prompt-1:7"))
    }

    @Test("Two identical notifications in one turn stay distinct")
    func distinctRepeats() throws {
        let first = payload("Notification", seq: 3, notification: "permission_prompt", message: "Bash")
        let second = payload("Notification", seq: 5, notification: "permission_prompt", message: "Bash")
        #expect(ClaudeHookNormalizer.normalize(first, receivedAt: .now)?.id != ClaudeHookNormalizer.normalize(second, receivedAt: .now)?.id)
    }

    @Test("Payloads survive URL transport intact")
    func roundTrip() throws {
        let awkward = "/Users/me/My Projects/ü \"quoted\" & <tags> ?x=1#frag %20 +/ 日本語 😀"
        let original = payload(
            "Notification", seq: 4, root: awkward, cwd: awkward,
            notification: "permission_prompt", message: String(repeating: "long message ", count: 600)
        )
        let url = try ClaudeHookURL.encode(original)
        #expect(url.scheme == ClaudeHookURL.scheme)
        #expect(url.absoluteString.contains(" ") == false)
        #expect(try ClaudeHookURL.decode(url) == original)
    }

    @Test("Malformed, foreign and oversized URLs are rejected")
    func rejects() throws {
        #expect(throws: ClaudeHookURL.DecodingError.notAHookURL) { try ClaudeHookURL.decode(URL(string: "\(ClaudeHookURL.scheme)://other?v=1&p=e30")!) }
        #expect(throws: ClaudeHookURL.DecodingError.unsupportedVersion) { try ClaudeHookURL.decode(URL(string: "\(ClaudeHookURL.scheme)://claude-hook?v=9&p=e30")!) }
        #expect(throws: ClaudeHookURL.DecodingError.missingPayload) { try ClaudeHookURL.decode(URL(string: "\(ClaudeHookURL.scheme)://claude-hook?v=1")!) }
        #expect(throws: ClaudeHookURL.DecodingError.malformedPayload) { try ClaudeHookURL.decode(URL(string: "\(ClaudeHookURL.scheme)://claude-hook?v=1&p=!!!")!) }
        #expect(throws: ClaudeHookURL.DecodingError.malformedPayload) { try ClaudeHookURL.decode(URL(string: "\(ClaudeHookURL.scheme)://claude-hook?v=1&p=e30")!) }
        let huge = String(repeating: "A", count: 40_000)
        #expect(throws: ClaudeHookURL.DecodingError.payloadTooLarge) { try ClaudeHookURL.decode(URL(string: "\(ClaudeHookURL.scheme)://claude-hook?v=1&p=\(huge)")!) }
    }
}

@Suite("Claude sessions in the engine")
@MainActor
struct ClaudeSessionTests {
    private func makeReceiver() async throws -> (ClaudeHookReceiver, IngestionService) {
        let service = IngestionService(store: InMemoryTernStore(), now: { Date(timeIntervalSince1970: 1_800_000_000) })
        try await service.start()
        return (ClaudeHookReceiver(service: service), service)
    }

    @discardableResult
    private func send(_ receiver: ClaudeHookReceiver, _ payload: ClaudeHookPayload) async throws -> IngestReport? {
        await receiver.handle(try ClaudeHookURL.encode(payload))
    }

    private func onlyWorkstream(_ service: IngestionService) async throws -> Workstream {
        let workstreams = await service.snapshot.workstreams
        #expect(workstreams.count == 1)
        return try #require(workstreams.first)
    }

    @Test("Working, needs input, resume, finish, fail: ownership follows the session")
    func lifecycle() async throws {
        let (receiver, service) = try await makeReceiver()

        try await send(receiver, payload("SessionStart", seq: 1, prompt: nil))
        var ws = try await onlyWorkstream(service)
        #expect(ws.title == "Avatar migration")
        #expect(ws.nextOwner == .none)
        #expect(ws.agentSessions.map(\.status) == [.idle])

        try await send(receiver, payload("UserPromptSubmit", seq: 2))
        ws = try await onlyWorkstream(service)
        #expect(ws.nextOwner == .agent)
        #expect(ws.attention == .silent)

        let needsInput = try await send(receiver, payload("Notification", seq: 3, notification: "permission_prompt", message: "Claude needs your permission to use Bash"))
        ws = try await onlyWorkstream(service)
        #expect(ws.nextOwner == .me)
        #expect(ws.attention == .high)
        #expect(ws.status.headline == "Claude needs your input")
        #expect(ws.status.detail == "Claude needs your permission to use Bash")
        #expect(needsInput?.notifications.count == 1)

        try await send(receiver, payload("PostToolUse", seq: 4))
        ws = try await onlyWorkstream(service)
        #expect(ws.nextOwner == .agent)
        #expect(ws.attention == .silent)
        #expect(ws.evaluation.decision.shouldNotify == false)

        let finished = try await send(receiver, payload("Stop", seq: 5))
        ws = try await onlyWorkstream(service)
        #expect(ws.nextOwner == .me)
        #expect(ws.attention == .medium)
        #expect(ws.agentSessions.map(\.status) == [.completed])
        #expect(finished?.notifications.count == 1)

        try await send(receiver, payload("UserPromptSubmit", seq: 6, prompt: "prompt-2"))
        try await send(receiver, payload("StopFailure", seq: 7, prompt: "prompt-2", error: "overloaded"))
        ws = try await onlyWorkstream(service)
        #expect(ws.nextOwner == .me)
        #expect(ws.attention == .high)
        #expect(ws.status.headline == "Claude stopped")
        #expect(ws.status.detail == "API overloaded")
    }

    @Test("Ending a session clears its claim but keeps it in history")
    func sessionEnd() async throws {
        let (receiver, service) = try await makeReceiver()
        try await send(receiver, payload("UserPromptSubmit", seq: 1))
        try await send(receiver, payload("Stop", seq: 2))
        try await send(receiver, payload("SessionEnd", seq: 3, branch: nil, root: nil))

        let ws = try await onlyWorkstream(service)
        #expect(ws.nextOwner == .none)
        #expect(ws.attention == .silent)
        #expect(ws.agentSessions.map(\.status) == [.ended])
        #expect(ws.events.count == 3)
        #expect(ws.state != .complete)
    }

    @Test("SessionEnd for an unknown session doesn't create a workstream")
    func orphanSessionEnd() async throws {
        let (receiver, service) = try await makeReceiver()
        let report = try await send(receiver, payload("SessionEnd", session: "never-seen", seq: 1, branch: nil, root: nil))
        #expect(report?.unlinked.count == 1)
        #expect(await service.snapshot.workstreams.isEmpty)
    }

    @Test("Re-delivered hook events are idempotent")
    func duplicates() async throws {
        let (receiver, service) = try await makeReceiver()
        try await send(receiver, payload("UserPromptSubmit", seq: 1))
        try await send(receiver, payload("Stop", seq: 2))
        let before = try await onlyWorkstream(service)

        let again = try await send(receiver, payload("Stop", seq: 2))
        #expect(again?.duplicates.count == 1)
        #expect(again?.notifications.isEmpty == true)
        let after = try await onlyWorkstream(service)
        #expect(after.events == before.events)
        #expect(after.evaluation.transition == before.evaluation.transition)
    }

    @Test("Sessions in one workstream keep independent states")
    func independentSessions() async throws {
        let (receiver, service) = try await makeReceiver()
        try await send(receiver, payload("UserPromptSubmit", session: "a", seq: 1, prompt: "pa"))
        try await send(receiver, payload("UserPromptSubmit", session: "b", seq: 1, prompt: "pb"))
        try await send(receiver, payload("UserPromptSubmit", session: "c", seq: 1, prompt: "pc"))
        try await send(receiver, payload("Stop", session: "c", seq: 2, prompt: "pc"))
        try await send(receiver, payload("Notification", session: "b", seq: 2, prompt: "pb", notification: "permission_prompt"))

        var ws = try await onlyWorkstream(service)
        let statuses = Dictionary(uniqueKeysWithValues: ws.agentSessions.map { ($0.id, $0.status) })
        #expect(statuses == ["claude:a": .working, "claude:b": .needsInput, "claude:c": .completed])
        #expect(ws.nextOwner == .me)
        #expect(ws.attention == .high)

        // A new session doesn't overwrite C's finished work.
        try await send(receiver, payload("UserPromptSubmit", session: "d", seq: 1, prompt: "pd"))
        ws = try await onlyWorkstream(service)
        #expect(ws.agentSessions.count == 4)
        #expect(ws.agentSessions.first { $0.id == "claude:c" }?.status == .completed)
    }

    @Test("A session stays with its workstream even after switching branch")
    func sessionStaysPut() async throws {
        let (receiver, service) = try await makeReceiver()
        try await send(receiver, payload("UserPromptSubmit", seq: 1, branch: "feat/one"))
        try await send(receiver, payload("Stop", seq: 2, branch: "feat/two"))
        let ws = try await onlyWorkstream(service)
        #expect(ws.events.count == 2)
        #expect(ws.title == "One")
    }

    @Test("Two sessions on the same repository and branch share a workstream")
    func sharedBranch() async throws {
        let (receiver, service) = try await makeReceiver()
        try await send(receiver, payload("UserPromptSubmit", session: "a", seq: 1, prompt: "pa"))
        try await send(receiver, payload("UserPromptSubmit", session: "b", seq: 1, prompt: "pb"))
        let ws = try await onlyWorkstream(service)
        #expect(ws.agentSessions.count == 2)
        #expect(ws.status.headline == "2 agents working")
    }

    @Test("Different branches and unrelated directories are separate workstreams")
    func separateWorkstreams() async throws {
        let (receiver, service) = try await makeReceiver()
        try await send(receiver, payload("UserPromptSubmit", session: "a", seq: 1, prompt: "pa", branch: "feat/one"))
        try await send(receiver, payload("UserPromptSubmit", session: "b", seq: 1, prompt: "pb", branch: "feat/two"))
        try await send(receiver, payload("UserPromptSubmit", session: "c", seq: 1, prompt: "pc", branch: nil, root: nil, cwd: "/tmp/x"))
        try await send(receiver, payload("UserPromptSubmit", session: "d", seq: 1, prompt: "pd", branch: nil, root: nil, cwd: "/tmp/y"))
        #expect(await service.snapshot.workstreams.map(\.title).sorted() == ["One", "Two", "x", "y"])
    }

    @Test("A failed Claude turn keeps pending review feedback with me")
    func failureKeepsFeedback() async throws {
        let (receiver, service) = try await makeReceiver()
        // Feedback on the PR linked to the same branch.
        let branch = ExternalReference.branch("feat/avatar-migration", repository: "/Users/me/Code/plane")
        try await service.register(WorkstreamID("avatar"), title: "Avatar migration", references: [branch])
        try await service.ingest([ObservedEvent(
            id: EventID(.github, "review", "1"), source: .github, kind: .changesRequested,
            timestamp: Date(timeIntervalSince1970: 1_800_000_000), metadata: [.reviewer: "Priya"], references: [branch]
        )])

        try await send(receiver, payload("UserPromptSubmit", seq: 1))
        #expect(try await onlyWorkstream(service).nextOwner == .agent)

        try await send(receiver, payload("StopFailure", seq: 2, error: "server_error"))
        let ws = try await onlyWorkstream(service)
        #expect(ws.nextOwner == .me)
        #expect(ws.attention == .high)
        #expect(ws.state == .needsAttention)
    }
}
