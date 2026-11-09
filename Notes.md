# BakaShrot - working notes

Where things stand and what's next, as of 2026-11-09. A new session: read
`CLAUDE.md` first (how to build, test, and the traps), then "Right now" and
"Open items" below. The detailed docs are in `Design/`:

| Doc | About |
|---|---|
| `Design/Packets.md` | The protocol: framing, every packet, flows, conventions, how to add a packet. |
| `Design/Attachments.md` | Attachments: one per message, in 1 MB parts, uploaded before the message, replicated after it. |
| `Design/Cryptography.md` | What libsodium is used for: the handshake proving both ends, the connections' encryption. What isn't done, and ideas for abstracting it. |
| `Design/ReplicationIssues.md` | Known replication problems, with benchmarks. |
| `Design/StorageConcurrency.md` | One connection per thread, WAL, the write mutex and the writer (done), and what's left. |
| `Design/Suggestions.md` | Improvements not done yet: pipelined pushes, faster replication, smaller ones. |
| `Design/Release.md` | The release smoke test, what's missing for 1.0.0, the (fixed) silent query failure, notes for CI/CD. |

## Right now (2026-11-09)

- **Nothing since `df61ef9` is committed**, on `timestamps-retention`: the
  tool renames, protocols 5 and 6 (node identities, error codes), names-only
  configs, `Synchronous`, schema v8 (`browse`), `Examples/`,
  `Restart-Test.ps1`. Every suite passes on it (8, see `CLAUDE.md`), it
  compiles with 5.73 and 6.40, the push bench gives ~17,000 msg/s for 4
  servers with `Synchronous = FULL`.
