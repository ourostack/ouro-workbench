# Native Scenario Verifier

`OuroWorkbenchScenarioVerifier` is the rendered verification path for the
5000-case Workbench scenario matrix.

It reads `docs/workbench-5000-scenario-matrix.tsv`, builds the same core
fixtures used by `WorkbenchScenarioMatrixTests`, computes production recovery,
readiness, and command-planning outcomes, then renders each row through native
AppKit window-surface fixtures.

Each row is rendered in two viewport profiles:

- `standard`: 1200 x 760.
- `short-window`: 640 x 420.

That means the verifier performs 10,000 native render/layout passes for the
5000 scenario rows.

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
enabled, PNGs are written under `samples/`.

## Current Local Baseline

Last local run on 2026-05-25:

```text
rows verified: 5000
render passes: 10000
viewports: standard, short-window
failures: 0
```
