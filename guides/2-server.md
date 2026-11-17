# 2. Server

[Index](readme.md) · Previous: [Certificates](1-certificates.md) · Next: [Client](3-client.md)

## Pre-requisites
* The certificate authority's `.crt` file.
* The server's `.crt` file.


---

## Configuring it
The server's config is typically kept in `server.toml`, next the `.crt` files. \
Create a blank one and all the following sections.

### Server's base config
```toml
# All paths are relative to this file's folder unless they're absolute.
[server]
listen = "0.0.0.0:7000"  # Used when binding.

ca = "ca.crt"
certificate = "server-1.crt"
key = "server-1.key"

# The watched CA's CRL.
# Not given: no CRL checks. Given but not there yet: nothing revoked (a warning is logged),
# and it's picked up once it appears.
#crl = "ca.crl"

database = "bakashrot.sqlite"

# "full": every push flushed to disk before it's answered, it survives a
# power loss. "normal": about twice the pushes, a power loss loses the last
# second or so. ("off" isn't allowed.)
synchronous = "full"

# Replication cut partway through an attachment resumes once the peer has
# read back and hashed what it already has, in 30 s at most: up to about
# 4 GB received on a hard disk, 15 GB on a SATA SSD, 30-60 GB on NVMe
# (estimates). Past that, resuming fails at every retry: keep attachments
# well under it (more than a few GB is a lot for this anyway).
max_attachment_size = "1G"    # bytes, or K M G T (1024-based); 0: none
retention_interval = "1m"     # how often old messages are deleted
```


### Replication
```toml
# Who this server replicates with, by address.
# A link carries messages one way: the server that dials sends, the one dialed takes them.
[replication]
push_to = []  # Servers we'll actively connect to.
              # Example: ["10.0.0.2:7000", "server-2.lan:7000"]

accept_from = []  # Connecting servers must have these origins, otherwise we abort.
                  # Example: ["10.0.0.2", "server-2.lan"], or ["*"]

retry_delay = "10s"
sync_interval = "5s"  # keep it under 5 min: a link idle that long is closed
batch_size = 1000     # messages per packet, 1-10000
```


### Roles section
```toml
# A database holds 1,048,575 topic and node pairs at most, all topics together,
# never freed: patterns like "*" in push_topics let clients make as many as they like.
[roles.sensor]
push_topics = ["sensors.*"]          # always as its own node (its name)
read_topics = ["*"]
query = true                         # read-only SQL, reads every topic

# Listing: by default, only the topics it may push to or read,
# and only the nodes of the topics it may read.
list_topics = false                  # true: lists every topic (query does too)
list_nodes = false                   # true: lists every node (query does too)

# Only relevant when replicating. 
send_nodes = ["*"]    # Replicates every node's messages (Default)
accept_nodes = ["*"]  # Accepts every foreign node's messages (Default)
```

#### Remarks:
* Any node/certificate without any known role is refused.

#### Examples:
> **Sensor:**
> ```toml
> [roles.sensor]
> push_topics = ["sensors.*"]
> read_topics = []
> ```

> **Log Processor:**
> ```toml
> [roles.log-processor]
> push_topics = ["alerts.sensors.*"]
> read_topics = ["sensors.*"]
> ```

> **Explorer:** (sees every name, reads nothing)
> ```toml
> [roles.explorer]
> list_topics = true
> list_nodes = true
> ```

> **Admin:** (everything a client can do, on every topic)
> ```toml
> [roles.admin]
> push_topics = ["*"]
> read_topics = ["*"]
> query = true
> list_topics = true
> list_nodes = true
> ```
> Its certificate: `bakashrot.exe cert issue --name node-admin --role admin`


### Retention
```toml
# How long each topic's messages are kept, from when they were first pushed.
# Any topic not present here will be kept forever.
[retention]
logs = "30d"
"sensors.*" = "12h"
"*" = "forever"  # Implied
```


---

## Opening the port

Admin PowerShell:
```powershell
New-NetFirewallRule -DisplayName BakaShrot -Direction Inbound -Protocol TCP -LocalPort 7000 -Action Allow
```


---

## Starting it

```shell
bakashrot-server.exe server.toml
2026-11-15T11:35:51.404202Z  INFO server-lan1 listening on 0.0.0.0:7000
```

* Creates `bakashrot.sqlite` on first start.
* Stop with Ctrl+C: what was accepted is saved.
* More logs: `set BAKASHROT_LOG=debug` before starting it.
