import Foundation

/// Converts Claude Code hook payloads into domain `ObservedEvent`s.
///
/// Lifecycle mapping. Claude Code separates turns from sessions, and so does Tern:
///
/// | Hook                                   | Event                | Meaning                                  |
/// |----------------------------------------|----------------------|------------------------------------------|
/// | SessionStart                           | `agentSessionOpened` | Session exists; says nothing about work  |
/// | UserPromptSubmit                       | `agentStarted`       | A turn began: the agent owns it          |
/// | Notification (permission, elicitation) | `agentNeedsInput`    | Turn is blocked on the user              |
/// | PostToolUse after a prompt, elicitation done | `agentResumed` | User answered; turn continues            |
/// | Stop                                   | `agentCompleted`     | Turn finished, control back to the user  |
/// | StopFailure                            | `agentFailed`        | Turn ended with an API error             |
/// | SessionEnd                             | `agentSessionEnded`  | Session closed                           |
///
/// `Stop` never ends the session. Idle reminders and other notifications that do not
/// change whose turn it is are dropped.
enum ClaudeHookNormalizer {
    static let provider = "claude"
    static let agentName = "Claude Code"

    /// Notification types that mean Claude is blocked until the user acts.
    static let needsInputNotifications: Set<String> = [
        "permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input",
    ]
    /// Notification types that mean the user has answered.
    static let resumedNotifications: Set<String> = ["elicitation_complete", "elicitation_response"]

    /// Returns `nil` for hooks that carry no ownership signal, or payloads without a usable session.
    static func normalize(_ payload: ClaudeHookPayload, receivedAt: Date) -> ObservedEvent? {
        let session = sanitized(payload.sessionID)
        guard !session.isEmpty else { return nil }

        let kind: WorkEventKind
        var metadata: [MetadataKey: String] = [:]
        var allowsNewWorkstream = true

        switch payload.hookEventName {
        case "SessionStart":
            kind = .agentSessionOpened
        case "UserPromptSubmit":
            kind = .agentStarted
        case "Notification":
            guard let type = payload.notificationType else { return nil }
            if needsInputNotifications.contains(type) {
                kind = .agentNeedsInput
                metadata[.prompt] = payload.message.map { String($0.prefix(200)) }
            } else if resumedNotifications.contains(type) {
                kind = .agentResumed
            } else {
                return nil
            }
        case "PostToolUse":
            // The helper only forwards PostToolUse while an input request is outstanding.
            kind = .agentResumed
        case "Stop":
            kind = .agentCompleted
        case "StopFailure":
            kind = .agentFailed
            metadata[.reason] = failureDescription(payload.error ?? payload.errorType)
        case "SessionEnd":
            kind = .agentSessionEnded
            allowsNewWorkstream = false
        default:
            return nil
        }

        metadata[.agentName] = agentName
        metadata[.agentSessionID] = "\(provider):\(session)"

        let timestamp = payload.timestampMilliseconds
            .map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) } ?? receivedAt
        let place = workplace(for: payload)

        return ObservedEvent(
            id: eventID(for: payload, session: session),
            source: .agent,
            kind: kind,
            timestamp: timestamp,
            metadata: metadata,
            references: [.agentSession(provider: provider, id: session)] + (place.map { [$0.reference] } ?? []),
            suggestedTitle: place?.title,
            workstreamKey: place?.reference,
            allowsNewWorkstream: allowsNewWorkstream
        )
    }

    /// `agent:claude:<session>:<event>:<key>`. A prompt is identified by its `prompt_id`;
    /// everything else by the helper's per-session sequence number (plus the prompt, when
    /// present), since the same notification can legitimately fire twice in one turn.
    static func eventID(for payload: ClaudeHookPayload, session: String) -> EventID {
        let event = sanitized(payload.hookEventName)
        let prompt = payload.promptID.map(sanitized)
        if event == "UserPromptSubmit", let prompt, !prompt.isEmpty {
            return EventID(.agent, provider, session, event, prompt)
        }
        let sequence = payload.sequence.map(String.init)
            ?? payload.timestampMilliseconds.map { "t\($0)" }
            ?? "0"
        return EventID(.agent, provider, session, event, prompt ?? "-", sequence)
    }

    /// Where the session is working: a git branch when available, otherwise the directory.
    /// A repository on GitHub is identified as `github.com/owner/name`, the same way pull
    /// requests are, so a session and its PR land in one workstream. Branches are deliberately
    /// not combined with the directory, so different branches stay separate workstreams.
    static func workplace(for payload: ClaudeHookPayload) -> (reference: ExternalReference, title: String)? {
        if let root = payload.gitRoot {
            let repository = URL(fileURLWithPath: root).lastPathComponent
            let identity = payload.gitRemote.map(ExternalReference.gitHubRepository) ?? root
            if let branch = payload.gitBranch, !branch.isEmpty {
                return (.branch(branch, repository: identity), title(branch: branch, repository: repository))
            }
            if let head = payload.gitHead, !head.isEmpty {
                return (.branch("detached-\(head)", repository: identity), "\(repository) @ \(head)")
            }
        }
        guard let cwd = payload.cwd, !cwd.isEmpty else { return nil }
        return (.workingDirectory(cwd), URL(fileURLWithPath: cwd).lastPathComponent)
    }

    /// "feat/avatar-migration" → "Avatar migration". Trunk branches fall back to the repository name.
    static func title(branch: String, repository: String) -> String {
        let trunks: Set<String> = ["main", "master", "develop", "dev", "trunk"]
        guard !trunks.contains(branch) else { return repository }
        let leaf = branch.split(separator: "/").last.map(String.init) ?? branch
        let words = leaf.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        let trimmed = words.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return repository }
        return first.uppercased() + trimmed.dropFirst()
    }

    private static func failureDescription(_ error: String?) -> String {
        switch error {
        case "rate_limit": "Hit a rate limit"
        case "overloaded": "API overloaded"
        case "authentication_failed", "oauth_org_not_allowed": "Authentication failed"
        case "billing_error", "account_on_hold": "Billing problem"
        case "max_output_tokens": "Ran out of output tokens"
        case .some(let other): other.replacingOccurrences(of: "_", with: " ").capitalized
        case nil: "Stopped with an error"
        }
    }

    /// Keeps identifiers to a safe character set so they can't break IDs or reference keys.
    private static func sanitized(_ value: String) -> String {
        String(value.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }.prefix(128))
    }
}
