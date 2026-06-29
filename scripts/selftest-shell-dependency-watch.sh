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
grep -Fq "write_manual_pr_summary" "$workflow" || fail "$workflow must summarize manual PR fallback"
grep -Fq "GITHUB_STEP_SUMMARY" "$workflow" || fail "$workflow must write manual PR fallback to the GitHub step summary"
grep -Fq "Manual PR command" "$workflow" || fail "$workflow must print a manual PR command when PR creation is blocked"
grep -Fq 'gh pr create --repo' "$workflow" || fail "$workflow must include a repo-qualified manual PR command"
grep -Fq "run_pr_command" "$workflow" || fail "$workflow must keep PR create/edit/comment best-effort after pushing the branch"
grep -Fq 'run_pr_command "updating refresh PR #${existing}" gh pr edit' "$workflow" \
  || fail "$workflow must route PR edits through the best-effort wrapper"
grep -Fq 'run_pr_command "commenting on refresh PR #${existing}" gh pr comment' "$workflow" \
  || fail "$workflow must route PR comments through the best-effort wrapper"
grep -Fq 'run_pr_command "creating refresh PR" gh pr create' "$workflow" \
  || fail "$workflow must route PR creation through the best-effort wrapper"
if grep -Eq '^[[:space:]]+gh pr (create|edit|comment)\b' "$workflow"; then
  fail "$workflow must not call gh pr create/edit/comment directly"
fi
grep -Fq "Package.resolved VERSION CHANGELOG.md Sources/OuroWorkbenchCore/WorkbenchRelease.swift" "$workflow" \
  || fail "$workflow must stage the shell pin, changelog, and version files"
grep -Fq "CHANGELOG.md" "$helper" || fail "$helper must update CHANGELOG.md with each version bump"
grep -Fq "Shared shell dependency refresh" "$helper" || fail "$helper must name the shell-refresh changelog entry"
grep -Fq "pin location mismatch" "$checker" || fail "$checker must validate the shell pin location"

fallback_tmp="$(mktemp -d)"
(
  trap 'rm -rf "$fallback_tmp"' EXIT
  python3 - "$fallback_tmp/pr-fallback.sh" <<'PY'
from pathlib import Path
import sys

workflow = Path(".github/workflows/shell-dependency-watch.yml").read_text(encoding="utf-8")
lines = workflow.splitlines()
start = next(index for index, line in enumerate(lines) if 'repo="${GITHUB_REPOSITORY:-ourostack/ouro-workbench}"' in line)
end = next(index for index, line in enumerate(lines[start:], start) if 'existing="$(gh pr list' in line)
prefix = "          "
block = []
for line in lines[start:end]:
    if not line:
        block.append("")
        continue
    if not line.startswith(prefix):
        raise SystemExit(f"unexpected workflow indentation while extracting PR fallback: {line!r}")
    block.append(line[len(prefix):])
Path(sys.argv[1]).write_text("\n".join(block) + "\n", encoding="utf-8")
PY
  bash -n "$fallback_tmp/pr-fallback.sh"
  cat > "$fallback_tmp/gh" <<'SH'
#!/usr/bin/env bash
printf 'GraphQL: GitHub Actions is not permitted to create or approve pull requests (createPullRequest): %s\n' "$*" >&2
exit 42
SH
  chmod +x "$fallback_tmp/gh"
  : > "$fallback_tmp/body.md"
  cat > "$fallback_tmp/run-fallback.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
branch="automation/ouro-workbench-refresh-shell-dependency"
title="Refresh shared shell dependency"
source "$1"
run_pr_command "creating refresh PR" gh pr create --repo "$repo" --base main --head "$branch" --title "$title" --body-file "$2"
echo "run_pr_command should exit 0 after writing the manual PR summary" >&2
exit 99
SH
  chmod +x "$fallback_tmp/run-fallback.sh"
  PATH="$fallback_tmp:$PATH" \
    GITHUB_REPOSITORY="ourostack/ouro-workbench" \
    GITHUB_STEP_SUMMARY="$fallback_tmp/summary.md" \
    bash "$fallback_tmp/run-fallback.sh" "$fallback_tmp/pr-fallback.sh" "$fallback_tmp/body.md"
  grep -Fq "Shell dependency refresh needs a PR" "$fallback_tmp/summary.md"
  grep -Fq "automation/ouro-workbench-refresh-shell-dependency" "$fallback_tmp/summary.md"
  grep -Fq "https://github.com/ourostack/ouro-workbench/compare/main...automation/ouro-workbench-refresh-shell-dependency" "$fallback_tmp/summary.md"
  grep -Fq 'gh pr create --repo "ourostack/ouro-workbench" --base main --head "automation/ouro-workbench-refresh-shell-dependency" --title "Refresh shared shell dependency" --fill' "$fallback_tmp/summary.md"
  grep -Fq "createPullRequest" "$fallback_tmp/summary.md"
)

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
