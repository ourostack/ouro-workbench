# SU0a — Clock-seam spike (D-U2-1 / F-U2-CLOCK resolution)

**Verdict: GO — Candidate B (init-param `now: Date? = nil`).** Empirically confirmed.

## The fork
Two candidate mechanisms to make the elapsed-clock reads deterministic-in-tests
without changing production behavior:
- **Candidate A — `@Environment` date-source.** One seam, reaches `body`-evaluated
  views.
- **Candidate B — init-param `now: Date? = nil`**, threaded
  `TerminalAgentRow → ElapsedTimePill(startDate:now:)` AND into the
  `accessibilityLabel` `coarseDescription(since:now:)` shim call. Prod default
  `nil` → live clock.

## The decisive site: the `:3718` computed label (M1)
`TerminalAgentRow` exposes its elapsed read TWICE:
1. the `ElapsedTimePill` body (`:3776`) — a `Text` rendered inside a
   `TimelineView(.periodic)` closure (a `body`-evaluated view), and
2. `:3718` — `accessibilityLabel` is a **computed-property `String`** that calls
   `ElapsedTimePill.coarseDescription(since:runningSince, now: Date())`. This is
   evaluated OUTSIDE SwiftUI `body` resolution and surfaced to ViewInspector via
   `.accessibilityElement(children:.ignore)` + `.accessibilityLabel(...)`.

An `@Environment` value cannot deterministically pin site (2): a computed-property
`Date()` read is not in the SwiftUI body-evaluation graph, and (L7 / ViewInspector
#317) `.environment(\.…)` does not reliably reach `find()`-descended nodes. So
**the `:3718` label site forces Candidate B regardless of what the pill body
allows** — only an explicit init-param threaded into the shim call pins it.

## Empirical evidence (throwaway test, since deleted)
Applied Candidate B to all three sites; ran a throwaway leaf snapshot of a
directly-constructed `TerminalAgentRow(entry:isSelected:runningSince:now:)` under
`ViewSnapshotHost.snapshotText` (ViewInspector `findAll()`):

- `runningSince = now − 5m`, injected `now` fixed → serialized tree contained BOTH
  `text="5m"` (the pill body `Text` inside the `TimelineView` closure) AND
  `running for 5m` (the `:3718` computed `accessibilityLabel`). PASS.
- `runningSince = now − 2h`, same injected `now` → BOTH sites flipped to `2h`
  (`text="2h"` + `running for 2h`). PASS.

Both sites pinned to the FIXED injected `now` with zero live-`Date()` drift, under
a single consistent seam. 2/2 throwaway assertions passed.

## Chosen seam (implemented in SU0c)
- `ElapsedTimePill` gains `var now: Date? = nil`; body:
  `coarseDescription(since: startDate, now: now ?? context.date)`. The
  `TimelineView(.periodic(from:.now, by:30))` driver is **RETAINED** — in prod
  (`now == nil`) the periodic `context.date` still drives the tick.
- `TerminalAgentRow` gains `var now: Date? = nil`; threads it into
  `ElapsedTimePill(startDate:runningSince, now: now)` AND into the
  `accessibilityLabel` call: `coarseDescription(since: runningSince, now: now ?? Date())`.
- `DecisionInboxSheet` gains `var now: Date? = nil`; body:
  `content(now: now ?? context.date)`. `TimelineView(.periodic)` driver RETAINED.

**Prod default = live clock everywhere** (`nil` → `context.date` / `Date()`); the
periodic `TimelineView` driver is untouched at both embed sites, so the live app
keeps ticking every 30s. Production behavior is unchanged.

## Why not Candidate A
Rejected: cannot deterministically pin the `:3718` computed-property `String` read
(the decisive site). Adopting it would have required a SECOND, different mechanism
for the label — two seams for one concern. Candidate B pins both sites with one
consistent init-param.
