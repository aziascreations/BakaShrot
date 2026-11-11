# BakaShrot
A message store with replication, written in PureBasic.

Servers take messages (usually JSON) per topic and node from authenticated clients,
store them in SQLite, and replicate them to their peers by name.

> [!NOTE]
> Meant as an internal tool on trusted machines and networks.


## Features
* Encrypted connections, both ends prove who they are (Ed25519, libsodium)
* Replication between peers, by topic and node names
* Attachments of any size, one per message
* Per-topic retention
* Read-only SQL queries on the stored messages
* Clients:
  * A DLL, with PureBasic prototypes
  * CLI tools to push, read, query and list
  * A Python module over the DLL, without dependencies


## Building
Requires PureBasic 5.73 or 6.40+ and the submodules.

* **Development:** `powershell -ExecutionPolicy Bypass -File Build.ps1` (into `Build\`)
* **Release:** `powershell -ExecutionPolicy Bypass -File Release.ps1` (into `Release\`)
* **Docker:** See [Docker/README.md](Docker/README.md)

See [Examples/](Examples/README.md) for ready-to-run setups,
and [Server/Config/schema.ini](Server/Config/schema.ini) for every option of the server.


## Cloning
Use one of these commands to clone the repository and its submodules:
```
git clone --recurse-submodules https://github.com/aziascreations/BakaShrot.git
git clone --recurse-submodules https://git.nibblepoker.lu/aziascreations/BakaShrot.git
```


## License
All the code in this repo is released in the [Public Domain](LICENSE).

Please note that this doesn't apply to the required PureBasic archives.
