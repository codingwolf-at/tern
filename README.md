<img src="docs/brand/concept-turn.svg" width="48" height="48" alt="The Tern mark: a path that turns and comes back, with a dot where it lands">

# Tern

> Know when it's your turn.

Developer work is spread across pull requests, reviews, CI runs, issue trackers and AI coding sessions. Most of the time, that work is in someone else's hands — a reviewer, a pipeline, an agent. Tern is a small native macOS menu bar app that tracks the state of each piece of work and stays quiet until the next action comes back to you.

> [!NOTE]
> Tern is an actively developed personal side project. APIs, UI and architecture are still evolving.

<!--
Screenshots: add PNGs to docs/images/ and uncomment.

<p align="center">
  <img src="docs/images/panel.png" width="360" alt="Tern's menu bar panel">
</p>
-->

## Why Tern

Tern is not a notification aggregator. It models work as a stream of **ownership transitions**:

```
ME → AGENT → REVIEWER → ME → CI → ME → COMPLETE
```

The interesting event is not "something happened". It is "the ball is back with me".

A new commit on a pull request you're reviewing, a CI run starting, an agent reading files — these change state, but they don't need you. A requested change, a failed check, or an agent waiting for input do. Tern is **quiet by default**: it surfaces a workstream only when the turn is yours and the reason is new.

## What it does

- **Menu bar app.** The Tern mark sits in the menu bar. When something needs you, the ball appears next to the path with a count beside it. Clicking it opens a SwiftUI panel.
- **Workstreams, not events.** A Plane work item, its pull request and the Claude Code sessions working on it are linked into one workstream.
- **Ownership detection.** For each workstream Tern works out who holds the next action: you, an agent, a reviewer, CI, someone external, or nobody.
- **Attention ranking.** Work that needs you is ranked by urgency and by how much the repository matters to you (primary, normal, low priority, muted). This is a ranking preference, separate from Personal/Professional contexts.
- **Take me there.** Tern doesn't just tell you when it's your turn; it can take you directly to where the next action happens. Items that are yours get one button: **Open PR**, **Open in Plane** or **Join meeting**, plus the other destination when a PR and its Plane item are linked. Buttons only use links GitHub, Plane or the calendar event provided, and pressing one changes nothing in Tern; the item updates when the source system reports what you did. Agent sessions have no button, since answering Claude happens in its own terminal or editor.
- **Snooze.** Right-click something that needs you and snooze it for 30 minutes, 1 hour, 3 hours or until tomorrow morning (9:00). It leaves Needs you, the badge and notifications until then, without changing the work itself; anything that changed meanwhile is notified once when the snooze ends. Snoozes are per context and listed in a small *Snoozed* section with Unsnooze.
- **Panel sections.** *Needs you*, *Waiting*, *Active*, *Your other work*, *Done today* and *Idle*.
- **Personal / Professional contexts.** Work is separated into two contexts; only the active one counts toward the queue and badge.
- **Transition-based alerts.** Tern decides whether a change is worth surfacing by comparing it against what you were last shown, and marks genuinely new items in the panel.
- **Meeting awareness.** A meeting from a calendar you classified becomes a candidate for *Needs you* 15 minutes before it starts, ranked with your work on one scale, with a Join action when the event carries a call link.
- **Integrations.** GitHub (through the `gh` CLI), Plane, Claude Code hooks, and macOS Calendar (read-only).

## Screenshots

<!--
<p align="center">
  <img src="docs/images/needs-you.png" width="360" alt="Needs you section">
  &nbsp;
  <img src="docs/images/contexts.png" width="360" alt="Personal and Professional contexts">
</p>
-->

*Screenshots coming soon.*

## The core model

```
  Event          GitHub sync · Plane sync · Claude Code hook
    ↓
  Normalize      integration-specific payload → WorkEvent
    ↓
  Workstream     link by PR, branch, session, Plane identifier
    ↓
  State          active · waiting · blocked · needs attention · complete
    ↓
  Ownership      me · agent · reviewer · CI · external · none
    ↓
  Attention      silent · low · medium · high · urgent
    ↓
  Next action    "Address requested changes", "Answer Claude", …
    ↓
  Surface        panel, badge, "New" marker
```

