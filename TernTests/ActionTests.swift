import Foundation
import Testing
@testable import Tern

/// Records what would have been opened; never launches a browser.
@MainActor
final class FakeActionRouter: ActionRouter {
    private(set) var opened: [URL] = []
    func open(_ url: URL) { opened.append(url) }
}

@Suite("Actions")
@MainActor
struct ActionTests {
    static let prURL = URL(string: "https://github.com/makeplane/plane/pull/421")!
    static let planeURL = URL(string: "https://app.plane.so/plane/browse/WEB-9307/")!

    /// A workstream whose evaluation says `owner` holds the next move, with the status about `focus`.
    private func workstream(owner: Owner = .me, focus: EventSource?, reason: AttentionReason = .changesRequested,
                            prURL: URL? = ActionTests.prURL, planeURL: URL? = ActionTests.planeURL,
                            hasPlane: Bool = true, hasPR: Bool = true) -> Workstream {
        var ws = Workstream(
            id: WorkstreamID("github.pr:makeplane/plane#421"), title: "Avatar migration",
            planeItem: hasPlane ? PlaneItemReference(identifier: "WEB-9307", title: "Avatar migration", url: planeURL) : nil,
            pullRequest: hasPR ? PullRequestReference(repository: "makeplane/plane", number: 421, url: prURL) : nil
        )
        ws.evaluation = WorkstreamEvaluation(
            decision: AttentionDecision(shouldNotify: false, state: owner == .me ? .needsAttention : .waiting, nextOwner: owner,
                                        attention: owner == .me ? .high : .low, nextAction: NextAction(title: "Next", reason: "Why"), reason: reason),
            status: StatusLine(headline: "Status", focus: focus),
            lastMeaningfulChange: GH.t0,
            transition: .initial
        )
        return ws
    }

    // MARK: Resolving

    @Test("A GitHub-focused item opens its PR first, and its Plane item second")
    func gitHub() {
        let actions = ActionResolver.actions(for: workstream(focus: .github), context: .professional)
        #expect(actions.primary?.kind == .openPullRequest)
        #expect(actions.primary?.url == Self.prURL)
        #expect(actions.primary?.title == "Open PR")
        #expect(actions.secondary?.kind == .openPlaneItem)
        #expect(actions.secondary?.url == Self.planeURL)
        #expect(actions.primary?.subjectID == SubjectID(rawValue: "github.pr:makeplane/plane#421"))
        #expect(actions.primary?.context == .professional)
    }

    @Test("A Plane-focused item opens Plane first; without a PR there's no secondary")
    func plane() {
        let both = ActionResolver.actions(for: workstream(focus: .plane, reason: .readyToStart), context: .professional)
        #expect(both.primary?.kind == .openPlaneItem && both.primary?.title == "Open in Plane")
        #expect(both.secondary?.kind == .openPullRequest)
        let planeOnly = ActionResolver.actions(for: workstream(focus: .plane, reason: .readyToStart, hasPR: false), context: .professional)
        #expect(planeOnly.primary?.url == Self.planeURL && planeOnly.secondary == nil)
    }

    @Test("Missing URLs never produce an action, and a GitHub item without a PR link falls back to Plane")
    func missingURLs() {
        #expect(ActionResolver.actions(for: workstream(focus: .github, prURL: nil, planeURL: nil), context: .professional) == .none)
        let fallback = ActionResolver.actions(for: workstream(focus: .github, prURL: nil), context: .professional)
        #expect(fallback.primary?.kind == .openPlaneItem && fallback.secondary == nil)
        #expect(ActionResolver.actions(for: workstream(focus: .github, hasPlane: false, hasPR: false), context: .personal) == .none)
    }

    @Test("Answering an agent has no destination Tern can open")
    func agent() {
        #expect(ActionResolver.actions(for: workstream(focus: .agent, reason: .agentNeedsInput), context: .personal) == .none)
    }

    @Test("Work someone else owns has no action, e.g. a ready-to-merge PR the lead merges")
    func notMine() {
        for owner in [Owner.external, .reviewer, .ci, .agent, .none] {
            let ws = workstream(owner: owner, focus: .github, reason: .approvedReadyToMerge)
            #expect(ActionResolver.actions(for: ws, context: .professional) == .none)
        }
    }

