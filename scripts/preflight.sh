#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_DEEP="false"

usage() {
  printf 'Usage: %s [--deep]\n' "$(basename "$0")" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --deep)
      RUN_DEEP="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 64
      ;;
  esac
done

run_step() {
  printf '\n==> %s\n' "$1"
}

cd "$ROOT_DIR"

run_step "Verify release version contract"
scripts/verify-version-contract.sh

run_step "Verify generated scenario matrix"
scripts/generate-workbench-5000-matrix.rb
git diff --exit-code -- docs/workbench-5000-scenario-matrix.tsv docs/workbench-5000-scenario-matrix.md

run_step "Run Swift tests"
swift test

run_step "Run required native scenario verifier"
swift run OuroWorkbenchScenarioVerifier \
  --out .build/workbench-scenario-verifier-preflight \
  --no-samples \
  --expect-rows 5000 \
  --expect-matrix-rows 5000 \
  --expect-deep-rows 0 \
  --expect-render-passes 25000 \
  --expect-coverage-digest 567dc7ec0c45835b

run_step "Package and verify native app bundle"
scripts/package-app.sh
scripts/verify-app-bundle.sh

run_step "Archive native app artifact"
scripts/archive-app-artifact.sh
scripts/smoke-app-artifact-verifier.sh

run_step "Smoke install rollback"
scripts/smoke-install-rollback.sh

if [[ "$RUN_DEEP" == "true" ]]; then
  run_step "Run deep native scenario verifier"
  swift run OuroWorkbenchScenarioVerifier \
    --out .build/workbench-scenario-verifier-deep-preflight \
    --no-samples \
    --deep-scenarios 15000 \
    --seed 20260525 \
    --expect-rows 20000 \
    --expect-matrix-rows 5000 \
    --expect-deep-rows 15000 \
    --expect-render-passes 100000 \
    --expect-coverage-digest 0fd57795f807596d
fi

run_step "Preflight complete"
