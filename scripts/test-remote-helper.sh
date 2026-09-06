#!/bin/zsh
set -euo pipefail

repo_root=${0:A:h:h}
helper=${1:-$repo_root/.build/debug/OuroWorkbenchRemote}
helper=${helper:A}
fixtures=$repo_root/Tests/Fixtures/RemoteHelper
test_root=$(mktemp -d /tmp/ouro-remote-helper.XXXXXX)
export LLVM_PROFILE_FILE="$test_root/helper-%p.profraw"
cleanup() {
  chmod -R u+rwX "$test_root" 2>/dev/null || true
  rm -rf "$test_root"
}
trap cleanup EXIT
chmod 700 "$test_root"

mkdir -m 700 "$test_root/copilot" "$test_root/copilot/personal" "$test_root/copilot/personal/hooks" "$test_root/gh" "$test_root/gh/personal" "$test_root/git" "$test_root/git/personal" "$test_root/ledger" "$test_root/map" "$test_root/shims"
config=$test_root/profiles.json
session_map=$test_root/map/session-map.json
ledger=$test_root/ledger
hook_wrapper=$test_root/copilot/personal/hooks/ouro-session-map-hook

printf '%s\n' \
  '{' \
  '  "schemaVersion": 1,' \
  '  "profiles": [' \
  '    {' \
  '      "id": "personal",' \
  '      "githubLogin": "arimendelow",' \
  '      "displayLabel": "Personal",' \
  '      "displayColor": "#6F42C1",' \
  "      \"copilotHome\": \"$test_root/copilot/personal\"," \
  "      \"ghConfigDir\": \"$test_root/gh/personal\"," \
  "      \"gitConfigGlobal\": \"$test_root/git/personal/config\"," \
  '      "allowedGitHubOwners": ["arimendelow", "ourostack"],' \
  '      "commitName": "Ari Mendel",' \
  '      "commitEmail": "ari@example.test",' \
  "      \"copilotExecutable\": \"$fixtures/fake-copilot\"," \
  "      \"ghExecutable\": \"$fixtures/fake-gh\"," \
  "      \"gitExecutable\": \"$fixtures/fake-git\"," \
  "      \"herdrExecutable\": \"$fixtures/fake-herdr\"," \
  '      "zshExecutable": "/bin/zsh",' \
  "      \"deskRoot\": \"$repo_root\"," \
  '      "workerID": "desk:worker",' \
  '      "continuationCap": 100,' \
  '      "remote": true,' \
  '      "autonomy": true' \
  '    }' \
  '  ]' \
  '}' > "$config"
chmod 600 "$config"

printf '%s\n' \
  '#!/bin/sh' \
  "exec '$helper' session-map-hook --config '$config' --session-map '$session_map' --ledger '$ledger' --official-hook '$fixtures/official-hook'" \
  > "$hook_wrapper"
chmod 700 "$hook_wrapper"
ln -s "$helper" "$test_root/shims/gh"
ln -s "$helper" "$test_root/shims/git"

mkdir -m 700 "$test_root/real-zdotdir"
mkdir -m 755 "$test_root/bootstrap-symlink-target"
ln -s "$test_root/bootstrap-symlink-target" "$test_root/bootstrap-symlink-output"
if "$helper" shell-bootstrap \
  --output "$test_root/bootstrap-symlink-output" \
  --zsh /bin/zsh \
  --real-zdotdir "$test_root/real-zdotdir" \
  --helper "$helper" \
  --config "$config" \
  --session-map "$session_map" >/dev/null 2>&1; then
  print -u2 'shell bootstrap accepted a symbolic-link output directory'
  exit 83
fi
if [[ "$(stat -f '%Lp' "$test_root/bootstrap-symlink-target")" != 755 ]]; then
  print -u2 'shell bootstrap mutated a symbolic-link target before rejecting it'
  exit 84
fi
"$helper" shell-bootstrap \
  --output "$test_root/ouro-zdotdir" \
  --zsh /bin/zsh \
  --real-zdotdir "$test_root/real-zdotdir" \
  --helper "$helper" \
  --config "$config" \
  --session-map "$session_map"
