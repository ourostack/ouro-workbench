# Anneal energy-0 sweep — ROUND 2 (next tier of ANNEAL-covered views)

Branch: chore/anneal-energy0-sweep-r2 (off origin/main 01919e8)
Method: single-actor SERIAL mutation sweep (mutate guard → swift test --filter → observe RED/GREEN → git checkout -- revert).
Baseline suite: GREEN (3404 tests, 1 pre-existing env-gated skip).

## Energy measure (P2): uncaught reachable behavioral guards whose mutation leaves the suite GREEN.

## ENERGY BEFORE (round-2 tier) = 8 uncaught guards

| # | View | Guard | Line | Mutation | Result |
|---|------|-------|------|----------|--------|
| 1 | TerminalAgentRow | `if isPinned` (pin glyph) | 3756 | `if false` | GREEN = energy |
| 2 | TerminalAgentRow | `if let cliName` (cli text) | 3776 | suppress body | GREEN = energy |
| 3 | TerminalAgentRow | `entry.owner.sidebarBadge` (owner badge + a11y) | 3762 | suppress body | GREEN = energy |
| 4 | TerminalAgentRow | `health.status != .available` (warn icon + a11y) | 3797 | suppress body | GREEN = energy |
| 5 | AutonomyStatusPopover | `bossWorkbenchMCPRegistration?.isActionable==true` (Connect Tools) | 4763 | suppress | GREEN = energy |
| 6 | WorkbenchVisibilityStrip | inbox-tap `(openInbox>0)?onOpenInbox:nil` (door wiring) | 5757 | invert ternary | GREEN = energy |
| 7 | TerminalRowContextMenu | Stop button (active-session arm) | 3624 | mutate "Stop" label | GREEN = energy |
| 8 | TerminalRowContextMenu | "Restart" arm of Launch/Restart ternary | 3619 | mutate "Restart" | GREEN = energy |

## CLASSIFIED NON-ENERGY (recorded, NOT churned)
- TerminalAgentRow archived rowIcon (3810) — CAUGHT by RecoverySurfaceStateSetTests.testD_sidebarArchived (mutation → RED).
- BossProposalItemRow cwd-editable arm (7594) — CAUGHT by F.fields.allEditable (mutation → RED).
- MarkdownMessageView heading-level font (6769) / bullet-indent padding (6748) — NODELESS (font/geometry, serializer whitelist excludes).
- MarkdownMessageView `.blank` → Color.clear (6736) — NODELESS (no content node).
- DecisionInboxSheet showFullLog / BossActionReceiptStrip isExpanded / BossDashboardView showsAdvanced — `@State private` no init seam = structurally unreachable in tests.
- All color/foregroundStyle/background/disabled/keyboard/role conditionals — NODELESS.
- OnboardingReadinessView AN-006 dead branch — recorded unreachable.
- All other swept views — PINNED.

## Closes (TDD: RED-under-mutation → GREEN-reverted, one commit per close)
- AN-R2-01: TerminalAgentRow fully-decorated row (isPinned + cliName + owner badge + health) — 4 guards.
- AN-R2-02: AutonomyStatusPopover MCP-actionable Connect button.
- AN-R2-03: WorkbenchVisibilityStrip live inbox door.
- AN-R2-04: TerminalRowContextMenu active-session arms (Stop + Restart).

## ENERGY AFTER target = 0 for round-2 tier.

## CLOSES LANDED (each: RED-under-mutation -> GREEN-reverted, one commit)
- AN-R2-01 (TerminalAgentRowDecoratedLeafTests + TerminalAgentRow.decorated.txt): isPinned + cliName + owner-badge + health (4 guards).
- AN-R2-02 (AutonomyStatusPopoverStandaloneTests + AutonomyStatusPopover.mcpActionable.txt): MCP-actionable Connect button (1).
- AN-R2-03 (DashboardStripStateSetTests + WorkbenchVisibilityStrip.inboxDoorLive.txt): live inbox door (1).
- AN-R2-04 (TerminalRowContextMenuStandaloneTests + TerminalRowContextMenu.activeSession.txt): active-session Stop + Restart (2).

## ENERGY AFTER (round-2 tier) = 0 (8 closed; re-verify each mutation now CAUGHT below).
## Round 3 warranted? YES — energy found (8) -> the loop continues; a round-3 sweep over the NEXT tier (e.g. the menu/sheet/onboarding views not in this scope) may surface more.
