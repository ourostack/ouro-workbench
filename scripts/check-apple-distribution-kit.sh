#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$ROOT_DIR/distribution/apple-distribution.json"
WRAPPER="$ROOT_DIR/scripts/apple-distribution-kit.sh"

fail() {
  printf 'apple distribution kit check failed: %s\n' "$1" >&2
  exit 1
}

[[ -x "$WRAPPER" ]] || fail "missing executable wrapper: scripts/apple-distribution-kit.sh"
[[ -f "$MANIFEST" ]] || fail "missing manifest: distribution/apple-distribution.json"

secret_file="$(
  find "$ROOT_DIR" \
    -path "$ROOT_DIR/.git" -prune -o \
    -path "$ROOT_DIR/.ci" -prune -o \
    -path "$ROOT_DIR/.build" -prune -o \
    -path "$ROOT_DIR/dist" -prune -o \
    -path "$ROOT_DIR/artifacts" -prune -o \
    -type f \( \
      -name '*.p8' -o \
      -name '*.p12' -o \
      -name '*.mobileprovision' -o \
      -name '*.provisionprofile' -o \
      -name '*.cer' -o \
      -name 'AuthKey_*.p8' \
    \) -print -quit
)"
[[ -z "$secret_file" ]] || fail "secret-looking Apple credential file committed: ${secret_file#$ROOT_DIR/}"

eval "$("$ROOT_DIR/scripts/read-workbench-release.sh")"

node - "$MANIFEST" "$WORKBENCH_VERSION" "$WORKBENCH_BUNDLE_IDENTIFIER" <<'NODE'
const fs = require("node:fs");

const [manifestPath, expectedVersion, expectedBundleId] = process.argv.slice(2);
const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));

function fail(message) {
  console.error(`manifest contract failed: ${message}`);
  process.exit(1);
}

if (manifest.app?.name !== "Ouro Workbench") fail("app.name must be Ouro Workbench");
if (manifest.app?.bundleId !== expectedBundleId) fail(`app.bundleId must be ${expectedBundleId}`);
if (manifest.app?.sku !== "bot-ouro-workbench-macos") fail("app.sku must be bot-ouro-workbench-macos");
if (manifest.team?.teamId !== "743GT2AJ24") fail("team.teamId must be 743GT2AJ24");

const channels = new Map((manifest.channels ?? []).map((channel) => [channel.id, channel]));
const direct = channels.get("direct-download");
if (!direct) fail("missing direct-download channel");
if (direct.platform !== "macos") fail("direct-download platform must be macos");
if (direct.distribution !== "developer-id") fail("direct-download distribution must be developer-id");
if (direct.bundleId !== expectedBundleId) fail(`direct-download bundleId must be ${expectedBundleId}`);

const store = channels.get("mac-app-store");
if (!store) fail("missing mac-app-store channel");
if (store.platform !== "macos") fail("mac-app-store platform must be macos");
if (store.distribution !== "app-store") fail("mac-app-store distribution must be app-store");
if (store.bundleId !== expectedBundleId) fail(`mac-app-store bundleId must be ${expectedBundleId}`);
if (store.store?.version !== expectedVersion) fail(`store.version must be ${expectedVersion}`);
if (store.store?.category !== "DEVELOPER_TOOLS") fail("store.category must be DEVELOPER_TOOLS");
if (store.store?.privacy?.policyUrl !== "https://ouro.bot/privacy/") fail("privacy.policyUrl must be https://ouro.bot/privacy/");

console.log("Workbench apple distribution manifest contract ok");
NODE

"$WRAPPER" manifest validate --manifest "$MANIFEST" >/dev/null
"$WRAPPER" plan --manifest "$MANIFEST" --mode dry-run --json >/dev/null
"$WRAPPER" store review-plan --manifest "$MANIFEST" --channel mac-app-store --json >/dev/null

printf 'apple distribution kit check ok\n'
