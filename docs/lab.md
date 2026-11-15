# A test lab, step by step

Two servers replicating each other, a client pushing to one, another
reading from the other. Every command here was run as written (on one
machine, 2026-11-15, Windows): the outputs shown are what came back.

Get a release (CI's artifacts, or `release.ps1` / `python release.py`):
the programs, `bakashrot.dll` / `libbakashrot.so`, the wheel, the
example configs. The certificates are throwaway for now: the identity
OID is a placeholder until NibblePoker's PEN (`oid.md`), every tool run
says so. Reissue them all once it changes.

| Machine | What runs there | Files it gets |
|---|---|---|
| admin (any) | `bakashrot-cert` | `ca.key` stays here, never copied |
| server-1 | `bakashrot-server` | `ca.crt`, `server-1.crt`, `server-1.key`, `server.toml` |
| server-2 | `bakashrot-server` | `ca.crt`, `server-2.crt`, `server-2.key`, `server.toml` |
| kitchen | `bakashrot` (pushes to server-1) | `ca.crt`, `kitchen.crt`, `kitchen.key`, `client.toml` |
| dashboard | `bakashrot` (reads from server-2) | `ca.crt`, `dashboard.crt`, `dashboard.key`, `client.toml` |
| any | Python, pushes and reads | `ca.crt`, `lab-py.crt`, `lab-py.key`, `client.toml` |

Below, `server-1.lab` and `server-2.lab` are the servers' addresses: put
their hostnames or IPs. The clients can be on the servers' machines.

## 1. The certificates (admin)

```
bakashrot-cert ca --name "Lab CA"
bakashrot-cert issue --name server-1 --role peer --server
bakashrot-cert issue --name server-2 --role peer --server
bakashrot-cert issue --name kitchen --role sensor
bakashrot-cert issue --name dashboard --role dashboard
bakashrot-cert issue --name lab-py --role sensor --role dashboard
```

A certificate is its name (the node) and its roles; the servers' configs
say what each role may do. `--server` makes a server's certificate; with
the `peer` role, the other server's config lets it replicate. More
clients: one `issue` each, any name and roles (`--role a --role b`).

## 2. The servers

`server.toml` on server-1 (server-2's: swap `1` and `2`):

```toml
[server]
listen = "0.0.0.0:7000"
ca = "ca.crt"
certificate = "server-1.crt"
key = "server-1.key"
crl = "ca.crl"                 # optional; a missing file is fine, it's watched
database = "bakashrot.sqlite"
topics = ["lab.temps", "lab.events"]

[retention]
"*" = "7d"

[replication]
push_to = ["server-2.lab:7000"]   # dialed, sent to
accept_from = ["server-2.lab"]    # taken from (its address as seen from here)

[roles.sensor]
push_topics = ["lab.*"]

[roles.dashboard]
read_topics = ["*"]
query = true

[roles.peer]
send_topics = ["lab.*"]
accept_topics = ["lab.*"]
```

- `topics` are names, not patterns (`"lab.*"` there is refused, with its
  line); the roles take patterns.
- Every setting, with its default: `server.example.toml` (`config.md`).
- Open the port: `New-NetFirewallRule -DisplayName BakaShrot -Direction
  Inbound -Protocol TCP -LocalPort 7000 -Action Allow` on Windows, the
  distribution's firewall on Linux.

Start each one from its folder: `bakashrot-server server.toml`. Their logs:

```
INFO server-1 listening on 0.0.0.0:7000
INFO server-2.lab:7000: linked to server-2
```

The first to start says once that the other refused (`WARN ...
actively refused it`) and dials again every 10 s. Stop with Ctrl+C
(SIGTERM on Linux): what was answered is stored. Unattended: a systemd
unit (`server.md`, "Running"), NSSM on Windows, or Docker (below).

## 3. The clients

`client.toml` for kitchen (dashboard's: its own name, `server-2.lab`):

```toml
server = "server-1.lab:7000"
ca = "ca.crt"
certificate = "kitchen.crt"
key = "kitchen.key"
```

`bakashrot` reads `client.toml` from the current folder (`-c` for
another).

## 4. Things to try

**Push on one server, read on the other.** On kitchen:

```
> bakashrot push lab.temps '{"celsius":21.5}'
Pushed as message #1
> bakashrot push lab.events '{"with":"file"}' -a note.txt
Pushed as message #1, with an attachment of 6 bytes
```

(Quoted for bash and PowerShell 7.3+; cmd wants `"{\"celsius\":21.5}"`,
and Windows PowerShell 5.1 drops the inner quotes: there, `@file` reads
the message from a file, `-` from stdin.) A few seconds later (a check-in every 5 s),
on dashboard:

```
> bakashrot list
Topics (2):
  lab.temps
  lab.events
Nodes (1):
  kitchen
> bakashrot messages lab.temps kitchen
1	{"celsius":21.5}
> bakashrot latest lab.events kitchen
Message lab.events:kitchen#1, pushed 2026-11-15T00:15:09.401Z
Attachment: 6 bytes
{"with":"file"}
> bakashrot attachment lab.events kitchen 1 got.txt
Saved 6 bytes as got.txt
> bakashrot query "SELECT topic, node, message_id, message_data ->> '$.celsius' AS c FROM messages"
{"columns":["topic","node","message_id","c"],"rows":[["lab.events","kitchen","1",null],["lab.temps","kitchen","1","21.5"]]}
```

**Refusals.** A topic not in the config:

```
> bakashrot push other "{}"
Refused by the server (UnknownName): unknown topic 'other'
```

A certificate whose roles aren't in the config
(`issue --name visitor --role guest`):

```
Failed to connect to server-1.lab:7000 (NotAllowed): none of visitor's roles (guest) is allowed on this server
```

**Catching up.** Stop server-2, push a few messages on kitchen (server-1
takes them; it logs once that server-2 refused), start server-2: within
about 10 s every one is on dashboard, in order.

**Revoking.** On admin, `bakashrot-cert revoke dashboard.crt` writes
`ca.crl`; copy it next to each server's `server.toml` (the `crl` above).
Within 5 s they reload it (`INFO ca.crl: reloaded, 1 revoked`), and the
certificate is refused, at its next connection or request:

```
Failed to connect to server-2.lab:7000 (AuthRejected): the server refused this client's certificate (CertificateRevoked)
```

**Python.** `pip install bakashrot-0.2.0-py3-none-<platform>.whl` (from the
release's `python/`), then, next to lab-py's `client.toml` (it may push and
read: `sensor` and `dashboard`):

```python
import bakashrot

with bakashrot.Client.from_file("client.toml") as client:
    client.connect()
    print(client.push({"celsius": 20.5}, "lab.temps"))   # its id: 1
    print(client.latest("lab.temps", client.node))       # Message(id=1, topic='lab.temps', node='lab-py', ...)
    print(client.query("SELECT COUNT(*) AS n FROM messages"))   # [{'n': '...'}]: query results are strings
```

The whole API:
`client.md`, "Python".

**Also worth a look:** a node pushes to one server only (its messages
reach the others by replication: pushing the same node to both makes
diverging ids, `known-issues.md`); `BAKASHROT_LOG=debug` for more logs;
the database is a plain SQLite file, the `messages` and `browse` views
are for looking into it (`storage.md`, "The query surface").

## Docker instead (Linux)

The image `ghcr.io/aziascreations/bakashrot-server` (`server.md`, "In
Docker"; not run by hand yet, only CI's check). On a server's machine,
`docker/compose.yml` from the repository, and next to it `config/` with
`ca.crt`, the server's certificate and key and `server.toml` as above,
except:

```toml
database = "/var/lib/bakashrot/bakashrot.sqlite"
```

The server runs as uid 10001, which must read its key:
`sudo chown 10001:10001 config/server-1.key`. Then `docker compose up -d`,
`docker compose logs -f`, `docker compose down` (a clean stop; the
database stays in its volume).
