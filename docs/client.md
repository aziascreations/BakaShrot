# The clients

What apps connect with, in layers:

| Layer | Where | For |
|---|---|---|
| `bakashrot-client` | `crates/bakashrot-client` | Rust: blocking, one connection per `Client` |
| The DLL | `crates/bakashrot-capi`: `bakashrot.dll`, `libbakashrot.so` | C and anything that loads a DLL: the `BakaShrot_*` exports, as many clients as needed |
| C header | `bindings/c/bakashrot.h` | generated from the DLL (cbindgen) |
| PureBasic | `bindings/purebasic/` | the prototypes and the error codes |
| Python | `bindings/python/bakashrot.py` | `Client` over the DLL (ctypes), standard library only |
| C# | `bindings/csharp/NibblePoker.BakaShrot.Client/` | `Client` over the DLL (P/Invoke), .NET Framework 2.0 and up, .NET Core, .NET; a NuGet package with every platform's library |
| The tool | `crates/bakashrot-tools`: `bakashrot` | the command line, over `bakashrot-client`; `bakashrot cert`, the certificates |

Decided in `../revamp.md`, "Decided" (2026-11-13). What goes over the
wire: `protocol.md`; the server's side: `server.md`.

**Status:** steps 7 to 9: connecting, pushes, messages, attachments,
names, queries, several clients.

## Who connects: certificates

