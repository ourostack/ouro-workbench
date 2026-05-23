# Native Packaging

Ouro Workbench is a SwiftUI macOS app built through Swift Package Manager. The
packaging script creates a local `.app` bundle around the release executable.

```bash
scripts/package-app.sh
open "dist/Ouro Workbench.app"
```

The generated bundle is intentionally local and unsigned for now. It lives under
`dist/`, which is ignored by git. The bundle keeps automatic and sudden
termination disabled so macOS does not quietly tear down managed terminal-agent
sessions.

Current bundle identity:

- Bundle name: `Ouro Workbench`
- Bundle identifier: `com.ourostack.workbench`
- Executable: `OuroWorkbench`
- Minimum macOS version: `14.0`

Before distributing beyond this machine, add signing, notarization, a real icon,
and release versioning.
