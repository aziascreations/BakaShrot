# Protocol - packets, flows and conventions

Reference for working on BakaShrot's networking. Related docs:

- `Design/Cryptography.md`: how the handshake proves both ends and sets up
  the encryption, and what's still left.
- `Design/ReplicationIssues.md`: known replication problems, with a benchmark.
- `Design/StorageConcurrency.md`: the database threading problem and its
  planned fix.

## Where things live

| What | Where |
|---|---|
| Packet base, type ids, limits | `Commons/Networking/Packets.pbi` |
| What a topic or node "ref" is: a name or an id | `Commons/Networking/Names.pbi` |
| Server: which name every id has, translating names to ids | `Server/Storage/Names.pbi` |
| One file per packet, with its `_Encode` and `_Decode` | `Commons/Networking/Packets/*.pbi` |
| Framing (and its encryption), connection metadata, the signed handshake transcript, `BakaShrot_GetPacketType` | `Commons/Networking/Connections.pbi` |
| Sealed Hello, key exchange; encrypting a buffer | `Commons/Cryptography/Session.pbi`, `Commons/Cryptography/Cipher.pbi` |
| Client side of the handshake, on any connection | `Commons/Networking/Outbound.pbi` |
| Server: listener, one thread per client, request handlers | `Server/Networking/Networking.pbi` |
| Server: links to peers, check-ins, sending missing messages and attachments | `Server/Networking/Peers.pbi` |
| Server: storing messages (the writer), attachments, deleting old ones | `Server/Storage/Writer.pbi`, `Attachments.pbi`, `Retention.pbi` |
| Server: its config, and the example one | `Server/Config/Config.pbi`, `Server/Config/schema.ini` |
| Server: the root thread, which stops and starts every worker (restart, vacuum) | `Server/Root.pbi` |
| Client DLL (one connection) | `Client/BakaShrot_Client.pbi`, used through `BakaShrot_Client_Prototypes.pbi` |
| Python client, over the DLL | `Interactors/Python/bakashrot.py` |
| Tests of the packets alone, without sockets | `Tests/HandshakeTest.pb` |
| Tests of the cipher and the session crypto, without sockets | `Tests/CipherTest.pb` |
| What goes over the wire (a recording proxy) | `Tests/wire_check.py`, run by `Tests/Python-Test.ps1` |
| A raw protocol client, for what the DLL never sends | `Tests/AttachmentEdgeClient.pb`, run by `Tests/AttachmentEdges-Test.ps1` |
| Every end-to-end suite | `Tests/*.ps1`, listed in `CLAUDE.md` |

## Transport and framing

- **TCP, IPv4.** A server listens on `[BakaShrot.Server] Host:Port`.
- **Frames:** every packet is sent as one frame: its size as a **4-byte
  little-endian** unsigned integer, followed by the packet itself.
  - `BakaShrot_SendPacket()` sends a frame and loops until all of it is
    sent.
- **Encryption:** the frame's content, not its size:
  - Frame 1, the Hello: sealed for the server's public key
    (`crypto_box_seal`, 48 bytes more).
  - Frame 2, the ChallengeRequest: plain text, signed by the server.
  - Every frame after it, both ways: encrypted with the connection's keys
    (`Cipher.pbi`): `[sequence number, 8 bytes LE][encrypted packet][16-byte
    tag]`, 24 bytes more. A frame that doesn't decrypt, or out of sequence,
    aborts the connection. `BakaShrot_SendPacket()` encrypts when given
    the cipher, `BakaShrot_OpenFrame()` decrypts once it's set up.
  - `BakaShrot_Inbox_*` gathers received bytes and takes complete frames out
    of them.
- **Limits:**
  - A packet is 1 to `#BakaShrot_MaxHandshakePacketSize` (4 KB) bytes until
    the other end is authenticated, then 1 to `#BakaShrot_MaxPacketSize`
    (16 MB, plus the 24 bytes of encryption). A frame announcing anything
    else is invalid, as soon as its
    4-byte size arrived. The server lifts it (`BakaShrot_Inbox_Lift()`)
    before sending AuthAccepted, the client once it got it. So anyone can
    connect, but only those with a key can make the other end hold big
    frames.
  - At most 2 frames' worth of data may wait, unread, in an inbox
    (`BakaShrot_Inbox_MaxSize()`: ~8 KB, then ~32 MB).
  - Breaking either limit aborts the connection.
  - A pushed message is at most `#BakaShrot_MaxMessageSize` (16 MB - 4 KB)
    of UTF-8, refused above (by the client DLL already), so a stored
    message fits in every packet that carries one later: LatestMessage, a
    ReplicateMessages batch of one, without the fields around it going over.
