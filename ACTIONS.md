# Actions

## 2026-09-28

- Read the working tree after the design-doc and `.gitignore` updates (`.build/` and `.swiftpm/` are ignored). The four review bugs are still in the helper and the MCP client.
- Recorded those bugs in `TODO.md` and the resulting rules in `PRD-updated.md`.
- Fixed the four failure-path bugs. Shared `unixSocketAddress` / `writeAll`, helper ignores `SIGPIPE` and exits 0 on expected refusals, MCP client retries a dropped helper once.
- `swift test --filter SocketAddressTests`: 5 tests passed, including a full-length `sun_path` bind+connect and `writeAll` returning `EPIPE` without killing the process.
- `Support/install.sh` copied the new helper, then `codesign` failed with `errSecInternalComponent` (this session cannot talk to the login keychain). The LaunchAgent was bootstrapped ad-hoc, a shell-spawned second copy stole the socket, and both were stopped. The agent stays unloaded until `bash Support/install.sh` is run from a normal Terminal, which can sign with "apple-bridge Dev Signing".

## 2026-09-29

- Installed binaries now go to `~/.local/bin`: `apple-bridge-helper` (stable signature) and `apple-bridge-mcp` (ad-hoc). The LaunchAgent `Program` points at the helper there. The socket and log stay in Application Support. The old helper copy under Application Support is removed on install.
- Added reminder read, create, update, and delete. Filtering and due parsing live in `AppleBridgeProtocol` so the helper and the tests share them. The MCP server (0.2.0) exposes `reminders_read`, `reminders_create`, `reminders_update`, and `reminders_delete` and does not retry the three mutations. `lists` is unchanged.
- `swift test`: 18 tests passed.
- Reinstalled from Terminal with the stable signing identity. Through the LaunchAgent: created an all-day high-priority reminder, completed it and cleared its due date, then deleted it; created a timed low-priority reminder on Work by name and deleted it. Empty update, a flagged create, a bad priority, and an unknown id returned the mac-reminders sentences. Nanobot's config was left on mac-reminders.

### 2026-09-29 (later) — review nits + per-request deadline (nanobot session)

- Verified the installed stack over MCP stdio: `lists` returned the four real lists (Reminders default, Family, Work, For Shawn).
- Flag semantics: `flagged: false` is now a no-op on **update** as well as create — `RemindersRules.updateFlagError` became `updateFlagTrueError`, and the handler's guard is `flag?.newValue?.bool == true`. Verified against a real record: `{"ok":true,...,"flagged":false}`.
- Added `AppleBridgeProtocol/Deadline.swift`: one 25s budget per request, `claim(_:hop:)` refuses with `no time budget left (hop=...)` once spent. Threaded `main.swift` → `dispatchReminder` → `HelperClient.request(_:deadline:)` → `RemindersHandler.handle(_:deadline:)`; no bare `semaphore.wait()` remains on the request path, so a stuck EventKit queue ends one connection instead of hanging it forever.
- 4 new `DeadlineTests` (unspent claim, exhaustion refuses without waiting, zero remaining refuses immediately, both message shapes). `swift test`: 22 tests passed.
- `Package.swift`: `AppleBridgeProtocol` is now a `library` product so tests link the shared logic directly.
- Docs updated in the same pass: README (protocol library contents, deadline rule), `AGENTS.md` (layout, new "Failure-path rules", status checkboxes), `PRD-updated.md` (the flag decision).
- Nanobot-side: added a rule to `~/.nanobot/workspace/AGENTS.md` — read a repo's own `AGENTS.md` before editing outside the workspace, and keep it updated in the same pass.

### 2026-09-29 (later) — signing identity: correcting what this session reported

- This session created a key+cert and reported identity `337077224940B00D20930533EE120E938F7E9464`. That cert is **not** in the login keychain now. The helper actually running is signed by `3C6196C867280334C4E6F4A25121C35B09B03FF6` (`notBefore Sep 29 03:07:33 2026 GMT`) — the identity from the Terminal reinstall recorded above. Treat that one as the project identity.
- Current verified state: exactly one `apple-bridge Dev Signing` certificate in the login keychain, and `codesign --force -s "apple-bridge Dev Signing"` succeeds from this CLI session (tested on a copy of `/bin/ls`). So the 2026-09-28 `errSecInternalComponent` blocker is not reproducing today.
- `security find-identity -v -p codesigning` annotates it `(CSSMERR_TP_NOT_TRUSTED)` while `security dump-trust-settings` shows one code-signing trust setting for that name. Signing and Reminders access both work anyway. If a future rebuild starts re-prompting for Reminders, re-check this trust setting first.
- Do **not** use `~/Library/Application Support/com.apple.remindd/Reminders-GroupContainer-Accessibility.plist` as the grant check: it existed earlier today and is gone now while access still works. That path is not the authoritative store.

### 2026-09-29 (later) — bounded response read on the MCP hop

