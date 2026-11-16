# 4. Pushing

[Index](readme.md) · Previous: [Client](3-client.md) · Next: [Reading](5-reading.md)

As `node-sensor` (`client.toml`).

```shell
E:\BakaShrot>bakashrot push sensors "{\"celsius\":21.5}"
Pushed as message #1

E:\BakaShrot>bakashrot push sensors @reading.json -a photo.jpg
Pushed as message #2, with an attachment of 245 bytes
```

* Always pushed as the certificate's node (`node-sensor`).
* `@file` reads the message from a file, `-` from stdin.
* `-a`: one attachment per message.


## Refused

```shell
E:\BakaShrot>bakashrot push other "{}"
Refused by the server (NotAllowed): node-sensor may not push to 'other'

E:\BakaShrot>bakashrot messages sensors node-sensor
Refused by the server (NotAllowed): node-sensor may not read 'sensors'
```

* `other` isn't in the `sensor` role's `push_topics`.
* The `sensor` role has no `read_topics`: reading is the viewer's ([Reading](5-reading.md)).
