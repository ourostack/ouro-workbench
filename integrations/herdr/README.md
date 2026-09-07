# Herdr integration

This directory is the sealed Workbench-side adapter for the Ouro mobile control plane. Herdr remains the canonical owner of terminal sessions and panes; Workbench contributes the hardened `OuroWorkbenchRemote` helper, checksummed adapter scripts, pinned dependency metadata, and a read-only health view.

`scripts/package-app.sh` copies these static files into `Ouro Workbench.app/Contents/Resources/integrations/herdr/static` and builds an exact-revision Remote artifact at `.../herdr/runtime`. The app signature seals both directories. `SHA256SUMS` independently pins every static integration file except itself.

Install the bundled helper into a versioned runtime with:

```bash
"/Applications/Ouro Workbench.app/Contents/Resources/integrations/herdr/static/install.sh" "/Applications/Ouro Workbench.app" "$HOME/.local/share/ouro-mobile-control-plane/runtime/workbench"
```

The adapter verifies the whole app signature, its static checksums, and the nested artifact manifest before delegating to the hardened helper. It never downloads code or accepts credentials. Rollback uses the sibling `uninstall.sh`; the helper deliberately retains a revision while it is current or referenced by a native session.

Profiles conform to `profiles.schema.json`. Keep the resulting registry in a private `0600` file and each credential directory at `0700`; never put credentials in this integration directory.