    @Test("A meeting with a call link joins it; without one, or declined, or over, there's no action")
    func meetings() {
        let at = CalendarTests.t0.addingTimeInterval(20 * 60)
        func status(_ meeting: Meeting) -> MeetingStatus { MeetingEvaluator.evaluate(meeting, context: .professional, at: at) }
        let linked = status(CalendarTests.meeting("l", in: CalendarTests.work, startsIn: 30, url: CalendarTests.zoom))
        #expect(ActionResolver.actions(for: linked).primary?.kind == .joinMeeting)
        #expect(ActionResolver.actions(for: linked).primary?.url == CalendarTests.zoom)
        #expect(ActionResolver.actions(for: linked).secondary == nil)
        #expect(ActionResolver.actions(for: status(CalendarTests.meeting("p", in: CalendarTests.work, startsIn: 30))) == .none)
        #expect(ActionResolver.actions(for: status(CalendarTests.meeting("d", in: CalendarTests.work, startsIn: 30, url: CalendarTests.zoom,
                                                                          participation: .declined))) == .none)
        #expect(ActionResolver.actions(for: status(CalendarTests.meeting("e", in: CalendarTests.work, startsIn: -60, url: CalendarTests.zoom))) == .none)
    }

    // MARK: Performing

    private func liveModel() async throws -> (AppModel, IngestionService, InMemoryTernStore, FakeActionRouter) {
        let store = InMemoryTernStore()
        let service = IngestionService(store: store, now: { GH.t0 })
        try await service.start()
        try await service.setActiveContext(.professional)
        try await service.setContext(.professional, forOwner: "makeplane")
        try await service.setContext(.personal, forOwner: "atul")
        let pr = { (repo: String, n: Int) -> [ObservedEvent] in
            let reference = ExternalReference.pullRequest(repository: repo, number: n)
            let ref = PullRequestReference(repository: repo, number: n, url: URL(string: "https://github.com/\(repo)/pull/\(n)"))
            return [
                ObservedEvent(id: EventID(.github, "act", repo, "\(n)", "o"), source: .github, kind: .pullRequestOpened, timestamp: GH.at(0),
                              metadata: [.role: "author", .actor: GH.me, .actorIsMe: "true"], references: [reference], pullRequest: ref),
                ObservedEvent(id: EventID(.github, "act", repo, "\(n)", "ci"), source: .github, kind: .ciFailed, timestamp: GH.at(1),
                              metadata: [.checkName: "build"], references: [reference], pullRequest: ref),
            ]
        }
        try await service.ingest(pr("makeplane/plane", 1) + pr("atul/blog", 2))
        let model = AppModel(service: service)
        let router = FakeActionRouter()
        model.router = router
        for _ in 0..<300 where !(model.workstreams.count == 2 && !model.contextRules.owners.isEmpty) { try await Task.sleep(for: .milliseconds(10)) }
        return (model, service, store, router)
    }

    @Test("Performing opens exactly the target, and changes nothing in Tern")
    func performDoesNotMutate() async throws {
        let (model, service, store, router) = try await liveModel()
        let item = try #require(model.needsYou.first)
        let target = try #require(model.actions(for: item).primary)
        #expect(target.url.absoluteString == "https://github.com/makeplane/plane/pull/1")

        let before = (store.load(), await service.snapshot, model.attentionQueue.map(\.id), item.workstream?.evaluation)
        #expect(model.perform(target))
        try await Task.sleep(for: .milliseconds(50))
        #expect(router.opened == [target.url])
        #expect(store.load() == before.0)
        #expect(await service.snapshot == before.1)
        #expect(model.attentionQueue.map(\.id) == before.2)
        #expect(model.needsYou.first?.workstream?.evaluation == before.3)
    }

    @Test("An action from the other context is refused; the active context's opens")
    func contextCorrect() async throws {
        let (model, _, _, router) = try await liveModel()
        let personal = try #require(model.workstreams.first { $0.pullRequest?.repository == "atul/blog" })
        // A stale row from Personal while Professional is active.
        let stale = try #require(model.actions(for: .workstream(personal)).primary)
        #expect(stale.context == .personal)
        #expect(!model.perform(stale))
        #expect(router.opened.isEmpty)

        model.setActiveContext(.personal)
        #expect(model.perform(stale))
        #expect(router.opened == [URL(string: "https://github.com/atul/blog/pull/2")!])
    }
}
