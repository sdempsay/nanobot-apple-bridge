# AGENTS.md — apple-bridge

Working notes for agents (and humans) in this repo. Read README.md first for the
architecture and its rationale; this file is the operational layer: what is
verified, what is broken in the environment, and what not to rediscover the hard way.

## What this repo is

Two Swift executables plus a shared protocol library (see README):

- `Sources/AppleBridgeProtocol` — wire types (Codable, JSONValue) plus the
  shared `sockaddr_un` builder and `writeAll`. Never import EventKit here.
- `Sources/apple-bridge-helper` — the only target that links EventKit. Runs as a
  per-user LaunchAgent. Holds the TCC grant.
- `Sources/apple-bridge-mcp` — stdio MCP front-end (line-delimited JSON-RPC,
  hand-rolled, zero dependencies). Talks only to the helper's Unix socket.

## Build & test (verified 2026-09-28)

```sh
swift build                                   # clean build, no warnings expected
bash Support/install.sh                       # build, install to ~/.local/bin, sign, bootstrap LaunchAgent
launchctl print gui/$(id -u)/com.org.dempsay.apple-bridge.helper | grep -E "state|pid"
cat ~/Library/Application\ Support/apple-bridge/helper.log
```

Remove the agent:

```sh
launchctl bootout gui/$(id -u)/com.org.dempsay.apple-bridge.helper
rm ~/Library/LaunchAgents/com.org.dempsay.apple-bridge.helper.plist
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

## Wire-protocol rules (pinned in README, enforced in code)

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
  restarts. `lists` is safe to resend. A mutating command must not assume that
  retry is exactly-once.
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
- [x] End-to-end `lists`: MCP stdio → socket → helper → EventKit → real user lists
- [ ] Milestone 2: `reminders`/`create`/`update`/`delete` (stable signing identity
      — done)
- [ ] Milestone 3: Calendar commands (second grant flow)

Verified end-to-end sample (2026-09-28): `tools/call lists` returned the user's
four lists (Reminders [default], Family, Work, For Shawn) with calendarIdentifiers.
Note: a list named "For Shawn" DOES exist on this Mac — relevant to the old
mac-reminders "No list named For Shawn" blocker.

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
