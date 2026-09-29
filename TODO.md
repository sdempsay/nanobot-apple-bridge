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
| 13 | Decide recurrence, all-day `end`, and `notes` volume | recurrence and all-day `end` settled; `notes` volume still open | #8 (recurrence narrowed by #11) |
| 14 | Test the calendar read path (none today) | partial | #9 (34 rules tests; EventKit paths still bare) |
| 15 | Sync docs with what actually shipped; rename LaunchAgent to `org.dempsay` | complete | #10 (`2cbabd1`) |
| 16 | Add `events_create`/`update`/`delete`, refusing recurring events | complete | #11 (`2cbabd1`) |

Calendar read shipped in `b134484` as a sizing prototype; rows 10–12 finished it
in `6b2426c`, merged as #12 / `7a8d065`. Rows 15 and 16 are the write surface
and the naming sweep, merged as #13 / `b146df6`. 66 tests, up from 52.

**Recurrence decision, settled (row 13 / #8, narrowed by #11):** reads report
occurrences, as the prototype already did. Writes are out of scope for recurring
events entirely — refuse rather than guess between series and single-occurrence
semantics. Shipped helper-side in `2cbabd1`, and it covers an event that is one
occurrence of a series too, not just the master: `.thisEvent` on a master
silently diverges from Calendar.app and the user cannot see the difference.

**All-day `end` resolved by observation, not by decision.** The writer sets an
exclusive next-midnight; EventKit stores `23:59` on the same day, and events
sourced from iCloud read back the same way, so create and read agree. Checked
against a self-created event and two real all-day events. The writer is left
alone deliberately — "correcting" it to match EventKit's documented convention
is what would have broken the round trip.

**`notes` volume is the one part of row 13 still genuinely undecided** — whether
`EventRecord.notes` should be truncated, and at what length. Nothing ships
truncating today.

**Row 14 remains the real gap.** The 34 event tests are all pure protocol logic;
`makeEventRecord`'s field mapping and the `Work` / `Work Calendar` name
ambiguity still have no coverage, because they need EventKit.
