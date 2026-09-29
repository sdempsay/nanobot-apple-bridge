# Actions

## 2026-09-28

- Read the working tree after the design-doc and `.gitignore` updates (`.build/` and `.swiftpm/` are ignored). The four review bugs are still in the helper and the MCP client.
- Recorded those bugs in `TODO.md` and the resulting rules in `PRD-updated.md`.
- Fixed the four failure-path bugs. Shared `unixSocketAddress` / `writeAll`, helper ignores `SIGPIPE` and exits 0 on expected refusals, MCP client retries a dropped helper once.
- `swift test --filter SocketAddressTests`: 5 tests passed, including a full-length `sun_path` bind+connect and `writeAll` returning `EPIPE` without killing the process.
- `Support/install.sh` copied the new helper, then `codesign` failed with `errSecInternalComponent` (this session cannot talk to the login keychain). The LaunchAgent was bootstrapped ad-hoc, a shell-spawned second copy stole the socket, and both were stopped. The agent stays unloaded until `bash Support/install.sh` is run from a normal Terminal, which can sign with "apple-bridge Dev Signing".

## 2026-09-29

- Installed binaries now go to `~/.local/bin`: `apple-bridge-helper` (stable signature) and `apple-bridge-mcp` (ad-hoc). The LaunchAgent `Program` points at the helper there. The socket and log stay in Application Support. The old helper copy under Application Support is removed on install.
