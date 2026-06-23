#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
eval "$("$ROOT_DIR/scripts/read-workbench-release.sh")"
BRANCH="main"
RUN_ID=""
INSTALL_DIR=""
OPEN_AFTER_INSTALL="false"

usage() {
  cat <<USAGE
Usage: install-latest-app-artifact.sh [options]

Download, verify, and install the app artifact from a successful GitHub Actions
CI run.

Options:
  --branch NAME       Branch to inspect when --run-id is omitted (default: main)
  --run-id ID         Specific GitHub Actions run id to download
  --install-dir PATH  Install destination directory
  --open              Reopen $WORKBENCH_APP_NAME after installing
  -h, --help          Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch)
      if [[ $# -lt 2 || -z "$2" ]]; then
        usage >&2
        exit 64
      fi
      BRANCH="$2"
      shift 2
      ;;
    --run-id)
      if [[ $# -lt 2 || -z "$2" || ! "$2" =~ ^[0-9]+$ ]]; then
        usage >&2
        exit 64
      fi
      RUN_ID="$2"
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
  printf 'GitHub CLI is required to download app artifacts. Install or authenticate gh first.\n' >&2
  exit 69
fi

repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
if [[ -z "$repo" ]]; then
  printf 'Unable to determine GitHub repository for %s\n' "$ROOT_DIR" >&2
  exit 1
fi

if [[ -z "$RUN_ID" ]]; then
  RUN_ID="$(gh run list \
    --repo "$repo" \
    --workflow CI \
    --branch "$BRANCH" \
    --status success \
    --limit 1 \
    --json databaseId \
    --jq '.[0].databaseId')"
fi
if [[ -z "$RUN_ID" || "$RUN_ID" == "null" ]]; then
  printf 'No successful CI run found for branch %s in %s\n' "$BRANCH" "$repo" >&2
  exit 1
fi

head_sha="$(gh run view "$RUN_ID" --repo "$repo" --json headSha --jq .headSha)"
if [[ -z "$head_sha" || "$head_sha" == "null" ]]; then
  printf 'Unable to determine head SHA for run %s\n' "$RUN_ID" >&2
  exit 1
fi

artifact_name="ouro-workbench-app-$head_sha"
download_root="$(mktemp -d)"
trap 'rm -rf "$download_root"' EXIT

gh run download "$RUN_ID" --repo "$repo" --name "$artifact_name" --dir "$download_root" >/dev/null

manifest=""
manifest_count=0
while IFS= read -r candidate; do
  manifest="$candidate"
  manifest_count=$((manifest_count + 1))
done < <(find "$download_root" -name "$WORKBENCH_ARTIFACT_NAME_PREFIX*.manifest.json" -type f -print)

if [[ "$manifest_count" -ne 1 ]]; then
  printf 'Expected exactly one app artifact manifest in %s, found %s\n' "$download_root" "$manifest_count" >&2
  exit 1
fi

manifest_sha="$(plutil -extract gitSha raw -o - "$manifest")"
if [[ "$manifest_sha" != "$head_sha" ]]; then
  printf 'Downloaded manifest SHA %s does not match run head SHA %s\n' "$manifest_sha" "$head_sha" >&2
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

printf 'Installing app artifact from %s run %s (%s)\n' "$repo" "$RUN_ID" "${head_sha:0:7}"
"$ROOT_DIR/scripts/install-app.sh" "${install_args[@]}"
