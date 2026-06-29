#!/usr/bin/env bash
#
# Keep Ouro Workbench dogfooding the current shared native app shell code.
# SwiftPM branch dependencies still pin a concrete revision in Package.resolved,
# so a plain checkout can silently keep using older shell package code unless we
# guard it. Shell CI/contract-only commits are intentionally ignored here.
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
  python3 - "$resolved" "$identity" "$shell_url" <<'PY'
import json
import sys

resolved, identity, shell_url = sys.argv[1:]
with open(resolved, encoding="utf-8") as fh:
    data = json.load(fh)

for pin in data.get("pins", []):
    if pin.get("identity") == identity:
        location = pin.get("location") or ""
        if location != shell_url:
            raise SystemExit(f"{identity} pin location mismatch: {location or '<none>'}, expected {shell_url}")
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

shell_snapshot="$(
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  git clone --quiet --filter=blob:none --no-checkout --single-branch --branch main "$shell_url" "$tmp"
  remote_revision="$(git -C "$tmp" rev-parse HEAD)"
  package_revision="$(git -C "$tmp" log -n 1 --format=%H HEAD -- Package.swift Sources)"
  [[ -n "$package_revision" ]] || exit 3
  pin_contains_package_revision=false
  if git -C "$tmp" cat-file -e "$resolved_revision^{commit}" 2>/dev/null \
    && git -C "$tmp" merge-base --is-ancestor "$package_revision" "$resolved_revision"; then
    pin_contains_package_revision=true
  fi
  printf '%s\t%s\t%s\n' "$remote_revision" "$package_revision" "$pin_contains_package_revision"
)" || fail "could not resolve package-relevant $shell_url $shell_ref"

remote_revision="${shell_snapshot%%$'\t'*}"
remainder="${shell_snapshot#*$'\t'}"
package_revision="${remainder%%$'\t'*}"
pin_contains_package_revision="${remainder#*$'\t'}"

if [[ "$pin_contains_package_revision" != "true" ]]; then
  cat >&2 <<EOF
error: $identity is stale in Package.resolved
  resolved:                $resolved_revision
  latest package-relevant: $package_revision
  remote main:             $remote_revision

Run:
  swift package update $identity
EOF
  exit 1
fi

if [[ "$resolved_revision" == "$remote_revision" ]]; then
  echo "shell dependency fresh: $identity@$resolved_revision"
else
  echo "shell dependency fresh: $identity@$resolved_revision (remote main $remote_revision has no newer package-relevant shell changes)"
fi
