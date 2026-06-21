# FRE subtraction — terminals-first, boss opt-in (doing doc)

Implements the subtractive FRE redesign from `fre-delight-doing.md`. Driven by the
operator mandate: *"very clear from the first FRE what its purpose is… then FEEL
that ease as quickly as possible… utility + lack-of-frustration shine… anything
that detracts/distracts → tear out."* Six-word story (the cut-test):
**"Your terminals. An agent runs them."**

## The core insight (from the code map)

The terminals-first product **already exists underneath**. Terminal creation has
**no gate** (⌘N works anytime); the main UI is fully functional. The 4-page
onboarding wizard is a `.sheet` auto-presented on top — a forced ceremony that
*hides* the working terminals and pushes the breakable `ouro check` Connect step
onto the critical first-run path. That forced ceremony is the distraction to tear
out. The boss + migration machinery is good — it just becomes **opt-in**, not forced.

This is also TTFA (Trust the Fucking Agent) applied to the user: don't demand a
trust ceremony up front; earn trust through instant utility, offer the boss when
they want it.

## What stays untouched

- The whole boss-setup wizard (`WorkbenchOnboardingSheet` + all its pages) — still
  reachable, now **opt-in** via the empty-state "Set up a boss" button
  (`model.presentOnboarding()`), exactly as the existing "Set Up Workbench" button
  already calls it.
- The migration / "Bring back your work" reconstruction — part of that opt-in flow.
- All `ouro check` / provider-check / readiness machinery.

## Units

### Unit 1 — Stop auto-presenting the forced wizard; first-run lands on the working app
**Files:** `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift` (launch logic ~lines
308–426, `canAutoPresentOnboardingOnLaunch` ~10348), `Sources/OuroWorkbenchCore/Onboarding.swift`
(`OnboardingPresentationPolicy` ~473).

- The wizard must **not** auto-present on launch — neither for `!onboardingHasBeenCompleted`
  nor for the `force-first-run-setup` marker. The app opens to the main window
  (`AgentHomeEmptyState`).
- Keep `model.presentOnboarding()` (the opt-in entry) fully working.
- The `force-first-run-setup` marker still resets state to a clean first-run; it just
  no longer triggers the modal. (`isFirstRunSetupForcedOnLaunch` may still drive any
  state-clearing, but must not set `isOnboardingPresented = true`.)
- Don't break already-onboarded users: they also just land on their normal UI (the
  wizard simply never forces). Mark `onboardingHasBeenCompleted = true` on first
  successful launch so any downstream `onboardingHasBeenCompleted` checks read as
  "ready to use" — **verify** no feature is gated on the wizard having run (the code
  map says terminal creation is not; confirm nothing else is before relying on this).

**TDD:** Add a pure policy seam, e.g. `OnboardingPresentationPolicy.shouldAutoPresentOnLaunch(...)`,
and a Core test asserting it returns `false` for the first-run case (fresh + forced).
Wire `canAutoPresentOnboardingOnLaunch` to it.

**Acceptance:** Launch with the `force-first-run-setup` marker → main window with the
empty state renders; **no** wizard sheet. ⌘N still opens a terminal.

### Unit 2 — Reframe `AgentHomeEmptyState` terminals-first
**File:** `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift` (~2499–2588).

