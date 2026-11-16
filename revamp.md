# BakaShrot revamp

Started 2026-11-13: what it should change, what's decided, what's still
open, and the plan. Every step of the plan is done (the workspace,
`bakashrot-proto`, `bakashrot-pki` and `bakashrot-cert`,
`bakashrot-config`, `bakashrot-storage`, `bakashrot-server` and
`bakashrot-client` answering every request, attachments included, the C
DLL with its C, PureBasic and Python bindings, the `bakashrot` tool,
retention, replication, operations and releases, then the finish: one
test runner, CI, Docker, `bench.ps1`), see "Plan".

## Decided

1. **Rust**, for the server, the client library and DLL, and the tools: one
   Cargo workspace at the root. Built in the order of "Plan" below.
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
- the protocol simplified (`docs/protocol.md`, "What changed"):
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
- **protocol 7's start** (`docs/protocol.md`): ALPN `bakashrot`, not
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
  - Crypto backend: **aws-lc-rs**, the one with ML-KEM.
  - The client's certificate is encrypted too: watchers still don't learn
    who connects. Peers the same way, one certificate each instead of a
    peer section plus a client section on the other server.
- **The certificate profile:**
  - **one identity extension** of our own, non-critical (rustls refuses
    critical ones it doesn't know): `SEQUENCE { version INTEGER (1), name
    UTF8String, roles SEQUENCE OF UTF8String }`. The name is the node;
    roles are free strings with the name rules, their meaning in the
    server's config. Only the server reads it. Its OID is
    `1.3.6.1.4.1.67681.1.1`, under NibblePoker's PEN (2026-11-16,
    `docs/oid.md`);
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
  - **a CRL file that isn't there** (2026-11-16): nothing revoked, on
    both ends, never blocking, where it's a setting: the server's
    config (warned in its log: a CRL deleted by mistake) and
    `client.toml` (the tool, Python's `from_file()`). A path given
    to the DLL's `SetCrl` or Python's `Client(crl=...)` is asked for
    explicitly: missing, it's a `FileError`. `bakashrot-cert revoke`
    needs no file to start from (it writes the first one). A file
    that's there but can't be read or isn't the CA's is refused;
  - clients check it too when given one (`client_config()` takes the
    same revocations): a server dialing its peer is a client, so servers
    block each other whichever end dials;
  - revoked by certificate, not by name: each certificate has its own key
    and serial number, so two servers of the same name each have theirs,
    revoked one at a time (`bakashrot-cert issue --file`).
- **The server's config is TOML** (2026-11-13), `docs/config.md`:
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
    (`[replication] push_to`, "Replication by address" below);
  - **no default topic** (dropped from the protocol too, 2026-11-13): a
    push always names its topic;
  - **the roles are the only lists of topics** (2026-11-16): `[server]
    topics` and `[replication] replicated_topics` are gone (refused as
    unknown keys), they repeated the roles. A push is taken if its
    roles' `push_topics` name the topic, a replicated message if the
    peer's `accept_topics` do; a topic exists from its first message,
    and is read, listed (`ListNames`: the topics with messages) and
    sent on by the roles that name it. So a topic that only came from a
    peer is read like any other, and a push to a topic nobody names is
    `NotAllowed` (`UnknownName` is only for nodes now);
  - **`list_topics` and `list_nodes`** (2026-11-16), two booleans of a
    role, for a tool that browses a server: listing answers every topic,
    every node with messages. Without them (or `query`, which gives
    both): the topics it may push to or read, the nodes of the topics
    it may read (every node until then). Names only, reading is still
    `read_topics`.
- **Schema v9, not compatible with v8** (2026-11-13): old databases aren't
  opened, their data isn't carried over (the real-life tests start empty).
  `docs/storage.md`:
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
- **The server and the client** (2026-11-13), `docs/server.md`:
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
- **The DLL** (2026-11-13), `docs/client.md`:
  - **connecting:** `BakaShrot_SetCaCertificate()`, `_SetCertificate()`,
    `_SetPrivateKey()`, `_SetCrl()`, each taking PEM text or a file's path;
  - **the old exports that don't fit any more are dropped**, not kept
    failing: the keys and node setters, the id-based ones, the default
    topic's `PushMessage()`;
  - **one connection per process**, as before (handles maybe later);
  - **`client.toml`** (server, ca, certificate, key, crl) replaces
    `client.ini`: Python's `Client.from_file()`, the tools at step 8.
- **The tools** (2026-11-14), `docs/client.md`, "The tools": one
  `bakashrot` program with subcommands (`push`, `latest`, `messages`,
  `query`, `list`) over `bakashrot-client`, `bakashrot-cert` kept apart
  (the CA's key); `-c/--config`, `client.toml` by default; the old tools'
  output; messages and SQL inline, `@file` or `-` (standard input); exit
  codes 0, 1, and 2 for bad arguments.
- **Attachments** (2026-11-14), `docs/server.md` and `client.md`:
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
- **Randomness from the OS** (2026-11-14), `docs/certificates.md`,
  "TLS": aws-lc built without CPU Jitter Entropy
  (`AWS_LC_SYS_NO_JITTER_ENTROPY`, `.cargo/config.toml`), its random
  generator seeded from the OS's (Windows' `ProcessPrng`, Linux's
  `getrandom`) and RDRAND, as BoringSSL and `ring` do. The jitter seeding
  took 25 ms in every process at its first connection: a tool command went
  from 36 ms to 11 ms (the old tools: 8).
- **Replication by address** (2026-11-14), `docs/config.md`:
  - **each server's config says who it replicates with**, by IP or
    hostname: `[replication] push_to`, the servers it dials and sends to
    (`host:port`, was `peers`), and `accept_from`, the servers whose
    replicated messages it takes (`"*"` for all). Not in the certificates:
    changing who replicates with whom would mean reissuing them;
  - **a link carries data one way**, from the server that dials to the one
    dialed (as the old links did); the other way is the other server's
    own `push_to`. The roles' `send_*` / `accept_*` still say which
    topics and nodes;
  - **`accept_from` is for servers only:** clients push wherever their
    roles allow, as now. A node pushing to one server only stays the
    config's rule, not checked, as in the old version
    (`docs/known-issues.md`).
- **Operations** (2026-11-14), `docs/server.md`, "Running";
  `readme.md`, "Releases":
  - **signals only:** SIGTERM and SIGINT on Linux; Ctrl+C, Ctrl+Break or
    the console closed on Windows; each stops it cleanly. No Windows
    service mode (a tool like NSSM if needed); more only if needed later;
  - **no console commands:** the old `quit`, `restart`, `vacuum`,
    `names`, `help` dropped; maybe an admin channel later;
  - **logs to the console only**, the easiest to redirect;
  - **Docker at the end** (step 13);
  - **a release per platform** (Windows x64, Linux x86-64): the
    programs, the client library and its bindings, the example configs,
    the docs, the licenses, and a smoke test;
  - **the Python wheel has the library in it**, for a simple install;
  - **version 0.2.0**; **0.3.0** on 2026-11-16 (the identity OID under
    NibblePoker's PEN, the roles as the only lists of topics,
    `list_topics` / `list_nodes`).
- **The PureBasic version removed** (2026-11-15): `OldSource/` deleted,
  kept in git history (up to `68966a8`). What of its notes and designs
  still holds went to `docs/known-issues.md`; the rest was already
  in `docs/` or only about PureBasic. Its PowerShell suites go
  with it: the Rust tests (`cargo test`, `test.ps1`, CI) are the one
  runner, with `release.py`'s smoke test across processes (old open item
  7).
- **The workspace at the root** (2026-11-15): `Source/`'s content moved
  up, `Source/README.md` merged into `readme.md`; scripts at the root:
  `build.ps1`, `test.ps1` (was `check.ps1`), `release.ps1` (over
  `release.py`, which CI's Linux job runs as is), `clean.ps1`. CI is
  `.github/workflows/ci.yml`.
- **CI on tags only** (2026-11-15): a `v*` tag (or a run by hand) runs
  the checks, then a release for Windows x64 and ARM64, Linux x64 and
  ARM64, each on its own kind of runner (the smoke test runs there), the
  archives kept as the run's artifacts. Nothing runs on pushes:
  `test.ps1` is run here before.
- **Docker** (2026-11-15): `docker/` (Dockerfile, compose.yml, test.sh):
  the server and the tools, built from source, on `debian:trixie-slim`,
  as uid 10001. CI builds amd64 and arm64 natively, checks each with
  `docker/test.sh`, and on a tag pushes them to
  `ghcr.io/aziascreations/bakashrot-server` with the workflow's token,
  then an index of both as `<version>` and `latest` (once the releases
  passed; `latest` only for versions without a `-`). The Gitea registry
  stays a push by hand. The workflow's safety is in its header: tags and
  manual runs only, a read-only token but where images are pushed (after
  they're built and checked), no token left on disk by checkout, actions
  pinned to commits, `--locked` builds.

## Proposed, to confirm

- **A GUI explorer** (2026-11-16, set aside for later): likely **egui**
  (`eframe`), the owner leaning to it. One exe in the workspace over
  `bakashrot-client`, Windows and Linux, MIT/Apache (Slint's GPLv3 or
  attribution license weighed against the CC0 project; a Win32 `.rc`
  dialog would be Windows only). To start it: a short spec from the
  owner (goal, connecting, a layout sketch, now / later / never,
  details such as times and paging, done when).

## Open questions

- **A handle-based DLL API** (several connections per process, old open item
  10): later maybe, the owner's call (one connection per process for now).

## The old open items

The PureBasic version's, still not fixed:

- **Gaps in a topic and node's ids** aren't detected on replication (6),
  and **`SyncState` is one packet** (9): `docs/known-issues.md`.
- **Peers are trusted with what they replicate** (12), unless messages
  get signed by their node: `docs/known-issues.md`.
- **Names left out of replication aren't warned about:** a topic or
  node one side doesn't take is skipped silently. Warn once per peer
  and name, again only when that changes (a log line at every check-in
  would spam).
- **A NUL cuts a message from Python** (23): `push()` passes it to
  `PushMessageToA` as a C string, `"a\x00b"` is stored as `a`. Refuse
  it in `push()`, or pass a length.

## Plan

Decided 2026-11-13. The crates without networking first, each tested on
its own; then one thin path through all of them; then one feature at a
time, through every layer at once, with its tests and docs.

Dependencies only point downward:

```
proto   pki   config   storage        no networking, tested on their own
   \     |      |       /
    server        client               the only crates that open sockets
                    |
             capi (DLL)   tools        thin layers over client
