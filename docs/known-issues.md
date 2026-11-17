# Known issues and ideas

What's known to be wrong or missing, what's left as it is and why, and
ideas for later.

## Threat model

BakaShrot is an **internal tool, on trusted machines and a trusted
network**, not exposed to the internet. So:

- TLS and the certificates are defence in depth: they stop a misconfigured
  client or server from talking to the wrong one and keep data off the
  wire in clear, they aren't holding off attackers.
- The security issues below are low priority unless the deployment
  changes. If it ever faces an untrusted network, start with messages
  signed by their origin and rate limiting connections.
- Correctness, durability and operations matter more: losing or mixing up
  data, or a server that can't run unattended, hurts on day one.

## Known issues

- **One server per node, not checked.** A node's messages are pushed to
  one server; the others get them by replication. A node pushing to two
  servers that replicate makes the same ids with different messages on
  each: only the last id per topic and node is compared, so it's never
  noticed, and a replicated id already stored keeps the local message.
  Fix if that rule ever has to go: one server owns each topic and node's
  ids (the others refuse or forward pushes), or at least compare a hash of
  the messages to log the drift.
- **Gaps in a topic and node's ids aren't detected** on replication (old
  item 6). A server with `1, 2, 5` says 5 and never gets 3 and 4. Batches
  are sent in order and a refusal stops them, so it needs something
  unusual, but nothing repairs it. Fix: send the count with the last id
  (count = last id: no gaps), compare ranges when they differ.
- **The attachments a server lacks:** it reports the 256 oldest at a
  time (`SyncState`). With several peers, ones none of them has can hold
  back newer ones.
- **Peers are trusted with what they replicate:** a server
  in `accept_from` can send any message its roles accept, for any node.
  Messages carry no proof of who first wrote them. Fix: sign each message
  with its node's key when first stored, check it on replication (every
  server then needs every node's public key).
- **Private keys sit in PEM files**, readable by whoever can read them: on
  trusted machines, file permissions are enough.
- **Polling rather than pushed subscriptions;** nothing reconnects by
  itself, on purpose.
- **At least once:** a push whose answer was lost (the server stopped
  between committing and answering) is stored twice if retried. A client
  that minds reads the latest message before retrying.
- **1,048,575 topic and node pairs per database** (2^20 - 1,
  `MAX_STREAMS`, `bakashrot-storage/src/lib.rs`), for all topics
  together, and 2^43 - 1 message ids per pair (`MAX_MESSAGE_ID`): the
  20 and 43 bits of a message's packed key (`storage.md`, "Keys"). Past
  the first, a new pair is refused from anyone, pushed or replicated;
  pairs aren't freed when their messages are deleted. Enough for now
  (the owner, 2026-11-16). Raising it means another key layout, so a
  new schema version.

## Found by reading the code, not reproduced

From a read of the source on 2026-11-15: no test shows any of these yet.
Reproduce one before fixing it, and move it up (or drop it) once known.

- **`sync_interval` over 5 min.** The server dialed closes the idle link
  (`IDLE_TIMEOUT`), so every check-in fails once ("closed the link",
  warned), then the link is dialed again after `retry_delay`. Nothing
  in the config caps `sync_interval`. Left as it is (the owner,
  2026-11-16): replicating every 5 min or more isn't a real use, the
  example config says to keep it under. Fix if needed: cap it under the
  idle timeout, or have an idle link ask its `SyncState` more often.
- **Resuming a big replicated attachment.** Before answering `Continue`,
  the receiver reads back and hashes every part it already has
  (`accept_from.rs`, `replicate_attachment`, `hash_parts`), while the
  sender waits 30 s for that answer (`push_to.rs`, `ANSWER_TIMEOUT`).
  Past what the disk reads and hashes in 30 s (estimated: about 4 GB
  on a hard disk, 15 GB on a SATA SSD, 30-60 GB on NVMe), the link
  drops, and the same happens at every retry. Left as it is (the
  owner, 2026-11-16): attachments over a few GB are excessive for this;
  the example config says so by `max_attachment_size` (1 GiB by
  default). Fix if needed: a wait scaled to the parts already received,
  or the hash's state kept with the attachment.
