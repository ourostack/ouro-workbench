#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/dist/Ouro Workbench.app"
OUT_DIR="$ROOT_DIR/artifacts"

usage() {
  printf 'Usage: %s [--app PATH] [--out-dir PATH]\n' "$(basename "$0")" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      if [[ $# -lt 2 || -z "$2" ]]; then
        usage
        exit 64
      fi
      APP_DIR="$2"
      shift 2
      ;;
    --out-dir)
      if [[ $# -lt 2 || -z "$2" ]]; then
        usage
        exit 64
      fi
      OUT_DIR="$2"
      shift 2
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

INFO_PLIST="$APP_DIR/Contents/Info.plist"

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$INFO_PLIST"
}

"$ROOT_DIR/scripts/verify-app-bundle.sh" "$APP_DIR" >/dev/null

version="$(plist_value CFBundleShortVersionString)"
build="$(plist_value CFBundleVersion)"
bundle_id="$(plist_value CFBundleIdentifier)"
git_sha="$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || printf 'unknown')"
short_sha="$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || printf 'unknown')"
archive_name="OuroWorkbench-${version}-build.${build}-${short_sha}.zip"
manifest_name="OuroWorkbench-${version}-build.${build}-${short_sha}.manifest.json"
archive_path="$OUT_DIR/$archive_name"
manifest_path="$OUT_DIR/$manifest_name"

mkdir -p "$OUT_DIR"
rm -f "$archive_path" "$manifest_path"

ditto -c -k --keepParent "$APP_DIR" "$archive_path"
sha256="$(shasum -a 256 "$archive_path" | awk '{print $1}')"
bytes="$(stat -f %z "$archive_path")"
created_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

printf '{\n' > "$manifest_path"
printf '  "appName": "Ouro Workbench",\n' >> "$manifest_path"
printf '  "bundleIdentifier": "%s",\n' "$bundle_id" >> "$manifest_path"
printf '  "version": "%s",\n' "$version" >> "$manifest_path"
printf '  "build": "%s",\n' "$build" >> "$manifest_path"
printf '  "gitSha": "%s",\n' "$git_sha" >> "$manifest_path"
printf '  "archive": "%s",\n' "$archive_name" >> "$manifest_path"
printf '  "sha256": "%s",\n' "$sha256" >> "$manifest_path"
printf '  "bytes": %s,\n' "$bytes" >> "$manifest_path"
printf '  "createdAt": "%s"\n' "$created_at" >> "$manifest_path"
printf '}\n' >> "$manifest_path"

printf 'Archived app artifact: %s\n' "$archive_path"
printf 'Wrote app artifact manifest: %s\n' "$manifest_path"