```

Error codes, limits and name rules live in `proto` only. The C header is
generated from the DLL; the PureBasic and Python constants are written
by hand.

| # | Step | What | Done when | Decide first | Status |
|---|---|---|---|---|---|
| 0 | Workspace | Cargo workspace, pinned toolchain, `test.ps1`, CI (fmt, clippy, test, doc) | The crates build, the checks pass | Crate names | Done 2026-11-13 |
| 1 | `bakashrot-proto` | Names, error codes, limits, every packet, frames | Round trips, refusals, random input never panics | The packet format | Done 2026-11-13, simplified the same day |
| 2 | `bakashrot-pki` + certificate tool | CA, server, client, peer certificates (P-384, the identity extension); name and roles read; the TLS setup (AES-256-GCM, X25519MLKEM768, the fixed server name); CRLs and their reload | `openssl verify` takes the tool's certificates; a TLS test accepts and refuses the right ones, a revoked one dropped | Decided 2026-11-13 | Done 2026-11-13 |
| 3 | `bakashrot-config` | Server config: topics, roles to permissions, peers, retention, clear errors | Every setting and refusal tested, each with its line | TOML, roles (decided 2026-11-13) | Done 2026-11-13 |
| 4 | `bakashrot-storage` | Schema v9, one writer, reads, names, attachments' states, query guards | Every request's SQL tested; concurrent writes; an old database refused | v9 (decided 2026-11-13) | Done 2026-11-13 |
| 5 | First path end to end | Server: TLS, identity from the certificate, `Welcome`, push and latest. Client library: the same | A Rust test pushes and reads back over TLS, a server on a free port | Decided 2026-11-13 | Done 2026-11-13 |
| 6 | The other requests | Runs of messages, names, queries, refusals with codes, 16 MB limits | Their end-to-end tests | | Done 2026-11-13 |
| 7 | C DLL | The `BakaShrot_*` exports over the client library, PureBasic prototypes, C header, `bakashrot.py` | `check_bakashrot.py` passes on it | Decided 2026-11-13 | Done 2026-11-13 |
| 8 | Tools | push, get, get-messages `--follow`, query, list (resolve is gone: names only), reading `client.toml` | The tools' end-to-end tests | Decided 2026-11-14 | Done 2026-11-14 |
| 9 | Attachments | Every layer: packets, storage, upload and download, client, DLL, tools | Every size and edge case, end to end | Decided 2026-11-14 | Done 2026-11-14 |
| 10 | Retention | Background deletion, `node_heads` kept, attachments cleaned up | Retention's end-to-end test | | Done 2026-11-14 |
| 11 | Replication | Peer links, sync state, batches by name, wildcards, attachments, skipping on arrival | Three servers end to end, a restart; the corrupted-attachment fix | Decided 2026-11-14 | Done 2026-11-14 |
| 12 | Operations | Signals and a clean stop, logs, release, wheel | Runs unattended, stops cleanly, the release's smoke test | Decided 2026-11-14 | Done 2026-11-14 |
| 13 | Finish | One test runner (the Rust tests, decided 2026-11-15), end-to-end tests in CI, the bench, Docker | Push speed with 4 servers replicating (`docs/server.md`, "Measured") | | Done 2026-11-16 (`bench.ps1`) |

Each step ends with its tests passing and its docs updated (the crate's
docs, `docs/`, this file's status), then a commit when the owner
asks. Open questions get settled at the step that needs them.
