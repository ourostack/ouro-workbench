#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
eval "$("$ROOT_DIR/scripts/read-workbench-release.sh")"
REPO="$WORKBENCH_REPOSITORY"
TAG=""
INSTALL_DIR=""
OPEN_AFTER_INSTALL="false"

usage() {
  cat <<USAGE
Usage: install-latest-release.sh [options]

Download, verify, and install the app artifact from a GitHub Release.

Options:
  --repo OWNER/REPO   GitHub repository (default: $REPO)
  --tag TAG           Release tag to install; defaults to latest release
  --install-dir PATH  Install destination directory
  --open              Reopen $WORKBENCH_APP_NAME after installing
  -h, --help          Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      if [[ $# -lt 2 || -z "$2" ]]; then
        usage >&2
        exit 64
      fi
      REPO="$2"
      shift 2
      ;;
    --tag)
      if [[ $# -lt 2 || -z "$2" ]]; then
        usage >&2
        exit 64
      fi
      TAG="$2"
      shift 2
      ;;
    --install-dir)
      if [[ $# -lt 2 || -z "$2" ]]; then
        usage >&2
        exit 64
      fi
      INSTALL_DIR="$2"
      shift 2
      ;;
    --open)
      OPEN_AFTER_INSTALL="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 64
      ;;
  esac
done

if ! command -v gh >/dev/null 2>&1; then
  printf 'GitHub CLI is required to download release assets. Install or authenticate gh first.\n' >&2
  exit 69
fi

if [[ -z "$TAG" ]]; then
  TAG="$("$ROOT_DIR/scripts/resolve-latest-release-tag.sh" --repo "$REPO")"
fi
if [[ -z "$TAG" || "$TAG" == "null" ]]; then
  printf 'No release tag found for %s\n' "$REPO" >&2
  exit 1
fi

download_root="$(mktemp -d)"
trap 'rm -rf "$download_root"' EXIT

gh release download "$TAG" \
  --repo "$REPO" \
  --pattern "$WORKBENCH_ARTIFACT_NAME_PREFIX*.zip" \
  --pattern "$WORKBENCH_ARTIFACT_NAME_PREFIX*.manifest.json" \
  --dir "$download_root" >/dev/null

manifest=""
manifest_count=0
while IFS= read -r candidate; do
  manifest="$candidate"
  manifest_count=$((manifest_count + 1))
done < <(find "$download_root" -name "$WORKBENCH_ARTIFACT_NAME_PREFIX*.manifest.json" -type f -print)

if [[ "$manifest_count" -ne 1 ]]; then
  printf 'Expected exactly one app artifact manifest in release %s, found %s\n' "$TAG" "$manifest_count" >&2
  exit 1
fi

"$ROOT_DIR/scripts/verify-app-artifact.sh" "$manifest" >/dev/null

install_args=(--artifact-manifest "$manifest")
if [[ -n "$INSTALL_DIR" ]]; then
  install_args+=(--install-dir "$INSTALL_DIR")
fi
if [[ "$OPEN_AFTER_INSTALL" == "true" ]]; then
  install_args+=(--open)
fi

printf 'Installing app artifact from %s release %s\n' "$REPO" "$TAG"
"$ROOT_DIR/scripts/install-app.sh" "${install_args[@]}"