Raw events never generate alerts directly. Every decision is derived from the workstream's full event history, so the same history always yields the same answer regardless of the order events arrived in. A change is surfaced only if the turn is yours at medium attention or above, and it differs from what you were last shown: the ball came back to you, it got more urgent, or a newer event caused it.

## Attention model

Tern keeps four ideas separate:

| Concept | Question it answers |
| --- | --- |
| **State** | Where is this work in its lifecycle? |
| **Ownership** | Who holds the next action? |
| **Attention** | How loudly should it claim you? |
| **Priority** | Among everything that needs you, what comes first? |

Two examples:

- **Approved and ready to merge.** If your team merges through a lead — signalled by a configurable label such as `ready to merge` — the merge is theirs. Tern shows the pull request as *waiting* on them rather than giving you a task.
- **Changes pushed after review.** You pushed fixes, so the turn is technically yours (re-request review), but it isn't worth an interruption. It goes under *Your other work* instead of *Needs you*.

Every surfaced item carries a reason (review requested, CI failed, agent needs input, …), so Tern can always say why something is in front of you.

## Contexts

Personal and Professional are a domain-level split, not a view filter. The active context determines what takes part in the attention queue, ranking, badge and notifications; switching recalculates all of it. Work in the other context keeps syncing quietly and is waiting in its own queue when you switch back.

| Personal | Professional |
| --- | --- |
| Personal GitHub repositories | Work GitHub organizations and repositories |
| Agent sessions in personal repos | Plane work items |
| Calendars marked Personal | Agent sessions in work repos |
| — | Calendars marked Professional |

Nothing is inferred. You classify a GitHub owner (or a single repository, which overrides its owner) once by right-clicking it in the panel; unknown repositories are intentionally *unclassified* and appear in neither context — only in a small Unclassified list — until you do. Plane is professional-only; a Plane item linked to a repository you marked Personal is a conflict and stays unclassified. Calendars are classified one by one under *Calendar* at the bottom of the panel; an unclassified calendar is never read.

## Integrations

