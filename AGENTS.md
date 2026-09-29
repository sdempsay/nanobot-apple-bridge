# AGENTS.md — apple-bridge

Working notes for agents (and humans) in this repo. Read PRD.md first for the
architecture and its rationale; this file is the operational layer: what is
verified, what is broken in the environment, and what not to rediscover the hard way.

`ACTIONS.md` is the dated work log — append to it when you change code, signing, or
docs. Rules that are still true go here; history goes there.

## What this repo is

Two Swift executables plus a shared protocol library (see PRD.md):

- `Sources/AppleBridgeProtocol` — wire types (Codable, JSONValue) plus the pure
  logic that is shared or worth testing without EventKit: the `sockaddr_un`
  builder, `writeAll`, the Reminders rules, and `Deadline` (one time budget per
  request, threaded through every waiting hop). Never import EventKit here.
- `Sources/apple-bridge-helper` — the only target that links EventKit. Runs as a
  per-user LaunchAgent. Holds the TCC grant.
- `Sources/apple-bridge-mcp` — stdio MCP front-end (line-delimited JSON-RPC,
  hand-rolled, zero dependencies). Talks only to the helper's Unix socket.

## Build & test (verified 2026-09-28)

```sh
swift build                                   # clean build, no warnings expected
bash Support/install.sh                       # build, install to ~/.local/bin, sign, bootstrap LaunchAgent
launchctl print gui/$(id -u)/org.dempsay.apple-bridge.helper | grep -E "state|pid"
cat ~/Library/Application\ Support/apple-bridge/helper.log
```

Remove the agent:

```sh
launchctl bootout gui/$(id -u)/org.dempsay.apple-bridge.helper
rm ~/Library/LaunchAgents/org.dempsay.apple-bridge.helper.plist
```

MCP handshake smoke test (no helper required; expects initialize + tools/list):

```sh
printf '%s\n%s\n' \
 '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}' \
 '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | ./.build/debug/apple-bridge-mcp
```

With no helper running, `tools/call` returns a graceful `isError` payload naming
the socket path — that is correct behavior, not a bug.

## Environment blocker: SwiftPM cannot clone git dependencies

**Symptom:** `swift package resolve` fails with `Failed to clone repository <url>:`
(empty error) for *any* GitHub dependency, over HTTPS *and* SSH. CLI `git clone`
of the same URLs works fine. This is SwiftPM's embedded git (Xcode 27 beta /
macOS 27 beta toolchain, Swift 6.4) — no `--use-system-git` flag exists in this
build. Not caused by git config, LFS settings, proxies, or cache state (all
checked and reverted).

**Consequence:** the official MCP Swift SDK is not usable right now. It also
pulls `eventsource → swift-nio → async-http-client`, so vendoring it by hand
means vendoring ~6 repos. We implement MCP stdio directly instead (~200 lines).

**If someone asks "why no dependencies?":** this section. Revisit when SwiftPM
fetching works on this machine; the SDK decision is reversible because the
hand-rolled layer is confined to `apple-bridge-mcp/main.swift`.

## TCC lessons (learned live, do not relearn)

1. **Attribution is to the responsible process, not the signature.** Running the
   helper from a terminal during testing returned `granted` immediately — because
   the terminal host already had Reminders access from mac-reminders work, not
   because our binary was approved. Only the launchd-started path gives the
   helper its own identity. Test via the LaunchAgent, never via `swift run` or a
   wrapper script.
2. The helper's Info.plist must carry `CFBundleIdentifier`
   (`org.dempsay.apple-bridge.helper`) plus both usage strings
   (`NSRemindersFullAccessUsageDescription`, `NSCalendarsFullAccessUsageDescription`).
   It is embedded via `-sectcreate __TEXT __info_plist` (see Package.swift).
