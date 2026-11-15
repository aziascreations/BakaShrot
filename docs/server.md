# The server and the client

`crates/bakashrot-server` (a library and the `bakashrot-server` program)
and `crates/bakashrot-client` (the blocking client library the C DLL will
wrap). Decided in `../revamp.md`, "Decided" (2026-11-13). What goes over
the wire: `protocol.md`.

**Status:** steps 5, 6, 9, 10, 11 and 12: connecting, pushes and their
attachments, messages, attachments, names, queries, retention,
replication, stopping cleanly. Every request of protocol 7 is answered.

## Running

```
bakashrot-server server.toml
```

The config (`config.md`) gives where to listen, the certificates, the CRL,
the database, the topics and the roles. Decided 2026-11-14
(`../revamp.md`, "Operations"):

- **Stopping:** SIGTERM or SIGINT on Linux; Ctrl+C, Ctrl+Break or its
  console closed on Windows. It stops taking connections and writes
  what was queued for the database (`Server::stop`): every push
  answered is stored, the ones after are refused (`ServerError`, "the
  server is stopping"), then it exits with 0. Nothing else to wait for:
  a client whose push wasn't answered pushes it again (at least once).
- **No console commands** (the old `quit`, `restart`, `vacuum`, `names`,
  `help`): it needs no console, a service manager runs it as is. `names`
  is `bakashrot list`, `restart` a stop and a start. Maybe an admin
  channel later.
- **Logs go to the console** (stdout, `tracing`), without colours when
  it isn't a terminal: redirect them, or let systemd or Docker keep
  them. `BAKASHROT_LOG` sets the level: `error`, `warn`, `info` (the
  default), `debug`, `trace`.
- **No Windows service mode:** a tool like NSSM runs it as one, stopping
  it with Ctrl+C.

A systemd unit, for example:

```ini
[Service]
ExecStart=/opt/bakashrot/bakashrot-server /etc/bakashrot/server.toml
User=bakashrot
Restart=on-failure
# SIGTERM, then 90 s at most: far more than a stop takes.
```

### In Docker

`docker/Dockerfile` (its comments have the details), the image
`ghcr.io/aziascreations/bakashrot-server` (amd64 and arm64, pushed by CI
on a version tag): the server, with `bakashrot` and `bakashrot-cert`
beside it, on `debian:trixie-slim`, as uid 10001.

- **The config** in `/etc/bakashrot`, read-only: `server.toml`, the
  certificates, the server's key (readable by uid 10001: `chown 10001`
  it, `bakashrot-cert` writes keys for their owner only). `listen =
  "0.0.0.0:7000"`: 127.0.0.1 isn't reachable from outside.
- **The database** in `/var/lib/bakashrot`, a volume: `database =
  "/var/lib/bakashrot/bakashrot.sqlite"`.
- **Running it:** `docker/compose.yml` (`docker compose up -d` from
  `docker/`, the config in `docker/config/`), or `docker run -d -p
  7000:7000 -v ./config:/etc/bakashrot:ro -v
  bakashrot-data:/var/lib/bakashrot <image>`. `docker stop` is SIGTERM:
  a clean stop. The logs: `docker logs`.
- **The tools:** `docker run --rm <image> bakashrot-cert ...`.
- **Checked** by `docker/test.sh <image>` (CI runs it on both before
  pushing): certificates by the image's tool, its server, a push read
  back over a Docker network, `docker stop` ending it cleanly.

## Inside the server

