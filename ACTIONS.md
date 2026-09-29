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
