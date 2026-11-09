# BakaShrot - start here

A message store with replication, in PureBasic: servers take JSON (or any)
messages per topic/node from authenticated clients, store them in SQLite,
and replicate them between peers by name. Clients: a DLL, CLI tools, a
Python module. An **internal tool on trusted machines**: correctness and
operations come before security hardening (`Notes.md`, "Threat model").

## Read first

1. `Notes.md`: "Right now" (what's committed, what's next), where things
   stand, "Open items, by importance" (the to-do list), "Testing tips".
2. `Design/`, by topic: `Packets.md` (the protocol, where every file lives,
   code conventions), `Attachments.md`, `Cryptography.md`,
   `StorageConcurrency.md`, `ReplicationIssues.md`, `Release.md`,
   `Suggestions.md`.
3. `git log --oneline` and `git status`: what's committed. Work happens on
   branches off `master` (`timestamps-retention` at this writing).

## Build

- Dev compiler, PureBasic 5.73: `C:\Program Files\PureBasic_573\Compilers\pbcompiler.exe <src> /EXE <out> [flags]`.
  Release compiler, 6.40 C backend: `C:\Program Files\PureBasic_640\Compilers\pbcompilerc.exe <src> /OUTPUT <out> /OPTIMIZER`.
  Code must compile with both (`Release.ps1` checks the 6.40 side).
- `Build.ps1` builds everything into `Build\`, **regenerates keys and
  configs, then runs a server waiting on its console**: don't run it from
  an automated shell. To rebuild after a change, compile what changed:

| Source | Output | Flags |
|---|---|---|
| `Server\BakaShrot_Server.pb` | `Build\BakaShrot_Server.exe` | `/CONSOLE /THREAD` |
| `Client\BakaShrot_Client.pbi` | `Build\BakaShrot_Client.dll` | `/DLL /THREAD` |
| `Tools\<Name>\<Name>.pb` (BakaShrot + PushMessage, GetLatestMessage, GetMessages, GetAttachment, Query, ResolveIds, List, GenerateKeyPairs) | `Build\<Name>.exe` | `/CONSOLE` |
| `Client\BakaShrot_Client_Prototypes.pbi` | `Build\ClientExample.exe` | `/CONSOLE` |
| `Tests\Bench\BenchServer.pb` (the server with a stop file, used by every test) | `Build\Bench\BenchServer.exe` | `/CONSOLE /THREAD` |
| `Tests\Bench\BenchClient.pb`, `BenchSeed.pb` | `Build\Bench\` | `/CONSOLE /THREAD` |
| `Tests\HandshakeTest.pb`, `Tests\CipherTest.pb` | `Build\` | `/CONSOLE` |
| `Tests\AttachmentEdgeClient.pb` | `Build\AttachmentEdgeClient.exe` | `/CONSOLE /THREAD` |

- `Release.ps1 [-Force]` builds the release with 6.40 into `Release\` and
  smoke-tests it (`-Force` replaces an existing folder of the same name).

## Test

Each suite starts its own servers (`BenchServer.exe`) on fixed ports, in a
fresh folder under `Build\`, and prints PASS/FAIL lines; exit code 0 means
all passed. `powershell -ExecutionPolicy Bypass -File Tests\<Suite>.ps1`:

| Suite | Ports | Covers |
|---|---|---|
| `Names-Test.ps1` | 12401-12402 | names/ids, filters, wildcards, replication by name |
| `BigMessages-Test.ps1` | 12403-12404 | 16 MB messages, handshake frame limit, `is_json`, query errors |
| `GetMessages-Test.ps1` | 12405 | runs of messages, `--follow` |
| `Python-Test.ps1` | 12406-12407 | `bakashrot.py` (`check_bakashrot.py`), the wire is encrypted (`wire_check.py`) |
| `Retention-Test.ps1` | 12408-12409 | `pushed_at`, retention, schema upgrade (Python) |
| `Attachments-Test.ps1` | 12410-12411 | attachments through the tools, replication, limits |
| `AttachmentEdges-Test.ps1` | 12413-12414 | raw-protocol edge cases, expiry, resuming, corruption (Python) |
| `Restart-Test.ps1` | 12415-12416 | servers killed mid-traffic and mid-catch-up: nothing acknowledged lost, ids carry on, both catch up (Python pushers) |

Plus `Build\HandshakeTest.exe` and `Build\CipherTest.exe` (no server), and
the release's smoke test. Speed: `Tests\Bench\Bench-Replication.ps1 -Ramp 10x0 -Parts Ramp`
(push ceiling for 4 servers: ~17,000 msg/s with the default `Synchronous =
FULL`, ~34,000-40,000 with `-Synchronous NORMAL`). After a change, run every
suite: they take a few minutes in all.

## Traps

- **Run exes from `Build\`**: the antivirus blocks them in temp folders.
- **`Build\` holds private keys**: git-ignored, never publish it. The one
  exception: `Examples/*/` commit their configs, keys included, on purpose
  (public, example-only, marked so); don't copy those keys anywhere else.
- **PureBasic is single pass**: constants, structures and procedures must
  be declared before use, so include order matters (e.g. `Config.pbi`
  includes `Packets.pbi` for its constants).
- **`SetDatabase*()` binds the next statement run on that connection**, not
  a specific one: set them right before their `DatabaseUpdate/Query`.
- **Never `Goto` out of a `Select`**: 5.73's ASM backend keeps the value on
  the stack, the jump corrupts it (a config error crashed the server with
  0xC0000005). Set the error, leave the `Select`, then jump. Out of
  `For`/`ForEach`/`While` loops is fine (checked on both compilers).
- **PureBasic lists aren't safe to walk from several threads** (`ForEach`
  moves the shared current element): give each thread its own copy.
- **Files mix CRLF and LF**: edits must keep each file's line endings.
- **PowerShell 5**: JSON passed as an argument loses its double quotes
  (tests write it to a file, `@file`), and `@()` can't be passed through
  `-File`.
- **Bash tool heredocs collapse `\\`**, and PureBasic uses `\` for fields:
  write edit scripts to files, or use the Edit tool.
- **The real server needs a console** (it stops at once without input):
  tests use `BenchServer.exe` and its stop file instead.

## Working rules

- **Commit only when the owner asks**, on a branch, not `master`.
- **Wire changes bump `#BakaShrot_ProtocolVersion`** (`Packets.pbi`, 6 at
  this writing); any difference refuses the connection.
- **Schema changes** add a `Server/Storage/db_schema_vN.dbml` (v8 at this
  writing) and a migration in `SetupStorageDatabase()` (`Storage.pbi`),
  existing databases must keep working.
- **Packets** follow `Design/Packets.md` "Code conventions": one file per
  packet in `Commons/Networking/Packets/`, `_Encode` / `_Decode` (and
  `_Free` when it holds data), every field validated on decode.
- **Every write goes through the writer** (`Server/Storage/Writer.pbi`,
  under its mutex); reads use the thread's own connection.
- **Docs follow the code**: a finished piece gets a "Done: ... (date)"
  section in `Notes.md`, what's left goes to its open items, and the
  `Design/` doc of that area is updated with it.
