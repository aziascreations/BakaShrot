# BakaShrot
A message store with replication.

Servers take messages (usually JSON) per topic and node from authenticated clients,
store them in SQLite, and replicate them to other servers by topic and node name.

> [!NOTE]
> Meant as an internal tool on trusted machines and networks.


## Features
* TLS 1.3 connections, both ends proving who they are with certificates from your own CA (`bakashrot-cert`)
* Replication between servers, by topic and node names
* Attachments, one per message, 1 GB by default
* Per-topic retention
* Read-only SQL queries on the stored messages
* Clients:
  * A C library (`bakashrot.dll`, `libbakashrot.so`), with a C header and PureBasic prototypes
  * A CLI tool to push, read, query and list
  * A Python module over the library, without dependencies, as a wheel with the library in it


## Building
Written in Rust, see [Source/README.md](Source/README.md): `cargo build --release` from `Source/`,
`python release.py` for a release (Windows x64, Linux x86-64) with its smoke test.

See [revamp.md](revamp.md) for why it was rewritten, what was decided, and the plan.
The PureBasic version it replaced (protocol 6) is in the git history: `OldSource/`, up to commit `68966a8`.


## Cloning
```
git clone https://github.com/aziascreations/BakaShrot.git
git clone https://git.nibblepoker.lu/aziascreations/BakaShrot.git
```


## License
All the code in this repo is released in the [Public Domain](LICENSE).

The releases include third-party crates under their own licenses, listed with their texts in `THIRD-PARTY.txt`.
