// tern-hook: forwards Claude Code hook events to Tern.
//
// Claude Code runs this as a command hook with the hook payload on stdin. It keeps only
// the fields Tern needs, adds a per-session sequence number, a timestamp and git context,
// and opens `tern://claude-hook?v=1&p=<base64url(JSON)>` in the background, which launches
// Tern if it isn't running. It never writes to stdout during normal use (Claude Code adds
// some hooks' stdout to the conversation) and always exits 0 so it can't disrupt a session.
//
// The URL is delivered to the Tern.app this helper is embedded in, never to whichever copy
// LaunchServices prefers, so hooks pointing at /Applications/Tern.app reach that app even
// when other builds are registered.
//
// Options:
//   --version                print the helper version
//   --print-target           print the app events are delivered to
//
// Environment:
//   TERN_HOOK_PRINT=1        print the URL instead of opening it (testing)
//   TERN_HOOK_STATE_DIR=...  where per-session state lives
//                            (default ~/Library/Application Support/Tern Hook/sessions)

import Foundation

/// Hook input fields forwarded to Tern. Prompts, assistant messages, transcript paths,
/// tool input and error text are never forwarded.
let forwardedFields = ["hook_event_name", "session_id", "prompt_id", "cwd", "source", "notification_type", "reason", "error", "error_type"]
let needsInputNotifications: Set<String> = ["permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input"]
let maximumInputBytes = 8 * 1024 * 1024

let environment = ProcessInfo.processInfo.environment

/// The Tern.app containing this helper (`Tern.app/Contents/Helpers/tern-hook`), or `nil`
/// when the helper runs on its own.
func containingApp() -> URL? {
    guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
    let helpers = executable.deletingLastPathComponent()
    let app = helpers.deletingLastPathComponent().deletingLastPathComponent()
    guard helpers.lastPathComponent == "Helpers", app.pathExtension == "app" else { return nil }
    return app
}

if CommandLine.arguments.contains("--version") {
    print("tern-hook 1")
    exit(0)
}

if CommandLine.arguments.contains("--print-target") {
    print(containingApp()?.path ?? "(default handler)")
    exit(0)
}

// MARK: - Input

let input = FileHandle.standardInput.readDataToEndOfFile()
guard input.count <= maximumInputBytes,
      let payload = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any],
      let event = payload["hook_event_name"] as? String,
      let rawSession = payload["session_id"] as? String
else { exit(0) }

let session = String(rawSession.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }.prefix(128))
guard !session.isEmpty else { exit(0) }

// MARK: - Per-session state

struct SessionState: Codable {
    var sequence = 0
    /// A permission or input request is outstanding; the next PostToolUse means the user answered.
    var awaitingInput = false
}

let stateDirectory = environment["TERN_HOOK_STATE_DIR"].map { URL(fileURLWithPath: $0) }
    ?? FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/Tern Hook/sessions", directoryHint: .isDirectory)

/// Runs `body` with the session's state under an exclusive lock, so concurrent async hooks
/// for one session get distinct sequence numbers. Returns `nil` if state can't be used.
func withSessionState<T>(_ body: (inout SessionState) -> T) -> T? {
    try? FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
    let url = stateDirectory.appending(path: session + ".json")
    let fd = open(url.path, O_RDWR | O_CREAT, 0o600)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    guard flock(fd, LOCK_EX) == 0 else { return nil }
    defer { flock(fd, LOCK_UN) }

    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    var state = (try? JSONDecoder().decode(SessionState.self, from: handle.readDataToEndOfFile())) ?? SessionState()
    let result = body(&state)
    guard let data = try? JSONEncoder().encode(state) else { return result }
    ftruncate(fd, 0)
    lseek(fd, 0, SEEK_SET)
    handle.write(data)
    return result
}

/// Removes state for sessions untouched for 30 days.
func pruneOldState() {
    let cutoff = Date().addingTimeInterval(-30 * 24 * 60 * 60)
    let files = (try? FileManager.default.contentsOfDirectory(at: stateDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    for file in files {
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let modified, modified < cutoff { try? FileManager.default.removeItem(at: file) }
    }
}

let notificationType = payload["notification_type"] as? String
let sequence: Int? = withSessionState { state -> Int? in
    switch event {
    case "PostToolUse":
        // Forward only the first tool result after an input request: that's the resume signal.
        guard state.awaitingInput else { return nil }
        state.awaitingInput = false
    case "Notification" where notificationType.map(needsInputNotifications.contains) == true:
        state.awaitingInput = true
    case "UserPromptSubmit", "Stop", "StopFailure", "SessionEnd":
        state.awaitingInput = false
    default:
        break
    }
    state.sequence += 1
    return state.sequence
} ?? (event == "PostToolUse" ? nil : 0)

guard let sequence else { exit(0) }
if event == "SessionStart" { pruneOldState() }

// MARK: - Git context

/// Runs a short command, giving up after `timeout` seconds.
func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 1) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning && Date() < deadline { usleep(5_000) }
    if process.isRunning { process.terminate(); return nil }
    guard process.terminationStatus == 0 else { return nil }
    let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
}

