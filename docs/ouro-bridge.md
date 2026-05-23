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

Future daemon APIs can promote these actions into first-class Workbench tools
after the native app proves the product shape.
