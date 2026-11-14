# Attachments

A message can have **one attachment**: any bytes (a file, a photo, a dump),
of any size up to the server's `MaxAttachmentSize` (default 1 GB, at most
1 TB). Most messages have none. The message's JSON can say what it is: the
attachment itself has no name or type, only its size and SHA-256.

Protocol version 4. Code: `Server/Storage/Attachments.pbi` (storage),
`Server/Networking/Networking.pbi` (requests), `Server/Networking/Peers.pbi`
(replication), `Client/BakaShrot_Client.pbi` (DLL).

## The rules

- **Sent and stored in parts** of 1 MB (`#BakaShrot_AttachmentChunkSize`, the
  last one what's left), one request each: neither end ever holds a whole
  attachment in memory (a 512 MB one: the server peaked at 15 MB).
- **Checked with its SHA-256**, given before the first part: the server
  checks it once all parts are in (uploads and replicated ones alike), the
  client when it reads one back.
- **A message is only stored once all of its attachment is.** The client
  uploads it first, then pushes the message with the upload's id: readers
  never see a message whose attachment is missing on the server it was
  pushed to. Messages stay immutable.
- **Replicated after the messages**, separately: a peer gets the message
  first (with the attachment's size and SHA-256), then its data once the
  messages are caught up. So on the other servers, a message can be there
  before its attachment: `AttachmentReady` tells.
- **Deleted with its message** (the retention): its parts go a few at a
  time, in the background.

## Pushing one

```
C -> S  UploadStart(topic, size, sha256)    same permissions as pushing to that
                                            topic, size <= MaxAttachmentSize
S -> C  UploadStarted(upload id, 1 MB)
C -> S  UploadChunk(upload id, 0, data)     in order, each the right size
S -> C  ChunkStored(received, complete 0)
        ...
C -> S  UploadChunk(upload id, last, data)
        server: reads all of it back, checks the SHA-256 (or drops it, refused)
S -> C  ChunkStored(received = size, complete 1)
C -> S  PushMessage(topic, json, upload id)
        server: the upload must be this client's (its node), for that topic,
        complete: the message and its attachment are stored together
S -> C  MessagePushed(id)
```

- An upload belongs to the client's node and the topic it was started for.
- One not pushed within `UploadTimeout` seconds (default 3600) is deleted.
- A refused part doesn't drop the upload; a SHA-256 mismatch does.
- The DLL does all of it in `BakaShrot_PushMessageWithFile()` /
  `_WithData()`; it reads a file twice (the SHA-256 first).

## Reading one

```
C -> S  GetAttachment(topic, node, message id, part)   same permissions as reading
S -> C  AttachmentChunk(ids, message id, size, sha256, part, data)
```

Any part, in any order (the DLL reads them in order). Refused if the
message has none, or if it isn't all on this server yet (replicated after
its message), or isn't kept here (bigger than this server's
`MaxAttachmentSize`).

## Replicating

On its link to a peer, at every check-in, once the messages are sent
(`Design/Packets.md`, Replication):

```
P -> S  MissingAttachmentsRequest
S -> P  MissingAttachments([(topic, node, message id, next part)])
                                   up to 256 attachments of messages S has,
                                   from what it takes from P, not all here
        P: for each one it has, all of it, and sends S (SendTopics/SendNodes):
P -> S  ReplicateAttachmentChunk(topic, node, message id, part, data)
S -> P  ChunkStored(received, complete)
        ... from the part S asked for: resumes after a dropped link
        S: once all of it is in, checks the SHA-256 its message came with:
        ready, or dropped and asked for again from the start
```

- A server relays what it has: an attachment that isn't on P either is
  skipped, S asks again at the next check-in, maybe of another peer.
- An attachment bigger than S's `MaxAttachmentSize` is marked not kept
  when its message arrives: S never asks for it.
