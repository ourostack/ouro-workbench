# Control-Action Audit (Unit 0a)

**Verdict: all present, no new action kind needed.**

The boss can already issue every control action this project needs (archive / restore /
createGroup / createTerminal / moveSession), end to end — model → validation → app apply.
No gap exists; nothing is appended to Slice 7.

## Evidence

### `BossWorkbenchActionKind` (`Sources/OuroWorkbenchCore/BossWorkbenchAction.swift:3`)
All required kinds are members of the enum:
- `createGroup` (line 8)
- `createTerminal` (line 9)
- `createSession` (line 10)
- `moveSession` (line 11)
- `archive` (line 13)
- `restore` (line 14)

(Plus `launch`, `recover`, `terminate`, `sendInput`, `setTrust`, `setAutoResume`, and the
onboarding-remediation kinds — out of scope for this audit.)

### Queue validation (`BossWorkbenchAction.validateForQueueing`, same file, ~214)
Each control action has a validation arm:
- `archive` / `restore` / `moveSession` require an `entry` (line 216–219).
- `moveSession` additionally requires a target `group` (line 254–257 →
  `missingGroupForMoveSession`).
- `createGroup` requires `name` + `workingDirectory` (line 230–236).
- `createTerminal` requires `name` + `command` (line 237–243).
- `createSession` requires `name` + `command` + `owner` (line 244–253).

### App apply path (`applyBossAction`, `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift:14695`)
Every kind is dispatched to a real handler (no fall-through no-ops):
- `createGroup` → `createGroup(name:rootPath:)` (line 14732).
- `createTerminal` → `createCustomSession(_:in:launchAfterCreate:)` (line 14737).
- `createSession` → `createCustomSession(_:in:launchAfterCreate:owner:)` with
  `.agent(name:)` owner (line 14753).
- `moveSession` → `moveSession(_:to:recordNativeAction:)`, guarded against running
  sessions (line 14890).
- `archive` → `archiveCustomSession(_:recordNativeAction:)`, guarded against running
  sessions + post-condition check on `isArchived` (line 14919).
- `restore` → `restoreCustomSession(_:recordNativeAction:)`, post-condition check on
  `isArchived == false` (line 14928).

All handlers exist with matching signatures:
`createGroup` (11411), `moveSession` (11508), `createCustomSession` (14481),
`archiveCustomSession` (14587), `restoreCustomSession` (14613).

## Conclusion
The full control-action surface (archive / restore / group-create / terminal-create /
session-create / move) is implemented at all three layers. The grounding expectation ("no
gap") holds. **No new TDD unit is appended to Slice 7.**
