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
| 10 | `EventRecord.id` uses unstable `eventIdentifier`; use `calendarItemIdentifier` | complete | #5 (`6b2426c`) |
| 11 | Give `events_read` a real date window and report it in the result | complete | #6 (`6b2426c`) |
| 12 | Port the self-explaining read contract (`filters`/`note`, `events_upcoming`, `serverInstructions`) | complete | #7 (`6b2426c`) |
| 13 | Decide recurrence, all-day `end`, and `notes` volume | mostly decided; #8 stays open for the read-side record | #8 (recurrence narrowed by #11) |
| 14 | Test the calendar read path (none today) | partial | #9 (34 rules tests; EventKit paths still bare) |
| 15 | Sync docs with what actually shipped; rename LaunchAgent to `org.dempsay` | done | #10 |
| 16 | Add `events_create`/`update`/`delete`, refusing recurring events | done | #11 |

Calendar read shipped in `b134484` as a sizing prototype; rows 10–12 finished it
in `6b2426c`, merged as #12 / `7a8d065`. 52 tests. Row 16 is the write surface,
unblocked now that row 10 has landed. Row 15 is next: the Calendar usage string
now claims "reads and writes" while only reading ships, and the LaunchAgent
still says `com.org.dempsay` where the house rule is `org.dempsay`.

**Recurrence decision, partial (row 13 / #8):** reads report occurrences, as the
prototype already did. Writes are out of scope for recurring events entirely —
refuse rather than guess between series and single-occurrence semantics. That
demotes recurrence from a write blocker to read-side documentation, and leaves
all-day `end` and `notes` volume still open in #8.
