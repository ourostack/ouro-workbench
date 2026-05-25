#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="$ROOT_DIR/VERSION"
RELEASE_SOURCE="$ROOT_DIR/Sources/OuroWorkbenchCore/WorkbenchRelease.swift"

fail() {
  printf 'Version contract verification failed: %s\n' "$1" >&2
  exit 1
}

[[ -f "$VERSION_FILE" ]] || fail "missing VERSION file"
version="$(tr -d '[:space:]' < "$VERSION_FILE")"
[[ "$version" =~ ^[0-9]+[.][0-9]+[.][0-9]+([-.][0-9A-Za-z.]+)?$ ]] || fail "VERSION is not semver-like: $version"

source_version="$(sed -n 's/^[[:space:]]*public static let version = "\(.*\)"[[:space:]]*$/\1/p' "$RELEASE_SOURCE" | head -n 1)"
[[ "$source_version" == "$version" ]] || fail "WorkbenchRelease.version is $source_version, expected $version"

printf 'Verified version contract: %s\n' "$version"
