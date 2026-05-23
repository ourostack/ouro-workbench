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

## Named Agent Lanes

### Claude Code

Use native resume when a Claude session id is known. The initial command
template is:

```text
claude --resume {{sessionId}}
```

If no session id is available, reopen with checkpoint context and mark the lane
as manual-action-needed until the resume strategy is verified.

### GitHub Copilot CLI

Native resume needs verification. Until then, persist transcript and checkpoint
state, then respawn with a recovery prompt.

### OpenAI Codex

Use native resume when a Codex session id is known. The initial command template
is:

```text
codex resume {{sessionId}}
```

If no session id is available, reopen with checkpoint context and mark the lane
as manual-action-needed until the resume strategy is verified.

## Trust

Trusted entries may auto-resume or respawn according to policy. Untrusted
entries never auto-resume, even if they were running before restart.
