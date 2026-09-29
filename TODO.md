# TODO

Hybrid tracker:
- **TODO.md** — thin index: task ID, status, GitHub issue link
- **GitHub Issues** — acceptance criteria, design, discussion

See AGENTS.md for the full workflow.

| ID | Task | Status | Issue |
| --- | --- | --- | --- |
| 1 | Ignore SIGPIPE and finish socket writes so one client disconnect cannot kill the helper | complete | — |
| 2 | Drop a dead helper socket in the MCP client and retry that call once | complete | — |
| 3 | Exit 0 when Reminders access is denied or another helper is already listening, so launchd does not restart the job | complete | — |
| 4 | Reject socket paths that do not fit in sun_path, and pass bind/connect a length that stays inside sockaddr_un | complete | — |
| 5 | Install apple-bridge-helper and apple-bridge-mcp to ~/.local/bin | complete | — |
| 6 | Add reminders_read, reminders_create, reminders_update, and reminders_delete | complete | — |
| 7 | Add NSCalendarsFullAccessUsageDescription to Info.plist | pending | #1 |
| 8 | Remove or refactor dead code in RemindersRules.swift:459 | pending | #2 |
| 9 | Clarify MCPError reconnectable timeout distinction | pending | #3 |
