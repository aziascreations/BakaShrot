# One server, one client

The smallest BakaShrot setup: one server on `127.0.0.1:12360`, one client
that pushes and reads messages with the tools.

> **The keys in `server.ini` and `client.ini` are public, they're in the
> repository.** They're only for trying this example on your own machine
> (the server only listens on 127.0.0.1). Never reuse them: make your own
> with `BakaShrotGenerateKeyPairs.exe`.

## Running it

Build first, `Build.ps1` at the root, or use a release folder (`-BinDir
Release\<version>` on both scripts). Then, from this folder:

```powershell
powershell -ExecutionPolicy Bypass -File Start-Server.ps1
powershell -ExecutionPolicy Bypass -File Run-Client.ps1
```

- `Start-Server.ps1` opens the server in its own window and waits until it
  listens. Type `quit` in that window to stop it (`help` lists the other
  commands). `-Here` runs it in the current console instead, `-Reset`
  deletes its database first, so the ids start from 1 again.
- `Run-Client.ps1` goes through what a client does, printing each command
  before its output. The commands can be pasted as they are from this
  folder:

```text
== Push a message to the client's default topic (logs, the server's DefaultTopic for it), as node demo
> ..\..\Build\BakaShrotPushMessage.exe @messages\hello.json client.ini
  Pushed as message #1
...
== Read the latest message of logs:demo (topic:node, by name)
> ..\..\Build\BakaShrotGetLatestMessage.exe logs demo client.ini
  Message logs:demo#2 (ids 1:2), pushed 2026-11-08T21:23:53.590Z
  Attachment: 159 bytes
  {"level":"info","text":"Daily report, attached"}
```

The server's database (`example.sqlite`) and what the client saves
(`out\`) stay in this folder, git ignores them.

## What's in here

| File | What it is |
|---|---|
| `server.ini` | The server: its key, its names, where it listens, the one client it accepts and what that client may do. Every option is documented in `Server/Config/schema.ini`. |
| `client.ini` | The client: its key pair, the node it writes as (`demo`), and the server's address and public key. Every tool takes it as its last argument. |
| `Start-Server.ps1` | Starts the server with `server.ini`. |
| `Run-Client.ps1` | The client's steps, below. |
| `messages\` | What the client pushes (`hello.json`, `reading.json`, `report.json` with `report.txt` attached) and the SQL it runs (`query.sql`). |

## How the two configs fit together

- **Keys:** each side has a key pair. The server lists the client's public
  key in `[BakaShrot.Client.demo] PublicKeys`; the client has the server's
  in `ServerPublicKey`. Every connection is encrypted, and only reaches the
  server holding the matching private key.
- **Names:** messages are filed under a topic and a node. The topics are
  listed in `[BakaShrot.Topics]`, the nodes come from the sections that
  define them (`server`, `demo`). The server gives each name an id of its
  own; clients use the names.
- **Who the client is:** its node, `demo`, in both configs (`Node`).
  Every message it pushes is stored under it. That's why the server
  checks it: the key proves who's connecting, the server's `Node` for that
  key says which node it may write as, so no client can push as another's
  node.
- **Where its pushes go:** the server's `DefaultTopic = logs`, unless a
  push names another topic in `PushTopics` (`-t sensors`). Only the server
  has it: `client.ini` has no topic.
- **What it may do:** read every topic (`ReadTopics = *`, `AllowRead`),
  push (`AllowWrite`), run read-only SQL (`AllowQuery`).
- **Retention:** `sensors` messages are kept a day, `logs` ones forever.
- **Durability:** `Synchronous = FULL` (the default): every message the
  server acknowledges is flushed to disk first, so it survives a power cut.
  `NORMAL` pushes faster but can lose the last second or so of messages
  then; see `Server/Config/schema.ini`.

## What the client does

`Run-Client.ps1`, step by step:

1. **Pushes** `hello.json` to `logs`, its default topic: `BakaShrotPushMessage @messages\hello.json`.
   JSON goes in a file (`@file`): PowerShell drops the double quotes of an
   argument.
2. **Pushes** `reading.json` to `sensors`: `-t sensors`.
3. **Pushes** `report.json` with `report.txt` attached: `-a messages\report.txt`.
4. **Reads the latest** message of `logs:demo`: `BakaShrotGetLatestMessage logs demo`.
5. **Saves the attachment** back to `out\report-copy.txt` and checks it's
   the same: `BakaShrotGetAttachment logs demo <id> out\report-copy.txt`.
6. **Reads every** message of `logs:demo`, one per line (id, time, data):
   `BakaShrotGetMessages logs demo --time`.
7. **Reads** `sensors:demo`'s latest.
8. **Shows the ids** the server has for the names: `BakaShrotResolveIds topic sensors`, `BakaShrotList`.
9. **Queries** with SQL: `BakaShrotQuery @messages\query.sql`, on the
   `messages` view, which has the names.

To watch messages arrive, leave this running and push from another
terminal:

```powershell
..\..\Build\BakaShrotGetMessages.exe logs demo --after latest --follow client.ini
```

## Looking at the database

`example.sqlite` is a plain SQLite file, the `messages` view has the
names. To browse one topic in a tool like SQLiteStudio:

1. Open the `browse` table: one row. Pick a topic in its `topic` cell (a
   dropdown of the topics, from its foreign key), and a node in `node` to
   narrow it, or leave it NULL for every node. Commit.
2. Open the `browse_messages` view: that topic's messages, newest first,
   with their node, id, time (UTC), data and attachment size.

The server never writes `browse`, so it's safe to change while it runs.
Close the tool when done: an open grid keeps the server from finishing
its checkpoints, and its WAL file grows meanwhile.

## From Python

The same `client.ini` works with the Python client
(`Interactors/Python/bakashrot.py`, over the DLL). From the repository's
root:

```python
import sys
sys.path.insert(0, r"Interactors\Python")
from bakashrot import Client

with Client.from_ini(r"Examples\SingleServer\client.ini", r"Build\BakaShrot_Client.dll") as client:
    print("pushed", client.push({"from": "python"}))
    for message in client.get_messages("logs", "demo").messages:
        print(message.id, message.json())
```