- A message skipped on arrival (past S's max age) has no attachment row:
  never asked for either.

## Storage (schema v7, `db_schema_v7.dbml`)

| Table | What |
|---|---|
| `attachments` | A message's: size, SHA-256, its blob once any of it is here, state: 0 missing, 1 receiving, 2 ready, 3 not kept. |
| `blobs` | The data of one attachment: whose (topic, node), size, SHA-256, bytes received, state: 0 receiving, 1 complete (an upload waiting for its message), 2 attached, 3 to delete. |
| `blob_chunks` | Its parts, 1 MB each, by (blob, index). |

- Triggers: deleting a message deletes its `attachments` row, which marks
  its blob to delete. The retention thread (`Retention.pbi`) deletes those
  parts 32 at a time, along with uploads past `UploadTimeout`, every
  `RetentionInterval` seconds, retention rules or not.
- Parts are written through the writer (each one its own transaction), read
  on each thread's own connection.
- SQLite reuses the freed pages; `vacuum` gives the space back to the disk.

## In the clients

| | DLL | Python | Tools |
|---|---|---|---|
| Push with one | `BakaShrot_PushMessageWithFile(Topic, Json, Path)`, `_WithData(Topic, Json, *Data, Size)` | `push(data, topic, attachment=bytes or path)` | `PushMessage -a <File>` |
| Does a message have one | `BakaShrot_GetMessageAttachmentSize()`, `BakaShrot_IsMessageAttachmentReady()` | `Message.attachment_size`, `.attachment_ready` | `GetLatestMessage` prints it |
| Read one | `BakaShrot_SaveAttachment(Topic, Node, Id, Path)`, `_LoadAttachment()` + `_GetAttachmentData()` | `save_attachment()`, `get_attachment()` | `GetAttachment <Topic> <Node> <Id> <OutFile>` |

## Speed

On one machine (i5-13500, localhost, PB 5.73): 5 MB up in ~80 ms and down
in ~65 ms through the tools; 512 MB up in 8.5 s (SHA-256 on both ends
included) and down in 3.9 s. One part per round trip: over a slow link,
latency adds up (1000 round trips per GB).

## Tested

- `Tests/Attachments-Test.ps1` (39 checks, two servers, ports 12410-12411):
  one part, several, an exact multiple, one byte; none; replicated
  identical; not kept past the other server's limit; too big to push;
  deleted with its message, parts included.
- `Tests/AttachmentEdges-Test.ps1` (51 checks, ports 12413-12414), with a
  raw protocol client (`Tests/AttachmentEdgeClient.pb`) for what the DLL
  never sends:
  - a wrong SHA-256: refused at the last part, the upload dropped, pushing
    with it refused;
  - parts out of order, of the wrong size, repeated, past the end, from
    another client: refused, the upload goes on;
  - someone else's upload, the wrong topic, attached twice, an unknown id,
    too big, a topic the client may not push to or read: refused, the
    connection stays up;
  - uploads left behind (half sent, complete but never pushed): kept within
    `UploadTimeout`, deleted past it (10.7 s for 10), then refused;
  - replication resuming: the receiver killed at ~45 MB of 400 MB,
    restarted: what it had committed is still there, the sender goes on
    from that part, the result is identical;
  - a byte flipped in the sender's database: the client refuses it
    (SHA-256), the peer drops it, serves nothing, and asks again.
- `check_bakashrot.py` (Python): bytes and files, round trips, refusals.

## Not done

- **Resuming an upload** after a dropped connection: the parts are kept
  until `UploadTimeout`, but the DLL starts over. (Replication resumes.)
- **Several parts in flight**, for links with high latency.
- **A corrupted copy is sent again and again.** If a server's own stored
  copy is damaged (disk, a bug), its peers drop it at every check-in and
  ask again: the whole attachment is re-sent every `PeerSyncInterval`
  (6 times in 6 s in the test). The server itself never notices, it serves
  the damaged parts to clients too (they refuse them, by their SHA-256).
  Fix: when a peer answers "doesn't match", the sender checks its own copy
  (`HashStorageBlob()`); if it's damaged, it marks it missing, so it gets a
  good one back from another peer, and stops sending it. Details, and how
  the test should change: `Notes.md`, open item 3.
- **No deduplication**: the same file attached twice is stored twice.
