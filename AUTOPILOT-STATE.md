# Autopilot State

Objective: Create a comprehensive Ouro Workbench surface/behavior spec, audit
the whole system against it, produce a work-suite implementation plan, implement
the plan, and validate live end-to-end against the spec without returning
control.

Current branch: `worker/factory-reset-setup-flow`

Canonical docs:

- Spec: `docs/workbench-surface-spec.md`
- Planning: `worker/tasks/2026-06-14-1420-planning-factory-reset-setup-flow.md`
- Audit report: `worker/tasks/audit-report.md`
- Audit backlog: `worker/tasks/audit-backlog.md`
- Doing: `worker/tasks/2026-06-14-1420-doing-factory-reset-setup-flow.md`

Gate state:

- Spec: written and committed
- Audit: written and committed
- Planning review: converged and approved
- Doing review: converged; doing doc ready
- Implementation: Unit 5e complete; Unit 4 cold-review findings fixed
- Live validation: Unit 6e complete; starting Unit 6f

Next action: create and run isolated import scanner E2E script for Unit 6f.
