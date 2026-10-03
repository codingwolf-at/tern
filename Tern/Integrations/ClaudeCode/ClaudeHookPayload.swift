import Foundation

/// The subset of a Claude Code hook payload that Tern accepts, as forwarded by `tern-hook`.
///
/// Field names follow Claude Code's hook input. Only allowlisted fields ever reach the app:
/// prompts, assistant messages, transcript paths, tool input and error text are dropped by
/// the helper before transport. `tern_*` fields are added by the helper itself.
struct ClaudeHookPayload: Hashable, Sendable, Codable {
    let hookEventName: String
    let sessionID: String
    let promptID: String?
    let cwd: String?
    /// SessionStart: `startup`, `resume`, `clear`, `compact`, `fork`.
    let source: String?
    /// Notification: e.g. `permission_prompt`, `idle_prompt`, `elicitation_dialog`.
    let notificationType: String?
    /// Notification body, truncated by the helper. Shown as context, never logged.
    let message: String?
    /// SessionEnd: `clear`, `resume`, `logout`, `prompt_input_exit`, `other`.
    let reason: String?
    /// StopFailure category. Claude Code 2.1 sends `error`; the docs name it `error_type`.
    let error: String?
    let errorType: String?

    /// Per-session sequence number assigned by the helper when the hook fired.
    let sequence: Int?
    /// When the hook fired, in milliseconds since 1970.
    let timestampMilliseconds: Int64?
    let gitRoot: String?
    let gitBranch: String?
    /// Short commit hash when HEAD is detached.
    let gitHead: String?

    enum CodingKeys: String, CodingKey {
        case hookEventName = "hook_event_name"
        case sessionID = "session_id"
        case promptID = "prompt_id"
        case cwd
        case source
        case notificationType = "notification_type"
        case message
        case reason
        case error
        case errorType = "error_type"
        case sequence = "tern_seq"
        case timestampMilliseconds = "tern_ts"
        case gitRoot = "tern_git_root"
        case gitBranch = "tern_git_branch"
        case gitHead = "tern_git_head"
    }

    init(
        hookEventName: String,
        sessionID: String,
        promptID: String? = nil,
        cwd: String? = nil,
        source: String? = nil,
        notificationType: String? = nil,
        message: String? = nil,
        reason: String? = nil,
        error: String? = nil,
        errorType: String? = nil,
        sequence: Int? = nil,
        timestampMilliseconds: Int64? = nil,
        gitRoot: String? = nil,
        gitBranch: String? = nil,
        gitHead: String? = nil
    ) {
        self.hookEventName = hookEventName
        self.sessionID = sessionID
        self.promptID = promptID
        self.cwd = cwd
        self.source = source
        self.notificationType = notificationType
        self.message = message
        self.reason = reason
        self.error = error
        self.errorType = errorType
        self.sequence = sequence
        self.timestampMilliseconds = timestampMilliseconds
        self.gitRoot = gitRoot
        self.gitBranch = gitBranch
        self.gitHead = gitHead
    }
}
