# Ouro Workbench Docs Index

This index separates current source-of-truth docs from historical planning and
audit artifacts. Prefer the normative section first when onboarding an agent or
auditing Workbench behavior.

## Normative Docs

- [Architecture](architecture.md): runtime layers, persistence contract, shared
  shell boundary, and repository ownership.
- [Guide](guide.md): operator mental model, daily control loops, boss/Ouro
  integration, restart recovery, and troubleshooting.
- [Ouro Bridge](ouro-bridge.md): current bridge contract between Workbench and
  Ouro agents.
- [Native Packaging](native-packaging.md): package/install/release bundle shape.
- [Recovery](recovery.md): restart-recovery contract and recovery playbook.
- [Preference-Driven Inbox](preference-driven-inbox.md): preference-backed
  waiting-on-human inbox behavior.
- [Surface Spec](workbench-surface-spec.md): Workbench UI/product surface
  contract.

## Product And Planning Roadmap

- [Product Tour](product-tour.md): product/investor tour and screenshot evidence
  workflow.
- [Roadmap](roadmap.md): forward-looking product roadmap.
- [FRE Functional Backlog](fre-functional-backlog.md): functional audit backlog.
- [FRE UX Backlog](fre-ux-backlog.md): UX audit backlog. Treat completed or
  superseded rows as historical unless a current task cites them.

## Validation And Control Decks

- [cmux Workbench Test Matrix](cmux-workbench-test-matrix.md): scenario coverage
  matrix and shortcut/a11y contract notes.
- [Native Scenario Verifier](native-scenario-verifier.md): scenario verifier
  workflow.
- [Workbench 5000 Scenario Matrix](workbench-5000-scenario-matrix.md): generated
  scenario catalogue. The TSV sibling is data, not prose guidance.
- [Surface Audit](surface-audit.md): audit findings from a prior surface pass;
  use as evidence, not current architecture policy.

## Historical Planning Artifacts

These files are useful provenance but are not current source-of-truth docs:

- [Boss-Owned Workspace Planning](boss-owned-workspace-planning.md)
- [Boss-Owned Workspace Doing](boss-owned-workspace-doing.md)
- [F9 Version-Floor / Tools Injection Doing](f9-version-floor-tools-list-probe-doing.md)
- [FRE Delight Doing](fre-delight-doing.md)
- [FRE Subtraction Doing](fre-subtraction-doing.md)
- [Onboarding Overhaul Doing](onboarding-overhaul-doing.md)

Task-specific logs and artifacts live under `worker/tasks/`; read them only when
resuming that task or investigating its exact provenance.
