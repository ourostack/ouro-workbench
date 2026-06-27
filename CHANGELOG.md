# Changelog

## 0.1.182 - Coverage-gate flake fix (MailboxClient)

- Internal: adds a deterministic test for the mailbox default-loader success path and allowlists a single CI-toolchain-synthesized resume-after-await region that flakily fails to register coverage (same class as the existing DaemonLiveness entry). No user-facing behavior change.

## 0.1.181 - Disclosure-panel coverage tightening

- Internal: the agent/session detail inspectors, the session transcript sheet, and the Harness Status refresh-in-flight state are now driven to test coverage via injectable initial-state seams. No user-facing behavior change — every panel still starts collapsed.

## 0.1.180 - Login-item coverage tightening

- Internal: the "Open at Login" controller and its boss-pane row (status line, enable/disable, error reporting) are now driven to test coverage by injecting the login-item plist handler behind a seam, so the state transitions and error path are exercised hermetically. No user-facing behavior change.

## 0.1.179 - Boss-pane Advanced coverage tightening

- Internal: the boss pane's expanded "Advanced" section is now driven to test coverage by adding an injectable initial-state seam, so the expanded render (watch status, agent manager, transcript search, runtime, release, recovery drill, action log) is exercised. No user-facing behavior change — the pane still starts collapsed.

## 0.1.178 - Directory-picker coverage tightening

- Internal: the "Choose" directory pickers in the New/Edit Terminal and Workspace sheets are now driven to test coverage by injecting the `NSOpenPanel` behind a seam, so the post-selection value-flow is exercised without a live modal. No user-facing behavior change — production still opens the real panel.

## 0.1.177 - Menu-bar controller coverage tightening

- Internal: the menu-bar status-item controller (its icon refresh, menu rebuild, and Show/Jump/Recovery/Watch/Check-In actions) is now driven to 100% test coverage via direct unit tests on a freshly-constructed controller. No user-facing behavior change — only the controller's `init` visibility was widened so tests can isolate it from the singleton.

## 0.1.175 - Menu-command coverage tightening

- Internal: the global menu-bar command dispatch (`⌘`-shortcuts for new terminal, command palette, split panes, font size, rename, etc.) is now driven to 100% test coverage by extracting its switch into a directly-testable free function. No user-facing behavior change — the extraction is byte-identical to the prior dispatch.

## 0.1.174 - Shared shell dependency refresh

- Internal: refreshes the pinned `ouro-native-apple-app-shell` revision to keep Workbench dogfooding the current shared native app shell. No user-facing behavior change.

## 0.1.155 - Workbench visibility plane

- Adds a read-only `workbench_visibility` MCP tool and native boss-pane visibility strip that combine Workbench session/decision counts with the selected Ouro agent's durable Work Card. Unknown claim verification state is represented explicitly as unavailable/unknown rather than false zeroes, and redacted Work Card next-action summaries are not expanded in Workbench output.

## 0.1.154 - Daemon cold-start verify polling

- The first-run daemon spine no longer reports a false "manual recovery required" while a freshly-started daemon is still coming up. When the boss check-in finds the Ouro daemon down, Workbench spawns it detached and now **polls** the verify probe for a bounded window (~10s) instead of taking a single immediate reading — so a daemon that needs a moment to bind its socket (a Node cold start, or the one-time `ouro` self-update download on the first launch after a new release) is correctly recognized as recovered ("Waking your agent…") rather than misclassified as unrecoverable. The honest "isn't responding yet" line still surfaces, but only after the daemon genuinely fails to come up within the budget.

## 0.1.153 - Workbench tools via runtime injection (no bundle entry)

- The boss agent now receives the Workbench MCP (`ouro_workbench`) at **runtime**, injected by the daemon for the boss's turn when Workbench launches it — nothing is written into the agent's git-synced bundle. This fixes a class of bugs where the `ouro_workbench` entry (a machine-specific binary path) was written into `agent.json`, then synced to your other machines where the path was wrong, drifted from the boss selection (boss on one agent, the MCP registration stranded on another), and survived a Workbench factory-reset because it lived outside Workbench's own state. Workbench now passes `ouro mcp-serve --agent <boss> --workbench-mcp <path>` (a coordinated `ouro` change adds the flag and merges the server per-turn/per-agent, never globally — no cross-agent tool leak), stops writing the bundle, and cleans up any stale `ouro_workbench`/`senses.workbench` entries it finds. One boss per machine; the boss is the only agent Workbench hands its tools to.

## 0.1.152 - Agent-driven first-run

- First-run no longer asks you to be the agent's hands. When the boss check-in finds the Ouro daemon down, Workbench now starts it itself — detached, so it survives Workbench quitting — and surfaces "Waking your agent…" instead of the old raw `Check-in failed: …Start it with ouro up` error; the Harness Status "Run ouro up" pane is gone too, replaced by an app-executed "Bring back online". Onboarding readiness is now daemon- and credential-aware, and the boss agent can drive its own setup through a named, audited onboarding-action family (`repairAgent`, `verifyProvider`, `refreshProvider`, `selectLane`, `registerWorkbenchMCP`, `ensureDaemon`) issued via `workbench_request_action` — each runs headlessly and classifies its result from a post-command verify probe, never an exit code — plus a `workbench_onboarding_status` read tool. A native cold-start bootstrap (ensure daemon → ensure a healthy agent → register Workbench MCP) drives a fresh machine and hands the wheel to the agent the instant it answers an MCP round-trip; the single human touchpoint is a native provider-config form whose credential goes straight to `ouro hatch` argv, never through the agent's context. The onboarding repair steps that used to spawn a terminal pane for you to drive now run app-executed. Closes a pre-existing gap where entry-less boss actions skipped authorization, while leaving the existing `sendInput` destructive-input safety floor intact.

## 0.1.151 - Glanceable per-session chip

- Each sidebar session row now carries a glanceable chip so the operator can tell what an agent is doing without opening its terminal: a health glyph (with an amber "stalled" state when a session looks busy but its output has gone quiet), a `done/total · current-step` todo mini, and a token/$ metric. The structured facets are derived from the agent's own JSONL transcript — not by scraping the PTY — via a new bounded, redacted `SessionActivityReader` (Claude Code `~/.claude/projects/<encoded-cwd>/<session>.jsonl`, with Codex rollout coverage for tokens/last-activity). It tails only the last ~256 KB, de-duplicates token usage by assistant message id, and never surfaces raw tool inputs/outputs. Refresh mirrors the git-status plumbing (off the main actor, throttled to skip dormant sessions); sessions with no mapped transcript render only the free health facet, never empty.

## 0.1.150 - Decision inbox

- The boss decision log is now a prioritized, triageable **decision inbox**: ⌘K → "Decision Inbox" (and the boss pane) open a focused queue of only the sessions that need you — escalations, holds, and blocked auto-advances — grouped by severity (critical/destructive-or-secret first, then routine escalations) and capped at the few open items, never the full 200-row log. Each item gains **Acknowledge / Snooze (1h, end of day, 1 day) / Resolve** controls next to the existing Teach control; a snoozed item resurfaces on its own when the snooze elapses. A toggle drops to the full chronological log for auditing. ⌘J now walks the inbox in priority order (most severe first, snoozed/resolved skipped), falling through to any live waiting session the boss hasn't recorded a decision for yet. Triage state is additive in workspace state (decoded if-present, no schema bump), so existing state loads with everything open.

## 0.1.149 - Split layout persistence

- A two-up detail split now survives relaunch: the split axis + the secondary pane's session are saved in workspace state (additive, no schema change) and restored on launch, degrading gracefully to a single pane if the secondary session is gone. (Multi-window and recursive splits remain follow-ups — see `_planning/w5-split-panes-multiwindow.md`.)

## 0.1.148 - Split panes (increment 1)

- The detail pane can now be split two-up (Split Right / Split Down) to watch two agent terminals side-by-side, with Close Pane and Focus Other Pane; the focused pane receives keyboard input and is the target of selected-session commands. A session shows in at most one pane. (In-memory for now; layout persistence and recursive/multi-window splits are follow-ups — see `_planning/w5-split-panes-multiwindow.md`.)

## 0.1.147 - Terminal & startup reliability

- Transcript writes no longer block the main actor on the PTY output hot-path: `TranscriptRecorder` now writes on a private serial queue (order preserved, flushed on close), so a chatty agent TUI or slow disk can't jank the UI.
- "Auto-launch resumable terminals on startup" now actually launches: the eligibility filter excluded every entry (it deduped against all recovery plans, including no-op ones); it now dedups only against entries startup-recovery handled, so a fresh autoResume session launches as intended.
- `screen -X quit` on session termination is now bounded by the same 1.5s watchdog as the other `screen` calls, so a wedged screen socket can't leak a stuck process.

## 0.1.146 - Sync MCP tools doc table

- `docs/guide.md`'s "Workbench MCP exposes" table now lists `workbench_sessions` and `workbench_create_session` (it had drifted), with a test (`WorkbenchGuideTests.testGuideDocListsEveryBossTool`) guarding against future drift from `WorkbenchGuide.bossTools`. The table is hand-maintained, not generated; the `WorkbenchGuide` doc-comment no longer claims the doc renders from the shared markdown.

## 0.1.145 - Decision marker parse robustness

- The boss decision marker fallback (`OURO_WORKBENCH_DECISIONS:` without a fenced block) now parses only the balanced JSON value, so trailing prose after the JSON no longer silently drops the whole decision batch — matching the fix already applied to the action marker in 0.1.142.

## 0.1.144 - Boss action exactly-once durability

- A boss reply that comes back empty after the boss already queued actions is no longer retried into duplicate actions: the action-request queue de-duplicates identical pending requests, and the check-in only retries an empty reply when the turn queued nothing.
- Queued boss actions are no longer lost if the app crashes between draining and applying them: `drain()` moves requests to a `processing/` holding area and they're deleted only after the app confirms it applied them, with unconfirmed actions recovered on next launch (at-least-once instead of at-most-once).

## 0.1.143 - Boss auto-advance safety hardening

- The boss can no longer auto-answer a destructive/secret-bearing terminal prompt via the actions channel: `applyBossAction`'s sendInput now classifies the live terminal prompt (not just the input text) through the same safety gate the decisions channel uses, withholding + escalating unsafe inputs. Fixes a hole where `{"action":"sendInput","text":"y"}` to a `rm -rf? [y/N]` prompt sailed through.
- A boss reply that emits both a sendInput action and an autoAdvance decision for the same session no longer double-sends the keystroke.
- The prompt safety classifier now normalizes whitespace before matching, so `rm  -rf` / tab-separated variants can't evade the destructive-command floor.

## 0.1.142 - Schema & parse robustness

- A session whose persisted `owner` has an unrecognized kind (forward schema drift) now decodes to the human operator instead of throwing — which previously dropped the entire session row via the failable decoder. Brings `SessionOwner` in line with every other persisted enum's unknown-value fallback.
- The boss action/decision marker fallback (`OURO_WORKBENCH_ACTIONS:` without a fenced block) now parses only the balanced JSON value, so trailing prose after the JSON no longer silently drops the whole batch.

## 0.1.141 - MCP server hardening

- `workbench_status` (and transcript search) no longer crash the MCP server when the workspace state contains duplicate session IDs — entries are de-duplicated by id during bootstrap, and the affected dictionaries use a collision-safe builder. Keeps the read-only server resilient to a malformed/torn state file.
- `workbench_sense` now lists the `workbench_sessions` tool (shipped in 0.1.138) so a boss relying on the sense contract knows the machine-readable session query exists.

## 0.1.139 - Owner-aware boss check-in