A client is its certificate, issued by the CA the servers trust
(`certificates.md`, `bakashrot cert issue`): its name is its node, its
roles say what it may do on each server (`config.md`). It needs the CA's
certificate (to check the server's), its own certificate and key, and the
CA's CRL if there is one (servers it revokes are refused).

### `client.toml`

What Python's `Client.from_file()` and the tool read. Paths are relative
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

- **Clients.** `BakaShrot_CreateClient()` makes one and returns its
  handle, the first argument of every other export;
  `BakaShrot_FreeClient(Client)` frees it. Each client has its own
  connection, answers and errors, and different clients can be used from
  different threads at once. A bad handle fails with `InvalidArgument`.
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

Every export but `CreateClient` takes the handle first (left out below):
a client's, or an enumeration's for the enumeration getters.

| Exports | What |
|---|---|
| `CreateClient()`, `FreeClient` | a new client's handle (0 if it failed); freed (its enumerations closed), 1 |
| `SetCaCertificate`, `SetCertificate`, `SetPrivateKey`, `SetCrl` (`A`/`W`) | PEM text (starting with `-----BEGIN`), or the path of a file holding it; `SetCrl` null or empty for none. Before connecting (`AlreadyConnected`); a file that can't be read is `FileError` |
| `Connect(Host, Port)` (`A`/`W`) | TLS with those; refused: `AuthRejected` (the server refused the certificate), `ServerNotVerified` (this client refused the server's), `NotAllowed` (none of its roles is the server's), `VersionMismatch` |
| `IsConnected`, `Disconnect` | `IsConnected` notices a connection the server closed |
| `GetNode` (`A`/`W`) | the node the server says this client is |
| `PushMessageTo(Topic, Data)` (`A`/`W`) | the id, -1 on failure |
| `GetLatestMessageOf(Topic, Node)` (`A`/`W`) | 1, or 0 with `NotFound` when there's none yet |
| `GetMessages(Topic, Node, After, Limit)` (`A`/`W`) | how many (0 isn't a failure), -1 on failure; then `GetMessageCount`, `SelectMessage(Index)`, `HasMoreMessages` |
| `GetMessageId`, `GetMessagePushedAt`, `GetMessageAttachmentSize`, `IsMessageAttachmentReady`, `GetMessageData`/`Topic`/`Node` (`A`/`W`) | the selected message; topic and node as asked |
| `ListNames(Kind, Topics, Nodes)` (`A`/`W`), then `GetNamesListAsJson` (`A`/`W`) | how many; `{"kind":"topic","names":[...],"truncated":false}`. 1 topics, 2 nodes, of the topic/node pairs `Topics` and `Nodes` match (a name or a pattern each, null for any): `(1, null, null)` every topic it may see, `(1, null, "kitchen")` the topics kitchen pushed to, `(2, "sensors.*", null)` the nodes that pushed to those |
| `Query(Sql)` (`A`/`W`), then `GetQueryResultAsJson` (`A`/`W`) | `{"columns":[...],"rows":[[...],...]}` |
| `EnumerateNames(Kind, Topics, Nodes)` (`A`/`W`), then `NextName`, `GetEnumName` (`A`/`W`), `GetNameCount`, `IsNamesListTruncated` | the same list without JSON: an enumeration's handle (0 on failure, the client's error); see below |
| `EnumerateQuery(Sql)` (`A`/`W`), then `GetQueryColumnCount`, `GetQueryColumnName(Index)` (`A`/`W`), `NextQueryRow`, `GetQueryValue(Index)` (`A`/`W`), `IsQueryValueNull(Index)` | the same result without JSON, a row at a time; see below |
| `CloseEnum` | an enumeration closed: 1, 0 if it wasn't one |
| `PushMessageWithFile(Topic, Data, FilePath)`, `PushMessageWithData(Topic, Data, *Data, Size)` (`A`/`W`) | the id, -1 on failure; the attachment 1 byte and up, as much as the server takes (`TooBig`); a file read twice (its SHA-256 first), one changed in between refused (`DataMismatch`) |
| `SaveAttachment(Topic, Node, MessageId, FilePath)` (`A`/`W`) | its size, -1 on failure (`NotFound`, `NotReady`, `AttachmentMismatch`); a failed one leaves no file |
| `LoadAttachment(Topic, Node, MessageId)` (`A`/`W`), then `GetAttachmentData(*Buffer, Size)`, `FreeAttachmentData()` | into memory, for small ones; the getter returns the size, copies nothing if it doesn't fit |
| `GetLastError`, `GetRefusalReason` (`A`/`W`) | why the client's last call failed |

The header has each one's comment. Every name starts with `BakaShrot_`.

**Enumerations**, like Win32's `FindFirstFile` / `FindNextFile` /
`FindClose`: `EnumerateNames()` or `EnumerateQuery()` asks the server
once and keeps the whole answer; `NextName()` / `NextQueryRow()` move to
the next item (1, 0 once there are no more, -1 for a handle that isn't
one of that kind), the getters read it. An enumeration starts before its
first item, so `while (BakaShrot_NextName(e) == 1)` reads them all, none
for an empty list. Several can be open at once, even on one client; the
client's later calls don't change them. They don't outlive their client:
`FreeClient()` closes them, their handles refused after. Otherwise
`CloseEnum()` once done. Their handles are numbered with the clients',
never reused: one is never the other's. A value's getter returns 0 for a
null, `IsQueryValueNull()` tells it from an empty string.

```c
int64_t e = BakaShrot_EnumerateNamesW(client, 1, NULL, L"kitchen");
while (BakaShrot_NextName(e) == 1) {
    BakaShrot_GetEnumNameW(e, name, sizeof name);   /* a topic kitchen pushed to */
}
BakaShrot_CloseEnum(e);
```

## Python

`bindings/python/bakashrot.py`: `Client(server, ca,
certificate, key, crl=None)` (PEM text or paths) or
`Client.from_file("client.toml")` (Python 3.11+, `tomllib`; the rest runs
on 3.8), `client.node` once connected, `push(data, topic,
attachment=None)` (the topic required; the attachment bytes or a path),
`latest()`, `get_messages()`, `iter_messages()`, `follow()`,
`get_attachment()` (bytes), `save_attachment()` (a file),
`list_topics()` / `list_nodes()` (names; `topic=` and `node=`, a name or
a pattern each, filter them: `list_topics(node="kitchen")` the topics
kitchen pushed to), `query()` / `query_raw()`.
Each `Client` has its own client in the DLL: several can be connected at
once, from any threads.
Errors: `RefusedError`, `ConnectionLostError`, `AuthError` (a certificate
refused, either way, or no role allowed), `BakaShrotError`. The DLL is
looked for next to the module, or `BAKASHROT_DLL`. The release has a
wheel with the library in it (`pip install bakashrot-*.whl`, nothing else:
`bindings/python/make_wheel.py`, `../README.md`, "Releases").

## C#

The NuGet package `NibblePoker.BakaShrot.Client` (namespace
`NibblePoker.BakaShrot`), or `bindings/csharp/NibblePoker.BakaShrot.Client/BakaShrot.cs`,
one file to copy into a project. C# 2 and .NET 2.0's class library only:
built for `net35` (it references `mscorlib` 2.0 only, so .NET Framework
2.0 and 3.x load it, 4.x too) and `netstandard2.0` (.NET Core 2.0 and up,
.NET 5 and up). The assembly is `NibblePoker.BakaShrot.Client.dll`, not
`BakaShrot.dll`, which is the library's name on Windows.

The package has the library for Windows and Linux, x64 and ARM64, in
`runtimes/<rid>/native/`: .NET Core and .NET take the machine's (or
`dotnet publish -r`'s). .NET Framework ignores `runtimes/`: the package's
`build/net35/NibblePoker.BakaShrot.Client.targets` copies `win-x64`'s next
to the app, `win-arm64`'s when `PlatformTarget` is `ARM64`
(`BakaShrotRuntime` to choose). CI packs it after the releases, from
their libraries, and keeps it as the run's `bakashrot-nuget` artifact.

```csharp
using (Client client = new Client("10.0.0.2", 7000, "ca.crt", "kitchen.crt", "kitchen.key", null))
{
    client.Connect();
    long id = client.Push("sensors", "{\"t\":21}");
    foreach (Message message in client.IterMessages("sensors", client.Node, 0))
        Console.WriteLine(message.Id + " " + message.Data);
}
```

`new Client(host, port, ca, certificate, key, crl)` (PEM text or paths,
`crl` null for none), `Connect()`, `Node`, `Connected`, `Push(topic,
data[, byte[]])`, `PushFile(topic, data, path)`, `Latest()` (null if
none), `GetMessages()` (a `MessagesPage`), `IterMessages()`, `Follow()`,
`GetAttachment()` (bytes), `SaveAttachment()` (a file), `ListTopics()` /
`ListNodes()` / `Query()` (the library's JSON, as a string: parsing it
is the app's; `ListTopics(topic, node)` / `ListNodes(topic, node)`
filter the lists as Python's do, null for any), `EnumerateTopics()` /
`EnumerateNodes()` (the same, filtered the same, as an
`IEnumerable<string>`) and `EnumerateQuery()` (`QueryRow`s: `Values`,
null for NULL, by index or column name, `Columns`), over the library's
enumerations, no JSON: each `foreach` asks again, the enumeration closed
when it ends (`Close()` ends it too, `ConnectionLostException`),
`Close()` / `Dispose()`. The same exceptions as Python's:
`RefusedException`, `ConnectionLostException`, `AuthException`,
`BakaShrotException`, each with its `ErrorCode`. Strings go as UTF-16 (the
`W` exports); one with a NUL is refused (`InvalidArgument`) rather than
cut. Each `Client` has its own client in the DLL, its calls serialized:
several at once, from any threads.

The library is found the usual DllImport way: next to the app, then the
PATH (`LD_LIBRARY_PATH` on Linux). It's 64-bit: the app must run as a
64-bit process (no "Prefer 32-bit" on .NET Framework).

## PureBasic

`bindings/purebasic/BakaShrot_Client_Prototypes.pbi` (with
`BakaShrot_ErrorCodes.pbi`): `BakaShrot_LoadClient("bakashrot.dll")`, then
the `W` exports without their suffix, the client first, and
`BakaShrot_*String(Client)` helpers for the getters. Run directly, it's an example: `ClientExample <DllPath> <CaFile>
<CertificateFile> <KeyFile> <Host> <Port>`, pushing a message and one
with an attachment, reading both back, then a second client at the same
time (run by hand against a server; not in CI, which has no PureBasic).

## The tool

`bakashrot`, one program to push, read, query and list, and to make the
certificates (`bakashrot cert`, no server needed: `certificates.md`).
Each other command connects with `-c <file>` (`client.toml` by default),
does one thing and exits: 0, 1 on a failure (why on stderr: `Refused by
the server (NotAllowed): ...`, `Failed to connect to ...`), 2 on bad
arguments. `--help` on each.

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
bakashrot list topics --nodes kitchen          Topics (1): the topics kitchen pushed to
bakashrot list nodes --topics 'sensors.*'      Nodes (2): those that pushed to sensors.*
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

- `exports.rs`, `exports`: the exports as C calls them, on one client: certificates from files and
  PEM, the `W` strings (and some `A`), the buffers (the size, too small,
  unaligned), selecting messages, attachments (from a file and memory,
  saved and loaded, the buffer, refused ones), every refusal and the
  client's own errors, closing, another identity.
- `exports.rs`, `clients`: two clients at once, each with its own answers
  and errors; bad and freed handles; 4 threads on 4 clients; a client
  freed while another thread uses it.
- `python.rs`: runs `bindings/python/check_bakashrot.py` on the DLL (two
  `Client`s at once, too); skipped, saying so, without Python 3.11+.
- PureBasic, by hand (no PureBasic in CI): run
  `BakaShrot_Client_Prototypes.pbi` directly, `ClientExample <DllPath>
  <CaFile> <CertificateFile> <KeyFile> <Host> <Port>`. Passed 2026-11-17
  with PureBasic 5.73 LTS and 6.41 (C backend), x64.
- C#, by hand (not in `test.ps1`): `cargo build`, then `dotnet test
  bindings/csharp/NibblePoker.BakaShrot.Client.Tests` (NUnit). Its `[SetUpFixture]`
  makes the certificates with `target/debug`'s `bakashrot cert`
  (`BAKASHROT_BIN` for another folder), starts `bakashrot-server` on a free
  port in `target/csharp-tests/`, copies the library next to the tests.
  On `net48` (the `net35` build) and `net8.0` (`netstandard2.0`), on Linux
  `net8.0` only. Passed 2026-11-18 on both, and on `net11.0`
  (`-p:TargetFrameworks=net11.0`).
- `header.rs`: `bindings/c/bakashrot.h` matches the exports (rewritten
  when it doesn't: check it in).

`crates/bakashrot-tools/tests/bakashrot.rs` runs the tool against a server:
messages (`--follow` too), pushes and refusals, big messages,
attachments, queries, lists, `client.toml`.