3. Signing identity determines whether the grant survives rebuilds. An **ad-hoc**
   signature gives TCC a designated requirement of `cdhash H"…"` — every rebuild
   is a brand-new client and re-prompts (this bit us: three `install.sh` runs,
   three prompts). With the stable self-signed identity below, the requirement is
   `identifier "org.dempsay.apple-bridge.helper" and certificate root = H"…"`,
   which survives rebuilds. `install.sh` prefers that identity and warns loudly if
   it falls back to ad-hoc.
4. The LaunchAgent must be `LimitLoadToSessionType = Aqua` — a system daemon
   context has no UI session for the prompt.

## Failure-path rules (learned the hard way, keep them)

- **Any hop that waits on a semaphore must take the request `Deadline` and call
  `deadline.claim(gate, hop:)` — never a bare `gate.wait()`.** A bare wait turns
  one stuck queue into an infinite hang for that connection, and the agent only
  sees a timeout with no explanation. Per-hop timeouts are worse: three hops at
  25s each is a 75s request. `Deadline` is created once in `dispatchReminder` and
  passed down, so the whole request stays inside one budget and the error names
  the stuck hop.
- Expected refusals (access denied, another helper already listening, socket path
  too long) exit 0 so `KeepAlive` does not restart the job into a prompt loop.
- **The response read is bounded by the request `Deadline`, not by `SO_RCVTIMEO`
  alone.** `readFrame(fd:deadline:hop:)` in `AppleBridgeProtocol` `poll()`s with the
  remaining budget before each byte. Framing stays byte-at-a-time so a reader can
  never swallow the next frame on a reused connection, but `SO_RCVTIMEO` bounds only
  one `read()` — a helper that dribbles one byte every 29s could otherwise hold an
  exchange open forever. Verified live: a listener that accepts and never answers now
  fails in 31s with `no complete response from the helper: helper response did not
  answer within 30 seconds` instead of hanging.
- The MCP client's budget (30s) sits **above** the helper's (25s) on purpose, so the
  helper's error — which names the stuck EventKit hop — reaches the agent first. The
  MCP budget is created once per `send` and shared by the retry, so two attempts
  cannot stack to 60s.
- A timeout is **not** reconnectable. Silence does not prove the connection died, and
  the request may already have been applied; resending a create/update/delete on
  timeout would duplicate or clobber work.
- A late callback after a timeout writes its captured box and nobody reads it.
  Harmless; do not add a mutex for it.

## Wire-protocol rules (pinned in PRD.md, enforced in code)

- Lists are addressed by EventKit `calendarIdentifier` (`listId`). Never by
  title — iCloud and On My Mac both ship a list named "Reminders".
- One JSON object per line in each direction. Responses: `{ok, error, result}`.
- Keep the command set narrow — same-user access is the entire security boundary.

## Gotchas

- **Dispatch sources must be retained while active.** A `makeReadSource` stored
  only in a local variable is released when the function returns; events stop
  firing silently, and clients still `connect()` successfully against the kernel
  backlog and wait forever for a response. Symptom: "helper accepts but never
  answers." This was the real first bug — it masqueraded as an EventKit threading
  issue until `sample <pid>` showed no accept thread at all.
- Stale `helper.sock` after a crash: the helper unlinks it at startup (after
  probing that nothing is listening). If you hand-delete the socket while the
  agent is running, launchd's KeepAlive will restart and heal it.
- A client that disconnects mid-response must not kill the helper. `SIGPIPE` is
  ignored, accepted sockets set `SO_NOSIGPIPE`, and a failed write drops that
  connection only.
- Denied Reminders access, "another helper is already listening", and a socket
  path that does not fit in `sun_path` exit 0. Any other exit is a crash:
  `KeepAlive` / `SuccessfulExit` false restarts the job. Do not exit non-zero
  for an expected refusal.
- The MCP client closes its socket and retries a call once after the helper
  restarts. `lists` and `reminders_read` are safe to resend. Create, update,
  and delete are not retried: the write may already have been applied.