/// A git binary that won't trigger the "install developer tools" prompt on a bare system.
func gitExecutable() -> String? {
    let paths = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
    for directory in paths where directory != "/usr/bin" {
        let candidate = directory + "/git"
        if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
    }
    if FileManager.default.isExecutableFile(atPath: "/Library/Developer/CommandLineTools/usr/bin/git") {
        return "/Library/Developer/CommandLineTools/usr/bin/git"
    }
    return run("/usr/bin/xcode-select", ["-p"]) != nil ? "/usr/bin/git" : nil
}

/// `owner/name` for a GitHub remote URL (https or ssh), so sessions match pull requests.
func gitHubRepository(_ remote: String) -> String? {
    var path: Substring
    if let range = remote.range(of: "github.com:") ?? remote.range(of: "github.com/") {
        path = remote[range.upperBound...]
    } else {
        return nil
    }
    if path.hasSuffix(".git") { path = path.dropLast(4) }
    let parts = path.split(separator: "/")
    guard parts.count == 2 else { return nil }
    return "\(parts[0])/\(parts[1])"
}

var forwarded: [String: Any] = [:]
for field in forwardedFields {
    if let value = payload[field] as? String { forwarded[field] = String(value.prefix(512)) }
}
if event == "Notification", let message = payload["message"] as? String {
    forwarded["message"] = String(message.prefix(200))
}
forwarded["tern_seq"] = sequence
forwarded["tern_ts"] = Int64(Date().timeIntervalSince1970 * 1000)

// Turn and session endings belong to a session that's already linked; skip git to deliver fast.
let endsTurnOrSession: Set<String> = ["Stop", "StopFailure", "SessionEnd"]
if let cwd = payload["cwd"] as? String, !endsTurnOrSession.contains(event), let git = gitExecutable() {
    if let root = run(git, ["-C", cwd, "rev-parse", "--show-toplevel"]) {
        forwarded["tern_git_root"] = root
        if let remote = run(git, ["-C", cwd, "remote", "get-url", "origin"]).flatMap(gitHubRepository) {
            forwarded["tern_git_remote"] = remote
        }
        if let branch = run(git, ["-C", cwd, "symbolic-ref", "--short", "-q", "HEAD"]) {
            forwarded["tern_git_branch"] = branch
        } else if let head = run(git, ["-C", cwd, "rev-parse", "--short", "HEAD"]) {
            forwarded["tern_git_head"] = head
        }
    }
}

// MARK: - Transport

guard let json = try? JSONSerialization.data(withJSONObject: forwarded, options: [.sortedKeys]) else { exit(0) }
let encoded = json.base64EncodedString()
    .replacingOccurrences(of: "+", with: "-")
    .replacingOccurrences(of: "/", with: "_")
    .replacingOccurrences(of: "=", with: "")
var components = URLComponents()
#if DEBUG
components.scheme = "tern-debug" // matches the Debug app; installed hooks use the Release helper
#else
components.scheme = "tern"
#endif
components.host = "claude-hook"
components.queryItems = [URLQueryItem(name: "v", value: "1"), URLQueryItem(name: "p", value: encoded)]
guard let url = components.url else { exit(0) }

/// Hands the URL to Launch Services in a new session and doesn't wait. Claude Code may end the
/// hook's process group as soon as it exits (e.g. right after a `claude -p` turn fails), and a
/// delivery in flight must survive that.
func deliverDetached(_ url: URL) {
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
    // -g: deliver in the background without activating Tern or showing a window.
    // -a: to this helper's own app, so another registered build can't intercept the event.
    let target = containingApp().map { ["-a", $0.path] } ?? []
    let arguments = ["/usr/bin/open", "-g"] + target + [url.absoluteString]
    var argv = arguments.map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    var pid: pid_t = 0
    _ = posix_spawn(&pid, "/usr/bin/open", nil, &attributes, &argv, environ)
}

if environment["TERN_HOOK_PRINT"] == "1" {
    print(url.absoluteString)
} else {
    deliverDetached(url)
}
exit(0)
