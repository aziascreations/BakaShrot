# Releases - smoke test, 1.0.0, CI/CD

How releases are built and checked, what's missing before a 1.0.0, and what
to keep in mind when the builds move to CI/CD. Related docs:

- `Notes.md`: where things stand, the open items.
- `Design/StorageConcurrency.md`: WAL, `synchronous`, the writer.
- `Design/Cryptography.md`: what the handshake and the encryption protect,
  and what they don't.

## Today

`Release.ps1` builds with PureBasic 6.40's C backend (`/OPTIMIZER`) into
`Release\<version>\` and zips it. `<version>` is `-Version`, or
`<date>-<commit>`, with `-dirty` if the tree has uncommitted changes (a
warning, not an error).

Its smoke test, from the release folder, on one server with a throwaway
database:

- generates keys with `KeyGen.exe`, writes a server and a client config;
- pushes two messages, reads the latest back by name, reads both with
  `GetMessages.exe`, resolves a name, queries them through the `messages`
  view with `is_json = 1`;
- if `python` is on the PATH, reads them and pushes one with
  `python\bakashrot.py`;
- pushes a 3 MB attachment with `PushMessage.exe -a` and reads it back
  identical with `GetAttachment.exe`;
- then force-kills the server and deletes everything.

The end-to-end tests in `Tests/` cover much more (names, replication, big
messages, GetMessages, the Python client, retention, attachments and their
edge cases), but against `Build\` (PB 5.73) and `BenchServer.exe`, not the
release. The list is in `CLAUDE.md`.

## Fixed: the release needed the Visual C++ runtime

**Fixed (2026-11-08):** `Libs/redist/x64/vcruntime140.dll` (from Visual
Studio's `VC\Redist` folder, see `Libs/redist/README.md`) is copied next to
the exes by `Release.ps1`, which refuses to build without it, and
`VERSION.txt` gives its version and "Windows 10 or later, 64-bit". Next to
the exe, it's found before an installed one (it isn't a KnownDLL). Still to
check once on a clean Windows (item 1 below).

What it was:

`libsodium.dll` (the official MSVC build) imports `vcruntime140.dll` and the
`api-ms-win-crt-*` DLLs: the **Visual C++ runtime**. The release didn't
ship it and `VERSION.txt` didn't say so: it worked on the build machine only
because the runtime is installed there, on a clean Windows
`BakaShrot_Server.exe`, `BakaShrot_Client.dll` and every tool would fail to
load. Our own exes and `sqlite3.dll` don't need it. The `api-ms-win-crt-*`
ones are the Universal CRT, part of Windows 10 and later.

Checked with: `grep -a -o -i -E "(vcruntime[0-9_]*|msvcp[0-9_]*|api-ms-win-crt-[a-z0-9-]+)\.dll"`
on each binary of the release folder.

## The 1.0.0 smoke test

What `Release.ps1`'s test should also do, by importance. Most of it exists
in `Tests/` already, to be pointed at the release instead.

1. **Run from the extracted zip**, in a fresh folder, not from the release
   folder: proves the zip has everything. Once on a **clean Windows**
   (Windows Sandbox is enough), which is where the runtime above shows up.
2. **Replication**: two servers from the release, same names with
   different ids. Push on A, read it on B by name, same data, same message
   id; and the other way around.
3. **Restart, picking up where it was** on its last run:
   - kill a server (not a clean stop), start it again on the same database;
   - the messages are still there, and the next push to a topic/node gets
     the next id, not 1 again or one already used;
   - with two servers: push on B while A is down, start A, A catches up on
     what it missed, and B gets what was pushed to A before it went down if
     B hadn't had it yet.

   That's how it's meant to work already, since nothing it needs lives
   only in memory: the next message ids are read from the database the
   first time a pair is pushed to (`Writer.pbi`), `node_heads` is kept by a
   trigger in the same transaction as the messages, and every check-in
   with a peer starts from both sync states, read from the databases. A
   killed process loses nothing committed, even with `synchronous =
   NORMAL` (only a power loss or an OS crash can). **Not tested against
   the release yet**, `Names-Test.ps1` restarts a server but doesn't check
   these.
4. **A clean shutdown**: the release server only stops from its console
   (`quit`), so the test force-kills it, and the clean path never runs.
   Needs a way to stop it without a console: a stop file like
   `BenchServer.exe`'s, or a local admin connection (`Notes.md`, console
   commands can't be scripted). Then check it stops within a few seconds,
   with its last messages committed.
5. **Refusals**:
   - an unknown public key, and a known one with the wrong private key:
     not authenticated;
   - a client given the wrong `ServerPublicKey`: can't connect (tested in
     `Tests/wire_check.py`, not against the release);
   - a frame over 4 KB before authenticating: cut right away;
   - a client reading a topic outside its `ReadTopics`, pushing outside its
     `PushTopics`, querying without `AllowQuery`: refused, and still
     connected.
6. **`config.example.ini` loads**: fill in keys, start the server from it.
   It's documentation, it drifts otherwise.
7. **The server's log is captured and checked**: no "Failed", "invalid",
   "unexpected", "too much data" from the clients that are meant to work.
   Today its output goes to a hidden console nobody reads.
8. **The data rules**:
   - a non-JSON push is stored as is, with `is_json = 0`;
   - a 1 MB message reads back whole, on both servers;
   - a JSON query over non-JSON rows without `is_json = 1` is refused with
     SQLite's error, not answered with no rows (fixed, see below).
9. **Every shipped tool runs once**: `ListNames`, `GetMessages --follow`
   (picks up a new push, exits 1 once the server is gone) aren't yet.
10. **Version hygiene**:
    - `-Version 1.0.0` refuses a dirty tree instead of appending `-dirty`;
    - the release commit is tagged (`v1.0.0`), the version comes from it;
    - `VERSION.txt` gives the protocol version (4) and the runtime needed;
    - the Python client is checked on the oldest version it claims (3.8),
      not only on the latest (3.14 here).

Order: 1-3 first (the runtime is fixed), they're what a real deployment hits
on day one. Then 5-8, cheap since `Tests/` has most of it. 4 with the
console item.

## Fixed: a JSON query over non-JSON rows answered nothing, silently

Item 8, it came up with every change about non-JSON messages. Fixed on
2026-11-08 (Windows).

**What happened.** Since pushes aren't checked to be JSON anymore, the
`data` table holds both, flagged in `is_json`. SQLite's JSON functions
(`->>`, `json_extract()`, ...) raise an error on a row that isn't JSON
("malformed JSON"), and that ends the query: SQLite doing what it should.
But `RunReadOnlyQuery()` reads the rows with PureBasic's `NextDatabaseRow()`,
which returns `#False` both at the end of the rows and on an error, and
`DatabaseError()` stays empty after it. So the query counted as a success:
`{"rows": []}` for an aggregate (`SELECT COUNT(*) ... WHERE message_data ->>
'$.level' = 'warn'` gave no row at all), or only the rows read before the
first non-JSON one. A wrong answer that looked like a right one.

