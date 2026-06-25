# SU-D0 spike verdict — recovery surface extraction (Q1 + Q2 + digest provenance)

Throwaway spike (`SUD0RecoverySpikeTests`, since DELETED). Run @ 2026-06-25 on
`feat/anneal-u3-onboarding-recovery`. **Verdict: GO** for SU-D — all three checks passed.

## (i) Digest provenance through the `WorkbenchStore.save` → fresh-VM `load()` seam — VERIFIED

A fixture with two `.shell` entries + two `ProcessRun`s (`processRuns:` on `WorkspaceState`),
saved then loaded by a fresh hermetic VM (AN-001 temp `agentBundlesURL`), produces the
intended digest buckets — the load path (bootstrap / migrate / reconcile) does NOT mutate a
`.needsRecovery` / `.manualActionNeeded` run out from under the pure `RecoveryPlanner`:

- An UNTRUSTED `.needsRecovery` entry → plan `.manualActionNeeded` with typed `blocker == .untrusted`
  → `recoveryDigest.needsYouCount == 1`.
- A TRUSTED + `autoResume` `.shell` `.needsRecovery` entry → plan `.respawn`
  ("trusted non-agent process may be respawned by policy", `RecoveryPlanner.swift:255-259`)
  → `recoveryDigest.autoRecoverableCount == 1`. (This is fact (4): the simplest reliably-buildable
  auto-recoverable; flipping its run status `.needsRecovery`↔`.manualActionNeeded` genuinely moves
  it between sections → the SU-D.b negative control is NON-vacuous.)
- Setting `model.liveScreenSessionNames = [PersistentTerminalSession.sessionName(for: entryId)]`
  on the trusted+autoResume entry → plan `.reattach` → `losslessReattachCount == 1`,
  `isLosslessReattach(for:) == true`. (The `.reattach` key is the DERIVED session name, fact (1).)

→ Every D digest bucket is reachable through the REAL seam. No C1-style impossibility.

## (ii) Q1 — `ContentUnavailableView` extraction — RESOLVED (system view extracts cleanly; NO fallback needed)

ViewInspector's `findAll` DOES descend the system
`ContentUnavailableView("Nothing to recover", systemImage: "checkmark.seal.fill", description:…)`
(`RecoverySheet` `:857`). The "nothing" tree extracts:

```
Text "Recovery"                       (the header)
Text "Nothing to recover"             (the digest sheetHeader subtitle)
Text "Done"                           (the Done button label)
Text "Nothing to recover"             (the ContentUnavailableView TITLE)
Image "checkmark.seal.fill"           (the ContentUnavailableView systemImage)
Text "No sessions are waiting on recovery. …"  (the ContentUnavailableView description)
```

So the "nothing" reference is MEANINGFUL on its own (CUV title + description + seal image +
the ABSENCE of any "Needs you"/"Ready to recover" section header). The Q1 reversible fallback
(assert only the header + section-absence) is NOT needed — recorded as a contingency only.

Provenance for "nothing": an empty `WorkspaceState` → `recoveryDigest.shouldShow == false`
→ the `if !shouldShow` branch (`:856`) renders the CUV.

## (iii) Q2 — `@Environment(\.dismiss)` + `.task` no-fire under `inspect()` — CONFIRMED

`ViewSnapshotHost.snapshotText(of: RecoverySheet(model:))` does NOT crash and produces a
deterministic tree. The `@Environment(\.dismiss)` (`:823`) defaults to a no-op when unhosted
(the synchronous `inspect()` path never invokes the dismiss closure); no `.task`/`.onAppear`
side-effect fires (strong U2 precedent — `BossProposalCardList` + `WorkbenchSidebarView` both
have `.task`). Confirmed empirically.

## Determinism observations (feed SU-D fixtures)

- `launchCommand(for:)` renders as the canonical fixture executable (`/bin/zsh`) — NO machine
  path / working directory in the rendered text (`WorkbenchCommandPlanner.displayCommand` is
  shell-quoted `[executable]+args`, no cwd). Use a canonical fixed executable.
- The `.help("Recovery detail: …")` tooltips (`:962`/`:1061`) are DROPPED by the host's AN-004
  `isHelpTooltip` — not in the tree. (They are the only path-bearing risk, and they're gone.)
- The trust-fix vs Start-fresh branch (`:974`): an UNTRUSTED `.needsRecovery` row → "Trust &
  resume" (blocker `.untrusted`); a directly-`.manualActionNeeded` run on a TRUSTED entry →
  `.manualActionNeeded` with NO blocker → `recoveryTrustFixAvailable == false` → "Start fresh".
  So the two boundaries are built by distinct entries in the same/different fixtures.
- The lossless-reattach pill (`:1040`) is ROW-level inside "Ready to recover": a `.reattach`
  row shows `Text("Reconnect — no loss")` + `link.circle.fill` (green); a `.respawn` row shows
  no pill + `arrow.clockwise` (orange). Both sit in the same section (fact (5)).

## Throwaway

`SUD0RecoverySpikeTests.swift` deleted after this verdict was recorded (per the spike discipline).
