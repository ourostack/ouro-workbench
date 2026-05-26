#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_MODE="false"
if [[ "$(basename "$SCRIPT_DIR")" == "Resources" && -f "$SCRIPT_DIR/../Info.plist" ]]; then
  BUNDLE_MODE="true"
  CONTENTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
  ROOT_DIR="$CONTENTS_DIR"
  APP_PATH="$(cd "$CONTENTS_DIR/.." && pwd)"
  OUT_ROOT="$HOME/Library/Application Support/OuroWorkbench/support-diagnostics"
else
  ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
  OUT_ROOT="$ROOT_DIR/artifacts/support-diagnostics"
  APP_PATH="$HOME/Applications/Ouro Workbench.app"
fi
INCLUDE_STATE="false"

usage() {
  cat <<'USAGE'
Usage: collect-support-diagnostics.sh [options]

Create a local support diagnostics zip. By default this records summaries only:
no transcript contents and no raw workspace state.

Options:
  --out DIR          Output directory (repo: artifacts/support-diagnostics; app: Application Support)
  --app PATH         Installed app path (default: current bundle or ~/Applications/Ouro Workbench.app)
  --include-state    Copy raw workspace-state.json into the diagnostics bundle
  -h, --help         Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)
      if [[ $# -lt 2 || -z "$2" ]]; then
        usage >&2
        exit 64
      fi
      OUT_ROOT="$2"
      shift 2
      ;;
    --app)
      if [[ $# -lt 2 || -z "$2" ]]; then
        usage >&2
        exit 64
      fi
      APP_PATH="$2"
      shift 2
      ;;
    --include-state)
      INCLUDE_STATE="true"
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

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$OUT_ROOT"
OUT_ROOT="$(cd "$OUT_ROOT" && pwd)"
bundle_name="ouro-workbench-diagnostics-$timestamp"
bundle_dir="$OUT_ROOT/$bundle_name"
zip_path="$OUT_ROOT/$bundle_name.zip"
app_support="$HOME/Library/Application Support/OuroWorkbench"
state_path="$app_support/workspace-state.json"

rm -rf "$bundle_dir" "$zip_path"
mkdir -p "$bundle_dir"

run_capture() {
  local output_file="$1"
  shift
  {
    printf '$'
    printf ' %q' "$@"
    printf '\n\n'
    "$@"
  } >"$bundle_dir/$output_file" 2>&1 || true
}

{
  printf 'generated_at_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'mode=%s\n' "$([[ "$BUNDLE_MODE" == "true" ]] && printf 'bundle' || printf 'repo')"
  printf 'root=%s\n' "$ROOT_DIR"
  printf 'app_path=%s\n' "$APP_PATH"
  printf 'app_support=%s\n' "$app_support"
  printf 'raw_state_included=%s\n' "$INCLUDE_STATE"
} >"$bundle_dir/manifest.txt"

run_capture "system.txt" sw_vers
run_capture "uname.txt" uname -a

{
  printf 'version='
  if [[ -f "$ROOT_DIR/VERSION" ]]; then
    tr -d '[:space:]' < "$ROOT_DIR/VERSION"
  elif [[ -f "$APP_PATH/Contents/Info.plist" ]]; then
    /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist" 2>/dev/null || printf 'unknown'
  else
    printf 'unknown'
  fi
  printf '\n'
  if git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$ROOT_DIR" rev-parse --show-toplevel 2>/dev/null || true
    git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || true
    git -C "$ROOT_DIR" status --short --branch 2>/dev/null || true
  else
    printf 'git=unavailable\n'
  fi
} >"$bundle_dir/repo.txt"

if [[ -d "$APP_PATH" ]]; then
  {
    printf 'app=%s\n\n' "$APP_PATH"
    /usr/libexec/PlistBuddy -c 'Print' "$APP_PATH/Contents/Info.plist" 2>/dev/null || true
    printf '\n-- spctl --\n'
    spctl -a -vv "$APP_PATH" 2>&1 || true
    printf '\n-- codesign --\n'
    codesign -dv "$APP_PATH" 2>&1 || true
    printf '\n-- bundle verifier --\n'
    if [[ -x "$ROOT_DIR/scripts/verify-app-bundle.sh" ]]; then
      "$ROOT_DIR/scripts/verify-app-bundle.sh" "$APP_PATH" --gui-smoke-timeout 3 2>&1 || true
    else
      printf 'repo bundle verifier unavailable from this diagnostics helper\n'
    fi
  } >"$bundle_dir/app-bundle.txt"
else
  printf 'Installed app bundle not found at %s\n' "$APP_PATH" >"$bundle_dir/app-bundle.txt"
fi

if [[ -f "$state_path" ]]; then
  {
    printf 'state_path=%s\n' "$state_path"
    printf 'state_bytes='
    wc -c < "$state_path" | tr -d '[:space:]'
    printf '\n'
    if command -v ruby >/dev/null 2>&1; then
      ruby -rjson -e '
        data = JSON.parse(File.read(ARGV[0]))
        entries = data["processEntries"] || []
        runs = data["processRuns"] || []
        projects = data["projects"] || []
        counts = ->(items, key) {
          items.each_with_object(Hash.new(0)) { |item, acc| acc[item[key] || "nil"] += 1 }
        }
        puts "schemaVersion=#{data["schemaVersion"]}"
        puts "boss=#{data.dig("boss", "agentName")}"
        puts "bossWatchEnabled=#{data["bossWatchEnabled"]}"
        puts "bossPaneCollapsed=#{data["bossPaneCollapsed"]}"
        puts "projects=#{projects.length}"
        puts "processEntries=#{entries.length}"
        puts "processRuns=#{runs.length}"
        puts "entriesByKind=#{counts.call(entries, "kind")}"
        puts "entriesByTrust=#{counts.call(entries, "trust")}"
        puts "entriesByAttention=#{counts.call(entries, "attention")}"
        puts "runsByStatus=#{counts.call(runs, "status")}"
      ' "$state_path"
    else
      printf 'ruby unavailable; JSON summary skipped\n'
    fi
  } >"$bundle_dir/workspace-state-summary.txt" 2>&1
  if [[ "$INCLUDE_STATE" == "true" ]]; then
    cp "$state_path" "$bundle_dir/workspace-state.json"
  fi
else
  printf 'Workspace state not found at %s\n' "$state_path" >"$bundle_dir/workspace-state-summary.txt"
fi

{
  if [[ -d "$app_support" ]]; then
    find "$app_support" -maxdepth 4 -type f -print | sed "s#^$HOME#~#"
  else
    printf 'App support directory not found: %s\n' "$app_support"
  fi
} >"$bundle_dir/app-support-files.txt"

{
  printf -- '-- screen sessions --\n'
  screen -ls 2>&1 || true
  printf '\n-- login item --\n'
  launchctl print "gui/$(id -u)/com.ourostack.workbench.login" 2>&1 || true
  printf '\n-- recent crash reports --\n'
  find "$HOME/Library/Logs/DiagnosticReports" \
    \( -name 'Ouro Workbench*.crash' -o -name 'OuroWorkbench*.crash' \) \
    -maxdepth 1 -type f -print 2>/dev/null | tail -n 10 || true
} >"$bundle_dir/runtime.txt"

(
  cd "$OUT_ROOT"
  ditto -c -k --keepParent "$bundle_name" "$zip_path"
)

printf 'Wrote diagnostics: %s\n' "$zip_path"
