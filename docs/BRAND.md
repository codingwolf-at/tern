# Tern brand

> Know when it's your turn.

Status: **B · Turn is approved and implemented in the app.** A · Flight and C · Signal are rejected; they stay below for history. The approved system is in [The approved system](#the-approved-system), and how the app applies it is in [In the app](#in-the-app).

Files:

- [`brand/preview.html`](brand/preview.html): side-by-side comparison. Open it in a browser. Every mark is shown at 16, 20, 24, 32 and 64 pt on paper, white, dark and accent grounds, in monochrome, and as a true 1× pixel raster.
- `brand/concept-*.svg`: the three marks on a 24 pt grid, in colour and `-mono` (`currentColor`) versions.
- `brand/concept-turn-idle.svg`, `brand/lockup-turn*.svg`, `brand/app-icon-turn.svg`: extra assets for the recommended direction.

---

## What the brand has to say

Tern is the place that tells me when it's my turn again. The product idea is the moment the ball comes back:

```
ME → AGENT → REVIEWER → ME → CI → ME → COMPLETE
```

Most of the time Tern is silent, because the work is in someone else's hands. So the identity has to be about **return and timing**. Watching, alerting, AI and productivity are not the point. The brand still has to make sense if any one source (Claude Code included) disappeared.

---

## Three directions

### A · Flight — rejected

| | |
|---|---|
| **Core idea** | The tern itself: a long-distance flier, light and exact. |
| **Mark** | One filled silhouette: a tern seen from below, with swept crescent wings and a forked tail. No eye, no beak, no detail. ([concept-flight.svg](brand/concept-flight.svg)) |
| **Wordmark** | `Tern`, title case, SF Pro Display Medium, open tracking. Feels airy. |
| **Palette** | Cool paper `#F3F5F4`, ink `#101618`, accent **Sea glass** `#2B8A80` (dark `#4FB8AC`). |
| **Typography** | SF Pro, lighter weights (Regular/Medium), more air between lines. |
| **UI accent** | Teal fills for selection and primary buttons. Wing silhouette as an empty-state illustration. |
| **Why it fits** | It is the name made literal, and a solid silhouette survives every size. |
| **Risks** | It reads as a "bird app" (birding, travel, Twitter-adjacent) before it reads as a developer tool. It carries none of Tern's actual idea: ownership, handoff, return. Teal sits next to success green, so "accent" and "done" blur together. A bird is the mascot route the brief warns against. |

### B · Turn — approved

| | |
|---|---|
| **Core idea** | The work leaves you, goes around, and comes back. The ball lands with you. *Tern / turn.* |
| **Mark** | One heavy stroke that rises from the left, makes a wide round turn, and comes back. Where it ends, a separate dot (the ball) sits at the start. Three strokes' worth of geometry and no detail. ([concept-turn.svg](brand/concept-turn.svg)) |
| **Wordmark** | Lowercase `tern`, SF Pro Display Semibold, tracking −0.03 em. Plain and uncustomised. The mark does the work. |
| **Palette** | Warm paper `#F6F4EF`, ink `#17191C`, accent **Coral** `#E5533B` (dark `#FF6A4D`). The red-orange of a tern's bill is the only bird reference, and nobody needs to get it. |
| **Typography** | SF Pro at native sizes, SF Mono for identifiers. |
| **UI accent** | The ball. A small filled Coral dot means *yours*. A hollow ring means *someone else's*. Coral appears only where it is your turn. |
| **Why it fits** | The mark *is* the product model: outbound, away, back to you. It also works at a glance as a "return" gesture, and with the dot it reads vaguely like a bird turning in flight. That is a bonus, not a requirement. The dot gives the menu bar a natural on/off state. |
| **Risks** | Without the dot it can read as a sideways `?` or a hook. The dot is not optional in the logo. A warm accent sits near critical red, so the two need a deliberate hue gap and a usage rule (below). Return/loop marks exist elsewhere (refresh and undo icons). The missing arrowhead and the separate dot are what keep this one distinct. |

### C · Signal — rejected (its ownership glyphs were kept)

| | |
|---|---|
| **Core idea** | State changed, and now it's yours. A hollow ring (someone else holds it) hops to a filled dot (you hold it). |
| **Mark** | Ring, arc, dot, left to right. ([concept-signal.svg](brand/concept-signal.svg)) |
| **Wordmark** | Lowercase `tern`, SF Pro Text Semibold, compact. Pairs with the mark like a status label. |
| **Palette** | Neutral white `#FFFFFF`, ink `#17191C`, accent **Marine** `#2F5BEA` (dark `#6B8CFF`). |
| **Typography** | SF Pro, denser, more "instrument panel". |
| **UI accent** | Ring and dot as ownership glyphs on every row. Marine for the filled state. |
| **Why it fits** | The clearest semantic system of the three: hollow means theirs, filled means yours. It explains the product without words. |
| **Risks** | As a logo it reads as a git graph or node diagram, which is the most clichéd developer symbol available. At 16 pt @1× the ring's counter is about 2 px and gets muddy on dark. Flat blue lands right in generic-SaaS territory. It is a better *UI language* than a *mark*. |

### Small-size validation

All checked in `preview.html` at 16, 20 and 32 pt, on light, dark and monochrome grounds, and as a 1× raster.

| | 16 @1× | 20 @1× | 32 | Dark | Mono | Result |
|---|---|---|---|---|---|---|
| A Flight | Blob, tail fork lost | OK | OK | OK | OK | Survives, but as a generic bird |
| B Turn | Path and dot stay separate, counter open | OK | OK | OK (≈1.3 px gap holds) | OK | **Passes** |
| C Signal | Ring counter about 2 px, muddy | OK | OK | Weakest | OK | Passes with a caveat |

None of the three fully collapses. B is the only one where the small size still shows the *idea* and not just the silhouette.

---

## Recommendation

1. **Best: B · Turn.** It is built from Tern's actual concept, the ball coming back. It is not built from the bird and not from "notifications". It survives 16 pt, it works as a macOS template image, and its dot gives the menu bar a built-in "your turn" state with no badge colour. It has no AI signifiers at all.
2. **Runner-up: C · Signal.** It loses as a logo but wins as a *UI language*. Its hollow-ring and filled-dot ownership glyphs are adopted into the recommended system below.
3. **Reject: A · Flight.** It is the most literal and the least specific. A bird says "Tern" the word and nothing about Tern the product, and the brief asks for abstract first.

---

## The approved system

Everything below is the spec the app follows. Source artwork lives in `docs/brand/`; the app's assets are generated from it and must not drift.

### Personality

**Quiet, timely, exact, light, candid, personal.**

### Mark

- Source of truth: [`brand/concept-turn.svg`](brand/concept-turn.svg) on a 24 × 24 pt grid.
- Path: `M3.75 11.5 C6.5 7.6 10 5.5 14 5.5 A6 6 0 0 1 14 17.5 H13.25`, stroke 3 pt, round caps and joins.
- Ball: circle at (7, 17.5), r 2.75. Keep at least 2 pt (grid units) of clear space between the path's end cap and the ball. Never let them touch.
- Clear space around the mark: 4 pt on the 24 pt grid (one-sixth of its size).
- Minimum size: 16 pt. Below that, use the dot alone.
- Don't: add an arrowhead, rotate or mirror it, use outlines or gradients, put the ball anywhere else, or use the mark without the ball (except in the menu bar idle state).

Colourways:

| Use | Path | Ball |
|---|---|---|
| On light | Ink `#17191C` | Coral `#E5533B` |
| On dark | Fog `#EDEBE6` | Coral dark `#FF6A4D` |
| On Coral | White | White |
| Monochrome / template | `currentColor` | `currentColor` |

### Menu bar

- Template image (monochrome, so the system tints it). The 24 pt-grid SVG is in the asset catalog as a vector template and displayed at 18 × 18 pt, so the glyph itself is about 14 pt. Checked at 16, 18, 20 and 24 pt in light and dark.
- **Idle (nothing needs you):** path only, no ball ([`concept-turn-idle.svg`](brand/concept-turn-idle.svg)).
- **Your turn:** path and ball ([`concept-turn-mono.svg`](brand/concept-turn-mono.svg)), with the count as text after it (`2`), in system menu bar text.
- No colour and no red badge in the menu bar. The ball landing *is* the signal.

### App icon

[`brand/app-icon-turn.svg`](brand/app-icon-turn.svg): ink squircle, paper-coloured path, Coral ball. It follows the macOS 1024 grid (824 pt body, 100 pt inset). A light variant (paper body, ink path) exists in the preview for reference. Dark is primary.

### Wordmark

- Lowercase **tern**, SF Pro Display Semibold, tracking −0.03 em, optical size large. In running text and the UI, the product name is **Tern** (title case).
- Lockup: mark at 1.25× cap height to the left of the wordmark, with a gap equal to the ball's diameter ([`lockup-turn.svg`](brand/lockup-turn.svg)).
- Inside the app the wordmark is live system text. For any use outside the app (website, README banner), outline it first. Apple's SF licence covers UI on Apple platforms, not logos, so before Tern is distributed widely the four letters should be redrawn as custom outlines that follow SF's proportions.

### Colour

Tern UI keeps the system materials and vibrancy in the panel. Paper and Night are for brand surfaces: the app icon, README, website, onboarding. The accent and semantic colours apply everywhere.

| Token | Light | Dark | Use |
|---|---|---|---|
| `paper` | `#F6F4EF` | — | Brand background (light) |
| `night` | — | `#141618` | Brand background (dark) |
| `ink` / primary fg | `#17191C` | `#EDEBE6` | Titles, primary text, the mark |
| `ink2` / secondary | `#686C73` | `#9A9DA3` | Metadata, ages, section labels (4.8:1 / 6.7:1) |
| `ink3` / tertiary | `#9A9DA3` | `#6B6F76` | Hairlines, disabled, hollow rings |
| **`coral`** / accent | `#E5533B` | `#FF6A4D` | *Your turn*: the ball, the one primary button, unread mark |
| `coralText` | `#C2412A` | `#FF6A4D` | Accent used as small text (4.7:1 on paper) |
| `success` | `#26794F` | `#4CC38A` | CI passed, merged, done |
| `warning` | `#96600F` | `#E8A33D` | Stale, starting soon, rate-limited |
| `critical` | `#C42452` | `#F2567A` | CI failed, blocked, error |

Rules:

- **Coral means "yours", never "bad".** Errors use `critical`, which is deliberately pushed toward crimson (hue ≈ 345°) away from Coral's orange-red (≈ 9°). Critical always comes with words ("CI failed"), never colour alone.
- At most one filled Coral element per row, and one Coral-filled button per screen: the top *Needs you* item's action. Other actions are quiet (bordered or plain).
- Semantic colours tint text or a small glyph. They never fill a row background.
- No gradients, no purple, no blue primary.

### Ownership glyphs (from Signal)

An 8 pt glyph at the start of each row:

| Owner | Glyph |
|---|---|
| Me | Filled Coral dot ● |
| Agent, Reviewer, CI, External | Hollow ring ○, 1.5 pt, `ink3` |
| Nobody / complete | None (or `success` ✓ in *Done today*) |

The row's text already says *who*. The glyph says only *is it mine?*

### Typography

Use system fonts only. No downloaded fonts.

| Role | Font | Size / weight |
|---|---|---|
| Panel title | SF Pro | 15 pt Semibold (`.headline`-ish) |
| Row title | SF Pro | 13 pt Semibold |
| Row metadata | SF Pro | 12 pt Regular, `ink2` |
| Section label | SF Pro | 11 pt Semibold, `ink2`, sentence case ("Needs you") |
| Identifiers | SF Mono | 11.5 pt Regular, `ink2` (`WEB-412`, `PR #421`, `tern#88`) |
| Counts, ages | SF Pro, monospaced digits | Match surrounding text |
| Brand display | SF Pro Display | Semibold, −0.02 to −0.03 em tracking, 20 pt+ only |

Sizing philosophy: native macOS sizes (13 pt body), hierarchy through weight and colour and not through size jumps, and at most three sizes per view. Prefer SwiftUI text styles so Dynamic Type and accessibility settings work. The panel keeps its existing text-style hierarchy (`.callout` row titles, `.caption` metadata). The only type changes are SF Mono for identifiers and the wordmark.

### Voice

Tern speaks like a colleague who glanced at your screen. It uses short, plain, present-tense words. It states *what* and *whose*, then stops.

| Prefer | Avoid |
|---|---|
| Your turn. | You have 3 pending action items! |
| Needs you. | Attention required |
| Waiting on review. | Your PR is currently awaiting reviewer feedback |
| CI failed on main. | Oops! Something went wrong with your build 😬 |
| Starts in 12 min. | Upcoming meeting reminder |
| Agent needs input. | AI assistant requires your attention |
| Nothing needs you. | You're all caught up! 🎉 Great job! |
| Snoozed until 9:00. | We'll remind you later |

Labelling:

- Use sentence case everywhere ("Needs you", "Done today").
- Start a label with the state or verb: "Waiting on review", "Open PR", "Join".
- Name the source by its own name (GitHub, Plane, Claude, CI). Never "integration".
- Times are relative and compact: "8m", "3h", "in 12 min".
- No exclamation marks, no emoji, no "AI-powered", "smart", "optimize", "productivity" or "insights".
- Never anthropomorphise Tern ("I noticed…"). It reports state.

### Visual principles

1. **Quiet by default.** Silence is the normal state. Colour, motion and sound are spent only when the turn changes to you.
2. **State over activity.** Show who holds the work now, not the event log. "Waiting on review" beats "3 new commits".
3. **One clear action.** Each item gets at most one primary action, and each screen gets one Coral button. Everything else is secondary.
4. **Hierarchy over density.** Fewer rows with clear weight beat more rows. Use whitespace and weight before borders and boxes.
5. **Coral is a signal, not a theme.** The accent appears only where it is your turn. If everything is coral, nothing is.
6. **Purposeful motion.** Animate only arrivals and departures (an item landing in *Needs you*, a snooze leaving). Keep it short (≤ 200 ms), with no loops, pulses or bounce.
7. **Native first.** Use system materials, SF fonts, SF Symbols for UI glyphs, standard controls and template menu bar images. Tern should look like it shipped with macOS and then got opinions.

---

## In the app

Where each part of the system lives. Raw hex values exist only in the asset catalog.

### Assets (`Tern/Resources/Assets.xcassets`)

| Asset | What it is |
|---|---|
| `Coral`, `CoralText`, `Critical`, `Warning`, `Success` | Colour sets with light and dark values from the table above |
| `TernMark` | Path and ball, template image, vector (from `concept-turn-mono.svg`) |
| `TernMarkPath` | Path only, template (from `concept-turn-idle.svg`) |
| `TernMarkBall` | Ball only, template, so the panel header can colour the ball on its own |
| `AppIcon` | 16–1024 px PNGs rendered from `brand/app-icon-turn.svg` |

`AccentColor` is deliberately left at the system default. A global coral accent would leak into links, toggles and focus rings and dilute "your turn". Coral is applied only where the rules below say so.

To regenerate the app icon after changing `app-icon-turn.svg`, render it with `NSImage` (macOS reads SVG) at 16, 32, 64, 128, 256, 512 and 1024 px into `AppIcon.appiconset/icon_<px>.png`.

### Code (`Tern/UI/Theme.swift`, `Tern/UI/TurnMark.swift`)

- `TernColor`: `yourTurn` (coral), `yourTurnText`, `critical`, `warning`, `success`. Views use these or system semantic styles (`.primary`, `.secondary`, `.tertiary`), never literal colours.
- `AttentionTone.of(level:reason:mine:)` is visual only. If it isn't the user's move, or the level is silent, the tone is `.quiet`. If the reason is a failure (`ciFailed`, `agentFailed`) or the level is urgent, it is `.critical`. Otherwise it is `.yourTurn`. `AttentionLevel.tint` maps through it.
- `OwnershipMark`: `.ball` for `me`, `.ring` for agent, reviewer, CI and external, `.none` for nobody.
- `TurnMark` draws the header mark from the two template layers.
- `Font.identifier(_:)` is SF Mono, for Plane keys and PR numbers. `Font.wordmark` is the lowercase **tern**.

### UI usage rules

| Element | Treatment |
|---|---|
| Menu bar, idle | `TernMarkPath`, 18 pt template, no count |
| Menu bar, needs you | `TernMark` (the ball lands) and the count as plain menu bar text. No badge, no colour |
| Panel header | `TurnMark` at 18 pt and **tern** in SF Pro Semibold 17 pt. The ball is `.tertiary` when idle and coral when something needs you |
| Needs you heading | `coralText` while the section has items, otherwise neutral |
| Ownership marker | 8 pt. A coral ball when it's yours, a 1.5 pt `.tertiary` ring when someone else holds it, nothing for nobody. VoiceOver reads "Your turn" or "Reviewer has it" |
| Lead action | Only the first Needs you item's primary button is filled coral. All other buttons are bordered and neutral, and secondary actions have secondary-coloured labels |
| Failures | The headline is crimson with an `exclamationmark.circle.fill` glyph. The ball stays coral because it's still the user's move. The button is never coral |
| Next action line | Neutral (`.secondary`) |
| New badge | `coralText` on a 12% coral capsule |
| Snooze / Unsnooze | Neutral. Never coral |
| Waiting, Active, Done, Idle | Neutral styles only |
| Context switcher | Native segmented control tinted `.primary`, so the active context is ink on light and white on dark. Never coral, never the system accent |
| Connection status dots | `success` / `warning`. Errors in `critical` |
| Notifications | Native. The app icon identifies Tern, and the content is unchanged |
| Empty Needs you | "Nothing needs you." The header summary reads "All quiet" |
