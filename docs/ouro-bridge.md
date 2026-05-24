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
- `workbench_request_action`: queue `launch`, `recover`, `terminate`, or
  `sendInput` for the native app to apply.

The native app drains queued action requests from Application Support and applies
them through the same trust-gated action path used by boss check-ins. Untrusted
entries are denied before action execution.

Applied boss and external Workbench actions are written to the persisted
workspace action log with source, action, target, result, success state, and
timestamp. The boss dashboard shows the recent log so control remains auditable
after the transient check-in output scrolls away.

Workbench status prompts include executable health for each configured session:
`available`, `missing`, or `notExecutable`, plus the resolved path when present.

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
