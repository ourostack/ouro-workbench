#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MCP_EXECUTABLE="$ROOT_DIR/dist/Ouro Workbench.app/Contents/MacOS/OuroWorkbenchMCP"

if [[ ! -x "$MCP_EXECUTABLE" ]]; then
  printf 'MCP action validation smoke failed: missing executable at %s\n' "$MCP_EXECUTABLE" >&2
  exit 1
fi

request='{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"workbench_request_action","arguments":{"action":"createTerminal","group":"This Mac","name":"Invalid Trust Smoke","command":"true","trust":true}}}'
output="$(printf '%s\n' "$request" | "$MCP_EXECUTABLE")"

if [[ "$output" != *'"isError":true'* ]] || [[ "$output" != *'trust must be a string'* ]]; then
  printf 'MCP action validation smoke failed: invalid trust payload was not rejected\n%s\n' "$output" >&2
  exit 1
fi

huge_number_request='{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"workbench_search_transcripts","arguments":{"query":"oversized-number-smoke","maxMatches":1e100}}}'
huge_number_output="$(printf '%s\n' "$huge_number_request" | "$MCP_EXECUTABLE")"

if [[ "$huge_number_output" != *'No transcript matches for oversized-number-smoke'* ]]; then
  printf 'MCP action validation smoke failed: oversized numeric limit did not clamp cleanly\n%s\n' "$huge_number_output" >&2
  exit 1
fi

printf 'MCP action validation smoke passed\n'
