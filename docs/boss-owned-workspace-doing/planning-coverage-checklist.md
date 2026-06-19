# Planning Coverage Checklist

Maps every planning-doc / spec requirement to a doing-doc unit. ✅ = covered, ❌ = gap.

## The 8 spec feature areas
1. ✅ General agent-session scanner (Core) — Units 0b/0c (record type), 2a–2d (Claude+Copilot recent), 3a–3f (running + matcher + unified scan).
2. ✅ MCP tool `workbench_discover_agent_sessions` — Units 4a (App lister), 4b (MCP wiring).
3. ✅ Propose-for-approval capability (NOT a gate) — Units 5a/5b (model), 5c/5d (queue), 5e (MCP tool), 5f (native card). "Capability never gate" stated in slice title + 5e description.
4. ✅ Onboarding hand-off (replace hardcoded import) — Units 7a/7b (flow policy `.bossReconstruct`), 7c (App import-step replacement).
5. ✅ Forward memory `{agent, command, cwd, harness, sessionId}` — Units 6a/6b (Core fields), 6c (record at create), 6d (native discovery).
6. ✅ Boss-forward UI + session STATUS list (running/waiting/done), terminals reachable — Units 8a/8b (Core classification), 8c (App surface, additive).
7. ✅ Health-probe — Unit 8d (audit reuse of transcript_tail/status; Core helper only if gap).
8. ✅ Missing control actions (archive / group-create) — Unit 0a (audit; grounding shows already present, so audit-only unless a real gap appears, which would append a unit to Slice 7).

## Planning "In Scope" items
- ✅ General scanner with general records `{harness, sessionId, cwd, repository, branch, title, lastActive, running}` — 0b defines the exact record; 2a–3f populate it.
- ✅ Flat-YAML reader, no SPM dep — Units 1a/1b.
- ✅ `workbench_discover_agent_sessions` — 4b.
- ✅ Propose capability + Core model + native card + result returns to boss — 5a–5f.
- ✅ Onboarding hand-off — 7a–7c.
- ✅ Forward memory — 6a–6d.
- ✅ Boss-forward UI + status list, terminals reachable — 8a–8c.
- ✅ Health-probe (reuse, helper only if needed) — 8d.
- ✅ Audit request_action; add archive/group-create only if absent — 0a.

## Planning "Out of Scope" (must NOT appear as work) — confirmed absent
- ✅ No agency/ms-desk/repo→agent/`agency --resume` command building — explicitly excluded in 0b, 2b ("do NOT build any resume command"), 3b ("zero agency knowledge"), 4b description.
- ✅ Existing `RecentSessionScanner` not modified/removed — stated in grounding + 7c ("do NOT delete `RecentSessionScanner`").
- ✅ Terminal UI not ripped out — 8c ("ADDITIVE — do not remove terminal UI").
- ✅ No new YAML SPM dependency — Units 1a/1b (custom reader); decision recorded.

## Resolved Open Questions requiring implementation
- ✅ Custom flat-YAML reader — 1a/1b.
- ✅ New scanner separate from `RecentSessionScanner` — new file `AgentSessionScanner.swift`, 0b onward.
- ✅ No new action kinds (audit only) — 0a.
- ✅ Forward memory as additive `ProcessEntry` fields stamped in `makeEntry` — 6a/6b/6c.
- ✅ Running detection via injected runner closure — 3c/3d (+ App lister 4a).

## Decisions Made requiring implementation reflection
- ✅ Autopilot = approval (process decision; reflected in Status fields).
- ✅ Clean sibling scanner — 0b/2/3 in new file.
- ✅ Custom flat-YAML — 1.
- ✅ Forward memory additive fields w/ decode-if-present — 6a/6b.
- ✅ Propose is a capability — 5 (slice title + 5e).
- ✅ Boss-forward additive UI — 8c.

## Coverage / quality requirements
- ✅ 100% line+region on new Core — every Core unit's Acceptance + Unit 9a gate.
- ✅ No new allowlist entries unless structural — Coverage Requirements section + 9a.
- ✅ Strict-concurrency + warnings-as-errors for App/MCP — 4a/4b/5e/5f/6c/7c/8c acceptance + 9a.
- ✅ All tests pass / no warnings / no AI attribution — 9a (incl. attribution grep).
- ✅ FS-injection seam (`homeURL`) + runner-injection — Coverage Requirements + 2/3 units.
- ✅ Branch discipline (stay on `fix/onboarding-audit`) — header + Execution section.

## Result
**Full coverage confirmed. No gaps (❌) found.** Every planning/spec requirement maps to at least one unit, and every Out-of-Scope guardrail is explicitly encoded in a unit description.

## Slice 9 final verification (post-build)
Re-checked at feature completion against landed, COMMITTED code (not just unit descriptions):
- Each of the 8 areas above has a tracked source artifact + (where applicable) a wired MCP tool — all 4 feature tools present in `OuroWorkbenchMCPMain.swift`.
- The `see → propose → act` loop COMPOSES end-to-end — proven by `integration-smoke.py` against the real release MCP binary (discover → propose → result round-trip with operator edit → session_health).
- Gates green: coverage 86/88 100% line+region (allowlist UNCHANGED), clean release strict build, 1427 tests / 1 pre-existing skip / 0 failures, zero AI attribution.
- **Every area remains ✅. Zero gaps.**
