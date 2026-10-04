import Foundation

/// How the user's team works, where that changes who owns the next action. Local configuration,
/// not GitHub logic: with no rules, Tern decides from GitHub's state alone.
struct WorkflowRules: Codable, Hashable, Sendable {
    /// A label that hands a ready pull request to someone else to merge. While the pull request
    /// is approved on its current head, otherwise mergeable and carries the label, the merge is
    /// theirs: Tern shows it as waiting and never asks the user to merge.
    struct MergeHandOff: Codable, Hashable, Sendable {
        /// Label name, matched case-insensitively.
        var label: String
        /// Who merges, for display ("manager", "lead").
        var mergedBy: String
    }

    var mergeHandOffs: [MergeHandOff] = []

    static let none = WorkflowRules()

    /// The first hand-off whose label is applied, with when it was applied.
    func mergeHandOff(in pullRequest: PullRequestFacts) -> (rule: MergeHandOff, since: WorkstreamFacts.Stamp)? {
        for rule in mergeHandOffs {
            if let since = pullRequest.labelApplied(rule.label) { return (rule, since) }
        }
        return nil
    }
}

extension WorkflowRules {
    /// Defaults key holding the rules as JSON. Absent means `standard`; set it to change them, e.g.
    ///
    ///     defaults write so.plane.tern workflow.rules '{"mergeHandOffs":[{"label":"ready to merge","mergedBy":"manager"}]}'
    ///     defaults write so.plane.tern workflow.rules '{"mergeHandOffs":[]}'   # no hand-off
    static let defaultsKey = "workflow.rules"

    /// The rules used when none are configured: this team merges through a lead, signalled
    /// by the "ready to merge" label.
    static let standard = WorkflowRules(mergeHandOffs: [MergeHandOff(label: "ready to merge", mergedBy: "manager")])

    /// Reads the configured rules. Unreadable configuration falls back to `standard`.
    static func load(from defaults: UserDefaults) -> WorkflowRules {
        guard let json = defaults.string(forKey: defaultsKey),
              let rules = try? JSONDecoder().decode(WorkflowRules.self, from: Data(json.utf8))
        else { return .standard }
        return rules
    }
}