**The fix** (`RunReadOnlyQuery()`, `Server/Storage/Storage.pbi`): once the
rows end, SQLite itself is asked, with `sqlite3_errcode()` on the
connection's handle (`DatabaseID()`), before `FinishDatabaseQuery()`.
`SQLITE_DONE` (or `SQLITE_ROW`/`SQLITE_OK`) means they really ended,
anything else is an error: the query is refused with `sqlite3_errmsg16()`'s
message, and a hint when it's about JSON:

    Query failed: malformed JSON (a row isn't JSON: add is_json = 1 to the WHERE)

Why this one:
- **Safe:** nothing else changes. The rows are still read by PureBasic, the
  query isn't touched, only what happens once they end. A false alarm
  would refuse a good query, visibly; it can't hide a bad one anymore.
- **Small:** two functions of the same `sqlite3.dll` PureBasic loaded, like
  `Writer.pbi` does, loaded once under a mutex. If they can't be found,
  every query is refused rather than unchecked.
- **General:** any error that cut the rows short is caught the same way (a
  write stopped by `query_only` in `DELETE ... RETURNING` too), not only
  JSON. It replaces the `DatabaseError()` check, which may be shared
  between threads anyway.

Not done: having the server add `is_json = 1` to queries itself. It would
mean rewriting arbitrary SQL (subqueries, CTEs, joins), and a query that
wants the non-JSON rows too would get the wrong answer the other way.

**Queries still need the clause** (or `CASE WHEN is_json THEN ... END`) to
run JSON functions over mixed rows: they're refused instead of wrong now.
`CASE WHEN` is the guaranteed form: with `AND is_json = 1`, SQLite doesn't
promise to test that term first. It does today for these queries, and if a
plan ever didn't, the query would be refused now, not answered wrong.

**Not on Linux:** PureBasic's own SQLite is linked in there, not reachable
this way, so it keeps the `DatabaseError()` check that misses it. To do if
it's ever built there: `ImportC` the two functions, or read the rows with
SQLite's API like the writer.

**Tested:** `Tests/BigMessages-Test.ps1`: an aggregate and a row-by-row
SELECT over mixed rows are refused with "malformed JSON"; non-JSON rows
read without JSON functions, `CASE WHEN is_json`, a query with really no
rows and a plain SQL error behave as before.

## Before calling it 1.0

Not smoke-test items, but what the "1.0" label would promise. From
`Notes.md`'s open items:

- ~~Clients and peers can't verify the server's identity.~~ Fixed
  (protocol 3, `Design/Cryptography.md`).
- ~~No encryption, no per-packet authentication after the handshake.~~
  Fixed (protocol 3).
- Messages aren't signed by the node that first wrote them: a peer is
  trusted with what it replicates (`Design/ReplicationIssues.md` #3).
- `synchronous = NORMAL`: the last commits can be lost on a power loss,
  decide if that's fine (`Design/StorageConcurrency.md`).

Either they're fixed, or they're documented limits of 1.0 (or it's a 0.9).

## For CI/CD

Notes for when the builds move to a pipeline.

- **Toolchain:**
  - PureBasic isn't freely downloadable: a self-hosted Windows runner with
    a licensed install, or a private image. Compiler paths are parameters
    (`Build.ps1 -Compiler`, `Release.ps1 -Compiler`), default to
    `C:\Program Files\PureBasic_573\...` and `..._640\...`.
  - Two compilers are in use: 5.73 for `Build\` and the tests, 6.40's C
    backend for releases. Decide whether CI tests the release build (it
    should, it's what ships), or both.
  - Check out with submodules (`Includes/PB-MessagePack`).
  - `Libs/` holds the libsodium and SQLite zips: pin them and check their
    hashes in the pipeline.
- **Scripts that need changes first:**
  - `Build.ps1` ends by running the server, which waits on its console:
    needs a `-NoRun` switch. It also writes private keys into `Build\`,
    which must never be published as an artifact.
  - The tests use fixed ports (12399 for the release, 12401-12414 for
    `Tests/`): parallel jobs on one runner collide, make them parameters
    or pick free ones.
  - One entry point that runs every test (`Tests/*.ps1`, the handshake
    and cipher tests) and fails if any fails. Today each is run by hand.
  - The release server needs a console, or it stops right away (no
    console input). The smoke test gives it a hidden window: check that
    works on the runner (a service account may not get a console), or do
    item 4 first.
- **Environment:**
  - Exes run from temp folders are blocked by the antivirus here, the
    tests run them from `Build\`. A runner may differ either way.
  - A clean-machine job, without the Visual C++ runtime, to catch missing
    DLLs (see above).
  - Python: 64-bit, the oldest claimed version (3.8) and the latest.
- **Versions and artifacts:**
  - Releases from tags (`v1.0.0` -> `-Version 1.0.0`), refusing a dirty tree.
  - Artifacts: the release zip, and a source zip. Not `Build\`.
- **Benchmarks** (`Tests/Bench/`): too noisy and long for every build. A
  nightly or on-demand job, compared to a stored baseline with
  `Compare-Runs.ps1`, failing only on a big drop.
- **Linux:** `Libsodium.pbi` and the writer have Linux paths, never built
  or tested. A later job, once wanted.
