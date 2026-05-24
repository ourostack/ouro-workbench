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

The generated bundle is intentionally local and unsigned for now. It lives under
`dist/`, which is ignored by git. The bundle keeps automatic and sudden
termination disabled so macOS does not quietly tear down managed terminal-agent
sessions.

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
