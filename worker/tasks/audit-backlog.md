# Workbench Surface Spec Audit Backlog

Status: routed
Date: 2026-06-14
Canonical report: `worker/tasks/audit-report.md`

## A-001 - Factory reset does not force setup

**Source**: audit
**What**: Factory reset removes data but does not persist an explicit next-launch setup requirement.
**Why it matters**: A healthy existing boss can make `shouldPresentOnboardingOnLaunch` return false, contradicting the reset dialog and leaving the user outside setup.
**Evidence**: `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift:9228`, `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift:9668`, `Sources/OuroWorkbenchCore/WorkbenchFactoryReset.swift:21`
**Severity**: critical
**Blast radius**: affects multiple modules
**Dependencies**: none
**Recommended lane**: planner-required
**Suggested supporting skills**: work-planner, work-doer
**Verification**: Add unit coverage for marker set/consume behavior and run a live reset/relaunch smoke that proves onboarding appears even when boss readiness is healthy.
**Status**: in-progress
**Linked work**: `worker/tasks/2026-06-14-1420-planning-factory-reset-setup-flow.md`
**Notes**: Marker must survive `removePersistentDomain`; either set it after wipe or use a domain/key not removed by reset.

---

## A-002 - Bootstrap recreates the confusing shell-only first-run state

**Source**: audit
**What**: Empty state bootstraps a `This Mac` project and inserts an auto-launchable `Local Shell`.
**Why it matters**: After reset, the user lands in a shell-only workbench instead of agent setup/import, matching the reported screenshot.
**Evidence**: `Sources/OuroWorkbenchCore/WorkbenchBootstrapper.swift:3`, `Sources/OuroWorkbenchCore/WorkbenchBootstrapper.swift:52`, `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift:13890`
**Severity**: critical
**Blast radius**: affects multiple modules
**Dependencies**: A-001
**Recommended lane**: planner-required
**Suggested supporting skills**: work-planner, work-doer
**Verification**: Add bootstrap tests for setup mode with `includeLocalShell: false`; add startup logic coverage or a live smoke proving no auto-launched shell appears before setup/import.
**Status**: in-progress
**Linked work**: `worker/tasks/2026-06-14-1420-planning-factory-reset-setup-flow.md`
**Notes**: Preserve ordinary fallback-shell behavior only if tests prove it does not affect reset/setup mode.

---

## A-003 - Built-in fallback sessions are undeletable dead ends

**Source**: audit
**What**: The row context menu exposes edit/archive/delete only for custom sessions.
**Why it matters**: If Workbench creates a fallback shell, the user cannot remove it through normal UI, making the app feel trapped.
**Evidence**: `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift:2941`, `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift:2995`, `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift:3033`
**Severity**: high
**Blast radius**: affects one module
**Dependencies**: A-002
**Recommended lane**: planner-required
**Suggested supporting skills**: work-doer
**Verification**: Unit-test the removability helper if extracted; otherwise live-validate that fallback shell is absent during setup and removable after manual creation/fallback.
**Status**: in-progress
**Linked work**: `worker/tasks/2026-06-14-1420-planning-factory-reset-setup-flow.md`
**Notes**: The best first fix may be hiding/defering the shell in setup mode rather than broadening delete behavior for all built-ins.

---

## A-004 - Low-level terminal controls are primary chrome

**Source**: audit
**What**: Running session headers show focus, redraw, Ctrl-C, Esc, EOF, and stop as an unlabeled primary icon strip.
**Why it matters**: These are terminal-driver details, not product concepts; the screenshot shows they make first use feel complicated.
**Evidence**: `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift:7320`, `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift:7835`, `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift:7935`
**Severity**: high
**Blast radius**: affects one module
**Dependencies**: none
**Recommended lane**: planner-required
**Suggested supporting skills**: frontend-design, work-doer
**Verification**: Build/run UI, inspect running session header at desktop/mobile-ish widths, and confirm advanced controls are behind a labeled menu with tooltips.
**Status**: in-progress
**Linked work**: `worker/tasks/2026-06-14-1420-planning-factory-reset-setup-flow.md`
**Notes**: Keep keyboard shortcuts and boss actions; change primary discoverability.

---

## A-005 - Primary IA still says Agents, Groups, This Mac, Terminals, Recovery

**Source**: audit
**What**: Sidebar top-level sections expose multiple competing concepts and old naming as normal chrome.
**Why it matters**: The user cannot form the simple model: Workspaces contain sessions, with one boss agent coordinating them.
**Evidence**: `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift:2611`, `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift:2632`, `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift:2711`, `docs/workbench-surface-spec.md:275`
**Severity**: high
**Blast radius**: affects one module
**Dependencies**: A-001, A-002
**Recommended lane**: planner-required
**Suggested supporting skills**: frontend-design, work-doer
**Verification**: Live UI should show `Workspaces`, not `Groups`, should not show `This Mac` as an imported workspace after reset, and should hide recovery when healthy.
**Status**: in-progress
**Linked work**: `worker/tasks/2026-06-14-1420-planning-factory-reset-setup-flow.md`
**Notes**: Full model rename can be staged; primary UI text should change in this pass.

