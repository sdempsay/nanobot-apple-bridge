# PRD — apple-bridge

Design and decisions. This is the contract: what the system is, why it is shaped
this way, and the decisions that are pinned. `README.md` is the story;
`AGENTS.md` is the operational layer agents must follow; `ACTIONS.md` is the
dated work log.

## Why this exists

Agents on macOS that need Apple Reminders/Calendar data today have three bad options:

- **AppleScript** — the only "official" door for decades, and it's fragile: no real
  timeouts (a hung app cascades into every subsequent script), synchronous Apple
  Events that queue behind the GUI thread, cryptic or silent errors, apps that must
  be launched first. Fine for one-offs, not infrastructure.
- **Direct SQLite** — the Reminders store is a local SQLite replica
  (`~/Library/Group Containers/group.com.apple.reminders/Container_v1/Stores/`), but
  it's TCC-gated (Full Disk Access), and writing directly risks desyncing CloudKit.
  The file is *not* "in iCloud" — CloudKit record sync keeps replicas in sync.
- **JXA bridge** (`ObjC.import("EventKit")` via osascript) — what mac-reminders uses
  today. Right layer (EventKit), flimsy vehicle: TCC grants attach to whatever
  launched osascript, and the ObjC bridge is finicky.

The actual stack is:

```
your code → EventKit → remindd → SQLite (local) ↔ CloudKit ↔ iCloud
```

EventKit is the sanctioned API layer. apple-bridge puts a small signed binary on
that layer and gives everything else a clean way to talk to it.

## Architecture

Privilege separation, the macOS-native pattern (same idea as XPC, pragmatic version):

```
agent (MCP client)
   │  stdio, MCP protocol
   ▼
apple-bridge-mcp        ← thin Swift stdio MCP service (fast-moving, ad-hoc signed)
   │  Unix domain socket, newline-delimited JSON
   ▼
apple-bridge-helper     ← signed Swift per-user LaunchAgent (stable, privileged)
   │  EventKit
   ▼
remindd → SQLite ↔ CloudKit ↔ iCloud
```

### Signed Swift helper (the privileged piece)

- Links EventKit — and it is the *only* target that does (see package layout
  under the MCP section). Embeds an Info.plist (`-sectcreate __TEXT __info_plist`)
  containing both usage strings from day one
  (`NSRemindersFullAccessUsageDescription` and
  `NSCalendarsFullAccessUsageDescription` — adding the calendar key now is
  harmless and avoids a second signing surprise later) **plus a stable
  `CFBundleIdentifier` and display name**. The usage string supplies the prompt
  text, but the bundle ID is what makes the TCC client a stable identifier:
  without it, the grant is often tied to the absolute path, so moving the binary
  from a `swift build` directory to the LaunchAgent path looks like a new app and
  the prompt comes back.
- Calls `requestFullAccessToReminders()`. (Linking the current SDK makes the
  older `requestAccess(to:)` path fail without a prompt.)
- Signed with a stable identity (Developer ID, or a stable self-signed identity for
  local-only use). Ad-hoc signing pins the TCC grant to the cdhash, so every rebuild
  re-prompts; a stable identity is what lets the grant survive rebuilds.
  Notarization matters only if another Mac will run the binary.
- **Signing alone does not make the permission prompt name the helper.** macOS
  attributes EventKit privacy prompts to the *responsible process*. A helper the
  MCP server starts with a normal spawn is still blamed on the GUI app that owns
  the session (Terminal, Cursor, etc.) — and if that host has no Reminders usage
  string, the prompt never appears and access is denied. That's the same failure
  mode the JXA bridge already has. Two ways to break the chain:
  1. **launchd starts the helper** — a launchd-started process is responsible for
     itself. This is the primary design (see Lifecycle).
  2. The parent spawns it with `responsibility_spawnattrs_setdisclaim` — private
     SPI. Fine as a documented dev fallback, but no milestone may depend on it;
     the LaunchAgent path is the one with a public mechanism.
- Exposes a narrow, stable command set over the socket:
  `lists`, `reminders`, `create`, `update`, `delete` (+ calendar equivalents later).
  Narrow is a security requirement, not minimalism: same-user access is the *whole*
  boundary, so any local process can drive whatever the helper exposes once it's
  approved.
