//! Configs taken and refused, and what they mean.

use bakashrot_config::{Config, Synchronous};
use std::path::Path;
use std::time::Duration;

const EXAMPLE: &str = include_str!("../example.toml");

/// The least a config has.
const MINIMAL: &str = r#"
[server]
listen = "127.0.0.1:7000"
ca = "ca.crt"
certificate = "server.crt"
key = "server.key"
"#;

fn with(extra: &str) -> String {
    format!("{MINIMAL}{extra}")
}

/// The error of a config that must be refused.
fn refused(text: &str) -> String {
    match Config::parse(text) {
        Ok(config) => panic!("taken: {config:?}\n{text}"),
        Err(error) => error.to_string(),
    }
}

fn days(days: u64) -> Option<Duration> {
    Some(Duration::from_secs(days * 86_400))
}

#[test]
fn the_example() {
    let config = Config::parse(EXAMPLE).unwrap();
    let server = &config.server;
    assert_eq!(server.listen, "0.0.0.0:7000".parse().unwrap());
    assert_eq!(server.crl, None);
    assert_eq!(server.topics.len(), 3);
    assert!(server.has_topic("Sensors.Kitchen"));
    assert!(!server.has_topic("sensors"));
    assert_eq!(server.synchronous, Synchronous::Full);
    assert_eq!(server.max_attachment_size, 1 << 30);
    assert_eq!(config.replication.peers, Vec::<String>::new());
    assert_eq!(config.retention.age("logs"), days(30));
    assert_eq!(
        config.retention.age("sensors.kitchen"),
        Some(Duration::from_secs(43_200))
    );
    assert_eq!(config.retention.age("other"), None);
    let names: Vec<&str> = config.roles.iter().map(|role| role.name.as_str()).collect();
    assert_eq!(names, ["sensor", "dashboard", "peer"]);
}

#[test]
fn defaults() {
    let config = Config::parse(MINIMAL).unwrap();
    let server = &config.server;
    assert_eq!(server.database, Path::new("bakashrot.sqlite"));
    assert!(server.topics.is_empty());
    assert_eq!(server.synchronous, Synchronous::Full);
    assert_eq!(server.max_attachment_size, 1 << 30);
    assert_eq!(server.retention_interval, Duration::from_secs(60));
    assert_eq!(config.retention.age("logs"), None);
    assert_eq!(config.replication.retry_delay, Duration::from_secs(10));
    assert_eq!(config.replication.sync_interval, Duration::from_secs(5));
    assert_eq!(config.replication.batch_size, 100);
    assert_eq!(config.replication.replicated_topics, None);
    assert!(config.roles.is_empty());
    assert!(config.permissions(&["anything"]).is_none());
}

#[test]
fn settings() {
    let config = Config::parse(&with(
        r#"crl = "ca.crl"
database = "data/messages.sqlite"
synchronous = "NORMAL"
max_attachment_size = 0
retention_interval = "1h30m"

[replication]
peers = ["10.0.0.2:7000", "server-3.lan:7001", "[fd00::4]:7000"]
retry_delay = "1m"
sync_interval = "2s"
batch_size = 10000
replicated_topics = ["logs"]
"#,
    ))
    .unwrap();
    assert_eq!(config.server.crl.as_deref(), Some(Path::new("ca.crl")));
    assert_eq!(config.server.synchronous, Synchronous::Normal);
    assert_eq!(config.server.max_attachment_size, 0);
    assert_eq!(config.server.retention_interval, Duration::from_secs(5400));
    assert_eq!(config.replication.peers.len(), 3);
    assert_eq!(config.replication.retry_delay, Duration::from_secs(60));
    assert_eq!(config.replication.batch_size, 10_000);
}

#[test]
fn retention_order() {
    let config = Config::parse(&with(
        r#"
[retention]
"*" = "365d"
"sensors.?????" = "1h"
"sensors.*" = "12h"
"sensors.k*" = "2h"
"Sensors.Kitchen" = "forever"
logs = "30d"
"#,
    ))
    .unwrap();
    let age = |topic| config.retention.age(topic);
    let hours = |hours: u64| Some(Duration::from_secs(hours * 3600));
    // Its name's line first, wherever it is.
    assert_eq!(age("sensors.kitchen"), None);
    assert_eq!(age("LOGS"), days(30));
    // Else the first pattern in the file's order (sorted, "sensors.*"
    // would come first), not the closest.
    assert_eq!(age("sensors.alpha"), hours(1));
    assert_eq!(age("sensors.kettle"), hours(12));
    // "*" last, though it's first.
    assert_eq!(age("other"), days(365));
}