- The boss check-in now surfaces each session's owner and treats agent-owned sessions (owner:agent:<name>) as driven by their owning agent — the boss no longer proposes advancing them, and `workbench_status` no longer inlines their waiting prompts for the boss to act on. Correctness groundwork for coding-session unification, where agents create sessions via `workbench_create_session`. Human-owned sessions are unaffected.

## 0.1.138 - Machine-readable session contract (coding-session unification)

- New `workbench_sessions` MCP tool returns structured JSON for programmatic clients — `{sessions:[{id,name,group,owner,kind,status,attention,needsHuman,trust,pid,exitCode,workingDirectory,startedAt,…}]}` — so an outbound client (the Ouro harness driving coding sessions through Workbench terminals) can resolve a freshly-created session's id by `name` and poll its `status`/`attention`/`needsHuman` without scraping the boss's human-readable `workbench_status` prompt. Supports `owner` / `name` / `includeArchived` filters.
- `workbench_request_action` and `workbench_create_session` gain an opt-in `format:"json"` for structured acknowledgements (`{ok,message,requestId}` / `{queued,name,group,owner,requestId}`). The boss still receives human-readable text by default — no regression.
- Foundation for routing the harness's `coding_*` tools through Workbench terminals (boundary B3, unified sessions): one session model, one set of tools, every coding session first-class and human-visible.

## 0.1.137 - Harness control actions

- The Harness Status view gains confirm-gated actions: Repair/start the ouro daemon when it's degraded, and register the Workbench MCP with the selected boss when it isn't. Workbench is now a control panel for the harness, not just a viewer — reusing the existing ouro-command runner and MCP registration; no destructive operations.

## 0.1.136 - Sidebar session filter

- A filter field at the top of the sidebar narrows the session list as you type — matches session name or group, with `owner:human` / `owner:agent` / `owner:<name>` tokens to filter by who owns a session (and status tokens). Empty filter shows everything as before. Complements the in-terminal ⌘F search; doesn't replace it.

## 0.1.135 - Reliability pass (harden 0.1.127→0.1.134)

- Editing a session no longer wipes its non-draft identity. The Edit Session sheet rebuilds the entry from the editable draft, which doesn't carry `owner` / `isPinned` / `friend`; `CustomTerminalSessionManager.updatedEntry` only copied id/archive/attention back, so an agent-created session (`owner: agent:<name>`, new in 0.1.130–0.1.132) silently reverted to human-owned on any edit (losing its sidebar badge), a pinned session lost its pin, and an assigned friend was dropped (which also stops the boss from auto-advancing it). `updatedEntry` now preserves all three. Regression test added.

## 0.1.134 - Harness Status view (GUI over the ouro harness)

- New read-only Harness Status view consolidating ouro daemon health, the local agent inventory (with the selected boss marked), and boss MCP-registration / reachability — reachable from the menu bar. A first step toward Workbench being the human control panel for the harness. Reuses the existing dashboard / onboarding / registration reads; refresh on demand.

## 0.1.133 - Remove inert desk-slug fields (B2 cleanup)

- Removed the now-vestigial `deskTrackSlug` / `deskTaskSlug` fields (and the `desk_track`/`desk_task` labels in the boss view + sense) left over from the removed Workbench→desk mirror. Back-compatible: existing workspace state loads unchanged (the stale keys are ignored).

## 0.1.132 - Agent-owned sessions are first-class in the sidebar

- Sessions an agent created through Workbench (`workbench_create_session`) now show a subtle owner badge (agent name) in the sidebar, so agent-initiated and human-initiated sessions sit side by side as equal citizens. Human-owned sessions are unchanged.

## 0.1.131 - Agents can create sessions through Workbench (workbench_create_session)

- New Workbench MCP tool `workbench_create_session`: an agent (the boss, via its registered `ouro_workbench` MCP) can create and launch a coding session through Workbench. The session appears as a first-class Workbench session tagged `owner: agent:<name>`, with the same trust gating and launch validation as a human-created terminal. A step toward unified sessions — agent- and human-initiated sessions in one list.

## 0.1.130 - Session ownership model (toward unified sessions)

- Sessions now carry an `owner` (the human operator or a named agent) on `ProcessEntry`, the foundation for unified sessions where agent-initiated and human-initiated coding sessions are both first-class. Back-compatible: existing state decodes as human-owned. No behavior change yet — the MCP create/launch tools that set agent ownership, and the sidebar rendering, land in follow-ups.

## 0.1.129 - Tool-grounded boss check-in (thin trigger)

