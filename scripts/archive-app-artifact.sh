#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
eval "$("$ROOT_DIR/scripts/read-workbench-release.sh")"
APP_DIR="$ROOT_DIR/dist/$WORKBENCH_APP_NAME.app"
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
release_signing_mode="${OURO_RELEASE_SIGNING_MODE:-}"
notarized=false

truthy() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$INFO_PLIST"
}

"$ROOT_DIR/scripts/verify-app-bundle.sh" "$APP_DIR" >/dev/null

if [[ "$release_signing_mode" == "developer-id" ]] || truthy "${OURO_REQUIRE_NOTARIZATION:-}"; then
  release_signing_mode="developer-id"
  "$ROOT_DIR/scripts/check-signing-readiness.sh"
  "$ROOT_DIR/scripts/sign-notarize-app.sh" --app "$APP_DIR" --app-name "$WORKBENCH_APP_NAME"
  notarized=true
else
  release_signing_mode="ad-hoc"
fi

version="$(plist_value CFBundleShortVersionString)"
build="$(plist_value CFBundleVersion)"
bundle_id="$(plist_value CFBundleIdentifier)"
git_sha="$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || printf 'unknown')"
short_sha="$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || printf 'unknown')"
git_dirty="false"
dirty_suffix=""
if git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if ! git -C "$ROOT_DIR" diff --quiet --ignore-submodules -- || ! git -C "$ROOT_DIR" diff --cached --quiet --ignore-submodules --; then
    git_dirty="true"
    dirty_suffix="-dirty"
  fi
fi
archive_name="$WORKBENCH_ARTIFACT_NAME_PREFIX${version}-build.${build}-${short_sha}${dirty_suffix}.zip"
manifest_name="$WORKBENCH_ARTIFACT_NAME_PREFIX${version}-build.${build}-${short_sha}${dirty_suffix}.manifest.json"
archive_path="$OUT_DIR/$archive_name"
manifest_path="$OUT_DIR/$manifest_name"

mkdir -p "$OUT_DIR"
rm -f "$archive_path" "$manifest_path"

ditto -c -k --keepParent "$APP_DIR" "$archive_path"
sha256="$(shasum -a 256 "$archive_path" | awk '{print $1}')"
bytes="$(stat -f %z "$archive_path")"
created_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

printf '{\n' > "$manifest_path"
printf '  "appName": "%s",\n' "$WORKBENCH_APP_NAME" >> "$manifest_path"
printf '  "bundleIdentifier": "%s",\n' "$bundle_id" >> "$manifest_path"
printf '  "version": "%s",\n' "$version" >> "$manifest_path"
printf '  "build": "%s",\n' "$build" >> "$manifest_path"
printf '  "gitSha": "%s",\n' "$git_sha" >> "$manifest_path"
printf '  "gitDirty": %s,\n' "$git_dirty" >> "$manifest_path"
printf '  "signingMode": "%s",\n' "$release_signing_mode" >> "$manifest_path"
printf '  "notarized": %s,\n' "$notarized" >> "$manifest_path"
printf '  "archive": "%s",\n' "$archive_name" >> "$manifest_path"
printf '  "sha256": "%s",\n' "$sha256" >> "$manifest_path"
printf '  "bytes": %s,\n' "$bytes" >> "$manifest_path"
printf '  "createdAt": "%s"\n' "$created_at" >> "$manifest_path"
printf '}\n' >> "$manifest_path"

printf 'Archived app artifact: %s\n' "$archive_path"
printf 'Wrote app artifact manifest: %s\n' "$manifest_path"