- Backgrounding the helper inside a tool/exec shell hangs the caller on the
  pipe; run it via the LaunchAgent or redirect and detach properly.
- `Package.swift` embeds an absolute path to Info.plist via `#filePath` — fine
  for local dev, breaks if the package moves; revisit before any CI.

## Status (2026-09-28)

- [x] Package skeleton, three targets, zero dependencies
- [x] Helper: socket server (0700 dir / 0600 sock verified), `lists` command,
      stale-socket handling, single-instance probe
- [x] MCP: initialize/tools-list/tools-call verified over stdio
- [x] LaunchAgent installs and runs the binary directly under launchd
- [x] First-run TCC prompt attributed to the helper's own identity (user clicked
      Allow under the LaunchAgent)
- [x] Stable signing identity created and in use — see "Recreating the signing
      identity" below. CORRECTION that preceded it: ad-hoc rebuilds DO re-prompt
      every time (TCC anchors ad-hoc signatures to the cdhash).
      **The identity of record is SHA-1 `3C6196C867280334C4E6F4A25121C35B09B03FF6`**
      (CN `apple-bridge Dev Signing`, notBefore 2026-09-29 03:07:33 UTC, expires 2036).
      Do not generate another cert with the same CN — a duplicate makes `codesign --sign
      "<name>"` ambiguous and can silently change the designated requirement, which
      invalidates the Reminders grant. Check with `security find-certificate -a -c
      "apple-bridge Dev Signing" -Z` before creating anything.
- [x] End-to-end `lists`: MCP stdio → socket → helper → EventKit → real user lists
- [x] Milestone 2: `reminders` / `create` / `update` / `delete`, exposed as
      `reminders_read`, `reminders_create`, `reminders_update`, `reminders_delete`
- [x] 2026-09-29: `reminders_all` (zero arguments) reads every visible list with both
      statuses in one call; `reminders_read` also accepts `list: "all"`. Verified live:
      19 records across 4 lists (6 open, 13 completed). Writing to `"all"` is refused.
- [x] 2026-09-29: blank optional strings are treated as omitted (`optionalField`), and
      the tool descriptions were rewritten against gpt-oss measurements — see
      "Calling the tools from a weak model".
- [x] 2026-09-29: `flagged: false` is a no-op on update as well as create (update
      used to reject it, which broke read → echo → update). `flagged: true` still
      fails, and the message now names the recovery.
- [x] 2026-09-29: one `Deadline` per request (25s) threaded through every waiting
      hop, replacing a 25s fetch timeout plus an unbounded `onMain` wait. Tests:
      `DeadlineTests` (4), including that the budget cannot compound across hops.
- [x] 2026-09-29: the MCP→helper response read is bounded by a per-request
      `Deadline` via `readFrame` (25s helper / 30s client). Tests: `FrameReadTests` (5)
      — silent peer, partial frame then silence, closed peer, spent budget, and that a
      frame boundary does not eat the next one. 27 tests (superseded by 52 at
      Milestone 3a).
- [x] 2026-09-29: Milestone 3a — Calendar read. `calendars`, `events_read` (with
      `start_after` / `start_before`), and `events_upcoming` (zero arguments). Second
      TCC grant required one human click, same as Reminders. `EventRecord.id` uses
      `calendarItemIdentifier`, not `eventIdentifier` — Apple documents the latter as
      changing when an event moves calendars or re-syncs. `EventPage` reports `window`,
      `filters`, and `note`. 52 tests.
- [x] 2026-09-29: Milestone 3b — Calendar write. `events_create` / `events_update` /
      `events_delete`, all refusing recurring events. The refusal is helper-side, not just
      in the tool description. `EKEvent` has no `isRecurring` — it is `recurrenceRules` on
      the superclass, and a non-nil *empty* array is NOT recurring; getting that wrong in
      the permissive direction would refuse ordinary events. Events save/remove via the
      span API (`save(_:span:commit:)` / `remove(_:span:commit:)`), not the generic
      `EKCalendarItem` one the reminder path uses. 66 tests. Verified live: create →
      read back → update → delete, plus 43 occurrences of 3 real series refused on both
      update and delete with the series still intact afterward.