- Lists are addressed by EventKit's `calendarIdentifier` on the wire; title is a
  convenience lookup only. Title addressing fails when two lists share a name
  (iCloud and On My Mac both ship a "Reminders" list). This is baked into the
  shared wire types, so it's pinned here before any code exists.
- Bonus unlock: as a long-lived process with a warm `EKEventStore`, it can subscribe
  to `EKEventStoreChangedNotification`. Note the notification is coarse — it means
  "something changed," and the helper must refetch — and it only exists while the
  process stays up and runs a run loop. Another reason the LaunchAgent is the real
  design and a per-call Swift process is not.

### Thin stdio MCP service (the fast-moving piece)

- A second executable target in the same Swift package, speaking MCP stdio
  (line-delimited JSON-RPC) directly — no SDK, for the reason recorded in
  AGENTS.md under "Environment blocker". Package layout:
  `Sources/AppleBridgeProtocol` (shared wire types as `Codable`s, plus the pure
  logic worth testing without EventKit: the single `sockaddr_un` builder so a long
  home directory cannot truncate the path, `writeAll`, `readFrame`, the Reminders
  rules, and `Deadline`), `Sources/apple-bridge-helper` (the only target that links
  EventKit), `Sources/apple-bridge-mcp`. Keeping EventKit out of the MCP target
  matters: linking it wouldn't raise a prompt by itself, but it puts the privacy
  API in the binary that's supposed to stay clear of TCC.
- Needs no TCC grant and no stable signature — it never touches EventKit, only
  the socket — so it can be rebuilt and iterated freely. Only the stable helper
  carries the signing discipline. Note "no stable signature" ≠ "unsigned": Apple
  Silicon refuses to execute a fully unsigned binary, so this target is ad-hoc
  signed on every build (fine — nothing in TCC attaches to it), while the helper
  must never be (ad-hoc pins the grant to the cdhash; rebuild = re-prompt).
- Relationship to mac-reminders: none in code. mac-reminders (Python + JXA) stays
  untouched as the reference implementation until apple-bridge reaches parity, then
  is superseded.

### Socket

- Unix domain socket at `~/Library/Application Support/apple-bridge/helper.sock`.
  Directory mode 0700 is necessary but not sufficient: the socket file itself gets
  mode 0600. Same-user UID is the trust boundary.
- Not TCP: no port squatting, no firewall prompts, no network exposure.
- Framing: newline-delimited JSON, e.g.
  `{"command":"create","listId":"<calendarIdentifier>","title":"..."}` →
  one JSON response line. (`listId` is the EventKit `calendarIdentifier` — see
  the helper section for why lists are never addressed by title on the wire.)
- **Single-instance rule:** two clients that fail to connect must not race to
  start two helpers. The LaunchAgent is the only thing that starts it; the dev
  fallback (disclaimed spawn) serializes bind with a lock.

### Lifecycle

- **A per-user LaunchAgent is the primary design**, running in the graphical
  session (`LimitLoadToSessionType = Aqua`) so the TCC prompt can actually
  present. A system daemon has no UI session to show the dialog, and in some
  launchd contexts `requestFullAccessToReminders()` waits forever instead of
  returning denied.
- **The helper binary must be the LaunchAgent's own program.** launchd makes the
  process it starts responsible for itself, and that process is then responsible
  for any child *it* starts — so a wrapper script or a `swift run` parent puts
  the TCC blame back on the wrapper. The plist's `Program` points directly at a
  stable installed path, `~/.local/bin/apple-bridge-helper`. `install.sh` writes
  that path with `$HOME` already expanded, because launchd does not expand `~`.
  `apple-bridge-mcp` is installed beside it. The socket and log stay under
  `~/Library/Application Support/apple-bridge/`.
- On startup the helper unlinks a stale `helper.sock` before binding; otherwise a
  `KeepAlive` plist crash-loops on the leftover socket.
- On-demand spawn from the MCP layer is the dev fallback only, via
  `responsibility_spawnattrs_setdisclaim` (private SPI — no milestone depends on
  it). Otherwise the grant attributes to whatever host launched the MCP server.

