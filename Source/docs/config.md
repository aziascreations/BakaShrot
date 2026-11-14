# The server's config

One TOML file, read and checked at once by `crates/bakashrot-config`: a
config that's wrong is refused whole, saying where (the line, shown) and
why. Every value is checked as it's read (serde), so every refusal has its
line. Every key, with its default: `crates/bakashrot-config/example.toml`.
Decided in `../../revamp.md`, "Decided".

## What's in it

| Section | What |
|---|---|
| `[server]` | where it listens, the certificate files, the database, its topics, how pushes are flushed, attachments, retention's pace |
| `[retention]` | how long each topic's messages are kept |
| `[replication]` | the peers it dials, the topics replicated at all, retry and sync pace, batch size |
| `[roles.<name>]` | what certificates with that role may do |

Unknown keys are refused, so a typo or a key of the old ini is caught.

## Who's who: certificates, then roles

A connection's certificate (`certificates.md`) says its node (its name)
and its roles. The server looks its roles up in `[roles.*]`:

- **Everything its roles allow, each role on its own**: `sensor` and
  `reader` push what `sensor` may push, read what `reader` may read. For
  replication, a role's topics go with that role's nodes, they're not
  mixed with another role's.
- **None of its roles has a section: refused.** Roles the server doesn't
  know are ignored (a certificate may have roles for other servers).
- Roles compare without case, like names.

What a role gives:

| Key | Default | Allows |
|---|---|---|
| `push_topics` | none | pushing to these topics, always as its own node |
| `read_topics` | none | reading these topics' messages |
| `query` | `false` | read-only SQL, which reads every topic |
| `send_topics` | none | replication: these topics sent to it |
| `accept_topics` | none | replication: these topics taken from it |
| `send_nodes` | `["*"]` | replication: only these nodes' messages sent |
| `accept_nodes` | `["*"]` | replication: only these nodes' messages taken |

No `AllowRead` / `AllowWrite`: a list that's empty allows nothing. No
default topic: a push always names its topic (protocol 7 has none).

## Peers

Peers are roles too: a server whose certificate has a role with
`send_topics` or `accept_topics` replicates, whichever end dialed. The
config only lists where to dial (`[replication] peers`, `host:port`): a
certificate can't say where a server is. Each side applies its own roles
to the other, as before each side had its own peer section.

`[replication] replicated_topics`, optional, filters every peer's
replication whatever its roles say: an edge node that keeps some topics to
itself. Without it, no filter; `[]` replicates nothing. Pushing and reading
aren't filtered.

## Names and values

- **Names** (topics, nodes, roles): 1-64 of `A-Z a-z 0-9 _ . -`, not only
  digits, compared without case. Lists of topics or nodes also take
  patterns: `*` any characters, `?` one, `"*"` for all. `[server] topics`
  takes names only.
- **Names with dots are quoted as keys:** `"sensors.kitchen" = "12h"`,
  `[roles."site.reader"]`. Unquoted, TOML reads dots as tables: refused,
  `[retention]` says to quote.
- **Durations:** numbers with a unit (`s m h d w`), added up: `"30s"`,
  `"1d12h"`. Ages in `[retention]` can also be `"forever"`.
- **Sizes:** bytes, or `"500M"` with `K M G T` (1024-based), up to 1T.
- **Paths:** relative ones are from the config file's folder.

## Retention

A topic takes its name's line, else the first pattern matching it in the
file's order, else `"*"`'s line wherever it is; without any, it's kept
forever. Ages count from when a message was first pushed, on whichever
server; each server has its own.

## What changed from the old ini

| Old (`OldSource/Server/Config/schema.ini`) | Now |
|---|---|
| `PrivateKey`, `[BakaShrot] Node` | `ca`, `certificate`, `key`: the node is the certificate's name |
| `[BakaShrot.Client.*]`: keys, `Node`, `Allow*` | `[roles.*]`, the node and roles from the certificate |
| `[BakaShrot.Peer.*]`: `Host`, `Port`, `Node`, `PublicKey`, topic and node lists | `[replication] peers` (addresses), the lists in the peer's roles |
| `ReplicatingTopics` | each peer role's `send_topics` / `accept_topics`; `replicated_topics` filters them all |
| topic and node ids, pins, ranges, `[BakaShrot.Nodes]` | names only: ids are the database's |
| `DefaultTopic` | dropped: a push always names its topic |
| `Host` + `Port` | `listen` |
| seconds | durations (`"10s"`) |
| `NetThreadPoolSize` | gone (tokio) |
| `UploadTimeout` | gone: attachments are streamed in their push (protocol 7), nothing waits |
| `FULL` / `NORMAL` | `"full"` / `"normal"`; `off` still refused |

## Tests

`crates/bakashrot-config/tests/config.rs`: the example, the defaults,
every setting, retention's order, permissions (several roles, none known,
replication per role), `replicated_topics`, paths from the config's
folder, and the refusals, each with its line: TOML errors, unknown keys
(the old ini's too), every value that's wrong, names twice (without case),
unquoted dotted names.
