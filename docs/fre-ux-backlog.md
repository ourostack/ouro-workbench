# Ouro Workbench UX backlog (audit-generated, U7–U36)

From the `workbench-ux-audit` workflow (12 surface auditors → adversarial value-verify → synthesize). 30 prioritized "design is how it works" units, operator + ouro-boss perspectives. Continues `fre-subtraction-doing.md` (U1–U6). Sequenced by priorityRank.

## Coverage gaps (future audit passes)
- Settings / preferences surface: the audit never covered the Settings window itself (the Boss Watch 'on by default' copy at ~1707, open-at-login toggle, autonomy/trust defaults) as a first-class UX surface — only incidental references. Worth a dedicated pass on whether defaults, copy, and reset paths there are honest and legible.
- Command palette (⌘K) as a primary surface: it appears only as the fallback door for the Decision Inbox and as a contrast example, but its own discoverability, result ranking, and whether a first-timer ever learns it exists were not audited.
- Keyboard/accessibility end-to-end: CI now requires the shortcut/a11y contract for native menu shortcuts, scoped shortcut documentation, representative labels, and help wiring, but no packaged-app AX pass has audited the existing keyboard-navigation and screen-reader story across the window as a whole (focus order, live ⌘-shortcut behavior, VoiceOver labels on the terminal pane).
- Agent detail view (AgentDetailView): repeatedly referenced as the destination of selecting an agent, but its own content, actions, and whether it's a legible 'what is this agent / is it healthy / what can it do' surface were never audited.
- Notifications / background alerting: there is no finding on how (or whether) the operator is told a session started waiting while Workbench is backgrounded — for a watchdog product, the OS-notification / dock-badge / attention-pull story is a notable uncovered surface.
- Multi-workspace lifecycle beyond create/rename: deleting/archiving a workspace, moving sessions between workspaces, and what happens to running terminals when a workspace is removed were not covered.
- Provider/credential management lifecycle: ProviderConfigSheet is covered for first-create, but rotating/removing credentials, the 'verify provider' result legibility, and the github-copilot cold-start unsupported path were only touched tangentially.
- Boss transcript / conversation surface: the boss's own check-in answers and decision narration are referenced (Boss: <one line>) but the surface where the operator actually reads the boss's prose responses, and its legibility/length/scrollback, was not audited as its own surface.


## [U7] Restore-recovery dead-end: "needs recovery" sessions offer only "Launch", silently destroying agent history
**#1** · `fixes-broken` · effort `M` · surface: Restart / reboot recovery & resume (P0) · operator

**Problem:** When the recovery planner classifies a restored session as manualActionNeeded (untrusted entry, no persisted session id, or .manual resume strategy), canRecover() returns false, so the InactiveTerminalSurface primary button falls through to "Launch" (model.launch → a brand-new run with NO resume) while the subtext directly above still reads "Recovery: <agent> lacks a persisted session id". The session also never appears in the Recovery sheet (recoverableEntries filters manualActionNeeded out). The dedicated "Manual Recovery" button title exists in recoveryButtonTitle but is dead code because canRecover gates it out. So after a reboot the operator is told a session needs recovery, then handed a calm "Launch" that quietly discards the agent's prior conversation/checkpoint with no warning.

**Fix:** Give manualActionNeeded sessions a first-class honest path: (1) include them in the Recovery sheet under a distinct "Needs you" group with their plain-language reason and any one-click remediation (e.g. "Trust this session to enable auto-resume"); (2) when canRecover is false but the latest run needs recovery, label the button "Start fresh" (not "Launch") and gate it behind a one-line confirmation naming what's lost ("This agent has no resumable session — starting begins a new conversation. Previous transcript stays viewable."); (3) never show a calm "Launch" under a "Recovery: …" headline.

**User stories:**
- _As a operator returning to Workbench after a reboot, I want the sessions that can't be auto-resumed clearly separated, explained in plain words, and a warning before any action that discards an agent's history, so that I never lose an agent's conversation by clicking a button that looked like a safe resume._
    - [ ] A restored session classified manualActionNeeded appears in the Recovery sheet under a labeled 'Needs you' group with its plain-language reason
    - [ ] On the inactive surface for such a session the primary button reads 'Start fresh', not 'Launch', and the subtext does not imply a lossless recovery
    - [ ] Activating 'Start fresh' shows a one-line confirmation naming that a new conversation begins and the prior transcript remains viewable
    - [ ] When the manual blocker is one-click fixable (e.g. trust), the Recovery sheet offers that fix inline instead of only a fresh-start

## [U8] Post-reboot false alarms: surviving sessions render as "needs boss review" and recovery counts contradict themselves
**#2** · `removes-friction` · effort `M` · surface: Restart / reboot recovery & resume (P0) · operator+boss

**Problem:** Three compounding honesty defects on the first surface after a reboot. (a) StartupRecoveryReconciler unconditionally sets attention=.needsBossReview + lastSummary="<name> needs startup recovery" for every entry running/waiting at quit, BEFORE the lossless-vs-lossy distinction is computed — so a session whose screen session is still alive (the success case of reboot recovery) is greeted as an orange alarm, and the quit path's own calmer copy is overwritten; the boss's bucket logic then classifies these as waitingOnYou and over-escalates. (b) Recovery counts disagree: the sidebar row / sheet header use oneLineStatus (excludes .reattach) while the row help, sheet body, and section visibility use recoverableEntries (includes .reattach), so a workspace of only live reattaches shows "0 recovery actions" next to a tooltip "N waiting" and a sheet listing N rows. (c) Recovery reason strings are raw internal jargon shown verbatim ("trusted non-agent process may be respawned by policy", "lacks a persisted session id", "session still running — reconnect") on the Recovery sheet, inactive surface, and drill rows.

**Fix:** (a) Have the reconciler consult live screen-session names (or run reattach reconciliation) BEFORE assigning attention — a surviving session lands as .active/.idle with a calm "Reconnected — kept running while Workbench was closed" summary; only genuinely-lost sessions get an attention flag, and that flag distinguishes "auto-resuming" from "needs you". (b) Derive the sidebar row text, its help, the sheet header, the sheet body, and shouldShowRecovery from ONE shared computed value; label reattach rows distinctly ("Reconnect — no loss") so a lossless reconnect is never counted as an alarming "recovery action". (c) Map each RecoveryAction to one operator-facing sentence in recoveryReason(), keeping the raw string behind a tooltip/disclosure for power users; reuse the verb mapping recoveryButtonTitle already has.

**User stories:**
- _As a operator (and the boss) immediately after a reboot, I want sessions whose terminal survived to read as calmly reconnected, only genuinely-lost sessions flagged, one trustworthy recovery count, and plain-language reasons, so that the post-reboot screen reflects reality — most agents just kept running — instead of a wall of false alarms, contradictory numbers, and debug jargon._
    - [ ] A session whose screen session is still alive is shown reconnected/active after startup, not 'needs boss review', with a calm reconnect summary
    - [ ] Only sessions that did not survive are placed in the operator's waiting/attention queue and the boss's waiting-on-you bucket
    - [ ] The sidebar Recovery row text, its hover help, the sheet header, and the sheet row count are derived from one shared value and never disagree; a lossless-reattach-only workspace never reads '0 recovery actions' over a non-zero list
    - [ ] No recovery copy shown to the operator contains internal phrases like 'by policy', 'persisted session id', or raw status values; each action maps to one plain sentence with the raw reason available on demand
- _As a Ouro boss triaging what needs the human right after a restart, I want lossless-reattach sessions to not appear in my waiting-on-you bucket and recovery reasons I can relay without decoding internal phrasing, so that I escalate only sessions that genuinely need the operator and report recovery state honestly._
    - [ ] The boss's status buckets do not classify a lossless-reattach session as waiting-on-you
    - [ ] The recovery state the boss reads distinguishes survived/reconnected from genuinely-lost

## [U9] Make the TTFA popover get-to-green FUN and EASY: every non-green check gets an inline one-click fix, and the alarm copy stops crying wolf
**#3** · `fixes-broken` · effort `M` · surface: TTFA autonomy readiness + repair flow (THE EXEMPLAR) · operator

**Problem:** The surface that exists to tell you you're NOT green offers no way to get green from there. AutonomyStatusCheckRow renders each of the 8 readiness checks as pure icon+label+detail with no action button; the popover's only actions are a generic bottom row (install-MCP / Watch / Login / Ask). Yet a fully-built per-step repair UI already exists (OnboardingRepairStepRow with Register/Connect/Run/Fix buttons), locked inside the opt-in wizard, and the actuators exist (setTrust, setAutoResume, installWorkbenchMCPForBoss, recoverAll). Compounding it, the blocked-state copy is punitive for benign one-tap states: an untrusted terminal, auto-resume off, or a stale MCP entry each trip the headline "Human-free operation is blocked" + "The boss cannot fully inspect, control, or recover the Workbench" + a red stop-sign (xmark.octagon), when the truth is "one tap from green." So the operator's headline ask — when TTFA isn't green, getting it green must be one-click — is inverted: a wall, with dread framing and no door.

**Fix:** Give AutonomyStatusCheckRow a trailing repair affordance for any non-.ok check, mapped per check id: terminal-trust→'Trust' (updateEntry trust), terminal-resume→'Enable resume', boss-mcp/needsUpdate→installWorkbenchMCPForBoss, recovery→'Recover', boss-watch→'Watch', open-at-login→'Login'; reuse the OnboardingRepairStepRow button vocabulary; checks with no in-app fix show no orphaned button. Separately, reframe the blocked state around the action: lead with what's needed and that it's quick ('2 things to make this hands-off'), reserve the octagon/'cannot recover' language for genuinely degraded conditions (missing executable/app/agent bundle), and use a softer 'needs you' indicator for one-tap toggles. (Note: paused watch is .warning not .blocker — keep it out of the blocked-state reframe.)

