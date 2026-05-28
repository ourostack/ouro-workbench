# Changelog

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
