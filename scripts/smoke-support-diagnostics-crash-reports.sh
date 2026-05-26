#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ouro-workbench-support-diagnostics.XXXXXX")"
HOME_DIR="$TEMP_ROOT/home"
OUT_ROOT="$TEMP_ROOT/out"
REPORTS_DIR="$HOME_DIR/Library/Logs/DiagnosticReports"

cleanup() {
  rm -rf "$TEMP_ROOT"
}

trap cleanup EXIT

mkdir -p "$REPORTS_DIR" "$OUT_ROOT"
printf '{"app_name":"OuroWorkbench"}\n' > "$REPORTS_DIR/OuroWorkbench-2099-01-01-000000.ips"
printf 'legacy crash report\n' > "$REPORTS_DIR/Ouro Workbench-legacy.crash"
printf 'unrelated\n' > "$REPORTS_DIR/OtherApp-2099-01-01-000000.ips"
printf 'scenario verifier\n' > "$REPORTS_DIR/OuroWorkbenchScenarioVerifier-2099-01-01-000000.ips"

HOME="$HOME_DIR" "$ROOT_DIR/scripts/collect-support-diagnostics.sh" --out "$OUT_ROOT" >/dev/null

runtime_file="$(find "$OUT_ROOT" -path '*/runtime.txt' -type f -print -quit)"
if [[ -z "$runtime_file" ]]; then
  printf 'Support diagnostics crash-report smoke failed: runtime.txt was not generated\n' >&2
  exit 1
fi

if ! grep -F 'OuroWorkbench-2099-01-01-000000.ips' "$runtime_file" >/dev/null; then
  printf 'Support diagnostics crash-report smoke failed: modern .ips report was omitted\n' >&2
  exit 1
fi

if ! grep -F 'Ouro Workbench-legacy.crash' "$runtime_file" >/dev/null; then
  printf 'Support diagnostics crash-report smoke failed: legacy .crash report was omitted\n' >&2
  exit 1
fi

if grep -F 'OtherApp-2099-01-01-000000.ips' "$runtime_file" >/dev/null; then
  printf 'Support diagnostics crash-report smoke failed: unrelated report leaked into diagnostics\n' >&2
  exit 1
fi

if grep -F 'OuroWorkbenchScenarioVerifier-2099-01-01-000000.ips' "$runtime_file" >/dev/null; then
  printf 'Support diagnostics crash-report smoke failed: scenario verifier report leaked into app diagnostics\n' >&2
  exit 1
fi

printf 'Support diagnostics crash-report smoke passed\n'
