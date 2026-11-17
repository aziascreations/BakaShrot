# BakaShrot
A vibe-coded and opinionated message store built on SQLite, with replication between servers.

BakaShort allows applications and scripts to push/read data and files and let them replicate over an entire mesh regardless of whether the links are up or reliable. \
It also allows to sleep easy knowing each client is strongly authenticated by using certificates over public networks.


## Features

* Cert-based authentication with TLS 1.3 connections
  * Easy tools provided to manage it and CRL-based revocations.
* Role-based scoping of push and reads baked into certificates.
* Directional replication between servers, either complete or by topic and node names.
* File replication, one per message, up to 1 GiB by default with resumable replication.
* Per-topic and per-server retention of messages and files.
  * Edge can be configured to minutes while internal can hold years independently.
* Read-only SQL queries on stored JSON messages.
* Every push flushed to disk before it's answered, or about twice the pushes with `synchronous = "normal"`
* Supports Windows and Linux, both on x64 and ARM64.
* Clients:
  * A C library (`bakashrot.dll`, `libbakashrot.so`), with a C header and PureBasic prototypes
  * A CLI tool to push, read, query and list
  * A Python module over the library, without dependencies, as a wheel with the library in it


## Limitations
The main ones, all in [docs/known-issues.md](docs/known-issues.md) with what's left as it is and why:

* No replication consensus.  *(See [Why not something else](#why-not-something-else))*
* Peers are trusted with what they replicate, and clients only scope restrictions based on their role.
* Only 1,048,575 topic and node pairs can exist per database.
* Clients poll for new messages themselves.


## Quick Start
All instructions to setup a BakaShrot network can be found in [guides/](guides/).

It should take you 5-10 minutes if you test without docker, and maybe 10-15 minutes if you use a dockerized server.


## Why not something else

### Replicated SQL/SQLite DB
Projects like [rqlite](https://github.com/rqlite/rqlite) and [dqlite](https://github.com/canonical/dqlite) could have been perfect for what BakaShrot tries to accomplish. \
They require a leader, a constant S2S connection, and do not support split networks by design.

In contrast, BakaShrot moves trust off the server mesh itself and assumes you properly set up each node with a unique name and cert to prevent conflicts.

This prevents you from properly load-balancing, letting untrusted users push messages, and whatnot. \
But you gain the ability to host a message-server network over unreliable links without losing a single bit of data.

### MQTT Brokers
[Mosquitto](https://mosquitto.org) and other MQTT brokers handle the topic-based messaging in a near-perfect way, but they only deliver messages to whoever is subscribed at that moment, and have limited archival options. \
BakaShrot keeps every message, and allows you to re-read them days or years later.
<!-- And compared to mosquitto, you won't want to jump off a bridge while setting it up. -->

### Other message stores
Projects like **Kafka, NATS JetStream** are a good alternative to BakaShrot if you have the infrastructure and resources to host them.

However, I don't have heaps of RAM to piss away on running a JVM or other stuff. \
And BakaShrot, while simpler in all other aspect, takes less than 50 MB to run and can share any 1-2$ VPS with other applications very easily.


## Cloning
```
git clone https://github.com/aziascreations/BakaShrot.git
```


## License
All the code in this repo is released in the [Public Domain](LICENSE).

The releases include third-party crates under their own licenses, listed with their texts in `THIRD-PARTY.txt`.