**User stories:**
- _As a operator monitoring autonomy readiness via the TTFA header pill, I want to fix whatever is keeping TTFA out of green directly from the popover that flagged it, with calm action-first copy, so that getting to green is a couple of clicks in one place, not a scavenger hunt across the app under a wall of dread._
    - [ ] Each check whose state is .warning or .blocker shows an inline action button when a remediation exists; a check with no possible in-app fix shows no orphaned button
    - [ ] Tapping terminal-trust's button flips the offending terminal(s) to trusted and the check turns green in place without leaving the popover; same for terminal-resume, boss-mcp/needsUpdate, recovery, watch, and login
    - [ ] When the only blockers are one-action toggles, the headline frames the remaining work as quick setup, not 'Human-free operation is blocked'
    - [ ] The stop-sign icon and 'cannot recover' language are reserved for genuinely degraded conditions; copy never claims the boss cannot recover when the blocker is a user-side toggle

## [U10] The live session detail header tells the truth: render attention (waiting / blocked / needs-review) with a why-banner instead of a calm green dot
**#4** · `fixes-broken` · effort `M` · surface: Session detail (terminal view, controls, attention) · operator+boss

**Problem:** "Is waiting on me obvious?" is the cut-test for this surface and the answer is no. SessionTitleStrip.statusDot hand-rolls a green/orange/grey trichotomy from activeSession/canRecover and ignores entry.attention entirely, while the sidebar SessionChip renders the real 5-state AttentionState (waitingOnHuman=orange hand.raised, blocked=red octagon, needsBossReview=blue eye). The detector flips a still-running session to .waitingOnHuman/.blocked, so a session sitting on a prompt shows orange in the 8pt sidebar dot but a calm GREEN dot in the full-screen header the operator lives on — two sources of truth, the worse one winning the biggest pixels. Worse, even when the dot is fixed, the WHY is discarded: AttentionSignalDetector matches a prompt/error line then throws it away, so the live view never says what the agent asked or what failed — the operator must parse raw ANSI scrollback. The boss's needsBossReview opinion is likewise invisible on the exact surface where the operator decides.

**Fix:** Drive statusDot (plus a short label) from entry.attention via the existing AttentionState.healthColor/healthSymbol/healthLabel for active sessions (reuse StatusDot/SessionChip — one shared mapping), keeping grey/orange recovery semantics only for the inactive case; render .needsBossReview (eye + 'Needs boss review') too. Have AttentionSignalDetector return a short reason string alongside the enum, persist it (entry.attentionReason), add it to the boss-facing SessionSnapshot, and render a slim one-line attention banner above the TerminalPane when attention.needsHuman ('Waiting on you · <reason>' / 'Blocked · <reason>') with a 'Jump to prompt' action. No banner for active/idle.

**User stories:**
- _As a operator with several agent terminals running, I want the detail header of the session I'm viewing to show the same waiting/blocked/review state the sidebar shows, plus a one-line summary of what the agent is asking or what failed, so that I can tell at a glance whether the terminal in front of me needs me and decide in seconds instead of reading raw scrollback._
    - [ ] When entry.attention is .waitingOnHuman / .blocked / .needsBossReview, the live detail header shows the matching glyph + label (not a generic green dot), derived from the same AttentionState mapping the sidebar uses
    - [ ] When a session is .waitingOnHuman or .blocked, a one-line banner shows the detected prompt/failure reason and offers a direct 'jump to prompt / focus input' affordance; no banner appears for .active/.idle
    - [ ] A plain shell with no structured activity still renders a sensible active/idle state, never empty or broken
- _As a Ouro boss reporting why a session is waiting, I want the reason I extract from the transcript to be the same one the operator sees on the detail surface, exposed in SessionSnapshot, so that the operator can audit my 'this one is waiting because X' claim against the live view, and we agree on why._
    - [ ] The reason string persisted to entry.attentionReason is exposed via the boss-facing SessionSnapshot, not only rendered in the UI
    - [ ] The boss-facing per-session state shown to the operator matches the entry.attention value the boss reads over MCP

## [U11] Stop matches its weight to its consequence: confirm before killing a live/holding agent on the reflexive ⌘. chord
**#5** · `fixes-broken` · effort `S` · surface: Session detail (terminal view, controls, attention) · operator

