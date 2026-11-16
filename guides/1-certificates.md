# 1. Certificates

[Index](readme.md) · Next: [Server](2-server.md)

More options: `bakashrot-cert.exe <command> --help`.


## The root certificate

```shell
bakashrot-cert.exe ca --name bakashrot-test
```

Resulting files:
* `ca.crt` - Must be copied to each server and client.
* `ca.key` - Stays on this machine, it can make any certificate.


## A server certificate

```shell
bakashrot-cert.exe issue --server --name server-lan1
Wrote .\server-lan1.crt
Wrote .\server-lan1.key
```

Depending on how you set up replications, you may have to add a role with `--role <ROLE_NAME>`. \
See [???]().


## Node certificates

```shell
bakashrot-cert.exe issue --name node-sensor --role sensor
Wrote .\node-sensor.crt
Wrote .\node-sensor.key

bakashrot-cert.exe issue --name node-viewer --role viewer
Wrote .\node-viewer.crt
Wrote .\node-viewer.key
```

* The name is the node its messages are pushed as.
* Roles mean nothing until the server's config says what they may do ([Server](2-server.md)).
* Several roles: `--role sensor --role viewer`.


## Checking one

```shell
bakashrot-cert.exe show node-sensor.crt
node-sensor.crt
  name:    node-sensor
  roles:   sensor
  usage:   client
  issuer:  bakashrot-test
  valid:   Nov 15 11:35:45 2026 +00:00 to Nov 15 11:35:45 2027 +00:00
  serial:  588a92f0c5b39bc557f463f0ef50c278a2f9df50
```


## Revoking one

```shell
bakashrot-cert.exe revoke node-sensor.crt
```

* Writes `ca.crl` (every certificate revoked so far).
* Copy it next to the server's `server.toml` and add `crl = "ca.crl"` under `[server]`.
* The server reloads it within 5 s; that certificate is refused from its next request.
