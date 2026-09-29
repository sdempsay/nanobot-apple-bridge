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
- The retry resends the request. That is safe for `lists`. A later mutating command must not treat the retry as exactly-once.
