#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Ouro Workbench.app"
INSTALL_DIR="$HOME/Applications"
OPEN_AFTER_INSTALL="false"

usage() {
  printf 'Usage: %s [--install-dir PATH] [--open]\n' "$(basename "$0")" >&2
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

"$ROOT_DIR/scripts/package-app.sh" >/dev/null

if [[ ! -d "$APP_SOURCE" ]]; then
  printf 'Packaged app not found: %s\n' "$APP_SOURCE" >&2
  exit 1
fi

mkdir -p "$INSTALL_DIR"
rm -rf "$APP_DEST"
ditto "$APP_SOURCE" "$APP_DEST"

printf 'Installed %s\n' "$APP_DEST"

if [[ "$OPEN_AFTER_INSTALL" == "true" ]]; then
  open "$APP_DEST"
fi