#[test]
fn permissions() {
    let config = Config::parse(&with(
        r#"
[roles.sensor]
push_topics = ["sensors.*"]

[roles.Reader]
read_topics = ["logs", "sensors.kitchen"]

[roles.admin]
query = true

[roles.peer]
send_topics = ["logs"]
send_nodes = ["kitchen-*"]

[roles.backup]
send_topics = ["sensors.*"]
accept_topics = ["*"]
accept_nodes = ["garage"]

[roles.idle]
"#,
    ))
    .unwrap();

    // None of its roles here: refused. Roles compare without case.
    assert!(config.permissions(&["unknown"]).is_none());
    assert!(config.permissions::<&str>(&[]).is_none());
    let idle = config.permissions(&["IDLE", "unknown"]).unwrap();
    assert_eq!(idle.roles().collect::<Vec<_>>(), ["idle"]);
    assert!(!idle.can_push("logs") && !idle.can_read("logs") && !idle.can_query());
    assert!(!idle.replicates());

    // Everything its roles allow.
    let both = config.permissions(&["sensor", "reader"]).unwrap();
    assert!(both.can_push("sensors.garage"));
    assert!(!both.can_push("logs"));
    assert!(both.can_read("Logs"));
    assert!(!both.can_read("sensors.garage"));
    assert!(!both.can_query());
    assert!(config.permissions(&["admin"]).unwrap().can_query());

    // Replication: each role's topics with that role's nodes, not mixed.
    let peer = config.permissions(&["peer", "backup"]).unwrap();
    assert!(peer.replicates());
    assert!(peer.sends("logs", "kitchen-1"));
    assert!(!peer.sends("logs", "garage"));
    assert!(peer.sends("sensors.a", "garage"));
    assert!(!peer.sends("other", "kitchen-1"));
    assert!(peer.accepts("anything", "garage"));
    assert!(!peer.accepts("logs", "kitchen-1"));
    // A role without the topics replicates nothing, whatever its nodes.
    let only_peer = config.permissions(&["peer"]).unwrap();
    assert!(!only_peer.accepts("logs", "kitchen-1"));
}

#[test]
fn replicated_topics_filter_the_roles() {
    let config = Config::parse(&with(
        r#"
[replication]
replicated_topics = ["logs", "alerts.*"]

[roles.peer]
send_topics = ["*"]
accept_topics = ["*"]

[roles.sensor]
push_topics = ["*"]
"#,
    ))
    .unwrap();
    let peer = config.permissions(&["peer", "sensor"]).unwrap();
    assert!(peer.sends("logs", "kitchen") && peer.accepts("Logs", "kitchen"));
    assert!(peer.sends("alerts.fire", "kitchen"));
    assert!(!peer.sends("sensors.a", "kitchen") && !peer.accepts("sensors.a", "kitchen"));
    assert!(peer.replicates());
    // Only replication: pushing isn't filtered.
    assert!(peer.can_push("sensors.a"));

    // Empty: nothing replicated.
    let none = Config::parse(&with(
        "[replication]\nreplicated_topics = []\n[roles.peer]\nsend_topics = [\"*\"]\n",
    ))
    .unwrap();
    assert!(
        !none
            .permissions(&["peer"])
            .unwrap()
            .sends("logs", "kitchen")
    );
    assert!(refused(&with("[replication]\nreplicated_topics = [\"a b\"]\n")).contains("'a b'"));
}

#[test]
fn files_are_from_the_configs_folder() {
    let folder = std::env::temp_dir().join(format!("bakashrot-config-{}", std::process::id()));
    std::fs::create_dir_all(&folder).unwrap();
    let path = folder.join("server.toml");
    std::fs::write(&path, with("crl = \"revoked/ca.crl\"\n")).unwrap();
    let config = Config::load(&path).unwrap();
    assert_eq!(config.server.ca, folder.join("ca.crt"));
    assert_eq!(config.server.crl, Some(folder.join("revoked/ca.crl")));
    assert_eq!(config.server.database, folder.join("bakashrot.sqlite"));

    std::fs::write(&path, "[server]\n").unwrap();
    let error = Config::load(&path).unwrap_err().to_string();
    assert!(error.starts_with(&path.display().to_string()), "{error}");
    assert!(error.contains("listen"), "{error}");
    std::fs::remove_dir_all(&folder).unwrap();

    let error = Config::load(&folder.join("missing.toml")).unwrap_err();
    assert!(error.to_string().contains("missing.toml"), "{error}");
}