- **`Release\20261109-df61ef9-dirty\` is out of date** (before
  `Synchronous`, `browse` and the error codes): commit, then
  `Release.ps1` again.
- **Suggested next** (not decided by the owner): the server without a
  console (item 1), then whatever the real-world test shows. The run on a
  clean Windows is the owner's, not an item here.

## Where things stand

- **Build:** `powershell -ExecutionPolicy Bypass -File Build.ps1`
  - Extracts libsodium and SQLite from `Libs/`, builds everything with
    PureBasic 5.73 (`-Compiler` for another) into `Build/`, and generates
    keys and configs for two servers (same names, different ids) and a
    client.
  - Then runs the first server. Its console takes `quit`, `restart`,
    `vacuum`, `names` and `help`.
- **Server:**
  - Every connection is encrypted, and both ends prove who they are: the
    client with an Ed25519 challenge, the server by signing the handshake
    with the key its clients know (since protocol 3, `Design/Cryptography.md`;
    the protocol is at 6: attachments in 4, node-only identities in 5,
    refusal codes in 6).
  - A client authenticates as a node (`[BakaShrot.Client.<name>] Node`,
    one per section, a key may be in several); its pushes go to that
    section's `DefaultTopic` unless they name one.
  - Topics are listed by name (`[BakaShrot.Topics]`), the server gives the
    ids and keeps them; nodes come from the sections that use them,
    `[BakaShrot.Nodes]` is optional, peers' nodes are taken as they come
    (`AcceptNodes = *` by default).
  - `[BakaShrot.Server] Synchronous = FULL` (default, every acknowledged
    push on disk) or `NORMAL` (faster, a power loss can lose the last
    second).
  - Clients can push messages (usually JSON, anything is stored, flagged
    in `is_json`), read the latest one of a topic/node pair or a run of
    them after an id, resolve names, and run raw read-only SQL, each depending on
    per-client `AllowRead`, `AllowWrite`, `AllowQuery`, `PushTopics` and
    `ReadTopics`. Topics and nodes by name or id, see below.
  - Links to its peers, retries when that fails, and replicates the missing
    messages in batches (`PeerBatchSize`).
  - Stamps every push with the time it arrived (`pushed_at`, UTC ms), which
    replication carries as is, and deletes each topic's messages past its
    max age (`[BakaShrot.Retention]`, per server).
  - A message can have one attachment of any size up to `MaxAttachmentSize`
    (default 1G), sent in 1 MB parts, replicated after its message
    (`Design/Attachments.md`).
  - One thread per client and per peer, each with its own SQLite connection.
  - The root thread can stop every worker (restart, vacuum).
- **Errors:** every refusal carries a code, every client failure too
  (`Client/BakaShrot_ErrorCodes.pbi`): `BakaShrot_GetLastError()` in the
  DLL, `error.code` in Python, the name in the tools' messages. Nothing
  reconnects by itself; delivery is at least once.
- **Database tools:** the `messages` view (by names), and `browse` /
  `browse_messages` to pick a topic from a dropdown in SQLiteStudio.
- **Example:** `Examples/SingleServer/`, a server and a client with scripts
  (its keys committed on purpose, public).
- **Client:** a DLL with A/W string exports, PureBasic prototypes in
  `Client/BakaShrot_Client_Prototypes.pbi`, and tools in `Tools/`:
  `BakaShrotPushMessage` (`-a` to attach a file),
  `BakaShrotGetLatestMessage`, `BakaShrotGetMessages` (with `--follow`),
  `BakaShrotGetAttachment`, `BakaShrotResolveIds`, `BakaShrotList`,
  `BakaShrotQuery`, `BakaShrotGenerateKeyPairs`.
- **Python:** `Interactors/Python/bakashrot.py`, over the DLL with ctypes,
  no dependencies, and `example.py`.
- **Release:** `Release.ps1` builds with PB 6.40's C backend into
  `Release\<date>-<commit>\` with a zip, and smoke-tests it.

## Renamed: group id -> topic id (2026-11-07)

- Everywhere: code (`TopicId`, `ReplicatingTopicIds`, `IsReplicatingTopic`,
  ...), config keys (`TopicId =`, `ReplicatingTopicIds =`), the DLL export
  (`BakaShrot_SetTopicId`), the columns (`topic_id`), docs, bench
  placeholders (`{TOPIC}`). Not "group commit", `PreferenceGroup*` or SQL
  `GROUP BY`. The wire format is unchanged (fields are positional).
- **Old configs need their keys renamed** by hand, `GroupId` is no longer
  read. Build.ps1 writes the new ones.
- **Old databases are migrated on start** (`MigrateStorageTopicIds()` in
  `Storage.pbi`, schema `db_schema_v4.dbml`). Tested on a v2 and a v3
  database, and two servers replicating after both were migrated.

## Done: topic and node names, filters (2026-11-07)

- **Names are the shared identity, ids are per server.** `[BakaShrot.Topics]`
  and `[BakaShrot.Nodes]` (`logs = 1`): "logs" can be 1 here and 200 on a
  peer. Replication sends names, the receiver stores under its own ids.
  Kept on purpose even though using the same ids everywhere would be
  simpler: hand-written configs drift, names keep them matching anyway.
  Rules for a "ref" (name or id): `Commons/Networking/Names.pbi`.
- **Only what's named on both servers replicates.** Unnamed topics and
  nodes, and names the other side doesn't have, are dropped. The sync
  state of every check-in lists every name the receiver takes from that
  peer, and its wildcards, and the sender only sends those: no refusal at
  every check-in. Unnamed ones still work locally, by id.
- **Wildcards (2026-11-07),** like file names: `*` any characters, `?` one,
  no case, only names (`Commons/Networking/Names.pbi`). In every topic list
  (`ReplicatingTopics`, `SendTopics`, `AcceptTopics`, `PushTopics`,
  `ReadTopics`) and in the peers' new node lists `SendNodes` (default `*`)
  and `AcceptNodes` (default: the nodes named here). In `AcceptTopics` /
  `AcceptNodes`, `*` and wildcards also take names this server doesn't have
  (`BakaShrot_Names_Ingest()`): highest free id counting down from 65535,
  origin "peer". So `AcceptNodes = kitchen-*` saves listing every kitchen
  node on every server. Clients still can't create topics by name.
- **A peer authenticates by name:** its own node must be named the same
  on the servers it links to (it sends its name when it has one). It sent
  a topic too before protocol 5.
- **Everywhere a topic or node goes, a name or an id:** config, the Hello,
  requests, tools, client.ini. Keys: `Topic`, `Node`, `ReplicatingTopics`
  (`TopicId`, `NodeId`, `ReplicatingTopicIds` still read when the new ones
  are missing, in server configs and client.ini).
- **Filters:** per client `PushTopics` / `ReadTopics` (default: its
  identities' topics, as before), per peer `SendTopics` / `AcceptTopics`
  (default: `ReplicatingTopics`). `*` = every topic. A push picks its topic
  (`BakaShrotPushMessage -t sensors`), never its node.
- **The config wins at start,** except when it would move a name to another
  id than the one its messages are under: the server then refuses to start
  and says which id to use (`Server/Storage/Names.pbi`).
- **Seeing the names:** the server's `names` console command, the
  `BakaShrotList` tool (`BakaShrot_ListTopics/Nodes()` + `BakaShrot_GetNamesList()`
  as JSON, request `ListNames`), `BakaShrotResolveIds` for one.
- **Clients:** `BakaShrot_ResolveTopic/Node()`, `BakaShrot_PushMessageTo()`,
  `BakaShrot_GetLatestMessageOf()`, the answer's names and ids. Raw
  queries: `SELECT * FROM messages WHERE topic = 'logs' AND node =
  'kitchen'` (a view over `data` with `topics` and `nodes`, uses the
  indexes). No foreign keys from `data`, see the evaluation below.
- **Protocol version 2:** v1 servers and clients can't talk to v2 ones.
- **Tested:** `Tests/Names-Test.ps1`, 44 checks: two servers with different
  ids for the same names, old and new keys, filters, resolving, listing,
  translation both ways, a node and a topic named on one side only, an
  unnamed node, wildcards taking a topic and a node, a `SendNodes` filter,
  no refusals in the logs, the start-up conflict.
  Bench: `-Names Wildcard` (each server names only its own nodes, the
  others come by `AcceptNodes = n*`), results in
  `Tests/Bench/Results-2026-11-07.md`.
  Release.ps1 on PB 6.40. Bench (every node named on every server): ~37,000
  msg/s flat out for 4 servers, p99 0.9 ms at 10 x 50.
- **For later:**
  - **Warn about dropped names.** `BakaShrot_Names_NoteDropped()` is called
    wherever something isn't replicated because one side doesn't know it
    (unnamed here, not taken by the peer, unknown to the peer, refused
    on arrival), but does nothing: it runs at every check-in, so a plain
    log line would spam. Make it warn once per peer and name, and again
    only when that changes.
  - **Two conventions for "unnamed":** `NameResolved` and `NamesList` give
    "" (with origin "id"), `LatestMessage` gives the id in digits. Still
    the case: both work, but pick one if more answers carry names.
  - Names stay in the database once given: removing one from the config
    keeps it (origin stays "config") until renamed.
  - The sync state lists every named node the receiver takes from that
    peer, every check-in (all of them by default): fine for thousands, a
    lot for tens of thousands (65536 at most, and the whole list every
    check-in). Wildcards help,
    since a node taken by `AcceptNodes = kitchen-*` needn't be named first,
    but once taken it has a name and is listed too.
  - Names a wildcard added (origin "peer") are never removed, even if the
    peer stops sending them or the wildcard goes away.

Evaluation that led to it: enforced foreign keys from `data` cost ~1 % per
insert, but an unknown id would fail a whole replicated batch
(`INSERT OR IGNORE` doesn't skip FK violations), and adding them to an
existing `data` means rebuilding the table. So: name tables, joined, no FKs.

## Done: big messages (2026-11-08)

- **Packets up to 16 MB once authenticated** (`#BakaShrot_MaxPacketSize`),
  4 KB before (`#BakaShrot_MaxHandshakePacketSize`): a frame announcing more
  is cut as soon as its size arrived, so anyone can connect but only those
  with a key get to make the other end hold big frames. The server lifts
  the limit (`BakaShrot_Inbox_Lift()`) before sending AuthAccepted, the
  client once it got it. Same protocol version: only the limit changed.
- **Pushes are capped at `#BakaShrot_MaxMessageSize`** (16 MB - 4 KB) of
  UTF-8, refused above (the DLL refuses it before sending), so a
  stored message fits in every packet that carries it: LatestMessage, a
  replicated batch of one. The "too big to replicate" stop can't happen
  anymore.
- **The inbox** grows by doubling, keeps a read offset instead of moving
  what's left after every packet (pipelined small packets in a 32 MB inbox
  would have moved megabytes each, under the server's mutex), and frees
  its buffer once emptied if it's 256 KB or more.
