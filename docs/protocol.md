# Protocol 8

What goes over a connection between a client and a server, or two servers.
The code is `crates/bakashrot-proto`; this describes it.

**Status (2026-11-13):** packets, frames, names and error codes are written
and tested (`bakashrot-proto`), so is the TLS setup (`bakashrot-pki`,
`certificates.md`). The server and the client speak it so far for
connecting, pushes and messages (`server.md`).

## Transport

- **TCP, then TLS 1.3**, both ends with a certificate from the deployment's
  CA (mutual TLS, `revamp.md`, "Decided"), at the strongest settings
  rustls has: ECDSA P-384 certificates, AES-256-GCM-SHA384, the X25519MLKEM768
  key exchange, nothing else offered.
- **Identities:** a certificate's identity extension gives its node's name
  and roles. The client's is who it is; the server's is checked by the
  certificate alone (the CA's, valid, not revoked, for servers, the name
  expected), no host names or IPs. Revoked certificates are in the CA's
  CRL: servers check it, and so do clients given it (servers dialing their
  peers too).
- **ALPN `bakashrot`** (`limits::ALPN`): both ends offer it and check it
  was agreed on, what isn't BakaShrot doesn't get past TLS. rustls only
  refuses a client offering other protocols, so the server closes one
  offering none right after the handshake, before the versions
  (2026-11-19). It isn't versioned.
