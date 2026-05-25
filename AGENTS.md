# Ouro Workbench Agent Instructions

## Product Truth

Ouro Workbench is a native macOS terminal-agent workbench. Arbitrary terminal/TUI
agents are first-class citizens. Claude Code, GitHub Copilot CLI, and OpenAI
Codex are important detected CLI identities, not separate fixed app modes.

Ouro agents do not replace terminal agents. An Ouro agent can be selected as the
workspace boss: the observer/coordinator/control layer that answers "what is
going on?", "is anything waiting on me?", and "keep things moving."

## P0 Requirements

- Native macOS app first. Do not build a web-first client.
- A selected boss Ouro agent can inspect and control the workspace.
- Terminal/TUI agents have persistent identity, output history, attention state,
  and resume metadata.
- Computer restart recovery is P0. Processes cannot survive reboot, but
  sessions must restore: history, status, panes, and safe auto-resume where the
  underlying CLI supports it.
- Claude Code, GitHub Copilot CLI, and OpenAI Codex must have explicit resume
  strategies before they are treated as complete detected terminal identities.

## Autonomy

TTFA applies. Prefer reversible, auditable action over permission-seeking.

Use fresh sub-agent review gates for unbiased validation. Human escalation is
reserved for genuinely uncovered human-only issues: credentials/private account
actions, irreversible destructive operations, or product ambiguity not covered
by the standing directives.

## Safety

This product is high-trust local software. Preserve auditability and recovery
truth. Do not silently claim a process survived a reboot; classify it as
resumed, respawned, or needing manual recovery.