- **Replication batches stay ~64 KB** (`#BakaShrot_ReplicateBatchBytes`), as
  before, a bigger message goes alone, and reading rows stops at that much.
- **Pushes aren't checked to be JSON anymore:** stored as they are, and
  SQLite flags them in `is_json` (`json_valid()` on insert), like replicated
  ones always were. PureBasic's `ParseJSON()` was the only thing that looked
  inside messages, and took 23 s for 16 MB. Queries using `->>` on messages
  that may not be JSON need `WHERE is_json = 1` (the bench queries, the
  release test and `GetValuesAtJsonPath()` have it): SQLite's JSON functions
  fail the whole query on a malformed row. That failure used to be silent
  (no rows, or only the first ones), it's refused with SQLite's message now:
  see open item 5 and `Design/Release.md`. `ReadString()` with
  `#PB_File_IgnoreEOL` too (6 s), the tools read files in one go now
  (`ToolClient_ReadTextFile()`).
- **Tested:** `Tests/BigMessages-Test.ps1`, 38 checks: frames over 4 KB cut
  before authenticating, pushes of 100 KB / 1 MB / just under the cap (0.7
  s), over it refused, non-JSON stored with is_json = 0 (10 edge cases), replicated intact to the
  other server, a 16 MB read back from it (0.5 s), small ones still
  batched. `Names-Test.ps1` and the handshake test still pass.
- **Left:** attachments for real files, if more than 16 MB is ever needed:
  done since, see `Design/Attachments.md`. Memory: an authenticated connection can hold
  up to ~32 MB of inbox (64 MB in the worst case of the growth), plus the
  packet being handled.

## Done: reading runs of messages, Python client (2026-11-08)

- **GetMessages / Messages** (packet types 22, 23, `Design/Packets.md`): the
  messages of a topic/node after an id, in id order, at most `Limit`
  (1-10000), stopped at ~1 MB (`#BakaShrot_MessagesBatchBytes`, a bigger
  one alone), with `More` when others follow. Same permissions as
  GetLatestMessage. No messages isn't a refusal. Same protocol version: an
  older server aborts the connection on it (unexpected packet).
