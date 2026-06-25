#!/usr/bin/env bash
#
# Refresh the shared native shell branch dependency and prepare the Workbench
# version bump required for the Package.resolved change. Safe on a fresh main
# checkout: it exits without edits when the shell pin is already current.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

identity="ouro-native-apple-app-shell"

fail() {
  echo "error: $*" >&2
  exit 1
}

non_shell_pin_snapshot() {
  python3 - "$identity" <<'PY'
import json
import sys

identity = sys.argv[1]
with open("Package.resolved", encoding="utf-8") as fh:
    data = json.load(fh)

rows = []
for pin in data.get("pins", []):
    if pin.get("identity") == identity:
        continue
    state = pin.get("state", {})
    rows.append(
        "\t".join(
            [
                pin.get("identity", ""),
                pin.get("location", ""),
                state.get("branch", ""),
                state.get("revision", ""),
                state.get("version", ""),
            ]
        )
    )
print("\n".join(sorted(rows)))
PY
}

current_version="$(tr -d '[:space:]' < VERSION)"
next_version="${OURO_WORKBENCH_SHELL_REFRESH_VERSION:-}"
if [[ -z "$next_version" ]]; then
  next_version="$(
    python3 - "$current_version" <<'PY'
import re
import sys

version = sys.argv[1]
match = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)(?:[-.][0-9A-Za-z.]+)?", version)
if not match:
    raise SystemExit(f"cannot bump non-semver version: {version}")
major, minor, patch = (int(part) for part in match.groups())
print(f"{major}.{minor}.{patch + 1}")
PY
  )"
fi

if [[ ! "$next_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  fail "next version is not semver: $next_version"
fi

if ./scripts/check-shell-dependency.sh; then
  echo "shell dependency already fresh; no refresh needed"
  exit 0
fi

[[ -z "$(git status --porcelain)" ]] || fail "refresh requires a clean worktree"

before_non_shell_pins="$(non_shell_pin_snapshot)"

echo "Refreshing $identity to latest main..."
swift package update "$identity"

./scripts/check-shell-dependency.sh

after_non_shell_pins="$(non_shell_pin_snapshot)"
if [[ "$before_non_shell_pins" != "$after_non_shell_pins" ]]; then
  diff -u <(printf '%s\n' "$before_non_shell_pins") <(printf '%s\n' "$after_non_shell_pins") || true
  fail "refresh changed non-$identity pins; inspect and refresh deliberately"
fi

if git diff --quiet -- Package.resolved; then
  fail "$identity freshness changed but Package.resolved has no diff"
fi

printf '%s\n' "$next_version" > VERSION
python3 - "$next_version" <<'PY'
from pathlib import Path
import re
import sys

next_version = sys.argv[1]
path = Path("Sources/OuroWorkbenchCore/WorkbenchRelease.swift")
text = path.read_text(encoding="utf-8")
updated, count = re.subn(
    r'(public static let version = ")[0-9]+\.[0-9]+\.[0-9]+(?:[-.][0-9A-Za-z.]+)?(")',
    rf'\g<1>{next_version}\2',
    text,
    count=1,
)
if count != 1:
    raise SystemExit("could not rewrite WorkbenchRelease.version")
path.write_text(updated, encoding="utf-8")
PY

./scripts/verify-version-contract.sh
echo "Prepared $identity refresh for Ouro Workbench v$next_version."
