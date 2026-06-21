#!/usr/bin/env bash
#
# Catalog-completeness smoke (#U25): the boss's self-description must match the
# real MCP surface. Drives the built OuroWorkbenchMCP binary's tools/list and
# asserts the advertised tool names equal WorkbenchGuide.advertisedToolNames — the
# single Core contract WorkbenchGuide.bossTools is pinned to by the unit test. So
# adding or removing a server tool without updating the catalog fails here, and
# the boss's check-in prompt / workbench_sense can never list a tool that doesn't
# exist (or omit one that does).
#
# Uses the debug build (swift build), so it runs without packaging the app.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

GUIDE="Sources/OuroWorkbenchCore/WorkbenchGuide.swift"

# The canonical contract: the string literals inside the advertisedToolNames
# array. Extracted from source so this smoke and the Core constant share one
# definition (no second hardcoded list to drift).
expected="$(
  awk '
    /public static let advertisedToolNames: Set<String> = \[/ { capture=1; next }
    capture && /\]/ { capture=0 }
    capture {
      while (match($0, /"[^"]+"/)) {
        s=substr($0, RSTART+1, RLENGTH-2)
        print s
        $0=substr($0, RSTART+RLENGTH)
      }
    }
  ' "$GUIDE" | sort -u
)"

if [ -z "$expected" ]; then
  echo "error: could not extract advertisedToolNames from $GUIDE" >&2
  exit 1
fi

echo "==> swift build --product OuroWorkbenchMCP"
swift build --product OuroWorkbenchMCP >/dev/null

bin="$(swift build --product OuroWorkbenchMCP --show-bin-path)/OuroWorkbenchMCP"
if [ ! -x "$bin" ]; then
  echo "error: MCP binary not found at $bin" >&2
  exit 1
fi

root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT

actual="$(
  printf '%s\n%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  | "$bin" --app-support-root "$root" 2>/dev/null \
  | python3 -c '
import sys, json
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    obj = json.loads(line)
    if obj.get("id") == 2:
        for t in obj["result"]["tools"]:
            print(t["name"])
' | sort -u
)"

if [ "$expected" != "$actual" ]; then
  echo "MCP tool-catalog smoke FAILED: tools/list does not match WorkbenchGuide.advertisedToolNames" >&2
  echo "--- only in catalog (advertisedToolNames) ---" >&2
  comm -23 <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") >&2
  echo "--- only in tools/list (the live server) ---" >&2
  comm -13 <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") >&2
  exit 1
fi

count="$(printf '%s\n' "$expected" | grep -c .)"
echo "MCP tool-catalog smoke passed ($count tools; tools/list == advertisedToolNames)"
