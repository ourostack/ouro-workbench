# Product Center Of Gravity Ideation

Status: planner handoff ready
Date: 2026-06-14
Branch: `worker/product-center-of-gravity`

## Spark

The felt failure is not merely the words `Local Shell`; it is the product
claim those words make. Workbench should feel like an agent-owned terminal
multiplexer and control room. A shell can exist, but only as one ordinary,
removable terminal session type inside that room.

The center must be:

- one selected Ouro boss agent owns coordination and answers what is happening,
- workspaces contain sessions,
- sessions are durable terminal/TUI processes that can be human-owned or
  agent-owned,
- first-run setup exists only to choose/create/repair the boss,
- after that, setup/import is boss-led and conversational,
- a plain shell is never a default identity, bootstrap primitive, or
  undeletable fallback.

## Observed Terrain

- `WorkbenchDefaults` still defaults to `projectName: "This Mac"` and
  `includeLocalShell: true`; normal empty-state bootstrap inserts a
  `BuiltInWorkbenchSessions.localShell` row.
- Setup-mode bootstrap already opts out with
  `WorkbenchDefaults.firstRunSetup(... includeLocalShell: false)`, which fixed
  the reset symptom but not the underlying primitive.
- `BuiltInWorkbenchSessions` names, detects, repairs, and classifies
  `Local Shell` as auto-launchable. Existing rows with that name are forcibly
  repaired back to `/bin/zsh -l`, `trusted`, and `autoResume: true`.
- App startup still calls `launchDefaultShellIfNeeded()` after startup recovery
  and auto-resume.
- The MCP server read path bootstraps state with the same defaults, so the boss
  can be shown a fabricated `Local Shell` even if the app should be reporting
  setup/no imported sessions truth.
- `CustomTerminalSessionManager.isCustomSession(_:)` returns true only for
  `.terminalAgent`, so `.shell` rows do not get normal edit/archive/delete
  actions in the sidebar context menu.
- The “New Terminal” sheet already has the right model: arbitrary command,
  optional trust/auto-resume, detected CLI identity when the command is Claude,
  Codex, or Copilot.
- Recovery and auto-launch already treat `.terminalAgent` and `.shell` as
  recoverable/launchable sessions; the bad part is not runtime support, it is
  the special built-in shell lifecycle.

## Divergent Shapes

### Boring

Rename `Local Shell` to `Terminal`, keep the built-in, and expose delete. This
would remove the screenshot sting but keep the wrong primitive: an empty
Workbench still creates a terminal row as the first object.

### Ambitious

Remove `.shell` from the model entirely and represent every terminal as
`.terminalAgent` with optional detected `agentKind`. This is clean but risks
schema churn and broad test/doc fallout for little immediate user benefit.

### Weird But Right

Keep `.shell` as a backward-compatible persisted kind, but remove built-in
shell creation/repair/auto-launch. Treat shell rows as normal managed terminal
sessions for edit/duplicate/archive/delete, and make the empty state a
workspace/session-less setup-ready state. Existing shell rows keep working,
but nothing in bootstrap or app launch asserts that a shell must exist.

## Surviving Shape

The weird-but-right shape is the thin correct move. It changes the product
center without unnecessary schema churn:

- `WorkbenchDefaults.includeLocalShell` should default false, or be renamed /
  deprecated toward no default terminal.
- Normal bootstrap creates the minimal workspace state only, with no process
  entry and no default `This Mac` workspace name.
- MCP read-only state rendering uses the same no-shell truth.
- The app stops calling `launchDefaultShellIfNeeded()` as a first-run/fallback
  path.
- `BuiltInWorkbenchSessions` loses repair/auto-launch authority; if a legacy
  `Local Shell` exists, it is just an editable/removable session.
- `CustomTerminalSessionManager` treats `.shell` rows as managed sessions and
  can produce drafts from direct executable/arguments.
- Tests/docs/scenario wording stop presenting `Local Shell` as the desired
  default. Scenario coverage may still include generic shell sessions as one
  terminal identity, but not named `Local Shell` as a canonical default.

## Scrutiny Notes

Tinfoil Hat and Stranger With Candy findings changed the implementation shape:

