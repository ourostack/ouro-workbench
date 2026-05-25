# Restart Recovery

Restart persistence is a P0 requirement.

## App Quit And Force-Quit

Workbench treats app quit, force-quit, reinstall, and relaunch as detach/attach
events. Starting a terminal tab launches the actual command inside a stable
system `screen` session named from the Workbench terminal id. The native app
owns only the visible client. If the app disappears, the `screen` session and
the child shell/TUI keep running. Reopening Workbench attaches to the same
session instead of rerunning the command. Installed app bundles use the bundled
`Contents/MacOS/Tools/screen` executable for this layer.

Manual `Stop` is the destructive action. It sends `screen -S <session> -X quit`
for that terminal and then records the run as exited, so Workbench does not
schedule recovery for a session the operator intentionally ended.

The `screen` command escape is moved away from Ctrl-A so readline, shells, and
terminal agents keep normal keyboard behavior. Workbench also forces
`TERM=xterm-256color` for launched terminals, which keeps commands such as
`clear` using terminal capabilities the embedded terminal can render.

## Computer Restart

macOS processes and PTYs do not survive an actual computer restart. After a
power cycle or OS reboot, Workbench restores the workbench state and starts the
best available recovery action:

- restore workspace state
- restore group and selected terminal state
- restore terminal-agent identity
- restore transcript/output history
- restore panes and attention state
- resume safely where supported
- report what could not be resumed

When Claude Code, Codex, or another CLI exposes native session metadata,
Workbench uses that resume command. Otherwise trusted custom terminals respawn
from their saved command and transcript context, and anything unsafe or
ambiguous is reported for manual/boss review.

The app records terminal output to per-run transcript files under Application
Support. Inactive sessions show the latest transcript tail in the detail pane,
and boss check-in prompts include transcript paths so durable output remains
discoverable after restart.

## Detected Agent Terminals

Workbench detects known agent terminals from the actual command, including
direct commands such as `claude --dangerously-skip-permissions` and legacy
shell/env wrappers such as `/bin/zsh -lc "env claude ..."`. Detection is used
for labels, executable health, recovery planning, and boss context.

### Claude Code

Use native resume when a Claude session id is known. The initial command
template is:

```text
claude --resume {{sessionId}}
```

If no session id is available, continue the most recent Claude Code session in
the same working directory with:

```text
claude --continue
```

### GitHub Copilot CLI

Launch through the GitHub CLI bridge:

```text
gh copilot
```

Trusted Workbench tabs pass Copilot's full-autonomy flag through the `gh`
argument boundary:

```text
gh copilot -- --yolo
```

Native resume needs verification. Until then, persist transcript and checkpoint
state, then respawn with a recovery prompt.

### OpenAI Codex

Use native resume when a Codex session id is known. The initial command template
is:

```text
codex resume {{sessionId}}
```

If no session id is available, resume the most recent Codex session with:

```text
codex resume --last
```

## Trust

Trusted entries may auto-resume or respawn according to policy. Untrusted
entries never auto-resume, even if they were running before restart.

## Recovery Drill

The native app exposes a dry-run `Recovery Drill`. It runs the same startup
reconciliation and recovery planner against an in-memory copy of the current
workspace state, then reports each session's pre-restart status, simulated
post-restart status, planned recovery action, and reason. The drill never
mutates persisted workspace state and does not start or stop processes.

The selected boss agent can run the same dry run through the
`workbench_recovery_drill` MCP tool.