env \
  ZDOTDIR="$test_root/ouro-zdotdir" \
  HERDR_ENV=1 \
  HERDR_SESSION=ouro-fixture \
  HERDR_PANE_ID=w1:p1 \
  /bin/zsh -d -i -c '[[ "$(whence -w copilot)" == "copilot: function" ]]'
jq -e --arg helper "$helper" --arg map "$session_map" --arg zdotdir "$test_root/ouro-zdotdir" '
  .schemaVersion == 1 and
  .generation == "ouro-fixture" and
  .paneID == "w1:p1" and
  .helperPath == $helper and
  .sessionMapPath == $map and
  .zdotdir == $zdotdir and
  .zshExecutable == "/bin/zsh" and
  (.functionSHA256 | test("^[0-9a-f]{64}$"))
' "$test_root/map/wrapper-ready/ouro-fixture/w1:p1.json" >/dev/null

env \
  HERDR_ENV=1 \
  HERDR_SOCKET_PATH="$test_root/herdr.sock" \
  HERDR_PANE_ID=w1:p1 \
  HERDR_WORKSPACE_ID=w1 \
  HERDR_TAB_ID=w1:t1 \
  HERDR_SESSION=ouro-fixture \
  HERDR_BIN_PATH="$fixtures/fake-herdr" \
  GH_TOKEN=ambient-gh-sentinel \
  GITHUB_TOKEN=ambient-github-sentinel \
  COPILOT_GITHUB_TOKEN=ambient-copilot-sentinel \
  "$helper" launch \
    --config "$config" \
    --ledger "$ledger" \
    --profile personal \
    --generation ouro-fixture \
    --pane w1:p1 \
    --shim-directory "$test_root/shims" \
    --json \
    -- 'fixture prompt'

jq -e '.entries == [{"generation":"ouro-fixture","paneID":"w1:p1","profileID":"personal","sessionID":"11111111-1111-4111-8111-111111111111"}]' "$session_map" >/dev/null
jq -e '.phase == "exited" and .exitStatus == 0 and .hookSessionID == "11111111-1111-4111-8111-111111111111"' "$ledger/attempts/"*.json >/dev/null
test -f "$test_root/copilot/personal/official-hook-ran"
test "$(stat -f '%Lp' "$session_map")" = 600
test "$(stat -f '%Lp' "$ledger")" = 700

env \
  HERDR_ENV=1 \
  HERDR_SOCKET_PATH="$test_root/herdr.sock" \
  HERDR_PANE_ID=w1:p1 \
  HERDR_WORKSPACE_ID=w1 \
  HERDR_TAB_ID=w1:t1 \
  HERDR_SESSION=ouro-fixture \
  HERDR_BIN_PATH="$fixtures/fake-herdr" \
  "$fixtures/pty-interrupt.py" \
    "$test_root/copilot/personal/interrupt-ready" \
    "$helper" launch \
      --config "$config" \
      --ledger "$ledger" \
      --profile personal \
      --generation ouro-fixture \
      --pane w1:p1 \
      --shim-directory "$test_root/shims" \
      -- 'interrupt fixture'

jq -s -e 'map(select(.phase == "exited" and (.exitStatus == 2 or .exitStatus == 130) and .hookSessionID == "11111111-1111-4111-8111-111111111111")) | length == 1' "$ledger/attempts/"*.json >/dev/null
jq -s -e 'all(.phase == "exited")' "$ledger/attempts/"*.json >/dev/null
test -z "$(find "$ledger/locks" -type f -print -quit)"

relay_state=$test_root/relay-supervisor.json
printf '%s\n' '{"schema":1,"status":"tripped","failures":5,"reason":"fixture","updated_at":"2026-09-06T00:00:00Z"}' > "$relay_state"
chmod 600 "$relay_state"
doctor_output=$(
  "$helper" doctor \
    --config "$config" \
    --relay-state "$relay_state" \
    --json
)
printf '%s' "$doctor_output" | jq -e '.checks[] | select(.name == "mobile-relay") | .state == "tripped"' >/dev/null

if rg -l 'ambient-(gh|github|copilot)-sentinel|fixture-profile-token' "$test_root" >/dev/null; then
  print -u2 'secret sentinel persisted in helper fixture state'
  exit 82
fi
print 'remote helper account/session/shim smoke ok'
