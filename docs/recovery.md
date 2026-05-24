# Restart Recovery

Restart persistence is a P0 requirement.

## Technical Truth

macOS processes and PTYs do not survive reboot. The product requirement is not
literal process immortality. It is seamless restoration:

- restore workspace state
- restore terminal-agent identity
- restore transcript/output history
- restore panes and attention state
- resume safely where supported
- report what could not be resumed

The app records terminal output to per-run transcript files under Application
Support. Inactive sessions show the latest transcript tail in the detail pane,
and boss check-in prompts include transcript paths so durable output remains
discoverable after restart.

## Named Agent Lanes

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