**Problem:** The primary Stop button is role:.destructive, bound to ⌘. (the universal macOS 'cancel' chord), and calls model.terminate(entry) which immediately marks the run terminated with no confirmation and no undo; the same instant-kill ⌘. also lives in TerminalFocusView and a Stop-All path exists. For a running agent holding context, a stray ⌘. muscle-memory or a misclick ends the session. The friction is inverted relative to consequence: the app already demands a named confirmation to DELETE an already-stopped (dead) terminal, yet kills a LIVE agent on one reflex chord with nothing — undermining TTFA (you can't trust leaving an agent running if a reflex nukes it).

**Fix:** Gate Stop by consequence: for a session whose attention is .active or .waitingOnHuman (live/holding context), require a confirmation naming the session ('Stop <name>? The agent is mid-session.') via the existing pendingDelete-style confirmationDialog plumbing; idle/finished sessions stop without ceremony. Apply the same gate to the ⌘. shortcut and the menubar 'Boss > Check In'-adjacent stop path, not just the button. Record terminate() in the action log so the stop is auditable.

**User stories:**
- _As a operator running a trusted agent that's actively working, I want Stop to ask for confirmation when the agent is live/holding context, but not when it's idle, so that a reflexive ⌘. or a misclick doesn't destroy an in-flight agent session, while stopping finished work stays frictionless._
    - [ ] Pressing Stop (button or ⌘.) on an .active or .waitingOnHuman session shows a confirmation naming the session before terminating
    - [ ] Stopping an idle/already-finished session requires no extra confirmation
    - [ ] The confirmation copy states the consequence in plain language ('This ends the running agent and its live context.')
    - [ ] A confirmed Stop is recorded in the audit log so the operator can see what was stopped and when

## [U12] The prominent Check In button: stop the silent no-op, give it a tooltip, and use one name for the action everywhere
**#6** · `fixes-broken` · effort `M` · surface: Header & toolbar · operator+both

**Problem:** The loudest control in the header has three compounding defects on one action (runBossCheckIn). (a) It is the only toolbar control with NO .help() — every neighbor has one — so hover, the universal learn-affordance, teaches a first-timer nothing, and the bare verb 'Check In' reads like a time-clock, not 'ask my boss for a status read-out (⌘I).' (b) It is gated only by bossCheckInIsRunning, never disabled when there's no boss, and runBossCheckIn returns silently on an empty boss name — so on a fresh machine the brightest, color-filled button (plus its ⌘I shortcut and the menubar item) is fully clickable and does absolutely nothing, the dead affordance the tenets forbid, wasting the perfect teach-a-boss moment. (c) The same action wears three names — 'Check In' (toolbar/menu), 'Ask' (autonomy popover), 'Ask <name>…' (status item) — and visually collides with the separate 'Boss Watch'/'Watch' loop, forcing the operator to learn by trial that they're identical.

**Fix:** Add a .help() describing the actual behavior and ⌘I ('Ask your boss for a status read-out — what's running, what's waiting on you, what's next'). When no boss is set, either disable Check In with an explanatory tooltip OR (better) route the click to presentOnboarding (the boss picker), turning the dead click into a guided next step; apply the same to the ⌘I shortcut and the menubar item. Pick one verb for the manual pull (e.g. 'Ask Boss') across the toolbar button, the popover button, and the status item; keep 'Boss Watch' as the distinct name for the automatic loop and add one-line help distinguishing 'ask once now' from 'ask automatically'. Disambiguate from the typed-question submit (also labeled 'Ask') when renaming.

**User stories:**
- _As a first-time operator scanning the header, I want to understand what the prominent boss-status button does before clicking — at minimum via hover — and to never click a loud button that silently does nothing, so that I can confidently ask my boss for a status read-out, or be guided to pick a boss, instead of a mystery or a dead click._
    - [ ] Hovering the button shows a tooltip describing the status-read-out behavior and its ⌘I shortcut; it is no longer the only toolbar control lacking a .help()
    - [ ] With no boss set, the button (and its ⌘I shortcut and the menubar item) either is disabled with an explanatory tooltip or routes the operator to pick/set up a boss — it never silently no-ops
    - [ ] Once a boss is set, the button behaves as today
- _As a operator learning how the boss works, I want the manual 'ask the boss now' action to have one consistent name wherever it appears, distinct from the automatic watch loop, so that I build a single mental model instead of guessing whether Check In, Ask, and Ask-<name> are the same thing._
    - [ ] The toolbar button, the autonomy-popover button, and the status-item entry use the same verb for runBossCheckIn
    - [ ] Help text on each distinguishes the one-shot ask from the automatic Boss Watch loop
    - [ ] No surface labels the manual check-in with a word also used for the automatic watch (or for the typed-question submit)

## [U13] Edit Terminal accepts the blank login shell the New Terminal sheet now creates (no more greyed-out Save)
**#7** · `fixes-broken` · effort `S` · surface: Sheets & forms (workspace, edit, command palette) · operator

**Problem:** U4 made command OPTIONAL on the New Terminal sheet (blank command → /bin/zsh -l login shell, blank name → 'Terminal'), but EditTerminalSessionSheet.canSave still requires name AND command AND working directory non-empty. So you can create a valid blank-shell terminal in one click, then open Edit on it and find Save permanently greyed out until you type a command you never needed — the exact disabled-primary dead-end U4 set out to kill, surviving in the sibling sheet. The model layer (CustomTerminalSessionFactory) already round-trips an empty command, so only the UI gate blocks it.

**Fix:** Make EditTerminalSessionSheet.canSave match NewTerminalSessionSheet.canCreate: require only a non-empty working directory; a blank command saves as the login shell, a blank name falls back to 'Terminal'. Define the validity rule once in a shared place so the two sheets can't drift again.

**User stories:**
- _As a operator who created a blank login-shell terminal, I want to open Edit and change its name or working directory without being forced to invent a command, so that editing a terminal is as forgiving as creating one — no greyed-out Save, no dead-end._
    - [ ] Opening Edit on a terminal that has no command shows an enabled Save button
    - [ ] Clearing the Command field in Edit and saving keeps the terminal as a login shell (parity with New Terminal)
    - [ ] Clearing the Name field and saving falls back to the default name rather than disabling Save
    - [ ] The validity rule for the New and Edit terminal sheets is defined once and shared

## [U14] Workspace forms reject a non-existent root path at create time (operator and boss) instead of failing later per-terminal
**#8** · `fixes-broken` · effort `M` · surface: Sheets & forms (workspace, edit, command palette) · operator+boss

**Problem:** createGroup/renameGroup validate only that name and rootPath are non-empty — no FileManager existence/isDirectory check and no tilde expansion. A typed or pasted bad root path is saved with a green light, becomes the default workingDirectory for every terminal in that workspace, and the only existence check is displaced to the per-session launch precheck — so the operator sees a per-terminal launch failure with no thread back to the form where the typo was made. Worse for the boss: the MCP createGroup action calls the same path and returns a success ack, then every createTerminal it issues into that group fails downstream, burning round-trips diagnosing a problem the create step should have rejected.

**Fix:** In createGroup/renameGroup, after the empty checks, expand ~ and verify the root path exists and is a directory; if not, set a path-specific errorMessage ('That folder doesn't exist: <path>') and return false so the sheet stays open on the field to fix (the New-Workspace sheet's guard already keeps it open and surfaces errorMessage). Mirror the same validation on the MCP createGroup path so the boss gets the rejection at create time, not at launch. Optionally offer to create the directory inline.

**User stories:**
- _As a operator creating or editing a workspace, I want the form to reject a root path that doesn't exist before the workspace is saved, so that I fix the typo right there instead of chasing a displaced terminal-launch error later._
    - [ ] Entering a non-existent root path and pressing Create keeps the sheet open and shows a path-specific error
    - [ ] A ~-prefixed path is expanded before the existence check
    - [ ] Editing a workspace to a non-existent path is rejected the same way
- _As a Ouro boss creating a workspace over MCP, I want the createGroup action to return a clear failure when the path doesn't exist rather than acking success, so that I don't get a success ack and then watch every terminal I create into that group fail._
    - [ ] The MCP createGroup action returns a clear failure when the path doesn't exist, instead of acking success and failing at launch

## [U15] Clone validates the agent-name inline and disables 'Open Clone' on a bad name, instead of mutating the command preview into an error
**#9** · `fixes-broken` · effort `S` · surface: Agent install / Hatch an Agent flow · operator

**Problem:** In the clone mode of OuroAgentInstallSheet the operator sees two bare fields, 'Git Remote' and 'Agent Name Override'. canInstall only checks the remote is non-empty, so the prominent 'Open Clone' button stays enabled even when the name is invalid; the only feedback for a bad name is that the monospaced command-preview line silently swaps to the thrown error text, and on click the failure is misattributed ('the link'). 'Override' is also opaque — a newcomer doesn't know it defaults to the repo name or that blank is fine. The native hatch form right next to it already renders clean inline validation (newAgentNameValidationMessage).

**Fix:** Rename the field to 'Agent name (optional)' with placeholder/help explaining it defaults to the repo name. Validate it inline reusing the existing newAgentNameValidationMessage-style messaging near the field, and reflect invalidity in canInstall so 'Open Clone' disables on a bad name instead of failing after click. Stop overloading the command-preview line as the error surface.

**User stories:**
- _As a operator cloning an existing agent from a Git remote, I want clear field labels and inline validation that tells me immediately when the name is unusable, so that I fix the name before clicking, instead of clicking a still-enabled button and getting a cryptic failure._
    - [ ] The optional-name field conveys it's optional and what it defaults to (no bare 'Override')
    - [ ] An invalid name shows a labeled inline error near the field, not as mutated command-preview text
    - [ ] The primary button is disabled while the name is invalid (canInstall reflects name validity, not just remote non-emptiness)
    - [ ] A valid clone proceeds with the same behavior as today

## [U16] In-app bug reporter tells the truth about what's anonymized: the screenshot and diagnostics zip are verbatim and stay local
**#10** · `fixes-broken` · effort `S` · surface: In-app bug reporter · operator

**Problem:** The disclosure line frames the whole bundle ('Includes a window screenshot, a support diagnostics zip…') then says 'The report text is anonymized — usernames, home paths, agent names, and tokens are stripped before it's saved or filed.' But the screenshot is captured as raw window pixels with zero redaction (so it can show home paths in titlebars/terminals, real agent names, branch names, on-screen output), and the diagnostics zip is copied verbatim with raw $HOME paths in its manifest — the redactor only ever touches report.md. The bundle-scope framing invites the operator to assume the whole bundle is scrubbed, so the careful operator who reads the disclosure is the one most misled. (Note: the screenshot and zip are never uploaded to the GitHub issue — only report.md is the issue body — but the operator can't tell that from this sheet.)

**Fix:** Make the copy precise about scope: the report TEXT is anonymized; the screenshot is a literal picture of your window and is NOT — review it before sharing; the diagnostics zip holds app logs/versions/environment and may include local paths. Add one line that the screenshot and zip stay on your Mac and are never uploaded to the GitHub issue (already true in code, just invisible in the sheet). No copy in the sheet should imply the screenshot or zip is scrubbed.

**User stories:**
- _As a operator filing a bug from inside Workbench, I want the disclosure to tell me exactly which parts of the bundle are anonymized, which are verbatim, and where each goes, so that I trust the privacy claim and don't accidentally leak my username/paths in artifacts I was told were 'anonymized'._
    - [ ] The info line distinguishes anonymized report text from the verbatim screenshot and diagnostics zip (names the broad zip contents in one short phrase)
    - [ ] Copy states the screenshot and diagnostics zip stay in the local bundle and are not uploaded when filing as a GitHub issue
    - [ ] No copy implies the screenshot or zip is scrubbed/anonymized when it isn't

## [U17] Two readiness systems can render contradictory verdicts (and tones) for the same machine — reconcile them under one contract
**#11** · `fixes-broken` · effort `M` · surface: TTFA autonomy readiness + repair flow (THE EXEMPLAR) · operator+boss

**Problem:** Two independent, never-reconciled readiness engines with different check sets, states, and copy registers. AutonomyReadinessBuilder (boss / boss-mcp / terminal-trust / terminal-resume / executables / recovery / boss-watch + login; states ready/attention/blocked) feeds the header TTFA pill; WorkbenchOnboardingAdvisor (daemon/agent/credential/provider-lane/mcp; states ready/needsAgent/needsDaemon/needsCredentials/needsRepair) feeds the wizard. They overlap on the boss agent + Workbench MCP bridge but share no evaluator and nothing cross-derives, and no test pins consistency. A real contradiction is demonstrable: TTFA has a terminal-trust blocker the wizard is blind to (header '.blocked — Human-free operation is blocked') while the wizard reports the warm 'X is ready'/'a couple of things need you' — same machine, two verdicts, two tones. The operator can't tell which is THE truth; the boss has no single readiness contract to reason about.

**Fix:** Pick one readiness as the source of truth and have the other derive from it (the TTFA snapshot subsumes onboarding's boss/mcp/credential checks, or both render from one shared evaluator). At minimum, evaluate the overlapping boss/MCP-bridge condition once and render it identically (same state, same copy register) in both surfaces, and add a test that pins the two surfaces cannot report contradictory readiness for the same fixture state.

**User stories:**
- _As a operator who checks both the TTFA pill and the boss-setup wizard, I want one consistent readiness verdict and tone wherever I look, so that I trust what the app tells me about whether autonomy is safe and never get whiplash from two conflicting headlines._
    - [ ] For any given machine state, the TTFA pill verdict and the wizard verdict express the same underlying conclusion (no 'blocked' in one and 'a couple of things need you' in the other for the same cause)
    - [ ] The boss/MCP-bridge condition is evaluated once and rendered identically (same state, same copy register) in both surfaces
    - [ ] A test pins that the two surfaces cannot report contradictory readiness for the same fixture state
- _As a Ouro boss reasoning about whether autonomy is safe, I want a single readiness contract to read rather than two heads that can disagree, so that my perception of readiness is consistent and auditable back to the operator._
    - [ ] The readiness condition the boss reads agrees with the verdict the operator sees on both the pill and the wizard for the same machine state

## [U18] Route every Hatch entry point to the native 'Create your agent' form — no newcomer lands in a raw `ouro hatch` CLI pane
**#12** · `removes-friction` · effort `M` · surface: Agent install / Hatch an Agent flow · operator

**Problem:** The polished native ProviderConfigSheet ('Create your agent' — name + provider + credentials, headless cold-start, no CLI pane, the path commit #222 built to kill the 'human becomes the agent's hands for job #0' seam) is wired to exactly ONE button, inside the wizard's Connect page. Every standalone Hatch entry point (empty-state button, both sidebar rows, File menu, boss menu, 'Hatch / Clone Another…', and an auto-trigger on first launch with no agents) instead opens OuroAgentInstallSheet, whose Hatch mode is a confirmation wrapper with NO input fields that renders the literal `ouro hatch` argv in monospaced text and on submit spawns a real CLI terminal the operator must converse with. The product ships the replacement AND the thing it replaces, and routes newcomers — and an empty-machine auto-launch — to the old CLI seam. The supporting copy compounds it: 'Hatch' and 'agent bundle' are unglossed Ouro jargon at the first newcomer touchpoint (the help tooltip explains 'hatch' with 'Ouro agent bundle'; the boss-name popover placeholder leaks 'agent bundle name').

**Fix:** Make presentNewAgentProviderConfigForm the destination for the primary Hatch entry points — at minimum the empty-state button, the 'Hatch Your First Agent' sidebar row, the File menu, and the no-agents auto-trigger — so creating an agent is filling three native fields with no CLI typing and no visible `ouro hatch` pane. Demote OuroAgentInstallSheet to an explicit 'Clone from a Git remote' affordance (its only unique capability; preserve it for clone). Lead the entry-point copy with plain language ('Create an agent' with a one-line 'why'); if 'Hatch' is kept as flavor, gloss it once on first encounter; replace the 'agent bundle name' placeholder with 'agent name'.

**User stories:**
- _As a newcomer who just opened Workbench with no agents installed, I want the prominent create-agent action (and the no-agents auto-launch) to open the friendly name+provider+credentials form the boss wizard uses, in plain language, so that I create my first agent by filling three fields, not by typing into a raw CLI conversation, and I understand what I'm making._
    - [ ] Clicking the empty-state create button (and the no-agents auto-trigger) opens ProviderConfigSheet in new-agent mode ('Create your agent'), NOT OuroAgentInstallSheet
    - [ ] The 'Hatch Your First Agent' sidebar row and File-menu entry route to the same native form
    - [ ] Creating an agent via that form requires zero CLI typing and spawns no visible `ouro hatch` terminal pane; no raw `ouro hatch` command preview is shown to a first-time creator
    - [ ] The primary create action's label and supporting copy are parseable by someone who has never used Ouro (no undefined 'hatch'/'bundle' as the only words); any user-facing 'agent bundle' (e.g. the boss-name placeholder) instead says 'agent name'

## [U19] The sidebar filter is trustworthy: structured owner:/status: queries go global, a zero-match state is explained, and the grammar is discoverable
**#13** · `fixes-broken` · effort `M` · surface: Sidebar & navigation · operator+both

**Problem:** Three compounding defects make the one tool meant to answer 'what's waiting on me' unreliable. (a) applySidebarFilter runs only over the selected workspace's sessions, so typing status:waiting silently scans one workspace — a blocked session in another workspace is invisible and an empty result falsely reads as 'nothing waiting,' a false-negative on the exact question the filter exists to answer (the boss's MCP equivalent is global). (b) When a filter hides every row the section renders only the 'New Terminal' row with no empty/no-results state, identical pixels to a genuinely empty workspace — tempting a needless New Terminal or filter-syntax doubt; Recovery and the command palette both use ContentUnavailableView here, this section doesn't. (c) The whole owner:/status: token grammar lives only in a hover tooltip and doc comments — no inline hint, example, chip, or autocomplete — so a first-timer never discovers they can ask 'what's waiting on me.'

**Fix:** (a) Run owner:/status: token queries across ALL workspaces (group results by workspace, or surface 'N more in other workspaces — search all'); add a one-line scope indicator in/under the field ('Searching: <workspace>' vs 'Searching: all') so scope is never silent. (b) When the filter is non-empty and yields zero matches, render a ContentUnavailableView-style row inside the section ('No sessions match "<query>"' + a one-click Clear filter using the existing clear action), distinct from a 'No terminals yet' hint when the filter is empty. (c) Surface the grammar where the operator looks: a rotating example placeholder ('Filter — try status:waiting') and/or tap-to-insert suggestion chips (Waiting · Agent · Idle), keeping plain-text matching as the zero-learning default. (Drop the speculative cross-workspace 'Search all' button for the empty state; no cross-workspace session search exists yet beyond what (a) adds.)

**User stories:**
- _As a operator triaging what needs my attention, I want to type status:waiting and see every session waiting on me regardless of workspace, with a clear message when a filter hides everything and a way to discover the grammar, so that an empty result actually means nothing is waiting, I never miss a blocked session in an unselected workspace, and I don't mistake a hidden list for an empty workspace._
    - [ ] Typing a status: or owner: token searches across all workspaces; when matches exist outside the selected one they are shown (grouped) or offered via a visible affordance
    - [ ] The filter field shows its current scope (this workspace vs all) so scoping is never invisible, and an empty filtered result is trustworthy
    - [ ] A non-empty filter with zero matches shows an explicit 'No sessions match <query>' state with a one-click Clear filter, distinct from a genuinely-empty-workspace hint
    - [ ] The filter field communicates at least one structured example inline (placeholder or chips), with a one-tap way to insert a status:/owner: token; plain-text filtering still works with no learning required

## [U20] The boss can read its TTFA autonomy snapshot over MCP and be pointed at a 'get to green' ask — it has the hands but not the sensor
**#14** · `fixes-broken` · effort `M` · surface: Boss MCP tool surface (the AGENT-as-user surface) · boss+both

**Problem:** The boss-facing MCP surface has no tool returning the AutonomyReadinessSnapshot — the 8-check TTFA verdict the operator sees — even though workbench_request_action already exposes setTrust, setAutoResume, repairAgent, registerWorkbenchMCP, requestProviderConfig, verifyProvider (the hands to clear almost every TTFA blocker). So the boss can read raw per-session JSON but cannot read the rolled-up 'is TTFA green, and which check is red' verdict; it must reverse-engineer it heuristically, costing round-trips and risking wrong conclusions. And the TTFA popover's only boss button fires the generic 'what's going on' check-in, never a 'help me get TTFA green' prompt — so the boss is never even pointed at the repair journey. The auditable-trust loop never closes for autonomy readiness.

**Fix:** Add a workbench_autonomy_readiness read tool returning the same snapshot the operator sees (overall state + each check's id/label/detail/state), with a description mapping blockers to action verbs (terminal-trust→setTrust, terminal-resume→setAutoResume, boss-bridge→registerWorkbenchMCP, etc.). Fold a one-line autonomy verdict into the workbench_status check-in prompt. Re-point the popover's primary boss action from a generic check-in to a scoped 'Get TTFA to green' ask that hands the boss the snapshot and lets it queue the fixes (which then show up in Applied Actions).

**User stories:**
- _As a Ouro boss operating Workbench over MCP, I want to read the live TTFA autonomy-readiness snapshot and act on its blockers in one round-trip, so that I can answer 'is autonomy hands-off ready, and what's blocking it' and clear the fixable blockers without the operator hunting._
    - [ ] An MCP read tool returns the full autonomy-readiness snapshot (overall state + each check's id, label, detail, state) for the current machine
    - [ ] The tool description tells the boss which blockers map to which request_action verbs
    - [ ] The workbench_status check-in prompt includes a one-line autonomy verdict so the boss sees readiness without a second call
    - [ ] After the boss queues e.g. setTrust for an untrusted terminal, a re-read of the readiness tool shows that check turned green
- _As a operator who set up a boss, I want the TTFA popover's boss button to ask a TTFA-scoped 'get to green' question and the boss's fixes to appear in Applied Actions, so that the boss is pointed at clearing my blockers and I can audit what it did._
    - [ ] The popover's primary boss button asks a TTFA-scoped question, not the generic 'what's going on' check-in
    - [ ] Fixes the boss queues for readiness blockers appear legibly in the action log

## [U21] Surface Boss Watch — the hands-off master switch — and the boss's action receipts in the always-visible boss area
**#15** · `removes-friction` · effort `M` · surface: Header & toolbar · operator+both

**Problem:** The most consequential autonomy decision is the least legible. Boss Watch (the on-by-default switch that makes the boss act automatically) lives only inside the icon-only 'More' (…) overflow menu, sandwiched between 'Clear Recent Workspaces' and 'Refresh Status,' with its on/off state hidden until the menu is opened, while the header gives prominent always-visible real estate to the TTFA pill (which only describes readiness) and Check In (a one-shot pull). The popover's 'Watch' button appears only when watch is OFF, so in the default ON state there's no glanceable header indicator and no header/popover way to pause autonomy. Relatedly, the boss's executed-action ledger (ActionLogView — source/action/target/result with success/failure glyphs, the receipt for every autonomous action) is buried inside 'Show Advanced' next to recovery-drill/runtime and shows only entries.prefix(1) collapsed, so a FAILED autonomous action is invisible by default — undercutting the TTFA auditable-trust story that 'every decision is in the log.'

**Fix:** Surface Boss Watch state next to the TTFA pill so the operator can SEE and FLIP hands-off operation from the header without opening the overflow (keep the More-menu entry as a secondary path; make the popover's watch control bidirectional). Promote a compact action ledger out of 'Advanced' into the default boss pane (e.g. 'Recent actions: 3 ok · 1 failed' that expands inline), surfacing FAILED autonomous actions prominently; keep deep tooling (transcript search, runtime, drill) under Advanced.

**User stories:**
- _As a operator deciding whether to trust the boss to keep things moving, I want to see at a glance whether Boss Watch is on and toggle it from the header, and to see the actions the boss just took (and any failures) without opening Advanced, so that I always know whether the boss is empowered to act, can pause it in one click, and can trust autonomous actions because their receipts are in plain sight._
    - [ ] The header shows, without opening any menu, whether Boss Watch is currently on or off, and Boss Watch can be toggled directly from the header
    - [ ] The TTFA pill/autonomy area and the Boss Watch state read as a coherent pair (readiness + whether autonomy is actually running)
    - [ ] A compact recent-actions summary (counts of ok/failed) is visible in the default boss pane, with failed autonomous actions surfaced prominently
    - [ ] The full action log remains expandable without forcing the operator into the Advanced tooling cluster
- _As a Ouro boss whose decisions must be legible back to the operator, I want the operator to be able to confirm 'is the boss empowered to act right now' and see my executed actions by default, so that the auditable-trust loop closes — the operator can see both my authority and my receipts at a glance._
    - [ ] Whether the boss is empowered to act (Boss Watch state) is readable from the header without digging
    - [ ] The boss's executed-action receipts are visible in the default boss pane, not hidden behind a power-user disclosure

## [U22] The Decision Inbox is reachable by clicking the count it shows — not only by knowing ⌘K / ⌘J
**#16** · `removes-friction` · effort `S` · surface: Boss legibility: dashboard, decision log, what-is-going-on · operator+both

**Problem:** The boss pane shows the live count of open escalations ('inbox: N', 'needs me: N') as plain non-interactive MetricChips, but the DecisionInboxSheet — the auditable-trust centerpiece — is presented ONLY via the ⌘K command palette or the ⌘J jump loop. There is no button, no badge tap, nothing visible that opens it; two code comments even claim it is 'Reached from the boss pane' but no such affordance exists. When the boss pane is collapsed the count vanishes entirely, so the only signal that the boss escalated something is gone too. An operator who sees 'inbox: 2' has no door — a dead affordance showing an alarming number, on the surface whose whole job is making trust legible.

**Fix:** Make the open-inbox signal the door: when openInbox > 0, render a prominent tappable pill at the top of the boss pane ('N waiting on you →') that opens the inbox, with a severity tint from the top group; make the 'inbox' MetricChip itself tappable to the same sheet. Keep a reachable count badge (e.g. on the 'Show Boss Pane' header button) when the pane is collapsed so an escalation is never silently buried. With openInbox == 0 the element is calm/absent — no dead zero-count button.

**User stories:**
- _As a operator who set up an Ouro boss, I want to click the 'N waiting' indicator in the boss pane and land directly in the Decision Inbox, so that I can see and triage what the boss escalated without knowing a keyboard shortcut or hunting a command palette._
    - [ ] When openInbox > 0 the boss pane shows a visibly tappable element whose label reflects the count and top severity, and clicking it opens the DecisionInboxSheet to the prioritized open queue
    - [ ] The same affordance (or a count badge) remains reachable when the boss pane is collapsed
    - [ ] With openInbox == 0 the element is calm/absent — no dead zero-count button

## [U23] Boss dashboard stops alarming and starts acting: humanize Decision-Log fields, replace bare '?' placeholders, and make 'Needs Me' items clickable
**#17** · `removes-friction` · effort `M` · surface: Boss legibility: dashboard, decision log, what-is-going-on · operator+both

**Problem:** Three legibility/dead-affordance defects on the trust dashboard. (a) Every DecisionLogRow footer prints raw developer telemetry — 'status: <rawValue>' (boss-side lifecycle: recorded/applied/overridden) and 'source: <actor id like boss:slugger>' — and the Teach button's polarity silently inverts by decision kind (pill says 'Auto-advance', button says 'always ask me instead'), so a first-timer decodes which choice reinforces vs corrects. (b) DashboardMetricsStrip/VisibilityStrip render 'needs me'/'coding'/'blocked'/'owed'/'returns' as a bare '?' when a sub-probe is unavailable, visually identical to a real value — reading as 'something's broken' when it may be a transient probe, with the why hover-only and no retry; a genuine zero isn't clearly distinct from 'unavailable'. (c) The 'Needs Me'/'Coding' columns — the boss's highest-intent 'these need you' content — render prefix(3) as single-line truncated plain Text (not buttons), silently dropping items 4+; each MailboxNeedsMeItem already carries a navigation ref the UI throws away, and the clickable SessionStatusListView sits right below.

**Fix:** (a) Drop raw status/source rawValues from the operator view (keep in hover/raw-log) or map to plain words ('decided by: Boss Watch', 'open / handled'); make the Teach control present both intents explicitly (segmented 'Do this automatically next time' / 'Always ask me'). (b) Replace bare '?' with a clearly 'not-a-value' state (muted dash + info glyph revealing the specific issue code+detail) plus a one-click 'Retry' that re-runs just that probe; keep a genuine zero visually distinct from 'unavailable'. (c) Make each Needs Me/Coding item a button that navigates via its existing ref/taskRef; when count > 3 show a 'View all N' control instead of silent truncation; reconcile thoughtfully with the Sessions 'Waiting on you' bucket (different sources/targets) rather than blind-merging.

**User stories:**
- _As a first-time operator reading the boss dashboard and Decision Log, I want each row in plain language, a chip that can't report yet to say so plainly and let me retry it, and the boss's 'these need you' list to be something I can click, so that I can act on what needs me and teach the boss without decoding raw field names, inverting buttons, unexplained '?' alarms, or a truncated read-only teaser._
    - [ ] No raw enum rawValue or internal actor id appears in the operator-facing Decision Log row; values are plain-language or moved to help/raw-log, and the teach control presents both intents explicitly
    - [ ] An unavailable metric renders as a clearly 'not a real value' state (not a bare '?'), exposes its specific reason without hover-only guessing, offers a one-click retry, and a genuine zero is visually distinct from 'unavailable'
    - [ ] Each Needs Me/Coding item is clickable and navigates to its underlying target via the ref it already carries; when more than three exist a clear 'View all N' control appears instead of silent truncation

## [U24] One-call attention queue + readback for the boss: filter sessions by needs-human and confirm queued actions landed
**#18** · `removes-friction` · effort `M` · surface: Boss MCP tool surface (the AGENT-as-user surface) · boss+both

**Problem:** The boss's core polling job costs more round-trips than it should and its actions can't be confirmed. (a) workbench_sessions filters only by owner/name/includeArchived — there is no attention/needsHuman filter and no attention-queue tool, even though every SessionSnapshot already carries attention + needsHuman; workbench_status returns the whole machine as one ~150-line prose blob, not a queryable list. So to answer 'what's waiting on me' the boss must fetch ALL sessions and re-derive the subset LLM-side every poll (more tokens/latency, non-deterministic — two polls can disagree). (b) request_action/create_session return a requestId ack ('returns only an enqueue ack, NOT the result') but no tool reads that requestId's outcome and the action-log entry carries no requestId — so to learn 'did my recover/sendInput land' the boss re-pulls the status blob and heuristically guesses which recent log line was its request, impossible when two similar actions are in flight. The queue already keys its lifecycle by requestId, so the handle exists but leads nowhere.

**Fix:** (a) Add an attention/needsHuman filter to workbench_sessions (e.g. attention:["waitingOnHuman","blocked","needsBossReview"]) so the boss can request only the queue in one round-trip, with each waiting/blocked row carrying the inline prompt snippet the operator path already computes (ideally a thin workbench_attention_queue alias). (b) Stamp the originating requestId onto the WorkbenchActionLogEntry when the app drains the queue, and add a workbench_action_result(requestId) tool returning {state: queued|applied|failed, result} (mirroring proposal_result's not-ready/ready shape) so a not-yet-drained request polls cleanly instead of erroring.

**User stories:**
- _As a Ouro boss on a polling watch loop, I want one tool call returning only the sessions needing a human (each with its waiting-prompt text), and a way to poll the requestId I got back to learn whether my action applied, so that I report 'what's waiting' and confirm 'fixed' in single cheap round-trips instead of fetching the whole machine and guessing from a prose blob._
    - [ ] workbench_sessions accepts an attention/needsHuman filter and returns only matching sessions; a loop that only cares about the attention queue never receives idle or archived sessions
    - [ ] Each returned waiting/blocked row includes the inline prompt snippet the operator-facing path already computes
    - [ ] request_action's requestId can be passed to a result tool returning queued/applied/failed plus the result text, and the action-log entry carries the originating requestId so request and outcome share a key
    - [ ] A not-yet-drained request returns a not-ready state, never an error, so the boss can poll cleanly
- _As a operator auditing what the boss did, I want the boss to be able to say 'request X applied' rather than 'I think it worked', so that autonomous actions are legibly confirmed rather than inferred._
    - [ ] The action-log entry the app writes shares a requestId key with the boss's queued request so outcomes are attributable

## [U25] The boss's self-description matches reality: complete the tool catalog and stop falsely flagging agent-owned sessions as 'waiting on you'
**#19** · `fixes-broken` · effort `M` · surface: Boss MCP tool surface (the AGENT-as-user surface) · both+boss

**Problem:** Two honesty defects in what the boss is told about itself and about sessions. (a) WorkbenchGuide.bossTools lists only 9 of the 14 advertised tools/list tools — missing workbench_onboarding_status, workbench_session_health, workbench_discover_agent_sessions, workbench_propose, workbench_proposal_result — and bossTools is the single source feeding the check-in prompt, workbench_sense, and the inner-agent context file. So a boss enumerating its capabilities from its briefing gives an incomplete answer, and the doc-drift test only checks bossTools⊆doc, not advertised⊆bossTools. (b) workbench_status computes the inline waiting-prompt ONLY for human-owned sessions, but still lists agent-owned sessions with raw attention=waitingOnHuman, and workbench_sessions reports needsHuman:true for them — so a row reading status=waitingForInput, attention=waitingOnHuman, needsHuman=true, owner=agent:foo looks exactly like a session begging for input but is off-limits to drive and has no prompt attached; the only 'hold, agent-driven' signal is one preamble sentence, not on the row. The boss wastes a transcript fetch or falsely tells the operator an agent's own loop needs them.

**Fix:** (a) Single-source the catalog (make bossTools the literal source tools/list iterates, or add a test asserting set-equality between tools/list names and bossTools) and add the 5 missing entries with one-line summaries, so adding/removing a tool fails the build until catalogs agree. (b) On agent-owned sessions, stamp the row with an explicit driver/actionable flag (e.g. driver:agent, actionable:false) and have needsHuman / workbench_sessions reflect that an agent-driven prompt is not a human-attention item, so the 'this is informational, hold' signal lives on the data, not only in preamble prose. Distinguish 'agent's own loop is driving it' from a genuine boss-raised needsBossReview so suppression doesn't hide real review items.

**User stories:**
- _As a Ouro boss reading my Workbench briefing and triaging sessions, I want the capability list to name every workbench_* tool I can actually call, and agent-owned sessions to be marked agent-driven (not human-actionable) on their own row, so that I can propose plans and discover/recover orphaned sessions instead of believing those abilities don't exist, and I don't waste a fetch or falsely tell the operator an agent's own loop needs them._
    - [ ] The tool names in workbench_sense / the check-in prompt are exactly the set returned by tools/list (verified by a set-equality test); the 5 missing tools each appear with a one-line summary; adding or removing a tool fails the build/test until catalogs agree
    - [ ] An agent-owned session's row carries an explicit driver/actionable flag distinguishing it from a human-attention item, identifiable from the row data without reading the preamble
    - [ ] needsHuman (or an equivalent field) does not read true for a session being driven by its owning agent's loop, while a genuine boss-raised review item is still surfaced

## [U26] Trim and de-jargon the opt-in boss wizard: drop the redundant Welcome page, delete the dead scan/arrange UI, and name the recover-work step one thing
**#20** · `removes-friction` · effort `M` · surface: Opt-in boss-setup wizard (Choose Boss / Connect / Arrange Work) · operator+both

**Problem:** Three intentionality defects in the now-opt-in wizard. (a) The Welcome splash adds no value: its three points ('Keep Your Tools'/'Choose a Boss'/'Recover the Thread') just restate the three following pages, and since the wizard is entered only after the operator already clicked 'Set up a boss,' it front-loads a click before the first real decision. (b) The recover-work step wears three names — nav 'Arrange Work', heading 'Bring back your work', button 'Bring Back My Work' (and the welcome card's 'Recover the Thread') — and 'Arrange' is stale jargon from a removed flow; nothing on the page arranges anything. (c) That stale 'Arrange' vocabulary leaks straight from an unreachable legacy scan/arrange UI (legacyScanBody + the .scanProposal/.arrangeApprovedImports/.bossReadyWelcome phases the flow policy can no longer produce) still shipping behind the import page, carrying a second contradictory recover-work mental model.

**Fix:** (a) Drop the Welcome page and open the wizard directly on Choose Boss (3 pages; progress dots auto-tighten from allCases); if a one-line orientation is wanted, fold it into a Choose Boss subtitle. (b) Set OnboardingPage.importWork.title to the real action ('Bring Back Work'/'Recover Work') so header, progress-dot a11y label, page heading, and button all agree; drop 'Arrange'. (c) Delete legacyScanBody and the three unreachable phases plus their dead arms in advance()/primaryActionImage and the flow enum, keeping only .bossSetupWizard, .bossReconstruct, and .duplicateCleanup (do NOT delete .duplicateCleanup); update the OnboardingNarrativeTests that assert on the dead strings.

**User stories:**
- _As a operator who just clicked 'Set up a boss', I want to land directly on choosing my boss, with the recover-work step called the same thing in the nav, heading, and button, so that I reach the first real decision immediately and don't get whiplash from a header that says 'Arrange Work' over a page that says 'Bring back your work'._
    - [ ] Opening the opt-in wizard lands on the Choose Boss page; there is no standalone intro page whose only content restates the following pages, and the progress indicator reflects the reduced count
    - [ ] The recover-work step's header, progress-dot a11y label, page heading, and primary button all use one consistent name describing the actual behavior; the word 'Arrange' no longer appears as a page title in the reachable wizard
- _As a Workbench maintainer / boss reading the wizard as a narrative surface, I want the wizard to contain only the reconstruction flow that actually runs, with no unreachable scan/arrange UI behind it, so that the product has one coherent recover-work model and the stale 'Arrange' naming has no source to leak from._
    - [ ] The import/recover page renders only the boss-driven reconstruction surface; no code path can show the legacy Scan/Arrange buttons or proposal cards, and the flow-phase enum no longer carries phases the policy cannot produce
    - [ ] No user-visible string in the reachable wizard refers to 'scan' or 'arrange' as the recover-work action

## [U27] Choose Boss is a pure pick: remove the per-row 'Enable Tools' button that competes with selection and duplicates the Connect step
**#21** · `removes-friction` · effort `M` · surface: Opt-in boss-setup wizard (Choose Boss / Connect / Arrange Work) · operator+both

**Problem:** On a page whose whole job is 'pick who watches this Mac,' OnboardingBossChoiceRow renders, per agent, BOTH a tap-to-select radio AND a trailing button cycling 'Enable Tools'/'Update Tools'/'Tools On' that runs select-if-needed + install-MCP — two competing tap targets that both 'choose this boss,' so the operator hesitates (tap the row, the button, or both?). The exact same MCP registration is then surfaced again on the next page as the 'Connect Workbench tools' repair step with its own 'Register' button, so one logical action ('give this boss the Workbench tools') spans two pages under inconsistent verbs (Enable Tools / Tools On / Register). For the boss/auditable-trust lens, tool-registration legibility is split across two pages with inconsistent vocabulary.

**Fix:** Make Choose Boss a pure pick: selecting an agent silently ensures its Workbench tools (registerWorkbenchForBossChoice already does select+install) — remove the standalone per-row Enable/Update/Tools-On button. Let the Connect page's 'Connect Workbench tools' repair step be the single honest place that shows tool status and offers a fix only when registration isn't current. One action, one verb, one location.

**User stories:**
- _As a first-time operator on the Choose Boss page, I want to pick my boss by selecting it, without a second per-row button that looks like a separate required step, so that I'm confident choosing an agent is all I need to do here, and I'm not asked to register the same tools again on the next page._
    - [ ] Selecting an agent on Choose Boss is the only affordance needed to proceed; there is no separate per-row tools button competing with selection
    - [ ] Workbench-tools registration is shown and actionable in exactly one place across the wizard, with one consistent verb
    - [ ] If the selected boss's tools are already registered, no 'connect/enable tools' step nags the operator on a later page

## [U28] Boss-actionable recovery breakdown: split the scalar recovery counts by how the boss may act (reattach / resume / respawn / needs-human)
**#22** · `removes-friction` · effort `S` · surface: Restart / reboot recovery & resume (P0) · boss+both

**Problem:** Two boss-facing recovery text scalars don't reflect the classification the product already computes elsewhere. workbench_visibility's 'recoverable=N' counts raw run-status .needsRecovery BEFORE the recovery plan is computed, so it lumps lossless reattach (always safe for the boss to trigger), side-effectful respawn (re-runs a command), and manualActionNeeded (which the boss literally cannot recover — needs the human) into one number, inflating what the boss is told it can act on; and the workbench_sense pulse (oneLineStatus) excludes reattach and merges the rest. The richer per-session action=/reason= classification already exists on the boss's primary workbench_status tool and the operator's TTFA recovery check already splits manual from auto — but these two text scalars don't, so a bare 'recoverable=3' tells the boss neither what it can safely self-execute nor what it must escalate.

**Fix:** Make the boss-facing recovery scalars reflect the existing RecoveryAction classification: source 'recoverable=N' from the recovery PLANS (not raw status, so human-only stops inflating it) and break the pulse into reattach=N (safe, no loss) / auto_resume / respawn / needs_human, so the boss knows without guessing which it may trigger via request_action and which it must surface to the operator. Keep the operator's audit legible by logging the boss's recover actions with the same classification.

**User stories:**
- _As a Ouro boss answering 'what can I keep moving after the restart?', I want the recovery signal broken down by how I'm allowed to act — safe lossless reconnect vs side-effectful respawn vs human-only, so that I resume what's safe in one round-trip and escalate only what genuinely needs the human, and the operator can audit that I did so._
    - [ ] The boss's quick recovery scalar reports a per-class breakdown (reattach/auto_resume/respawn/needs_human), not a single 'recoverable' integer
    - [ ] Sessions classified manualActionNeeded are not counted as boss-actionable 'recoverable'
    - [ ] When the boss triggers a recovery, the action log records the classification so the operator can audit which sessions the boss resumed vs escalated

## [U29] Get-or-create on the boss session-create path: one MCP call provisions a workspace and lands a terminal in it
**#23** · `removes-friction` · effort `M` · surface: Sheets & forms (workspace, edit, command palette) · boss

**Problem:** The boss-facing create path couples like the human forms: workbench_create_session / createTerminal resolve the target group via resolveGroup, which throws 'No unique group matches <value>. Create it first via workbench_request_action (createGroup)' when the named group doesn't exist. So to put a terminal in a not-yet-existing workspace the boss must issue createGroup, poll/confirm it drained (createGroup returns only an enqueue ack), then issue create_session referencing it — a multi-call + poll round-trip tax with a failure-prone intermediate on a fresh machine, when the most natural action ('start a terminal for this project') should be one call.

**Fix:** Add an opt-in get-or-create affordance on the session-create path: accept the group by name plus a rootPath (or a createGroupIfMissing flag) so a single workbench_create_session call provisions the group when absent and lands the session in it, returning both the resolved group id and the new session id. Keep the strict must-already-exist behavior as the default for callers that pass a known group. (Scope is boss-only — the human New Terminal sheet has no group picker, so there is no equivalent inline shortcut to add there.)

**User stories:**
- _As a Ouro boss keeping work moving on a fresh machine, I want to create a terminal in a named workspace in one call, provisioning the workspace if it doesn't exist yet, so that I get a session running in the fewest round-trips instead of orchestrating create-group-then-create-terminal._
    - [ ] A single create-session MCP call can target a named group and create that group (with a given root path) if it is missing
    - [ ] The call returns both the resolved group id and the new session id
    - [ ] Strict must-already-exist behavior remains available for callers that pass a known group

## [U30] Bug-report outcomes persist and the boss can file one: durable filed-status + an MCP report-bug tool
**#24** · `removes-friction` · effort `M` · surface: In-app bug reporter · operator+boss

**Problem:** Two gaps around the bug bundle as a durable, agent-reachable artifact. (a) The filed GitHub-issue URL lives only in a transient @Published var and is never written into the bundle; report.md is composed before filing and never written back. So once the sheet closes the operator can't tell which past report was actually filed or its issue URL, and the boss-visible action log conveys only a terse 'Filed <url>' one-liner that can roll off the 200-entry cap — neither can later answer 'was this bug filed?' reliably. (b) The MCP surface has no tool to file or list bug reports — bug reporting is a human-only sheet path — so the boss, the consumer best positioned to notice 'this session is wedged / a recovery drill failed / an MCP action didn't apply,' must drop the defect in prose; a boss-detected issue never becomes an auditable, operator-visible artifact.

**Fix:** (a) Persist per-report outcome alongside the bundle (filed URL + filed/unfiled status, optionally completeness) — a small status file or index — so both the operator (re-opening the folder/sheet) and the boss (via a read) can answer 'filed? where?' after the sheet closes. (b) Expose a workbench_report_bug tool that runs the same anonymized BugReportWriter path (enqueueing an action the app drains, since the bundle needs live app state) and returns the bundle path + collection warnings, so the boss can capture a defect in one round-trip and the operator can later File-as-Issue from the existing card; optionally a read side to enumerate recent reports + filed status to avoid duplicates. The tool's description states what is/isn't anonymized (text yes, screenshot no). Keep filing-to-GitHub human-gated.

**User stories:**
- _As a operator (and boss) reviewing past bug reports, I want each report's filed status and issue URL to persist after the sheet closes, so that I can tell which bugs were actually sent without re-deriving it._
    - [ ] A report's filed/unfiled status and issue URL survive closing the sheet and are retrievable by the operator and via a boss read
    - [ ] The boss-visible audit/action log conveys whether the report was filed and where, not just a one-liner that can roll off
- _As a Ouro boss watching sessions via MCP, I want a tool to capture a Workbench/session defect into the same anonymized bug bundle a human would create, so that defects I detect become auditable artifacts the operator can review and file, instead of vanishing into chat._
    - [ ] An MCP tool creates a bug-report bundle using the existing redaction path and returns the bundle path + collection warnings
    - [ ] The created bundle appears to the operator the same way a human-created one does (revealable, File-as-Issue available)
    - [ ] The tool's description states what is and isn't anonymized (text yes, screenshot no) so the boss can relay an honest privacy note

## [U31] Header zero-jargon + tray calm: hide '0 running, 0 recovery actions' on a quiet machine and calm the menu-bar Boss/TTFA before a boss exists
**#25** · `removes-friction` · effort `S` · surface: Header & toolbar · operator+both

**Problem:** Two leftover loud/jargon surfaces that undercut the shipped calm first-run header (U5). (a) HeaderView renders model.summary.oneLineStatus unconditionally next to the (now calm) boss selector, so a fresh no-boss machine reads 'No boss yet · 0 running, 0 recovery actions' — two information-free zeros plus 'recovery actions,' internal jargon for a RecoveryPlan count (the human concept, per the Recovery sheet, is 'sessions that didn't survive a restart'); the same low-signal line also feeds the boss prompt builder. (b) The NSStatusItem tray menu independently renders 'Boss: <name>' and 'TTFA · <state> — <headline>' and reads alarmingly on a fresh first run — the same false-alarm-before-a-boss-exists problem U5 fixed in the in-window pill, surviving on a second surface.

**Fix:** (a) When there's nothing notable (0 running AND 0 recovery), render nothing or a calm 'All quiet' instead of the count string; replace 'recovery action(s)' with wording consistent with the Recovery sheet ('sessions waiting to recover'); only show the count line when a count is non-zero so the header stays signal-dense. (b) Reuse the Core HeaderCalmPresentation seam in the tray menu so the no-boss state reads calm there too.

**User stories:**
- _As a operator who just launched Workbench with no boss and no sessions, I want the in-window header and the menu-bar menu to stay calm — no zero-counts, no recovery jargon, no alarming Boss/TTFA before a boss exists, so that first run reads as 'ready and quiet,' not an ops dashboard full of zeros and an unexplained recovery subsystem._
    - [ ] With 0 running and 0 recovery items the header shows no count string (or a calm 'All quiet'), not '0 running, 0 recovery actions'; the word 'recovery action' is replaced with Recovery-sheet-consistent language; when counts are non-zero the informative string still appears
    - [ ] The menu-bar (tray) menu reads calm in the no-boss state, consistent with the in-window calm header, via the shared HeaderCalmPresentation seam

## [U32] Default workspace name is a neutral home, and its terminals section names the relationship instead of repeating it
**#26** · `removes-friction` · effort `S` · surface: Sidebar & navigation · operator

**Problem:** Two related sidebar legibility defects. (a) The bootstrapped default workspace is named 'Unsorted Sessions' — a state-claiming word telling a first-time operator their sessions are mis-filed / pending cleanup on a clean install where nothing has happened, a mild false alarm and a chore-implying name at the exact moment the product should feel like a ready home (it also becomes an odd handle the boss reasons with by name). (b) The selected workspace's name then renders twice — as a row in the 'Workspaces' section and as the bare header of the terminals section below — with no label tying them together, so on first run the operator sees the identical string twice (worst case 'Unsorted Sessions' verbatim) and must reverse-engineer the master/detail relationship.

**Fix:** (a) Rename the bootstrap default to something neutral and inviting ('Home', 'My Terminals', or the home folder basename); reserve any 'unsorted/unfiled' language for an actual catch-all bucket if one is ever introduced; migrate or leave existing user-named workspaces intact (don't force-rename user data; update the two pinned tests). (b) Title the terminals section to express its relationship ('Terminals in <workspace>') rather than the bare name, and strengthen the selected-workspace affordance in the Workspaces list (e.g. a leading accent bar) so the header reads as a relationship, not a repeat.

**User stories:**
- _As a operator on a fresh install scanning the sidebar, I want my default workspace to have a neutral welcoming name and the terminals section to clearly belong to the selected workspace, so that I'm not told my sessions are 'unsorted' before I've created one, and I don't read the duplicated name as redundancy or a bug._
    - [ ] The bootstrapped default workspace name does not imply disorder or pending cleanup, and reads sensibly as both a workspace row and a section header; existing user-named workspaces are not force-renamed
    - [ ] The terminals section header expresses its relationship to the selected workspace (e.g. 'Terminals in <workspace>'), and the selected workspace in the Workspaces list is obviously the one whose terminals are shown below

## [U33] Collapse the two adjacent session-action menus into one sectioned menu with no duplicated commands
**#27** · `removes-friction` · effort `S` · surface: Session detail (terminal view, controls, attention) · operator

**Problem:** The running session header carries TWO adjacent overflow menus: a 'Session Controls' menu (Focus/Redraw/Restart/Ctrl-C/Esc/EOF, plus Copy Launch Command and Open Working Directory) and a 'More' menu (Ask Boss + Copy Launch Command + Open Working Directory + Edit/Duplicate/Move/Archive/Delete). 'Copy Launch Command' and 'Open Working Directory' appear in BOTH, the split boundary is arbitrary (Restart, a relaunch action, sits in the send-keys menu while Edit/Duplicate sit in the other), and 'Session Controls' is a generic container label that names no capability. A first-timer can't predict which menu holds which action and finds the same two commands in each — a guess-which-menu tax with duplication signaling the split is incidental, not designed.

**Fix:** Collapse to one overflow menu (plus the primary Stop) with labeled sections — e.g. 'Send' (Ctrl-C/Esc/EOF/Redraw), 'Window' (Focus), 'This Session' (Copy Launch / Open Dir / Edit / Duplicate / Move / Archive / Delete / Restart), plus 'Ask Boss About This Session' near the top. Remove the duplicated Copy Launch Command / Open Working Directory. Drop the generic 'Session Controls' label or fold it into 'More' so no visible control is labeled with a container word.

**User stories:**
- _As a operator looking for a session action, I want one predictable sectioned overflow menu with no duplicated commands, so that I don't open two menus and guess which holds Redraw vs Archive._
    - [ ] The running session header exposes a single overflow menu (plus the primary Stop), not two adjacent menus, with send-key / window / lifecycle actions under clear section labels
    - [ ] No command appears in more than one menu (Copy Launch Command / Open Working Directory appear once)
    - [ ] No visible control is labeled with a generic container word like 'Session Controls'

## [U34] New Workspace auto-fills its name from the chosen folder so Create is never gratuitously disabled
**#28** · `removes-friction` · effort `S` · surface: Sheets & forms (workspace, edit, command palette) · operator

**Problem:** NewTerminalGroupSheet starts name='' and disables Create until a non-empty name is typed; picking a root folder via Choose sets the path but does NOT populate the name field — there is no lastPathComponent autofill — so the single most common workspace name (the folder's own basename) must always be hand-typed, and Create sits disabled on first open. This is the same empty-state-with-a-disabled-primary friction U4 removed for terminals, still alive for workspaces; the New Terminal sheet already implements exactly the autofill pattern (an onChange that only fills when the field is still empty).

**Fix:** When the user picks a root path via Choose (or the sheet opens with a path set), default the Name field to that path's last component if Name is still empty — porting the New Terminal sheet's empty-guarded onChange pattern (re-targeted to the path change). Keep it editable and don't overwrite a name the operator typed first; optionally allow Create with an empty name by defaulting to the folder basename at create time.

**User stories:**
- _As a operator setting up a workspace for a project folder, I want the workspace name to default to the folder I pick, so that I create a workspace in one or two clicks instead of retyping a name the app already knows._
    - [ ] Choosing a root folder auto-fills the Name field with the folder's basename when Name is empty, and the auto-filled name remains editable
    - [ ] I am not blocked by a disabled Create button when a sensible default name is derivable, and if I type my own name first, choosing a folder does not overwrite it

## [U35] Replace the raw `ouro clone` command pane with a native, inline-progress clone flow
**#29** · `removes-friction` · effort `M` · surface: Agent install / Hatch an Agent flow · operator

**Problem:** Even after the primary Hatch entry points are routed to the native form (U18), OuroAgentInstallSheet's clone path remains a CLI seam: it renders the literal `ouro clone <remote> --agent <name>` argv in monospaced text as its centerpiece, its primary button reads 'Open Clone' with a terminal icon, and submitting spawns an actual CLI terminal session the user must converse with — the antithesis of the sibling ProviderConfigSheet's 'reads as one product, no CLI seams' posture. The cold-start hatch path already proves inline headless reporting is possible; clone is the remaining surface that shells out visibly.

**Fix:** Keep a native clone form (remote URL + optional name, with the inline validation from U15) but do the clone headlessly with progress and inline success/failure, not by exposing the `ouro clone …` string and an 'Open Clone' terminal pane — mirroring how the cold-start hatch path reports inline. No create/clone flow displays a literal `ouro hatch`/`ouro clone` command to the operator. Preserve the existing security property: credentials reach the runtime via argv built natively, never through agent context.

**User stories:**
- _As a operator cloning an agent from the native UI, I want to fill a small native form and see progress/result inline, never a raw shell command or a CLI conversation pane, so that the app feels like one coherent product rather than a launcher that shells out to `ouro`._
    - [ ] No create/clone flow displays a literal `ouro hatch` or `ouro clone` command string to the operator
    - [ ] Clone collects remote + optional name in a native form and reports success/failure inline without opening a terminal the user must talk to
    - [ ] The existing security property holds: credentials still reach the runtime via natively-built argv, never through agent context

## [U36] Make the empty-state 'Installed agents' card honest: real affordances or one purposeful CTA, not a dead look-alike of the sidebar
**#30** · `removes-friction` · effort `S` · surface: First-run & empty state · operator

**Problem:** When agents are installed, AgentHomeEmptyState renders an 'Installed agents' card whose rows (status dot + name + 'boss' capsule) are bare HStacks with no Button, onTapGesture, help, or accessibility label — purely decorative — while one column left the sidebar's SidebarAgentRow wraps the SAME visual vocabulary in a real Button that selects the agent. So the empty state shows a less-capable read-only copy of an interactive list, re-listing names the sidebar already carries (adding zero new information), training the operator that clicking things sometimes does nothing. The non-ready rows compound it: each colors its dot green/orange, collapsing three distinct failure states (disabled, missingConfig, invalidConfig) into one wordless orange dot with no label, tooltip, or action — an alarm the operator can't read or resolve, even though the per-status repair copy already exists (agent.detail) and the product is legible about this everywhere else.

**Fix:** Either make the card rows real affordances (tap → model.selectAgent, matching the sidebar, keyboard-reachable, with a help/hover cue) so the empty state is an honest launchpad, OR drop the card since the sidebar is already the single source of truth; if kept, it should earn its place with a CTA the sidebar can't carry (e.g. 'pick one as your boss') rather than re-listing names. For any non-ready row, surface the existing per-status reason (disabled / agent.json missing / invalid config) as label or tooltip and offer a direct action to resolve it (at minimum a .help() with agent.detail), so an intentionally-disabled agent doesn't read as an unexplained error.

**User stories:**
- _As a operator opening Workbench with one or more agents already installed, I want the agents shown in the empty-state card to behave like the sidebar — clickable to inspect/select — and any non-green one to tell me in plain words why and how to fix it, so that I'm not staring at a list that looks tappable but is inert or an orange dot I can't read, and I can act on an agent right from the home screen._
    - [ ] Clicking a row in the empty-state card selects that agent and shows its detail view (same outcome as the matching sidebar row), OR the card is removed and the sidebar remains the single source of truth; if retained, every row is keyboard-reachable with a hover/help affordance
    - [ ] A non-ready row shows a human-readable reason (disabled / agent.json missing / invalid config) as label or tooltip and offers a direct action to resolve it; an intentionally disabled agent does not read as an unexplained error/alarm
    - [ ] There is no read-only list in the empty state that visually mimics the interactive sidebar list without acting like it

---

## Review + live-hunt follow-ups (U37–U42)

Lower-priority items surfaced by the independent cold-review of U7/U8/U9 and by live driving of the running app (things the static audit couldn't see). Sequenced, not dropped.

## [U37] Command palette: kill the duplicate, group the flat list, fix the naming drift
`removes-friction` · `S` · surface: Command palette (⌘K) · operator
**Problem (live-hunt finds):** (a) "Select Agent: slugger" appears TWICE (byte-identical), and there is no "Select Agent: ouroboros" — a real duplicate-entry bug. (b) The palette is one ungrouped ~34-item flat list (scrolls far past the window) — hard to scan. (c) It still offers "Set Up Workbench" ("conversational setup and recent-session import") while the rest of the app now says "Set up a boss" — pre-subtraction naming drift.
**Fix:** de-dupe the Select-Agent rows (one per non-boss installed agent; none for the current boss); group commands into labelled sections (Session / Boss / Workspace / Agents / Diagnostics / App); rename/retire "Set Up Workbench" to match the opt-in-boss framing.
**User story:** _As an operator hitting ⌘K, I want a de-duplicated, sectioned palette whose names match the rest of the app, so that I can find a command fast and never see the same agent listed twice._

## [U38] Recovery trust-fix gate keys off typed blocker, not planner prose (U7-1)
`fixes-broken` · `S` · surface: Restart/reboot recovery · operator
**Problem:** `recoveryTrustFixAvailable` gates the inline "Trust & resume" fix on `recoveryPlan.reason == "entry is not trusted"` — an exact string match. If that planner prose is ever edited, the inline fix silently vanishes and every untrusted session falls back to history-discarding "Start fresh," with no test catching it.
**Fix:** key the gate off a typed blocker/enum on the recovery plan, not a prose match; add a test.

## [U39] RecoveryDrill count diverges from RecoveryDigest (U8-3)
`removes-friction` · `S` · surface: Recovery drill (Advanced) · operator
**Problem:** `RecoveryDrill` computes its own `actionableCount` excluding `.reattach`, diverging from the single `RecoveryDigest` every other surface now uses — another operator-visible recovery count that can disagree.
**Fix:** route the drill's count through `RecoveryDigest`.

## [U40] Post-launch lastSummary leaks technical plan strings (flag c)
`removes-friction` · `S` · surface: Session status / boss prompt · operator+boss
**Problem:** `markStarted` sets `lastSummary = TerminalCommandPlan.reason` ("respawn X from persisted workbench context", "prepare X command for manual review") — mildly-technical jargon that lands in operator-visible status and the boss prompt; outside U8c's RecoveryAction scope, so legitimately deferred from that unit.
**Fix:** give `TerminalCommandPlan` an operator sentence so the post-launch status reads plainly.

## [U41] Readiness actuators rewrite session status as a side-effect (U9-minor)
`removes-friction` · `S` · surface: TTFA popover · operator
**Problem:** the U9 trust/resume actuators set `entry.lastSummary` ("X trust set to trusted") as a side-effect of a settings toggle; that field is operator-visible and feeds the boss prompt, so tapping "Trust" in the readiness popover oddly rewrites a session's status line.
**Fix:** don't repurpose `lastSummary` for a settings-toggle confirmation.

## [U42] Boss-watch wakes on lossless reconnects (review residue)
`removes-friction` · `S` · surface: Boss watch · boss+both
**Problem:** `bossWatchTick`'s `hasActionableState` gates on raw `summary.needsRecovery.isEmpty`, which counts `.reattach` survivors as actionable — can wake the boss for a pure-reconnect workspace where nothing needs action.
**Fix:** gate on `RecoveryDigest.actionableCount` (needs-action only), consistent with the other surfaces.
