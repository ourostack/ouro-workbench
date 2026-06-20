# Health-probe audit (Unit 8d)

**Question**: Can the boss confirm a resumed session came up healthy using the
existing MCP surfaces, or is a Core helper needed?

## Existing surfaces (verified at HEAD)

- `workbench_sessions` (`WorkbenchSessionsRenderer.snapshots`) — JSON per session
  with `status` (latest run's `ProcessStatus`), `attention`, `needsHuman`, `pid`,
  `exitCode`, `startedAt`, `lastOutputAt`.
- `workbench_transcript_tail` (`TranscriptTailReader`) — bounded tail text of the
  latest transcript.
- `AttentionSignalDetector.classify(tail:)` (Core) — already strips ANSI and
  classifies a tail into `.waitingOnHuman` / `.blocked` / `.unknown`.

## Finding: a small gap

The raw materials are all present, but the boss had to **interpret** them itself
— combine run status + exit code + tail signal + how long since start / since
output into a single "is it healthy" judgement, ad hoc, every time. That
interpretation is exactly the kind of general, deterministic logic that belongs
in Core (where it's testable and pinned), per the dispatch's "Core-shaped logic
goes to Core with 100% coverage" rule. So the gap was resolved with a helper
rather than left as an audit-only no-op.

## Resolution: `SessionHealthProbe` (Core) + `workbench_session_health` (MCP)

- **Core** `Sources/OuroWorkbenchCore/SessionHealthProbe.swift` — pure
  `classify(runStatus:tail:elapsedSinceStart:elapsedSinceOutput:exitCode:…)` plus
  a `classify(snapshot:tail:now:)` convenience over a `SessionSnapshot`. Reuses
  `AttentionSignalDetector` for the tail reading so the verdict agrees with the
  rest of the workbench. Verdict `SessionHealth`:
  - `healthy` — fresh output, OR sitting at a prompt waiting on the human
    (`.waitingForInput` / a prompt in the tail), OR exited code 0.
  - `starting` — no output yet and within the startup grace (default 20s), OR no
    run status yet.
  - `stalled` — running but output went quiet past the stalled threshold (default
    90s, matching `SessionChip.stalledThreshold`), OR nothing emitted past the
    grace. NOT a prompt-wait (that's healthy).
  - `failed` — exited non-zero (or with no code), needs recovery / manual action,
    or the tail ended on a terminal error (`AttentionSignalDetector .blocked`).
  - 100% line+region covered (24 tests, incl. boundary cases at both thresholds).
  - GENERAL — zero harness/agency knowledge.
- **MCP** `workbench_session_health` — resolves the target session, reads its
  snapshot + transcript tail, runs the probe, returns
  `{name, health, status, needsHuman}`. Built clean under
  `-warnings-as-errors -strict-concurrency=complete`; end-to-end verified against
  the built binary (a running-with-fresh-output session → `healthy`; a
  running-but-quiet session → `stalled`).
