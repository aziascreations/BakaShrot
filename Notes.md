# BakaShrot - working notes

Where things stand and what's next, as of 2026-11-08. The detailed docs are in
`Design/`:

| Doc | About |
|---|---|
| `Design/Packets.md` | The protocol: framing, every packet, flows, conventions, how to add a packet. |
| `Design/Cryptography.md` | What libsodium is used for: the handshake proving both ends, the connections' encryption. What isn't done, and ideas for abstracting it. |
| `Design/ReplicationIssues.md` | Known replication problems, with benchmarks. |
| `Design/StorageConcurrency.md` | One connection per thread, WAL, the write mutex and the writer (done), and what's left. |
| `Design/Suggestions.md` | Improvements not done yet: pipelined pushes, faster replication, smaller ones. |
| `Design/Release.md` | The release smoke test, what's missing for 1.0.0, the (fixed) silent query failure, notes for CI/CD. |

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
    with the key its clients know (protocol 3, `Design/Cryptography.md`).
  - Clients can push messages (usually JSON, anything is stored, flagged
    in `is_json`), read the latest one of a topic/node pair or a run of
    them after an id, resolve names, and run raw read-only SQL, each depending on
    per-client `AllowRead`, `AllowWrite`, `AllowQuery`, `PushTopics` and
    `ReadTopics`. Topics and nodes by name or id, see below.
  - Links to its peers, retries when that fails, and replicates the missing
    messages in batches (`PeerBatchSize`).
  - One thread per client and per peer, each with its own SQLite connection.
  - The root thread can stop every worker (restart, vacuum).
- **Client:** a DLL with A/W string exports, PureBasic prototypes in
  `Client/BakaShrot_Client_Prototypes.pbi`, and tools in `Tools/`:
  `PushMessage`, `GetLatestMessage`, `GetMessages` (with `--follow`),
  `Resolve`, `ListNames`, `Query`, `KeyGen`.
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
- **A peer authenticates by name:** its own topic and node must be named the
  same on the servers it links to (it sends its name when it has one).
- **Everywhere a topic or node goes, a name or an id:** config, the Hello,
  requests, tools, client.ini. Keys: `Topic`, `Node`, `ReplicatingTopics`
  (`TopicId`, `NodeId`, `ReplicatingTopicIds` still read when the new ones
  are missing, in server configs and client.ini).
- **Filters:** per client `PushTopics` / `ReadTopics` (default: its
  identities' topics, as before), per peer `SendTopics` / `AcceptTopics`
  (default: `ReplicatingTopics`). `*` = every topic. A push picks its topic
  (`PushMessage -t sensors`), never its node.
- **The config wins at start,** except when it would move a name to another
  id than the one its messages are under: the server then refuses to start
  and says which id to use (`Server/Storage/Names.pbi`).
- **Seeing the names:** the server's `names` console command, the
  `ListNames` tool (`BakaShrot_ListTopics/Nodes()` + `BakaShrot_GetNamesList()`
  as JSON, request `ListNames`), `Resolve` for one.
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
- **Left:** attachments for real files (the unused `attachements` table:
  the message references a blob sent in chunks, only when wanted), if more
  than 16 MB is ever needed. Memory: an authenticated connection can hold
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
- **Tool:** `GetMessages <Topic> <Node> [--after <Id|latest>] [--limit <N>]
  [--follow] [--interval <Ms>] [ClientIni]`: one line per message, id, tab,
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
  against ~75/s launching `PushMessage.exe` each time.
- **Released:** `GetMessages.exe` and `python\` (bakashrot.py, example.py),
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
2. **The 1.0.0 smoke test isn't done:** a run from the extracted zip on a
   clean Windows (the shipped runtime has never been checked there),
   replication between two release servers, restart catch-up (designed to
   work, never tested: kill a server, check ids continue and peers catch
   up). (`Design/Release.md`, items 1-3)
3. **`synchronous = NORMAL`:** the last commits can be lost on a power loss
   or OS crash (not on a killed process). Decide, or switch to `FULL`.
   (`Design/StorageConcurrency.md`)
4. **Drift between servers** when one topic/node pair is written to on two
   servers: only partially resynced. Accepted while each pair has a single
   writer; document that as the rule. (`Design/ReplicationIssues.md` #1)
5. **Gaps in a pair's ids aren't detected** on replication.
   (`Design/ReplicationIssues.md` #5)
6. **No single test runner**, and fixed ports (12399, 12401-12407): every
   `Tests/*.ps1` and the two `.pb` tests are run by hand. Needed for CI.
   (`Design/Release.md`, "For CI/CD")
7. **Is `DatabaseError()` per thread?** Messages could land in the wrong
   thread's log or refusal; Windows queries no longer depend on it.
   (`Design/StorageConcurrency.md`)
8. **Limits:** the sync state must fit in one packet (65536 topic/node
   pairs); `ReplicatingTopicIds` ranges are expanded to every id they cover.
   (`Design/ReplicationIssues.md` #7)

### Client side

9. **One connection per process** (the DLL's globals): a handle-based API
   for several. No reconnect in `GetMessages --follow` / `follow()`, polling
   rather than server-pushed subscriptions.
10. **Breaking with protocol 3:** every client config needs
    `ServerPublicKey`; older clients can't connect. Fine while it's all
    built from this repo, worth a line in the release notes of the first
    real release.

### Security, low priority under the threat model

11. **Peers are trusted completely:** messages aren't signed by the node
    that first wrote them, a peer can replicate anything in what we accept
    from it. (`Design/ReplicationIssues.md` #3)
12. **Private keys sit in plain-text ini files**, readable by whoever can
    read the config. On trusted machines: file permissions are enough.
13. **No key rotation or revocation**, other than editing configs and
    restarting; a server can't announce a new key, clients pin one.
14. **The handshake costs the server work before the client proved
    anything** (a sealed box, a key pair, a signature): no rate limit, only
    the 4 KB handshake limit and the 10 s timeout.
15. **Small ones:** the DLL doesn't wipe its private key; one identity key
    both signs and opens sealed boxes; `EncodeData`/`DecodeData` are
    misnamed (they sign/verify). (`Design/Cryptography.md`)

### Housekeeping

16. **Review.md rules** not checked against the newer code (`.i` in
    networking structures, explicit enumeration values), see below. The
    file itself says to ignore it for now.
17. **Linux is untested** (libsodium via `-lsodium`, the query error check
    falls back to `DatabaseError()`).
18. **Console commands can't be scripted** (see 1).

### Done recently (details in the sections above and `Design/`)

- Protocol 3: encrypted connections, the server proves itself (2026-11-08).
- The release ships the Visual C++ runtime, from `Libs/redist/` (2026-11-08).
- A JSON query over non-JSON rows is refused with SQLite's error instead of
  answering nothing (2026-11-08, Windows).
- GetMessages, `--follow`, the Python client; big messages (16 MB) and
  `is_json`; names, filters and wildcards; speed: ~34,300 msg/s for 4
  servers (2026-11-07/08).

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