- [x] 2026-09-29: the `org.dempsay` LaunchAgent rename is done. `install.sh` retires
      `com.org.dempsay.…` on every run. **Both grants survived it with no prompt**, and
      they also survived the Calendar usage-string text change — see below.

**Changing the usage string or the LaunchAgent label does not re-prompt.** Verified
live, not reasoned: with the usage string changed to mention creating/editing/deleting
events and the agent relabelled `com.org.dempsay` → `org.dempsay`, both Reminders and
Calendar came back `granted` immediately. Neither is part of the designated
requirement, which is `identifier "org.dempsay.apple-bridge.helper" and certificate
root = H"3c6196…"` — built from the embedded Info.plist's `CFBundleIdentifier` (never
change that) and the signing cert. A re-prompt after either change means something else
is wrong; do not go looking for the string or the label.

**`CSSMERR_TP_NOT_TRUSTED` on `find-identity` is a red herring.** It is reported even
when the keychain is unlocked and `codesign` succeeds, so it is NOT a health check for
this self-signed identity — do not read it as "the grant is about to break" or as
evidence that the keychain is locked. Test signing instead: copy a binary and run
`codesign --force --sign "apple-bridge Dev Signing" /tmp/probe`. An unlocked keychain
yields exit 0 and a requirement anchored to `3c6196…`; a locked one fails with
`errSecInternalComponent`. `install.sh`'s guard correctly tests
`security show-keychain-info` instead, which is why it never misreads this.

**All-day `endDate` is normalized to the last minute of the day.** EventKit stores
`2026-10-09T23:59` regardless of whether we set an exclusive next-midnight or not, and
iCloud-sourced all-day events read back the same way — so create and read agree and
row 13's display concern does not reproduce. Verified against a self-created event and
against two real all-day events in the Family calendar. Do not "fix" the writer to emit
next-midnight on the strength of EventKit's documented convention; the observed
behaviour is authoritative and the round trip is what matters.

**Calendar grant flow — `tccutil` cannot do this.** It addresses
LaunchServices-registered bundles; the helper is a bare executable whose plist is
embedded via `-sectcreate __TEXT __info_plist`, which is not one. Both
`org.dempsay.…` and `com.org.dempsay.…` return `No such bundle identifier
(OSStatus error -10814)`. The real flow is `bash Support/install.sh` then click
Allow on the prompt. `Support/grant-calendar-permission.sh` was written on the
wrong assumption and removed in 283cd4e — do not recreate it.

**Locked keychain is a real failure mode.** If the login keychain is locked,
`codesign` fails with `errSecInternalComponent` and
`security show-keychain-info` returns `User interaction is not allowed`.
`install.sh` now checks for this up front and refuses
before touching the running agent, because the failure it used to cause was
silent: the freshly-linked ad-hoc binary got copied into place, collapsing the
designated requirement to the cdhash and invalidating the TCC grant. Unlock with
`security unlock-keychain ~/Library/Keychains/login.keychain-db` and re-run.

**Naming.** Every identifier this repo owns starts `org.dempsay`. The
LaunchAgent label was `com.org.dempsay.…` until 741cce2; `install.sh` now retires
that label on every run so a leftover agent cannot compete for the socket.

Verified end-to-end sample (2026-09-28): `tools/call lists` returned the user's
four lists (Reminders [default], Family, Work, For Shawn) with calendarIdentifiers.
Note: a list named "For Shawn" DOES exist on this Mac — relevant to the old
mac-reminders "No list named For Shawn" blocker.

Verified again (2026-09-29) through the LaunchAgent: an all-day reminder was
created on the default list, completed, cleared, and deleted; a timed reminder
was created on Work by list name and deleted. `~/.nanobot/config.json` was not
changed. The MCP tool `lists` was not renamed.