- First reported as "the MCP client has no read timeout at all". **That was wrong** — `SO_RCVTIMEO`/`SO_SNDTIMEO` were already set to 30s in `ensureConnected`. The real gap is narrower: `SO_RCVTIMEO` bounds a single `read()`, and the response was read one byte at a time, so a helper dribbling bytes could keep an exchange open indefinitely; and a fired timeout surfaced as `read from helper failed (Resource temporarily unavailable)`, naming nothing.
- Added `readFrame(fd:deadline:hop:)` and `FrameReadError` to `AppleBridgeProtocol/SocketAddress.swift` next to `writeAll`. It `poll()`s with `deadline.secondsLeft` before each byte, so the whole frame is capped at one budget however the peer paces itself. Framing stays byte-at-a-time on purpose: a chunked read could swallow the next frame on a reused connection.
- `HelperClient.send` now creates one `Deadline(seconds: 30)` shared by the retry (two attempts cannot stack to 60s) and `exchange` uses `readFrame`. 30s sits above the helper's 25s so the helper's hop-named error wins. New `MCPError.timedOut` is **not** reconnectable — silence does not prove the connection died and the request may already have applied.
- Tests: `FrameReadTests` (5) — frame boundary leaves the next frame readable, silent peer times out inside budget, partial frame then silence times out inside budget, closed peer reports `.closed`, spent budget refuses without waiting. `swift test`: 27 passed.
- Verified live, not just in unit tests: stopped the LaunchAgent, ran a Python listener on the socket path that accepts and never answers, and the MCP call returned `no complete response from the helper: helper response did not answer within 30 seconds` in **31s** instead of hanging. Then removed the dummy socket, re-bootstrapped the agent, and confirmed `lists` returns the real four lists again. Only `apple-bridge-mcp` was reinstalled (ad-hoc); the granted helper binary was not touched.

### 2026-09-29 (later) — making the tools callable by gpt-oss

- Root cause of "the bridge only shows completed reminders": it did not. `status:"any"` on every list returns 6 open + 13 completed. The reported empty lists came from a call that stuffed every optional field — `due_after`/`due_before` (which exclude undated reminders), `search:"e"`, `priority:"none"` — narrowing 13 records to 6.
- **Measured against the local `gpt-oss:latest` (Ollama, temperature 0) using the real `tools/list`.** The old schema produced `reminders_read {'due_after': '1970-01-01', 'due_before': '2100-12-31', 'flagged': False, 'limit': 100, 'list': '', 'priority': '', 'search': '', 'status': 'open'}` for "Read all my reminders." It also emitted `priority: ''`, which is not in the enum — **Ollama does not enforce `enum` for this model**, so server-side handling is the backstop.
- Three fixes, all verified:
  1. `reminders_all` — a zero-argument tool (`isAllLists`/`allListsSentinel` in `RemindersRules`, `calendarsForQuery` in the helper, dispatch in the MCP layer). A model cannot mis-fill a tool that takes nothing. Writes to `"all"` are refused by `calendarForQuery` with a message that says why.
  2. `optionalField` in the MCP layer: blank optional strings mean "omitted". Deliberately **not** applied to `notes` on update (empty clears the note) or to `title` (must stay rejected).
  3. Description rewrite: the NARROWS rule at tool level, the due-window footgun named explicitly, "OPTIONAL — omit to not filter" on each field, and removal of every "Defaults to X" phrase, which had been inviting the model to send the default.
- Result with the new schema and no probe-side help: "Read all my reminders." → `reminders_all {}`; "Show me everything on every list, including finished ones." → `reminders_all {}`; "What is on my Work list?" → `reminders_read {"list": "Work"}`. Before the change, all three produced junk-filled `reminders_read`.
- Live after `bash Support/install.sh` (helper re-signed with the identity of record, grant survived — `lists` returned 4 lists): `reminders_all` → 19 records across Family / For Shawn / Reminders / Work, `truncated: false`; `reminders_read` with `list:"all"` → same 19; `reminders_read` with blank `list`/`search`/`priority` → 13 on the default list instead of erroring; `reminders_create` with `list:"all"` → refused and nothing written (re-count stayed 19).
- Tests: `isAllLists` cases added; `swift test` 28 passed.

### 2026-09-29 (later) — self-explaining read results + caller slot rename

- A caller outside this repo (websocket harness running `gpt-oss:latest`) kept reading `matched: 0` as "the list is empty". It was not: the logged call combined `list: ""` (→ default list, which has 0 open), `status: "open"`, and a 1970→2100 due window (→ drops undated). Verified against real data: Work has 3 reminders by UUID `B7BBE638-252B-4E4F-94B9-8262A962C2B8` and by name; the filter matrix showed `3 → 1 (priority:none) → 0 (+ due window)`.
- Added `scope`, `filters`, `note` to `ReminderPage` (all optional, absent when not applicable, per the wire rule). `effectiveFilters` echoes only what really narrowed the read; `pageNote` fires only on a misleading page. Helper passes the scope via `readScope`.
- Replaying the logged call verbatim now returns:
  `matched: 0, scope: default list "Reminders", filters: {due: 1970-01-01..2100-01-01, status: open}, note: "nothing matched these filters; 13 reminder(s) exist in this scope; 6 reminder(s) with no due date were excluded by the due window — omit due_after/due_before to include them"`
  `reminders_all` returns 19 across all 4 lists with no note.
