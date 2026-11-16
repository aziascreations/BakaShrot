# The clients

What apps connect with, in layers:

| Layer | Where | For |
|---|---|---|
| `bakashrot-client` | `crates/bakashrot-client` | Rust: blocking, one connection per `Client` |
| The DLL | `crates/bakashrot-capi`: `bakashrot.dll`, `libbakashrot.so` | C and anything that loads a DLL: the `BakaShrot_*` exports, one connection per process |
| C header | `bindings/c/bakashrot.h` | generated from the DLL (cbindgen) |
| PureBasic | `bindings/purebasic/` | the prototypes and the error codes |
| Python | `bindings/python/bakashrot.py` | `Client` over the DLL (ctypes), standard library only |
| The tools | `crates/bakashrot-tools`: `bakashrot` | the command line, over `bakashrot-client` |

Decided in `../revamp.md`, "Decided" (2026-11-13). What goes over the
wire: `protocol.md`; the server's side: `server.md`.

**Status:** steps 7 to 9: connecting, pushes, messages, attachments,
names, queries.

## Who connects: certificates

A client is its certificate, issued by the CA the servers trust
(`certificates.md`, `bakashrot-cert issue`): its name is its node, its
roles say what it may do on each server (`config.md`). It needs the CA's
certificate (to check the server's), its own certificate and key, and the
CA's CRL if there is one (servers it revokes are refused).

### `client.toml`

What Python's `Client.from_file()` and the tools read. Paths are relative
to the file's folder.

```toml
server = "10.0.0.2:7000"     # host:port, [an IPv6 address]:port
ca = "ca.crt"
certificate = "kitchen.crt"
key = "kitchen.key"
crl = "ca.crl"               # optional; a file not there yet: none
```

## The DLL

Its conventions:

- **One connection per process.** Calls from several threads wait for each
  other.
- **`A` and `W` exports:** strings in and out as UTF-8 (`char*`) or UTF-16
  (`uint16_t*`, `wchar_t*` on Windows; PureBasic uses these),
  null-terminated. A null string is an empty one where that means
  something (a message), refused otherwise (`InvalidArgument`).
- **Strings out** are copied into the caller's buffer of `BufferSize`
  bytes: the getter returns the bytes needed, terminator included, and
  copies nothing if they don't fit; a null buffer asks for the size.
- **Failures:** 0, or -1 where a count or an id is returned. Then
  `BakaShrot_GetLastError()` gives the code (`../crates/bakashrot-proto/src/error.rs`:
  1-99 a server's refusal, the connection still open; 100 and up the
  client's own) and `BakaShrot_GetRefusalReason()` why, in words (now for
  every failure, not only refusals). After `ConnectionLost` or
  `ProtocolError` the connection is closed: connect again. Nothing
  reconnects by itself; a push whose answer was lost may have been stored.
- **Inside:** every export catches panics (`Internal`); no threads, no
  runtime, so it unloads cleanly; nothing allocated on one side is freed
  on the other; the C runtime linked statically on Windows (the release
  DLL imports system DLLs only).

| Exports | What |
|---|---|
| `SetCaCertificate`, `SetCertificate`, `SetPrivateKey`, `SetCrl` (`A`/`W`) | PEM text (starting with `-----BEGIN`), or the path of a file holding it; `SetCrl` null or empty for none. Before connecting (`AlreadyConnected`); a file that can't be read is `FileError` |
| `Connect(Host, Port)` (`A`/`W`) | TLS with those; refused: `AuthRejected` (the server refused the certificate), `ServerNotVerified` (this client refused the server's), `NotAllowed` (none of its roles is the server's), `VersionMismatch` |
| `IsConnected`, `Disconnect` | `IsConnected` notices a connection the server closed |
| `GetNode` (`A`/`W`) | the node the server says this client is |
| `PushMessageTo(Topic, Data)` (`A`/`W`) | the id, -1 on failure |
| `GetLatestMessageOf(Topic, Node)` (`A`/`W`) | 1, or 0 with `NotFound` when there's none yet |
| `GetMessages(Topic, Node, After, Limit)` (`A`/`W`) | how many (0 isn't a failure), -1 on failure; then `GetMessageCount`, `SelectMessage(Index)`, `HasMoreMessages` |
| `GetMessageId`, `GetMessagePushedAt`, `GetMessageAttachmentSize`, `IsMessageAttachmentReady`, `GetMessageData`/`Topic`/`Node` (`A`/`W`) | the selected message; topic and node as asked |
| `ListTopics`, `ListNodes`, then `GetNamesList` (`A`/`W`) | how many; `{"kind":"topic","names":[...],"truncated":false}` |
| `Query(Sql)`, then `GetQueryResult` (`A`/`W`) | `{"columns":[...],"rows":[[...],...]}` |
| `PushMessageWithFile(Topic, Data, FilePath)`, `PushMessageWithData(Topic, Data, *Data, Size)` (`A`/`W`) | the id, -1 on failure; the attachment 1 byte and up, as much as the server takes (`TooBig`); a file read twice (its SHA-256 first), one changed in between refused (`DataMismatch`) |
| `SaveAttachment(Topic, Node, MessageId, FilePath)` (`A`/`W`) | its size, -1 on failure (`NotFound`, `NotReady`, `AttachmentMismatch`); a failed one leaves no file |
| `LoadAttachment(Topic, Node, MessageId)` (`A`/`W`), then `GetAttachmentData(*Buffer, Size)`, `FreeAttachmentData()` | into memory, for small ones; the getter returns the size, copies nothing if it doesn't fit |
| `GetLastError`, `GetRefusalReason` (`A`/`W`) | why the last call failed |

The header has each one's comment. Every name starts with `BakaShrot_`.

## Python

`bindings/python/bakashrot.py`: `Client(server, ca,
certificate, key, crl=None)` (PEM text or paths) or
`Client.from_file("client.toml")` (Python 3.11+, `tomllib`; the rest runs
on 3.8), `client.node` once connected, `push(data, topic,
attachment=None)` (the topic required; the attachment bytes or a path),
`latest()`, `get_messages()`, `iter_messages()`, `follow()`,
`get_attachment()` (bytes), `save_attachment()` (a file),
`list_topics()` / `list_nodes()` (names), `query()` / `query_raw()`.
Errors: `RefusedError`, `ConnectionLostError`, `AuthError` (a certificate
refused, either way, or no role allowed), `BakaShrotError`. The DLL is
looked for next to the module, or `BAKASHROT_DLL`. The release has a
wheel with the library in it (`pip install bakashrot-*.whl`, nothing else:
`bindings/python/make_wheel.py`, `../README.md`, "Releases").

## PureBasic

`bindings/purebasic/BakaShrot_Client_Prototypes.pbi` (with
`BakaShrot_ErrorCodes.pbi`): `BakaShrot_LoadClient("bakashrot.dll")`, then
the `W` exports without their suffix, `BakaShrot_*String()` helpers for the
getters. Run directly, it's an example: `ClientExample <DllPath> <CaFile>
<CertificateFile> <KeyFile> <Host> <Port>`, pushing a message and one
with an attachment, reading both back (run by hand against a server;
not in CI, which has no PureBasic).

## The tools

`bakashrot`, one program to push, read, query and list (`bakashrot-cert`,
for the CA, is apart: `certificates.md`). Each command connects with
`-c <file>` (`client.toml` by default), does one thing and exits: 0, 1 on a
failure (why on stderr: `Refused by the server (NotAllowed): ...`,
`Failed to connect to ...`), 2 on bad arguments. `--help` on each.

```text
bakashrot push logs '{"t":21}'                 Pushed as message #42
bakashrot push logs @reading.json              (- for the standard input)
bakashrot push logs '{"cam":1}' -a photo.jpg   Pushed as message #43, with an attachment of 81234 bytes
bakashrot latest logs kitchen                  Message logs:kitchen#43, pushed 2026-11-14T09:12:03.120Z
                                               Attachment: 81234 bytes
                                               {"cam":1}
bakashrot attachment logs kitchen 43 copy.jpg  Saved 81234 bytes as copy.jpg
bakashrot messages logs kitchen                1<TAB>{"t":20}, a line each
bakashrot messages logs kitchen -f --after latest --time
bakashrot query "SELECT topic, count(*) FROM messages GROUP BY topic"
bakashrot list                                 Topics (2): ... Nodes (1): ...
bakashrot list nodes --json                    {"kind":"node","names":["kitchen"],"truncated":false}
```

- **`messages`:** the first 100 by default (`--limit 0` for all), `--after
  <id>` or `latest`; data as stored, a line break in it spanning lines;
  `--follow` checks every `--interval` ms (500) until stopped or the
  connection fails (exit 1); `--time` adds the push time between the id and
  the data.
- **Attachments:** `push -a <file>`; `attachment` replaces the file,
  leaves none if it fails; `latest` says a message's (", not on this
  server yet" for one on its way from a peer).
- **Messages and SQL:** inline, `@file` or `-` (a UTF-8 BOM dropped).
  PowerShell before 7.3 drops the double quotes inside arguments: use a
  file there.
- **Speed** (release, a local server, 2026-11-14): a command takes about
  11 ms, connecting included; `messages --limit 0`
  writes 200,000 messages to a file in 0.26 s (Python's `iter_messages()`:
  1.5 s). More: `server.md`, "Measured".

## Tests

`crates/bakashrot-capi/tests/`, each against a server on a free port:

- `exports.rs`: the exports as C calls them: certificates from files and
  PEM, the `W` strings (and some `A`), the buffers (the size, too small,
  unaligned), selecting messages, attachments (from a file and memory,
  saved and loaded, the buffer, refused ones), every refusal and the
  client's own errors, closing, another identity.
- `python.rs`: runs `bindings/python/check_bakashrot.py` on the DLL; skipped, saying so, without Python 3.11+.
- `header.rs`: `bindings/c/bakashrot.h` matches the exports (rewritten
  when it doesn't: check it in).

`crates/bakashrot-tools/tests/bakashrot.rs` runs the tool against a server:
messages (`--follow` too), pushes and refusals, big messages,
attachments, queries, lists, `client.toml`.
