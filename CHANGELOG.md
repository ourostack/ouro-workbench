# Changelog

## 0.1.0 - Unsigned Preview

- Native macOS Workbench for Claude Code, OpenAI Codex, GitHub Copilot CLI, local shells, and arbitrary terminal/TUI agents.
- Cmux-style groups with multiple terminal tabs per group.
- Persistent terminal backing through bundled `screen` for app quit and force-quit recovery.
- Startup recovery planner for native resume, checkpoint respawn, and manual-action classification after computer restart.
- Selectable Ouro boss agent with Boss Line, Boss Watch, focused Ask Boss, and TTFA readiness.
- Packaged Workbench MCP server for status, transcript tail/search, recovery drill, and queued trusted actions.
- Versioned unsigned app artifact zip and manifest with SHA-256 verification.
- Protected CI gates for Swift tests, native scenario verification, bundle verification, artifact verification, and install rollback smoke.
