# Suggestions, not done yet

Improvements that came out of the 2026-11-07 benchmarks
(`Tests/Bench/Results-2026-11-07.md`), kept aside on purpose. The first two
are bigger changes, worth it when the use case needs them, the rest are
smaller.

## 1. Several pushes in flight per connection

**Today:** a client sends a `PushMessage`, waits for its `MessagePushed`,
then sends the next. One node can push at most once per round trip:

| Round trip | Most pushes/s per node |
|---|---|
| localhost, now | ~2,000-3,000 |
| LAN, 0.5 ms | ~2,000 |
| WAN, 50 ms | ~20 |

The server side doesn't care much, it groups pushes from every connection
anyway. This is about one node, or few nodes, far from their server.

**What it entails:**

- **Protocol.** Let a client send up to W pushes before the first answer.
  TCP and the one thread per connection already keep them in order, and the
  answers come back in the same order, so the Nth answer belongs to the Nth
  push. Still, add a `RequestId` (client-chosen, echoed in `MessagePushed`
  and `RequestRefused`) so a client can match answers without counting, and
  so a desync is detectable. Old clients send no `RequestId` and keep
  working one at a time. See `Design/Packets.md` for how to add a field.
- **Server inbox.** It holds at most two of the biggest packets
  (`BakaShrot_Inbox_MaxSize()`), anything more aborts the connection as
  "sent too much data". Since big packets (2026-11-08) that's ~32 MB once
  authenticated, plenty for a window of small pushes, but a window of big
  ones still needs backpressure: stop reading that client's socket while its inbox is full,
  so TCP slows it down. PureBasic's `NetworkServerEvent()` keeps reporting
  data that isn't read, so backpressure means the listener has to skip that
  client's events without spinning: easiest is a per-client "full" flag,
  with the listener not calling `ReceiveNetworkData()` for it and leaving
  it out of its `select()` set until the client thread drains its inbox.
- **Server thread.** Take every complete packet in the inbox, queue all the
  pushes in the writer at once (`BakaShrot_Storage_Queue`), then send the
  answers. One connection then fills a whole group commit by itself.
- **Client DLL.** Keep `BakaShrot_PushMessage()` as is (synchronous, W=1).
  Add an asynchronous variant for those who want it, without callbacks
  since the DLL is used from other languages:
  `BakaShrot_PushMessageAsync(Json)` returns a local sequence number,
  `BakaShrot_GetPushResult(Sequence)` / `BakaShrot_WaitPushes()` collect the
  ids or the refusals. The DLL holds at most W unanswered pushes, the next
  call waits for room.
- **Semantics.** Each push is still independent: a refused one doesn't stop
  the next ones, the caller gets one result per push. Ids are still handed
  out in send order per node.
- **Bench.** `BenchClient` gets a window per pusher, to measure W = 1, 4,
  16, ideally with a simulated latency (or the servers on another machine).

**Effort:** medium. Packets, DLL API, the server's inbox and thread loop.
The inbox backpressure is the delicate part.

## 2. Replication: windowed batches, several sockets per link, check-ins on demand

**Today,** per peer link: one connection, a check-in every
`PeerSyncInterval` (5 s) or so, then for each topic/node id the peer is
behind on, one batch of up to `PeerBatchSize` messages at a time, waiting
for its acknowledgement before the next, one pair after the other. The
benchmarks show it keeps up (the hub relays ~25,000+ msg/s), but the lag is
the check-in wait: 4-10 s of pushes, two check-ins from leaf to leaf.

**What it entails, cheapest first:**

1. **Check-ins on demand.** The writer signals (`Commons/Threading/Signal.pbi`)
   when it committed something, and the link threads check in as soon as
   there's something new, at most every `PeerMinSyncInterval` (say 100
   ms), and still every `PeerSyncInterval` when idle. Cheap since the sync
   state is now read from `node_heads`. Lowers the lag from seconds to
   about the minimum interval plus the relay through the hub. Biggest gain
   for the least work.
2. **A window of batches.** Send up to W batches before waiting for the
   first acknowledgement, acknowledged in order. On a refusal, stop, and the
   next check-in starts again after the last acknowledged one.
   - **Needed first: the receiver must refuse a gap.** Today a batch is
     stored whatever its first id, with `INSERT OR IGNORE`. With a window,
     batch 2 could be stored after batch 1 was refused, leaving a gap that
     the max-only sync state never repairs (`ReplicationIssues.md` #5).
     Refuse a batch whose first id isn't the pair's head + 1, which
     `node_heads` (or the writer's id cache) makes a cheap check.
   - The same inbox limit as above: two packets. A peer connection needs a
     bigger inbox, or the backpressure.
3. **Several sockets per link.** `PeerConnections = N` in the peer's
   section: N connections, N threads on both ends, each one checking in and
   catching up its share of the topic/node ids (for example
   `(TopicId * 65536 + NodeId) % N`). A pair always goes over the same
   socket, which keeps its messages in order. Catch-ups of different pairs
   then run in parallel instead of one after the other. On the receiving
   side, the batches of the N threads queue on the write mutex: they could
   join the pushes' group commit (one transaction for whatever batches and
   pushes are waiting) instead of one transaction each.
4. **One connection for both directions** (`ReplicationIssues.md` #8), if
   the number of connections ever matters.

**Effort:** 1 is small, 2 is medium (mostly the gap check and the inbox), 3
is medium (config, threads, partitioning), 4 is larger (both ends of the
protocol change).

## 3. Smaller ones

- **Decide on `synchronous = NORMAL`** (`#BakaShrot_Storage_Synchronous`):
  the last commits before a power loss or an OS crash can be lost, and their
  ids handed out again (drift). With group commit, `FULL` costs one sync per
  transaction, not per push, so it may cost much less than it used to: worth
  one benchmark run before deciding.
- **`Build.ps1`:** the compiler path and `-Compiler` are fixed (2026-11-07),
  but the `Libs\` zips for libsodium and SQLite are gone: it only works while
  the extracted DLLs are still in `Libs\*d`.
- **Benchmark on two machines:** the servers on one, `BenchClient` on the
  other. Flat out, the load generator uses ~85 % of a core on the same
  machine, and the servers compete with it for the CPU and the disk.
- **The WAL at full speed:** flat out, each server writes ~25,000 WAL
  frames/s, and the checkpoints can't keep it small, so the writer falls
  back to checkpointing by itself past `#BakaShrot_Storage_WalBackstopFrames`
  (the worst push goes up to ~0.7 s). A bigger page size, or fewer indexes
  (is `idx_data_message_id` needed?), would write fewer pages per push.
- **Full-table JSON queries** grow with the data (~0.45 ms per 1,000 rows).
  If some JSON field gets queried often, a generated column with an index
  on it (like the `msg_type` noted in `db_schema_v4.dbml`) makes it a lookup.
