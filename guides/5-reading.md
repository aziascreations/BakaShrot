# 5. Reading

[Index](readme.md) · Previous: [Pushing](4-pushing.md)

As `node-viewer` (`-c viewer.toml`).


## Topics and nodes

```shell
E:\BakaShrot>bakashrot -c viewer.toml list
Topics (1):
  sensors
Nodes (1):
  node-sensor
```


## A node's messages in a topic

```shell
E:\BakaShrot>bakashrot -c viewer.toml messages sensors node-sensor
1	{"celsius":21.5}
2	{"celsius":22}
```

* One per line: id, tab, data.
* The node is a name, not a pattern: `*` fails with `'*' isn't a node name`.
* `-f` keeps waiting for new ones, `-t` adds the time, `--after <id>` skips the first ones.


## The latest one, with its attachment

```shell
E:\BakaShrot>bakashrot -c viewer.toml latest sensors node-sensor
Message sensors:node-sensor#2, pushed 2026-11-15T11:35:53.484Z
Attachment: 245 bytes
{"celsius":22}

E:\BakaShrot>bakashrot -c viewer.toml attachment sensors node-sensor 2 photo.jpg
Saved 245 bytes as photo.jpg
```


## SQL

Read-only, every topic, needs `query = true` in the role:
```shell
E:\BakaShrot>bakashrot -c viewer.toml query "SELECT node, message_id, message_data ->> '$.celsius' AS c FROM messages"
{"columns":["node","message_id","c"],"rows":[["node-sensor","1","21.5"],["node-sensor","2","22"]]}
```


## Names

The topics a node pushed to, the nodes that pushed to some topics (a name
or a pattern):
```shell
E:\BakaShrot>bakashrot -c viewer.toml list topics --nodes node-sensor
Topics (1):
  sensors

E:\BakaShrot>bakashrot -c viewer.toml list nodes --topics "sens*"
Nodes (1):
  node-sensor
```


## Refused

```shell
E:\BakaShrot>bakashrot -c viewer.toml push sensors "{}"
Refused by the server (NotAllowed): node-viewer may not push to 'sensors'
```

* The `viewer` role has no `push_topics`.
