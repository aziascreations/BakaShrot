# Storage: schema v9

The server's database: one SQLite file. The code is
`crates/bakashrot-storage`; the schema is
`crates/bakashrot-storage/src/schema_v9.sql`, made in one go. Decided in
`../revamp.md`, "Decided" (2026-11-13).

## In short

- **By name outside, packed integers inside.** The rest of the code (the
  server, the tools) only sees topics, nodes, message ids and times, as on
  the wire. Inside, a topic and node pair is a *stream*, and a message's
  key packs its stream and its id into one integer. Only this crate packs
  and unpacks keys; the `messages` view shows plain columns.
- **One B-tree per kind of data:** messages, attachment parts. A push
  writes its message's row and nothing else (no index): about 2.3 times
  the pushes of a layout with an index, 30% less disk (see "Measured").
- **One writer, many readers** (WAL). Writes go in batches, one
  transaction each: a group commit.

## Streams

A **stream** is one node's messages in one topic: `logs` written by
`kitchen` is one, `logs` written by `garage` another. Everything works on
them:

- message ids count per stream, from 1;
- replication compares each stream's `last_id` (`SyncState`'s heads);
- `GetMessages` reads a range of one stream.

`streams` holds each one's id (1 to 2^20 - 1), its topic and node names
(compared without case), and `last_id`: the highest id it ever had.
Deleting messages leaves `last_id`, so ids never go back. A trigger keeps
it, for pushes and replication alike.

There are no `topics` or `nodes` tables: a topic's streams are its rows in
`streams`, the names are listed from there (`Reader::topics()`,
`nodes()`), and the config adds the topics it names.

## Keys

```
data.key             = stream_id << 43 | message_id
                       [0][ stream: 20 bits ][ message id: 43 bits ]

attachment_parts.key = attachment_id << 20 | part
                       [0][ attachment: 43 bits ][ part: 20 bits ]
```

- `data.key` is the table's own key (`INTEGER PRIMARY KEY`): the messages
  are stored ordered by stream, then id. A stream's messages sit together;
  "after id 100", "the last 10" are ranges of keys, read in order. No
  other index is written when a message is stored.
- **Limits:** 1,048,575 streams per database, message ids up to
  2^43 - 1 (8,796,093,022,207) per stream: 278 years at 1,000 messages a
  second. `MAX_MESSAGE_ID` (`bakashrot-proto`) is that, so the protocol
  can't carry an id a server can't store. Past either, a push is refused
  (`TooBig`).
- **Attachment parts** the same way: 2^20 parts of 1 MiB is exactly the
  1 TiB limit, an attachment's parts are a range of keys.
- `data` also has `stream_id`, `message_id` and `is_json` as **virtual
  columns**: computed when read, never stored (a test checks the schema
  unpacks keys as the code does).

Why no index? A second B-tree to write at every push, and reads going
through the index then to the row. Measured below.

## Writing

`Database::writer()` gives the one connection that writes;
`Writer::batch(|batch| ...)` runs a closure in one transaction. Every
operation of a `Batch` is all or nothing on its own (a savepoint), so a
batch goes on after one fails: the server queues pushes and stores them
together, one disk flush for all.

