#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

scripts/check-shell-dependency.sh
scripts/check-shell-boundary.sh --selftest
scripts/check-shell-boundary.sh

RUN_DEEP="false"
RUN_ONLY="all"
RUN_SELFTEST="false"
PR_BASE_REF="${OURO_PR_BASE_REF:-origin/main}"
SWIFT_STRICT_FLAGS=(-Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete)
PREFLIGHT_GATES=(
  release-policy
  generated-scenario-matrix
  swift-tests
  ui-probes
  required-scenario-verifier
  app-bundle
  app-artifact
  install-rollback
)

DEEP_PREFLIGHT_GATE=deep-scenario-verifier

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") [--deep] [--only <gate>] [--selftest]

Gates:
$(printf '  %s\n' "${PREFLIGHT_GATES[@]}" "$DEEP_PREFLIGHT_GATE")
EOF
}

is_known_gate() {
  local gate="$1"
  local known
  for known in "${PREFLIGHT_GATES[@]}" "$DEEP_PREFLIGHT_GATE"; do
    [[ "$gate" == "$known" ]] && return 0
  done
  return 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --deep)
      RUN_DEEP="true"
      shift
      ;;
    --only)
      [[ $# -ge 2 ]] || {
        usage
        exit 64
      }
      RUN_ONLY="$2"
      shift 2
      ;;
    --only=*)
      RUN_ONLY="${1#--only=}"
      shift
      ;;
    --selftest)
      RUN_SELFTEST="true"
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

if ! is_known_gate "$RUN_ONLY" && [[ "$RUN_ONLY" != "all" ]]; then
  usage
  exit 64
fi

if [[ "$RUN_SELFTEST" == "true" ]]; then
  script="$ROOT_DIR/scripts/preflight.sh"
  "$script" --help >/dev/null 2>&1
  "$script" --only=release-policy --help >/dev/null 2>&1
  status=0
  "$script" --only >/tmp/ouro-workbench-preflight-selftest.out 2>/tmp/ouro-workbench-preflight-selftest.err || status=$?
  if [[ "$status" -eq 0 ]]; then
    printf 'preflight selftest expected --only without a value to fail\n' >&2
    exit 1
  fi
  [[ "$status" -eq 64 ]] || {
    printf 'preflight selftest expected --only without a value to exit 64\n' >&2
    exit 1
  }
  status=0
  "$script" --only does-not-exist >/tmp/ouro-workbench-preflight-selftest.out 2>/tmp/ouro-workbench-preflight-selftest.err || status=$?
  if [[ "$status" -eq 0 ]]; then
    printf 'preflight selftest expected unknown gate to fail\n' >&2
    exit 1
  fi
  [[ "$status" -eq 64 ]] || {
    printf 'preflight selftest expected unknown gate to exit 64\n' >&2
    exit 1
  }
  printf 'preflight CLI selftest ok\n'
  exit 0
fi

eval "$("$ROOT_DIR/scripts/read-workbench-release.sh")"

run_step() {
  printf '\n==> %s\n' "$1"
}

preflight_release_policy() {
  run_step "Verify preflight CLI"
  scripts/preflight.sh --selftest

  run_step "Verify release version contract"
  scripts/verify-version-contract.sh

  run_step "Verify release freshness policy"
  scripts/release-policy.sh freshness --mode pr --base-ref "$PR_BASE_REF"
  scripts/release-policy.sh selftest-pr-base
  scripts/release-policy.sh selftest-release-api-fallback
  scripts/release-policy.sh selftest-package-guards
  scripts/release-policy.sh selftest-shell-dependency-watch
  scripts/release-policy.sh selftest-paths

  run_step "Verify release support tooling"
  scripts/smoke-package-shallow-guard.sh
  scripts/install-latest-app-artifact.sh --help >/dev/null
  scripts/install-latest-release.sh --help >/dev/null
  scripts/resolve-latest-release-tag.sh --help >/dev/null
  scripts/verify-published-release.sh --help >/dev/null
  scripts/selftest-latest-release-installer.sh
  scripts/collect-support-diagnostics.sh --help >/dev/null
  scripts/smoke-support-diagnostics-crash-reports.sh
  scripts/generate-release-notes.sh >/dev/null
}

