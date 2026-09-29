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
| 7 | Add NSCalendarsFullAccessUsageDescription to Info.plist | complete | #1 (closed — key present since `8891028`) |
| 8 | Remove or refactor dead code in RemindersRules.swift:459 | pending | #2 |
| 9 | Clarify MCPError reconnectable timeout distinction | pending | #3 |
| 10 | `EventRecord.id` uses unstable `eventIdentifier`; use `calendarItemIdentifier` | pending | #5 |
| 11 | Give `events_read` a real date window and report it in the result | pending | #6 |
| 12 | Port the self-explaining read contract (`filters`/`note`, `events_upcoming`, `serverInstructions`) | pending | #7 |
| 13 | Decide recurrence, all-day `end`, and `notes` volume | pending | #8 |
| 14 | Test the calendar read path (none today) | pending | #9 |
| 15 | Sync docs with what actually shipped; rename LaunchAgent to `org.dempsay` | pending | #10 |

Calendar read shipped in `b134484` as a sizing prototype. Row 10 gates any
event write command; rows 11–12 gate calling it from a weak model.
