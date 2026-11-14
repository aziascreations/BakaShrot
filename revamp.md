# BakaShrot revamp

Started 2026-11-13: what it should change, what's decided, what's still
open, and the plan. Steps 0 to 10 of the plan are done (the workspace,
`bakashrot-proto`, `bakashrot-pki` and `bakashrot-cert`,
`bakashrot-config`, `bakashrot-storage`, `bakashrot-server` and
`bakashrot-client` answering every request but replication's,
attachments included, the C DLL with its C, PureBasic and Python
bindings, the `bakashrot` tool, retention), see "Plan".

- **Old implementation:** `OldSource/`, PureBasic, protocol 6, schema v8.
  Frozen as the reference: it still builds and passes its suites from there
  (`OldSource/CLAUDE.md`), and its docs describe the behaviour to carry over
  (`OldSource/Notes.md`, `OldSource/Design/`).
- **New implementation:** `Source/`, see `Source/README.md`.

## Why

The old code works and is well tested, but every new need costs a lot in
PureBasic, which has no libraries for it:

- The connections' security is a custom protocol (sealed Hello, key
  exchange, signed transcript, own cipher framing,
  `OldSource/Design/Cryptography.md`), on libsodium.
- The client auth rework needs X.509 certificates: that took writing a DER
  reader/writer and an X.509 layer by hand (`OldSource/Commons/Cryptography/Der.pbi`,
  `X509.pbi`, `OldSource/Design/Certificates.md`), and TLS would still be
  missing.
- Threading traps (lists shared between threads, a listener racing client
  threads, item 21), compiler quirks (5.73's `Goto` out of a `Select`),
  single-pass includes: see `OldSource/CLAUDE.md`, "Traps".

## Decided

1. **Rust**, for the server, the client library and DLL, and the tools: one
   Cargo workspace in `Source/`. Built in the order of "Plan" below.
2. **A C-compatible client DLL**, usable from any language as today: the
   same kind of exports (`BakaShrot_*A/W`, cdecl), the same conventions
   (strings copied into the caller's buffers, the size needed returned,
   `BakaShrot_GetLastError()` and the same error code numbers), so
   `bakashrot.py` (ctypes) and PureBasic apps keep working with few
   changes. Only connecting changes (certificates instead of keys and a
   node), and the exports taking or returning a topic or node id go
   (`BakaShrot_GetLatestMessage(TopicId, NodeId)`, `_SetNodeId()`,
   `_GetMessageTopicId/NodeId()`...): names only on the wire, see below.
   Rules for the DLL:
   - every export wrapped in `catch_unwind`, a panic becomes `Internal`
     (`panic = "unwind"` in the release profile);
   - no memory allocated on one side is freed on the other;
   - synchronous: no async runtime, no threads of its own, so it can be
     unloaded (`BakaShrot_UnloadClient()`) and Windows' loader lock is
     never in the way;
   - the C runtime linked statically on Windows (`+crt-static`), built
     against an old glibc on Linux (manylinux);
   - `W` exports take UTF-16 everywhere (PureBasic's strings; `wchar_t` is
     32 bits on Linux);
   - the toolchain pinned (`rust-toolchain.toml`), a C header generated
     (`cbindgen`).
3. **Identities come from certificates issued by a custom CA**: a client's
   certificate says its name (its node) and its roles. Servers and clients
   trust the CA, not lists of keys.

Also decided (2026-11-13):

- the build order ("Plan"); the protocol crate is `bakashrot-proto`;
  existing crates rather than our own (MessagePack: `rmp-serde`);
- the protocol simplified (`Source/docs/protocol.md`, "What changed"):
  - **names only on the wire**: topics and nodes by name everywhere, each
    server's ids stay in its database (no refs, no `ResolveName`, no ids
    in answers or in the sync state);
  - **packets derived with `serde`**, `[type, [fields...]]`, each packet's
    rules in one `Check`;
  - **26 packets down to 18**: reading the latest is `GetMessages` with no
    `after`, one answer for runs and the latest, the missing attachments
    in the `SyncState`, no echoes in answers;
  - **attachments streamed inside their request**: no upload ids or
    expiry, no request or answer per part.
- **protocol 7's start** (`Source/docs/protocol.md`): ALPN `bakashrot`, not
  versioned; right after TLS each end sends its version (4 bytes) and
  checks the other's, abandoning the connection if they differ (the
  client's error: `VersionMismatch`, 111); then the server's `Welcome`.
