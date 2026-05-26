# Native Packaging

Ouro Workbench is a SwiftUI macOS app built through Swift Package Manager. The
packaging script creates a local `.app` bundle around the release executable.

```bash
scripts/package-app.sh
open "dist/Ouro Workbench.app"
```

For this machine, install the bundle into `~/Applications`:

```bash
scripts/install-app.sh --open
```

Install a downloaded, verified artifact directly from its manifest:

```bash
scripts/install-app.sh --artifact-manifest artifacts/OuroWorkbench-0.1.5-build.<build>-<sha>.manifest.json --open
```

Install the latest successful protected `main` artifact in one step:

```bash
scripts/install-latest-app-artifact.sh --open
```

Install the latest published GitHub Release in one step:

```bash
scripts/install-latest-release.sh --open
```

The release installer downloads the versioned zip and manifest assets from
GitHub Releases, verifies the SHA-256 manifest with the same artifact verifier,
then reuses the rollback-safe installer.

Use `--install-dir /path/to/Applications` to choose another install location.
The installer stages the new app inside the target directory, moves the previous
bundle aside, promotes the staged bundle, verifies it, and restores the previous
bundle if any pre-success install or verification step fails.

The generated bundle is intentionally local and unsigned for now. It lives under
`dist/`, which is ignored by git. The bundle includes:

- `Contents/MacOS/OuroWorkbench`
- `Contents/MacOS/OuroWorkbenchMCP`
- `Contents/MacOS/Tools/screen`, the terminal persistence backend
- `Contents/Resources/collect-support-diagnostics.sh`, the bundled support
  diagnostics helper
- `Contents/Resources/OuroWorkbench.icns`, the native app icon
- `SwiftTerm_SwiftTerm.bundle`, the embedded terminal resource bundle

`VERSION` is the source of truth for `CFBundleShortVersionString` and the
Workbench MCP `serverInfo.version`. `scripts/package-app.sh` derives the bundle
build number from the git commit count, refuses shallow git checkouts that would
produce misleading build numbers, and `scripts/verify-version-contract.sh`
guards the source version against drift.

Verify a packaged bundle with:

```bash
scripts/verify-app-bundle.sh
```

Bundle verification also runs the native executable in `--smoke-launch` mode so
missing runtime resources are caught before CI uploads the artifact.

Create a versioned zip plus manifest with SHA-256 and bundle metadata:

```bash
scripts/archive-app-artifact.sh
```

Verify a downloaded zip against its manifest, then expand and verify the app:

```bash
scripts/verify-app-artifact.sh artifacts/OuroWorkbench-0.1.5-build.<build>-<sha>.manifest.json
```

Run the full local protected-gate preflight with:

```bash
scripts/preflight.sh
```

The preflight also runs `scripts/smoke-install-rollback.sh`, which simulates an
installed-bundle verification failure and proves the previous app is restored.
It also checks the release-support helper scripts so published builds and local
bug reports use the same verified paths.

Create a local support diagnostics zip with:

```bash
scripts/collect-support-diagnostics.sh
```

The diagnostics helper can run from a repo checkout or from the installed app
bundle at `Contents/Resources/collect-support-diagnostics.sh`. The diagnostics
bundle records system, repo-or-bundle, installed app, `screen`, login item, and
workspace-state summaries. It does not copy terminal transcript contents or raw
`workspace-state.json` unless `--include-state` is passed explicitly. The native
boss dashboard exposes this as `Support Diagnostics` and can reveal the produced
zip in Finder or copy its path. Bundle verification rejects missing, empty, or
non-executable diagnostics helpers, and preflight runs the helper from the
packaged app to prove the installed path works.

The app prefers the bundled `screen` executable and falls back to `/usr/bin/screen`
only during development runs where the app bundle tool is not present. The
bundle keeps automatic and sudden termination disabled so macOS does not quietly
tear down managed terminal-agent sessions.

The main native window autosaves its frame through AppKit under the
`OuroWorkbenchMainWindow` autosave name. Relaunch should preserve the operator's
last window size and position while still enforcing the app's minimum usable
terminal workspace size.

The native app has an `Open at Login` control in the boss dashboard. It writes a
machine-local LaunchAgent at
`~/Library/LaunchAgents/com.ourostack.workbench.login.plist` that opens the
installed app at login, so app startup can trigger workspace recovery after a
computer restart. The LaunchAgent writes logs under
`~/Library/Logs/OuroWorkbench/`.

If the installed app path changes, the native status shows `update needed`
instead of treating a stale plist as healthy; toggling `Open at Login` back on
rewrites the LaunchAgent for the current bundle path.

Current bundle identity:

- Bundle name: `Ouro Workbench`
- Bundle identifier: `com.ourostack.workbench`
- Executable: `OuroWorkbench`
- Version source: `VERSION`
- Minimum macOS version: `14.0`

Public unsigned preview releases are published by `.github/workflows/release.yml`.
The workflow checks out full git history, runs `scripts/preflight.sh`, generates
release notes, and attaches the verified app zip plus manifest to a GitHub
Release. Apple Developer ID signing and notarization remain the explicit
post-preview distribution gap.

CI has a separate `App bundle` job that checks out full git history, packages
the release app, verifies the bundle contents, rejects local build-path linkage,
and uploads the unsigned app artifact for inspection. The uploaded artifact
contains a versioned zip created with `ditto --keepParent`, so downloading and
expanding it preserves the `Ouro Workbench.app` wrapper instead of flattening
the bundle contents. The manifest records the bundle identifier, version, build
number, git SHA, dirty-worktree flag, archive filename, byte size, and SHA-256 checksum.
`scripts/verify-app-artifact.sh` checks those fields against the zip and
expanded app.
