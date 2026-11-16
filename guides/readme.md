# BakaShrot - Guides

One server, one client that pushes (`node-sensor`), one that reads (`node-viewer`).
Commands are for `cmd`, run from the release's folder (`E:\BakaShrot`).

| Step | Guide                             | Result                                                       |
|------|-----------------------------------|--------------------------------------------------------------|
| 1    | [Certificates](1-certificates.md) | A CA, the server's and the nodes' certificates; revoking one |
| 2    | [Server](2-server.md)             | `server.toml`, the port opened, the server running           |
| 3    | [Client](3-client.md)             | `client.toml` for each node                                  |
| 4    | [Pushing](4-pushing.md)           | Messages and attachments stored                              |
| 5    | [Reading](5-reading.md)           | Messages listed, read, queried                               |

Who gets which files:

| Machine | Files                                                                                 |
|---------|---------------------------------------------------------------------------------------|
| admin   | `bakashrot-cert.exe`, `ca.crt`, `ca.key` (never copied)                               |
| server  | `bakashrot-server.exe`, `ca.crt`, `server-lan1.crt`, `server-lan1.key`, `server.toml` |
| sensor  | `bakashrot.exe`, `ca.crt`, `node-sensor.crt`, `node-sensor.key`, `client.toml`        |
| viewer  | `bakashrot.exe`, `ca.crt`, `node-viewer.crt`, `node-viewer.key`, `viewer.toml`        |

More:
* `bakashrot <command> --help`, `bakashrot-cert <command> --help`.
* Two replicating servers, Python, Docker: `docs/lab.md`.
* Every setting: `docs/config.md`.