- **Encrypted and authenticated:** see `Design/Cryptography.md`.

## Packet layout

- **A packet is a plain sequence of MessagePack values**, not a map or an
  array, read in order with PB-MessagePack:
  1. `Magic` (integer), always `#BakaShrot_ProtocolMagic` (`0x42534854`,
     "BSHT").
  2. `Version` (integer), always `#BakaShrot_ProtocolVersion` (4:
     attachments; 3: the Hello sealed, a key per connection, everything
     after the ChallengeRequest encrypted, times; 2 had topics and nodes by
     name, in plain text; 1 had ids only).
  3. `PacketType` (integer), one of the ids below.
  4. The packet's own fields, in the order listed.
- **Encodings:** strings are UTF-8 MessagePack strings, the nonce a
  MessagePack binary.
- **Decoding:** `BakaShrot_ReadPacketBase()` checks the magic, the version
  and that the type is positive. Each `_Decode` then checks it's **its own**
  type, and checks every field's MessagePack type, read error and range.
  Anything wrong means the whole packet is rejected.
- **Not checked:** trailing data after the last field is ignored.

### Topics and nodes: names and ids

- **Each server has its own ids** (0-65535) for topics and nodes, and the
  config can name them (`[BakaShrot.Topics]`, `[BakaShrot.Nodes]`). The
  **name is what's shared**: "logs" can be 1 on one server and 200 on
  another.
- **A ref** is how a packet gives a topic or node: a name (1-64 of
  `A-Z a-z 0-9 _ . -`, not only digits, any case), or an id in digits,
  which always means that id on the receiving server. An unnamed topic or
  node goes by its id in digits.
- **Clients** give refs in their requests, the server resolves them in its
  own names. **Servers** send names to each other, never rely on ids
  matching: the sync state maps the sender's ids to names, and the batches
  carry names.
- **Only what's named on both servers replicates.** Unnamed topics and
  nodes, and names the other server doesn't have, are dropped, unless the
  receiver's `AcceptTopics` / `AcceptNodes` for that peer has a wildcard
  (`*`, `sensors.*`) matching it: it's then added there with an id of its
  own. The sync state lists every name the receiver takes, and its
  wildcards, so the sender only sends those and nothing gets refused at
  every check-in.

### Packet types

Direction: **C** client, **S** server, **P** peer, a server acting as a client
over its own link to another server.

