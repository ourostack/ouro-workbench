# U2 Planning-Coverage Checklist

Every requirement from the campaign journal (`../2026-06-24-anneal-visual-testing.md`) + the U2 brief, mapped to a doing unit. ✅ = has a unit · ❌ = MISSING.

## Brief: U2 scope + decomposition
- ✅ TimelineView injectable-clock source touch (first product-source change; named prerequisite) — **SU0** (SU0a-d)
- ✅ Re-locate `:3775`/`:2166` in the NEW `WorkbenchViewsAndModel.swift` (were OLD-file refs) — done in Pre-execution facts (validated @ b588b78; both coincide) + SU0c targets them
- ✅ Make date injectable/deterministic in tests WITHOUT changing prod behavior (env-value/init-param defaulting to `.now` in prod, fixed in snapshots) — **D-U2-1** + **SU0a** (spike resolves env-vs-init-param) + **SU0c**
- ✅ Its own sub-PR with its own tests; gates sidebar (A) + inbox surfaces — **SU0** (own commit, SU0b tests) ; SU3 depends on SU0
- ✅ Surface F (④ proposal card) full enumerated state-set (list none/one/many; card 0/one/many; itemRow selected×editable/static/absent) — **SU2** (SU2a enumerates exactly this)
- ✅ Fold in AN-002 serializer hardening (extract bound value for TextField, not placeholder; de-dup findAll placeholder re-emission) — **SU1** (SU1a-c) ; ④ editable fields are where it matters → SU1 gates SU2
- ✅ Surfaces A (sidebar rows) + B (tab-strip) full state-sets per §Surfaces — **SU3** (A) + **SU4** (B)
- ✅ A depends on the TimelineView touch (sidebar embeds ElapsedTimePill) — **SU3 DEPENDS ON SU0** (stated in dep graph + SU3 header)
- ✅ `.accessibilityIdentifier` strategy (resolve fork F1): selective, NOT broad 121-view rollout; record decision + rationale — **D-U2-2 (F1 RESOLVED)** + per-surface audit in SU2c/SU3c/SU4c

## Brief: Coverage note (do NOT gate yet)
- ✅ Views lib NOT added to COVERAGE_DIRS until FINAL unit — **D-U2-5** + Completion Criteria + Code Coverage Requirements scope note
- ✅ U2 grows snapshot coverage; note running views-lib coverage % as surfaces land — captured per sub-unit: `views-coverage-after-SU0/2/3/4.txt` (SU0d, SU2c, SU3c, SU4c)

## Brief: Hard constraints
- ✅ Every fixture provenance-built via REAL seam (`AgentProposalQueue.enqueue`, `WorkbenchStore.save`→VM), NEVER hand-assembled (P2) — **D-U2-4** + each SUx (a) requires provenance-built fixtures
- ✅ Each surface ≥1 negative control (P2) — SU2b, SU3b, SU4b each add a negative control; SU1a is itself a negative control
- ✅ Determinism: fixed clock/locale/UUID; zero machine paths (P3) — Completion Criteria + each (b) phase: twice-run byte-identical + no `/Users/` scan
- ✅ Snapshots non-redundant (P4e) — Completion Criteria + SU2b/SU4b assert no two refs byte-identical (FP4 distinct empty-states in SU4)
- ✅ TimelineView touch must NOT change prod behavior (live app still ticks) — **SU0b** behavior tests + SU0c retains the periodic driver + SU0d reviewer negative-control ("does prod actually change?")
- ✅ Prove via `--uisurfacetest` + a behavior test — **SU0b** (behavior test) + SU0c/SU0d gate on `--uisurfacetest` green
- ✅ AN-001: inject temp `agentBundlesURL` in EVERY VM fixture — **D-U2-4** + Completion Criteria + Execution section ("AN-001 in EVERY VM fixture")
- ✅ Gate: strict build/test 0 warn/fail — Completion Criteria + each (c)/(d) phase
- ✅ Gate: `--uisurfacetest` green — Completion Criteria + SU0
- ✅ Gate: `check-coverage.sh` green (allowlist/COVERAGE_DIRS unchanged this unit) — Completion Criteria + D-U2-5
- ✅ One commit per sub-unit — Execution section + each (c)/(d) commit
- ✅ NO AI attribution — Completion Criteria + every commit instruction + Execution
- ✅ `SerpentGuide.ouro/` unstaged — Completion Criteria + Execution + SU0d ("stage NOTHING else")

## Brief: Git
- ✅ Branch `feat/anneal-u2-surface-snapshots` off origin/main @ 8e71619 — header (verified current branch + HEAD)
- ✅ Write doc under `worker/tasks/2026-06-24-anneal-visual-testing/` as `U2-surface-snapshots.md` + commit `docs(doing):` — done (this doc)
- ✅ No PR — Execution + header

## Campaign rubric (P1–P7) touchpoints for U2
- ✅ P2 (negative control + provenance) — per-surface negative controls + real-seam fixtures
- ✅ P3 (determinism) — fixed clock (SU0)/locale/UUID; no machine paths; twice-run
- ✅ P4a/b (structured, minimal-noise) — inherited from U1 serializer; AN-002 (SU1) improves fidelity
- ✅ P4c (complete enumerated state-set per surface) — SU2a/SU3a/SU4a enumerate the full §Surfaces sets
- ✅ P4d (committed + CI-diffed + artifact-on-failure) — inherited from U1 store; references committed per sub-unit
- ✅ P4e (non-redundant) — asserted in SU2b/SU4b
- ✅ P5 (≥2 adversarial reviewers, zero CRITICAL/HIGH) — SU0d (the product-source change) explicitly; the fresh review gate before READY covers the doc
- ✅ P6 (strict flags green, zero flakes) — gates on every sub-unit
- ⏸ P1 (coverage completeness) + P7 (grep-guard retirement) — DEFERRED to U4 by design (D-U2-5); U2 only GROWS coverage + records running % (not a gap — explicitly out of U2 scope per the brief)

## Brief: Return-to-operator items (must be answerable from the doc)
- ✅ Sub-unit decomposition + dependencies (esp. TimelineView gating sidebar) — dep graph + per-SU headers
- ✅ Re-located TimelineView sites + injectable-clock design (how prod preserved) — Pre-execution facts + D-U2-1 + SU0
- ✅ `.accessibilityIdentifier` decision — D-U2-2
- ✅ How AN-002 fixed in the serializer — D-U2-3 + SU1
- ✅ New fork worth surfacing — the THIRD clock leak (`TerminalAgentRow.accessibilityLabel:3718`) — Open Questions F-U2-CLOCK + Notes

## Result
**Full coverage confirmed.** No campaign/brief requirement is without a doing unit. The only items not given an EXECUTION unit (P1 coverage gating, P7 guard retirement) are EXPLICITLY deferred to U4 by the brief's own "do NOT gate yet" instruction — correctly recorded as out-of-U2-scope, not dropped.
