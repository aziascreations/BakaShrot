# Known issues and ideas

What's still true of the PureBasic version's notes, for this one. That
version was removed on 2026-11-15; it's in git history up to commit
`68966a8` (`OldSource/Notes.md`, "Open items"; `OldSource/Design/`).

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
- **Peers are trusted with what they replicate** (old item 12): a server
  in `accept_from` can send any message its roles accept, for any node.
  Messages carry no proof of who first wrote them. Fix: sign each message
  with its node's key when first stored, check it on replication (every
  server then needs every node's public key).
- **Private keys sit in PEM files**, readable by whoever can read them: on
  trusted machines, file permissions are enough.
- **One connection per process in the DLL** (old item 10, `revamp.md`,
  "Open questions"): a handle-based API for several. Polling rather than
  pushed subscriptions; nothing reconnects by itself, on purpose.
- **At least once:** a push whose answer was lost (the server stopped
  between committing and answering) is stored twice if retried. A client
  that minds reads the latest message before retrying.

## Ideas for later

From the old benchmarks and suggestions (`OldSource/Design/Suggestions.md`),
worth it only when a use calls for them:

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