- **Server:** `BakaShrot_NetClient_HandleGetMessages()`. `GetMessagesAfter()`
  (`Storage.pbi`) asks for one row more than the limit and tells whether
  more follow (`*More`, optional, the peers don't use it).
- **DLL:** `BakaShrot_GetMessagesA/W(Topic, Node, AfterMessageId, Limit)`
  returns how many came (-1 on failure), the first one selected;
  `BakaShrot_SelectMessage(Index)` selects the others for the existing
  `BakaShrot_GetMessage*()` getters, `BakaShrot_GetMessageCount()`,
  `BakaShrot_HasMoreMessages()`. GetLatestMessage fills the same list (one
  message). The DLL checks the answer is about what it asked, no more than
  asked, after the asked id.
- **Tool:** `BakaShrotGetMessages <Topic> <Node> [--after <Id|latest>]
  [--limit <N>] [--follow] [--interval <Ms>] [ClientIni]`: one line per message, id, tab,
  data as stored. `--follow` polls every 500 ms once caught up, exits 1 when
  the connection fails. Polling, not pushed by the server: fine for a few
  followers, a subscription would be the next step if many follow.
- **Python** (`Interactors/Python/bakashrot.py`): `Client(...)` or
  `Client.from_ini()`, `push()` (a str as is, anything else as JSON),
  `latest()` (None if none), `get_messages()` -> page with `.more`,
  `iter_messages()`, `follow()`, `resolve_topic/node()`, `list_topics/nodes()`,
  `query()` / `query_raw()`. `RefusedError` (still connected) vs
  `ConnectionLostError`. Uses the DLL's UTF-8 exports, a lock serializes
  calls. **One connection per process** (the DLL's globals): a second
  Client can't connect while one is. ~9,600 pushes/s on one connection,
  against ~75/s launching `BakaShrotPushMessage.exe` each time.
- **Released:** `BakaShrotGetMessages.exe` and `python\` (bakashrot.py, example.py),
  the smoke test reads both messages back with the tool and with Python
  (if `python` is on the PATH).
- **Tested:** `Tests/GetMessages-Test.ps1` (27 checks: limits, after an id /
  latest, by ids, refusals, non-JSON and multi-line data, 600 KB / 3 MB
  ones split over answers, `--follow` picking up new pushes and failing
  when the server stops), `Tests/Python-Test.ps1` (32 checks, through
  `check_bakashrot.py`: pages and `more`, iteration, Unicode, empty and
  non-JSON data, is_json, 700 KB ones one per answer, refusals keep the
  connection, follow() from another thread, one connection per process).
  `BigMessages-Test.ps1`'s raw-frame check now accepts "too much data" as
  well as "invalid frame" (which one is down to timing, both cut it right
  away), from unauthenticated clients only.
- **Left:** a reconnect in `--follow` and `follow()`; server-pushed
  subscriptions instead of polling; several connections per process (a
  handle-based DLL API); reading back a range in reverse (the last N).

## Done: encrypted connections, the server proves itself (2026-11-08)

- **Protocol version 3:** the Hello is sealed for the server's public key,
  each connection gets its own keys from an exchange both ends sign, and
  everything after the ChallengeRequest is encrypted. v2 clients and
  servers can't talk to v3 ones. Details: `Design/Cryptography.md`.
- **Every client needs the server's public key:** `client.ini`'s
  `ServerPublicKey` (`Build.ps1` and `Release.ps1` already wrote it),
  `BakaShrot_SetServerPublicKey()` in the DLL, `server_public_key` in
  `bakashrot.py` (third argument of `Client()`). The server logs it when it
  starts. A peer section's `PublicKey` is now required: it's who the link
  must reach.
- **Code:** `Commons/Cryptography/Session.pbi` (sealed Hello, key exchange),
  `Cipher.pbi` (unchanged but for `_EncryptTo()`), the handshake in
  `Connections.pbi`, `Outbound.pbi` and `Networking.pbi`. Encrypting is in
  the framing (`BakaShrot_SendPacket()` takes the cipher,
  `BakaShrot_OpenFrame()`), the request handlers didn't change.
- **Tested:** `Tests/CipherTest.pb` 56 checks, `Tests/wire_check.py` (in
  `Python-Test.ps1`) through a recording proxy, every other test and the
  release's smoke test over encrypted connections, peer links included.
- **Left:** see `Design/Cryptography.md`'s "What's NOT done": per-message
  signatures for replication, keys in plain-text inis, rotation.

## State on 2026-11-08: good, mid, bad

As judged for the threat model below (internal tool, trusted machines).

**Good**
- The core works and is tested end to end: push, latest, runs of messages
  and `--follow`, names and ids, filters and wildcards, raw read-only SQL,
  per-client permissions, retention, attachments; eight `Tests/*.ps1`
  suites, two `.pb` tests, the release's smoke test (PB 6.40 C), all
  passing (see `CLAUDE.md` for the list).
- Fast: ~40,800 msg/s pushed across 4 servers (10 nodes each, PB 5.73),
  fully replicated; ~9,000 msg/s from one Python connection.
- Replication by name, each server with its own ids; restart catch-up is
  designed in (nothing it needs lives only in memory).
- Security beyond what's needed here: encrypted connections, both ends
  proven, peer links verified.
- Data: 16 MB messages, anything stored (`is_json`), errors of queries
  surfaced; pushed times; retention per topic and server; one attachment
  per message, any size, flat memory (512 MB with the server at 15 MB).
- Clients: DLL for any language, CLI tools, dependency-free Python.
- Packaging (runtime included) and docs that match the code.

**Mid**
- Replication: gaps aren't detected; two servers writing the same
  topic/node pair can drift (fine with one writer per pair, a rule to
  state); the sync state must fit in one packet.
- `synchronous = NORMAL`: a power loss can lose the last commits (a killed
  process loses nothing committed). Often fine internally, to decide.
- Client: one connection per process, `--follow` polls, no reconnect.
- Tests run by hand, on fixed ports, no runner, no CI.
- Linux untested; keys in plain-text inis (file permissions are enough
  here).

**Bad**
- The server can't run unattended: it needs a console, stops at once
  without one, can't be stopped cleanly from a script, so no service. The
  main blocker for deploying it.
- Never run from the extracted zip, on a clean Windows, nor with two
  release servers, nor restarted after a kill: designed to work, unchecked.
- A corrupted stored attachment is re-sent to peers forever (open item 3).

Commits (at this writing, check `git log`): `master` has everything up to
protocol 3 (`12fbe5f`); branch `timestamps-retention` adds timestamps and
retention (`9caf816`); attachments and their tests were left uncommitted on
that branch, waiting for the owner to ask.

Suggested order: a stop file and running as a service; smoke-test items
1-3 (`Design/Release.md`); the corrupted-attachment fix; a single test
runner, then CI.

## Done: pushed times, retention (2026-11-08)

- **`pushed_at`:** every message has the time it was pushed, in
  milliseconds since 1970 UTC, set by the server it was pushed to when the
  push arrived (its clock), and kept as is on every server it's replicated
  to (`ReplicateMessages` carries it). Clients get it in `LatestMessage`
  and `Messages`: `BakaShrot_GetMessagePushedAt()` in the DLL,
  `Message.pushed_at` / `.pushed` (a UTC datetime) in Python,
  `BakaShrotGetMessages --time`, and `BakaShrotGetLatestMessage` shows it. In SQL:
  `data.pushed_at`, and `pushed_at` / `pushed_utc` (text) in the
  `messages` view.
- **Upgrade:** a database from before gets the column, every message
  stamped with the time of the upgrade (their real time is unknown), so a
  max age counts from then for them (schema v6, `db_schema_v6.dbml`).
- **Protocol:** folded into version 3 (not released yet, like the
  encryption); a v3 build from before today can't talk to this one.
- **Retention:** `[BakaShrot.Retention]` in each server's config,
  `topic = age` by name or id, pattern (`sensors.* = 12h`), or `*`; ages
  like `30d`, `1d12h`, `forever`. Every `RetentionInterval` seconds
  (`[BakaShrot.Server]`, default 60), `Server/Storage/Retention.pbi`
  deletes what was pushed before now minus the age, 5000 at a time through
  the writer, so pushes go on. Each server applies its own: a peer keeps
  its copies by its own rules. An age without a unit refuses to start.
- **What deleting keeps:** `node_heads`, so ids never go back (the writer's
  next id now comes from it), and peers aren't sent again what a server
  deleted.
- **Skipped on arrival:** what a peer replicates already past this
  server's max age for the topic isn't stored, but its head still goes up
  to it, so the peer doesn't send it again (`InsertReplicatedMessages()`'s
  `SkipBeforeMs`). Each peer's thread has its own copy of the rules. The file doesn't shrink, SQLite reuses the space; `vacuum`
  gives it back.
- **Cost:** a column and a `(topic_id, pushed_at)` index entry per message;
  no slowdown measured (40,817 msg/s for 4 servers, PB 5.73,
  `Tests/Bench/Bench-Replication.ps1 -Ramp 10x0 -Parts Ramp`).
- **Tested:** `Tests/Retention-Test.ps1` (52 checks, ports 12408-12409):
  the upgrade of an old database (needs Python), stamps within the push's
  time, `--time`, the same `pushed_at` on both servers, deleting by name,
  pattern and `*` on one server only, ids going on after it, nothing sent
  again, skipped on arrival (B started late: its head goes up, nothing
  stored, nothing sent again), the bad age refused. Python checks
  `pushed_at` too.
- **By topic only, on purpose:** no per-node max age.
- **Removed:** the `archives` table, a leftover of the first schemas that
  nothing ever used, dropped from existing databases at start.

## Done: attachments (2026-11-08)

- **One per message**, optional: bytes of any size up to the server's
  `MaxAttachmentSize` (default 1G, at most 1T), no name or type (the JSON
  says what it is), a size and a SHA-256. Protocol version 4, schema v7.
- **Pushing:** uploaded first in 1 MB parts (UploadStart, UploadChunk), the
  server checks the SHA-256, then the PushMessage carries the upload's id:
  the message and its attachment are stored in the same transaction, so
  readers never see one without the other. Uploads not pushed within
  `UploadTimeout` (default 3600 s) are deleted.
- **Reading:** a part per request (GetAttachment), checked by the client.
  Messages tell `AttachmentSize` and `AttachmentReady`.
- **Replication:** separate from the messages, after them: the message
  carries the size and SHA-256, then at each check-in the peer lists what
  it's missing (MissingAttachments), the sender sends the parts, from where
  the peer stopped. Over the receiver's `MaxAttachmentSize`: the message
  comes, the attachment is marked not kept and never asked for.
- **Deleted with its message** (retention): triggers mark the data, the
  retention thread deletes its parts 32 at a time. It now always runs.
- **Clients:** DLL `BakaShrot_PushMessageWithFile/WithData()`,
  `_SaveAttachment()`, `_LoadAttachment()` + `_GetAttachmentData()`,
  `_GetMessageAttachmentSize()`, `_IsMessageAttachmentReady()`; Python
  `push(..., attachment=bytes or path)`, `get_attachment()`,
  `save_attachment()`, `Message.attachment_size/_ready`; tools
  `BakaShrotPushMessage -a`, `BakaShrotGetAttachment`.
- **Measured:** 512 MB up in 8.5 s, down in 3.9 s, identical, the server
  peaking at 15 MB of memory. The push benchmark isn't affected (messages
  without attachments only gain a LEFT JOIN on reads).
- **Tested:** `Tests/Attachments-Test.ps1` (39 checks, ports 12410-12411),
  Python's checks (55 in all now); every other suite still passes.
- **Edge cases tested:** `Tests/AttachmentEdges-Test.ps1` (51 checks, a raw
  protocol client): wrong SHA-256, parts out of order / wrong size /
  repeated, others' uploads, wrong topic, attached twice, too big, uploads
  expiring past `UploadTimeout`, replication resuming after the receiver
  was killed mid-transfer, a corrupted stored copy. All hold.
- **Found:** a server whose own copy is corrupted re-sends it to its peers
  at every check-in, forever, and serves it to clients (who refuse it).
  Not fixed: open item 3 below has the details and the proposed fix.
- **Left:** resuming an upload after a dropped connection (replication
  does resume); several parts in flight for high-latency links.
  See `Design/Attachments.md`.

## Renamed: the tools (2026-11-08)

Every tool is prefixed with `BakaShrot` (no `_`, the server keeps
`BakaShrot_Server`), folder, source and exe alike, three renamed too:

| Before | Now |
|---|---|
| KeyGen | BakaShrotGenerateKeyPairs |
| ListNames | BakaShrotList |
| Resolve | BakaShrotResolveIds |
| PushMessage, GetLatestMessage, GetMessages, GetAttachment, Query | BakaShrotPushMessage, BakaShrotGetLatestMessage, ... |

The packets and DLL functions keep their names (`ListNames`,
`GetMessages`, `BakaShrot_ResolveTopic()`...). Older sections below
still say the old names where they tell what was done then.

## Done: tools wait for Enter when started from Explorer (2026-11-08)

- **Every tool** ends through `ToolConsole_End()` (`Tools/Common/ToolConsole.pbi`,
  included by `ToolClient.pbi`, and by BakaShrotGenerateKeyPairs directly): started directly
  (a double-click, a shortcut), it prints "Press Enter to close..." and
  waits, so what it printed (the usage, BakaShrotGenerateKeyPairs' keys) can be read before
  its console closes.
- **Started directly** = alone on its console (`GetConsoleProcessList`, as
  [PB-Template-Win32-CliApp](https://github.com/aziascreations/PB-Template-Win32-CliApp)
  does it) **and** its input and output are a console: a redirected tool
  never waits, even alone on a new hidden console (the `--follow` test's
  `Start-Process -WindowStyle Hidden -RedirectStandardOutput`). Never
  waits outside of Windows.
- **Checked:** from a shell, from Python's `subprocess`, hidden and
  redirected: no wait; `Start-Process` in a new window: waits. Every suite
  still passes; compiles with 5.73 and 6.40.

## Done: error codes, protocol 6 (2026-11-09)

- **Every failure has a code**, in `Client/BakaShrot_ErrorCodes.pbi`
  (shipped next to the prototypes, which include it), with what to do about
  each in its header:
  - 1-99, sent by the server with each refusal (`RequestRefused` got a
    `Code`, protocol 5 -> 6): NotAllowed, UnknownName, NotFound, NotReady,
    TooBig, NoDefaultTopic, InvalidRequest, DataMismatch, QueryFailed,
    ServerError. Each of the server's 64 refusals has one.
  - 100+, the client's own: NotConnected, ConnectFailed, AuthRejected,
    ServerNotVerified, ConnectionLost, ProtocolError, InvalidArgument,
    FileError, AttachmentMismatch, AlreadyConnected, Internal. The
    handshake (`Outbound.pbi`) tells where it failed: unreachable, closed
    by the server (wrong ServerPublicKey, key or node not allowed, another
    version), the server's signature wrong.
- **DLL:** `BakaShrot_GetLastError()` after any call that can fail (0 when
  it succeeded); `BakaShrot_ErrorName()` names a code. Set where it
  happens (`BakaShrot_Fail()`), the lost connection, refusals and
  unexpected answers in one place each.
- **Python:** `ErrorCode` (IntEnum, the same numbers), `error.code` on every
  exception; `RefusedError` (1-99), `ConnectionLostError` (not connected,
  unreachable, lost, protocol error: connect again), the new `AuthError`
  (rejected or unverified: fix the config). `latest()` tells "no message"
  by its code, not its text.
- **Tools:** failures print the code's name, "Refused by the server
  (UnknownName): Unknown topic 'nope'", "Failed to connect and
  authenticate to host:port (AuthRejected): ..."; exit codes unchanged (1).
  `BakaShrotGetMessages --after latest` only starts from the start on
  NotFound, any other refusal is told.
- **Nothing reconnects by itself**, decided: apps act on the codes. A push
  whose answer was lost may be stored twice if retried: at least once,
  accepted (11b).
- **Tested:** the Python client's checks (UNKNOWN_NAME, NOT_FOUND,
  NOT_ALLOWED, QUERY_FAILED, INVALID_ARGUMENT, FILE_ERROR,
  ALREADY_CONNECTED, NOT_CONNECTED, CONNECT_FAILED, AUTH_REJECTED),
  `Names-Test.ps1` (the tools' code names), `Restart-Test.ps1` (a killed
  server gives the pushers CONNECTION_LOST).

## Done: restart catch-up tested (2026-11-09)

- **`Tests/Restart-Test.ps1`** (15 checks, ports 12415-12416, 26 s): two
  servers, a client node pushing on each through `Tests/restart_pusher.py`
  (as fast as answers come, logging every acknowledged id), servers killed
  with `Stop-Process -Force` (TerminateProcess, like a crash):
  1. B killed while both push, A goes on alone for 3 s, B restarted.
  2. B killed again partway through catching up (9,376 -> 10,806 of 22,064
     kitchen messages when killed), restarted.
  3. A killed while both push (the other direction), restarted.
- **All hold:** every acknowledged push survived, ids 1..n without a gap
  on both servers, the last acknowledged message is the one pushed, the
  next push gets the next id, and both servers end with the same messages
  (counts, ids, data and pushed_at sums equal), each catching up on what
  the other got meanwhile. The logs show nothing but the links lost and
  retried while a server was down.
- **Found:** a push committed but not answered before the kill (#26272
  stored, #26271 the last answered): a client retrying it stores it twice
  (open item 11b).
- With `Synchronous = FULL`, the default; a killed process loses nothing
  committed with `NORMAL` either (only a power loss or an OS crash would).

## Done: browsing a topic from a database tool, schema v8 (2026-11-09)

- **A view can't take a parameter**, and SQLiteStudio has no dropdown for
  one. It does show a dropdown for a column with a foreign key (its
  `FkComboBox`, in the installed copy), so:
- **`browse`**: one row (`id = 1`), `topic` referencing `topics(name)` and
  `node` referencing `nodes(name)` (NULL: every node). Set them from the
  dropdowns, commit, open **`browse_messages`**: that topic's messages,
  newest first, with `node`, `message_id`, `pushed_utc`, `message_data`,
  `is_json`, `attachment_size`. Index searches all the way (by name, then
  `(topic_id, pushed_at)`).
- **The server never writes `browse`** nor turns foreign keys on, so the
  references never get in its way; a topic renamed in the config only
  leaves a stale name there. Made by `SetupStorageDatabase()`, so every
  database gets them at its next start (`db_schema_v8.dbml`).
- **Writing to it while the server runs** is a short write next to the
  server's (it waits up to its 5 s busy timeout). A database tool left
  open on a table holds a read snapshot, which keeps checkpoints from
  finishing: the WAL grows until it's closed.
- **Tested:** `Names-Test.ps1` sets it with Python's `sqlite3` (foreign
  keys on, like SQLiteStudio): a topic lists its messages, a node narrows
  them, a name that isn't a topic is refused. Not tested by hand in
  SQLiteStudio itself.

## Done: Synchronous, FULL by default (2026-11-09)

- **`[BakaShrot.Server] Synchronous`**: `FULL` (default, every commit
  flushed: an acknowledged push survives a power loss) or `NORMAL`
  (flushed at checkpoints, about every second: faster, but a power loss
  can lose the last second and hand its ids out again). `OFF` and `EXTRA`
  are refused, saying why. The server logs it ("ready (synchronous FULL)").
- **Measured** (`Design/StorageConcurrency.md`): `FULL` halves the push
  ceiling here (17,200 msg/s for 4 servers instead of 33,900), a single
  sequential client gets ~1/flush pushes/s (1,300/s on this VM's 0.6 ms
  flush), and a steady load only gets ~0.7 ms more per push.
- **The bench takes `-Synchronous`** (`FULL` by default, like the server),
  `-Synchronous NORMAL` to compare with the numbers from before.
- **Before:** the release smoke test passed on the release built with
  protocol 5 and names-only configs, and the example ran from its
  extracted zip (2026-11-09). Not done: a run on a clean Windows.
- **Tested:** `Names-Test.ps1` checks the C server starts with `NORMAL`
  and logs it, and that `OFF` is refused; every suite passes with the
  `FULL` default.

## Done: the server picks the ids, nodes come from their sections (2026-11-08)

- **`[BakaShrot.Topics]` is a list of names**, one per line. The server
  gives each its id: the one its database already has for the name, else
  the lowest free one (`AssignConfigId()`, `Config.pbi`), so the order
  doesn't matter and ids never move. `name = id` still pins one: every
  existing config works as it is (the tests and `Build.ps1` keep their
  pinned ids, they check the translation between servers).
- **`[BakaShrot.Nodes]` is optional:** `[BakaShrot] Node`, every peer's and
  client's `Node` name their node by themselves (`DeclareConfigNode()`),
  before any node list is read. List only the others to know by name.
- **The root reads the database's names before the config**
  (`BakaShrot_Names_ReadKnown()`, `Root.pbi`), from `DatabasePath` read
  ahead. `BakaShrot_Names_Load()` then reconciles as before.
- **A peer's `AcceptNodes` defaults to `*`** (was: the named ones only):
  other servers' clients come as they come, under ids of this server's
  counting down from 65535. `AcceptNodes` still narrows it per peer.
- **Found: the Preferences library misreads LF files** with keys without
  `=`: it takes the next line for the value, a section header too, losing
  that whole section. The config is now opened through a CRLF copy in the
  temporary folder when it has LF line endings (`OpenConfigPreferences()`),
  deleted once read.
- **Tested:** `Names-Test.ps1` (55 checks): two servers with names-only
  topics and no nodes listed (C's in an LF file), ids in order, the nodes
  from the sections, D taking a node it never named, C restarted with its
  topics reordered and a new one: same ids. Every suite and the push bench
  (35,600 msg/s) pass; compiles with 5.73 and 6.40. The example's
  `server.ini` lists names only.

## Done: protocol 5, a client's node and default topic apart (2026-11-08)

- **Client sections** (`[BakaShrot.Client.<name>]`): `Node` (required, the
  node that key writes as) and `DefaultTopic` (optional, where its pushes
  go when they don't name a topic) instead of `Identities = Topic:Node;...`.
  `PushTopics` / `ReadTopics` default to `DefaultTopic`, nothing without
  one. A key that writes as several nodes is in a section per node.
- **Why the node:** every push is stored under the authenticated node, so
  the server decides which node each key writes as. The topic was only
  ever the default one, and mixing the two made it look like more.
- **The Hello carries the node only** (protocol 4 -> 5): `client.ini`,
  the DLL (`BakaShrot_SetTopic*()` removed), the tools and Python
  (`Client(...)` lost its `topic` argument) have no topic any more. A push
  without one and no `DefaultTopic` is refused ("No default topic for this
  client").
- **Servers too:** `[BakaShrot] Topic` and peers' `Topic` aren't read any
  more (ignored if left), a server links to its peers by node only.
- **Old configs:** `Identities` makes the server refuse to start, saying
  what to write (`Node = garage and DefaultTopic = logs instead of
  Identities = logs:garage`).
- **Tested:** `Names-Test.ps1` (now 49 checks): no `DefaultTopic` means a
  push must name its topic, a key can't write as another section's node
  (and the log says why), the old `Identities` refused. Every suite and
  the push bench (36,400 msg/s, no failures) pass; compiles with 5.73 and
  6.40.

## Done: examples, one server and one client (2026-11-08)

- **`Examples/`**, one folder per setup with its README, indexed in
  `Examples/README.md`. The first, `Examples/SingleServer/`: one server on
  127.0.0.1:12360, one client (`logs:demo`, may push to logs and sensors,
  read all, query), retention on sensors.
- **Its configs are committed, keys included** (a fixed key pair each,
  marked as public and example-only in the files and the README). Every
  other config with keys stays out of git.
- **`Start-Server.ps1`** opens the server in its own window and waits until
  it listens (`-Here` in the current console, `-Reset` deletes its
  database). **`Run-Client.ps1`** pushes (to its topic, another topic, with
  an attachment), reads back (latest, every message with `--time`, the
  attachment, checked), resolves and lists names, runs a SQL query; it
  prints each command, pasteable from the example's folder. Both take
  `-BinDir`, `Build\` by default.
- **Git ignores** what they write: `Examples/**/*.sqlite*`, `Examples/**/out/`.
- **Checked:** both scripts, twice in a row (the ids go on), the
  double-start guard, the README's Python snippet. `Start-Server.ps1 -Here`
  wasn't (it needs an interactive console).

## Threat model (2026-11-08)

BakaShrot is an **internal tool, on trusted machines and a trusted
network**, not exposed to the internet. So:

- The encryption and the server proving itself are defence in depth: they
  stop a misconfigured client from talking to the wrong server and keep
  data off the wire in clear, they aren't holding off attackers.
- What's left on the security side is low priority (below), unless the
  deployment changes. If it ever faces an untrusted network, start with
  per-message signatures, rate limiting the handshake, and keys out of
  plain-text inis.
- Correctness, durability and operations matter more: losing or mixing up
  data, or a server that can't be run unattended, hurts on day one.

## Open items, by importance (for that internal tool)

### Operations and correctness

1. **The server needs a console, and can't be stopped cleanly without
   one.** It reads its commands from the console window (`quit`, ...), and
   stops at once without console input. So no service, no scheduled task,
   no clean stop from a script (tests force-kill it). Fix: a stop file like
   `BenchServer.exe`'s, and/or a local admin connection, then a way to run
   it as a service. (`Design/Release.md` smoke test #4)
2. **The 1.0.0 smoke test, what's left:** replication between two servers
   built by `Release.ps1` (the suites use `BenchServer.exe`, the same server
   code). Done: the release's own smoke test and the example from its zip
   (2026-11-09), restart catch-up (`Restart-Test.ps1`, 2026-11-09). The run
   on a clean Windows is the owner's, as needed: not an open item here.
   (`Design/Release.md`, items 1-3)
3. **A corrupted stored attachment is re-sent to peers forever.** Found
   by `Tests/AttachmentEdges-Test.ps1` part 4 (a byte flipped in the
   sender's `blob_chunks`, `flip.py`).
   - What happens: the peer checks the SHA-256 once all parts are in,
     drops its copy (`FinishReplicatedAttachment(..., #False)`), refuses the
     last part ("The attachment doesn't match its SHA-256, send it again"),
     and lists it as missing again. At the next check-in the sender sends
     all of it again: every `PeerSyncInterval` (6 times in 6 s in the test),
     1 GB each time for a 1 GB attachment. Forever.
   - The sender never notices: it also serves the damaged parts to clients
     (`GetAttachment`), who refuse them by their SHA-256 (the DLL checks at
     the end of `BakaShrot_Download()`).
   - Proposed fix, in `BakaShrot_PeerLink_SendAttachment()`
     (`Server/Networking/Peers.pbi`): when the peer refuses with "doesn't
     match", check this server's own copy with `HashStorageBlob()`
     (`Server/Storage/Attachments.pbi`, the link's own `DbId`). If it's
     damaged, `FinishReplicatedAttachment(TopicId, NodeId, MessageId,
     BlobId, #False)` already does the rest: drops the blob, marks the
     attachment missing (state 0), so this server stops sending it and asks
     its own peers for a good copy (`MissingAttachments`), and stops
     serving it. Log it loudly. If its copy is fine (the damage was in
     transit), sending again is right.
   - The refusal now has its own code (DataMismatch, protocol 6): match
     that rather than the text.
   - The origin (where it was pushed) has no other source: its attachment
     then stays missing ("isn't here yet"), better than serving bad data;
     maybe a "lost" state (4) so `BakaShrotGetAttachment` says so.
   - Optional, to catch it on reads too: a SHA-256 per part in
     `blob_chunks`, checked by `ReadStorageBlobChunk()`, at ~3 s/GB.
   - Test: part 4 of `AttachmentEdges-Test.ps1` then expects the sender to
     log its copy as damaged and the re-sends to stop (today it only prints
     an INFO line with the count); its own `attachments` row goes to 0.
4. ~~**`synchronous = NORMAL`**~~: done, `[BakaShrot.Server] Synchronous`,
   `FULL` by default (see "Done: Synchronous" above).
5. ~~**Drift between servers**~~: ruled out by config, a node pushes to
   one server (written in `schema.ini` and `Design/ReplicationIssues.md`
   #1). Not an open item: nothing to do unless that rule has to go.
6. **Gaps in a pair's ids aren't detected** on replication.
   (`Design/ReplicationIssues.md` #5)
7. **No single test runner**, and fixed ports (12399, 12401-12416): every
   `Tests/*.ps1` and the two `.pb` tests are run by hand. Needed for CI.
   (`Design/Release.md`, "For CI/CD")
8. ~~**Is `DatabaseError()` per thread?**~~ Yes, checked (2026-11-09):
   two threads failing on their own connections 20,000 times each, never
   once the other's message, with 5.73 and 6.40 (`/THREAD`).
   `sqlite3_errmsg16()` on the connection gives the same messages, kept as
   is. Linux untested (item 18).
9. **Limits:** the sync state must fit in one packet (65536 topic/node
   pairs); `ReplicatingTopicIds` ranges are expanded to every id they cover.
   (`Design/ReplicationIssues.md` #7)

### Client side

10. **One connection per process** (the DLL's globals): a handle-based API
   for several. Polling rather than server-pushed subscriptions. Nothing
   reconnects by itself, on purpose: the error codes tell the app when to
   (see "Done: error codes" above).
11. ~~**Breaking with protocols 3 to 6**~~: in the release notes now
    (`VERSION.txt`, "Compatibility", written by `Release.ps1`): servers and
    clients from the same release only, what old configs need.
11b. ~~**A push whose answer was lost can be stored twice if retried.**~~
    Accepted, the way it is: delivery is at least once. A server killed
    between committing a push and answering it keeps it (`Restart-Test.ps1`
    saw #26272 stored, #26271 the last answered), the client gets
    ConnectionLost; pushing it again stores it twice. Documented in
    `BakaShrot_ErrorCodes.pbi`, the DLL's header and `bakashrot.py`; a
    client that minds checks the latest message before retrying.

### Security, low priority under the threat model

12. **Peers are trusted completely:** messages aren't signed by the node
    that first wrote them, a peer can replicate anything in what we accept
    from it. (`Design/ReplicationIssues.md` #3)
13. **Private keys sit in plain-text ini files**, readable by whoever can
    read the config. On trusted machines: file permissions are enough.
14. **No key rotation or revocation**, other than editing configs and
    restarting; a server can't announce a new key, clients pin one.
15. **The handshake costs the server work before the client proved
    anything** (a sealed box, a key pair, a signature): no rate limit, only
    the 4 KB handshake limit and the 10 s timeout.
16. **Small ones:** the DLL doesn't wipe its private key; one identity key
    both signs and opens sealed boxes; `EncodeData`/`DecodeData` are
    misnamed (they sign/verify). (`Design/Cryptography.md`)

### Housekeeping

17. **Review.md rules** not checked against the newer code (`.i` in
    networking structures, explicit enumeration values), see below. The
    file itself says to ignore it for now.
18. **Linux is untested** (libsodium via `-lsodium`, the query error check
    falls back to `DatabaseError()`).
19. **Console commands can't be scripted** (see 1).

### Done recently (details in the sections above and `Design/`)

- Protocol 3: encrypted connections, the server proves itself (2026-11-08).
- The release ships the Visual C++ runtime, from `Libs/redist/` (2026-11-08).
- A JSON query over non-JSON rows is refused with SQLite's error instead of
  answering nothing (2026-11-08, Windows).
- GetMessages, `--follow`, the Python client; big messages (16 MB) and
  `is_json`; names, filters and wildcards; speed: ~34,300 msg/s for 4
  servers (2026-11-07/08).
- `pushed_at` timestamps, carried by replication; retention per topic and
  server, skipping on arrival what's past its age (2026-11-08).
- Attachments, protocol 4: one per message, in 1 MB parts, replicated after
  their message, resumable; edge cases tested (2026-11-08).
- Tools renamed `BakaShrot<Name>`, waiting for Enter when started from
  Explorer; `Examples/SingleServer/` (2026-11-08).
- Protocol 5: a client is a node, its default topic the server's
  (`Node`, `DefaultTopic`); names-only topics, ids picked by the server,
  nodes from their sections, `AcceptNodes = *` (2026-11-08).
- `Synchronous`, `FULL` by default, measured (2026-11-09).
- Schema v8: `browse` / `browse_messages` for database tools (2026-11-09).
- Restart catch-up tested: kills mid-traffic and mid-catch-up, nothing
  acknowledged lost (`Restart-Test.ps1`, 2026-11-09).
- Protocol 6: error codes everywhere, at-least-once delivery accepted
  (2026-11-09).

## To check against Review.md

`Review.md` has two rules the newer code hasn't been reviewed against:

- **No `.i` in networking structures.** The wire packets use `.l`/`.q`, but
  `BakaShrot_ConnectionMetadata\Status`, `BakaShrot_Inbox\Size` and the
  server/link structures use `.i`. Decide whether the rule covers in-memory
  connection state, or only what goes on the wire.
- **Networking enumerations must declare their values explicitly.**
  `BakaShrot_PacketTypes` does. `BakaShrot_ConnectionStatuses` (already
  implicit before) and `BakaShrot_InboxResults` don't.

## Testing tips

- **Run exes from `Build/`.** Exes in the session's temp/scratchpad folder are
  blocked by the antivirus.
- **Test the server's console commands** with a small driver that includes
  `Server/Root.pbi` and calls `BakaShrot_Root_*` directly. Piping commands
  into the server doesn't work.
- **With no console input,** `Input()` returns `Chr(4)` on every call, and the
  server stops on it.
- **Don't trust timestamps** from PowerShell's `Register-ObjectEvent`: lines
  queue up during `Start-Sleep`. PureBasic's console output into a pipe is
  also buffered until exit. Trust the order, not the times.
- **JSON on a tool's command line loses its double quotes** (PowerShell 5
  and PureBasic's `ProgramParameter()`): the tests write it to a file and
  pass `@file`.
- **Things only a raw client can do** (a wrong SHA-256, abandoned uploads):
  `Tests/AttachmentEdgeClient.pb`, over `Commons/Networking/Outbound.pbi`.
  Copy its `Exchange()` / `Refusal()` helpers for new protocol tests.
- **Log scans in the tests skip "Refused a request" lines:** refusals are
  expected, and their codes' names (`InvalidRequest`, `QueryFailed`) hold
  the words the scans look for. PowerShell's `-match` ignores case.
- **Traffic while a server is killed:** `Tests/restart_pusher.py` pushes as
  fast as answers come and logs every acknowledged id, then the error's
  code; `Restart-Test.ps1` shows how to read it back.
- **Corrupting or seeding a database** from a test: Python's `sqlite3`,
  with the server stopped through its stop file (its WAL is checkpointed
  then), see `Retention-Test.ps1` (an old schema) and
  `AttachmentEdges-Test.ps1` (`flip.py`).
