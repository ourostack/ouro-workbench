#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
eval "$("$ROOT_DIR/scripts/read-workbench-release.sh")"
REPO="$WORKBENCH_REPOSITORY"

usage() {
  cat <<USAGE
Usage: resolve-latest-release-tag.sh [options]

Print the newest non-draft GitHub Release tag, including prereleases.

Options:
  --repo OWNER/REPO   GitHub repository (default: $REPO)
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
  printf 'GitHub CLI is required to inspect release tags. Install or authenticate gh first.\n' >&2
  exit 69
fi

tag="$(gh release list \
  --repo "$REPO" \
  --exclude-drafts \
  --limit 1 \
  --json tagName \
  --jq '.[0].tagName')"

if [[ -z "$tag" || "$tag" == "null" ]]; then
  printf 'No release tag found for %s\n' "$REPO" >&2
  exit 1
fi

printf '%s\n' "$tag"
