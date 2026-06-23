#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
eval "$("$ROOT_DIR/scripts/read-workbench-release.sh")"
VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")"
[[ "$VERSION" == "$WORKBENCH_VERSION" ]] || {
  printf 'VERSION does not match WorkbenchRelease.version\n' >&2
  exit 1
}

cat <<NOTES
# $WORKBENCH_APP_NAME $VERSION

Ouro Workbench is a native macOS workbench for terminal agents. It wraps Claude
Code, OpenAI Codex, GitHub Copilot CLI, local shells, and arbitrary terminal/TUI
agents as durable Workbench terminals, then gives a selected Ouro boss agent the
context and audited controls needed to answer what is going on and keep trusted
work moving.

## Release State

- Public ad-hoc-signed preview for macOS 14+.
- Apple Developer ID signing and notarization are not included in this release.
- The app bundle includes the native app, Workbench MCP server, SwiftTerm
  resources, terminal persistence backend, support diagnostics helper, and app
  icon.
- Force-quit and relaunch recovery is backed by persistent \`screen\` sessions.
- Computer restart recovery restores Workbench state and safely resumes,
  respawns, or flags sessions according to each terminal's trust and resume
  posture.

## Install

Download both release assets:

- \`$WORKBENCH_ARTIFACT_NAME_PREFIX$VERSION-build.<build>-<sha>.zip\`
- \`$WORKBENCH_ARTIFACT_NAME_PREFIX$VERSION-build.<build>-<sha>.manifest.json\`

Then verify and install from a repo checkout:

\`\`\`bash
scripts/verify-app-artifact.sh artifacts/$WORKBENCH_ARTIFACT_NAME_PREFIX$VERSION-build.<build>-<sha>.manifest.json
scripts/install-app.sh --artifact-manifest artifacts/$WORKBENCH_ARTIFACT_NAME_PREFIX$VERSION-build.<build>-<sha>.manifest.json --open
\`\`\`

To install the latest published release directly with GitHub CLI:

\`\`\`bash
scripts/install-latest-release.sh --open
\`\`\`

## Operator Highlights

- Cmux-style groups in the sidebar, with as many terminal tabs per group as you need.
- Known CLI identities are detected from the command, not separated into fixed tabs.
- Boss Line quick asks: "What's Going On?", "Waiting On Me?", "Keep Moving", and "Respond For Me".
- Token-aware command palette with aliases for boss actions, diagnostics, Workbench MCP, refreshes, selected-terminal controls, and release updates.
- Workbench MCP tools for status, transcript tail/search, recovery drills, and queued trusted actions.
- TTFA readiness badge for boss bridge, trust, executable health, recovery posture, Boss Watch, and Open at Login.
- Recovery Drill for non-mutating restart simulations before you trust a long autonomous run.
- Explicit Redraw, Ctrl-C, Esc, and EOF controls for operating resized shells and TUIs without silently mutating live terminal state.
- Stable icon terminal controls so the session header stays usable without clipped labels in normal-width windows.
- Stable dashboard status rows that protect controls from long diagnostics, release, recovery, MCP, and mailbox messages.
- Cleaner terminal reparenting so split and full-screen prompts redraw at the top after app reopen or focus changes.
- Bounded compact Action Log rows so long native action results do not crowd the reveal control.
- Sidebar project rows keep group names readable in narrow cmux-style navigation, with subdued add actions that no longer resemble selected terminals.
- Terminal host resize redraws keep prompts top-aligned when the boss pane is collapsed, expanded, or moved into full-screen focus.
- A small native terminal inset keeps prompts and typed commands from rendering against the host edge.
- In-app Support Diagnostics for collecting, revealing, and copying a local evidence zip without transcript contents by default.

## Verification

This release is produced by the protected release workflow after the same local
preflight gates used for development:

- Swift tests
- 5000-row scenario matrix drift check
- 25,000-pass native scenario verifier
- app bundle verification
- artifact checksum verification
- install/rollback smoke tests

NOTES