- **the server is async, on `tokio`**: a task per connection (cheap, so
  many connections and peers at once stay simple), timers for check-ins
  and retention, clean shutdown; `tokio-rustls` for TLS. Frames by
  `tokio-util`'s codec, configured once in `bakashrot-proto`
  (`frame::codec()`, its `tokio` feature). The DLL stays blocking (std and
  rustls, no runtime), as decided above.
- **TLS 1.3 only, with certificates on both ends, at the strongest settings
  rustls has** (both ends are ours: nothing to negotiate down to). Replaces
  the custom handshake and cipher; no libsodium.
  - Certificates: **ECDSA P-384 with SHA-384** (the strongest rustls
    checks; Ed448 isn't in it).
  - Cipher suite: **TLS13_AES_256_GCM_SHA384** only.
  - Key exchange: **X25519MLKEM768** only, the X25519 + ML-KEM hybrid
    (holds against quantum computers too).
  - Crypto backend: **aws-lc-rs**, the one with ML-KEM (its Windows build
    to check at step 2: it may want CMake and NASM).
  - The client's certificate is encrypted too: watchers still don't learn
    who connects. Peers the same way, one certificate each instead of a
    peer section plus a client section on the other server.
- **The certificate profile:**
  - **one identity extension** of our own, non-critical (rustls refuses
    critical ones it doesn't know): `SEQUENCE { version INTEGER (1), name
    UTF8String, roles SEQUENCE OF UTF8String }`. The name is the node;
    roles are free strings with the name rules, their meaning in the
    server's config. Only the server reads it. Its OID is a placeholder
    for now, see "Open questions" (the UUID arc of `OldSource/` can't be
    used: `rcgen` writes OID parts of 64 bits at most);
  - the name again as the subject's CN, for people (`openssl x509 -text`,
    logs); the server only trusts the extension;
  - extended key usage `clientAuth` for clients, `serverAuth` and
    `clientAuth` for servers (they're clients of their peers);
  - **no host names or IPs**: a server is verified by its certificate: our
    CA's, valid, not revoked, `serverAuth`. Every server certificate has the
    same fixed DNS name, `bakashrot-server` (not a real host), which every
    client asks for: rustls' own verifier then does all the checking;
  - **for later: `AllowedServerNames`**, in a client's config (and for
    the peers a server dials): the server identity names it accepts, any
    of the CA's servers without it (noted 2026-11-13);
  - lifetimes, the tool's defaults: the CA about 10 years, the others
    about 1 year (expired ones then leave the CRL);
  - the CA's key kept off the servers: whoever has it can make any
    identity, peers included.
- **Revocation by a CRL**, signed by the CA, made by the certificate tool
  (`revoke`), dropped in the server's folder:
  - the server checks it at every handshake (rustls does it), watches the
    file (its time and size, every few seconds: works on network shares
    and with editors that replace files), reloads it on a change, and
    drops the connections whose certificate it now revokes;
  - a new file that doesn't verify is refused, the previous one kept and
    the refusal logged; no file means nothing revoked;
  - clients check it too when given one (`client_config()` takes the
    same revocations): a server dialing its peer is a client, so servers
    block each other whichever end dials;
  - revoked by certificate, not by name: each certificate has its own key
    and serial number, so two servers of the same name each have theirs,
    revoked one at a time (`bakashrot-cert issue --file`);
  - optionally, a node blocked by name in the config, whatever certificate
    it has (emergencies, a node taken down).
- **The server's config is TOML** (2026-11-13), `Source/docs/config.md`:
  - `[server]`, `[retention]`, `[replication]`, `[roles.<name>]`; unknown
    keys refused; names only (no ids, pins or ranges);
  - **roles in the certificate, permissions in the config**: a certificate
    may do everything its roles allow, each role on its own; refused when
    none of its roles has a section. A role gives `push_topics`,
    `read_topics`, `query`, and for replication `send_topics`,
    `accept_topics`, `send_nodes`, `accept_nodes`; no `AllowRead/Write`
    (an empty list allows nothing). Changing what a role may do doesn't
    need new certificates;
  - **no peer sections:** peers are roles too (replicating with a server
    whose certificate has a role with `send_topics` / `accept_topics`,
    whichever end dials); the config only lists the addresses it dials
    (`[replication] peers`);
  - **no default topic** (dropped from the protocol too, 2026-11-13): a
    push always names its topic;
  - `[replication] replicated_topics`, optional: the only topics
    replicated at all, whatever the roles say, to filter on edge nodes.
- **Schema v9, not compatible with v8** (2026-11-13): old databases aren't
  opened, their data isn't carried over (the real-life tests start empty).
  `Source/docs/storage.md`:
  - **streams** (a topic and node pair: its id, names, last id) instead of
    `topics`, `nodes` and `node_heads`;
  - **packed keys**: a message's key is `stream_id << 43 | message_id`, one
    B-tree and no index for the messages (an attachment's parts the same
    way); 2^20 - 1 streams, ids up to 2^43 - 1 (`MAX_MESSAGE_ID` lowered to
    it). Hidden from everything but `bakashrot-storage`: its API and the
    `messages` view are by name;
  - **no time index** (measured at 5M messages: it halves the pushes); time
    queries read their streams, an index is a migration away if needed;
  - `attachments` (five states) and `attachment_parts`, uploads inside
    their push; a `metadata` table with `schema_version` for migrations.
- **The server and the client** (2026-11-13), `Source/docs/server.md`:
  - **crates:** `tokio` and `tokio-rustls` on the server, `tracing` for
    its logs; the client blocking (std and `rustls`, no runtime). Named
    `bakashrot-server` (also the program: `bakashrot-server
    <config.toml>`) and `bakashrot-client`;
  - **a certificate with none of its roles in the config** gets
    `RequestRefused` (`NotAllowed`, saying which roles), then the
    connection closes;
  - **timeouts:** 10 s to connect (TLS, versions, welcome), 5 min of
    silence before the server closes, 30 s for an answer (the client);
  - **the writer:** one thread, a queue, group commits; WAL checkpoints on
    a thread of their own.
- **The DLL** (2026-11-13), `Source/docs/client.md`:
  - **connecting:** `BakaShrot_SetCaCertificate()`, `_SetCertificate()`,
    `_SetPrivateKey()`, `_SetCrl()`, each taking PEM text or a file's path;
  - **the old exports that don't fit any more are dropped**, not kept
    failing: the keys and node setters, the id-based ones, the default
    topic's `PushMessage()`;
  - **one connection per process**, as before (handles maybe later);
  - **`client.toml`** (server, ca, certificate, key, crl) replaces
    `client.ini`: Python's `Client.from_file()`, the tools at step 8.
- **The tools** (2026-11-14), `Source/docs/client.md`, "The tools": one
  `bakashrot` program with subcommands (`push`, `latest`, `messages`,
  `query`, `list`) over `bakashrot-client`, `bakashrot-cert` kept apart
  (the CA's key); `-c/--config`, `client.toml` by default; the old tools'
  output; messages and SQL inline, `@file` or `-` (standard input); exit
  codes 0, 1, and 2 for bad arguments.
- **Attachments** (2026-11-14), `Source/docs/server.md` and `client.md`:
  - **the DLL keeps the old six exports**, by names: `PushMessageWithFile`,
    `PushMessageWithData`, `SaveAttachment`, `LoadAttachment` then
    `GetAttachmentData` and `FreeAttachmentData`;
  - **a failed download starts over** (the protocol's `from_part` isn't
    used by clients yet), leaving no file;
  - **the tool:** `push -a <file>`, `attachment <topic> <node> <id>
    <file>`, `latest` saying a message's attachment;
  - **Python:** `push(..., attachment=bytes or a path)`,
    `get_attachment()`, `save_attachment()`;
  - **the SHA-256 through `aws-lc-rs`**, already built for TLS, instead of
    the `sha2` proposed: no other crate, and faster.
- **Randomness from the OS** (2026-11-14), `Source/docs/certificates.md`,
  "TLS": aws-lc built without CPU Jitter Entropy
  (`AWS_LC_SYS_NO_JITTER_ENTROPY`, `Source/.cargo/config.toml`), its random
  generator seeded from the OS's (Windows' `ProcessPrng`, Linux's
  `getrandom`) and RDRAND, as BoringSSL and `ring` do. The jitter seeding
  took 25 ms in every process at its first connection: a tool command went
  from 36 ms to 11 ms (the old tools: 8).

## Proposed, to confirm

Nothing at the moment.

Noted, not planned (dropped 2026-11-13): **typed query results**, numbers as
numbers in `QueryResult`'s JSON instead of protocol 6's strings. Messages
come back as text either way; only what SQL computes would gain
(`COUNT(*)`, ids, `data->>'$.x'`). Query results stay strings, as before.

## Open questions

- **"One server per node"** (a node pushes to one server only,
  `OldSource/Design/ReplicationIssues.md` #1): a CA certificate is valid on
  every server, so which server takes a node's pushes must come from the
  server's config (a list of nodes, or a role per server).
- **A handle-based DLL API** (several connections per process, old open item
  10): later maybe, the owner's call (one connection per process for now).
- **Running as a service** (old open item 1): designed in from the start,
  e.g. a Windows service mode, a stop signal, no console needed.
- **Tests:** keep the PowerShell suites (ported to certificates and the new
  config), move them to Rust integration tests, or both; a single runner and
  CI either way (old open item 7).
- **The identity extension's OID, a placeholder for now:** it goes under a
  Private Enterprise Number of NibblePoker's, from IANA (free, within a
  week; the owner's to request). Until then `bakashrot_pki::IDENTITY_OID`
  is under RFC 5612's documentation PEN (32473),
  `IDENTITY_OID_IS_PLACEHOLDER` is `true` and `bakashrot-cert` warns when
  it makes a certificate. Certificates issued with it stop being read once
  it changes: get the number before any is in use. How to request it and
  what to change then: `Source/docs/oid.md`.

## Kept: the behaviour to carry over

Described in `OldSource/Notes.md` and `OldSource/Design/`, tested by
`OldSource/Tests/`:

- Topics and nodes by name, each server with its own ids (now in its
  database only), wildcards, `PushTopics` / `ReadTopics`, `SendTopics` /
  `AcceptTopics`, `SendNodes` / `AcceptNodes` (`Packets.md`, "Topics and
  nodes").
- Requests: push (JSON or not, `is_json`), latest, runs of messages after
  an id (one request now), list names, read-only SQL (`Packets.md`, "Client
  requests"; the three read-only guards).
- Replication by name: sync state, batches of ~64 KB, only what's named on
  both sides, then attachments (`Packets.md`, "Replication").
- `pushed_at` stamped on arrival, carried by replication; retention per
  topic and server (`Notes.md`, "pushed times, retention").
- Attachments: one per message, 1 MB parts, SHA-256, replicated after
  their message (`Design/Attachments.md`); streamed inside the push now.
- Limits: 16 MB messages, the reply batch sizes, 1 G attachments by default.
- Error codes: the same numbers and meanings
  (`OldSource/Client/BakaShrot_ErrorCodes.pbi`); refuse vs abort; at least
  once delivery, nothing reconnects by itself.
- Storage: one writer, WAL, `Synchronous = FULL` by default, `node_heads`
  so ids never go back, the `messages` and `browse` views
  (`Design/StorageConcurrency.md`).
- The console commands (`quit`, `restart`, `vacuum`, `names`, `help`).
- Docker image, release zip, Python wheel (`Design/Release.md`,
  `OldSource/Docker/`).

## The old open items

From `OldSource/Notes.md`, "Open items":

- **Gone by design:** the custom crypto and its small issues (items 15-16),
  keys in plain-text inis as the identity (13, partly: private keys still
  sit in files), the console requirement (1, if designed in), the list and
  threading traps, the 5.73 quirks.
- **To carry over and fix:** a corrupted stored attachment re-sent forever
  (3, the proposed fix is written there); gaps in a pair's ids not detected
  (6); the sync state in one packet (9); warn once about dropped names; a
  leading BOM dropped from messages (22): store the bytes as sent; a NUL
  cutting a message in Python (23): pass lengths, not C strings.
- **Still true:** peers trusted with what they replicate (12), unless
  messages get signed by their origin; rotation (14) becomes reissuing
  certificates.

## Plan

Decided 2026-11-13. The crates without networking first, each tested on
its own; then one thin path through all of them; then one feature at a
time, through every layer at once, with its tests and docs. The old suites,
ported, say when a step is done; `OldSource/` stays runnable to compare.

Dependencies only point downward:

```
proto   pki   config   storage        no networking, tested on their own
   \     |      |       /
    server        client               the only crates that open sockets
                    |
             capi (DLL)   tools        thin layers over client
```

Error codes, limits and name rules live in `proto` only; the C, PureBasic
and Python constants get generated from it (protocol 6 had them copied by
hand in each).

| # | Step | What | Done when | Decide first | Status |
|---|---|---|---|---|---|
| 0 | Workspace | Cargo workspace, pinned toolchain, `check.ps1`, CI (fmt, clippy, test, doc) | The crates build, the checks pass | Crate names | Done 2026-11-13 |
| 1 | `bakashrot-proto` | Names, error codes, limits, every packet, frames | Round trips, refusals, random input never panics | The packet format | Done 2026-11-13, simplified the same day |
| 2 | `bakashrot-pki` + certificate tool | CA, server, client, peer certificates (P-384, the identity extension); name and roles read; the TLS setup (AES-256-GCM, X25519MLKEM768, the fixed server name); CRLs and their reload | `openssl verify` takes the tool's certificates; a TLS test accepts and refuses the right ones, a revoked one dropped | Decided 2026-11-13 | Done 2026-11-13 |
| 3 | `bakashrot-config` | Server config: topics, roles to permissions, peers, retention, clear errors | `schema.ini`'s cases, the configs `Names-Test` refuses | TOML, roles (decided 2026-11-13) | Done 2026-11-13 |
| 4 | `bakashrot-storage` | Schema v9, one writer, reads, names, attachments' states, query guards | Every request's SQL tested; concurrent writes; an old database refused | v9 (decided 2026-11-13) | Done 2026-11-13 |
| 5 | First path end to end | Server: TLS, identity from the certificate, `Welcome`, push and latest. Client library: the same | A Rust test pushes and reads back over TLS, a server on a free port | Decided 2026-11-13 | Done 2026-11-13 |
| 6 | The other requests | Runs of messages, names, queries, refusals with codes, 16 MB limits | `GetMessages-Test`, `BigMessages-Test`, ported | | Done 2026-11-13 |
| 7 | C DLL | The old exports over the client library, PureBasic prototypes, C header, `bakashrot.py` | `check_bakashrot.py` passes on it | Decided 2026-11-13 | Done 2026-11-13 |
| 8 | Tools | push, get, get-messages `--follow`, query, list (resolve is gone: names only), reading `client.toml` | The tools' parts of the old suites | Decided 2026-11-14 | Done 2026-11-14 |
| 9 | Attachments | Every layer: packets, storage, upload and download, client, DLL, tools | `Attachments-Test`, `AttachmentEdges-Test` | Decided 2026-11-14 | Done 2026-11-14 |
| 10 | Retention | Background deletion, `node_heads` kept, attachments cleaned up | `Retention-Test`'s local checks | | Done 2026-11-14 |
| 11 | Replication | Peer links, sync state, batches by name, wildcards, attachments, skipping on arrival | `Names-Test` (replication), `Restart-Test`; the corrupted-attachment fix | One server per node | |
| 12 | Operations | Console commands, service and signals, logs, Docker, release, wheel | Runs unattended, stops cleanly, the release's smoke test | The service | |
| 13 | Finish | One test runner, end-to-end tests in CI, the bench | Push speed against the old ~17,000 msg/s (4 servers) | | |

Each step ends with its tests passing and its docs updated (the crate's
docs, `Source/docs/`, this file's status), then a commit when the owner
asks. Open questions get settled at the step that needs them.

### Done: steps 0 and 1 (2026-11-13)

- **Workspace** (`Source/`): `Cargo.toml` (edition 2024, shared lints:
  `unsafe_code` denied, docs required, clippy's defaults; release profile
  with LTO, `panic = "unwind"` for the DLL's `catch_unwind`),
  `rust-toolchain.toml` (1.100.0, rustfmt, clippy), `.gitattributes` (LF),
  `check.ps1` (fmt, clippy with warnings as errors, tests, docs),
  `../.github/workflows/source.yml` (the same on Windows and Linux, Gitea
  Actions reads it too; not run yet, nothing pushed).
- **`bakashrot-proto`**, on `serde`, `rmp-serde` and `serde_bytes`
  (first written over `rmp` with hand-written packets, then simplified the
  same day: names only, derived packets, 18 of them, streamed attachments;
  the packets' code about half of what it was):
  - `limits`, `error` (the protocol 6 numbers, one table for the enum,
    names and descriptions), `names` (names and wildcards: the old rules,
    tested case by case);
  - `frame`: blocking `read()` / `write()` for the DLL, and `codec()`
    (feature `tokio`): `tokio-util`'s codec set to the same frames, for the
    server (it replaced an own `Decoder`);
  - `packets`: one table for the 18 types, the `Packet` enum and its
    `serde` form, each packet's struct with its `Check`; decoding reads
    with buffers that grow with the data (never from an announced
    length), checks every rule and that nothing follows.
  - 25 tests: round trips of a sample of every type, golden bytes, every
    truncation and trailing byte refused, wrong shapes and types, ranges,
    ids in order, names everywhere, a 4 GiB binary announced, and 250,000
    random or mutated packets that never make it panic (0.4 s), the
    codec's frames the same as the blocking ones.
  - Reviewed once more: one text per error code, empty `Check`s by
    default, `Attachment::part_count()` / `part_len()` for the receivers,
    ALPN tied to the version by a test; the batch sizes (~1 MiB per
    `Messages`, ~64 KiB per `ReplicateMessages`) left the protocol crate,
    they're the server's to set (steps 6 and 11).
- **`Source/docs/protocol.md`**: protocol 7, every packet, the flows, what
  changed from 6.
- **Left for later steps:** the TLS side of the protocol (ALPN, `Welcome`
  sent first: steps 2 and 5); generating the C, PureBasic and Python
  constants from `error` (step 7); a `cargo fuzz` target, if the random
  test ever misses something.

### Done: step 2 (2026-11-13)

`Source/docs/certificates.md` has all of it.

- **`bakashrot-pki`**, on `rcgen`, `rustls` (aws-lc), `x509-parser`
  (`verify-aws`, the same aws-lc) and `yasna`:
  - `Identity`: the extension read and written, names and roles checked;
  - `Ca`: a new CA, loading one (refused if the key isn't its
    certificate's), issuing client and server certificates, `issued()`,
    CRLs; `summarize()` for people;
  - `Revocations`: a CRL's serial numbers, only taken if it's the CA's
    (issuer and signature checked); shared with the server's TLS setup, so
    replacing it takes effect at the next handshake;
  - `tls`: the server's and the client's rustls configurations at the
    strongest settings, rustls' own verifiers (the server's wrapped to
    check revocation and the identity), `peer_identity()`.
  - The server name is fixed (`bakashrot-server`, in every server's
    certificate) instead of a verifier of our own: rustls' checks it all.
- **`bakashrot-tools`**: `bakashrot-cert` (`ca`, `issue`, `revoke`,
  `show`), never writing over a certificate or key, a CRL written aside
  then moved in place, revoking only the CA's certificates.
- **18 tests:** handshakes in memory (the strongest settings negotiated,
  identities both ways, servers as their peers' clients; refused: another
  CA's client or server, a client posing as a server, a revoked client and
  taken again once the CRL changes, no identity, another protocol
  version), certificates and CRLs, OpenSSL agreeing (`verify` for clients
  and servers, the CRL, a revoked one; Git's OpenSSL found), the tool end
  to end.
- **`aws-lc-rs` builds as it is** here (no CMake or NASM to install).
- **Then (2026-11-13):** clients check the CRL too when given one, so
  servers block each other both ways; ALPN `bakashrot` with the versions
  exchanged right after TLS (`frame::write_version()` / `check_version()`,
  error `VersionMismatch`); `--file` for a second certificate of the same
  name. 47 tests in the workspace.
- **Left:** the placeholder OID (a PEN, see "Open questions");
  `AllowedServerNames` (noted above); exchanging the versions, watching the
  CRL file and dropping revoked connections (step 5).
- **Simplified (2026-11-13):** reading PEM and certificates in one place
  (`lib.rs`), the EKU through x509-parser's accessor. The verifiers'
  delegation stays: rustls' own CRL support would mean a new TLS
  configuration per CRL change, and still `Revocations` for open
  connections.

### Done: step 3 (2026-11-13)

`Source/docs/config.md` has all of it; every key with its default:
`Source/crates/bakashrot-config/example.toml`.

- **`bakashrot-config`**, on `toml` and `serde` (`indexmap` for the
  file's order): `Config::load()` (paths from the config's folder) and
  `parse()`, checked in one go: TOML errors with their line, unknown keys,
  names, durations, sizes, addresses, ranges, things given twice (without
  case), `synchronous = "off"` refused as before.
- `Config::permissions(roles)`: what a certificate's roles allow together,
  `None` when none is known; `Permissions::can_push / can_read /
  can_query / sends / accepts / replicates`. `Retention::age(topic)`.
- **11 tests** (58 in the workspace): the example, defaults, every
  setting, retention's order, permissions, `replicated_topics`, paths, the
  refusals, each with its line (the old ini's keys among them).
- **Simplified the same day:** values checked as serde reads them
  (`deserialize_with`, `try_from`) instead of raw structs checked after:
  one set of structs, and every refusal has its line.
- **`upload_timeout` removed (2026-11-13):** protocol 7 streams an
  attachment inside its push, nothing waits for its message any more; a cut
  upload goes when its connection ends (schema v9).
- **Left for the server (step 5 on):** loading the certificate files,
  refusing a push to a topic it doesn't have, `[replication] peers`
  dialed; one server per node (see "Open questions") and the default
  topic, for later.
- **The default topic left the protocol too (2026-11-13):** `Welcome` has
  none, a push always names its topic (`NoDefaultTopic`, 6, never sent).

### Done: step 4 (2026-11-13)

`Source/docs/storage.md` has all of it (the layout, why, the numbers).

- **`bakashrot-storage`**, on `rusqlite` (SQLite bundled):
  - `Database::open`: makes a v9 database, opens one, refuses the old
    server's, a newer one's or another program's, migrates (none yet),
    deletes left-over uploads;
  - `Writer::batch`: one transaction, each operation all or nothing (a
    savepoint): pushes, uploads, replication, retention, purging
    attachments;
  - `Reader`: messages (after an id, the last ones, about 1 MiB per
    answer), names, heads, missing attachments, attachments and parts, as
    the protocol's types;
  - `QueryRunner`: read-only SQL, three guards, results as strings;
  - `Writer::vacuum()`: the old `vacuum` command.
- **The schema** moved into the crate (`src/schema_v9.sql`); the keys'
  layout is checked against it by a test.
- **15 tests** (73 in the workspace): every operation, the limits, refused
  databases, queries, the view's plans, readers with two writers at once;
  and `compare_with_old` (ignored by default): the same workload as the
  old storage, for comparing.
- **Measured before deciding** (Python, 5M messages): the packed layout
  23k pushes/s against 9k for v8's, 330 MB against 484 MB; a time index
  costs half the pushes, whatever the cache.
- **Simplified:** the protocol's types as answers (no copies), one stream
  lookup, the states typed both ways, `u64`s checked by `rusqlite`, fixed
  SQL for reads (the key's layout only in `lib.rs` and the schema).
- **Left for the server:** hashing parts as they stream (SHA-256), which
  topics exist (the config), retention's pace, a time limit on queries.
- **Against the old storage** (same workload, storage alone; `storage.md`,
  "Against the old storage"): pushes 13.8k/s against the old 25.9k at 1M,
  12.2k against 19.6k at 5M; reading 1000 messages 10 times faster,
  retention 3 to 12 times. The old writer's speed is its code (checkpoints
  in a background thread, next ids in memory, no savepoint per push), not
  its schema: two of those brought over at step 5.

### Done: step 5 (2026-11-13)

`Source/docs/server.md` has all of it.

- **`bakashrot-server`**: TLS with `bakashrot-pki`'s settings, the versions,
  the identity and its roles (refused with `NotAllowed` when none is
  known), `Welcome`; pushes (topic known, allowed, not too big) through
  one writer thread doing group commits; messages through a pool of read
  connections; the CRL file polled and reloaded, a revoked connection
  dropped at its next request; the other requests refused until their
  steps. The program: `bakashrot-server <config.toml>`, `tracing` logs,
  Ctrl+C.
- **`bakashrot-client`**: blocking; connects (TLS, ALPN checked, the
  versions, `Welcome`), `push`, `get_messages`; errors as the protocol's
  codes.
- **5 end-to-end tests** (and `push_rate`, ignored): pushes and reads back,
  refusals keeping the connection, refused certificates (each with its
  code), revoked ones dropped, six connections at once.
- **Then optimized:** checkpoints on their own thread and connection (the
  writer only past 10,000 pages): 13.8k to 34.7k pushes/s, storage alone;
  no savepoint around a push: 37.3k (the old storage: 25.9k). Next ids in
  memory left out: one indexed read per push, not where the time goes.
  The whole server, 10 clients over TLS: 36k pushes/s with `normal`, 9.2k
  with `full` (a disk flush per group).

### Done: step 6 (2026-11-13)

`Source/docs/server.md`, "Requests so far".

- **`GetMessages`** refuses an unknown topic (not the config's) or node
  (no messages in any topic) with `UnknownName`, as the old server did; a
  known pair without messages answers none.
- **`ListNames`:** the config's topics the roles may push to or read
  (all with `query`), every node with messages.
- **`Query`** on a pool of `query_only` connections; "malformed JSON"
  gets the old hint (`is_json = 1`).
- **The client:** `list_names`, `query`; messages and queries over
  `MAX_MESSAGE_SIZE` refused before sending.
- **4 more end-to-end tests:** runs of messages and big messages (the old
  suites' server parts: the tools' parts are step 8, replication's step
  11), names, queries.

### Done: step 7 (2026-11-13)

`Source/docs/client.md` has all of it.

- **`bakashrot-capi`** builds `bakashrot.dll` / `libbakashrot.so`: the old
  exports over `bakashrot-client` (A and W, buffers, `GetLastError`, the
  same codes), certificates set from PEM or files, one connection per
  process, panics caught, the C runtime static on Windows (the release DLL
  imports system DLLs only).
- **Bindings:** `bindings/c/bakashrot.h` generated by cbindgen (a test
  keeps it current), `bindings/purebasic/` (prototypes, error codes, an
  example run by hand against a server), `bindings/python/bakashrot.py`
  (certificates, `Client.from_file("client.toml")`, names only).
- **Small changes under it:** the client checks `GetMessages`' limit and
  `after` before sending, and says whether the server closed the
  connection (`is_open`); the server knows a client's own node before its
  first push (none, not `UnknownName`).
- **Tests:** the exports called directly (`exports.rs`),
  `check_bakashrot.py` ported (43 checks) run on the DLL (`python.rs`),
  the header. The attachment checks come back with step 9.

### Done: step 8 (2026-11-14)

`Source/docs/client.md`, "The tools".

- **`bakashrot`** (`bakashrot-tools`): `push <topic> <message>`, `latest
  <topic> <node>`, `messages <topic> <node>` (`--after <id|latest>`,
  `--limit`, `--follow`, `--interval`, `--time`), `query <sql>`, `list
  [topics|nodes|all] [--json]`, connecting with `client.toml` (`-c`). The
  old tools' output, without the ids; errors on stderr.
- **Gone:** `ResolveIds` (no ids), `GenerateKeyPairs` (`bakashrot-cert`),
  the default topic (`push` names its topic). `GetAttachment` and `push
  -a` come with step 9.
- **Tests** (`tests/bakashrot.rs`, 5): the GetMessages suite's checks
  (defaults, `--after`, `--limit`, `latest`, another reader, refusals,
  data as stored, big messages, `--follow` taking only new ones and failing
  once the server is gone), Names' and BigMessages' tool checks (pushes,
  refusals, the size limit, `latest`, `list`), queries, `client.toml`
  (relative paths, a typo, an unreachable server).

### Done: step 9 (2026-11-14)

`Source/docs/server.md` ("Requests"), `client.md`.

- **The server:** a push with an attachment is checked (topic, roles,
  sizes, the server's `max_attachment_size`), answered `Continue`, then
  every part read, written while the next ones come (4 at most waiting
  for the writer), the SHA-256 checked as they come; the message is
  stored with it once all of it matches. A wrong part, a wrong SHA-256, a
  failed write: refused once all parts came, the upload dropped. A cut
  connection drops it too. `GetAttachment` sends the size and SHA-256,
  then the parts from `from_part` (`NotFound`, `NotReady`, `TooBig` for
  one this server doesn't keep). The writer's queue takes every write
  now, not only pushes.
- **The client:** `push_with_attachment(topic, data, source)` (anything
  `Read + Seek`: read twice, its SHA-256 first), `get_attachment(..., out)`
  checked with its SHA-256 (`AttachmentMismatch`), `save_attachment(...,
  path)` written aside then moved, so a failed one leaves no file.
- **The DLL, Python, the tool, PureBasic:** as decided; the PureBasic
  example pushes an attachment and reads it back (run by hand, 5.73).
- **Tests:** the server's (`attachments`: the Attachments suite's sizes, 1
  byte to 5 MB + 123 and exactly 2 MB, read back and saved, none or
  missing refused, no file left, the limit, 0 for none, not allowed; and
  `attachment_edges`: a source changed between its SHA-256 and its
  sending, one failing in the middle, a part of the wrong size, a wrong
  SHA-256, reading from a part on, something else than a part; uploads
  dropped each time), the DLL's exports, `check_bakashrot.py`'s
  attachment checks back (52 checks), the tool's.
- **Measured** (release, local, `normal`): a 200 MB attachment up in 1.3 s
  and down in 0.5 s through the tool, its start included.
- **Left for replication (step 11):** replicated attachments
  (`replicating`, `too_big`), the corrupted-attachment fix, resuming from
  a part.

### Done: step 10 (2026-11-14)

`Source/docs/server.md` ("Retention").

- **The server:** a task (`retention.rs`, `Server::apply_retention()`):
  at start, then every `retention_interval`, every topic in the database
  by its name, its age from `[retention]`, its messages before now minus
  it deleted through the writer's queue (10,000 per write, so pushes go
  on between them), then the deleted messages' attachment parts (64 per
  write); each topic's count logged. As the old server did, except that
  uploads left behind are dropped at once (protocol 7), not on a timeout.
- **Tests:** `end_to_end.rs`'s `retention`: a topic kept 2 s, checked
  every second, its messages and attachment gone, another topic kept,
  ids going on, a younger message kept through a pass.
- **Left for replication (step 11):** the peer keeping its own copies,
  and what arrives already past its age (counted as received, not
  stored).
