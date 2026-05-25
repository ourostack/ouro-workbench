# Native Scenario Verifier

`OuroWorkbenchScenarioVerifier` is the rendered verification path for the
5000-case Workbench scenario matrix and the deterministic deep sweep built on
top of it.

It reads `docs/workbench-5000-scenario-matrix.tsv`, builds the same core
fixtures used by `WorkbenchScenarioMatrixTests`, computes production recovery,
readiness, and command-planning outcomes, then renders each row through native
AppKit window-surface fixtures.

Each row is rendered in five viewport profiles:

- `standard`: 1200 x 760.
- `short-window`: 640 x 420.
- `compact-terminal`: 520 x 360.
- `tall-workspace`: 900 x 1000.
- `wide-workspace`: 1600 x 900.

That means the required verifier performs 25,000 native layout/invariant passes
for the 5000 scenario rows. PNG rasterization is reserved for evidence samples
so the CI path stays deterministic while still using the same native surface
fixtures and geometry checks.

## What It Checks

- Terminal focus content and controls never overlap the macOS traffic-light
  region.
- Dashboard text, warnings, metrics, and action-log rows do not cross the
  terminal split boundary.
- Collapsed boss-pane surfaces do not render boss dashboard content.
- Archived session surfaces preserve history without rendering an active
  terminal body.
- Header, sidebar, boss, terminal, and archived text/control regions stay
  inside every viewport profile.
- The rendered evidence is backed by the same matrix fixtures used by recovery,
  readiness, and command-planning tests.
- Deep generated scenarios mutate boss selection, project/group counts,
  terminal names, working directories, command shapes, peer sessions, run
  statuses, transcript paths, executable health, and restart metadata.

## Commands

Fast CI verifier:

```bash
swift run OuroWorkbenchScenarioVerifier --out .build/workbench-scenario-verifier --no-samples
```

Local verifier with PNG evidence:

```bash
swift run OuroWorkbenchScenarioVerifier --out .build/workbench-scenario-verifier --sample-limit 20
```

Debug a small prefix:

```bash
swift run OuroWorkbenchScenarioVerifier --out .build/workbench-scenario-verifier-smoke --max-rows 100 --no-samples
```

Deep deterministic sweep:

```bash
swift run OuroWorkbenchScenarioVerifier --out .build/workbench-scenario-verifier-deep --no-samples --deep-scenarios 15000 --seed 20260525
```

Strict contract check for the required CI baseline:

```bash
swift run OuroWorkbenchScenarioVerifier \
  --out .build/workbench-scenario-verifier \
  --no-samples \
  --expect-rows 5000 \
  --expect-matrix-rows 5000 \
  --expect-deep-rows 0 \
  --expect-render-passes 25000 \
  --expect-coverage-digest 567dc7ec0c45835b
```

Full local preflight, including the required native verifier contract and app
bundle packaging:

```bash
scripts/preflight.sh
```

Include the scheduled deep sweep locally:

```bash
scripts/preflight.sh --deep
```

The verifier writes `summary.json` to the output directory. When samples are
enabled, representative native PNGs are rasterized and written under `samples/`.
The summary includes a stable coverage digest plus distributions for terminal
identity, lifecycle, trust/resume posture, surface, boss bridge state,
executable health, recovery action, readiness state, boss agent, workspace size,
run count, and viewport coverage.

## Current Local Baseline

Last local run on 2026-05-25:

```text
rows verified: 5000
render passes: 25000
viewports: standard, short-window, compact-terminal, tall-workspace, wide-workspace
coverage digest: 567dc7ec0c45835b
failures: 0
```

Deep local baseline from the same date:

```text
rows verified: 20000
matrix rows: 5000
deep generated rows: 15000
deep seed: 20260525
render passes: 100000
viewports: standard, short-window, compact-terminal, tall-workspace, wide-workspace
coverage digest: 0fd57795f807596d
failures: 0
```

## CI And Protection Target

The required pull-request target is the full 5000-row matrix across the five
viewport profiles above: 25,000 native layout/invariant passes. This is the
realistic always-on goal: high enough to exercise the surfaces that have broken
in real use, but still small enough for every PR. The CI job also enforces the
expected row counts, render-pass count, and coverage digest, so scenario drift
requires an intentional baseline update.

The verifier runs as its own GitHub Actions job named `Native scenario verifier`
so branch protection can require it separately from `Swift tests`.

The `Swift tests` job also regenerates the 5000-row scenario matrix and fails
if the checked-in TSV or markdown summary drift from
`scripts/generate-workbench-5000-matrix.rb`.

## Scheduled Deep Sweep

The repository also has a scheduled and manually dispatchable `Deep Scenario
Verifier` workflow. It keeps the PR gate fast, then runs the 100,000-pass deep
sweep out of band so generated fixture coverage can keep growing without making
ordinary pull requests feel heavy.
