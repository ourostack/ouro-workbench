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
- Implementation: Unit 2 complete; Unit 2 cold review pending; starting Unit 3a
- Live validation: pending

Next action: dispatch Unit 2 cold review, then write Unit 3a failing surface policy tests.
