#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Ouro Workbench.app"
INSTALL_DIR="$HOME/Applications"
OPEN_AFTER_INSTALL="false"
VERIFY_SCRIPT="$ROOT_DIR/scripts/verify-app-bundle.sh"

usage() {
  printf 'Usage: %s [--install-dir PATH] [--verify-script PATH] [--open]\n' "$(basename "$0")" >&2
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

APP_SOURCE="$ROOT_DIR/dist/$APP_NAME"
APP_DEST="$INSTALL_DIR/$APP_NAME"
STAGING_ROOT=""
STAGED_APP=""
BACKUP_APP=""
INSTALL_SUCCEEDED="false"
DESTINATION_REPLACED="false"

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

"$ROOT_DIR/scripts/package-app.sh" >/dev/null

if [[ ! -d "$APP_SOURCE" ]]; then
  printf 'Packaged app not found: %s\n' "$APP_SOURCE" >&2
  exit 1
fi
if [[ ! -x "$VERIFY_SCRIPT" ]]; then
  printf 'App verifier is not executable: %s\n' "$VERIFY_SCRIPT" >&2
  exit 64
fi

if [[ "$OPEN_AFTER_INSTALL" == "true" ]]; then
  osascript -e 'tell application id "com.ourostack.workbench" to quit' >/dev/null 2>&1 || true
  for _ in {1..20}; do
    if ! pgrep -x "OuroWorkbench" >/dev/null 2>&1; then
      break
    fi
    sleep 0.25
  done
fi

mkdir -p "$INSTALL_DIR"
STAGING_ROOT="$(mktemp -d "$INSTALL_DIR/.ouro-workbench-install.XXXXXX")"
STAGED_APP="$STAGING_ROOT/$APP_NAME"
BACKUP_APP="$STAGING_ROOT/previous-$APP_NAME"

ditto "$APP_SOURCE" "$STAGED_APP"
"$VERIFY_SCRIPT" "$STAGED_APP" >/dev/null

if [[ -e "$APP_DEST" ]]; then
  mv "$APP_DEST" "$BACKUP_APP"
fi
mv "$STAGED_APP" "$APP_DEST"
DESTINATION_REPLACED="true"

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
  exit "$open_status"
fi