**GitHub** — Tern runs your installed, authenticated [`gh`](https://cli.github.com) CLI to read pull requests you authored and reviews requested from you. Authentication stays inside `gh`: Tern never asks for, reads or stores a GitHub token.

**Plane** — Read-only sync of open work items assigned to you, from Plane Cloud or a self-hosted instance. You connect with a workspace and a personal access token, which is stored in the macOS login Keychain. Plane items are linked to pull requests when their identifier appears in the branch name, title or body.

**Claude Code** — A small helper, `tern-hook`, is bundled inside `Tern.app` and registered as a Claude Code [command hook](https://docs.claude.com/en/docs/claude-code/hooks). It forwards session lifecycle events (started, needs input, finished, failed) to Tern through a local `tern://` URL. Only the fields Tern needs are forwarded — never prompts, responses, transcripts or tool input. Tern normalizes them into the same work events as every other integration.

**Calendar** — Read-only access to the calendars on your Mac through EventKit, granted only when you press *Allow access*. Tern reads upcoming meetings from the calendars you marked Personal or Professional and keeps them in memory only: it persists the classification and which meeting alerts it has shown, never titles, notes, attendees or links. A meeting is not a workstream; it is its own short-lived source of attention that goes through the same notification policy. All-day events and meetings you declined never claim attention. The Join action appears only when the event itself carries a link to a known call service (Zoom, Meet, Teams, …).

## Local first

Tern runs entirely on your Mac and has no server of its own. It reuses authentication you already have (`gh`) or keeps credentials in the Keychain (Plane), and stores its state as a JSON file in `~/Library/Application Support/Tern/`. The only network traffic is Tern's own calls to GitHub (via `gh`) and to your Plane instance.

## Visual identity

The mark is a path that rises, turns and comes back, with a ball where it lands: the work went around, and now it's your turn. One accent colour, coral, means "your turn" and nothing else. Errors are crimson, and everything that isn't yours stays neutral. The UI uses system fonts, with SF Mono for identifiers. [docs/BRAND.md](docs/BRAND.md) has the full system and usage rules.

## Architecture

```
Tern/
├── App/            entry point, AppModel (panel state), URL routing
├── Domain/         workstreams, events, ownership, attention, contexts, workflow rules
├── Engine/         attention engine, ownership resolver, priority model, notification policy
├── Services/       IngestionService — the single path from events to workstreams
├── Integrations/   GitHub, Plane, Claude Code: sync, API models, normalizers
├── Persistence/    JSON state store, Keychain
├── UI/             SwiftUI panel, rows, connection views
└── Debug/          mock scenarios and diagnostics (Debug builds only)
TernHook/           the tern-hook command-line helper
TernTests/          Swift Testing suite
scripts/            install and hook-management scripts
```

Integrations only produce normalized events. `IngestionService` deduplicates them, links them to workstreams, and asks the engine — pure, deterministic functions over a workstream's history — for its current state, owner, attention and next action.

## Development

**Requirements:** macOS 15+, Xcode 16+ (Swift 6). Optional: an authenticated `gh` CLI, a Plane account, Claude Code.

```bash
open Tern.xcodeproj
```

Run the **Tern** scheme. Debug builds keep their own bundle ID, URL scheme, defaults and Keychain items, so they never touch an installed copy. They start in memory with a mock scenario; set `TERN_MOCK=0` in the scheme's environment to start empty, or `TERN_PERSIST=1` to start without the mock and keep state across launches in `~/Library/Application Support/Tern/state-debug.json` (never the installed app's `state.json`).

Build Release from the command line:

```bash
xcodebuild -project Tern.xcodeproj -scheme Tern -configuration Release build
```

Build, install to `/Applications`, register the Claude Code hooks and launch:

```bash
scripts/install-tern.sh
```

Run it again to upgrade. `--help` lists the options (`--no-hooks`, `--dest`, `--ad-hoc`, …). Hooks can be managed separately:

```bash
scripts/install-claude-hooks.sh status
```

Workflow rules (such as the merge hand-off label) are read from user defaults:

```bash
defaults write so.plane.tern workflow.rules '{"mergeHandOffs":[{"label":"ready to merge","mergedBy":"manager"}]}'
```

## Testing

The project includes a comprehensive automated test suite written with [Swift Testing](https://developer.apple.com/xcode/swift-testing/), covering normalization, ownership, attention, notification decisions, determinism, persistence and the Claude Code hook path end to end.

```bash
xcodebuild test -project Tern.xcodeproj -scheme Tern -destination 'platform=macOS'
```

### Calendar validation checklist

A manual smoke test for the Calendar integration:

1. Run the Debug build from Xcode with `TERN_PERSIST=1` in the scheme's environment (so step 11 can check a relaunch).
2. Under *Calendar* at the bottom of the panel, press **Allow access…** and grant it. Ad-hoc-signed Debug builds can lose the grant after a rebuild; grant again if *Access off* appears.
3. Open the calendar list and mark one calendar **Personal**.
4. Mark another calendar **Professional**.
5. In Calendar, create a meeting about 16 minutes from now in the Professional calendar, with a Google Meet or Zoom link in its URL, location or notes.
6. Switch to Professional. The meeting shows under **Up next** with a countdown and "Needs you from <time>".
7. At that time (15 minutes before the start) it moves to **Needs you**, marked *New*, with "Inside the 15-minute preparation window" and **Join meeting**; the badge counts it.
8. Switch to Personal: it is gone from the panel and the badge. A Personal-calendar meeting behaves the same way the other way round.
9. Back in Professional, click **Join meeting**: the call link opens. A meeting without a link shows **Prepare for meeting** and nothing to click.
10. Switch contexts back and forth: no second *New* alert for the same meeting.
11. Quit and relaunch: the meeting is still in Needs you, without a new alert.
12. After the meeting starts it leaves Needs you (shown as in progress under Up next), and after it ends it disappears.

## Roadmap

Ideas, not promises:

- Calendar awareness — hold back interruptions during meetings
- Richer workstream context and history in the panel
- More developer workflow integrations
- Clearer explanations of why something is or isn't surfaced
