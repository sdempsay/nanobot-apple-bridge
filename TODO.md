# TODO

| ID | Task | Status |
| --- | --- | --- |
| 1 | Ignore SIGPIPE and finish socket writes so one client disconnect cannot kill the helper | complete |
| 2 | Drop a dead helper socket in the MCP client and retry that call once | complete |
| 3 | Exit 0 when Reminders access is denied or another helper is already listening, so launchd does not restart the job | complete |
| 4 | Reject socket paths that do not fit in sun_path, and pass bind/connect a length that stays inside sockaddr_un | complete |