| Id | Packet | Dir | Fields, in order | Answered by |
|---|---|---|---|---|
| 0 | None | | Never valid. | |
| 1-3 | | | Used by the removed `AuthenticationPacket.pbi`, don't reuse. | |
| 4 | ClientHello | C→S | `ClientTopic` str (ref), `ClientNode` str (ref), `ClientPubKeyB64` str, `ClientSessionKey` bin (32 bytes). Sent sealed for the server's key | ChallengeRequest |
| 5 | ChallengeRequest | S→C | `ChallengeB64` str (32 bytes), `Nonce` bin (32 bytes), `ServerSessionKey` bin (32 bytes), `ServerSignature` bin (64 bytes, of the transcript). The last packet in plain text | ChallengeResponse |
| 6 | ChallengeResponse | C→S | `ChallengeResponseB64` str (64-byte signature of the transcript), `Nonce` bin (32 bytes) | AuthAccepted |
| 7 | AuthAccepted | S→C | None. | |
| 8 | PushMessage | C→S | `Topic` str (ref, "" for the client's own), `JsonData` str, `UploadId` int (its attachment, 0 for none) | MessagePushed / RequestRefused |
| 9 | MessagePushed | S→C | `MessageId` int ≥ 1 | |
| 10 | GetLatestMessage | C→S | `Topic` str (ref), `Node` str (ref) | LatestMessage / RequestRefused |
| 11 | LatestMessage | S→C | `TopicId`, `NodeId` int 0-65535 (the server's), `TopicName`, `NodeName` str (names, or ids in digits), `MessageId` int ≥ 1, `PushedAt` int (time, see below), `JsonData` str, `AttachmentSize` int (0 for none), `AttachmentReady` int 0/1 | |
| 12 | RequestRefused | S→C | `Reason` str, for logs and humans | |
| 13 | SyncStateRequest | P→S | None. | SyncState / RequestRefused |
| 14 | SyncState | S→P | `TopicCount` int, then each topic's `Id` int and `Name` str (the named topics S takes from P); `NodeCount` int, then each node's `Id` and `Name` (the named nodes S takes from P); `TopicPatternCount` int, then each pattern str; `NodePatternCount` int, then each pattern str (S's wildcards for P, `*` included); `PairCount` int, then each pair's `TopicId`, `NodeId`, `MessageId`. Ids are S's own, names are never digits | |
| 15 | ReplicateMessages | P→S | `Topic` str, `Node` str (names, never digits), `Count` int 1-10000, then each message's `MessageId` int (≥ 1, strictly increasing), `PushedAt` int (as stored, from its origin), `JsonData` str, `AttachmentSize` int (0 for none) and `AttachmentSha256` bin (32 bytes, empty for none) | MessagePushed (last id) / RequestRefused |
| 16 | QueryRequest | C→S | `Sql` str | QueryResult / RequestRefused |
| 17 | QueryResult | S→C | `JsonResult` str: `{"columns":[...],"rows":[[...],...]}`, every value a string or null | |
| 18 | ResolveName | C→S | `Kind` int (1 topic, 2 node), `Ref` str | NameResolved / RequestRefused |
| 19 | NameResolved | S→C | `Kind` int, `Id` int 0-65535 (the server's), `Name` str ("" if unnamed) | |
| 20 | ListNames | C→S | `Kind` int (1 topics, 2 nodes) | NamesList |
| 21 | NamesList | S→C | `Kind` int, `Truncated` int 0/1, `Count` int, then each entry's `Id` int, `Name` str ("" if unnamed), `Origin` str ("config", "id") | |
| 22 | GetMessages | C→S | `Topic` str (ref), `Node` str (ref), `AfterMessageId` int ≥ 0, `Limit` int 1-10000 | Messages / RequestRefused |
| 23 | Messages | S→C | `TopicId`, `NodeId` int 0-65535 (the server's), `TopicName`, `NodeName` str (names, or ids in digits), `More` int 0/1, `Count` int 0-10000, then each message's `MessageId` int (≥ 1, strictly increasing, above `AfterMessageId`), `PushedAt` int, `JsonData` str, `AttachmentSize` int (0 for none) and `AttachmentReady` int 0/1 | |
| 24 | UploadStart | C→S | `Topic` str (ref, "" for the client's own), `Size` int 1-MaxAttachmentSize, `Sha256` bin (32 bytes) | UploadStarted / RequestRefused |
| 25 | UploadStarted | S→C | `UploadId` int ≥ 1, `ChunkSize` int (1 MB) | |
| 26 | UploadChunk | C→S | `UploadId` int, `ChunkIndex` int ≥ 0 (the next one), `Data` bin (1 MB, the last one what's left) | ChunkStored / RequestRefused |
| 27 | ChunkStored | S→C, S→P | `Received` int (bytes so far), `Complete` int 0/1 (all of it, SHA-256 checked) | |
| 28 | GetAttachment | C→S | `Topic`, `Node` str (refs), `MessageId` int ≥ 1, `ChunkIndex` int ≥ 0 | AttachmentChunk / RequestRefused |
| 29 | AttachmentChunk | S→C | `TopicId`, `NodeId` int (the server's), `MessageId` int, `Size` int, `Sha256` bin (32 bytes), `ChunkIndex` int, `Data` bin | |
| 30 | MissingAttachmentsRequest | P→S | None. | MissingAttachments / RequestRefused |
| 31 | MissingAttachments | S→P | `Count` int 0-256, then each one's `Topic`, `Node` str (names), `MessageId` int, `NextChunk` int | |
| 32 | ReplicateAttachmentChunk | P→S | `Topic`, `Node` str (names), `MessageId` int, `ChunkIndex` int (the next one), `Data` bin | ChunkStored / RequestRefused |

**Attachments** (24-32, and the attachment fields): see
`Design/Attachments.md`. At most one per message, in parts of 1 MB, checked
with their SHA-256, replicated after their message.

**Times** (`PushedAt`): milliseconds since 1970-01-01 00:00:00 UTC, 1 to
`#BakaShrot_MaxTimestamp` (9999-12-31), anything else aborts. A message is
stamped by the server it's pushed to, when the push arrives (its clock, not
the client's), and keeps that time on every server it's replicated to.

## Rules

- **One request at a time.** A client sends one request and waits for its
  single answer before the next one.
- **Refuse or abort:**
  - **Refuse** (RequestRefused, the connection stays open) for things that
    are valid but not allowed: permissions, no message found, too big,
    a failed query, a regular client sending replication packets.
  - **Abort** (the connection is closed) for anything malformed or out of
    order: an invalid frame or packet, a packet type that isn't expected at
    that point, an answer to a different request, a timeout during the
    handshake.
  - The client side applies the same rules to the answers it gets.
- **Timeouts:**
  - The server gives a client `#BakaShrot_Net_HandshakeTimeout` (10 s) per
    handshake step, then waits for requests forever.
  - The client side (`Outbound.pbi`) waits `#BakaShrot_Outbound_Timeout`
    (10 s) for each answer.
- **The identity is fixed by the handshake.** Requests never carry who sends
  them; the server uses the authenticated topic and node. A push picks its
  topic, never its node.

## Flows

### Handshake (every connection)

```
        client: knows the server's Ed25519 public key (ServerPublicKey),
        makes a key pair for this connection
C -> S  ClientHello         identity (topic and node refs) + Base64 public key
                            + the public half of the client's pair,
                            sealed for the server's public key
        server: opens it (or aborts: not for this server), the refs must
        resolve to its ids, the key must decode to 32 bytes, and one
        [BakaShrot.Client.<name>] must list both this key and this identity
S -> C  ChallengeRequest    fresh random challenge + nonce, the public half of
                            the server's pair, and the server's signature of
                            the transcript (in plain text)
        client: the signature checks out with ServerPublicKey (or aborts)
        both: the connection's keys, from both pairs (crypto_kx), the
        pairs' secrets wiped; everything from here on is encrypted
C -> S  ChallengeResponse   the client's signature of the transcript, nonce echoed
        server: nonce == the one issued, signature valid for the Hello's key
S -> C  AuthAccepted        status -> Authenticated
```

The transcript both sign (`BakaShrot_HandshakeTranscript`, 208 bytes):
a 16-byte label (`"BakaShrot3 srv"` or `"BakaShrot3 cli"`, zero-padded),
the client's and the server's Ed25519 public keys, the client's and the
server's session halves, the challenge, the nonce.

- The status moves through New → Challenged → Authenticated, or Aborted /
  Disconnected (`BakaShrot_ConnectionStatuses`).
- When authenticating, the server also records two things for the
  connection:
  - Its **permissions**, from the matching client section: `AllowRead`,
    `AllowWrite`, `AllowQuery`, and the `PushTopics` / `ReadTopics` filters
    (default: the topics of its `Identities`).
  - Whether it's a **peer**: its key and identity match a
    `[BakaShrot.Peer.<name>]`, and then its `AcceptTopics`.

### Client requests

```
PushMessage(t, json)       AllowWrite, t in PushTopics ("" = own topic), at most
                           #BakaShrot_MaxMessageSize. JSON or not: stored as
                           is, SQLite flags it in is_json
                           -> stored under t and the authenticated node with the
                           next message id, stamped with now (pushed_at)
                           -> MessagePushed(id)
GetLatestMessage(t, n)     AllowRead, t in ReadTopics -> LatestMessage
GetMessages(t, n, after,   AllowRead, t in ReadTopics -> Messages: those above
            limit)         after, in id order, at most limit, fewer once they
                           reach ~1 MB (#BakaShrot_MessagesBatchBytes, a
                           bigger one alone). None isn't a refusal. More = 1
                           if others follow: ask again after the last id
ResolveName(kind, ref)     topics: in PushTopics or ReadTopics, or AllowQuery
                           -> NameResolved(id, name)
ListNames(kind)            topics: those in PushTopics or ReadTopics, all with
                           AllowQuery -> NamesList(entries)
QueryRequest(sql)          AllowQuery -> QueryResult
```

**Raw queries** (`RunReadOnlyQuery()` in `Server/Storage/Storage.pbi`) are kept
read-only by three things:
1. The SQL must start with `SELECT` or `WITH`.
2. It runs on its own fresh connection with `PRAGMA query_only = ON`. Writes
   fail, and turning the pragma off only affects that throwaway connection.
3. Only the first statement runs.

Statements with no result columns are refused, and so are results over
10000 rows or too big for one packet. An error while reading the rows
refuses the whole query with SQLite's message, never a partial or empty
result: JSON functions over a row that isn't JSON give "malformed JSON",
add `is_json = 1` to the WHERE (or `CASE WHEN is_json THEN ... END`). PureBasic reports no column types for
SQLite, so values come back as strings.

### Replication (between servers)

Each server opens its own link to every `[BakaShrot.Peer.<name>]`,
authenticates as itself (the peer must list it as a client), and retries
every `PeerRetryDelay` seconds when that fails or the link drops. On its own
link, every `PeerSyncInterval` seconds, starting right away:

```
P -> S  SyncStateRequest
S -> P  SyncState           every name S takes from P (its AcceptTopics and
                            AcceptNodes for P), their wildcards, and
                            MAX(message_id) for each topic/node of those, in
                            S's ids
        P: compares with its own state (GetSyncState()), matching by name,
           drops what's unnamed on its side, or neither listed by S nor
           matching one of S's wildcards (BakaShrot_Names_NoteDropped(), a
           no-op for now), and for every pair in its SendTopics and
           SendNodes for S that S is behind on (0 for a name S doesn't have
           yet):
P -> S  ReplicateMessages   the topic and node names, the next missing messages
                            of that pair, in id order, with their original
                            message ids and pushed_at: up to PeerBatchSize of them, cut short
                            at about 64 KB (a bigger message goes alone)
        S: resolves the names to its own ids, adds the ones a wildcard took,
           refuses what it doesn't take (only if its config changed since
           its sync state), see Server/Storage/Names.pbi
S -> P  MessagePushed(id)   the batch stored in one transaction with
                            INSERT OR IGNORE, the last id echoed
        ... until caught up, or the first refusal for that pair
        then the attachments of the messages S now has:
P -> S  MissingAttachmentsRequest
S -> P  MissingAttachments  what S lacks, among what it takes from P
P -> S  ReplicateAttachmentChunk ... -> S -> P ChunkStored, per part
                            (Design/Attachments.md)
```

- **Batch size:** `PeerBatchSize` is set on the sending side, in
  `[BakaShrot.Server]` (default 100, clamped to 1-10000).
- **Size check:** the sender estimates a batch's size with
  `#BakaShrot_ReplicateBatchOverhead` + `#BakaShrot_ReplicateMessageOverhead`
  per message + the JSON's UTF-8 bytes, and stops adding messages before
  it would go over `#BakaShrot_ReplicateBatchBytes` (64 KB, as when that
  was the packet limit: short transactions, little memory). A message
  bigger than that goes in a batch of its own. It also stops reading rows
  from the database once it has about that much (`GetMessagesAfter()`).

- **Both directions** are covered because each server pushes over the link
  it opened itself.
- **Only peers may replicate:** a regular client sending a SyncStateRequest
  or ReplicateMessages is refused with `Only peers can replicate`.
- **Unexpected packets:** a packet on a link outside a check-in drops the
  link.
- **Retention:** each server deletes a topic's messages past its own
  `[BakaShrot.Retention]` max age (`Server/Storage/Retention.pbi`), by their
  pushed_at. The sync state comes from `node_heads`, which deleting leaves
  alone: a server still says it has what it deleted, so peers don't send it
  again. What a peer sends already past this server's max age isn't
  stored, but counts as received the same way (still acknowledged). A
  peer that links later only gets what the others still have.

## Code conventions

- **Encode:** `BakaShrot_<Name>Packet_Encode(*Struct, *OutSize.Integer)` sets
  the base fields itself, and returns a new buffer (the caller frees it with
  `FreeMemory`) or 0.
- **Decode:** `BakaShrot_<Name>Packet_Decode(*MsgPackData)` returns a new
  struct (the caller frees it with `FreeStructure`) or 0. It reads a view
  made with `MsgPackWrapMsgBuffer()`, which the caller frees with
  `MsgPackFree(*View, #False)`.
- **Linear code:** each field is written or read top to bottom: check its
  type, read it, check the error, check its range. No loops, except for
  lists such as SyncState's.
- **Which decoder to use:** `BakaShrot_GetPacketType()` reads a received
  packet's type, so a handler can pick the right `_Decode`.

## Adding a packet

1. Add its id to `BakaShrot_PacketTypes` in `Commons/Networking/Packets.pbi`.
   Never reuse an id.
2. Add `Commons/Networking/Packets/<Name>Packet.pbi`, with its structure
   (`Extends BakaShrot_PacketBase`), `_Encode` and `_Decode`, following an
   existing one.
3. Include it from `Commons/Networking/Connections.pbi`, and add it to the
   flow comment at the top of that file.
4. **Server side:** handle it in `BakaShrot_NetClient_HandleRequest()`
   (`Server/Networking/Networking.pbi`), checking the permission or role
   first.
5. **Client side:** add a `<Name>String()` procedure to the DLL with its
   `A`/`W` exports if it takes strings, a prototype in
   `BakaShrot_Client_Prototypes.pbi`, and a tool if useful.
6. Update this document's packet table and flows.
