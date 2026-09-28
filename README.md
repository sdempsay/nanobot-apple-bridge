# apple-bridge

A signed Swift bridge to Apple's local data stores (Reminders first, Calendar next),
fronted by a lightweight stdio MCP service so agents get reliable, structured access
to Apple services without touching AppleScript.

Requires macOS 14+ — that's when full Reminders access
(`requestFullAccessToReminders()`) and the split usage-string keys landed.

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
apple-bridge-mcp        ← thin Swift stdio MCP service (fast-moving, unsigned)
   │  Unix domain socket, newline-delimited JSON
   ▼
apple-bridge-helper     ← signed Swift per-user LaunchAgent (stable, privileged)
   │  EventKit
   ▼
remindd → SQLite ↔ CloudKit ↔ iCloud
```

### Signed Swift helper (the privileged piece)

- Links EventKit, embeds an Info.plist (`-sectcreate __TEXT __info_plist`) with
  `NSRemindersFullAccessUsageDescription`, calls `requestFullAccessToReminders()`.
  (Linking the current SDK makes the older `requestAccess(to:)` path fail without
  a prompt.)
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
  2. The parent spawns it with `responsibility_spawnattrs_setdisclaim` — the
     fallback for ad-hoc/dev use.
- Exposes a narrow, stable command set over the socket:
  `lists`, `reminders`, `create`, `update`, `delete` (+ calendar equivalents later).
  Narrow is a security requirement, not minimalism: same-user access is the *whole*
  boundary, so any local process can drive whatever the helper exposes once it's
  approved.
- Bonus unlock: as a long-lived process with a warm `EKEventStore`, it can subscribe
  to `EKEventStoreChangedNotification`. Note the notification is coarse — it means
  "something changed," and the helper must refetch — and it only exists while the
  process stays up and runs a run loop. Another reason the LaunchAgent is the real
  design and a per-call Swift process is not.

### Thin stdio MCP service (the fast-moving piece)

- A second Swift executable in this repo (`apple-bridge-mcp/`), built on the
  official MCP Swift SDK. Same language and toolchain as the helper, and the two
  share the socket's command/response types as Swift `Codable`s.
- Needs no TCC grant and no stable signature — it never touches EventKit, only the
  socket — so it can be rebuilt and iterated freely. Only the stable helper carries
  the signing discipline.
- Relationship to mac-reminders: none in code. mac-reminders (Python + JXA) stays
  untouched as the reference implementation until apple-bridge reaches parity, then
  is superseded.

### Socket

- Unix domain socket at `~/Library/Application Support/apple-bridge/helper.sock`.
  Directory mode 0700 is necessary but not sufficient: the socket file itself gets
  mode 0600. Same-user UID is the trust boundary.
- Not TCP: no port squatting, no firewall prompts, no network exposure.
- Framing: newline-delimited JSON, e.g.
  `{"command":"create","list":"Work","title":"..."}` → one JSON response line.
- **Single-instance rule:** two clients that fail to connect must not race to start
  two helpers. Either the LaunchAgent is the only thing that starts it (preferred),
  or bind is serialized with a lock.

### Lifecycle

- **A per-user LaunchAgent is the primary design**, running in the graphical session
  so the TCC prompt can actually present. A system daemon has no UI session to show
  the dialog, and in some launchd contexts `requestFullAccessToReminders()` waits
  forever instead of returning denied.
- On-demand spawn from the MCP layer is the fallback only, and only if the spawn
  disclaims responsibility via `responsibility_spawnattrs_setdisclaim` — otherwise
  the grant attributes to whatever host launched the MCP server.

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

## Status

Design captured 2026-09-28 and revised after external design review (TCC
responsible-process correction, `remindd` naming, second-grant Calendar, socket
hardening, EventKit ceiling) and a decision to write both components in Swift.
No code yet. Natural first steps:

1. Scaffold one Swift package with two executable targets: `apple-bridge-helper`
   (EventKit auth flow, socket server, `lists` command) and `apple-bridge-mcp`
   (MCP Swift SDK, socket client, one tool) — sharing Codable wire types.
2. Add the per-user LaunchAgent plist; the helper runs under launchd from day one,
   not as an afterthought.
3. Port the remaining commands (`reminders`, `create`, `update`, `delete`) to
   parity with mac-reminders.
4. Calendar support (second usage string + grant flow).