#[test]
fn refusals() {
    let cases: &[(&str, &str)] = &[
        // Not TOML, or another shape: the line is said.
        ("[server", "line 1"),
        ("", "missing field `server`"),
        (&with("lsiten = \"x\"\n"), "unknown field `lsiten`"),
        (&with("[other]\n"), "unknown field `other`"),
        // The old ini's keys.
        (&with("PrivateKey = \"x\"\n"), "unknown field `PrivateKey`"),
        (
            &with("[roles.sensor]\nAllowWrite = 1\n"),
            "unknown field `AllowWrite`",
        ),
        (
            &with("[roles.sensor]\ndefault_topic = \"x\"\n"),
            "unknown field `default_topic`",
        ),
        // [server]
        (
            &MINIMAL.replace("127.0.0.1:7000", "127.0.0.1"),
            "'127.0.0.1' isn't an address and a port",
        ),
        (&with("topics = [\"a b\"]\n"), "'a b' isn't a name ("),
        (
            &with("topics = [\"sensors.*\"]\n"),
            "'sensors.*' isn't a name (",
        ),
        (&with("topics = [\"12\"]\n"), "'12' isn't a name"),
        (
            &with("topics = [\"logs\", \"Logs\"]\n"),
            "'Logs' is given twice",
        ),
        (
            &with("synchronous = \"OFF\"\n"),
            "isn't allowed: a power loss",
        ),
        (&with("synchronous = \"extra\"\n"), "write \"full\""),
        (
            &with("synchronous = \"fast\"\n"),
            "'fast' isn't \"full\" or \"normal\"",
        ),
        (
            &with("max_attachment_size = \"2T\"\n"),
            "isn't a size up to 1T",
        ),
        (&with("max_attachment_size = -1\n"), "isn't a size up to 1T"),
        (
            &with("max_attachment_size = \"1GB\"\n"),
            "isn't a size up to 1T",
        ),
        (&with("retention_interval = \"3600\"\n"), "isn't a duration"),
        (&with("retention_interval = 60\n"), "invalid type: integer"),
        // Gone with protocol 7: no upload waits for its message.
        (
            &with("upload_timeout = \"1h\"\n"),
            "unknown field `upload_timeout`",
        ),
        (
            &with("retention_interval = \"0s\"\n"),
            "'0s' isn't a duration",
        ),
        // [retention]
        (
            &with("[retention]\nlogs = \"30\"\n"),
            "logs = \"30\" isn't an age",
        ),
        (&with("[retention]\nlogs = 30\n"), "isn't an age"),
        (
            &with("[retention]\n\"a b\" = \"1d\"\n"),
            "'a b' isn't a topic name or a pattern",
        ),
        (
            &with("[retention]\nlogs = \"1d\"\nLOGS = \"2d\"\n"),
            "'LOGS' is given twice",
        ),
        (
            &with("[retention]\nsensors.kitchen = \"1d\"\n"),
            "quote names with dots",
        ),
        // [replication]
        (
            &with("[replication]\npeers = [\"10.0.0.2\"]\n"),
            "isn't a host and a port",
        ),
        (
            &with("[replication]\npeers = [\"a:1\", \"a:1\"]\n"),
            "'a:1' is given twice",
        ),
        (
            &with("[replication]\nbatch_size = 0\n"),
            "batch size must be 1 to 10000",
        ),
        (
            &with("[replication]\nbatch_size = 10001\n"),
            "batch size must be 1 to 10000",
        ),
        (
            &with("[replication]\nsync_interval = \"soon\"\n"),
            "'soon' isn't a duration",
        ),
        // [roles]
        (&with("[roles.\"a b\"]\n"), "'a b' isn't a role name"),
        (
            &with("[roles.peer]\n[roles.Peer]\n"),
            "'peer' and 'Peer' are the same role",
        ),
        (
            &with("[roles.r]\npush_topics = [\"a b\"]\n"),
            "'a b' isn't a name or a pattern",
        ),
        (
            &with("[roles.r]\naccept_nodes = [\"x\", \"X\"]\n"),
            "'X' is given twice",
        ),
        (&with("[roles.r]\nquery = 1\n"), "invalid type: integer"),
        (&with("[roles.site.reader]\n"), "unknown field `reader`"),
    ];
    for (text, expected) in cases {
        let error = refused(text);
        assert!(
            error.contains(expected),
            "expected {expected:?} in:\n{error}"
        );
        // Every refusal says where.
        assert!(error.contains("line "), "no line in:\n{error}");
    }
}
