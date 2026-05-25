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

Use `--install-dir /path/to/Applications` to choose another install location.
The installer stages the new app inside the target directory, moves the previous
bundle aside, promotes the staged bundle, verifies it, and restores the previous
bundle if any pre-success install or verification step fails.

The generated bundle is intentionally local and unsigned for now. It lives under
`dist/`, which is ignored by git. The bundle includes:

- `Contents/MacOS/OuroWorkbench`
- `Contents/MacOS/OuroWorkbenchMCP`
- `Contents/MacOS/Tools/screen`, the terminal persistence backend

Verify a packaged bundle with:

```bash
scripts/verify-app-bundle.sh
```

Run the full local protected-gate preflight with:

```bash
scripts/preflight.sh
```

The preflight also runs `scripts/smoke-install-rollback.sh`, which simulates an
installed-bundle verification failure and proves the previous app is restored.

The app prefers the bundled `screen` executable and falls back to `/usr/bin/screen`
only during development runs where the app bundle tool is not present. The
bundle keeps automatic and sudden termination disabled so macOS does not quietly
tear down managed terminal-agent sessions.

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
- Minimum macOS version: `14.0`

Before distributing beyond this machine, add signing, notarization, a real icon,
and release versioning.

CI has a separate `App bundle` job that packages the release app, verifies the
bundle contents, rejects local build-path linkage, and uploads the unsigned app
artifact for inspection. The uploaded artifact is a zip created with
`ditto --keepParent`, so downloading and expanding it preserves the
`Ouro Workbench.app` wrapper instead of flattening the bundle contents.