Except when SQLite rolls the whole transaction back by itself, which it
may on a full disk, an I/O error or out of memory (`Batch::is_rolled_back()`).
What came after then ran outside any transaction, each operation
committed alone, while the batch failed and every write in it was
answered as failed: a retried push stored twice. Since 2026-11-19 every
operation after is refused (`Error::RolledBack`) and so is the batch:
nothing in it is stored, every write answered `ServerError`
(`nothing_runs_once_sqlite_rolled_back` in `batch.rs`, a `ROLLBACK`
standing in for SQLite's). The server's writer stops running the group
there.

| Operation | What |
|---|---|
| `push(topic, node, pushed_at, data)` | the next id of its stream, which it returns; the stream is made if new |
| `start_upload(size, sha256)`, `write_part(id, part, data)`, `push_with_attachment(id, ...)`, `cancel_upload(id)` | a push with an attachment: its parts first, then the message with it |
| `replicate(topic, node, messages, max_attachment_size, skip_before)` | a peer's messages, with their ids; ones already here are kept; ones pushed before `skip_before` (past their age here) only counted in `last_id` |
| `write_part`, `finish_replicated(id, matches)` | a replicated attachment's parts, then ready (or started over) |
| `damaged(id)` | a ready attachment found not matching its SHA-256: its parts dropped, asked for again (`replicating`) |
| `delete_before(topic, cutoff, limit)` | retention |
| `purge_attachments(max_parts)` | deleted messages' attachments |
| `Checkpointer::checkpoint()` (its own connection) | the WAL copied into the database, every second, off the writer's way |

**SHA-256s are the caller's to check:** the server hashes the parts as they
stream by, nothing is read back from the disk. A resumed replicated
attachment's first parts are read back (`Reader::read_part`) to finish its
hash.

## Reading

`Database::reader()` gives a connection that reads, as many as needed; they
read while the writer writes. Answers are the protocol's own types:

| Reader | Gives | How |
|---|---|---|
| `messages(topic, node, after, limit)` | `Messages`: after an id in order, or the last ones; about 1 MiB at most (a bigger message alone), `more` if others follow | a range of keys |
| `topics()` | the topics with messages | `streams` |
| `heads()`, `heads_after(after, limit)`, `last_id(topic, node)` | each stream's last id, all or a page after a pair (names without case): `SyncState` | `streams` (its `(topic, node)` index) |
| `to_replicate(topic, node, after, limit)` | messages after an id as replication sends them (attachments' SHA-256s), about 1 MiB at most | a range of keys |
| `missing_attachments(limit)` | replicated attachments not all here, from which part | `attachments` (index on states) |
| `attachment(topic, node, id)`, `read_part(id, part)` | an attachment, its parts | the message's key; a part's key |

A topic and node with no messages read as none, unless the node has none
in any topic: `Error::UnknownName`. A topic is never unknown: it's allowed or not, by the roles.

## Attachments

One table, a state each:

| State | Meaning | Next |
|---|---|---|
| `uploading` | a push's attachment, parts coming, no message yet (`message_key` NULL) | all parts and the SHA-256 match: the message is stored and the attachment `ready`, one transaction. Cut short: deleted with its parts (and every one left at start) |
| `replicating` | its message came from a peer with its size and SHA-256; parts come after | asked from part `received / 1 MiB` on; all came and match: `ready`, else started over (also at start, all came but not checked) |
| `ready` | all here, checked | readable |
| `too_big` | bigger than this server's `max_attachment_size` | never asked for; its message is kept |
| `deleting` | its message was deleted (a trigger) | parts deleted in batches, then the row |

Readers never see a message whose pushed attachment is missing: the
message is only stored with its complete attachment. A replicated message
can be here before its attachment: `Messages` says `ready: false`.

## Retention

`delete_before(topic, cutoff, limit)` reads each of the topic's streams from
its oldest message and stops at the first it keeps: only what it deletes is
read, nothing indexes `pushed_at`. So messages go **in id order**: one
stamped earlier than the one before it (a server's clock set back) waits for
that one. `last_id` stays. The parts of deleted messages' attachments go
afterwards, `purge_attachments(max_parts)` a batch at a time.

## The query surface

Clients' `Query` runs on `Database::query_runner()`, read-only four ways:
the file is opened read-only (`SQLITE_OPEN_READONLY`, 2026-11-19: the
handle itself can't write), the connection is `query_only`, the statement
must be one SQLite says only reads, and one statement only (more is
refused, not ignored). PRAGMAs are
refused as they're prepared ("not authorized", SQLite's authorizer), the
`pragma_*` table functions too: some take effect at that point, and
`PRAGMA query_only = 0`, though refused, turned `query_only` off for the
connection's next queries (found 2026-11-15). The result is
`{"columns":[...],"rows":[[...]]}`, every value a string or null (blobs in
hex), 10,000 rows and 16 MB at most (`TooBig`). A failing row fails it all,
with SQLite's message: never a partial result. "malformed JSON" (a JSON
function on a row that isn't) gets a hint: add
`is_json = 1` to the WHERE.

The `messages` view, by name:

| Column | |
|---|---|
| `topic`, `node` | names |
| `message_id`, `message_data`, `is_json`, `pushed_at`, `pushed_utc` | the message's |
| `attachment_size`, `attachment_state` | NULL without one |

```sql
SELECT * FROM messages WHERE topic = 'logs' AND node = 'kitchen'
SELECT message_data ->> '$.temp' FROM messages WHERE topic = 'sensors' AND is_json = 1
```

SQLite's functions are there, JSON's included; not `soundex()` nor the
`dbstat` table (left out of the build, "The file").

- **By topic, or topic and node:** ranges of the table, read in order (a
  test checks the plans).
- **Filters on `pushed_at` or `message_id`** read the streams they're in,
  whole: a millisecond or two for 10,000 messages per stream, growing with
  them (see "Measured"). If that gets slow, a time index is one migration
  away ("For later").
- `browse` / `browse_messages`: for database tools (set `browse`'s
  one row, open the view); no dropdowns any more.

## The file

- `PRAGMA application_id` = "BSHT": a BakaShrot database.
- `metadata`: `schema_version` (9), `created_at`, `created_by` (this crate
  and its version).
- **Opening** (`Database::open`): an empty file is made a v9 database; a
  v9 one is opened; an older one is migrated, a version at a time, each
  step one transaction that also sets `schema_version` (none yet); a newer
  one or another program's is refused, saying which.
- Every connection: WAL, `synchronous` from the config (`full`: every
  commit flushed; `normal`: about once a second), a 5 s busy timeout. No
  foreign keys: one writer keeps the tables consistent, `CHECK`s keep the
  values valid.
- SQLite is compiled in (`rusqlite`'s `bundled`): the same version
  everywhere, no system library. Without full-text search (FTS3, FTS5),
  R-Tree, `dbstat`, STAT4, `soundex()`, extension loading and column
  metadata, which libsqlite3-sys turns on and nothing here uses: 310 KB
  less in the server (`LIBSQLITE3_FLAGS` in `../.cargo/config.toml`; a
  test checks they're out). JSON is SQLite's own, always there.

## Measured

Python's `sqlite3` (SQLite 3.50), 5,000,000 small JSON messages pushed to
500 streams (100 topics x 5 nodes) at random, 100 per transaction, WAL,
`synchronous = NORMAL`, 16 MB page cache:

| | v9 (this) | v9 + a time index |
|---|---|---|
| Pushes/s | **23k** | 9-10k |
| File | **330 MB** | 457 MB |
| Latest 100 of a stream | 0.05 ms | 0.05 ms |
| 1000 after an id | 0.53 ms | 0.53 ms |
| Retention, 10% of a topic | 5.5 ms | 6.4 ms |
| Query: a node's last hour | 1.65 ms | 0.90 ms |
| Query: a topic's last hour | 8.4 ms | 4.7 ms |

- A push dirties its stream's page: with pushes spread over many streams,
  each costs about a page written to the WAL. Any index per stream (a
  time index) doubles that, and a bigger cache doesn't help (it's writes,
  not reads).
- Bigger batches over fewer streams share pages: the server's group commit
  helps most when many pushes come at once.

### The benchmark (2026-11-13)

`storage_rate` (`tests/storage.rs`, ignored by default:
`PUSHES=1000000 SYNC=normal cargo test --release -p bakashrot-storage --
--ignored --nocapture`, or `bench.ps1 -Only storage`): the storage layer
alone (no network), pushes over 500 streams picked at random, 100 per
transaction, 200-byte JSON; 2000 latest-message reads; 500 reads of 1000
messages after a stream's middle id; retention of 10% of one topic. NVMe,
one run each.

| | 1M | 1M `full` | 5M |
|---|---|---|---|
| Pushes/s | 37,332 | 29,952 | 29,363 |
| File | 249 MB | 249 MB | 1,239 MB |
| Latest message | 0.017 ms | 0.017 ms | 0.017 ms |
| 1000 after an id | 0.43 ms | 0.43 ms | 0.45 ms |
| Retention, 10% of a topic | 7 ms | 9 ms | 8 ms |

`normal` unless said. Most of the push speed is the writer's: checkpoints
off the push path (`Database::checkpointer()`, every second on its own
connection, the writer only checkpointing itself past 10,000 pages,
`WRITER_CHECKPOINT_PAGES`), and no savepoint around a push (a failed one
leaves at most its empty stream).

## Tests

`crates/bakashrot-storage/tests/storage.rs`, on database files in
`target/`: opening (made, reopened, an empty file), refused databases
(another program's, a newer version, no version), pushes and reads
(ids per stream, names without case, after/latest/limit/more, the 1 MiB
cut), uploads (parts in order and of their size, incomplete refused, a
failed operation not spoiling its batch, cancelled and left-over ones
deleted), replication (own ids, kept ones, attachments to ask for, too big,
started over, resumed), retention (limits, id order, heads kept, ids going
on, attachments purged in batches),
the limits (no stream, no id left, the highest key), queries (results, every write refused, failing rows, too
big), the view's plans, and readers with two writers at once. In
`src/lib.rs`: the keys, the schema unpacking them the same, the states.

## For later

- **A time index**, if time queries over big streams get slow: a v10
  migration adding an index on `(stream_id, pushed_at)` and joining the
  view on it too (measured above: twice the write cost).
- **Interrupting long queries** (a time limit): the server's, with
  SQLite's interrupt.
- **Attachments as files** next to the database instead of in it, if their
  size calls for it.