## Scope

- **In:** Reminders — lists, CRUD, recurrence, alarms. Then Calendar via the same
  `EKEventStore`. Calendar is a **second TCC grant**, not a freebie:
  `NSCalendarsFullAccessUsageDescription` + `requestFullAccessToEvents()`, and a
  second switch in Privacy & Security. One binary can carry both usage strings; it
  cannot carry both approvals.
- **Out (explicit non-goals):**
  - Mail and Notes — Apple ships no public API for them; AppleScript-or-nothing.
  - **Sections and reliable section membership** — not exposed in EventKit. Getting
    them requires private ReminderKit or direct SQLite, both of which we reject.
    Stated here so the "no direct SQLite" rule doesn't get relitigated later.

## Alternatives considered

- **Single all-Swift binary (MCP server calls EventKit itself, no socket):**
  rejected. An MCP binary spawned by the agent host is blamed on that host for TCC
  unless the spawn is disclaimed — and we don't control how MCP hosts spawn
  servers, so we can't force the disclaim. We'd also lose the warm store and change
  notifications. Note the MCP layer is still Swift — the split is what makes that
  viable, since only the helper needs a stable signature.
- **Per-call Swift CLI (no long-lived process):** rejected as the primary shape —
  kills `EKEventStoreChangedNotification` (needs a persistent process with a run
  loop) and still needs a disclaimed spawn for correct TCC attribution. May survive
  as a dev/debug mode.
- **Status quo JXA bridge:** works, but permission attribution is flaky and
  debugging the ObjC bridge burns time. Capability is identical — this is a
  reliability/polish migration, not a feature unlock.
- **AppleScript / direct SQLite:** see "Why this exists".

## Decisions (pinned)

### Helper lifetime

- A peer disconnect is not a process failure. The helper ignores `SIGPIPE`, sets `SO_NOSIGPIPE` on accepted sockets, and closes only that connection.
- Exit 0 when Reminders access is denied, when another helper is already listening, or when the socket path does not fit in `sun_path`. The LaunchAgent restarts the job on every other exit.
- `bind` returning `EADDRINUSE` is the already-listening case and exits 0.

### Socket address

- Both sides build the Unix address through one helper. A path that does not leave room for a trailing NUL in `sun_path` (104 bytes on Darwin) is rejected before `bind` or `connect`. The length passed to the kernel is never larger than `sockaddr_un`.

### Install location

- The helper and the MCP executable are installed to `~/.local/bin`. The LaunchAgent `Program` is the absolute path of `apple-bridge-helper` there.
- The socket and the helper log stay in `~/Library/Application Support/apple-bridge/`.

### MCP client

- After the helper restarts, the next call closes the dead socket, connects again, and retries that call once.
- Socket reads and writes time out so a helper that accepts and never answers cannot stall the stdio loop. The response read is bounded by a per-request `Deadline` (30s in the client, above the helper's 25s so the helper's hop-named error reaches the agent first), shared by the retry so two attempts cannot stack.
- The retry resends the request. That is safe for `lists` and `reminders_read`. Create, update, and delete are not retried. A timeout is not reconnectable: silence does not prove the connection died, and the request may already have been applied.

### Reminder commands

