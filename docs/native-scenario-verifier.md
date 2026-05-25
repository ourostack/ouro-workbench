# Native Scenario Verifier

`OuroWorkbenchScenarioVerifier` is the rendered verification path for the
5000-case Workbench scenario matrix.

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
  inside the viewport in both profiles.
- The rendered evidence is backed by the same matrix fixtures used by recovery,
  readiness, and command-planning tests.

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

The verifier writes `summary.json` to the output directory. When samples are
enabled, representative native PNGs are rasterized and written under `samples/`.

## Current Local Baseline

Last local run on 2026-05-25:

```text
rows verified: 5000
render passes: 25000
viewports: standard, short-window, compact-terminal, tall-workspace, wide-workspace
failures: 0
```

## CI And Protection Target

The required pull-request target is the full 5000-row matrix across the five
viewport profiles above: 25,000 native layout/invariant passes. This is the
realistic always-on goal: high enough to exercise the surfaces that have broken
in real use, but still small enough for every PR.

The verifier runs as its own GitHub Actions job named `Native scenario verifier`
so branch protection can require it separately from `Swift tests`.
