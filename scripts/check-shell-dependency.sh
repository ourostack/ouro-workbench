#!/usr/bin/env bash
#
# Keep Ouro Workbench dogfooding the current shared native app shell. SwiftPM
# branch dependencies still pin a concrete revision in Package.resolved, so a
# plain checkout can silently keep using an older shell main unless we guard it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

identity="ouro-native-apple-app-shell"
shell_url="https://github.com/ourostack/ouro-native-apple-app-shell.git"
shell_ref="refs/heads/main"
manifest="Package.swift"
resolved="Package.resolved"

fail() {
  echo "error: $*" >&2
  exit 1
}

[[ -f "$manifest" ]] || fail "missing $manifest"
[[ -f "$resolved" ]] || fail "missing $resolved"

python3 - "$manifest" "$shell_url" <<'PY'
import re
import sys

manifest, shell_url = sys.argv[1:]
text = open(manifest, encoding="utf-8").read()
pattern = re.compile(
    r'\.package\(\s*url:\s*"' + re.escape(shell_url) + r'",\s*branch:\s*"main"\s*\)',
    re.S,
)
if not pattern.search(text):
    raise SystemExit(f"Package.swift must depend on {shell_url} branch main")
PY

pin="$(
  python3 - "$resolved" "$identity" <<'PY'
import json
import sys

resolved, identity = sys.argv[1:]
with open(resolved, encoding="utf-8") as fh:
    data = json.load(fh)

for pin in data.get("pins", []):
    if pin.get("identity") == identity:
        state = pin.get("state", {})
        branch = state.get("branch") or ""
        revision = state.get("revision") or ""
        if not revision:
            raise SystemExit(f"{identity} pin is missing state.revision")
        print(f"{branch}\t{revision}")
        break
else:
    raise SystemExit(f"Package.resolved has no pin for {identity}")
PY
)"

branch="${pin%%$'\t'*}"
resolved_revision="${pin#*$'\t'}"
[[ "$branch" == "main" ]] || fail "$identity must resolve branch main, got '${branch:-<none>}'"

remote_revision="$(git ls-remote "$shell_url" "$shell_ref" | awk 'NR == 1 {print $1}')"
[[ -n "$remote_revision" ]] || fail "could not resolve $shell_url $shell_ref"

if [[ "$resolved_revision" != "$remote_revision" ]]; then
  cat >&2 <<EOF
error: $identity is stale in Package.resolved
  resolved: $resolved_revision
  remote:   $remote_revision

Run:
  swift package update $identity
EOF
  exit 1
fi

echo "shell dependency fresh: $identity@$resolved_revision"