- Wire commands are `lists`, `reminders`, `create`, `update`, and `delete`. The MCP tools are `lists`, `reminders_all`, `reminders_read`, `reminders_create`, `reminders_update`, and `reminders_delete`. `lists` stays a plain array of `{id, name, isDefault}` and is not renamed.
- `reminders_all` takes no arguments and maps to `reminders` with `list: "all"`, `status: "any"`, `limit: 100`. `"all"` is reserved: it reads every visible list and is refused for create and update, which need exactly one target list. A list literally named "all" stays reachable by its calendarIdentifier.
- A blank optional string (`""` or spaces) is treated as omitted for `list`, `status`, `search`, `due_after`, `due_before`, `priority`, and `due`. It is not omitted for `notes` on update, where an empty string clears the note, nor for `title`, which must still be rejected.
- A list argument may be a calendarIdentifier or a title. An identifier wins. A title is used only when one visible list has that name. "Recently Deleted" is excluded from that resolution. Omitting the list uses `defaultCalendarForNewReminders()`.
  - A helper that returns `{reminders, matched, truncated}` plus `{scope, filters, note}`.
  - A page default of 50, max 100. Open reminders soonest due first, undated last. A bare date due value is all-day in the helper's local zone; a zoned datetime is converted into it. `flagged: true` filters to flagged reminders, which EventKit cannot report, so the page is empty. `flagged: false` does not filter.
  - `flagged: true` fails on create and update with `The flag is not available through EventKit — omit the flagged field and retry.` The message names the recovery, because agents hit it mid-call. `flagged: false` or omitted is a no-op on **both** create and update — every record reports `flagged: false`, so that end state already holds and update must tolerate a caller echoing a record back.
  - Public reminder keys are snake_case: `list_id`, `all_day`, `completion_time`. Omitted optional fields are absent rather than null.
  - Recurrence, alarms, tags, URLs, locations, subtasks, and the flag are not implemented for **reminders**.

### Calendar

- `EventRecord.id` is `calendarItemIdentifier`, not `eventIdentifier` — Apple documents the latter as changing when an event moves calendars or re-syncs. `calendarItemIdentifier` can still be lost by a full iCloud sync, so every write error about a missing id says so and tells the caller to re-read.
- `EventRecord.recurring` reports whether the event is part of a series. `EKEvent` has no `isRecurring`; recurrence is `recurrenceRules` on `EKCalendarItem`, and a non-nil **empty** array does not mean recurring — reading that wrong in the permissive direction would refuse ordinary events.
- **Recurring events are readable and unwritable.** Create refuses any recurrence argument by name; update and delete refuse any event whose `recurring` is true, before touching a field. The refusal explains that apple-bridge will not guess between this occurrence and the whole series, because a model that retries after a bare "not allowed" will try a different field. Edit or delete a series in Calendar.app, not here.
- An event that is one occurrence of a series is still refused. There is no occurrence-scoped write path: `save(_:span:commit:)` with `.thisEvent` on a series master silently diverges from what Calendar.app would do, and the user cannot see the difference.
- Events save and remove through the span-based EventKit API, not the generic `EKCalendarItem` one the reminder path uses.
- A date-only `start` creates an all-day event ending at midnight starting the next day, EventKit's exclusive convention, computed by adding a real day rather than `day + 1` so month end works. `all_day: true` forces it, and an `end` is ignored for all-day events, which always run one day.
- `end` before `start` is refused. A timed create with no `end` defaults to one hour.
- An update that changes nothing is refused (`Update needs at least one field to change.`) rather than silently saving a no-op.
- `calendar: "all"` is a read scope. Writing to it is refused by name.
- Writes are `retry: false`, like reminder writes: the change may already have been applied, and a timeout does not prove otherwise.
- All-day `endDate` reads back as the last minute of the day (`23:59`), not the next midnight, whether we set the exclusive form or iCloud supplied the event. Create and read agree; do not "correct" the writer toward EventKit's documented convention.
- Windowed reads: no `start_after` means now, no `start_before` means a 7-day lookahead, a window wider than 62 days is refused rather than trimmed, and `Recently Deleted` is skipped. Every page reports `window`, `filters`, and `scope`.

## Status

Implemented and in daily use: **Reminders** lists + CRUD over MCP, and **Calendar**
read + CRUD, 66 tests passing, verified against real user data (4 reminder lists,
19 reminders; 15 calendars, 43 occurrences of 3 real recurring series refused for
write with the series left intact). Recurring events are deliberately
read-only — see the Calendar decisions above. The design was captured
2026-09-28 and revised across two rounds of external design review (TCC
responsible-process correction, `remindd` naming, second-grant Calendar, socket
hardening, EventKit ceiling; then Apple Silicon signing requirements, Info.plist
identity, LaunchAgent program/Aqua-session specifics, private-SPI fallback
scoping, and `calendarIdentifier` wire addressing).

Remaining calendar work is tracked in `TODO.md`; the open items are the
EventKit-path tests (row 14) and the read-side record for recurrence
(row 13).