- **The versions, first:** right after TLS, each end sends its protocol
  version, 4 bytes little-endian (`frame::write_version()`), and reads the
  other's (`frame::check_version()`). Different versions: both ends
  abandon the connection (the client's error is `VersionMismatch`). This
  comes before any frame, so it holds whatever later versions change.
- **The server speaks next:** a `Welcome`, saying who the connection is.
  Then the client sends requests. A certificate none of whose roles the
  server has gets a `RequestRefused` (`NotAllowed`) instead, then the
  connection closes.
- **Frames:** every packet is one frame, its size as a 4-byte
  little-endian unsigned integer, then the packet (`frame`). A size of 0,
  or over `MAX_PACKET_SIZE` (16 MiB), aborts the connection as soon as it
  arrived. The blocking client reads and writes them with `frame::read()`
  / `write()`, the async server with `frame::codec()` (`tokio-util`).
  The limit applies to authenticated links only, as the owner asked
  (2026-11-08, then 4 KB before authenticating): TLS authenticates both
  ends before any frame, so nothing unauthenticated reaches one (rustls
  bounds the handshake itself). Kept rather than lifted (2026-11-19): a
  buggy peer announcing gigabytes would make the other end hold them.

## Packets

A packet is **a MessagePack array of two: its type, then its fields as an
array**, `[type, [field, ...]]`. A struct inside is an array of its fields,
an optional value nil or itself, bytes a binary. The structs in
`crates/bakashrot-proto/src/packets/` are the format: `serde` derives it
(`rmp-serde`'s compact form). Any MessagePack library reads it. For
example `PushMessage { topic: "logs", data: "{}", attachment: None }`:

```
92             array of 2
04             type 4, PushMessage
93             its 3 fields
a4 6c 6f 67 73 "logs"
a2 7b 7d       "{}"
c0             nil: no attachment
```

**Decoding checks everything** (`Packet::decode`): the types and number
of fields, each packet's rules (ranges, names, ids in order), and that
nothing follows. Anything wrong is a `DecodeError`: the connection is
aborted. (A struct given as a map of its field names is taken too, a
leniency of `serde`'s derive: nothing writes it, it isn't part of the
format, its values are checked all the same.)

### Values

- **Topics and nodes are names**, everywhere: 1-64 of `A-Z a-z 0-9 _ . -`,
  not only digits, compared without case (`names`). A name that isn't one
  is malformed (the client libraries check before sending); a node the
  server has no message of is refused (`UnknownName`), a topic is only
  ever allowed or not (the roles). Ids are each server's own, in
  its database, never on the wire.
- **Patterns** (in a `SyncState`): names with `*` (any characters, none
  included) and `?` (one).
- **Message ids:** 1 to 2^43 - 1 (`MAX_MESSAGE_ID`), in their topic/node
  pair: what a server stores (`storage.md`, "Keys").
- **Times:** milliseconds since 1970-01-01 00:00:00 UTC, 1 to
  9999-12-31 23:59:59.999 (`MAX_TIMESTAMP`). Stamped by the server a
  message is pushed to, kept by replication.
- **Attachments:** `[size, sha256]`, 1 B to 1 TiB, sent in parts of
  1 MiB (`ATTACHMENT_PART_SIZE`), the last one what's left.

### Types

Direction: **C** client, **S** server, **P** peer (a server linked to
another, as its client). Ids are protocol 7's own (6 can't connect; 8
added `ListNames`' filters and `SyncState`'s pages); a new packet takes
the next one, none is ever reused.

| Id | Packet | Dir | Fields | Answered by |
|---|---|---|---|---|
| 1 | Welcome | S→C, S→P | `server` name, `node` name (the connection's, from its certificate) | |
| 2 | RequestRefused | S→C, S→P | `code` 1-99 (`error`), `reason` str | |
| 3 | Continue | S→C, S→P | none: send the attachment's parts | |
| 4 | PushMessage | C→S | `topic` name, `data` str (up to `MAX_MESSAGE_SIZE` bytes), `attachment` or nil | MessagePushed / RequestRefused; with an attachment, Continue first |
| 5 | MessagePushed | S→C, S→P | `message_id` | |
| 6 | GetMessages | C→S | `topic`, `node`, `after` (an id, 0 for all) or nil (the last ones), `limit` 1-10000 | Messages / RequestRefused |
| 7 | Messages | S→C | `more` bool, `[[id, pushed_at, data, [size, ready] or nil]...]` (ids strictly increasing, 10000 at most) | |
| 8 | GetAttachment | C→S | `topic`, `node`, `message_id`, `from_part` | Attachment then its parts / RequestRefused |
| 9 | Attachment | S→C | `size`, `sha256` | |
| 10 | AttachmentPart | C→S, S→C, P→S | `data` bin, 1 B to 1 MiB | |
| 11 | ListNames | C→S | `kind` (1 topics, 2 nodes), `topics`, `nodes`: each a name or a pattern, or nil for any (those of the topic/node pairs they match) | NamesList |
| 12 | NamesList | S→C | `kind`, `truncated` bool, `[name...]` (65536 at most) | |
| 13 | Query | C→S | `sql` str | QueryResult / RequestRefused |
| 14 | QueryResult | S→C | `json` str: `{"columns":[...],"rows":[[...],...]}` | |
| 15 | SyncStateRequest | P→S | `after`: `[topic, node]`, the last head of the previous page, or nil for the first | SyncState / RequestRefused |
| 16 | SyncState | S→P | `more` bool, `[topic...]`, `[node...]` (names and patterns it takes from P), `[[topic, node, last_id]...]` (in the order of their names, 32768 at most), `[[topic, node, message_id, next_part]...]` (attachments it lacks, 256 at most); the lists and attachments in the first page only | |
| 17 | ReplicateMessages | P→S | `topic`, `node`, `[[id, pushed_at, data, [size, sha256] or nil]...]` (1-10000, ids strictly increasing) | MessagePushed (the last id) / RequestRefused |
| 18 | ReplicateAttachment | P→S | `topic`, `node`, `message_id`, `from_part` | Continue, then its parts, then MessagePushed / RequestRefused |
| 19 | Ping | C→S, P→S | none: keeps an idle connection open | Pong |
| 20 | Pong | S→C, S→P | none | |

## Flows

```
Pushing         C: PushMessage                      S: MessagePushed / RequestRefused
  with an       C: PushMessage(attachment)          S: Continue / RequestRefused
  attachment    C: AttachmentPart x every part      S: MessagePushed / RequestRefused (DataMismatch)
Reading         C: GetMessages(after: id)           S: Messages, `more` if others follow
  the latest    C: GetMessages(after: nil, 1)       S: Messages (empty if none)
An attachment   C: GetAttachment(from_part)         S: Attachment, then AttachmentPart x the rest
                                                       / RequestRefused (NotFound, NotReady)
Replicating     P: SyncStateRequest                 S: SyncState, `more` if others follow
                P: SyncStateRequest(after) x pages  S: SyncState
                P: ReplicateMessages x the batches  S: MessagePushed each / RequestRefused
                P: ReplicateAttachment x missing    S: Continue / RequestRefused
                                                       (NotReady: another peer sending it)
                P: AttachmentPart x from next_part  S: MessagePushed / RequestRefused
Keeping alive   C: Ping (every minute while idle)   S: Pong
```

- **Parts are streamed:** no request or answer per part, TCP paces them.
  A part's index follows from the order, its exact size from the
  attachment's size (`Attachment::part_len()`); the receiver checks both,
  and the SHA-256 once all came.
- **Once the server said `Continue`**, it reads every part even if storing
  them failed, then refuses: the client never has to read while sending.
- **A server failing while it sends parts** closes the connection; the
  client asks again `from_part` the next one it needs.
- **Replication:** `SyncState` is all a check-in needs. Its heads come
  in pages of `MAX_HEADS_PER_PACKET` (32768): the biggest first page,
  every list full and every name 64 characters, is about 13.3 MB, in a
  16 MiB frame (`the_biggest_sync_state_fits`). The peer asks for the
  next `after` the last head while `more`, then compares them all with
  what it has, by name, sends the messages the server lacks in
  batches of up to `batch_size` messages and about 1 MiB (a bigger
  message alone), then the attachments it listed.

## Rules

- **One request at a time:** a client sends one, waits for its answer (the
  parts of an attachment being part of its request or answer). While a
  `Query` runs, anything from the client (its closing, having given up
  waiting) stops the query and closes the connection (2026-11-20); the
  server's own limit stops it past `query_time_limit` (`QueryTimedOut`).
- **Silence:** the server closes a connection with no request for
  `IDLE_TIMEOUT_SECS` (5 min). An end waiting longer between requests
  sends a `Ping` every `KEEPALIVE_SECS` (1 min) meanwhile (added
  2026-11-19, protocol 8 not released yet): the tool's and the bindings'
  follows and the replication links do it themselves; the DLL has no
  thread of its own, so an app idle that long calls `BakaShrot_Ping()`.
  A `Ping` needs no permission; a revoked certificate's is dropped like
  any request.
- **Refuse or abort:** valid but not allowed or not found (permissions,
  unknown names, over a limit, a failed query) is a `RequestRefused` with a
  code, the connection stays. Malformed or out of order (a bad frame, a
  `DecodeError`, an unexpected packet) aborts it. Clients apply the same
  to answers.
- **The identity is the connection's:** requests never say who sends them.
  A push picks its topic, never its node.
- **Error codes** (`error`): 1-99 refusals, 100+ the client's own, never
  renumbered.
