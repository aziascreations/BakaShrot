# Storage concurrency

Status (2026-11-07): **one connection per thread, WAL mode, a write mutex,
group commit, and a single writer connection with prepared statements are
done.** Full benchmark history: `Tests/Bench/Results-2026-11-07.md`. Ideas
not done yet: `Design/Suggestions.md`.

## The writer (2026-11-07, `Server/Storage/Writer.pbi`)

- **Every write goes through one connection,** opened by
  `OpenStorageWriter()` when the workers start and closed by
  `CloseStorageWriter()` once they're stopped (`Server/Root.pbi`). It's the
  one exception to the rule below: shared, but only ever used while holding
  the write mutex, so never by two threads at once.
- **Prepared statements, kept open,** through SQLite's own API
  (`sqlite3_prepare16_v2`, `sqlite3_bind_*`, `sqlite3_step`), from the
  same `sqlite3.dll` PureBasic loads: `DatabaseID()` is its `sqlite3`
  handle. PureBasic prepares a statement again on every call. Windows only,
  elsewhere the writer falls back to PureBasic's functions.
- **The next id of every topic/node id in memory,** instead of a
  `MAX(message_id) + 1` in every insert: read from the database the first
  time, raised by replicated messages, forgotten on any rollback. Only right
  while this writer is the only one writing.
- **Checkpoints in a background thread,** every second, in PASSIVE rounds
  that don't block anything, then a short one under the write mutex once
  little is left, so the WAL can start over. The writer still checkpoints by
  itself past 10,000 WAL frames, as a backstop when the thread can't keep up
  (flat out). Without that backstop the WAL reached 700 MB and Windows
  throttled the writes, up to 5 s for a push.
- **`node_heads`,** the highest message id of every topic/node id, kept by a
  trigger on `data` (so even `BenchSeed` keeps it right). The sync state is
  read from it: 0.5 ms instead of 167 ms at 2.4M rows, on every check-in.
  Schema: `Server/Storage/db_schema_v3.dbml` (now `db_schema_v4.dbml`)`.
- **Measured:** ~25,700 -> ~34,300 msg/s for 4 servers, ~38,400 built with
  PureBasic 6.40's C backend. p99 at 10 nodes x 50 msg/s: 13.6 -> 0.8 ms.

## WAL and the write mutex (2026-11-07)

- **WAL mode,** set by `SetupStorageDatabase()` (stored in the file), with
  `synchronous = NORMAL` on every connection (`#BakaShrot_Storage_Synchronous`
  in `Storage.pbi`). Readers no longer block the writer: a 0.5 s raw query
  used to stall pushes for seconds and once made one fail with "database is
  locked", now pushes run next to it at full speed.
- **The tradeoff of NORMAL:** commits are only synced at checkpoints. The
  file can't get corrupted, but the last commits before a power loss or an
  OS crash can be lost. Those messages were acknowledged and maybe already
  replicated, so their ids could be handed out again: drift
  (`ReplicationIssues.md` #1). Set it to `FULL` to sync every commit again.
- **`BakaShrot_Storage_WriteMutex`** around every write. A connection that
  finds the database locked sleeps in SQLite's busy handler (1, 2, 5, 10...
  ms) and retries; with 10+ threads pushing, that's where the time went, and
  10 nodes per server pushed less than 5. Queued on the mutex, the next one
  writes as soon as the lock is free. The busy timeout still covers other
  processes.