- Merely hiding `Local Shell` during setup is insufficient; normal empty-state
  bootstrap and startup launch can still reintroduce it.
- Removing `.shell` entirely is more churn than signal; recovery/autonomy code
  already supports it and persisted rows may exist.
- MCP read paths must also stop synthesizing default shell state; otherwise the
  boss sees a fabricated Workbench reality.
- Canonical state is the post-load JSON that bootstrap saves, so legacy shell
  rows must be preserved through load rather than repaired in place.
- `custom session` is the lying word. The capability should be thought of as
  managed terminal sessions; implementation may preserve the existing type name
  for scope, but tests must prove `.shell` rows are manageable and are not
  silently transmuted on load.
- User-owned shells may still auto-launch through the explicit
  `autoLaunchResumableOnStartup` preference. The product bug is built-in
  fallback shell creation/repair/launch, not shell support.
- `This Mac` is part of the same drift. Normal empty bootstrap should not
  create a workspace named `This Mac`; use the setup/unsorted workspace until
  imported or created work gives a better name.
- Scenario coverage should keep generic/legacy shell regression coverage without
  naming `Local Shell` as a canonical identity.

## Thin Slice

1. Add failing tests that express the center:
   - empty bootstrap creates a workspace but no terminal rows,
   - default empty bootstrap does not create `This Mac`,
   - MCP read-only current-state bootstrapping does not synthesize a shell,
   - legacy `Local Shell` is preserved, not repaired or duplicated,
   - `.shell` entries are manageable custom sessions,
   - built-in default-shell startup launch path is gone or inert,
   - scenario names/docs no longer encode `Local Shell` as default.
2. Implement minimal core/app changes to make those tests pass.
3. Update the surface spec, audit report/backlog, README/guide/roadmap lines
   that explicitly name the wrong default.
4. Run full Swift tests, scenario verifier, build/package/install, and live E2E:
   fresh launch/reset with empty support root should show setup/empty workspace
   without `Local Shell`; a manually created shell should be removable.

## Non-Goals

- No schema migration that deletes user shell sessions.
- No removal of terminal/TUI support.
- No disabling explicit user-owned shell auto-resume/recovery.
- No MCP action rename from `group` to `workspace` in this tranche unless a
  user-facing string is directly implicated.
- No split of `OuroWorkbenchApp.swift`; that remains a follow-up after the
  user-blocking center-of-gravity fix lands.

## Open Questions

None for the human. The standing product decision resolves naming/scope:
shells are ordinary terminal sessions, never the default story.

## Planner Handoff

Goal: make Workbench's default/fresh/reset path and session lifecycle enforce
the product center: boss-led agent terminal workbench, with shells as ordinary
managed sessions only.

Likely files:

- `Sources/OuroWorkbenchCore/WorkbenchBootstrapper.swift`
- `Sources/OuroWorkbenchCore/CustomTerminalSession.swift`
- `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift`
- `Sources/OuroWorkbenchCore/WorkbenchScenarioMatrix.swift`
- `Sources/OuroWorkbenchScenarioVerifier/main.swift`
- `Tests/OuroWorkbenchCoreTests/WorkbenchBootstrapperTests.swift`
- `Tests/OuroWorkbenchCoreTests/CustomTerminalSessionTests.swift`
- `docs/workbench-surface-spec.md`
- `README.md`, `docs/guide.md`, `docs/roadmap.md`, audit artifacts

Acceptance signals:

- no fresh/reset state creates or auto-launches `Local Shell`,
- no empty state creates a default `This Mac` workspace,
- MCP read-only state does not synthesize a local shell,
- any existing shell row has edit/archive/delete in normal UI,
- tests prove shell rows are preserved as user data rather than repaired into a
  built-in,
- docs no longer recommend a persistent default `Local Shell`,
- live app validation confirms the screenshot concern cannot recur.

Risks:

- Some tests currently assume the legacy default shell; update them to the new
  center rather than preserving the old behavior.
- Removing default launch must not break explicit auto-resume; preserve
  `RecoveryPlanner.autoLaunchEligibleEntries`.
- Existing persisted shell rows must keep launching/recovering.