- The automatic boss check-in now sends a thin trigger instead of a ~174-line embedded state dump. The boss fetches live state through its registered Workbench MCP tools (`workbench_status` for the full per-session view, `workbench_sense`, transcript/search/recovery tools) and acts via `workbench_request_action` — reasoning is tool-grounded, not prompt-only. This enforces the harness↔Workbench boundary and makes the empty-reply failure mode far less likely (the boss's first step is a tool call, not a one-shot over a huge prompt). A one-line pulse stays in the trigger so a boss that skips its tools still reports and escalates rather than going blind; the existing retry-on-empty remains as a safety net. The reply-side action/decision JSON protocol is unchanged.

## 0.1.128 - Stop mirroring Workbench groups into the desk

- Workbench no longer writes `track.md`/`task.md` into `~/desk` during onboarding import (removed `DeskMirrorWriter`). GUI groups/terminals are organization state, not desk work-state — the desk is owned by its principal and will be surfaced later as a read viewer over the desk MCP, never mirrored into. Onboarding still imports recent sessions as terminals/groups.

## 0.1.127 - Boss check-in retries once on an empty reply

- The automatic Boss Watch check-in no longer fails (and trips exponential backoff) when a reasoning-model boss intermittently spends its token budget on reasoning and returns an empty final answer. `BossAgentMCPClient.retryingOnEmpty` re-asks exactly once on `(empty response)` / `(no response)` / blank; only a genuinely-empty *retry* counts as a failure. Real errors (boss process unavailable, RPC/tool error, timeout) still fail straight through and surface immediately. 4 new tests.

## 0.1.126 - Harden the boss auto-answer safety floor

- Audited the defense-in-depth `PromptSafetyClassifier` — the hard floor that withholds the boss from auto-answering destructive/secret/financial prompts even on a trusted session — and closed real coverage gaps. Newly escalated to a human instead of auto-answered: the `rm -fr` flag-order variant of `rm -rf`; infrastructure teardown (`terraform destroy`, `kubectl delete`, `docker system prune`, `docker volume rm`); system power (`shutdown`, `reboot`); and crypto/private-key secrets (`private key`, `seed phrase`, `recovery phrase`, `mnemonic`). The floor still errs toward escalate (a blocked mundane prompt just becomes a human decision), and false-positive guards keep everyday prompts auto-advancing. 21 classifier tests.

## 0.1.125 - God-tier agent TUIs (correct colors) + git-repo onboarding groups

**Agent CLIs now render correctly.** Claude Code and Codex TUIs were showing garish green/black background "chips" behind text — the "awful terminal rendering." Root cause: Workbench advertised `TERM=xterm-256color` + `COLORTERM=truecolor` to the inner shell, so the agents emitted 24-bit truecolor escape sequences — but the persistent sessions run inside GNU `screen` 4.00.03 (the build bundled with macOS), which predates truecolor and *mangles* those sequences into background-color garbage. The fix is to stop advertising truecolor — Workbench no longer sets `COLORTERM`, so agents emit 256-color, which `screen` relays faithfully and renders cleanly. Verified live in a fresh session: Claude Code's welcome screen, logo, headings, and inline code all render correctly now. (Truecolor can return if Workbench ever ships a `screen` ≥ 5.0.)

**Onboarding import groups by git repo.** Reworked how onboarding organizes discovered sessions into groups. Before, sessions were bucketed by a brittle path heuristic that only grouped correctly under a folder literally named `Projects` — so two terminals in different subdirectories of the *same* repo split into *different* groups. Now sessions group by their **git repository root**: every terminal opened anywhere inside a repo lands in one group, named after the repo. An explicit name (e.g. a cmux workspace title) still wins, and non-repo directories fall back to the old heuristic. New pure `WorkspaceGrouping.repositoryRoot` + the regrouped builder are unit-tested.

- Reworked how onboarding import organizes discovered sessions into groups. Before, sessions were bucketed by a brittle path heuristic that only grouped correctly for directories literally under a folder named `Projects` — so two terminals opened in different subdirectories of the *same* repo landed in *different* groups, which made the grouping feel arbitrary. Now sessions group by their **git repository root**: every terminal opened anywhere inside a repo lands in one group, named after the repo. An explicit name (e.g. a cmux workspace title) still wins, and directories outside any git repo fall back to the previous path heuristic.
- The scanner resolves each session's repo root by walking up from its working directory to the nearest `.git` (cached per directory). New pure `WorkspaceGrouping.repositoryRoot` + the regrouped builder are unit-tested: same-repo/different-subdir → one group, distinct repos → separate groups, explicit names override, and the Claude-worktree fallback still works.

## 0.1.124 - Automatic updates (check in background, install on quit, "Update" badge)

- Workbench now keeps itself up to date the way Codex / Claude Code do, **on by default**: it quietly checks GitHub for a newer release on launch (throttled to ~once/hour), downloads + verifies it in the background, and **applies it the next time you quit** — never a surprise relaunch while it's babysitting live agents.
- An **"Update vX" badge** appears in the header as soon as a verified update is staged. Click it to install + relaunch immediately instead of waiting for quit.
- Opt out anytime: **Settings → Startup → "Automatically check for updates and install on quit."** With it off, nothing hits the network until you run "Check for Updates…" yourself.
- The background check uses the same verified pipeline as the manual install (SHA-256 + byte count vs the release manifest, bundle-id match, strictly-newer version, `codesign --verify`). The quit-time swap keeps a rollback copy until it succeeds. New pure `WorkbenchAutoUpdatePolicy` (the throttle) is unit-tested.

## 0.1.123 - One-click in-app updates (no more re-running the installer)

- **You no longer have to re-run the `curl | bash` installer to update.** When a newer release is available, the About sheet's Release Updates row now shows **"Install & Relaunch"**: it downloads the new release's app archive + manifest straight from GitHub, verifies the archive's **SHA-256 and byte count against the published manifest**, checks the bundle identifier and **code signature**, swaps the running app in place (keeping a rollback copy until the move succeeds), refreshes Launch Services, and relaunches. Same trust chain as the installer — HTTPS + the release's own SHA-256 — with nothing moved unless every check passes.
- Running terminals **survive the update**: it's a normal quit (sessions detach, not killed), so your agents reattach on the new version.
- New `WorkbenchUpdatePlanner` + `WorkbenchUpdateVerification` in Core are pure and unit-tested (planning picks the zip/manifest assets; verification rejects SHA/byte/bundle-id/downgrade mismatches).

## 0.1.122 - Test the factory-reset data wipe

- Extracted the *data* half of Reset to Factory Defaults — back up the workspace state to a timestamped sibling, then clear the whole preference domain — into `WorkbenchFactoryReset.wipeData`, and unit-tested it against a real temp directory + a real `UserDefaults` suite. Proves the state file is moved aside intact, **all** preferences (font, theme, onboarding flag) are cleared, the no-state-file case still clears prefs, and a same-second double reset doesn't throw. No behavior change — same wipe, now verified deterministically instead of by eyeball.

## 0.1.121 - Rename to "Reset to Factory Defaults" + full preference wipe

- Renamed **Reset to First Run** → **Reset to Factory Defaults** (More menu and ⌘K) to match what it actually does: a clean reset of *Workbench's own data*, not your work. The confirmation dialog now spells this out plainly.
- The reset now clears **all** Workbench preferences (font, theme, menubar, recents, onboarding + one-time migration flags) by removing the whole preference domain — a true factory state on relaunch, not a half-reset that left font/theme behind.
- Clarified the model in code + copy: running terminals are stopped *cleanly* (no invisible orphaned agents left burning tokens), and each agent's session history (Claude, Codex, cmux …) lives with that harness's own storage — never inside Workbench — so it's untouched. Relaunch and resume any agent after a reset. The workspace state is still backed up to a timestamped file first.

## 0.1.120 - Render boss replies as Markdown

- Boss/agent replies now render as proper Markdown — **bold**, *italic*, `code`, links, `##` headings, and `-`/`*` bullets — instead of showing the raw `**` and `-` characters. Applied to the boss-pane "Boss Reply" and the onboarding Setup Assistant reply. Block structure is parsed by a small tested `BossMessageMarkdown` parser; inline marks render via `AttributedString`.

## 0.1.119 - One-click "Reset to First Run"

- Added **Reset to First Run** (More menu and ⌘K palette) for cleanly re-experiencing onboarding while iterating on it. It stops running terminals, kills their persistent screen sessions, backs up the workspace state to a timestamped file, clears the onboarding-shown + migration flags, and relaunches into the fresh onboarding flow. Your `ouro`/agent setup is left untouched, so it's *your* first run — and it's reversible via the backup. Saves are suppressed during the reset so the wipe can't be undone by the quit-time save.

## 0.1.118 - Fix the blank/wrecked window (the dogfooding showstopper)

- Fixed the bug where selecting a group with no terminals (or restoring that selection on launch) blanked the **entire window** — both sidebar and detail — and stayed blank across restarts. Root cause: the no-selection empty state used a greedy `maxHeight:.infinity` VStack as the NavigationSplitView detail, which made the whole split view lay out ~2.5× the window height and shift off-screen, so the visible area landed on an empty region with the header pushed out of view. The empty-state content is now in a height-bounded `ScrollView`, and the header is pinned so it can never be starved. Verified on a real window: the empty group now shows the proper "Pick a terminal" home, and selecting a populated group still renders its terminal.

## 0.1.117 - Preview async + boss-watch banner + misc polish

- The import-preview sheet now opens immediately with a "Loading preview…" placeholder while the (watchdog-bounded) transcript load runs, so opening a preview never feels janky.
- A failing Boss Watch surfaces a **prominent banner** at the top of the boss pane after 2+ consecutive failures, explaining the backoff and that a manual Check In always tries — instead of burying the error in the Advanced status line.
- `selectBoss` now updates every existing project's boss to match the global selection, so per-project `WorkbenchProject.boss` no longer drifts to a stale agent.
- About sheet's "Copy Version" briefly flips to "Copied ✓" so you can tell it worked.

## 0.1.116 - Onboarding correctness: provider-check tasks + pending Run

- A `check-*` row that was *pending* (not actually running) used to spin forever; it now shows a **Run** button that re-triggers the check. Genuine in-flight checks still show the spinner.
- Provider-check `Task`s are now tracked, cancelled on sheet dismiss, and generation-stamped — so a late completion from a previous run can no longer overwrite cleaned-up state and flip a repaired lane back to a stale failure.

## 0.1.115 - Command palette keyboard navigation

- The ⌘K command palette now supports **↑/↓ to move the selection** (highlighted row, auto-scrolls) and **Return runs the highlighted command**, not just the first match.
- "Search Transcripts" from the palette no longer no-ops on an empty query — it reveals the search field and focuses it.
- "Install Workbench MCP" only appears in the palette when it would actually do something (not already registered), matching its buttons.

## 0.1.114 - No beachball on the import preview

- Hardened the Codex import-preview lookup: it shells out to `sqlite3` against the live Codex DB from the (main-actor) preview view. It now opens the DB `-readonly` (no write-lock contention) and is bounded by a 1.5s watchdog, so a stuck database lock can't hang the app — it just falls back to the file-based preview.

## 0.1.113 - Persistence safety + sheet polish

- Bounded run history: every launch/recovery appended a `ProcessRun` that was never pruned, so a long-lived or crash-looping session grew the persisted state forever and slowed every (synchronous) save. Workbench now keeps the newest 25 runs per session.
- The five form sheets (New/Edit Terminal, New/Edit Group, Install Agent) can now be dismissed with **Escape**, and the terminal/group sheets submit with **Return** — previously you had to mouse to the button.
- Minor: consistent ellipsis in "Use Other Boss…" and "Scanning recent local sessions…".

## 0.1.112 - Shortcuts work even when a terminal has focus

- Every global/navigation shortcut is now a real **menu-bar command**, so it fires even while a SwiftTerm terminal has keyboard focus — previously these were view-level shortcuts the focused terminal swallowed, so ⌘K (command palette), ⌘I (check in), ⌘J, ⌘N/⌘T, ⌘[ / ⌘] (cycle terminals), ⇧⌘[ / ⇧⌘] (cycle groups), ⇧⌘F (focus), ⌃⌘B (sidebar), ⌘1–9, font ⌘= / ⌘- / ⌘0, ⌘L (redraw), ⌘. (stop), ⌘, , ⌘/ , and Find were dead in normal use. The same fix that made ⇧⌘B work, applied to the whole app — and the commands are now discoverable in the menu bar (File / View / Terminal / Boss).
- Resolved a ⌘F collision (terminal Find vs. transcript search) — ⌘F is now unambiguously "Find in Terminal."

## 0.1.111 - Restart recovery reconnects to running agents

- App restart is now lossless: agents that kept running under `screen` while the app was gone are **reattached** — Workbench reconnects to the exact live process instead of respawning it. This applies to every still-alive session, even untrusted / non-auto-resume ones (reattaching a viewer is always safe), so nothing is orphaned and no work is lost. Reattached sessions come back running and no longer show up as "needs recovery."
- Only sessions that didn't survive a restart go through the (gated) respawn / native-resume path — so the Recovery sheet shows what genuinely needs attention, not everything that was open. Startup detects live sessions (`screen -ls`) before recovery runs, off-main with a watchdog.
- The recovery drill still simulates a full computer restart (nothing alive) so it remains a worst-case preview.

## 0.1.110 - Boss reliability + safety

- The boss never sends a destructive input on your behalf: boss-driven `sendInput` actions now pass the same safety floor (`PromptSafetyClassifier`) the auto-advance decisions path uses, so an obviously-dangerous, secret-bearing, financial, or agreement input is withheld and escalated even on a trusted session — closing a path where a confused/prompt-injected boss reply could have run, e.g., `rm -rf`.
- An empty / "(empty response)" boss reply is now treated as an actionable failure instead of a blank "success" — it surfaces a real error ("check the agent is set up… run `ouro mcp-serve --agent <name>`") and no longer silently clears the Boss Watch error or shows an empty pane.
- A down or misconfigured boss no longer gets re-invoked every poll interval forever: the automatic Boss Watch loop backs off exponentially (60s → … → 15m cap) after consecutive failures and resumes immediately on the next success. A manual Check In always tries.
- Fixed a stale "dry-run" comment that claimed auto-advance never sends input.

## 0.1.109 - Bug report screenshots capture the app, not the form

- Fixed: the bug report's `screenshot.png` captured the Report a Bug sheet itself (the key window while open) instead of the app behind it — so the screenshot showed the form, not the state you were reporting on. Capture now resolves through the sheet's parent window, so it grabs the actual workbench window.

## 0.1.108 - Bug reporter polish + stop the onboarding nag

- Fixed the bug reporter's note field: the text caret rendered above the placeholder line, so typed text didn't land where you expected. The placeholder now sits behind a transparent editor with matched insets, so the caret and your text align exactly.
- Onboarding no longer re-opens on every launch. A configured machine with a lingering config gap (e.g. TTFA blocked) was forced into the Welcome modal each time; it now auto-presents at most once, and the gap stays visible in the TTFA pill. Reopen setup anytime from the More menu.
- (Carries the 0.1.107 fix so ⇧⌘B opens the reporter even when a terminal has keyboard focus.)

## 0.1.107 - ⇧⌘B opens the bug reporter even from a terminal

- Fixed: pressing ⇧⌘B did nothing when a terminal had keyboard focus — the focused terminal view swallowed the chord, so the advertised shortcut only worked via the More menu or ⌘K palette. ⇧⌘B is now a real menu-bar command, which macOS matches before the event reaches the terminal, so it opens the bug reporter from anywhere. (Found while verifying the reporter end-to-end through the running app.)

## 0.1.106 - File a bug report straight to GitHub

- The bug reporter can now file a report as a **GitHub issue** on `ourostack/ouro-workbench` (labelled `bug`) with one click — a durable, searchable venue the boss/Claude can read from anywhere. The issue body is `report.md`; the screenshot and diagnostics zip stay in the local bundle and are referenced by path (the CLI can't upload them).
- Uses the GitHub CLI, resolved from the usual install locations so it works even from a GUI-launched app with a minimal PATH. If `gh` is missing or unauthenticated, the local bundle is still saved and the reporter says exactly what to fix; a missing `bug` label transparently retries without it.
- Title/body composition is the pure, unit-tested `GitHubIssueComposer`.

## 0.1.105 - Report a bug from inside the app

- New in-app bug reporter: press `⇧⌘B` (also `Report a Bug…` in the More menu and the `⌘K` palette), describe what happened, and `Create Report`. Each report is a self-contained, timestamped folder under `~/Library/Application Support/OuroWorkbench/bug-reports/` so it's trivial to find and hand off.
- Every bundle gathers everything needed to debug: a `report.md` (app + macOS version, boss/Boss Watch/auto-advance posture, all current sessions with status/attention/trust/friend/branch, the recent boss decision log with *why*, and the recent action log), a `screenshot.png` captured in-process (no screen-recording prompt), and the support `diagnostics.zip`. A failed screenshot or diagnostics run is recorded as a warning instead of sinking the report. No terminal transcript contents are included.
- The report layout and bundle assembly are the pure, unit-tested `BugReportComposer` / `BugReportWriter`; the reporter folder is reachable any time via `Open Bug Reports Folder`.

## 0.1.104 - Test coverage on the auto-advance decision (hardening)

- Extracted the "should this send input to a terminal, and how is it recorded" decision from `recordBossDecisions` into the pure, unit-tested `resolveAutoAdvanceOutcome`: only an `autoAdvance` that clears the gate executes (status `applied`); a blocked one is recorded with its reason; escalate/hold never execute. Behavior-preserving — the most consequential path now has regression protection it lacked. No functional change.

## 0.1.103 - The boss reacts the moment a session needs you

- Auto-advance and escalation now fire **event-driven**: the instant a session is flagged waiting or blocked, the boss is asked to decide right then, instead of waiting up to the ~60s Boss Watch poll. The boss reacts much faster, and is called only when there's actually something to do rather than on every tick. The periodic poll stays as a backstop.
- Rate-limited (a burst of events coalesces into one ask) and fully guarded — it never overlaps a running check-in and respects the Boss Watch switch. The throttle is the pure, tested `BossWatchEventPolicy`.

## 0.1.102 - The boss manages your sessions automatically (opt-out)

- The inbox now works out of the box — no per-session setup. **Sessions are trusted by default** (mark one "hands off" / untrusted to exclude it), and **Boss Watch is on by default**, so the boss watches, decides, and auto-advances waiting prompts without you flipping anything. This replaces the previous opt-in (mark Trusted + turn on Boss Watch), which buried the feature behind setup.
- A one-time migration brings existing setups along: sessions that were untrusted only because that used to be the default are trusted, and Boss Watch is enabled, once. Both are reversible — mark a session hands-off or turn Boss Watch off and it sticks.
- Safety is unchanged and stays fully automatic: destructive/secret prompts are never auto-answered, a cold start with no learned preferences escalates everything, the Settings → Boss kill-switch turns it all off, and every decision is in the Boss Decision Log.

## 0.1.101 - Detect blocked (stuck-on-error) sessions

- Completes the attention model: Workbench now flags a session **blocked** (red dot) when it ends on a terminal, unrecoverable error and isn't at a prompt — `command not found`, `permission denied`, `fatal:`, a build/compilation failure, `module not found`, a segfault, and similar, checked only as the *last* line so an error the agent worked past never trips it. A prompt after an error still wins (that's waiting, the human can act). Reuses the same detection path as waiting; reverts to active when the session makes progress again.
- Blocked sessions surface everywhere `needsHuman` already drives — the red sidebar dot, `⌘J`, and the boss check-in — so the boss can escalate or recover them. They're never auto-advanced (the gate requires a waiting prompt).

## 0.1.100 - Make the Boss Watch dependency discoverable

- The Settings → Boss auto-advance toggle and the Boss Decision Log empty state now say the boss decides during check-ins, so you turn on **Boss Watch** for hands-off operation. Prevents the "I marked a session trusted and enabled auto-advance but nothing happened" confusion — the boss simply hadn't checked in yet.

## 0.1.99 - Give the boss the waiting prompt inline

- The boss check-in prompt and `workbench_status` now inline the actual **waiting prompt text** for each session that needs a human (a bounded transcript-tail snippet), under a "Waiting prompts (decide each…)" section. Previously the boss only saw `attention=waitingOnHuman` and the transcript *path*, so it had to make a separate `workbench_transcript_tail` call per session to know what was being asked — extra latency it often wouldn't do. Now it can decide and propose the exact input in one turn, which is what makes auto-advance actually fire.
- Bounded, read-only tail reads; only the handful of currently-waiting, running sessions.

## 0.1.98 - Harden auto-advance against stale prompts

- Auto-advance now re-checks the **live** session before sending: the gate refuses unless the session is still running **and** still `waitingOnHuman` at execution time. An LLM check-in round-trip takes seconds, during which the session may move past the prompt; this prevents injecting an answer into a session that already advanced. The detector reverts `waiting → active` on new output, so "still waiting" is an accurate guard.
- The gate also refuses to auto-answer a prompt shorter than 3 characters (no real context to classify). Persisted decision strings (prompt / reasoning / proposed input / preference) are length-capped so a verbose boss reply can't bloat saved workspace state.
- These conditions live in the pure, unit-tested `evaluateAutoAdvanceGate`, so they can't be bypassed.

## 0.1.97 - Teach the boss (preference-driven inbox, phase 3)

- The learning loop closes the inbox. Each Boss Decision Log row now has a **Teach** control: for an escalate/hold, "auto-advance these next time"; for an auto-advance you disagree with, "always ask me instead". It hands the boss a standing preference for that decision's friend and asks it to persist it via its own notes tools (same conversation plane as check-ins, since the boss owns its memory), so future decisions improve.
- Both the request and the boss's acknowledgement are written to the action log. New `FriendPreferenceTeaching` (Core) renders the directive and derives the reinforce/correct preference from a decision.
- Completes the [preference-driven inbox](docs/preference-driven-inbox.md): detect → decide-from-friend-preferences → act (gated, audited) → review → **teach**.

## 0.1.96 - Boss auto-advances waiting sessions (preference-driven inbox, phase 2)

- The boss now *acts*: when a session is waiting and the boss decides `autoAdvance`, Workbench sends the proposed input for it — closing the loop from detect → decide → act, with the least possible delay.
- Defense-in-depth gate (`evaluateAutoAdvanceGate`): a send happens only when the kill-switch is on **and** the session is `Trusted` (untrusted is the default, so this is your per-session opt-in) **and** the friend's trust is family/friend **and** the new `PromptSafetyClassifier` clears the prompt — destructive, secret, financial, deploy, and agreement prompts always escalate, never auto-answered, even if the boss proposed an answer. Idempotent: a prompt already decided is never re-sent.
- A **Settings → Boss** toggle ("Let the boss auto-advance waiting sessions") is the global kill-switch (defaults on). Every attempt — sent (`applied`) or held with its reason (`recorded`) — lands in the Boss Decision Log (⌘K), so the automation is fully auditable. Inner agents are told in their context file that a boss may answer their prompts on trusted sessions.

## 0.1.95 - Decision log review surface (preference-driven inbox, phase 1c)

- A native **Boss Decision Log** sheet to read the audit trail: each entry shows the decision (auto-advance / escalate / hold), the session and friend it was for, the waiting prompt, the proposed input, the preference cited, confidence, reasoning, time, and status. Newest-first, with an empty state explaining what will appear. Open it from the `⌘K` command palette ("Boss Decision Log").
- Closes phase 1 of the [preference-driven inbox](docs/preference-driven-inbox.md): the boss records its decisions (1b) and you can now review *why* it made each call — the visibility you asked to prioritize, in place before any auto-advance executes.

## 0.1.94 - Boss records inbox decisions (preference-driven inbox, phase 1b)

- The boss now writes to the decision log. Its check-in / Boss Watch prompt asks it to emit, for every waiting session, an `ouro-workbench-decisions` JSON block — `kind` (autoAdvance/escalate/hold) + the proposed input, the friend preference it relied on, a confidence, and its reasoning — decided from that session's resolved friend. Workbench parses the block, resolves each session + friend, and records it.
- **Dry-run by design:** this only *logs* what the boss decided and why — it never sends input, even for `autoAdvance`. The audit trail is built and proven before any execution lands (phase 2). Recordings are deduped per session so repeated Boss Watch ticks over a still-waiting prompt don't flood the log.
- New `BossDecisionParser` (mirrors the action parser: lenient, one bad decision never drops the batch) and `recordDecisionIfNew`. No UI yet — the native review surface is next.

## 0.1.93 - Boss decision-log model (preference-driven inbox, phase 1a)

- The durable audit contract for the inbox: a `BossInboxDecision` records, for every call the boss makes about a waiting session, **what** it decided (`autoAdvance` / `escalate` / `hold` + the proposed input), **why** (the friend preference cited, a confidence, and freeform reasoning), **for whom** (the resolved friend), **about what** (the session + the waiting prompt), **when**, and **how it turned out** (`recorded` / `applied` / `overridden`).
- `WorkspaceState.decisionLog` stores these newest-first, capped at 200 like the action log, decoded leniently and present-or-empty so existing state loads unchanged. Unknown decision kinds decode to the non-acting `escalate`.
- Model + store only — no producer or UI yet. The boss recorder (MCP) and the native review surface build on this in the next slices.

## 0.1.92 - Machine-owner friend resolution (preference-driven inbox, phase 0b)

- A session's friend now resolves the same way the Ouro CLI does it: a session with no explicit friend (and no group default) falls back to the **machine owner** — the local OS user as a `human`/`family` friend, with the username as its id (the exact `(local, username)` external id the boss resolves against, so the real `FriendRecord` and its preferences attach later). A given machine maps to its owner with no manual picker.
- The boss check-in prompt / `workbench_status` now show that resolved owner instead of `unassigned` for the common case. Resolution stays pure (`effectiveFriend(for:fallback:)`); the OS read lives in `SessionFriend.machineOwner()` at the app/MCP boundary.
- Still identity + visibility only — no advancing yet. The design doc now records the resolved decisions: automate-first (TTFA) posture with a decision-log audit centerpiece (not escalate-only), and CLI-mirrored owner resolution.

## 0.1.91 - Session friend identity (preference-driven inbox, phase 0)

- Foundation for [the preference-driven inbox](docs/preference-driven-inbox.md): a session can now carry a **friend** (human or agent) — the entity it acts for, whose preferences will govern how the boss advances it. Mirrors the Ouro `FriendRecord` (name, `kind`, `trustLevel` family/friend/acquaintance/stranger). Sessions inherit their group's `defaultFriend` when they don't set their own; unassigned sessions resolve to nil (and the boss will never auto-advance those).
- The boss check-in prompt and `workbench_status` now report each session's friend (`friend=<name> (<kind>, <trust>)`, or `unassigned`), so the boss can already reason about whose policy applies.
- Schema only — fully backward compatible (decode-if-present) and no behavior change yet. Assigning friends and preference-driven advancing land in later phases.

## 0.1.90 - Jump to the next session that needs you (⌘J)

- `⌘J` jumps focus to the next session that needs the operator — waiting at a prompt, flagged for boss review, or blocked — across all groups, in sidebar order, wrapping around. This completes the attention loop the prior releases built: detection lights a session up, `⌘J` carries you straight to it without scanning panes. The binding is in the keyboard help (`⌘/`), and since it flows from the single-source `WorkbenchGuide` catalog it also reaches the boss `workbench_sense` and the inner-agent context. No-op when nothing needs you.

## 0.1.89 - Auto-detect when a session is waiting on you

- Workbench now watches each running session's output and automatically flags it as `waiting on human` when it's sitting at a prompt that needs a decision — a Claude Code / Codex approval menu, a `y/N`, a selection list, "press enter", or a passphrase prompt. The session lights up in the sidebar (orange dot), the menubar, Boss Watch, and needs-me notifications without anyone polling it; when the agent resumes, the flag clears itself. This is the core of attention routing: knowing which of your agents needs you, across all of them, at a glance.
- Built stability-first: a new pure, heavily-tested `AttentionSignalDetector` classifies a transcript tail and is deliberately conservative (a false "waiting" is worse than a missed one — bare shell prompts, compiler output, and progress bars never trigger it). Detection runs off the main actor against the already-written transcript on the existing output-settle debounce, so the terminal output hot path is untouched. Transitions only `active`↔`waiting`, never disturbing `needs review` / `blocked`.

## 0.1.88 - Boss sees per-session Git status

- The boss check-in prompt and the `workbench_status` MCP tool now report each session's git state inline (`git=<branch> (clean|dirty[, +ahead/-behind])`, or `none` for non-repos), so the boss can reason about which sessions have uncommitted work or have drifted from their upstream. The native check-in reuses the already-refreshed app state; the MCP server probes git read-only and watchdog-bounded per session.

## 0.1.87 - Per-session Git status in the sidebar

- Each terminal session's sidebar row now shows the git status of its working directory: branch name (or `(detached)`), a dirty dot when the tree has uncommitted/untracked changes, and an `↑ahead↓behind` suffix versus its upstream. For an agent workbench where most sessions live in worktrees/branches, this is the "where am I" glance at a glance.
- Backed by a new `GitSessionStatus` + `GitStatusReader` in Core that parse `git status --porcelain=v2 --branch`. The probe is read-only and lock-free (`--no-optional-locks`), runs off the main actor, and is watchdog-bounded so a slow or locked repo can never stall the UI. Refreshed on launch, on app foreground, and from the Refresh Status button.
- PR/CI status and surfacing git status to the boss/MCP are tracked as follow-ups.

## 0.1.86 - Single-source guide + inner-agent Workbench awareness

- New `WorkbenchGuide` is the one catalog describing what Workbench is and how to drive it: keyboard shortcuts, the boss capability list, and the action verbs. The in-app `Command-/` shortcut sheet, `workbench_sense`, the boss check-in prompt, and the docs all render from it, so the surfaces can't drift. The action verbs are derived straight from `BossWorkbenchActionKind`, so what's advertised to the boss is exactly what the parser accepts.
- `workbench_sense` now doubles as an in-app help oracle: alongside the tool list it carries the `ouro-workbench-actions` protocol and the operator keyboard shortcuts, so the boss can answer "how do I switch terminals?" without leaving the tool.
- Inner-agent awareness: every terminal Workbench launches now inherits `OURO_WORKBENCH=1`, `OURO_WORKBENCH_VERSION`, `OURO_WORKBENCH_GROUP`, `OURO_WORKBENCH_SESSION`, `OURO_WORKBENCH_BOSS`, and `OURO_WORKBENCH_CONTEXT_FILE` (plus the existing `TERM_PROGRAM=OuroWorkbench`). The context file is a rendered brief (`…/Application Support/OuroWorkbench/agent-context.md`, refreshed per launch) so a Claude Code, Codex, or shell agent can answer "what am I running in?" by reading one file. No files are written into project repositories.

## 0.1.85 - Automatic release on merge to main

- New `auto-release.yml`: every push to `main` reads `VERSION` and, if no `v<VERSION>` release exists yet, builds + publishes a prerelease GitHub Release automatically. Since `VERSION` is bumped in each PR, every merge that changes it cuts exactly one release; merges that don't are no-ops.
- `release.yml` is now a reusable (`workflow_call`) workflow and idempotent — it skips publishing if the tag's release already exists, so manual tag pushes, dispatches, the auto-release driver, and re-runs can never double-publish.
- This is the first release to carry the full stability + hardening pass (0.1.42–0.1.84).

## 0.1.84 - Update deep scenario verifier digest for pinned/colored coverage

- 0.1.83 added `isPinned`/`colorTag` draws to the deep scenario generator, which (correctly) shifts the seeded corpus and its coverage digest. Update the expected deep-run digest (`scripts/preflight.sh --deep` and the deep-scenario-verifier CI workflow) from `0fd57795f807596d` to `83e10a2284896aea`, regenerated and verified by a full `./scripts/preflight.sh --deep` run. (The standard required digest is unchanged.)

## 0.1.83 - Scenario verifier exercises pinned + color-tagged states

- The deep scenario generator (the CI verifier that renders thousands of synthetic layouts) never set `isPinned` or `colorTag`, so it gave green confidence for sidebar layouts that were never actually drawn. It now randomly pins entries (selected + peers, so pinned-first ordering is exercised with multiples) and color-tags some groups — closing the false-confidence gap on the two fields shipped in 0.1.56/0.1.57.

## 0.1.82 - Small robustness: empty-command guard + diagnostics pipe drain

- Launching an entry whose command is blank now fails with a clear "no command configured" error instead of synthesizing an opaque `/usr/bin/env ''` failure. (Can't happen via the UI, but a hand-edited `.workbench.json` could.)
- The support-diagnostics runner now drains the script's output pipe before waiting on exit, so a verbose diagnostics run can't deadlock on a full pipe buffer.

## 0.1.81 - MCP server always answers a request

- The `ouro-workbench` MCP server silently dropped any stdin line it couldn't parse as a single JSON-RPC object (e.g. pretty-printed or batched input), leaving the boss agent hanging forever waiting for a reply. It now responds with a JSON-RPC parse error (`-32700`, null id) for an unparseable non-empty line, while still skipping blank keepalive lines and genuine notifications.
- If a response ever fails to serialize, the server now emits a minimal valid internal-error reply instead of writing nothing — so every request gets exactly one response.

## 0.1.80 - Desk mirror track lists only imported terminals

- A Desk mirror `track.md` listed *every* proposed terminal, but only the selected ones get a `task.md` written — so the track referenced task slugs whose directories don't exist (dangling Desk references). The track now lists only the selected terminals, matching what's actually written. (track.md and task.md remain write-only-if-absent so user/Desk edits are never clobbered on a re-Arrange.)

## 0.1.79 - Deterministic "latest run" selection

- The summary, recovery planner, recovery drill, startup reconciler, prompt builder, and transcript search all independently picked the "latest run" for an entry by `startedAt` alone — with no tiebreak. When two runs shared an identical timestamp (a tight create loop, or second-granularity restore), the winner depended on array order and the call sites could disagree about which run was current. A single `ProcessRun.isMoreRecent` comparator (newer `startedAt`, ties broken on `id`) now backs all of them.

## 0.1.78 - Transcript search runs off the main thread

- ⌘K transcript search opened and read every transcript file synchronously on the main thread, so a workspace with many or large transcripts (or one on a slow/network volume) could freeze the UI mid-search. The search now runs on a background task and publishes results back on the main actor, dropping stale results if the query changed meanwhile. (Mirrors how support-diagnostics collection already offloads.)

## 0.1.77 - MCP server never quarantines the app's live state file

- The `ouro-workbench` MCP server reads the same workspace-state file the app owns. With the corrupt-file quarantine added in 0.1.60, a read-only consumer hitting a transient read error — or a schema bump seen by a stale MCP binary — could move the app's live state file aside, destroying good state. `WorkbenchStore.load` gains a `quarantineCorruptFile` flag (default true for the owning app); the MCP server now loads with it `false`, so it surfaces the error without ever touching the file. Quarantine remains the owning app's decision alone.

## 0.1.76 - Fix: first-run onboarding must still auto-present (regression in 0.1.71)

- 0.1.71 narrowed the launch onboarding gate to "genuine config gap," but the blocker-ID set it checked didn't include the **no-agent / boss-not-installed / boss-not-selected** states (`hatch` / `clone` / `use-<agent>` steps). A brand-new machine with no Ouro agent would therefore never see onboarding on launch. The gate now also presents whenever readiness is `.needsAgent`.

## 0.1.75 - Closing the window quits cleanly (no more headless zombie)

- Closing the Workbench window now quits the app. Previously it tore down the SwiftUI scene — deallocating the view model and silently cancelling the Boss-Watch and external-action loops — while the menu-bar item lingered pointing at nothing, so autonomy stopped but the UI implied it was still running. Quitting is the honest outcome, and the clean-detach-on-quit (0.1.67) means persistent sessions reattach on the next launch.
- To keep Workbench running in the background, **minimize (⌘M)** instead of closing — that preserves the window, model, and loops. (If true close-to-background is wanted later, that's a larger change — flagged for follow-up.)

## 0.1.74 - Throttle unexpected-exit notifications

- A crash-looping session, or a "Recover All" across several flaky sessions, no longer stacks one macOS banner per exit. Unexpected-exit notifications are now throttled per entry (at most one every 30s).

## 0.1.73 - Action-pump + mailbox/MCP timeout robustness

- The external-action queue drain (directory listing + per-file reads + deletes), which runs every 2 seconds, now happens off the main thread — so it can't jank the UI under a queue backlog. Applying the decoded actions still happens on the main actor.
- The mailbox and MCP request timeouts now cancel the in-flight sibling task on the timeout path too (a `defer`), instead of leaking the still-running request when the timeout fires first.

## 0.1.72 - De-duplicate import-proposal group IDs

- Two distinct projects whose names slugify identically (e.g. `My Project` and `My-Project`) no longer collide on the same import-proposal group id. The collision previously caused SwiftUI to drop/duplicate rows, made a selection toggle on one group flip the other, and merged the two projects' Desk-mirror tracks. Group ids/slugs are now de-duplicated across groups the same way task slugs already are within a group.

## 0.1.71 - Onboarding no longer re-pops on every launch

- A fully-configured machine no longer gets the onboarding sheet thrown at it on every launch. Provider *liveness* checks (`ouro check`) aren't persisted and start unrun each launch, which previously read as "not ready" and forced onboarding open before the checks could pass.
- Onboarding now only auto-presents for a genuine **configuration** gap (no ready boss, an unconfigured provider lane, or unregistered Workbench MCP). When the only thing pending is a liveness check, Workbench runs it in the background and readiness resolves to ready silently — the check state still shows in the boss pane.

## 0.1.70 - Onboarding subprocess robustness

- **The recent-work scan can no longer wedge on a busy Codex database.** The Codex history scan now opens the SQLite DB `-readonly` (never contends with a live Codex writer) and is bounded by a 5s watchdog — a WAL-locked or slow DB returns empty instead of hanging, which previously left the Scan/Arrange buttons permanently disabled.
- **Provider checks no longer false-fail on chatty output.** `ouro check` output is now drained continuously rather than read after the process exits, so a check that prints more than the pipe buffer (~64KB) can't block itself into a bogus "did not finish."

## 0.1.69 - Lenient boss-action parsing

- A boss reply containing one malformed action (e.g. an action type a newer build knows but this one doesn't) no longer discards the entire batch of valid actions. Actions decode element-by-element; bad ones are skipped, the rest apply. A payload that isn't an action array at all still surfaces as a parse error.

## 0.1.68 - Fix launch-preflight false-blocks (self-review followups)

- **Reattach/recover no longer blocked by a moved working directory.** The pre-launch validation added in 0.1.62 also ran on recover / auto-resume, which reattach to a still-live `screen` session where the original cwd is irrelevant — so a long-running session whose repo moved got wrongly blocked. Preflight now only validates fresh spawns (`recoveryAction == nil`).
- **Agents defined as shell functions/aliases no longer false-blocked.** Preflight only hard-checks a command given as an explicit path (`contains "/"`); bare names and `zsh -lc "agent …"` wrappers resolve through PATH / the login shell at launch in ways the health checker can't model, so they're no longer pre-blocked.
- Internal: the `willTerminate` observer token is now retained and removed in `deinit` (prevents observer accumulation across view-model instances in tests/previews).

## 0.1.67 - Quitting cleanly detaches sessions (no more phantom "needs recovery")

- On quit, every still-running persistent session is now recorded as cleanly **detached** — accurate, since `screen` keeps it alive after Workbench closes. Previously `markTerminated` never ran on quit, so sessions stayed `.running` and the next launch's startup reconciler flipped them into an alarming "needs startup recovery" pile even though a single relaunch reattaches them.
- Trusted auto-resume sessions still reattach automatically on the next launch; others show a calm "detached on quit; reattaches on next launch" instead of a false crash alarm.
- Also flushes any pending output timestamps and saves state on quit.

## 0.1.66 - Fix: stale search highlight when switching sessions

- With the ⌘F search bar open, switching to another terminal left the previous session's match highlight stuck on screen. Switching sessions now clears the outgoing terminal's highlight and closes the search bar.

## 0.1.65 - Fix: re-selecting/resizing a shell no longer clears its screen

- The redraw nudge that Workbench sends on attach/resize/appearance-change was a Ctrl-L (form-feed). In a full-screen TUI that means "repaint" (harmless), but in a plain shell sitting at a prompt it **clears the visible scrollback** — so clicking back to a shell terminal or resizing the window wiped what you were looking at.
- Ctrl-L is now only sent when the session is in the alternate-screen buffer (a TUI). Normal-buffer shells are left alone; SwiftTerm repaints them via its own reflow.

## 0.1.64 - Fix: disk-full no longer crashes during transcript writes

- `TranscriptRecorder.append` used the deprecated `FileHandle.write(_:)`, which raises an *uncatchable* Objective-C exception on disk-full or a closed descriptor — crashing the whole app. Switched to the throwing `write(contentsOf:)`; a failed append now drops that slice and the session keeps running.

## 0.1.63 - Fix: jumping to a session in another group lands on the right one

- Clicking a running session in the menu-bar list, an "Open" on the recovery sheet, or "Open" on the import summary banner now switches to the session's **group** before selecting it. Previously these set the selected entry without switching the project, so a target in another group silently fell back to the wrong terminal.
- Centralized in `selectEntryAcrossGroups(_:)` so all cross-group jumps behave consistently.

## 0.1.62 - Validate sessions before launch

- Launching (or recovering / auto-resuming) a session now fails fast with a clear message when its **working directory doesn't exist** or its **command isn't found / isn't executable**, instead of silently spawning an instantly-dead session or running the agent in the app's own directory.
- The check reuses the existing executable-health resolver (PATH-aware) and runs before any existing session is torn down. The failing entry is flagged `needs review` and the reason lands in the action log.

## 0.1.61 - Fix: ⌘K palette commands that open a sheet now work

- Choosing **Open Settings**, **About**, **New Terminal**, **Install Agent**, or **Keyboard Shortcuts** from the ⌘K command palette previously often did nothing — the palette dismissed and the target sheet raced SwiftUI's single-presentation context and never appeared.
- The palette now stashes the chosen command and runs it from the sheet's `onDisappear`, so the follow-on sheet presents cleanly after the palette is fully gone.

## 0.1.60 - Stability: never silently wipe the workspace

- **A corrupt or unreadable state file no longer destroys your setup.** Previously any decode failure reset the workspace to empty and immediately saved over the original. Now the unreadable file is quarantined to a timestamped `workspace-state.json.corrupt-<time>` sibling *before* the fallback, and the error message tells you exactly where it went.
- **One bad row no longer sinks everything.** Projects, terminals, runs, and the action log decode element-by-element — a single corrupt or schema-drifted entry is skipped, the rest load.
- **Schema drift is tolerated.** The persisted enums (`ProcessKind`, `ProcessStatus`, `ProcessTrust`, `AttentionState`, `TerminalAgentKind`) decode unknown raw values to a safe default instead of throwing — so a state file written by a newer build loads in an older one (relevant when iterating on Workbench itself).
- 6 new tests cover quarantine, lenient element skip, and enum fallback.

## 0.1.59 - Stability: stop blocking the UI on `screen`

- Stopping a session no longer blocks the main thread on `screen -X quit` — it's dispatched off-main, fire-and-forget, so `Stop` / `Stop All Running` stay responsive even if a `screen` socket is wedged.
- The session-exit detach-vs-crash check (`screen -ls`) now runs under a 1.5s watchdog: if `screen` hangs (e.g. stuck socket on an NFS home), it's killed and treated as not-listed instead of beachballing the whole app indefinitely. The common case (screen answers in milliseconds) is unaffected.

## 0.1.58 - Stability: throttle the terminal output hot path

- **Fixes the dominant source of UI jank.** Previously every chunk of terminal output (hundreds/sec from a busy Claude/Codex session) mutated `@Published state`, re-rendered the whole app, re-ran the header summarizer, and synchronously rewrote the entire workspace-state JSON to disk on the main thread.
- Output timestamps are now coalesced and flushed on a 2-second debounce: at most one state mutation + one disk write per interval instead of hundreds per second. The terminating-session path eagerly folds in the pending timestamp so last-output freshness isn't lost.
- No user-visible behavior change beyond the app feeling dramatically smoother under active agent output; recovery freshness checks tolerate the 2s coalescing window.

## 0.1.57 - Pinned terminals

- Right-click → `Pin to Top` floats a session to the top of its group in the sidebar; `Unpin from Top` reverses it. Pinned rows show a small pin glyph next to the name.
- Pinned entries stay above unpinned ones (stable within each partition), so the sessions you care about are always at hand even in a busy group. Order persists in `WorkbenchStore`.
- Stored as `isPinned` on `ProcessEntry` (decode-if-present → pre-pin state loads with `isPinned == false`). The ⌘1–9 quick-select and terminal cycling honor the pinned-first order since they read the same `sessionEntries`.
- 4 unit tests cover the default, coding round-trip, backward-compat decode, and the pinned-first partition.

## 0.1.56 - Per-group color tags

- Groups can now be color-tagged so the sidebar is scannable at a glance. Pick a color from `Group Actions → Color Tag` (8 colors + None). The group's folder icon tints to match.
- Stored as an optional `colorTag` on `WorkbenchProject` (synthesized Codable → existing state loads unchanged; new `WorkbenchGroupColor` enum in Core degrades gracefully if a future build adds colors an older build doesn't know).
- 4 unit tests cover color parsing, unknown/nil fallback, and the project coding round-trip incl. backward-compat decode.

## 0.1.55 - Auto-launch resumable terminals on startup (opt-in)

- New Settings → Startup toggle: **Auto-launch resumable terminals on startup** (default off). When on, reopening Workbench launches every terminal marked Auto Resume that isn't already running — so a `.workbench.json` workspace comes up with its agents waiting for you, not just on the first `Open Workspace…`.
- Runs *after* startup recovery so crashed sessions take the recovery path; only entries with no pending recovery plan and not already running are auto-launched. Fires at most once per launch.
- Default off so existing users see no behavior change; the result is recorded in the action log (`Auto-launched 3 resumable sessions`).

## 0.1.54 - Toggle sidebar visibility (⌃⌘B)

- `⌃⌘B` collapses the sidebar so the terminal pane takes the full window width. Press again to bring the sidebar back. Matches VSCode's chrome-toggle binding (adjusted to require Ctrl since plain ⌘B is bold/clash territory).
- Listed in the ⌘/ keyboard help under App.

## 0.1.53 - Copy transcript tail from sidebar context menu

- Right-click → `Copy Last 20 Lines` snaps the latest 20 transcript lines onto the clipboard. Handy for pasting into Slack / Linear when reporting what an agent just did, without opening the full transcript sheet.
- Disabled when the entry has no transcript on disk yet (e.g. never launched).

## 0.1.52 - Drag-to-reorder groups in the sidebar

- Mirrors the terminal-row reorder added in 0.1.50: drag any project row in the Groups section to put it where you want. Order persists in `WorkbenchStore`.
- Uses the same `WorkbenchEntryReorder` helper so the move algorithm has one canonical implementation.

## 0.1.51 - Recover All Crashed Terminals

- Companion to `Stop All Running…`: `More → Recover All Crashed…` and `Recover All Crashed Terminals` in the ⌘K palette run the standard recovery plan against every session currently flagged for recovery. Useful after stepping away — one click rather than N right-click / recover sequences.
- Palette entry only surfaces when something is actually recoverable; the More menu entry mirrors that with a disabled state.
- Result lands in the action log (`Recovered 3 crashed sessions`) for auditability.

## 0.1.50 - Drag-to-reorder terminals in the sidebar

- The sidebar now accepts drag-to-reorder on the current group's terminal rows. Pick up any row, drop it where you want — Workbench persists the new order in `WorkbenchStore` so it survives across launches and is honored by every list view that sources from `state.processEntries`.
- The reorder is scoped to the visible (project-filtered, non-archived) rows: dragging within a group never disturbs sessions in other groups or archived entries.
- Index translation lives in `WorkbenchEntryReorder` (new, in Core) with 5 unit tests covering single moves, drop-to-end, multi-selection blocks, out-of-bounds destinations, and empty moves.

## 0.1.49 - Stop All Running Terminals

- `More → Stop All Running…` and `Stop All Running Terminals` in the ⌘K palette terminate every currently-running session in one click. End-of-day cleanup is now one action instead of N right-click / stop sequences.
- Palette entry only surfaces when something is actually running so it doesn't bloat the empty-workbench palette. Disabled state on the menu mirrors that — greyed out when nothing's running.
- Result lands in the action log (`Stopped 4 running sessions`) for auditability.

## 0.1.48 - Sidebar elapsed-time pill on running sessions

- Every currently-running session in the sidebar now shows a small `5m` / `1h 14m` pill next to its row. Answers "how long has this Codex been running?" at a glance without clicking through to the transcript or the run log.
- Pill is driven by a SwiftUI `TimelineView(.periodic(by: 30))` so it refreshes once every 30 seconds — fine-grained enough for human glance, never busy.
- Hover-help on the pill shows the absolute start date (`Running since May 27, 6:42 PM`).
- Idle and archived rows show no pill, keeping the row uncluttered when nothing's running.
- Format is promoted to `WorkbenchElapsedFormatter` in the core module with 6 unit tests so the displayed string is exercised end-to-end.

## 0.1.47 - Drop-folder to open workspace + About sheet

- **Drop a Finder folder onto the Workbench window** to open it as a workspace. If the folder contains a `.workbench.json`, Workbench arranges the declared terminals; otherwise the user gets the same error path as `Open Workspace…`. Closes the muscle-memory gap: "drag a project root into the app" should just work, like a code editor.
- **About sheet**: `More → About Ouro Workbench…` (and `Open About` in the ⌘K palette) opens a compact info sheet with the app name, version + build hash (selectable + a Copy button), one-line tagline, and an "Open Repo" link. The hidden title bar prevents the system-provided About item from surfacing; this is the discoverable replacement.
- Multi-folder drops are accepted; non-directory items in the drop are silently filtered rather than erroring loudly.

## 0.1.46 - Settings sheet (⌘,)

- New `Settings…` sheet, reachable via `⌘,` (standard macOS shortcut), the More menu, and the ⌘K palette ("Open Settings"). Consolidates user preferences that used to be scattered across raw `UserDefaults` reads — terminal font size, theme override, menu-bar icon visibility — into a single discoverable surface.
- **Terminal section**: font-size stepper (clamps to 9..28pt) with a Reset button. Mirrors ⌘+ / ⌘- / ⌘0 from anywhere in the app.
- **Appearance section**: terminal-theme picker — `Follow System` (current default — flips with macOS appearance), `Light`, or `Dark`. Light/Dark pin the SwiftTerm palette regardless of system appearance, so a user can keep a light terminal in a dark editor or vice versa. Active sessions re-paint immediately on change.
- **Workbench Chrome section**: toggle to hide the menubar status item without quitting and reinstalling. Off hides the `∞` icon; on re-attaches it to the live model.
- **Advanced section**: shortcut button that opens System Settings → Notifications so the user can manage Workbench banners without hunting.
- Settings persist in `UserDefaults` under `ouro.workbench.terminalThemeOverride` and `ouro.workbench.showMenuBarStatusItem`. Existing prefs (font size, recents) keep their existing keys.

## 0.1.45 - Recent workspaces

- The More menu now shows an `Open Recent Workspace` submenu listing the last 8 directories you opened via `Open Workspace…`. Click a row to reopen that workspace; the per-row hover shows the full path.
- Recent entries are persisted in `UserDefaults` (`ouro.workbench.recentWorkspacePaths`) so they survive across launches.
- If a recent path no longer has a `.workbench.json` when you click it, the entry is silently dropped from the menu rather than showing a dead path forever.
- A `Clear Recent Workspaces` action sits at the bottom of the submenu.

## 0.1.44 - Right-click context menu on sidebar terminals

- Right-click (or two-finger click) on a terminal row in the sidebar now opens a native macOS context menu with the same actions as the per-session overflow menu: **Launch/Restart**, **Stop** (when running), **Ask Boss About This Session**, **Copy Launch Command**, **Open Working Directory**, plus, for custom sessions, **Edit**, **Duplicate**, **Move to Group**, **Archive / Restore**, and **Delete**.
- Lets the user act on a session without having to first focus it.

## 0.1.43 - "Where you left off" inline transcript preview

- Inactive-session card now renders the last ~12 lines of the most recent transcript inline under a "Where you left off" label so the user has immediate context when reopening Workbench, instead of needing to click through to the transcript sheet. The full sheet is still one tap away via the "View full transcript" button.
- ANSI escape sequences (CSI cursor controls, OSC title sequences, etc.) are stripped from the inline preview so TUI cursor-position codes don't pollute it. The full transcript sheet keeps the raw bytes.
- Limits the preview to a 180pt scroll view height so it never crowds the launch / recovery buttons.

## 0.1.42 - Boss-Watch needs-me notifications

- When **Boss Watch** is enabled and the dashboard refresh surfaces newly-arrived needs-me items, Workbench now posts a macOS user notification so you can leave the app in the background and trust it to ping you. Single-item notifications include the item's label and detail; multi-item notifications summarise the new arrivals plus the total count waiting.
- Only fires while Boss Watch is on — without Watch the user isn't in autonomous mode and notifications would be unsolicited.
- Skips the first dashboard refresh after Watch turns on so launching Workbench doesn't dump the entire stale backlog as banners — only genuinely new items trigger pings. Toggling Watch off and back on resets the baseline.
- Uses the same `UNUserNotificationCenter` permission Workbench already requests for unexpected-exit alerts; denied permissions silently no-op.

## 0.1.41 - Export current group as .workbench.json

- New `Save Workspace As…` action in the More menu (`⇧⌘S`) and ⌘K palette — writes the currently-selected group's terminals out to a `.workbench.json` file at a user-picked location. Closes the loop with `Open Workspace…` so a workbench you've arranged interactively can be committed to a repo as declarative project setup.
- Working directories under the project root are rewritten as relative paths so the resulting file stays portable across machines; absolute paths outside the root are kept absolute.
- JSON output is pretty-printed with sorted keys for readable diffs when committed to a repo.

## 0.1.39 - Search options in the ⌘F bar

- The in-terminal search bar now exposes three SwiftTerm `SearchOptions` toggles next to the field:
  - `Aa` — case-sensitive match (default off).
  - `.*` — treat the query as a regular expression (default off).
  - `Wˌ` — whole-word matches only (default off).
- Active toggles light up in the workbench accent color so it's obvious which modes are on. Flipping a toggle re-runs the current query so the "No matches" pill and the highlighted hit stay in sync.

## 0.1.37 - `.workbench.json` declarative workspace config

- New: a repo can commit a `.workbench.json` at its root to declare the group + terminals it wants Workbench to spin up. `Open Workspace…` (in the More menu, with `⌘O`, and in the ⌘K palette) opens a directory picker, reads the file, and reconciles the declared terminals against existing sessions — never duplicates.
- File shape:
  ```json
  {
    "group": "spoonjoy-v2",
    "rootPath": "~/Projects/spoonjoy-v2",
    "terminals": [
      {
        "name": "dev server",
        "command": "npm run dev",
        "workingDirectory": ".",
        "trust": "trusted",
        "autoResume": true,
        "notes": "vite + tailwind"
      }
    ]
  }
  ```
  All fields except `name` + `command` are optional. `rootPath` defaults to the picked directory; `group` defaults to the directory's last path component; `workingDirectory` accepts `~` expansion and treats relative paths as relative to the workspace root.
- Terminals marked `autoResume: true` launch immediately after the workspace opens, so a `git clone && open .` flow can have a project's agents waiting for you in seconds.
- Parser errors (missing file, malformed JSON, empty `terminals`) surface as user-facing error messages via the existing alert. The resulting summary banner ("Arranged N terminals…") matches the onboarding Arrange flow's idiom.
- Adds 9 tests covering decode, error paths, root-path / working-directory / group-name resolution.

## 0.1.34 - Menubar status item

- Workbench now installs an `NSStatusItem` in the macOS menu bar (`∞` icon, swaps to `⚠` when recovery is needed). Title shows the running session count next to the icon for at-a-glance signal that mirrors the Dock badge.
- Clicking the icon opens a menu with:
  - Header: `Boss: <name>` plus the current TTFA state and one-line headline.
  - `Show Workbench` — brings the main window forward (un-hides + de-miniaturizes if needed).
  - List of running sessions, each clickable to jump to that terminal in the workbench.
  - `Recovery: N waiting…` (only when N > 0) — opens the Recovery sheet on the focused window.
  - `Start / Stop Boss Watch` toggle.
  - `Ask <boss>…` — runs the standard boss check-in (disabled while one is in flight).
  - `Quit Ouro Workbench`.
- Lets you minimize Workbench and trust the menubar to be your jump-off point.

## 0.1.33 - Polish push: ⌘T, Dock badge, tail truncation, exit alerts

- **⌘T** is now a second route to "new terminal" alongside ⌘N. Matches Terminal.app / iTerm2 / browser "new tab" muscle memory.
- **Dock badge** now shows the count of currently-running sessions so the user gets a glanceable "is anything running" signal without bringing Workbench forward. Updates live on session start / stop; cleared when the count is zero.
- **Sidebar terminal names tail-truncate** instead of middle-truncating. `Codex: hello! please…` is dramatically easier to scan than `Codex: h…can make`; the distinguishing detail is at the start of the name, not the middle.
- **macOS notification on unexpected exit**: when a terminal session ends with a non-zero exit code (or no exit code, e.g. SIGKILL) and the user didn't manually stop it, post a `UNNotification` so a crashed Codex / Claude pings them even when Workbench isn't forward. Subtitle calls out when recovery needs manual action. First post triggers a one-time authorization request; if the user denies it, posts silently fail (correct macOS behavior).

## 0.1.32 - Onboarding re-checks providers on reopen

- Fixed sticky "Repair slugger" / "outward provider did not finish" warning on the onboarding Connect step. Root cause: `runOnboardingProviderChecksIfNeeded` skips lanes in `.running` or `.passed` state, but a `.running` entry got stuck if the user dismissed the sheet mid-check — the lane then kept showing the repair prompt forever, even though slugger was actually healthy.
- `presentOnboarding` now discards any provider-check entries that aren't a confirmed `.passed` before re-evaluating readiness. Stuck `.running` and stale `.failed` entries are wiped; the lane re-checks fresh on every open. Confirmed `.passed` results are kept so we don't waste cycles re-running a check the user knows works.

## 0.1.31 - Chrome polish: window title + TTFA pill

- **Window title** now reflects current focus instead of being blank. Shape: `Ouro Workbench — <boss> — <agent | group · session>`. The title bar itself stays hidden, but the Dock window list, `⌘\`` window switcher, Mission Control, and screen recordings all show this — so the user can identify a window without having to bring it forward.
- **TTFA pill** in the header now reads `TTFA · ready` / `TTFA · watch` / `TTFA · blocked` instead of just `TTFA`. The state word is what the popover already exposes; surfacing it on the pill itself means hover-help is no longer required to know whether autonomy is actually working. Hover-help is also more useful now — quotes the snapshot headline ("Boss is clear to run" / "Autonomy is usable with watch points" / "Human-free operation is blocked") with a "click to open the autonomy readiness checklist" call-to-action.

## 0.1.29 - Recovery sheet

- The sidebar `Recovery` row is now a button. Clicking it opens a `RecoverySheet` listing every session the recovery planner currently considers actionable, with per-row "Open" (jump to that terminal) and "Recover" / "Resume" / "Respawn" buttons.
- When more than one session is recoverable, a top-level `Recover All` button runs through every candidate and logs a single batch action entry instead of N near-identical ones.
- The Recovery row icon tints orange when there's something waiting and the hover-help shows the count; gray when nothing is recoverable.
- Previously this was a static label that just told you "N running, M recovery actions" — there was no way to act on the recovery candidates without diving into the boss dashboard's Advanced disclosure.

## 0.1.28 - Terminal font size shortcuts

- `⌘+` / `⌘=` increases the terminal font size by 1pt, `⌘-` decreases it, `⌘0` resets to the macOS default (13pt). Matches Terminal.app / iTerm2 / browser conventions.
- Bounds clamp to 9..28pt — below 9pt the cells become unreadable, above 28pt the layout crowds the chrome.
- The chosen size persists in UserDefaults (`ouro.workbench.terminalFontSize`) so it survives across launches.
- Size propagates to every currently-active session immediately on change AND to every newly-created session at start time so the user's chosen size is honored from the first frame.

## 0.1.27 - ⌘F search in the focused terminal

- `⌘F` now opens a search bar over the focused terminal. Type, Return for next match, ⌘G / ⇧⌘G to step forward and backward, Esc / Done to dismiss. The bar shows a "No matches" pill when the query has no hits and clears the SwiftTerm selection on dismiss.
- Backed by SwiftTerm's built-in `findNext` / `findPrevious` API and the terminal's own selection service, so the matched range is highlighted in the buffer and the scrollback auto-scrolls to reveal off-screen hits.
- Added `presentTerminalSearch` / `dismissTerminalSearch` / `stepTerminalSearch(direction:)` to the view model so the shortcuts and the bar share one source of truth. Bar state lives on `WorkbenchViewModel` (`isTerminalSearchPresented`, `terminalSearchQuery`, `terminalSearchHasResult`).
- Surfaced the shortcut in the ⌘/ keyboard help sheet under Terminal Signals.

## 0.1.26 - Real terminal theming + clickable URLs

- **Clickable URLs**: implemented the `TerminalView.requestOpenLink` delegate so OSC 8 hyperlinks emitted by TUIs and implicit URLs auto-detected by SwiftTerm are now openable. Default `linkHighlightMode` (`.hoverWithModifier`) means cmd-hover surfaces them and click opens them in the user's default browser. Only `http` / `https` / `mailto` / `file` schemes are accepted — a hostile process can't embed a `javascript:` URL that navigates the user's machine.

- Fixed "Claude Code black and white": the terminal was never installing an ANSI 16-color palette, so SwiftTerm collapsed colored SGR output to a monochrome fallback. The Workbench terminal now ships a proper xterm-shaped 16-color palette so Claude Code, Codex, `ls --color`, and any other TUI render in their intended colors.
- Fixed "white-highlighted text even when nothing was selected": that artifact was reverse-video output (ANSI `ESC[7m`, used by many TUIs for emphasis) painting with an unthemed bright-white ANSI 7. The new palette uses a muted gray for ANSI 7 (`#c8ccd0` dark / `#c8c8ca` light), so reverse video reads as a soft block of inverse contrast instead of a glaring near-white slab.
- Terminal theme now follows system light/dark mode. `TerminalHostView` overrides `viewDidChangeEffectiveAppearance` and re-applies the right `WorkbenchTerminalPalette.Theme` (background, foreground, selection, caret, full 16-color palette) plus a redraw burst so already-rendered cells get repainted with the new palette. The SwiftUI focus-mode wash and host inset use a dynamic NSColor that resolves to the matching shade automatically.
- Both light and dark themes are tuned for their backgrounds: the dark theme is workbench near-black + soft off-white; the light theme is near-paper white + graphite. The accent color stays the workbench blue in both, with selection / caret alpha values picked to read on the chosen background.
- `LocalProcessTerminalView.applyWorkbenchTheme(_:)` is the single workhorse called from `configureNativeFeel` at session init, on host reparent (`attach`), and on appearance change — so terminals created in one appearance and viewed in another never display stale colors.
- Brief note on the underlying library: SwiftTerm remains the right Swift-native choice for Workbench's terminal. Apple doesn't publish a public terminal emulator framework, iTerm2's emulator is Objective-C / LGPL and hard to embed, and writing our own vt100 emulator is multi-month work. The fixes above are about configuring SwiftTerm properly, not about replacing it.

## 0.1.25 - Keyboard shortcut help sheet

- New one-screen reference for every Workbench keyboard shortcut, grouped by intent: Navigate (⌘1..9, ⌘[/], ⇧⌘[/], ⇧⌘F), Boss + Agents (⌘I Check In, ⌘K palette, palette-search hints for jumping to an agent / running ouro check / managing agents), Terminal Signals (⌘↩ Launch/Restart, ⌘L redraw), and App (⌘N new terminal, ⌘/ help).
- Reachable from the header **More** menu (`Keyboard Shortcuts… ⌘/`) and from the ⌘K command palette by searching `keyboard` / `shortcut` / `cheat sheet`.
- Sheet rows have copy-selectable monospaced shortcut strings so the user can lift them into docs or messages without retyping.

## 0.1.23 - Header boss chip shows health

- Header `Boss:` selector now shows a small status dot (green = ready, orange = bundle disabled / no agent.json, red = invalid config or no bundle at all) so the health of the persisted boss is visible everywhere the chrome is — same idiom the sidebar Agents section uses.
- When the persisted boss has no bundle in `~/AgentBundles`, the chip surfaces a red `missing` pill next to the name. The hover-help spells out the fix: pick an installed agent from the dropdown or hatch a new one. Previously the user could land in a state where the boss didn't exist and the only signal was that Boss Watch / Check In silently failed.
- Boss selector dropdown rows now append a status suffix (`— disabled`, `— no agent.json`, `— invalid config`, `— missing`) when an agent isn't ready, so unhealthy bundles are obvious before you switch to them.

## 0.1.22 - Keyboard cycling for terminals

- Added daily-use keyboard shortcuts for jumping between terminals and groups without taking your hands off the keyboard:
  - `⌘1` … `⌘9` — select the Nth terminal in the currently-visible session list (1-indexed; ignored silently when the slot is empty).
  - `⌘[` / `⌘]` — cycle to the previous / next terminal, wrapping at the ends.
  - `⇧⌘[` / `⇧⌘]` — cycle to the previous / next group.
- Added a shared `WorkbenchCycleDirection` enum in Core and view-model helpers (`selectTerminal(atOneIndexedPosition:)`, `cycleTerminal(direction:)`, `cycleGroup(direction:)`) that the shortcuts call. Helpers are no-ops with a `false` return when the targeted slot doesn't exist, so the shortcuts decline gracefully on an empty workbench.
- The shortcuts live in an invisible `TerminalCyclingShortcuts` view inside the root pane so they stay in the responder chain across the agent / terminal / Agent Home detail-pane modes without intercepting clicks.

## 0.1.21 - Agent-aware command palette

- Surfaced the Agents IA in the ⌘K command palette so every action that used to require opening the sidebar pane is reachable by name from any focus:
  - **Manage Agents** opens the Agents pane focused on the current boss.
  - **Select Agent: \<name\>** appears once per installed bundle in `~/AgentBundles/*.ouro`, with the agent's status detail surfaced in the row and the agent name as a payload so search like "agent slugger" lands on the right command.
  - **Repair \<name\>** opens a Workbench terminal pre-loaded with `ouro check --agent <name>`.
  - **Open \<name\> agent.json** opens the bundle's config file in the user's default JSON editor; **Reveal \<name\> Bundle** opens the bundle in Finder.
  - **Use \<name\> As Boss** is offered when the focused agent is ready and not already the boss.
  - **Install MCP for \<name\>** / **Update MCP for \<name\>** appears when the bundle's Workbench MCP registration is actionable.
- Extended `WorkbenchCommandDescriptor` with an optional `payload` field so one command ID (e.g. `selectAgent`) can address many concrete targets without inventing a separate ID per agent. Codable decoding remains backwards-compatible with descriptors that predate the payload field.
- `CommandPaletteSheet` now dispatches the full descriptor through a payload-aware `performCommand(_: WorkbenchCommandDescriptor)` overload so the ⌘K row that searches "agent slugger" actually selects slugger, not just opens the generic Agents pane.

## 0.1.20 - Calm terminal palette

- Fixed the "white-highlighted text" artifact on the terminal: SwiftTerm's default selection color (`NSColor.selectedTextBackgroundColor`) is tuned for white-paper text fields and lands on a black terminal as a glaring near-white block. The Workbench terminal now uses a translucent accent-blue selection instead.
- Set explicit native background / foreground / caret colors on the SwiftTerm view via `configureNativeFeel()` instead of relying on system defaults, so the terminal renders predictably across light/dark mode toggles and across the in-window pane vs the full-screen focus mode.
- Pulled the colors into a shared `WorkbenchTerminalPalette` helper used by the SwiftTerm view, the host inset (so the inset never flashes pure black before the terminal claims pixels), and the SwiftUI focus mode background. Keeps the focus mode and in-window terminal visually identical.

## 0.1.19 - First-class Agents pane

- Added an `Agents` sidebar section above `Groups` listing every Ouro bundle in `~/AgentBundles/*.ouro`. Each row shows the bundle name, a status dot (ready / disabled / missing config / invalid config), the current boss flag, and the human-facing provider/model lane summary. Selecting an agent opens a dedicated detail pane — orthogonal to terminal selection — without diving into the boss dashboard's Advanced disclosure.
- Built a dedicated `AgentDetailView` with the same chrome philosophy as `SessionDetailView`: a slim title strip (status dot, name, boss pill, More menu, `Use as Boss` primary action) with everything else in body cards. A disclosure inspector reveals the bundle path, config path, status detail, and MCP registration detail.
- Surfaced model providers per agent: the Lanes card shows the human-facing and agent-facing provider/model pairs as read from `agent.json`, with an `Edit agent.json` button that opens the file in the user's default JSON editor.
- Surfaced repair as a first-class action: `Run ouro check` opens a Workbench terminal pre-loaded with `ouro check --agent <name>` so providers, the daemon, and MCP tools can be fixed without leaving the app or remembering the CLI shape.
- Surfaced Workbench MCP install/update directly from the agent's status card (no more digging into Boss Dashboard → Advanced → Ouro Agents).
- Extended the `Boss:` selector menu with `Manage Agents…` and `Hatch / Clone Agent…` entries so the new pane and the hatching flow are reachable from the always-visible header chip.
- When the sidebar's `Agents` section is empty, it shows `Hatch Your First Agent` as a primary entry; once at least one bundle exists, the entry becomes `Hatch / Clone Agent`.
- Selecting a terminal automatically clears the Agents pane focus (and vice versa), so the detail pane is always exactly one of: agent, terminal, or the Agent Home empty state.

## 0.1.18 - Install over /Applications no longer feels damaged

- Refresh Launch Services and clear `com.apple.quarantine` xattrs at the end of `scripts/install-app.sh` so replacing an ad-hoc-signed `Ouro Workbench.app` in place (especially under `/Applications`) no longer surfaces the generic "the application may be damaged or incomplete" Finder error. Without the refresh, Launch Services held the previous bundle signature for that path and would not let Finder open the new build.

## 0.1.17 - Terminal-First Workbench

- Slimmed the app chrome dramatically so the terminal owns the screen: the top header drops to a single ~40pt row, the boss dashboard defaults to collapsed (with a one-time migration for existing installs), and the per-session chrome is now a single 38pt title strip with a status dot, the terminal name, and a compact action cluster.
- Folded the old multi-row session header — pills, resume command, notes, transcript, Edit/Duplicate/Move/Archive/Delete — into a disclosure-driven inspector and a single overflow menu, so they remain one click away without ever eating vertical space.
- Made onboarding import-proposal rows actually selectable: tap a row to toggle whether that terminal participates in Arrange, with a per-group select-all toggle and live counts. The Arrange button is disabled and explains itself when zero terminals are selected.
- Arrange now reports what it did: it dismisses the onboarding sheet on success and shows a transient banner ("Arranged N terminals across M groups") with a one-click "Open" jump to the first imported terminal.
- Replaced the empty "No session selected" placeholder with an Agent Home surface that surfaces Hatch / Set Up Workbench / New Terminal as first-class actions and lists installed agents with the active boss flagged.
- Replaced the fragmented inactive-session view (transcript snippets + embedded mini-terminal box) with a calm single card showing status, recovery reason, the launch command, and a single primary action; transcripts moved to a focused sheet.
- Trimmed the boss dashboard so it shows only essentials (metrics, mailbox warnings, Boss Line, latest reply, needs-me / coding counts) by default; agent manager, transcript search, runtime, release, recovery drill, MCP setup, full action log, and applied actions live behind an Advanced disclosure.
- Reorganized the top toolbar so Watch, Set Up Workbench, Refresh, and Hatch live in a single "More" menu; the visible row is now Boss · status · autonomy · dashboard chevron · More · Commands · Check In.

## 0.1.16 - Onboarding Setup Assistant

- Replaced the ambiguous onboarding free-form prompt with a visible Setup Assistant that explains whether it is asking the selected boss or running a setup step.
- Show setup-action status and boss replies inside onboarding instead of sending answers only to the main Boss Line surface.
- Keep typed scan/import requests behind the same provider and Workbench-tool readiness gates as the primary onboarding buttons.
- Treat natural-language questions such as "which sessions should I import?" as boss questions instead of accidentally applying an import command.

## 0.1.11 - Workbench Sense Registration

- Register Workbench as an explicit Ouro local sense when installing the boss-agent MCP bridge.
- Treat a matching Workbench MCP server without `senses.workbench.enabled` as repair-needed instead of fully registered.
- Preserve existing boss-agent senses while adding the Workbench sense declaration.

## 0.1.5 - Sidebar And Resize Polish

- Reworked sidebar project and add-action rows so group names stay readable and "New Group" / "New Terminal" no longer look like selected tabs.
- Redraw terminals after real host-size changes so collapsing, expanding, and focusing the boss pane does not leave prompts stranded halfway down the terminal.
- Added a small backed terminal inset so shell prompts and typed commands do not render hard against the window edge.

## 0.1.4 - Dashboard Row Polish

- Stabilized boss-dashboard status rows so long runtime, diagnostics, release, recovery, MCP, and mailbox messages truncate predictably without crowding controls.
- Kept the compact Action Log reveal control reachable when native action results are long.
- Reworked terminal hosting so split and full-screen terminals redraw cleanly after app reopen or focus-mode reparenting.

## 0.1.3 - Header Control Polish

- Compact terminal signal controls to stable icon buttons so the session header stays usable in normal-width windows without truncated labels.
- Preserve tooltips and accessibility labels for Full Screen, Redraw, Ctrl-C, Esc, EOF, and Stop controls in both pane and focused terminal modes.

## 0.1.2 - Operator Control Surface

- Expanded the command palette with boss quick asks, workspace refresh, Ouro-agent refresh, Workbench MCP install/refresh, release-page open, diagnostics reveal/copy/open-folder, and selected-terminal actions.
- Made command palette search token-aware with aliases for operator terms like `diag`, `boss`, `mcp`, `folder`, and `signal`.
- Added explicit terminal `EOF` / Ctrl-D controls, `Command-L` redraw shortcuts, selected-terminal copy/open/reveal commands, and smaller session-header utility buttons.
- Added diagnostics zip path copy, diagnostics output-folder open, action-log entries for native diagnostics/release/terminal-control actions, and stronger diagnostics runner validation.
- Hardened packaged-app preflight by smoke-running the bundled diagnostics helper and verifying the helper is non-empty.

## 0.1.1 - Post-Preview Hardening

- Added explicit terminal `Redraw` controls that send Ctrl-L in pane and focused terminal modes.
- Added command-palette actions for terminal focus, terminal redraw, boss-pane toggle, support diagnostics, and release update checks.
- Added in-app support diagnostics collection and Finder reveal from the native boss dashboard.
- Bundled the support diagnostics helper into the `.app` and made bundle verification reject missing or non-executable diagnostics helpers.
- Updated support diagnostics to run from either a repo checkout or the installed app bundle.

## 0.1.0 - Unsigned Preview

- Native macOS Workbench for Claude Code, OpenAI Codex, GitHub Copilot CLI, local shells, and arbitrary terminal/TUI agents.
- Cmux-style groups with multiple terminal tabs per group.
- Persistent terminal backing through bundled `screen` for app quit and force-quit recovery.
- Startup recovery planner for native resume, checkpoint respawn, and manual-action classification after computer restart.
- Selectable Ouro boss agent with Boss Line, Boss Watch, focused Ask Boss, and TTFA readiness.
- Packaged Workbench MCP server for status, transcript tail/search, recovery drill, and queued trusted actions.
- Versioned unsigned app artifact zip and manifest with SHA-256 verification.
- Protected CI gates for Swift tests, native scenario verification, bundle verification, artifact verification, and install rollback smoke.