- Renamed the nanobot MCP slot `mac-reminders` → `mac_reminders` in `~/.nanobot/config.json` (backup `config.json.bak-20260929-090516`). Reason: gpt-oss emits `mcp_mac_reminders_reminders_read` with underscores, the real name has a hyphen, and the mismatch surfaced as `error parsing tool call` → 4 retries → fallback model. Tool names for every session change on restart.
- Tests: 4 new page-diagnostic cases; `swift test` 32 passed. Reinstalled both binaries with the identity of record; `lists` returned 4 lists afterwards, so the grant survived.

### 2026-09-29 (later) — Calendar write, org.dempsay rename, docs

- Merged PR #13 as `b146df6`: `events_create` / `events_update` / `events_delete`, the `org.dempsay` LaunchAgent rename, and the PRD/AGENTS/README sync.
- **Recurring events are refused helper-side**, not just in the tool description. The message explains it will not guess between this occurrence and the whole series, because a model that retries after a bare "not allowed" tries another field instead of stopping. An event that is *one occurrence* of a series is refused too — there is no occurrence-scoped path, since `save(_:span:commit:)` with `.thisEvent` on a master silently diverges from Calendar.app and the user cannot see the difference.
- `events_create` rejects recurrence *by name* (`rrule`, `repeat`, `every`, `frequency`, …). Unhandled, `rejectUnknown` answers "Unknown argument", which reads like a typo and invites a retry with a different spelling.
- `EventRecord.recurring` added so a caller can see which events are unwritable before attempting a write.
- Three EventKit facts that are not guessable and were each wrong on the first attempt: `EKEvent` has no `isRecurring` (it is `recurrenceRules` on the superclass, and a non-nil *empty* array is NOT recurring — getting that wrong permissively would refuse ordinary events); events save through the span API, not the generic `EKCalendarItem` one the reminder path uses; and `day + 1` breaks at month end, so the all-day end adds a real day.
- LaunchAgent renamed to `Support/org.dempsay.apple-bridge.helper.plist`; `install.sh` retires the `com.org.dempsay` label on every run, because a leftover agent under it would run a second helper against the same socket.
- **Both TCC grants survived the rename and the usage-string change with no prompt.** Verified live, not reasoned — neither is part of the designated requirement, which is built from the embedded `CFBundleIdentifier` and the signing cert.
- **`CSSMERR_TP_NOT_TRUSTED` on `find-identity` is a red herring.** It is reported with the keychain unlocked *and* `codesign` succeeding, so it is not a health check for a self-signed identity. This contradicted an earlier note in AGENTS.md, which had recommended using it for exactly that. Test by signing a copy instead. The locked-keychain failure is still real and still fails `codesign` with `errSecInternalComponent`; `install.sh`'s guard correctly tests `security show-keychain-info`.
- **All-day `endDate` reads back as `23:59` on the same day**, not the next midnight, whether we set the exclusive form or iCloud supplied the event. Checked against a self-created event and two real all-day events in the Family calendar: create and read agree, so row 13's display concern does not reproduce. Writer left alone deliberately — matching EventKit's documented convention here is what would have broken the round trip.
- Verified live: create → read back → update → delete → delete-again; 43 occurrences across 3 real series refused on both update and delete, with all 9 occurrences of the probed one intact afterward; `calendar: "all"` refused on write; missing start and empty update both refused; no test events left behind.
- Tests: `EventWriteRulesTests` (14). `swift test` 66 passed, up from 52.

### 2026-09-29 (later) — calHelper retired, slot renamed to apple_bridge

- Removed `calhelper` from `~/.nanobot/config.json` (backup `config.json.bak-before-calhelper-removal`) and renamed the slot `mac_reminders` → `apple_bridge` (backup `config.json.bak-before-slot-rename`), then `launchctl kickstart -k gui/$(id -u)/ai.nanobot.gateway`. Log confirms `MCP connected servers: ['apple_bridge', 'gitlab-mr', 'open-brain']`.
- Reason for the rename: the slot fronts Reminders *and* Calendar now, and `mac_reminders` misdescribed half of it. The stronger reason is guessability — the model emits tool names by composing the slot, and a mismatch cost 4 retries plus a model fallback the first time (see the `mac-reminders` entry above). `apple_bridge` matches the repo, the PR, and `apple-bridge-mcp`, which is the string the model has already seen.
- Reason for removing calHelper: it covered a strict subset (iCloud read, create, no update or delete, hardcoded `America/Chicago`) and having both registered meant two overlapping calendar tool sets for a model to choose between. Its directory, venv, and `~/.config/calHelper/.env` were left in place.
- **Not done, and it is the part that matters:** the calHelper Apple app-specific password in `~/.config/calHelper/.env` is still valid and needs revoking at appleid.apple.com. EventKit never had that exposure — the TCC grant is bound to a signed binary instead.
- Also not done: no edit to `Support/grant-calendar-permission.sh` since its deletion in 283cd4e, and `toolTimeout: 150` was left as-is rather than changed alongside the rename.