---

## A-006 - Onboarding/import is app-led string routing, not boss-led setup

**Source**: audit
**What**: Onboarding routes typed commands through keyword matching and presents a static import proposal.
**Why it matters**: The spec requires a narrow wizard only for boss setup, then a boss-led welcome, scan, ambiguity questions, proposal, and duplicate cleanup guidance.
**Evidence**: `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift:12519`, `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift:12563`, `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift:12615`
**Severity**: high
**Blast radius**: affects multiple modules
**Dependencies**: A-001
**Recommended lane**: planner-required
**Suggested supporting skills**: work-planner, work-doer
**Verification**: Live onboarding after boss readiness should present boss-narrated welcome/import steps and proposal support without making import a separate traditional wizard.
**Status**: in-progress
**Linked work**: `worker/tasks/2026-06-14-1420-planning-factory-reset-setup-flow.md`
**Notes**: Reuse existing scanner/proposal data; do not build a new dashboard.

---

## A-007 - Import scanner misses known Codex and Claude stores

**Source**: audit
**What**: Scanner omits Codex archived/manual-recovery JSONL and Claude task records, and can skip session index when SQLite has candidates.
**Why it matters**: Setup cannot credibly ask to import local coding-agent sessions if it ignores common recent stores on this machine.
**Evidence**: `Sources/OuroWorkbenchCore/Onboarding.swift:530`, `Sources/OuroWorkbenchCore/Onboarding.swift:696`, `Sources/OuroWorkbenchCore/Onboarding.swift:728`
**Severity**: high
**Blast radius**: affects one module
**Dependencies**: none
**Recommended lane**: planner-required
**Suggested supporting skills**: work-doer
**Verification**: Add representative fixture tests for Codex archived JSONL, Codex manual-recovery JSONL, Claude task records, and SQLite-plus-index union behavior.
**Status**: in-progress
**Linked work**: `worker/tasks/2026-06-14-1420-planning-factory-reset-setup-flow.md`
**Notes**: Preserve lookback filtering for signal quality unless future UX adds an older-sessions path.

---

## A-008 - `OuroWorkbenchApp.swift` is a god file

**Source**: audit
**What**: One app file contains root view, sidebar, sheets, dashboard, onboarding, terminal UI, focus mode, menu wiring, and view model.
**Why it matters**: Mixed responsibilities make product-surface changes harder to review and increase regression risk.
**Evidence**: `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift` is 16770 lines; next largest app/core implementation file is far smaller.
**Severity**: medium
**Blast radius**: affects multiple modules
**Dependencies**: A-001, A-002, A-004, A-006
**Recommended lane**: inch-worm-ready-after-reeval
**Suggested supporting skills**: inch-worm
**Verification**: Re-evaluate after the first-run pass; extract only stable, cohesive chunks with tests or screenshot verification.
**Status**: deferred
**Linked work**:
**Notes**: Deferred intentionally to avoid mixing architecture churn into the user-blocking reset/setup fix.

---

## A-009 - Current docs and scenario wording encode the old product

**Source**: audit
**What**: Docs and verifier labels still describe command-center/dashboard/group-first Workbench.
**Why it matters**: Future contributors will keep reintroducing the old story unless docs converge after behavior lands.
**Evidence**: `docs/product-tour.md:3`, `docs/product-tour.md:29`, `docs/product-tour.md:34`, `docs/surface-audit.md:7`, `Sources/OuroWorkbenchScenarioVerifier/main.swift:775`
**Severity**: medium
**Blast radius**: affects multiple modules
**Dependencies**: A-001, A-004, A-005, A-006
**Recommended lane**: inch-worm-ready-after-reeval
**Suggested supporting skills**: inch-worm
**Verification**: After implementation, update product tour, guide, architecture, and scenario labels to match live behavior and rerun scenario verifier.
**Status**: deferred
**Linked work**:
**Notes**: Deferred until live UI behavior is validated, so docs describe reality rather than intent.

---

## A-010 - MCP/action names still expose old organization language

**Source**: audit
**What**: Boss-control docs and likely MCP action schemas use `Group` language for workspace organization.
**Why it matters**: Boss-facing contracts can preserve old mental models even after UI text changes.
**Evidence**: `docs/product-tour.md:53`, `docs/product-tour.md:55`, `Sources/OuroWorkbenchMCP/main.swift`, `Sources/OuroWorkbenchCore/WorkbenchCommandPalette.swift:57`
**Severity**: medium
**Blast radius**: crosses trust boundaries
**Dependencies**: A-005
**Recommended lane**: inch-worm-ready-after-reeval
**Suggested supporting skills**: inch-worm
**Verification**: Re-audit MCP tool schemas and action names after UI-level Workspaces rename; preserve backward-compatible aliases if public tools are already in use.
**Status**: deferred
**Linked work**:
**Notes**: Deferred because renaming MCP contracts is higher-risk than changing primary UI labels and should be designed with compatibility.

---

