# 3. Client

[Index](readme.md) · Previous: [Server](2-server.md) · Next: [Pushing](4-pushing.md)

`client.toml`, next to `ca.crt`, `node-sensor.crt` and `node-sensor.key`:
```toml
server = "192.168.1.10:7000"
ca = "ca.crt"
certificate = "node-sensor.crt"
key = "node-sensor.key"
```

`viewer.toml`, the same with the viewer's certificate:
```toml
server = "192.168.1.10:7000"
ca = "ca.crt"
certificate = "node-viewer.crt"
key = "node-viewer.key"
```

* `server`: the server's IP or hostname, and its `listen` port.
* `bakashrot.exe` reads `client.toml` from the current folder, `-c viewer.toml` for another one.
* Optional: `crl = "ca.crl"`, to refuse a revoked server (a file not there yet revokes nothing).
