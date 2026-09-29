# PRD updates

Learned while fixing the milestone-1 socket failure paths (2026-09-28).

## Helper lifetime

- A peer disconnect is not a process failure. The helper ignores `SIGPIPE`, sets `SO_NOSIGPIPE` on accepted sockets, and closes only that connection.
- Exit 0 when Reminders access is denied, when another helper is already listening, or when the socket path does not fit in `sun_path`. The LaunchAgent restarts the job on every other exit.
- `bind` returning `EADDRINUSE` is the already-listening case and exits 0.

## Socket address

- Both sides build the Unix address through one helper. A path that does not leave room for a trailing NUL in `sun_path` (104 bytes on Darwin) is rejected before `bind` or `connect`. The length passed to the kernel is never larger than `sockaddr_un`.

## Install location

- The helper and the MCP executable are installed to `~/.local/bin`. The LaunchAgent `Program` is the absolute path of `apple-bridge-helper` there.
- The socket and the helper log stay in `~/Library/Application Support/apple-bridge/`.

## MCP client

- After the helper restarts, the next call closes the dead socket, connects again, and retries that call once.
- Socket reads and writes time out so a helper that accepts and never answers cannot stall the stdio loop.
- The retry resends the request. That is safe for `lists` and `reminders_read`. Create, update, and delete are not retried.

## Reminder commands (2026-09-29)

- Wire commands are `lists`, `reminders`, `create`, `update`, and `delete`. The MCP tools are `lists`, `reminders_read`, `reminders_create`, `reminders_update`, and `reminders_delete`. `lists` stays a plain array of `{id, name, isDefault}` and is not renamed.
- A list argument may be a calendarIdentifier or a title. An identifier wins. A title is used only when one visible list has that name. "Recently Deleted" is excluded from that resolution. Omitting the list uses `defaultCalendarForNewReminders()`.
- Read returns `{reminders, matched, truncated}`. The default page is 50 and the maximum is 100. Open reminders come back soonest due first, undated last. A date due value is all-day in the helper's local zone; a zoned datetime is converted into that zone. `flagged: true` filters to flagged reminders, which EventKit cannot report, so the page is empty. `flagged: false` does not filter.
- Create and update reject any attempt to change the flag (`The flag is not available through EventKit.`). Creating with `flagged: false` or omitting it is a no-op. Records always report `flagged: false`.
- Public reminder keys are snake_case: `list_id`, `all_day`, `completion_time`. Omitted optional fields are absent rather than null.
- Recurrence, alarms, tags, URLs, locations, subtasks, and the flag are not implemented.
