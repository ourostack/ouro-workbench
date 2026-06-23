#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
eval "$("$ROOT_DIR/scripts/read-workbench-release.sh")"
APP_NAME="$WORKBENCH_APP_NAME.app"
INSTALL_DIR="$HOME/Applications"
OPEN_AFTER_INSTALL="false"
VERIFY_SCRIPT="$ROOT_DIR/scripts/verify-app-bundle.sh"
ARTIFACT_MANIFEST=""

usage() {
  printf 'Usage: %s [--install-dir PATH] [--artifact-manifest PATH] [--verify-script PATH] [--open]\n' "$(basename "$0")" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-dir)
      if [[ $# -lt 2 || -z "$2" ]]; then
        usage
        exit 64
      fi
      INSTALL_DIR="$2"
      shift 2
      ;;
    --artifact-manifest)
      if [[ $# -lt 2 || -z "$2" ]]; then
        usage
        exit 64
      fi
      ARTIFACT_MANIFEST="$2"
      shift 2
      ;;
    --verify-script)
      if [[ $# -lt 2 || -z "$2" ]]; then
        usage
        exit 64
      fi
      VERIFY_SCRIPT="$2"
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
      usage
      exit 64
      ;;
  esac
done

APP_SOURCE=""
APP_DEST="$INSTALL_DIR/$APP_NAME"
STAGING_ROOT=""
STAGED_APP=""
BACKUP_APP=""
INSTALL_SUCCEEDED="false"
DESTINATION_REPLACED="false"

running_workbench_pids_for_destination() {
  local pid
  local command
  for pid in $(pgrep -x "$WORKBENCH_BUNDLE_EXECUTABLE" 2>/dev/null || true); do
    command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    case "$command" in
      "$APP_DEST/Contents/MacOS/$WORKBENCH_BUNDLE_EXECUTABLE"*)
        printf '%s\n' "$pid"
        ;;
    esac
  done
}

destination_workbench_is_running() {
  [[ -n "$(running_workbench_pids_for_destination)" ]]
}

wait_until_workbench_stops() {
  for _ in {1..40}; do
    if ! destination_workbench_is_running; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

stop_running_workbench() {
  if ! destination_workbench_is_running; then
    return
  fi

  printf 'Stopping running %s before install...\n' "$WORKBENCH_APP_NAME" >&2
  osascript -e "tell application id \"$WORKBENCH_BUNDLE_IDENTIFIER\" to quit" >/dev/null 2>&1 || true
  if wait_until_workbench_stops; then
    return
  fi

  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    kill -TERM "$pid" >/dev/null 2>&1 || true
  done < <(running_workbench_pids_for_destination)
  if wait_until_workbench_stops; then
    return
  fi

  printf 'Unable to stop running %s before install.\n' "$WORKBENCH_APP_NAME" >&2
  exit 1
}

installed_workbench_is_running() {
  destination_workbench_is_running
}

cleanup() {
  if [[ -n "$STAGING_ROOT" ]]; then
    rm -rf "$STAGING_ROOT"
  fi
}

restore_backup() {
  if [[ "$INSTALL_SUCCEEDED" == "true" ]]; then
    return
  fi
  if [[ -n "$BACKUP_APP" && -d "$BACKUP_APP" ]]; then
    rm -rf "$APP_DEST"
    mv "$BACKUP_APP" "$APP_DEST"
  elif [[ "$DESTINATION_REPLACED" == "true" ]]; then
    rm -rf "$APP_DEST"
  fi
}

trap 'restore_backup; cleanup' EXIT

if [[ ! -x "$VERIFY_SCRIPT" ]]; then
  printf 'App verifier is not executable: %s\n' "$VERIFY_SCRIPT" >&2
  exit 64
fi
if [[ -n "$ARTIFACT_MANIFEST" ]]; then
  "$ROOT_DIR/scripts/verify-app-artifact.sh" "$ARTIFACT_MANIFEST" >/dev/null
else
  "$ROOT_DIR/scripts/package-app.sh" >/dev/null
  APP_SOURCE="$ROOT_DIR/dist/$APP_NAME"
fi

stop_running_workbench

mkdir -p "$INSTALL_DIR"
STAGING_ROOT="$(mktemp -d "$INSTALL_DIR/.ouro-workbench-install.XXXXXX")"
STAGED_APP="$STAGING_ROOT/$APP_NAME"
BACKUP_APP="$STAGING_ROOT/previous-$APP_NAME"

if [[ -n "$ARTIFACT_MANIFEST" ]]; then
  archive_name="$(plutil -extract archive raw -o - "$ARTIFACT_MANIFEST")"
  archive_path="$(dirname "$ARTIFACT_MANIFEST")/$archive_name"
  artifact_extract_root="$STAGING_ROOT/artifact"
  mkdir -p "$artifact_extract_root"
  ditto -x -k "$archive_path" "$artifact_extract_root"
  APP_SOURCE="$artifact_extract_root/$APP_NAME"
fi

if [[ ! -d "$APP_SOURCE" ]]; then
  printf 'App source not found: %s\n' "$APP_SOURCE" >&2
  exit 1
fi

ditto "$APP_SOURCE" "$STAGED_APP"
"$VERIFY_SCRIPT" "$STAGED_APP" >/dev/null

if [[ -e "$APP_DEST" ]]; then
  mv "$APP_DEST" "$BACKUP_APP"
fi
mv "$STAGED_APP" "$APP_DEST"
DESTINATION_REPLACED="true"

# Refresh Launch Services so Finder/Spotlight see the new ad-hoc signature on
# the existing bundle path. Without this, replacing an ad-hoc-signed app in
# place (especially under /Applications) can leave Launch Services holding the
# previous signature for this bundle id, which surfaces to the user as the
# generic "the application may be damaged or incomplete" Finder error.
# Also strip any com.apple.quarantine xattrs that ditto may have inherited
# from the staging path.
xattr -cr "$APP_DEST" >/dev/null 2>&1 || true
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -u "$APP_DEST" >/dev/null 2>&1 || true
  "$LSREGISTER" -f "$APP_DEST" >/dev/null 2>&1 || true
fi

"$VERIFY_SCRIPT" "$APP_DEST" >/dev/null
INSTALL_SUCCEEDED="true"
rm -rf "$BACKUP_APP"

printf 'Installed %s\n' "$APP_DEST"

if [[ "$OPEN_AFTER_INSTALL" == "true" ]]; then
  open_status=1
  for _ in {1..5}; do
    if open "$APP_DEST"; then
      open_status=0
      break
    fi
    sleep 0.5
  done
  if [[ "$open_status" -ne 0 ]]; then
    exit "$open_status"
  fi

  for _ in {1..40}; do
    if installed_workbench_is_running; then
      exit 0
    fi
    sleep 0.25
  done

  printf 'Installed %s did not launch from %s\n' "$WORKBENCH_APP_NAME" "$APP_DEST" >&2
  exit 1
fi