| What | Where | How |
|---|---|---|
| Connections | tokio, a task each | TLS (`tokio-rustls`, `bakashrot-pki`'s settings), the versions, the identity, then requests one at a time |
| Writes | one writer thread | a queue of every write (pushes, uploads and their parts, replicated messages and parts, retention's deletes); the thread writes whatever is queued in one transaction (group commit, 1000 at most): the busier, the bigger the groups |
| Reads, queries | tokio's blocking threads | a pool of read connections and one of query connections (`query_only`), reused |
| WAL checkpoints | one thread, every second | its own connection, off the writer's way (`storage.md`) |
| The CRL file | a task, every 5 s | reloaded when its time or size changes; one that isn't the CA's is refused, the previous one stays |
| Retention | a task, at start then every `retention_interval` (1 min) | below |
| Replication | a task per server of `push_to` | below: links kept up, a check-in every `sync_interval` (5 s) |

## Retention

`[retention]` (`config.md`) says how long each topic's messages are kept.
At start, then every `retention_interval`, the server goes through every
topic in its database (one no longer in `topics` too) and deletes the
messages pushed before now minus its age, 10,000 per write, so pushes go
on between them. Then the parts of their attachments, 64 MB per write.
Each topic's count is logged ("deleted 3 messages of topic 'logs'").

- **In id order** (`storage.md`, "Retention"): a message stamped earlier
  than the one before it (a clock set back) waits for that one.
- **Ids go on:** a stream's last id stays, the next push takes the next.
- **"May be" deleted past its age:** up to `retention_interval` later.
- **Each server its own:** a peer's ages are its own. What a peer sends
  already past this server's age isn't stored, but counts as received:
  it isn't sent again.

## Replication

Decided in `../revamp.md` ("Replication by address", 2026-11-14).
Each server's config says who it replicates with, by address
(`config.md`, "Peers"): `push_to`, the servers it dials and sends to;
`accept_from`, the servers whose messages it takes (`"*"` for all). A link
carries messages one way, from the server that dials to the one dialed;
the other way is the other server's own `push_to`.

**Sending** (`push_to.rs`): a link to each server of `push_to`, as a
client with this server's certificate; a failed or dropped one is dialed
again after `retry_delay` (10 s), its failure logged once until it
changes. It checks in from the start, then again at once if it sent
something (so it keeps up under load), after `sync_interval` (5 s)
otherwise:

1. `SyncStateRequest`: the other server answers what it takes from this
   one (topics and nodes, patterns included), its last id in each topic
   and node, and the attachments it lacks (256 at most).
2. **The messages:** for each topic and node here that it takes and that
   its roles here may be sent (`send_topics`, `send_nodes`,
   `replicated_topics`), and where it's behind, the messages after its
   last id, `batch_size` (1000) at a time and about 1 MiB at most (a
   bigger one alone), each batch answered before the next. A refusal
   leaves that topic and node for the next check-in.
3. **The attachments it lacks:** those this server has ready, from the
   part it needs. One it says doesn't match its SHA-256 is read back
   here: damaged (a disk, a bug), this server's copy is dropped and asked
   for again from its own peers (`replicating`, not served meanwhile),
   instead of sent again at every check-in (the old open item 3).

**Receiving** (`accept_from.rs`): replication requests are answered only
if the connection comes from `accept_from` (a hostname looked up at its
first request, `NotAllowed` otherwise), and only for what its roles'
`accept_topics` / `accept_nodes` allow (`NotAllowed`). Messages keep
their ids and `pushed_at`; ones already here are kept as they are; one
past this server's age is only counted. An attachment comes after its
message (`replicating`, `NotReady` to readers), from the part this server
needs, the parts it had read back for the SHA-256; matching, it's ready,
otherwise started over (`DataMismatch`). A stop between its last part
and the check: started over at the next start.

**One server per node** stays the config's rule, as in the old version
(`known-issues.md`): a node pushing to two servers that replicate makes
the same ids with different messages, undetected.

## A connection

1. **TLS:** the client's certificate must be the CA's, valid, not revoked,
   with an identity (`certificates.md`). A refused one gets TLS's alert,
   then a gentle close: the server shuts down and reads until the client
   closes (1 s at most). Closing at once reset the connection (the
   client's version bytes unread), which could beat the alert to the
   client: `ConnectionLost` instead of `AuthRejected`, about 1 in 10 under
   load on Windows.
2. **The versions:** each end sends its own; different ones, the
   connection is dropped (the client says `VersionMismatch`).
3. **The roles:** none of the certificate's roles in the config, the
   server answers `RequestRefused` (`NotAllowed`, saying which roles) and
   closes; otherwise `Welcome` (the server's name, the client's node).
4. **Requests**, one at a time. Before each, the certificate is checked
   against the current CRL: revoked since, the connection is dropped.

| Timeout | |
|---|---|
| TLS, versions, welcome | 10 s (the server); the client's connect too |
| Silence between requests | 5 min, then the server closes |
| An answer | 30 s (the client) |
| An attachment's next part | 30 s (the server), then it closes |

## Requests so far

- **`PushMessage`:** the topic must be one of the config's (`UnknownName`),
  the roles must allow pushing to it (`NotAllowed`), the message at most
  `MAX_MESSAGE_SIZE` (`TooBig`); stored under the client's node, stamped
  with the server's time; answered `MessagePushed` once committed.
- **With an attachment:** also at most the config's `max_attachment_size`
  (`TooBig`; 0 takes none). The server answers `Continue`, then reads
  every part: each written while the next come (4 at most waiting for the
  writer, so the client waits through TCP rather than the server holding
  them), the SHA-256 computed as they come. All there and matching, the
  message is stored with it, ready, in one transaction. A part of the
  wrong size (`InvalidRequest`), a wrong SHA-256 (`DataMismatch`), a
  failed write: refused once every part came, the connection kept. A
  connection that closes, or sends anything else than the next part, is
  dropped. Not pushed, the upload goes (`storage.md`, "Attachments").
- **`GetAttachment`:** the roles must allow reading the topic
  (`NotAllowed`), the topic must be one of the config's (`UnknownName`).
  A message without one, or none of that id: `NotFound`; one still on its
  way from a peer: `NotReady`; one this server doesn't keep: `TooBig`.
  Then `Attachment` (its size, its SHA-256) and the parts from
  `from_part`. A part that can't be read closes the connection.
- **`GetMessages`:** the roles must allow reading the topic
  (`NotAllowed`), the topic must be one of the config's and the node one
  with messages in any topic, or the client's own (`UnknownName`); a known
  topic and node without messages answer none. At most `limit` messages and about 1 MB
  (`MESSAGES_BYTES`, a bigger message alone), `more` if others follow.
- **`ListNames`:** topics are the config's, those the roles may push to or
  read (every one with `query`, which reads them all anyway); nodes are
  every one with messages. `truncated` past 65,536.
- **`Query`:** the roles must allow it (`NotAllowed`); read-only SQL,
  refused with SQLite's message (`QueryFailed`, with a hint to add
  `is_json = 1` on "malformed JSON"), over 10,000 rows or 16 MB
  (`TooBig`), never a partial result (`storage.md`, "The query surface").
- **Sizes:** frames up to 16 MB (`MAX_PACKET_SIZE`), a bigger one drops the
  connection; messages up to `MAX_MESSAGE_SIZE` (16 MB less 4 KB), the
  server refusing bigger ones (`TooBig`); the client refuses messages and
  queries over it before sending (`InvalidArgument`).

## The client

`Client::connect(address, settings)` (`host:port`, the CA's certificate,
the client's certificate and key, the CRL if any), then `push(topic,
data)`, `get_messages(topic, node, after, limit)`, `list_names(kind)`,
`query(sql)`. Blocking, no runtime. The DLL and the bindings over it:
`client.md`.

Attachments: `push_with_attachment(topic, data, source)`, the source any
`Read + Seek` (a `File`, a `Cursor`), read twice: its SHA-256, then its
parts; `get_attachment(topic, node, id, out)` into any `Write`, checked
with its SHA-256 once all came; `save_attachment(topic, node, id, path)`,
written to `path` and `.download` then moved over `path`, so a failed one
leaves no file. A source or a part that fails half-way closes the
connection (the server can't be told to stop); a failing `out` doesn't
(the rest is read, then `FileError`).

Its errors are the protocol's codes: a server's refusal keeps its own
(1-99), the client's are 100 and up (`ConnectFailed`, `AuthRejected` when
the server refused its certificate, `ServerNotVerified` when it refused the
server's, `ConnectionLost`, `ProtocolError`, `InvalidArgument`,
`FileError`, `AttachmentMismatch`, `VersionMismatch`).

## Measured

`push_rate` (`tests/end_to_end.rs`, ignored by default): a whole server on
localhost, 10 clients each its own node (`CLIENTS`), one push at a time
each, 200-byte JSON, 20,000 pushes per client.

| `synchronous` | 10 clients | Slowest push | 1 client |
|---|---|---|---|
| `normal` | 40,400/s | 37 ms | 14,200/s |
| `full` | 9,229/s | 9 ms | 1,920/s |

- With `normal`, the server reaches the storage's own ceiling (about 37k/s
  alone, `storage.md`, a slightly different load). Up from 36,000/s once
  a connection's revocation check stopped reading its certificate at
  every request (its serial is read once, at connect).
- One client waits for each answer: a round trip and a commit per push.
  Through Python and the DLL, about 10,700 pushes/s (the old module did
  about 9,000), and 140,000 messages/s read.
- With `full`, every group commit waits for the disk's flush (about 1 ms
  here): 10 clients make groups of about 10. More clients, bigger groups.
- **Attachments** (release, the tool, `normal`): 200 MB up in 1.3 s and
  down in 0.5 s, the tool's start and the client's hashing included.
- **Built for size** (`opt-level = "s"`, 2026-11-14; the numbers here
  were measured before, at 3): `normal` about 5% lower (36,900-38,100/s
  against 39,800-40,400), `full` the same (the disk's), attachments and
  tool commands the same. The programs and the DLL 25-31% smaller.

### Against the old server (2026-11-14)

The same work on the same machine, release builds, one server on
localhost: the old one (`OldSource/Build/Bench/BenchServer.exe`, its DLL,
`bakashrot.py` and tools) and this one. Pushes and reads through each one's
Python module and DLL (10 clients: 10 processes, the same node), 200-byte
JSON; the rest through the tools.

| | Old, `full` | New, `full` | Old, `normal` | New, `normal` |
|---|---|---|---|---|
| One tool command, connecting included | 8 ms | 12 ms | 8 ms | 11 ms |
| Pushes, 1 client | 1,945/s | 1,954/s | 9,386/s | 11,600-13,100/s |
| Pushes, 10 clients | 9,006/s | 10,072/s | 25,419/s | 56,200-64,300/s |
| Reads, Python | 76,466/s | 130,861/s | 77,526/s | 146,368/s |
| The tool writing 120,000 messages to a file | | | 45.5 s | 0.14 s |
| A 200 MB attachment up, the tool | 3.49 s | 1.15 s | 2.84 s | 1.15 s |
| The same down | 1.57 s | 0.59 s | 1.62 s | 0.67 s |

- **`full`, one client:** both wait for the disk's flush at every push.
- **A command:** the TLS handshake's P-384 signatures and checks, both
  ends, cost about 7 ms against the old handshake's X25519; aws-lc's CPU
  Jitter Entropy seeding cost 25 ms more per process before it was turned
  off (`certificates.md`, "TLS").
- **The old tool's read** printed a line at a time to the console API.

### Replication, against the old server (2026-11-14)

`replication_rate` (`tests/end_to_end.rs`, ignored by default) against
the old `Tests/Bench/Bench-Replication.ps1 -Parts Ramp -Ramp 10x0`: 4
servers in a Y (a hub sending to 3 leaves, each sending to the hub), 10
nodes pushing to each as fast as they're answered for 30 s, 200-byte
JSON, the same machine. The old one's pushers are its PureBasic bench
client, the new one's `bakashrot-client` threads in the test's process.

| | Old, `full` | New, `full` | Old, `normal` | New, `normal` |
|---|---|---|---|---|
| Pushes, all 4 servers | 16,638/s | 16,000-16,300/s | 33,895/s | 35,300-37,500/s |
| Slowest push | 134 ms | 50-57 ms | 854 ms | 420-510 ms |
| Behind when the pushes stop (most of a server) | 9.0 s of pushes | 0 | 11.4 s | 0.3-0.9 s |
| Until every server has everything | 8.8 s | 0.3 s | 14.8 s | 5.3-5.6 s |

- **Keeping up:** a link checks in again at once after sending; before
  it waited `sync_interval` after every check-in, as the old one did, and
  pushes went faster (19,300/s `full`, 40,200/s `normal`) while the
  leaves fell 7-9 s behind and took 10-20 s to catch up.
- **`batch_size` 1000** (was 100, the old `PeerBatchSize`): `normal` went
  from 27,500-31,500/s to 35,300-37,500/s, and from 2-2.5 s to under 1 s
  behind. Batches stay about 1 MiB at most.
- **The last few seconds** with `normal` are a link's `sync_interval`:
  idle once caught up, it looks again 5 s later.

## Tests

`crates/bakashrot-server/tests/end_to_end.rs`, a server on a free port
each:

- pushes and reads back (ids, data, times, another connection);
- runs of messages (`OldSource/Tests/GetMessages-Test.ps1`, the server's
  part): from the start, after an id, with a limit, `more`, the last ones,
  nothing yet, unknown topics and nodes, names without case, data that
  isn't one line of JSON;
- big messages (`BigMessages-Test.ps1`, one server's part): five of 600 KB
  and one of the largest size, one per answer, read back whole; one byte
  over refused; a query result over 16 MB refused;
- names: topics by role, nodes;
- attachments (`Attachments-Test.ps1`, one server's part): 100 KB, 5 MB +
  123 bytes, exactly 2 MB, 1 byte, 1 MB, read back and saved; the
  messages saying theirs; none, or no such message, refused leaving no
  file; another reader, one not allowed; over the server's limit, 0 for
  none, empty; the parts stored;
- attachment edges (`AttachmentEdges-Test.ps1`'s, through the client and
  a raw connection): a source changed between its SHA-256 and its
  sending, one failing half-way (the connection closed, the upload
  dropped), a part of the wrong size, a wrong SHA-256, reading from a
  part on, something else than a part (closed, dropped);
- queries (`BigMessages-Test.ps1`'s): not allowed, results, a non-JSON row
  refused with the hint, errors, writes and two statements refused;
- refusals keeping the connection (not allowed, unknown topic, a bad name
  the client catches);
- certificates refused (no known role, with why; another CA's client; a
  client trusting another CA; nothing listening);
- revoked certificates (an open connection dropped at its next request, a
  new one refused, others going on, a bad CRL refused);
- six connections pushing at once (one id stream per node, none lost or
  doubled);
- stopping cleanly: eight nodes pushing flat out, the server stopped
  under them: every push answered is there after a restart, the ones
  after refused as `ServerError`;
- retention (`Retention-Test.ps1`'s local part): a topic's messages and
  their attachment deleted past its age, another topic kept forever, ids
  going on, a younger message kept through a pass;
- replication (`Names-Test.ps1`'s replication, `Restart-Test.ps1`,
  `AttachmentEdges-Test.ps1`'s corruption): three servers of one CA, a
  pushing to b and c. b gets every message by name with its id, time
  and data, and the attachment; c, whose `accept_from` hasn't a, gets
  nothing; b's own pushes don't go to a. b stopped, a pushes meanwhile
  and its copy of an attachment gets damaged; b started again on its
  database and address: a links again, sends what b lacks, ids go on;
  b refuses the damaged copy, a finds it damaged and asks for it again;
- replication edges (the test as the peer, a raw connection): what
  `SyncState` says, ids and last ids kept, a message past its age only
  counted, an attachment from the wrong part refused, one cut after its
  first part going on from the second (the first read back for the
  SHA-256), one not matching refused and asked for from the start, a
  certificate whose roles take nothing refused;
- `replication_rate`, ignored by default: the benchmark above (`SYNC`,
  `NODES`, `SECONDS`, `BATCH`).

The old tests' tool parts (`--follow`, the output) are the tools' tests
(`client.md`).
