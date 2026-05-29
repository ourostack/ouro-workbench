#!/usr/bin/env bash
#
# Ouro Workbench — one-line installer.
#
#   curl -fsSL https://ouro.bot/workbench-install.sh | bash
#
# Self-contained: needs only tools present on a stock macOS (curl, unzip/ditto,
# shasum). No git checkout, no GitHub CLI, no jq/python. Downloads the latest
# published release artifact, verifies its sha256 against the release manifest,
# installs the app, clears the download quarantine, and opens it.
#
# Env overrides:
#   OURO_WB_REPO         GitHub owner/repo        (default: ourostack/ouro-workbench)
#   OURO_WB_INSTALL_DIR  install destination dir  (default: ~/Applications)
#   OURO_WB_NO_OPEN=1    don't open the app after installing
set -euo pipefail

REPO="${OURO_WB_REPO:-ourostack/ouro-workbench}"
INSTALL_DIR="${OURO_WB_INSTALL_DIR:-$HOME/Applications}"
API="https://api.github.com/repos/${REPO}/releases?per_page=1"

say()  { printf '\033[1;36m▸\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$1" >&2; }
die()  { printf '\033[1;31m✗\033[0m %s\n' "$1" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "Ouro Workbench is macOS-only (this is $(uname -s))."
if [ "$(uname -m)" != "arm64" ]; then
  warn "Builds are Apple Silicon (arm64); on this $(uname -m) Mac the app may not launch."
fi
for tool in curl shasum ditto; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"
done

say "Finding the latest Ouro Workbench release…"
rel="$(curl -fsSL "$API")" || die "couldn't reach the GitHub release API."

# Pull the asset URLs out of the (newest) release object without jq.
zip_url="$(printf '%s' "$rel" | grep -o '"browser_download_url": *"[^"]*\.zip"' | sed 's/.*"\(https[^"]*\)"/\1/' | head -1)"
manifest_url="$(printf '%s' "$rel" | grep -o '"browser_download_url": *"[^"]*\.manifest\.json"' | sed 's/.*"\(https[^"]*\)"/\1/' | head -1)"
[ -n "$zip_url" ] || die "no .zip asset on the latest release."
[ -n "$manifest_url" ] || die "no .manifest.json asset on the latest release."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
zip_path="$tmp/$(basename "$zip_url")"

say "Downloading $(basename "$zip_url")…"
curl -fsSL "$zip_url" -o "$zip_path" || die "download failed."
manifest="$(curl -fsSL "$manifest_url")" || die "couldn't fetch the release manifest."

# Verify the archive against the sha256 recorded in the manifest.
expected="$(printf '%s' "$manifest" | grep -o '"sha256": *"[0-9a-f]*"' | sed 's/.*"\([0-9a-f]*\)"/\1/' | head -1)"
[ -n "$expected" ] || die "manifest has no sha256 to verify against."
actual="$(shasum -a 256 "$zip_path" | awk '{print $1}')"
[ "$actual" = "$expected" ] || die "checksum mismatch (expected $expected, got $actual). Aborting."
say "Checksum verified."

say "Extracting…"
ditto -x -k "$zip_path" "$tmp/extracted"
app_src="$(find "$tmp/extracted" -maxdepth 2 -name '*.app' -type d | head -1)"
[ -n "$app_src" ] || die "no .app found inside the archive."
app_name="$(basename "$app_src")"

mkdir -p "$INSTALL_DIR"
dest="$INSTALL_DIR/$app_name"
if [ -d "$dest" ]; then
  say "Replacing existing install at $dest"
  rm -rf "$dest"
fi
ditto "$app_src" "$dest"

# The download set the com.apple.quarantine xattr; the build is ad-hoc-signed
# (not yet notarized), so strip it to avoid the Gatekeeper "unidentified
# developer" / "damaged" prompt. lsregister refresh keeps Launch Services tidy.
xattr -cr "$dest" 2>/dev/null || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$dest" >/dev/null 2>&1 || true

ver="$(printf '%s' "$manifest" | grep -o '"version": *"[^"]*"' | sed 's/.*"\([^"]*\)"/\1/' | head -1)"
say "Installed ${app_name%.app} ${ver:-} → $dest"

if [ "${OURO_WB_NO_OPEN:-}" != "1" ]; then
  open "$dest" || warn "couldn't auto-open; launch it from $INSTALL_DIR."
fi

cat <<'NEXT'

Next:
  • Set up your boss agent and tools via "Set Up Workbench" (wand button / ⌘K).
  • Toggle "Open at Login" so it relaunches and recovers after a restart.
  • ⌘M backgrounds it (autonomy keeps running); ⌘W quits.
NEXT
