# Ouro Bridge

Ouro Workbench uses two existing Ouro surfaces before inventing new daemon APIs.

## Read Plane

Ouro Mailbox is the fast status surface. The daemon exposes a read-only local
HTTP server at `http://127.0.0.1:6876`.

Workbench reads:

- `/api/machine`
- `/api/agents/<agent>`
- `/api/agents/<agent>/needs-me`
- `/api/agents/<agent>/coding`
- `/api/agents/<agent>/sessions`
- `/api/agents/<agent>/attention`
- `/api/events`

Mailbox stays read-only. It answers what is happening without becoming the
control authority.

## Boss Plane

The selected Ouro boss agent is reached through MCP stdio:

```bash
ouro mcp-serve --agent slugger
```

Workbench should use boss-agent turns for natural-language check-ins:

- what is currently going on
- is anything waiting on the human
- what terminal agents are active
- what blockers exist
- what next actions can safely move work forward

The native `Boss Line` is the human-facing version of this same plane. It sends
the selected boss a Workbench-grounded prompt through `ouro mcp-serve --agent
<boss>`, then applies any fenced `ouro-workbench-actions` through the native
trust-gated action path. The built-in quick asks intentionally cover the common
operating loop: status, waiting-on-human, keep moving, and respond on the
human's behalf when the answer is routine.

Session-level `Ask Boss` buttons use the same route but focus the prompt on a
single process id so the boss can inspect or act on the terminal the human is
currently looking at.

## Control Plane

Initial control requests should route through the boss agent instead of silently
bypassing it. That lets the selected boss use existing Ouro tools and preserve
the authority model.

Direct Workbench control is still necessary for local terminal panes it owns:

- launch trusted configured sessions
- persist transcript and run metadata
- send input through a retained session controller
- terminate sessions
- classify restart recovery as resumed, respawned, or manual

## Workbench MCP Server

The packaged app includes a companion MCP server:

```bash
"/Users/arimendelow/Applications/Ouro Workbench.app/Contents/MacOS/OuroWorkbenchMCP"
```

This gives an Ouro agent a direct Workbench-facing tool surface:

- `workbench_status`: summarize persisted Workbench state, processes, recovery
  plans, and transcript paths.
- `workbench_transcript_tail`: read a bounded tail from the latest transcript
  for a process entry. The server clamps transcript reads to 64 KB.
- `workbench_search_transcripts`: search saved transcript text across process
  runs. The server clamps returned matches to 200 lines and clips pathological
  no-newline result snippets to keep tool output readable.
- `workbench_recovery_drill`: dry-run restart recovery planning for current
  Workbench sessions without mutating state.
- `workbench_request_action`: queue `launch`, `recover`, `terminate`, or
  `sendInput` for the native app to apply.

The native app drains queued action requests from Application Support and applies
them through the same trust-gated action path used by boss check-ins. Untrusted
entries are denied before action execution.

Malformed or partially written queued action files are moved into a rejected
queue folder so one bad request cannot block later valid boss/Ouro actions.

Applied boss and external Workbench actions are written to the persisted
workspace action log with source, action, target, result, success state, and
timestamp. The boss dashboard shows the recent log so control remains auditable
after the transient check-in output scrolls away.

Workbench status prompts include executable health for each configured session:
`available`, `missing`, or `notExecutable`, plus the resolved path when present.
They also include persisted Boss Watch state so the selected boss can tell
whether background observation is enabled or paused.

Status prompts include the Workbench organization map: all groups, the selected
group, active terminal tab names per group, and each process's group plus
detected CLI identity. This is how an Ouro boss can answer "what is going on in
the harness group?" without treating every terminal on the machine as a flat
bag of processes.

The native boss dashboard has a `Workbench MCP` row that registers or updates an
`ouro_workbench` entry in `~/AgentBundles/<boss>.ouro/agent.json`. The entry
points at the packaged `OuroWorkbenchMCP` executable and uses no arguments:

```json
{
  "mcpServers": {
    "ouro_workbench": {
      "command": "/Users/arimendelow/Applications/Ouro Workbench.app/Contents/MacOS/OuroWorkbenchMCP",
      "args": []
    }
  }
}
```

Once registered, the selected boss agent can discover the workbench tools from
its normal Ouro MCP/tool surface.

## TTFA Readiness

`TTFA` in the native header is not decorative. It summarizes whether the selected
boss can be trusted to run the Workbench with minimal babysitting:

- boss agent name is valid
- Workbench MCP is registered for that boss
- detected Claude Code, GitHub Copilot CLI, and OpenAI Codex terminals are
  trusted when boss control is expected
- detected agent terminals have automatic restart strategies enabled when they
  should recover without human help
- detected agent executables are available on PATH
- no session currently requires manual recovery
- Boss Watch and Open at Login are enabled or called out as watch points

The readiness popover can apply obvious local fixes, including Workbench MCP
registration, Boss Watch startup, Open at Login registration, and a fresh boss
ask.
