# Replication - known issues

How it works now: see the top of `Server/Networking/Peers.pbi`. In short, every
`PeerSyncInterval` seconds a server asks each linked peer for its sync state
(the highest message id per topic/node id), and sends it the messages it's
behind on, with their original ids. Each peer does the same over its own link.

Issues below are roughly ordered by how much they matter.

## 1. Drift: the same message id with different content (accepted for now)

**When:** the same topic/node id is written to on two servers, for example
when a client identity is registered on both and pushes to each while they
can't reach each other. This is a configuration issue that """shouldn't"""
happen in real use.

**What happens:** both servers are at `1:2#1`, the link drops, then:

| | Server A | Server B |
|---|---|---|
| Before | 1 | 1 |
| Client pushes to both | 1, 2a, 3a | 1, 2b |
| Once relinked | A is ahead, sends `#3a` | B isn't ahead, sends nothing |
| Result | 1, 2a, 3a | 1, 2b, 3a |

- Only the max id is compared, so `#2a` vs `#2b` is never noticed.
- If both had sent the same id, `INSERT OR IGNORE` would keep the local one
  and silently drop the other.
- The servers end up partially resynced, with a mixed history for that pair.

**Possible fix, maybe someday:** authoritative servers. Each topic/node id
gets one server that's allowed to assign its message ids, and the others only
replicate it. Pushes for a pair not owned locally are refused, or forwarded.
A cheaper half-measure: detect drift by also comparing a hash of each
message (or of a range of them), and at least log it.

## 2. ~~The peer isn't verified~~ (fixed 2026-11-08, protocol 3)

It was: the handshake only proved the connecting side, the `PublicKey` in a
`[BakaShrot.Peer.<name>]` section was never checked, so whatever answered on
the peer's address got this server's messages pushed to it.

Now a link's Hello is sealed for the peer section's `PublicKey`, and the
peer must sign the handshake with the matching private key, or the link
fails; the link is encrypted (`Design/Cryptography.md`). A missing or
invalid `PublicKey` stops the server at start. The section's `Topic` and
`Node` are still only checked when the peer links to here.

## 3. Peers are trusted completely

A connection that authenticated with a peer's identity and key can replicate
messages for any topic/node id the receiver replicates, with any content.
Messages carry no proof of who first wrote them, so a compromised or buggy
peer can inject or overwrite history for nodes it doesn't own. (Overwrite
only in the sense of issue 1: it can't replace an id that's already stored.)

**Fix:** sign each message with its originating node's key when it's first
stored, keep the signature with it, and verify it on replication. That needs
every server to know the public key of every node it replicates.

## 4. Database concurrency (fixed)

**Fixed 2026-11-06:** every link thread and client thread now has its own
database connection, see `Design/StorageConcurrency.md`. Kept below for the
record.

The link threads used to read the database with the same unlocked handle as
the client threads.

**Seen happening** (2026-11-06, benchmark with `PeerBatchSize = 1`):
1. Server 1's link thread was reading the messages to send.
2. At the same time, server 1's thread for server 2's incoming link was
   reading the sync state for server 2's check-in.
3. Both went through the same handle, so a read came back empty while
   messages were still left. Server 1 logged
   `Sent 1424 messages ... it had up to #0` for a backlog of 5000, and the
   check-in ended there.

The next check-in picked up where it stopped, so nothing was lost here. But
the same collision during a write could have stored wrong data.

## 5. Gaps aren't detected

Only `MAX(message_id)` is compared. If a server has `1, 2, 5` for a pair (say
`3` and `4` were refused midway through a check-in), it reports `5` and never
gets `3` and `4`. Messages are sent in order and the sending stops at the
first refusal, so this needs something unusual, but nothing repairs it.

**Fix:** send a count with the max (`COUNT(*) = MAX` means no gaps), and fall
back to comparing id ranges when they differ.

## 6. Speed: batched since, the per-batch overhead remains

**Benchmarks** (2026-11-06, both servers on localhost, PureBasic 5.73 x64,
SQLite 3.54.1). The same 5000 messages of ~28 bytes and 1000 of ~4 KB, sent
from scratch:

| Version | 5000 small | 1000 x 4 KB |
|---|---|---|
| One message per packet (before batching) | 63.6 s, ~79 msg/s | 12.2 s, ~82 msg/s |
| `PeerBatchSize = 1` | ~69-87 msg/s | 12.0 s, ~83 msg/s |
| `PeerBatchSize = 100` (default) | 0.67 s, ~7500 msg/s | 0.94 s, ~1070 msg/s, ~4.3 MB/s |
| `PeerBatchSize = 1000` | 0.11 s, ~45000 msg/s | 1.48 s, ~680 msg/s |

**Where the per-batch time goes,** measured before batching:

- **~3.8 ms is SQLite**, one transaction synced to disk. The same inserts
  inside one transaction take 0.014 ms each (5000 in 71 ms). Hence one
  transaction per batch.
- **The rest is polling.** Both ends wait for packets in `Delay(5)` loops
  (5.5 ms each on Windows, `Delay(1)` is 1.6 ms), and each batch waits for
  its acknowledgement before the next one, so it pays a few of those per
  round trip.

**Big messages** don't gain from batch sizes over ~16: only that many 4 KB
messages fit in a ~64 KB batch (`#BakaShrot_ReplicateBatchBytes`). Since
2026-11-08 a batch stops reading rows once it has that much, so a big
`PeerBatchSize` no longer reads rows it then can't send.

**Further fixes, if needed:**

1. Keep the rows that didn't fit for the next batch instead of reading them
   again.
2. ~~Wake the waiting thread when data arrives instead of polling with
   `Delay(5)`.~~ Done 2026-11-07: client threads sleep on an event the
   listener sets (`Commons/Threading/Signal.pbi`), the listener and the
   outbound side sleep in `select()` (`Commons/Networking/SocketWait.pbi`).
3. Send the next batch before the previous one is acknowledged (a window).
4. ~~WAL mode~~ Done 2026-11-07, see `Design/StorageConcurrency.md`.

**Since then** (2026-11-07, `Tests/Bench/Bench-Replication.ps1`, 4 servers in
a Y): the hub relays up to ~5700 msg/s of pushes to its leaves without
falling behind, sending at ~38000 msg/s while a catch-up runs. The lag is
now just the check-in wait, 4-6 s of pushes at every load (two check-ins for
leaf to leaf). A shorter `PeerSyncInterval` is what would lower it.

~~**A message that's too big for a batch isn't replicated.**~~ Fixed
2026-11-08: pushes are capped at `#BakaShrot_MaxMessageSize`, 4 KB under the
16 MB packet limit, so one always fits in a batch of its own.

## 7. Sync state size limit

The whole sync state must fit in one packet: 16 MB since 2026-11-08 (was
64 KB, roughly 4000 topic/node pairs), so the counts are what limits it now,
65536 topics, nodes and pairs (`SyncStatePacket.pbi`). The replicated topics are also sent as a list, and
`ReplicatingTopicIds = 0-65535` expands to 65536 entries, which doesn't fit.

**Fix:** send ranges instead of expanded lists, and page the pairs (for
example per topic).

## 8. Two links per pair of servers

With two servers listing each other as peers, there are two connections, and
each one is only used by its opener to push. That's what makes both
directions work, but it doubles the connections and the check-ins. Fine for
now. If it ever matters, one link could carry both directions.

## 9. Messages for topics a server doesn't replicate

The receiver lists the topics it replicates, and the sender only sends
those, so they're never sent. But a batch that arrives for another topic
anyway is refused, and that stops the pair's catch-up for that check-in. It only happens if the two servers disagree about the list
mid-check-in, for example after a config change.

## 10. ~~Replicated messages aren't validated~~

Moot since 2026-11-08: pushed messages aren't checked to be JSON either,
both are stored as is and flagged by `is_json`.