- **Measured** with `Tests/Bench/Bench-Replication.ps1` (4 servers in a Y,
  ~200-byte messages, i5-13500, all on localhost), along with the wake-ups
  instead of `Delay()` polling (`ReplicationIssues.md` #6):

  | | Before | After |
  |---|---|---|
  | Cluster push ceiling, 5 / 10 nodes per server | ~955 / ~900 msg/s | ~5770 / ~5730 msg/s |
  | Push latency p50 / p99, 10 nodes x 50 msg/s | 18 / 490 ms | 0.4 / 5 ms |
  | Indexed query (latest message) | 6-12 ms | ~0.5 ms |
  | Pushes while a 0.5 s query loops | 323 of 400 msg/s, max 5.1 s, 1 failure | 396 of 400, max 17 ms |

  That ceiling turned out not to be the database, but the `PrintN()` logging
  every push (~0.4 ms each, serialized): see below.

## Group commit (2026-11-07)

- **`InsertNextMessage()`** queues the push (`BakaShrot_Storage_Queue`),
  then takes the write mutex. Whoever holds it writes every queued push in
  one transaction (up to `#BakaShrot_Storage_MaxGroupSize`), so the pushes
  that were waiting find theirs done. No extra thread: the busier it gets,
  the bigger the groups. Each push still returns once committed.
- **`[Storage]` log line** every 10 s while pushes come in: pushes/s,
  pushes per transaction, ms per push, and how busy the writes are.
- **No more log line per push, read or query** (`#BakaShrot_Net_LogRequests`
  in `Networking.pbi`): that `PrintN()` was what capped a server at ~2,400
  pushes/s.
- **Measured:** a single server ~2,400 -> ~12,000 pushes/s, the cluster of 4
  ~5,800 -> ~25,700 msg/s, 2.5-9 pushes per transaction when saturated.
  The writes are now the limit again (70-90 % busy at 0.07-0.11 ms per push).
- **Open:** p99 at moderate load went up (0.7 -> 8-18 ms). Suspect: a WAL
  checkpoint running while holding the write mutex.

## The rule

**Never share a database handle between threads.** The `SetDatabase*()`
parameters and the query results belong to a handle, so two threads using one
overwrite each other's. That used to happen: a peer link once read an empty
result while 3500 messages were left to send, see
`Design/ReplicationIssues.md`, issue 4.

Every thread that touches the database opens its own connection with
`OpenStorageDatabase()` and closes it when it ends:

| Who | Opens | Closes | Where |
|---|---|---|---|
| A client thread | once its client is authenticated | when the thread ends | `BakaShrot_NetClient_Thread()`, `Server/Networking/Networking.pbi` |
| A peer link thread | when the thread starts | when the thread ends | `BakaShrot_PeerLink_Thread()`, `Server/Networking/Peers.pbi` |
| A raw query | for the query, read-only | right after | `RunReadOnlyQuery()`, `Server/Storage/Storage.pbi` |
| The root | at start, and on restart | on restart and at the end | `Server/Root.pbi` |

The root's connection is only used for setup, and while the workers are
stopped (vacuum, restart). See `Server/Root.pbi`.

## What makes several connections work

- **Busy timeout.** Each connection sets
  `PRAGMA busy_timeout = #BakaShrot_Storage_BusyTimeout` (5000 ms), in
  `OpenStorageDatabase()`. SQLite allows one writer at a time across
  connections. Without it, a write fails at once with "database is locked"
  while another connection writes. With it, the write waits its turn.
- **Atomic next id.** `InsertNextMessage()` is a single statement:
  ```sql
  INSERT INTO data (topic_id, node_id, message_id, message_data)
  SELECT ?1, ?2, COALESCE(MAX(message_id), 0) + 1, ?3
  FROM data WHERE topic_id = ?1 AND node_id = ?2
  RETURNING message_id
  ```
  Nothing can run between reading `MAX` and inserting, even from another
  connection. The UNIQUE `(topic_id, node_id, message_id)` constraint stays
  as a safety net.
- **`BEGIN IMMEDIATE` for replicated batches** (`InsertReplicatedMessages()`).
  It takes the write lock up front, waiting for it like any write, instead
  of a deferred transaction that could fail midway when upgrading to a write
  lock.

**Tested:** 8 connections pushing 100 messages each to the same topic/node
id at once, while two servers replicated. 800 pushes in 6.2 s, no failures,
ids exactly 1-800 on both servers.

## Left for later

- **What happens when the busy timeout runs out.** The statement fails, so
  the push or batch is refused and retried at the next check-in for
  replication. Fine at current loads; decide later whether pushes should
  retry.
- **Whether PureBasic's `DatabaseError()` is per thread** in thread-safe
  mode. If it's shared by the whole program, an error message could show up
  in the wrong thread's log or refusal. The data isn't affected.
  `RunReadOnlyQuery()` only checks it after reading the rows on Linux, where
  it could refuse a valid query because of another thread's error. On
  Windows it asks SQLite instead (`sqlite3_errcode()` on its own
  connection), see `Design/Release.md`.
- **A single storage thread with a job queue,** only if writes ever become
  the bottleneck. SQLite only has one writer anyway.