- **`SyncState` in one packet.** Every head the peer may
  send goes in one frame of 16 MiB at most: with very many topic and
  node pairs (hundreds of thousands) it doesn't fit, the packet can't
  be sent and replication stops. Fix: heads in several packets, or only
  those that changed.
- **Peers with several roles.** `SyncState` lists the union of its
  roles' `accept_topics` and the union of their `accept_nodes`
  (`Permissions::accepted`), while what's taken is each role on its
  own: the sender can offer a topic of one role with a node of another,
  refused (`NotAllowed`), and sent again, a whole batch, at every
  check-in. Fix: the pairs per role in `SyncState`, or the sender
  remembering what was refused.
- **A peer can use up a topic and node's ids.** A replicated message
  may have any id up to the highest (2^43 - 1, `MAX_MESSAGE_ID`), and
  the stream's last id follows it (`batch.rs`, `replicate`). One such
  message from a server in `accept_from`, for any topic and node its
  roles accept, and every later push to that topic by that node is
  refused ("no message id left", `insert_pushed`); it replicates on to
  the other servers. Nothing lowers a last id again. Part of "Peers
  are trusted" above, but one message is enough and a bug can do it.
  Left as it is (the owner, 2026-11-16): no cheap check tells a bad id
  from a real one. Ids jump for good reasons (retention, a server that
  joins late), so "must follow the last id here" or a bound on the jump
  refuses real messages or stops nothing; refusing ids past its own
  for the nodes that push here breaks a node moving to another server
  and back. Fix: messages signed by their node, as above.
- **A pair refused for good is sent again at every check-in**, a whole
  batch each time (`push_to.rs`, `send_messages`: a refusal only
  leaves it for the next check-in): the database's topic and node
  pairs all used, a message id past the last one. Fix: with "Peers
  with several roles" above.
- **Patterns in `push_topics` let clients make topics.** The roles are
  the only lists of topics since 2026-11-16 (`config.md`): a client
  with `push_topics = ["*"]` makes as many topic and node pairs as it
  likes, up to the database's 2^20 - 1, after which no new pair is
  taken from anyone. Listing topics also only shows those with
  messages: a client can't ask what it may push to. Fine for the
  threat model; names in `push_topics` where the set is closed.
- **Whether a node exists can still be probed.** Listing nodes is
  filtered by the roles since 2026-11-16 (`list_nodes`), but
  `GetMessages` answers `UnknownName` for a node without messages
  anywhere and none for one with messages in another topic
  (`reader.rs`, `messages`). Fix: none in both cases.
- **No limits per client.** Any number of connections (each a task and
  its buffers), any amount pushed: an allowed client can fill the disk
  or the server's memory. Fine for the threat model; first thing to
  add if it changes (a cap on connections, a quota per node).
- **A clock set before 1970 while running.** The server refuses to
  start with one (`check_clock`, `bakashrot-server/src/lib.rs`), but
  isn't checked again: set back that far afterwards, pushes are stamped
  `pushed_at` 0 (`now()`), which readers refuse when decoding. Fix if
  ever needed: refuse pushes (`ServerError`) while the clock is before
  1970.
- **A small one:** the client's connect timeout is per socket
  operation, not for the whole connection.

## Ideas for later

Worth it only when a use calls for them:

- **Several pushes in flight per connection.** One request at a time
  (`protocol.md`, "Rules") caps a node at one push per round trip:
  thousands a second on a LAN, about 20 over 50 ms. A client could send
  several before the first answer (answers come back in order; a request
  id to match them), with an asynchronous push in the DLL beside the
  blocking one. The server already groups pushes from every connection.
- **Replication, lower lag:** a link checks in again at once after
  sending, otherwise every `sync_interval`. Next, cheapest first: check
  in as soon as the writer commits something (at most every 100 ms or so);
  send several batches before the first answer (the receiver must then
  refuse a batch that doesn't follow its last id, which also closes the
  gaps above); several connections per link, each topic and node always
  on the same one.
- **Benchmark on two machines:** on one, the load generator and the
  servers compete for the CPU and the disk.
- **A JSON field queried often:** a generated column with an index on it
  turns a full scan into a lookup (`storage.md`, "For later", has the
  other storage ideas).