## Calling the tools from a weak model

Measured against `gpt-oss:latest` on this Mac (Ollama, temperature 0), using the real
`tools/list` output. Not theory — these were reproduced.

- **Small models fill every optional field.** Asked to "read all my reminders", gpt-oss
  sent `reminders_read` with `due_after: 1970-01-01`, `due_before: 2100-12-31`,
  `search: ""`, `priority: ""`, `list: ""`, `flagged: false`, `limit: 100`. Those look
  permissive but each one narrows: the due window dropped every undated reminder, and
  `search: ""` hit the blankSearch rejection.
- **`enum` is not enforced by Ollama for this model** — it emitted `priority: ""`,
  which is not a legal enum value. Server-side validation and coercion are the real
  backstop; do not rely on the schema to reject junk.
- **What fixed it, in order of strength:**
  1. A zero-argument tool for the common intent (`reminders_all`). A model cannot
     mis-fill a tool that takes nothing. `reminders_all {}` is what it now chooses.
  2. Blank-means-absent coercion in `optionalField` (MCP layer).
  3. Description text: state the rule at the **tool** level ("every field you send
     NARROWS the result; to apply no filter, omit it"), name the footgun ("due_after /
     due_before EXCLUDE reminders that have no due date"), and **delete "Defaults to X"
     from field descriptions** — telling a weak model the default invites it to send it.
     With only (3), the junk call became `reminders_read {}` — correct, but still the
     default list, not "everything".
- When a prompt is about one named list, it now produces exactly `{"list": "Work"}`.
- **Read results now explain themselves.** `ReminderPage` carries `scope` (what was
  actually read: `all 4 lists` / `list "Work"` / `default list "Reminders"), `filters`
  (only the filters that really narrowed it — `status` shows up because omitting it
  means open-only), and `note` (one line, only when the caller is about to be misled).
  This is the layer that catches a caller we do not control: gpt-oss kept sending
  `due_after: 1970-01-01` + `due_before: 2100-01-01` + `list: ""` and reading `matched: 0`
  as "the list is empty". It now gets:
  `nothing matched these filters; 13 reminder(s) exist in this scope; 6 reminder(s) with
  no due date were excluded by the due window — omit due_after/due_before to include them`.
- Caller-side naming gotcha (outside this repo, in `~/.nanobot/config.json`): the slot was
  `mac-reminders`, so tools were `mcp_mac-reminders_reminders_read`. gpt-oss kept emitting
  `mcp_mac_reminders_…` with underscores → `error parsing tool call` → 4 retries → model
  fallback. The slot is renamed to `mac_reminders` (2026-09-29) so the model's guess is
  correct. Needs a gateway restart, and tool names change for every session.

## Recreating the signing identity (one-time, per machine)

Self-signed code-signing cert, no Apple account needed. Run it in a temp dir; the
private key and .p12 are deleted after import. `security add-trusted-cert` pops a
GUI authorization dialog — expect to enter the login password once.

```sh
openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 \
  -sha256 -config signing.cnf            # CN "apple-bridge Dev Signing", EKU codeSigning
openssl pkcs12 -export -inkey key.pem -in cert.pem -out identity.p12 -passout pass:…
security import identity.p12 -k ~/Library/Keychains/login.keychain-db -P … -T /usr/bin/codesign
security add-trusted-cert -p codeSign -r trustRoot -k ~/Library/Keychains/login.keychain-db cert.pem
rm -f key.pem identity.p12
security find-identity -v -p codesigning   # should list "apple-bridge Dev Signing"
```

The `basicConstraints = critical,CA:TRUE` + `keyUsage …,keyCertSign` combination
is what lets a self-signed cert act as its own anchor for `certificate root` in
the designated requirement. To remove: `security delete-certificate -c "apple-bridge Dev Signing"`
plus the matching private key (Keychain Access → login → certificates).
