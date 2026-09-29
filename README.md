# apple-bridge — The macOS Reminders API Apple Never Gave You

Or: How I Learned to Stop Worrying and Love the TCC Prompt

Every macOS developer who has ever needed a reminder out of the machine has had the
same conversation with themselves:

> "AppleScript can do it. AppleScript can do anything, technically."

Then the app hangs, the script times out, and you remember why AppleScript is the
only "official" door: it's the door that's been left unlocked for twenty years
because nobody actually wants to walk through it.

There is no public Reminders API. There is EventKit, which is private. There is a
local SQLite replica, which is TCC-gated and will happily desync your CloudKit if
you write to it. There is JXA — EventKit through osascript — which works right up
until the permission prompt attaches to the wrong process and silently denies you.

So we built a small signed binary that sits on EventKit and talks to the world over
a Unix socket. This is that story.

## There is no API. There is only EventKit, and EventKit is private.

The sanctioned layer is EventKit, and the sanctioned way to use it is to be a
first-party app. Everything else is a negotiation with macOS about who you are and
what you're allowed to see.

The actual stack, for the curious:

```
your code → EventKit → remindd → SQLite (local) ↔ CloudKit ↔ iCloud
```

apple-bridge puts a small signed binary on that layer and gives everything else a
clean way to talk to it. The binary is the only thing that ever touches EventKit.
Everything else talks to the binary over a Unix socket, like civilized software.

## The part where macOS makes you your own certificate authority

Here's a fun fact about macOS privacy prompts: they attach to the *process*, not
the *binary*. Rebuild your helper and the grant evaporates. Ad-hoc signing pins
the grant to the cdhash, so every rebuild re-prompts, and the prompt is the kind
of thing you cannot automate your way out of.

We fixed this by generating our own self-signed code-signing identity and trusting
it in the login keychain. Because that's the kind of thing you do at 2am when the
alternative is clicking "Allow" forever.

The rules that came out of it, because we paid for them:

- The helper is the **only** target that links EventKit. It runs as a per-user
  LaunchAgent in the graphical session, because a launchd-started process is
  responsible for itself — and the prompt needs a UI session to exist at all.
- The MCP front-end never touches EventKit. It doesn't need a grant, it doesn't
  need a stable signature, and it can be rebuilt freely. Apple Silicon won't run
  an unsigned binary, so it's ad-hoc signed on every build, which is fine: nothing
  in TCC attaches to it.
- The signing identity is a stable self-signed cert named `apple-bridge Dev
  Signing`. Do not generate a second one with the same name. We did, once, and
  `codesign --sign "<name>"` became a coin flip about which cert you got.

## The part where the LLM gaslit us about the Work list

Then we pointed an LLM at it. "What are all my active reminders?" it asked, and
helpfully filled every optional field with what it believed "no filter" meant:

```json
{"due_after": "1970-01-01", "due_before": "2100-01-01",
 "flagged": false, "limit": 100, "list": "", "priority": "none",
 "search": "e", "status": "open"}
```

The Work list came back empty. The LLM concluded the reminders must be in a
different account. They were not. They were in the list it never asked for
(`list: ""` means "the default list", which has zero open reminders), excluded by
a due window that silently drops undated reminders, narrowed by a priority filter
that means "unset", and searched for the letter "e".

We fixed it the only way that reliably works with a small model:

1. **A tool with no arguments.** `reminders_all` cannot be mis-filled, because
   there is nothing to fill.
2. **Blank means absent.** `""` is not a filter; it is a model being thorough.
3. **Read results that explain themselves.** Every page says what it read, which
   filters applied, and how many undated reminders the due window ate:

```json
{ "matched": 0,
  "scope": "default list \"Reminders\"",
  "filters": { "due": "1970-01-01..2100-01-01", "status": "open" },
  "note": "nothing matched these filters; 13 reminder(s) exist in this scope;
           6 reminder(s) with no due date were excluded by the due window" }
```

The model stopped gaslighting us the day the tool started talking back.

## Before / after

Before — JXA, the flimsy vehicle:

```js
ObjC.import("EventKit")   // pray
```

After — one call, no filters to get wrong:

```
reminders_all → 19 reminders, 6 open, 4 lists, one call
```

## What it actually is

Three Swift targets in one package:

- `AppleBridgeProtocol` — wire types and the pure logic worth testing without
  EventKit: the `sockaddr_un` builder, `writeAll`, `readFrame`, the Reminders
  rules, and `Deadline` (one time budget per request, threaded through every
  waiting hop).
- `apple-bridge-helper` — the only target that links EventKit. Signed, stable,
  runs under launchd, holds the TCC grant.
- `apple-bridge-mcp` — a hand-rolled stdio MCP server. No SDK, because SwiftPM
  on this Mac cannot clone a git dependency to save its life (see AGENTS.md).

## The rules we learned the hard way

- Every hop that waits takes the request `Deadline` and claims it. A bare
  `semaphore.wait()` turns one stuck queue into an infinite hang.
- Expected refusals exit 0, so the LaunchAgent's `KeepAlive` doesn't restart the
  helper into a prompt loop.
- A timeout is not reconnectable. Silence doesn't prove the connection died, and
  the request may already have been applied.
- Lists are addressed by EventKit `calendarIdentifier` on the wire, never by
  title. Two accounts both ship a "Reminders" list; titles lie.
- `flagged: false` is a no-op on create and update. `flagged: true` fails, and
  the error names the recovery, because agents hit it mid-call.

## Status

Working, tested (32 tests), and in daily use against real reminders. The design,
its rationale, and the pinned decisions live in [PRD.md](PRD.md); the operational
rules agents must follow are in [AGENTS.md](AGENTS.md); and the whole messy
story, day by day, is in [ACTIONS.md](ACTIONS.md).

Now go write some code that actually matters.
