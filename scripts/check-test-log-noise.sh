#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: $(basename "$0") <label> <log-path>" >&2
  exit 64
fi

label="$1"
log_path="$2"

if [ ! -f "$log_path" ]; then
  echo "error: test log does not exist: $log_path" >&2
  exit 66
fi

if grep -E -n 'AddressBook|CoreData:|NSXPCConnection|NSXPCStore|sendMessage: failed|Failed to create' "$log_path"; then
  echo ""
  echo "FAIL: $label emitted live macOS Contacts/CoreData/XPC noise." >&2
  echo "Rendering tests must use deterministic seams instead of waking live system services." >&2
  exit 1
fi
