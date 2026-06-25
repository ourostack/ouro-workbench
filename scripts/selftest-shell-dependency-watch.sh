#!/usr/bin/env bash
#
# Locks the shell dependency watcher contract so Workbench keeps the same
# self-healing dependency path as the other native consumers.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() {
  echo "error: $*" >&2
  exit 1
}

workflow=".github/workflows/shell-dependency-watch.yml"
helper="scripts/refresh-shell-dependency.sh"
checker="scripts/check-shell-dependency.sh"

[[ -f "$workflow" ]] || fail "missing $workflow"
[[ -x "$helper" ]] || fail "$helper must be executable"

grep -Fq "repository_dispatch:" "$workflow" || fail "$workflow must support repository_dispatch"
grep -Fq "ouro-native-apple-app-shell-main-updated" "$workflow" || fail "$workflow must listen for shell main dispatches"
grep -Fq "schedule:" "$workflow" || fail "$workflow must have a scheduled check"
grep -Fq "$helper" "$workflow" || fail "$workflow must run $helper"
grep -Fq "automation/ouro-workbench-refresh-shell-dependency" "$workflow" || fail "$workflow must use the stable automation branch"
grep -Fq "Package.resolved VERSION Sources/OuroWorkbenchCore/WorkbenchRelease.swift" "$workflow" \
  || fail "$workflow must stage only the shell pin and version files"
grep -Fq "pin location mismatch" "$checker" || fail "$checker must validate the shell pin location"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

python3 - "$tmp/Package.resolved" <<'PY'
from pathlib import Path
import json
import sys

path = Path(sys.argv[1])
path.write_text(json.dumps({
    "pins": [
        {
            "identity": "ouro-native-apple-app-shell",
            "location": "https://example.invalid/ouro-native-apple-app-shell.git",
            "state": {
                "branch": "main",
                "revision": "4393cac90d482af1713d4c1a84f7fdeeb27a5946",
            },
        }
    ],
    "version": 3,
}, indent=2), encoding="utf-8")
PY

if output="$(python3 - "$tmp/Package.resolved" 2>&1 <<'PY'
import json
import sys

resolved = sys.argv[1]
identity = "ouro-native-apple-app-shell"
shell_url = "https://github.com/ourostack/ouro-native-apple-app-shell.git"
with open(resolved, encoding="utf-8") as fh:
    data = json.load(fh)
for pin in data.get("pins", []):
    if pin.get("identity") == identity:
        location = pin.get("location") or ""
        if location != shell_url:
            raise SystemExit(f"{identity} pin location mismatch: {location or '<none>'}, expected {shell_url}")
        break
else:
    raise SystemExit(f"Package.resolved has no pin for {identity}")
PY
)"; then
  fail "location guard accepted a shell pin from the wrong upstream"
fi

grep -Fq "pin location mismatch" <<<"$output" || fail "location guard failed without the expected diagnostic"

echo "shell dependency watch selftest ok"
