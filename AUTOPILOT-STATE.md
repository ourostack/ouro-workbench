# Autopilot State

Objective: Re-center Ouro Workbench around boss-owned terminal/TUI
multiplexing by removing the remaining built-in `Local Shell` default lifecycle
from bootstrap, startup, MCP truth, tests, scenarios, current docs, and live
validation while preserving user-owned shell sessions.

Current branch: `worker/product-center-of-gravity`

Canonical docs:

- Spec: `docs/workbench-surface-spec.md`
- Ideation: `worker/tasks/2026-06-14-1939-ideation-product-center-of-gravity.md`
- Audit report: `worker/tasks/audit-report.md`
- Audit backlog: `worker/tasks/audit-backlog.md`
- Planning: `worker/tasks/2026-06-14-1947-planning-product-center-of-gravity.md`
- Doing: `worker/tasks/2026-06-14-1947-doing-product-center-of-gravity.md`
- Artifacts: `worker/tasks/2026-06-14-1947-doing-product-center-of-gravity/`

Gate state:

- Work Ideator: completed; Tinfoil Hat and Stranger With Candy findings folded
  into the handoff.
- Full-system audit addendum: completed; A-011 through A-014 routed.
- Planning review: converged and approved.
- Doing doc: drafted; conversion review passes in progress.

Next action: complete doing-doc conversion review chain, mark doing
`READY_FOR_EXECUTION`, then execute units directly with strict TDD and live E2E.