preflight_generated_scenario_matrix() {
  run_step "Verify generated scenario matrix"
  scripts/generate-workbench-5000-matrix.rb
  git diff --exit-code -- docs/workbench-5000-scenario-matrix.tsv docs/workbench-5000-scenario-matrix.md
}

preflight_swift_tests() {
  run_step "Run Swift tests"
  scripts/check-swift-tests.sh
}

preflight_ui_probes() {
  run_step "Run native UI surface probe"
  swift run "${SWIFT_STRICT_FLAGS[@]}" OuroWorkbench --uisurfacetest

  run_step "Run keyboard and accessibility contract probe"
  swift run "${SWIFT_STRICT_FLAGS[@]}" OuroWorkbench --keyboarda11ycontract
}

preflight_required_scenario_verifier() {
  run_step "Run required native scenario verifier"
  swift run "${SWIFT_STRICT_FLAGS[@]}" OuroWorkbenchScenarioVerifier \
    --out .build/workbench-scenario-verifier-preflight \
    --no-samples \
    --expect-rows 5000 \
    --expect-matrix-rows 5000 \
    --expect-deep-rows 0 \
    --expect-render-passes 25000 \
    --expect-coverage-digest 89292786bde2e133
}

preflight_app_bundle() {
  run_step "Package and verify native app bundle"
  scripts/smoke-verify-app-timeout.sh
  scripts/package-app.sh
  scripts/verify-app-bundle.sh
  rm -rf .build/support-diagnostics-preflight
  "dist/$WORKBENCH_APP_NAME.app/Contents/Resources/collect-support-diagnostics.sh" \
    --out .build/support-diagnostics-preflight >/dev/null
  find .build/support-diagnostics-preflight -name 'ouro-workbench-diagnostics-*.zip' -type f | grep -q .
  scripts/smoke-mcp-action-validation.sh
}

preflight_app_artifact() {
  run_step "Archive native app artifact"
  scripts/archive-app-artifact.sh
  scripts/smoke-app-artifact-verifier.sh
  scripts/smoke-install-from-artifact.sh
  scripts/selftest-install-app-artifact-version.sh
  scripts/selftest-published-release-verifier.sh
  scripts/selftest-web-installer.sh
}

preflight_install_rollback() {
  run_step "Smoke install rollback"
  scripts/smoke-install-rollback.sh
}

preflight_deep_scenario_verifier() {
  run_step "Run deep native scenario verifier"
  swift run "${SWIFT_STRICT_FLAGS[@]}" OuroWorkbenchScenarioVerifier \
    --out .build/workbench-scenario-verifier-deep-preflight \
    --no-samples \
    --deep-scenarios 15000 \
    --seed 20260525 \
    --expect-rows 20000 \
    --expect-matrix-rows 5000 \
    --expect-deep-rows 15000 \
    --expect-render-passes 100000 \
    --expect-coverage-digest d205bd5c250d80ca
}

run_gate() {
  case "$1" in
    release-policy) preflight_release_policy ;;
    generated-scenario-matrix) preflight_generated_scenario_matrix ;;
    swift-tests) preflight_swift_tests ;;
    ui-probes) preflight_ui_probes ;;
    required-scenario-verifier) preflight_required_scenario_verifier ;;
    app-bundle) preflight_app_bundle ;;
    app-artifact) preflight_app_artifact ;;
    install-rollback) preflight_install_rollback ;;
    deep-scenario-verifier) preflight_deep_scenario_verifier ;;
    *)
      usage
      exit 64
      ;;
  esac
}

if [[ "$RUN_ONLY" == "all" ]]; then
  for gate in "${PREFLIGHT_GATES[@]}"; do
    run_gate "$gate"
  done

  if [[ "$RUN_DEEP" == "true" ]]; then
    run_gate "$DEEP_PREFLIGHT_GATE"
  fi
else
  run_gate "$RUN_ONLY"
fi

run_step "Preflight complete"