Current copy leads boss-first ("Set up Workbench / Choose a boss agent, scan this
Mac…") with "New Terminal" buried as the third button. Reframe:

- **Headline:** `Your terminals. An agent runs them.`
- **Subtext:** `Your terminal agents stay real terminals — open one and go. When you
  want a boss watching the whole Mac and keeping work moving, set one up. No setup
  required to start.`
- **Button hierarchy** (left→right or by prominence):
  1. **`New Terminal`** — `.borderedProminent`, primary. Action unchanged
     (`model.isNewSessionSheetPresented = true`).
  2. **`Set up a boss`** — `.bordered`. Action `model.presentOnboarding()` (the opt-in
     wizard; same call the old "Set Up Workbench" button used).
  3. **`Hatch an Agent`** — keep, lower visual weight (`.bordered`, or fold into a
     secondary position). Action unchanged.
- Keep the "Installed agents" list as-is.
- Watch the SwiftUI layout notes already in this view (ScrollView clamp; don't
  introduce greedy `maxHeight:.infinity`).

**TDD:** copy is view-level; assert via a small testable surface if one exists, else
rely on strict build + visual drive. Keep the headline/subtext as named constants if
that eases a copy assertion.

**Acceptance:** Empty state leads with purpose + `New Terminal`; boss is a secondary
opt-in. Verified visually by driving.

### Unit 3 — Honest "ready" on the (now opt-in) Choose Boss page
**Files:** `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift` (`OnboardingBossChoice`
~3800–3846; `onboardingBossChoices` detail strings ~10409–10431).

At Choose Boss, an agent shows green **"ready"** + **"Ready to be your boss."** before
any connection check — then the very next page runs `ouro check` and can fail/spin.
That's the premature-truth the operator flagged. Make the Choose Boss claim reflect
what's actually known at that point (the bundle is **installed/enabled**), and let the
Connect step be where the connection is *earned*.

- `statusLabel` for `.ready` → `"installed"` (badge stays green; it's a real, true state).
- detail for `.ready` → `"Installed on this Mac. We'll check its connection next."`
- Leave `.disabled` / `.missingConfig` / `.invalidConfig` copy as-is.
- Do **not** touch `OuroAgentBundleStatus` enum or the empty-state "Installed agents"
  dot — only the onboarding-choice copy.

**TDD:** `OnboardingBossChoice` copy is pure — assert the new `statusLabel`/detail
strings for `.ready` in `OnboardingTests`.

**Acceptance:** Choose Boss no longer claims connection-readiness before the check.

## Plan continues — sequenced, nothing deferred
Operating rule (operator): **nothing is "out of scope" — to defer is to decide it
won't be built.** Everything found goes IN the plan, sequenced. Units 1–3 are done +
driven-verified; the rest come next in priority order, each built + driven the same way.

### Unit 4 — New Terminal = instant utility (highest "feel ease fast" lever) ✅
The empty-state PRIMARY action "New Terminal" opens a creation sheet whose **Create /
Create & Launch are disabled on an empty form** (confirmed live; stayed disabled with a
Name set via AX — diagnose whether a Command is required or it's a SwiftUI-binding quirk
when implementing). The first thing a new user clicks should get them a working shell
with minimal/zero required input: default the name, allow blank → the login shell, or a
one-click launch straight from the empty state. Find the Create `.disabled(...)` condition
+ the `isNewSessionSheetPresented` sheet; make the happy path instant. Drive-verify a
terminal actually opens and is usable.

### Unit 5 — Calm the first-run header ✅
On a brand-new first-run (no boss yet) the header shows `Boss: missing` (red) + a red
`TTFA · blocked` pill — alarm before the user has chosen to set up a boss. `TTFA · blocked`
is *honest* (no autonomy without a boss) but loud + premature here. Soften/neutralize
pre-boss (calmer "no boss yet"; a quieter TTFA state until a boss exists) without lying
about autonomy once a boss IS set.

### Unit 6 — Opt-in wizard polish (off the critical path now, still real)
The boss-setup wizard is opt-in now, so its friction no longer blocks first-run — but it
must still be smooth + honest when chosen: the Connect page `ouro check` spinner/failure
UX (the original "spins for minutes" complaint), end-to-end. Lower priority than U4/U5
precisely because it's opt-in, but IN the plan.

(Further friction found while driving lands here as more units — sequenced, never dropped.)

## Build / test / verify
- Strict build: `Scripts/package-app.sh` (release, `-warnings-as-errors
  -strict-concurrency=complete`). Core tests: `swift test` (Core suite must stay green).
- TDD per unit (red → green), commit after each unit.
- After all units: install (`Scripts/install-app.sh`), reset to pristine (per
  `fre-delight-doing.md`), relaunch, and **drive-verify**: first-run shows the
  terminals-first empty state with no forced wizard; ⌘N opens a terminal; "Set up a
  boss" opens the (now opt-in) wizard; Choose Boss reads honestly.
- No AI attribution, no Co-Authored-By in any commit / PR / doc.

## Progress log
- (start) doing doc authored on `feat/fre-delight` after full onboarding code map.
- Unit 1 complete (commit a26e999): added pure Core seam
  `OnboardingPresentationPolicy.shouldAutoPresentOnLaunch` (always false) + 4 Core tests
  (fresh, forced, completed, forced+completed — all assert false); wired
  `canAutoPresentOnboardingOnLaunch` to it; updated the launch-`.task` else-branch comment.
  Gating audit: NO user-facing feature is gated on `onboardingHasBeenCompleted` — the only
  reads are the auto-present gate, the wizard Done/Cancel label, and the mid-wizard rollback
  guard. Deliberately did NOT blanket-mark the flag at first launch (the doc's "mark true"
  instruction was premised on downstream gating that the audit proves doesn't exist; marking
  true would defeat `rollbackOnboardingIfIncomplete` for the opt-in wizard). Strict build clean;
  full Core suite green (1475 passed, 1 pre-existing skip).
- Unit 2 complete (commit e1fe12f): extracted empty-state copy into Core
  `AgentHomeEmptyStateCopy` (headline / subtext / button titles) + a Core test pinning the exact
  strings; reframed `AgentHomeEmptyState` — `New Terminal` is now `.borderedProminent` and leads,
  `Set up a boss` (`.bordered`, → `presentOnboarding()`) is second, `Hatch an Agent` last;
  ScrollView clamp + "Installed agents" list untouched. Updated the pre-existing
  source-introspection test `WorkbenchSurfacePolicyTests` (it encoded the OLD boss-first ordering,
  the exact contract this unit inverts) to assert the new hierarchy. Strict build clean; full Core
  suite green (1478 passed, 1 skip); Core 100% line+region coverage gate PASSES (both new Core
  files at 100%).
- Unit 3 complete (commit 630f599): extracted the Choose Boss per-status copy into a pure Core
  helper `OnboardingBossChoiceCopy` (statusLabel + detail keyed on `OuroAgentBundleStatus`) + a
  Core test pinning the new `.ready` strings and the unchanged others. `.ready` statusLabel →
  "installed", detail → "Installed on this Mac. We'll check its connection next." Both App sites
  (`OnboardingBossChoice.statusLabel`, `onboardingBossChoices`) now delegate to the seam; the
  `OuroAgentBundleStatus` enum and empty-state "Installed agents" dot are untouched. Strict build
  clean; full Core suite green (1482 passed, 1 skip); Core coverage gate PASSES.
- All three units complete. Remaining: install + visual drive-verify + push (operator-owned).
- (driven verification) Units 1–3 confirmed by driving the installed build (AX tree available on
  the fresh build, so real element-clicks): first-run shows ONE window, NO forced wizard (U1);
  empty state reads "Your terminals. An agent runs them." with New Terminal as the prominent
  primary + "Set up a boss" opt-in (U2); the opt-in wizard's Choose Boss reads "installed" /
  "Installed on this Mac. We'll check its connection next." (U3). New friction found while driving:
  New Terminal opens a creation sheet with Create/Create&Launch disabled on an empty form → Unit 4.
  "Out of scope" section replaced with a sequenced backlog (U4 New Terminal instant, U5 calm header,
  U6 opt-in wizard polish) per operator: nothing deferred.
- Unit 4 complete (3 vertical slices, TDD per slice, strict build + Core suite + coverage gate green
  after each). Root cause confirmed exactly as diagnosed.
  - Slice 1 (commit 381eacc) — Core: `CustomTerminalSessionFactory.makeEntry` no longer throws
    `emptyCommand` (or `emptyName`) for a blank draft. Empty command → bare login shell
    (`executable "/bin/zsh"`, `arguments ["-l"]`, `agentKind nil`, summary "Terminal session: login
    shell") — the same shape `WorkbenchScenarioMatrix`'s `user_shell` already uses (proven-healthy:
    `canonicalTokens`/`detect` leave it alone, `ExecutableHealthTarget` resolves a real `/bin/zsh`).
    Empty name → default "Terminal" (`defaultBlankSessionName`). `emptyWorkingDirectory` guard kept.
    `draft(from:)` round-trips a `/bin/zsh -l` entry back to an empty-command draft. Replaced the old
    `emptyCommand` expectation in `testCustomSessionRequiresNameCommandAndWorkingDirectory` (now
    `…RequiresOnlyWorkingDirectory`) with the new blank-allowed semantics + 4 new cases (blank→login
    shell w/ default name; blank keeps provided name; blank preserves notes; login-shell→empty-command
    round-trip). Core coverage 100% (88/90 at 100%, 2 pre-existing allowlisted).
  - Slice 2 (commit a85d3d4) — App: added `WorkbenchViewModel.createBlankTerminal()` (blank draft,
    working dir = `selectedProject?.rootPath ?? home`, the SAME default `NewTerminalSessionSheet` uses;
    calls existing `createCustomSession(draft, launchAfterCreate: true)`). Wired the empty-state PRIMARY
    "New Terminal" button to call it — instant, no sheet. Sidebar New Terminal / ⌘N still open the sheet.
  - Slice 3 (commit 25cf8b5) — App: relaxed `NewTerminalSessionSheet.canCreate` to require only a
    non-empty working directory (command + name optional; the factory defaults both). Create & Launch is
    enabled on an empty form → launches a blank login shell instead of being a dead-end. The
    `onChange(of: command)` detected-agent auto-name behavior is untouched (typed-command path intact).
  - Verify: `swift build -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete` clean after
    each slice; full Core suite green (1486 passed, 1 pre-existing skip — 4 net-new tests); coverage gate
    PASSES. Drive-verify of a real launched terminal is operator-owned (install path).
- Unit 5 complete (3 vertical slices, TDD per slice; strict build + full Core suite + coverage gate green
  after each). Root cause: the header conflated two distinct states — "no boss chosen yet" (empty
  `agentName`, EXPECTED on first run) was rendered with the SAME loud red `Boss: missing` + red
  `TTFA · blocked` as a genuinely broken boss.
  - Slice 1 (commit 18f8a2c) — Core: new pure, framework-free seam `HeaderCalmPresentation.resolve(
    bossAgentName:bossAgentStatus:autonomyState:installedBossHelp:)` → a `Presentation` (boss label text,
    `BossDotColor`, missing-pill flag, boss help, TTFA text, `TtfaPillStyle`, TTFA help). Empty/whitespace
    name → calm ("No boss yet", `.neutral` dot, no missing pill, calm help, "TTFA · off" neutral); named +
    nil status → loud red "missing" + real TTFA; named + installed → today's per-status colors (ready=green,
    disabled/missingConfig=orange, invalidConfig=red) + real TTFA. 8 new Core tests covering every branch;
    Core 100% line+region coverage held.
  - Slice 2 (commit 19668cd) — App: `BossSelectorView` now derives a single `presentation` from the seam;
    `bossHealthColor`/`bossHealthHelp` and the label HStack read off it; removed the old `bossIsMissing`
    (its `bossAgent == nil` definition fired on the empty case, the exact bug). `BossDotColor.swiftUIColor`
    maps `.neutral → .secondary`. First-run boss reads "No boss yet" w/ a neutral dot and no red pill;
    named-but-missing stays loud red "missing".
  - Slice 3 (commit ea17267) — App: `AutonomyStatusButton` (the TTFA header pill) derives the same seam,
    fed the SNAPSHOT's state (the value actually rendered, incl. the appended login-item check) so the
    loud boss-is-set path is byte-identical to before. No boss yet → "TTFA · off" in a neutral gray pill
    with calm help ("Set up a boss to enable hands-off operation."); click→readiness-checklist affordance
    kept; the popover (`snapshot.headline`/`detail`) is untouched. The `AutonomyReadinessState` enum and the
    readiness-checklist computation are NOT changed (view-level override only, per the unit's lowest-risk
    instruction).
  - Scope note: a SECOND surface — the NSStatusItem **menu-bar (tray) menu** (~line 651) — independently
    renders `Boss: <name>` + `TTFA · <state> — <headline>` and would also read alarmingly on first run. It
    is NOT the shared header pill (a distinct NSMenuItem rendering), so per the unit's "header-only, stop if
    shared with a non-header surface" guard it was left untouched; the new Core seam is reusable there if the
    operator wants the tray calmed too (separate decision).
  - Verify: strict build clean after each slice; full Core suite green (1494 passed, 1 pre-existing skip —
    8 net-new tests); coverage gate PASSES. Drive-verify of the calm first-run header is operator-owned
    (install path).
