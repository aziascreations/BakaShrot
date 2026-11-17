# The server's config

One TOML file, read and checked at once by `crates/bakashrot-config`: a
config that's wrong is refused whole, saying where (the line, shown) and
why. Every value is checked as it's read (serde), so every refusal has its
line. Every key, with its default: `crates/bakashrot-config/example.toml`.
Decided in `../revamp.md`, "Decided".

## What's in it

| Section | What |
|---|---|
| `[server]` | where it listens, the certificate files, the database, how pushes are flushed, attachments, retention's pace |
| `[retention]` | how long each topic's messages are kept |
| `[replication]` | the servers it sends to and takes from, retry and sync pace, batch size |
| `[roles.<name>]` | what certificates with that role may do |

Unknown keys are refused, so a typo is caught.

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
| `list_topics` | `false` | listing topics answers every one with messages, not only those it may push to or read |
| `list_nodes` | `false` | listing nodes answers every one with messages, not only those of the topics it may read |
| `send_topics` | none | replication: these topics sent to it |
| `accept_topics` | none | replication: these topics taken from it |
| `send_nodes` | `["*"]` | replication: only these nodes' messages sent |
| `accept_nodes` | `["*"]` | replication: only these nodes' messages taken |

`list_topics` and `list_nodes` (2026-11-16) only give names, for a tool
that browses a server: reading a topic is still `read_topics`. `query`
gives both, it reads everything anyway.

No `AllowRead` / `AllowWrite`: a list that's empty allows nothing. No
default topic: a push always names its topic (protocol 7 has none).

**The roles are the only lists of topics** (decided 2026-11-16): no
`[server] topics`, no `[replication] replicated_topics`, both refused as
unknown keys. A topic exists from its first message, pushed by a client
whose `push_topics` name it or taken from a peer whose `accept_topics`
do; it's then read, listed, sent on and aged like any other, each by the
roles that name it. A pattern (`push_topics = ["sensors.*"]`) lets its
clients make topics: names for a closed set.

## Peers

Who replicates with whom is each server's config, by address (not the
certificates: that would mean reissuing them):

- **`[replication] push_to`:** the servers it dials and sends to,
  `host:port`.
- **`[replication] accept_from`:** the servers it takes replicated
  messages from, IP addresses or hostnames without a port, `"*"` for
  all; none by default. Clients aren't concerned: they push wherever
  their roles allow.

A link carries messages one way: the server that dials sends, the one
dialed takes them. What's sent and taken is still the roles': the other
server's certificate's roles here, their `send_*` for what's sent to it,
their `accept_*` for what's taken from it.

An edge node that keeps some topics to itself leaves them out of its
peers' `send_topics`.

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

## Tests

`crates/bakashrot-config/tests/config.rs`: the example, the defaults,
every setting, retention's order, permissions (several roles, none known,
replication per role), the topic lists that are gone, paths from the config's
folder, and the refusals, each with its line: TOML errors, unknown keys,
every value that's wrong, names twice (without case),
unquoted dotted names.
