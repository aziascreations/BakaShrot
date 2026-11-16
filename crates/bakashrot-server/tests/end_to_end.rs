//! A server on a free port, clients over TLS: pushes and reads, runs of
//! messages, big ones, names, queries, attachments, retention, replication
//! between servers, refusals, certificates refused, revoked ones dropped,
//! pushes at once.

use bakashrot_client::{Client, Settings};
use bakashrot_config::Config;
use bakashrot_pki::{Ca, Identity, Issued, Revocations, Usage, summarize, tls};
use bakashrot_proto::limits::{ATTACHMENT_PART_SIZE, MAX_MESSAGE_SIZE, MAX_PACKET_SIZE};
use bakashrot_proto::packets::{
    Attachment, AttachmentPart, GetAttachment, MessagePushed, Messages, NameKind, PushMessage,
    ReplicateAttachment, ReplicateMessages, ReplicatedMessage, StoredAttachment, SyncState,
    SyncStateRequest,
};
use bakashrot_proto::{ErrorCode, Packet, frame};
use bakashrot_server::Server;
use std::io::{Cursor, Read, Seek, SeekFrom, Write};
use std::net::TcpStream;
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};
use tokio_rustls::rustls::{ClientConnection, StreamOwned};

const CONFIG: &str = r#"
[server]
listen = "127.0.0.1:0"
ca = "ca.crt"
certificate = "server.crt"
key = "server.key"
crl = "ca.crl"

[roles.sensor]
push_topics = ["logs", "sensors"]

[roles.reader]
read_topics = ["*"]

[roles.logs]
read_topics = ["logs"]

[roles.analyst]
query = true

[roles.explorer]
list_topics = true
list_nodes = true

[roles.peer]
send_topics = ["*"]
accept_topics = ["*"]
"#;

/// A server running on a free port, its CA and folder.
struct Running {
    folder: PathBuf,
    ca: Ca,
    ca_issued: Issued,
    ca_certificate: String,
    server: Server,
    address: String,
    // Kept for the server's tasks to run.
    runtime: tokio::runtime::Runtime,
}

fn folder(name: &str) -> PathBuf {
    static COUNT: AtomicUsize = AtomicUsize::new(0);
    let folder = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join(format!(
        "server-{}-{}-{name}",
        std::process::id(),
        COUNT.fetch_add(1, Ordering::Relaxed)
    ));
    let _ = std::fs::remove_dir_all(&folder);
    std::fs::create_dir_all(&folder).unwrap();
    folder
}

impl Running {
    fn start(name: &str) -> Running {
        Running::start_with(name, "")
    }

    /// With more `[server]` settings (and sections after them).
    fn start_with(name: &str, settings: &str) -> Running {
        let ca = Ca::create("Test CA", 10).unwrap();
        Running::start_in(folder(name), ca, "server-1", settings, "127.0.0.1:0")
    }

    /// Another server with the same CA, named `server`.
    fn peer(&self, name: &str, server: &str, settings: &str) -> Running {
        let ca = self.ca_issued.clone();
        Running::start_in(folder(name), ca, server, settings, "127.0.0.1:0")
    }

    fn start_in(
        folder: PathBuf,
        ca_issued: Issued,
        name: &str,
        settings: &str,
        bind: &str,
    ) -> Running {
        let ca = Ca::load(&ca_issued.certificate, &ca_issued.key).unwrap();
        let server = ca
            .issue(&Identity::new(name, &["peer"]).unwrap(), Usage::Server, 10)
            .unwrap();
        std::fs::write(folder.join("ca.crt"), &ca_issued.certificate).unwrap();
        std::fs::write(folder.join("server.crt"), &server.certificate).unwrap();
        std::fs::write(folder.join("server.key"), &server.key).unwrap();
        let config = CONFIG.replace(
            "[roles.sensor]",
            &format!(
                "{settings}
[roles.sensor]"
            ),
        );
        std::fs::write(folder.join("server.toml"), config).unwrap();
        Running::run(folder, ca, ca_issued, bind)
    }

    /// Stopped as `bakashrot-server` stops, `meanwhile` run, then started
    /// again on the same database and address.
    fn restart_after(self, meanwhile: impl FnOnce()) -> Running {
        let Running {
            folder,
            ca,
            ca_issued,
            server,
            address,
            runtime,
            ..
        } = self;
        runtime.block_on(server.stop());
        runtime.shutdown_background();
        meanwhile();
        Running::run(folder, ca, ca_issued, &address)
    }

    /// Its `server.toml` served on `bind`, retention and replication going.
    fn run(folder: PathBuf, ca: Ca, ca_issued: Issued, bind: &str) -> Running {
        let config = Config::load(&folder.join("server.toml")).unwrap();
        let server = Server::start(config).unwrap();
        let runtime = tokio::runtime::Runtime::new().unwrap();
        let listener = runtime
            .block_on(tokio::net::TcpListener::bind(bind))
            .unwrap();
        let address = listener.local_addr().unwrap().to_string();
        let serving = server.clone();
        runtime.spawn(async move { serving.serve(listener).await });
        let retaining = server.clone();
        runtime.spawn(async move { retaining.apply_retention().await });
        let replicating = server.clone();
        runtime.spawn(async move { replicating.replicate().await });
        Running {
            folder,
            ca,
            ca_certificate: ca_issued.certificate.clone(),
            ca_issued,
            server,
            address,
            runtime,
        }
    }

    fn issue(&self, name: &str, roles: &[&str]) -> Issued {
        self.ca
            .issue(&Identity::new(name, roles).unwrap(), Usage::Client, 10)
            .unwrap()
    }

    fn connect(&self, issued: &Issued) -> Result<Client, bakashrot_client::Error> {
        Client::connect(
            &self.address,
            &Settings {
                ca: &self.ca_certificate,
                certificate: &issued.certificate,
                key: &issued.key,
                crl: None,
            },
        )
    }
}

fn code(error: bakashrot_client::Error) -> u32 {
    error.code()
}

#[test]
fn push_and_read_back() {
    let running = Running::start("push");
    let kitchen = running.issue("kitchen", &["sensor", "reader"]);
    let mut client = running.connect(&kitchen).unwrap();
    assert_eq!((client.server(), client.node()), ("server-1", "kitchen"));

    assert_eq!(client.push("logs", r#"{"t": 21}"#).unwrap(), 1);
    assert_eq!(client.push("Logs", "not json").unwrap(), 2);
    assert_eq!(client.push("sensors", "{}").unwrap(), 1);

    let all = client.get_messages("logs", "kitchen", Some(0), 10).unwrap();
    let ids: Vec<u64> = all.messages.iter().map(|m| m.id).collect();
    assert_eq!(ids, [1, 2]);
    assert_eq!(all.messages[0].data, r#"{"t": 21}"#);
    assert!(all.messages[0].pushed_at > 1_700_000_000_000);
    let latest = client.get_messages("logs", "kitchen", None, 1).unwrap();
    assert_eq!(latest.messages[0].data, "not json");
    // A node without any message: unknown.
    assert_eq!(
        code(client.get_messages("logs", "nobody", None, 1).unwrap_err()),
        ErrorCode::UnknownName.code()
    );

    // Another connection sees them.
    let mut other = running.connect(&kitchen).unwrap();
    assert_eq!(
        other
            .get_messages("logs", "kitchen", Some(1), 10)
            .unwrap()
            .messages
            .len(),
        1
    );
}

#[test]
fn refusals_keep_the_connection() {
    let running = Running::start("refusals");
    let mut sensor = running
        .connect(&running.issue("sensor-1", &["sensor"]))
        .unwrap();
    let mut reader = running
        .connect(&running.issue("screen", &["reader"]))
        .unwrap();

    fn refused<T: std::fmt::Debug>(result: Result<T, bakashrot_client::Error>) -> u32 {
        code(result.unwrap_err())
    }
    assert_eq!(
        refused(sensor.get_messages("logs", "sensor-1", None, 1)),
        ErrorCode::NotAllowed.code()
    );
    assert_eq!(
        refused(reader.push("logs", "{}")),
        ErrorCode::NotAllowed.code()
    );
    // A topic is its roles': one that none of them names.
    assert_eq!(
        refused(sensor.push("nope", "{}")),
        ErrorCode::NotAllowed.code()
    );
    // The client checks names before sending.
    assert_eq!(
        refused(sensor.push("a b", "{}")),
        ErrorCode::InvalidArgument.code()
    );
    // Still connected.
    assert_eq!(sensor.push("logs", "{}").unwrap(), 1);
    assert_eq!(
        reader
            .get_messages("logs", "sensor-1", None, 1)
            .unwrap()
            .messages
            .len(),
        1
    );
}

#[test]
fn certificates_refused() {
    let running = Running::start("certificates");
    // None of its roles is in the config: refused, saying so.
    let error = running
        .connect(&running.issue("visitor", &["guest"]))
        .unwrap_err();
    assert_eq!(error.code(), ErrorCode::NotAllowed.code(), "{error}");
    assert!(error.message().contains("guest"), "{error}");

    // Another CA's client: the server refuses it in the handshake.
    let other = Ca::create("Other CA", 10).unwrap();
    let stranger = Ca::load(&other.certificate, &other.key)
        .unwrap()
        .issue(
            &Identity::new("kitchen", &["sensor"]).unwrap(),
            Usage::Client,
            10,
        )
        .unwrap();
    let error = running.connect(&stranger).unwrap_err();
    assert_eq!(error.code(), ErrorCode::AuthRejected.code(), "{error}");

    // A client trusting another CA: the server isn't verified.
    let error = Client::connect(
        &running.address,
        &Settings {
            ca: &other.certificate,
            certificate: &stranger.certificate,
            key: &stranger.key,
            crl: None,
        },
    )
    .unwrap_err();
    assert_eq!(error.code(), ErrorCode::ServerNotVerified.code(), "{error}");

    // Nothing listening.
    let error = Client::connect(
        "127.0.0.1:1",
        &Settings {
            ca: &running.ca_certificate,
            certificate: &stranger.certificate,
            key: &stranger.key,
            crl: None,
        },
    )
    .unwrap_err();
    assert_eq!(error.code(), ErrorCode::ConnectFailed.code(), "{error}");
}

#[test]
fn revoked_certificates_are_dropped() {
    let running = Running::start("revoked");
    let kitchen = running.issue("kitchen", &["sensor"]);
    let garage = running.issue("garage", &["sensor"]);
    let mut connected = running.connect(&kitchen).unwrap();
    let mut kept = running.connect(&garage).unwrap();
    assert_eq!(connected.push("logs", "{}").unwrap(), 1);

    let serial = summarize(&kitchen.certificate).unwrap().serial;
    let crl = running.ca.revocation_list(&[serial], 30).unwrap();
    std::fs::write(running.folder.join("ca.crl"), crl).unwrap();
    assert_eq!(running.server.reload_revocations().unwrap(), 1);

    // Its open connection goes at its next request, a new one is refused.
    let error = connected.push("logs", "{}").unwrap_err();
    assert_eq!(error.code(), ErrorCode::ConnectionLost.code(), "{error}");
    let error = running.connect(&kitchen).unwrap_err();
    assert_eq!(error.code(), ErrorCode::AuthRejected.code(), "{error}");
    // Others go on.
    assert_eq!(kept.push("logs", "{}").unwrap(), 1);

    // A CRL that isn't the CA's is refused, the previous one stays.
    std::fs::write(running.folder.join("ca.crl"), "not a CRL").unwrap();
    assert!(running.server.reload_revocations().is_err());
    assert!(running.connect(&kitchen).is_err());
}

#[test]
fn pushes_at_once() {
    let running = Running::start("concurrent");
    let nodes = ["n1", "n2", "n3"];
    let threads: Vec<_> = nodes
        .iter()
        .flat_map(|node| {
            let issued = running.issue(node, &["sensor"]);
            // Two connections per node: one stream of ids between them.
            (0..2).map(move |_| issued.clone())
        })
        .map(|issued| {
            let mut client = running.connect(&issued).unwrap();
            std::thread::spawn(move || {
                (0..200)
                    .map(|i| client.push("logs", &format!("{{\"i\": {i}}}")).unwrap())
                    .collect::<Vec<u64>>()
            })
        })
        .collect();
    let mut ids: Vec<Vec<u64>> = threads.into_iter().map(|t| t.join().unwrap()).collect();
    let reader = running.issue("screen", &["reader"]);
    let mut reader = running.connect(&reader).unwrap();
    for (node, pair) in nodes.iter().zip(ids.chunks_mut(2)) {
        let mut all: Vec<u64> = pair.concat();
        all.sort_unstable();
        assert_eq!(all, (1..=400).collect::<Vec<u64>>(), "{node}");
        let latest = reader.get_messages("logs", node, None, 1).unwrap();
        assert_eq!(latest.messages[0].id, 400);
    }
}

/// Pushes per second through a whole server: 10 clients over TLS, each
/// its own node, one push at a time each (the group commit gathers them).
/// Not run by default: `PUSHES=20000 cargo test --release -p
/// bakashrot-server -- --ignored --nocapture` (pushes per client; `SYNC`
/// `full`, the default, or `normal`; `CLIENTS`, 10 by default).
#[test]
#[ignore]
fn push_rate() {
    let per_client: usize = std::env::var("PUSHES").map_or(20_000, |n| n.parse().unwrap());
    let sync = std::env::var("SYNC").unwrap_or_else(|_| "full".into());
    let count: usize = std::env::var("CLIENTS").map_or(10, |n| n.parse().unwrap());
    let running = Running::start_with("rate", &format!("synchronous = \"{sync}\""));
    let json = format!(
        r#"{{"kind":"temp","value":21.37,"pad":"{}"}}"#,
        "x".repeat(160)
    );
    let clients: Vec<Client> = (0..count)
        .map(|n| {
            running
                .connect(&running.issue(&format!("node{n}"), &["sensor"]))
                .unwrap()
        })
        .collect();
    let start = std::time::Instant::now();
    let threads: Vec<_> = clients
        .into_iter()
        .map(|mut client| {
            let json = json.clone();
            std::thread::spawn(move || {
                let mut slowest = std::time::Duration::ZERO;
                for _ in 0..per_client {
                    let push = std::time::Instant::now();
                    client.push("logs", &json).unwrap();
                    slowest = slowest.max(push.elapsed());
                }
                slowest
            })
        })
        .collect();
    let slowest = threads
        .into_iter()
        .map(|t| t.join().unwrap())
        .max()
        .unwrap();
    let took = start.elapsed().as_secs_f64();
    let total = per_client * count;
    println!(
        "{sync}: {total} pushes from {count} clients in {took:.1} s: {:.0}/s, slowest push {} ms",
        total as f64 / took,
        slowest.as_millis()
    );
}

fn ids(messages: &Messages) -> Vec<u64> {
    messages.messages.iter().map(|message| message.id).collect()
}

/// `OldSource/Tests/GetMessages-Test.ps1`, the server's part (the tool's
/// is step 8).
#[test]
fn runs_of_messages() {
    let running = Running::start("runs");
    let mut kitchen = running
        .connect(&running.issue("kitchen", &["sensor", "reader"]))
        .unwrap();

    // Nothing yet: none, not a refusal, once the node is known.
    kitchen.push("sensors", "{}").unwrap();
    let none = kitchen
        .get_messages("logs", "kitchen", Some(0), 100)
        .unwrap();
    assert!(none.messages.is_empty() && !none.more);
    assert!(
        kitchen
            .get_messages("logs", "kitchen", None, 1)
            .unwrap()
            .messages
            .is_empty()
    );

    for i in 1..=120 {
        assert_eq!(kitchen.push("logs", &format!(r#"{{"i":{i}}}"#)).unwrap(), i);
    }
    let run = |client: &mut Client, after, limit| {
        client
            .get_messages("logs", "kitchen", after, limit)
            .unwrap()
    };
    let first = run(&mut kitchen, Some(0), 100);
    assert_eq!(ids(&first), (1..=100).collect::<Vec<_>>());
    assert!(first.more);
    assert_eq!(first.messages[99].data, r#"{"i":100}"#);
    let rest = run(&mut kitchen, Some(100), 100);
    assert_eq!(ids(&rest), (101..=120).collect::<Vec<_>>());
    assert!(!rest.more);
    assert_eq!(
        ids(&run(&mut kitchen, Some(115), 100)),
        [116, 117, 118, 119, 120]
    );
    let some = run(&mut kitchen, Some(10), 7);
    assert_eq!(ids(&some), (11..=17).collect::<Vec<_>>());
    assert!(some.more);
    let past = run(&mut kitchen, Some(120), 100);
    assert!(past.messages.is_empty() && !past.more);
    // The last ones, in order; `more` is only for runs after an id.
    let latest = run(&mut kitchen, None, 2);
    assert_eq!(ids(&latest), [119, 120]);
    assert!(!latest.more);

    // Another client allowed to read logs only.
    let mut screen = running
        .connect(&running.issue("screen", &["logs"]))
        .unwrap();
    assert_eq!(ids(&run(&mut screen, Some(100), 100)).len(), 20);
    let refused = |result: Result<Messages, bakashrot_client::Error>| code(result.unwrap_err());
    assert_eq!(
        refused(screen.get_messages("sensors", "kitchen", None, 1)),
        ErrorCode::NotAllowed.code()
    );
    // A topic without messages: none, for a node that has some elsewhere.
    assert!(
        kitchen
            .get_messages("nothing", "kitchen", None, 1)
            .unwrap()
            .messages
            .is_empty()
    );
    assert_eq!(
        refused(kitchen.get_messages("logs", "nobody", None, 1)),
        ErrorCode::UnknownName.code()
    );
    // Names without case.
    assert_eq!(
        ids(&screen.get_messages("LOGS", "Kitchen", None, 1).unwrap()),
        [120]
    );

    // Data that isn't one line of JSON comes back as stored.
    let text = "not JSON\r\nover two lines\twith a tab, ünïcode";
    assert_eq!(kitchen.push("logs", text).unwrap(), 121);
    assert_eq!(run(&mut kitchen, None, 1).messages[0].data, text);
}

/// `OldSource/Tests/BigMessages-Test.ps1`, one server's part (replicating
/// them is step 11): up to the limit, answers split at about 1 MB.
#[test]
fn big_messages() {
    let running = Running::start("big");
    let mut kitchen = running
        .connect(&running.issue("kitchen", &["sensor", "reader", "analyst"]))
        .unwrap();
    let message = |size: usize, n: &str| {
        let head = format!(r#"{{"n":"{n}","pad":""#);
        format!("{head}{}\"}}", "x".repeat(size - head.len() - 2))
    };

    // 5 of 600 KB and the biggest: one per answer, the biggest alone.
    let mut pushed: Vec<String> = (0..5)
        .map(|i| message(600 * 1024, &format!("m{i}")))
        .collect();
    pushed.push(message(MAX_MESSAGE_SIZE, "max"));
    for (i, data) in pushed.iter().enumerate() {
        assert_eq!(kitchen.push("logs", data).unwrap(), i as u64 + 1);
    }
    let (mut read, mut answers, mut after) = (Vec::new(), 0, 0);
    loop {
        let answer = kitchen
            .get_messages("logs", "kitchen", Some(after), 100)
            .unwrap();
        answers += 1;
        assert_eq!(answer.messages.len(), 1);
        after = answer.messages[0].id;
        read.extend(answer.messages.into_iter().map(|message| message.data));
        if !answer.more {
            break;
        }
    }
    assert_eq!(answers, 6);
    assert!(read == pushed, "read back whole");

    // One byte over: the client refuses it, the connection stays.
    let error = kitchen
        .push("logs", &message(MAX_MESSAGE_SIZE + 1, "over"))
        .unwrap_err();
    assert_eq!(error.code(), ErrorCode::InvalidArgument.code(), "{error}");
    assert_eq!(kitchen.push("logs", r#"{"n":"small"}"#).unwrap(), 7);
    let latest = kitchen.get_messages("logs", "kitchen", None, 1).unwrap();
    assert_eq!(latest.messages[0].data, r#"{"n":"small"}"#);

    // Stored as pushed; a result over the limit is refused, not cut.
    let sizes = kitchen
        .query(
            "SELECT message_id, length(message_data) AS size FROM messages WHERE message_id >= 5",
        )
        .unwrap();
    assert_eq!(
        sizes,
        format!(
            r#"{{"columns":["message_id","size"],"rows":[["5","{}"],["6","{MAX_MESSAGE_SIZE}"],["7","13"]]}}"#,
            600 * 1024
        )
    );
    let error = kitchen
        .query("SELECT message_data, message_data FROM messages WHERE message_id = 6")
        .unwrap_err();
    assert_eq!(error.code(), ErrorCode::TooBig.code(), "{error}");
}

#[test]
fn names() {
    let running = Running::start("names");
    let mut sensor = running
        .connect(&running.issue("kitchen", &["sensor"]))
        .unwrap();
    sensor.push("logs", "{}").unwrap();
    let mut garage = running
        .connect(&running.issue("garage", &["sensor"]))
        .unwrap();
    garage.push("sensors", "{}").unwrap();
    let mut screen = running
        .connect(&running.issue("screen", &["logs"]))
        .unwrap();
    let mut analyst = running
        .connect(&running.issue("analyst-1", &["analyst"]))
        .unwrap();

    let names = |client: &mut Client, kind| {
        let list = client.list_names(kind).unwrap();
        assert_eq!(list.kind, kind);
        assert!(!list.truncated);
        list.names
    };
    // Topics: those it may push to or read; every one for a query role.
    assert_eq!(names(&mut sensor, NameKind::Topic), ["logs", "sensors"]);
    assert_eq!(names(&mut screen, NameKind::Topic), ["logs"]);
    assert_eq!(names(&mut analyst, NameKind::Topic), ["logs", "sensors"]);
    // Nodes: those of the topics it may read; every one for a query role.
    assert!(names(&mut sensor, NameKind::Node).is_empty());
    assert_eq!(names(&mut screen, NameKind::Node), ["kitchen"]);
    assert_eq!(names(&mut analyst, NameKind::Node), ["garage", "kitchen"]);
    // `list_topics` and `list_nodes`: every one, without reading any.
    let mut explorer = running
        .connect(&running.issue("browser", &["explorer"]))
        .unwrap();
    assert_eq!(names(&mut explorer, NameKind::Topic), ["logs", "sensors"]);
    assert_eq!(names(&mut explorer, NameKind::Node), ["garage", "kitchen"]);
    assert_eq!(
        code(
            explorer
                .get_messages("logs", "kitchen", None, 1)
                .unwrap_err()
        ),
        ErrorCode::NotAllowed.code()
    );
}

/// The query parts of `OldSource/Tests/BigMessages-Test.ps1`.
#[test]
fn queries() {
    let running = Running::start("queries");
    let mut sensor = running
        .connect(&running.issue("kitchen", &["sensor"]))
        .unwrap();
    for data in [r#"{"n":"small"}"#, "plain text", r#"{"n":"other"}"#] {
        sensor.push("logs", data).unwrap();
    }
    let error = sensor.query("SELECT 1").unwrap_err();
    assert_eq!(error.code(), ErrorCode::NotAllowed.code(), "{error}");

    let mut analyst = running
        .connect(&running.issue("analyst-1", &["analyst"]))
        .unwrap();
    assert_eq!(
        analyst
            .query("SELECT message_id, is_json FROM messages ORDER BY message_id")
            .unwrap(),
        r#"{"columns":["message_id","is_json"],"rows":[["1","1"],["2","0"],["3","1"]]}"#
    );
    assert_eq!(
        analyst
            .query("SELECT COUNT(*) AS n FROM messages WHERE is_json = 1 AND message_data ->> '$.n' = 'small'")
            .unwrap(),
        r#"{"columns":["n"],"rows":[["1"]]}"#
    );
    assert_eq!(
        analyst
            .query("SELECT message_id FROM messages WHERE message_id < 0")
            .unwrap(),
        r#"{"columns":["message_id"],"rows":[]}"#
    );
    let failed = |result: Result<String, bakashrot_client::Error>| {
        let error = result.unwrap_err();
        assert_eq!(error.code(), ErrorCode::QueryFailed.code(), "{error}");
        error.message().to_owned()
    };
    // A non-JSON row fails the query, never a partial answer.
    let why = failed(
        analyst.query("SELECT COUNT(*) FROM messages WHERE message_data ->> '$.n' = 'small'"),
    );
    assert!(
        why.contains("malformed JSON") && why.contains("is_json = 1"),
        "{why}"
    );
    let why = failed(analyst.query("SELECT nope FROM data"));
    assert!(why.contains("nope"), "{why}");
    failed(analyst.query("DELETE FROM data"));
    failed(analyst.query("SELECT 1; SELECT 2"));
    // Still connected, nothing deleted.
    assert_eq!(
        analyst.query("SELECT COUNT(*) AS n FROM data").unwrap(),
        r#"{"columns":["n"],"rows":[["3"]]}"#
    );
}

const MIB: usize = ATTACHMENT_PART_SIZE as usize;

/// `size` bytes that differ with `seed`.
fn bytes(size: usize, seed: u8) -> Vec<u8> {
    (0..size)
        .map(|i| (i as u8).wrapping_mul(31).wrapping_add(seed))
        .collect()
}

fn sha256(data: &[u8]) -> [u8; 32] {
    let mut digest = [0; 32];
    digest.copy_from_slice(aws_lc_rs::digest::digest(&aws_lc_rs::digest::SHA256, data).as_ref());
    digest
}

#[test]
fn attachments() {
    let running = Running::start_with("attachments", "max_attachment_size = \"8M\"");
    let mut kitchen = running
        .connect(&running.issue("kitchen", &["sensor", "reader"]))
        .unwrap();
    let sizes = [100 * 1024, 5 * MIB + 123, 2 * MIB, 1, MIB];
    let files: Vec<Vec<u8>> = (0..sizes.len()).map(|i| bytes(sizes[i], i as u8)).collect();
    for (i, file) in files.iter().enumerate() {
        let id = kitchen
            .push_with_attachment(
                "logs",
                &format!(r#"{{"n":{}}}"#, i + 1),
                &mut Cursor::new(file),
            )
            .unwrap();
        assert_eq!(id, i as u64 + 1);
    }
    assert_eq!(kitchen.push("logs", r#"{"n":6}"#).unwrap(), 6);

    let read = kitchen
        .get_messages("logs", "kitchen", Some(0), 10)
        .unwrap();
    let attachments: Vec<_> = read.messages.iter().map(|m| m.attachment.clone()).collect();
    let mut expected: Vec<_> = sizes
        .iter()
        .map(|&size| {
            Some(StoredAttachment {
                size: size as u64,
                ready: true,
            })
        })
        .collect();
    expected.push(None);
    assert_eq!(attachments, expected);

    for (i, file) in files.iter().enumerate() {
        let mut out = Vec::new();
        let size = kitchen
            .get_attachment("logs", "kitchen", i as u64 + 1, &mut out)
            .unwrap();
        assert_eq!((size, &out), (file.len() as u64, file), "#{}", i + 1);
    }
    let saved = running.folder.join("saved.bin");
    assert_eq!(
        kitchen
            .save_attachment("logs", "kitchen", 2, &saved)
            .unwrap(),
        sizes[1] as u64
    );
    assert_eq!(std::fs::read(&saved).unwrap(), files[1]);
    assert!(!running.folder.join("saved.bin.download").exists());

    // None, or none to give: refused, no file left.
    let none = running.folder.join("none.bin");
    for id in [6, 99] {
        let error = kitchen
            .save_attachment("logs", "kitchen", id, &none)
            .unwrap_err();
        assert_eq!(error.code(), ErrorCode::NotFound.code(), "{error}");
        assert!(
            error.message().contains(&format!("logs:kitchen#{id}")),
            "{error}"
        );
    }
    assert!(!none.exists() && !running.folder.join("none.bin.download").exists());
    let error = kitchen
        .get_attachment("nothing", "kitchen", 1, &mut Vec::new())
        .unwrap_err();
    assert_eq!(error.code(), ErrorCode::NotFound.code(), "{error}");
    let mut logs_only = running
        .connect(&running.issue("lounge", &["logs"]))
        .unwrap();
    let mut out = Vec::new();
    assert_eq!(
        logs_only
            .get_attachment("logs", "kitchen", 3, &mut out)
            .unwrap(),
        2 * MIB as u64
    );
    kitchen
        .push_with_attachment("sensors", "{}", &mut Cursor::new(b"s"))
        .unwrap();
    let error = logs_only
        .get_attachment("sensors", "kitchen", 1, &mut Vec::new())
        .unwrap_err();
    assert_eq!(error.code(), ErrorCode::NotAllowed.code(), "{error}");

    // Over the server's limit, or empty: refused, nothing stored.
    let big = bytes(8 * MIB + 1, 9);
    let error = kitchen
        .push_with_attachment("logs", "{}", &mut Cursor::new(&big))
        .unwrap_err();
    assert_eq!(error.code(), ErrorCode::TooBig.code(), "{error}");
    let error = kitchen
        .push_with_attachment("logs", "{}", &mut Cursor::new(b""))
        .unwrap_err();
    assert_eq!(error.code(), ErrorCode::InvalidArgument.code(), "{error}");
    assert_eq!(kitchen.push("logs", "{}").unwrap(), 7);

    let mut analyst = running
        .connect(&running.issue("analyst-1", &["analyst"]))
        .unwrap();
    assert_eq!(
        analyst
            .query("SELECT COUNT(*), SUM(state = 'ready') FROM attachments")
            .unwrap(),
        r#"{"columns":["COUNT(*)","SUM(state = 'ready')"],"rows":[["6","6"]]}"#
    );
    assert_eq!(
        analyst
            .query("SELECT COUNT(*) FROM attachment_parts")
            .unwrap(),
        r#"{"columns":["COUNT(*)"],"rows":[["12"]]}"#,
        "1 + 6 + 2 + 1 + 1 + 1 parts"
    );

    let none = Running::start_with("no-attachments", "max_attachment_size = 0");
    let mut client = none.connect(&none.issue("kitchen", &["sensor"])).unwrap();
    let error = client
        .push_with_attachment("logs", "{}", &mut Cursor::new(b"x"))
        .unwrap_err();
    assert_eq!(error.code(), ErrorCode::TooBig.code(), "{error}");
}

/// A source read twice: `first`, then `second` (as if it changed in
/// between), the second time failing after `fail_after` bytes if set.
struct Changing {
    first: Vec<u8>,
    second: Vec<u8>,
    fail_after: Option<usize>,
    pass: usize,
    at: usize,
}

impl Read for Changing {
    fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
        let data = if self.pass == 1 {
            &self.first
        } else {
            &self.second
        };
        let mut end = data.len().min(self.at + buffer.len());
        if self.pass > 1
            && let Some(fail) = self.fail_after
        {
            if self.at >= fail {
                return Err(std::io::Error::other("the disk is gone"));
            }
            end = end.min(fail);
        }
        let read = end - self.at;
        buffer[..read].copy_from_slice(&data[self.at..end]);
        self.at = end;
        Ok(read)
    }
}

impl Seek for Changing {
    fn seek(&mut self, to: SeekFrom) -> std::io::Result<u64> {
        assert_eq!(to, SeekFrom::Start(0), "only rewound");
        self.pass += 1;
        self.at = 0;
        Ok(0)
    }
}

/// A connection speaking the protocol itself, for what the client never
/// sends.
struct Raw(StreamOwned<ClientConnection, TcpStream>);

impl Raw {
    fn connect(running: &Running, issued: &Issued) -> Raw {
        let config = tls::client_config(
            &running.ca_certificate,
            &issued.certificate,
            &issued.key,
            Revocations::none().shared(),
        )
        .unwrap();
        let tcp = TcpStream::connect(&running.address).unwrap();
        tcp.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        let connection = ClientConnection::new(config, tls::server_name()).unwrap();
        let mut raw = Raw(StreamOwned::new(connection, tcp));
        frame::write_version(&mut raw.0).unwrap();
        raw.0.flush().unwrap();
        frame::read_version(&mut raw.0).unwrap();
        assert!(matches!(raw.receive(), Some(Packet::Welcome(_))));
        raw
    }

    fn send(&mut self, packet: impl Into<Packet>) {
        frame::write(&mut self.0, &packet.into().encode()).unwrap();
        self.0.flush().unwrap();
    }

    /// The next packet, none once the server closed the connection.
    fn receive(&mut self) -> Option<Packet> {
        let bytes = frame::read(&mut self.0, MAX_PACKET_SIZE).ok()??;
        Some(Packet::decode(&bytes).unwrap())
    }

    #[track_caller]
    fn refused(&mut self, code: ErrorCode) {
        match self.receive() {
            Some(Packet::RequestRefused(refused)) => {
                assert_eq!(refused.code, code.code(), "{refused:?}")
            }
            other => panic!("expected {code}, got {other:?}"),
        }
    }

    /// Pushes with an attachment of `size` bytes and `sha256`, then the
    /// parts given.
    fn push(&mut self, size: usize, sha256: [u8; 32], parts: &[&[u8]]) {
        self.send(PushMessage {
            topic: "logs".into(),
            data: "{}".into(),
            attachment: Some(Attachment {
                size: size as u64,
                sha256,
            }),
        });
        assert!(matches!(self.receive(), Some(Packet::Continue(_))));
        for part in parts {
            self.send(AttachmentPart {
                data: part.to_vec(),
            });
        }
    }
}

#[test]
fn attachment_edges() {
    let running = Running::start("attachment-edges");
    let issued = running.issue("kitchen", &["sensor", "reader"]);
    let mut kitchen = running.connect(&issued).unwrap();
    let mut analyst = running
        .connect(&running.issue("analyst-1", &["analyst"]))
        .unwrap();
    let uploads = |analyst: &mut Client| {
        analyst
            .query("SELECT COUNT(*) FROM attachments WHERE state = 'uploading'")
            .unwrap()
    };
    let none_left = r#"{"columns":["COUNT(*)"],"rows":[["0"]]}"#;

    // Changed between its SHA-256 and its sending: refused, dropped, the
    // connection still there.
    let file = bytes(3 * MIB, 1);
    let mut changed = Changing {
        first: file.clone(),
        second: bytes(3 * MIB, 2),
        fail_after: None,
        pass: 0,
        at: 0,
    };
    let error = kitchen
        .push_with_attachment("logs", "{}", &mut changed)
        .unwrap_err();
    assert_eq!(error.code(), ErrorCode::DataMismatch.code(), "{error}");
    assert_eq!(
        kitchen
            .push_with_attachment("logs", "{}", &mut Cursor::new(&file))
            .unwrap(),
        1
    );

    // Failing in the middle: the client closes, the server drops the upload.
    let mut failing = Changing {
        first: file.clone(),
        second: file.clone(),
        fail_after: Some(MIB + 10),
        pass: 0,
        at: 0,
    };
    let error = kitchen
        .push_with_attachment("logs", "{}", &mut failing)
        .unwrap_err();
    assert_eq!(error.code(), ErrorCode::FileError.code(), "{error}");
    let error = kitchen.push("logs", "{}").unwrap_err();
    assert_eq!(error.code(), ErrorCode::ConnectionLost.code(), "{error}");
    let started = Instant::now();
    while uploads(&mut analyst) != none_left {
        assert!(
            started.elapsed() < Duration::from_secs(10),
            "the cut upload stays"
        );
        std::thread::sleep(Duration::from_millis(50));
    }

    // A part of the wrong size: refused once all came, the connection kept.
    let mut raw = Raw::connect(&running, &issued);
    let size = 2 * MIB + 1;
    let file = bytes(size, 3);
    raw.push(
        size,
        sha256(&file),
        &[&file[..1000], &file[MIB..2 * MIB], &file[2 * MIB..]],
    );
    raw.refused(ErrorCode::InvalidRequest);
    raw.push(
        size,
        sha256(&file),
        &[&file[..MIB], &file[MIB..2 * MIB], &file[2 * MIB..]],
    );
    assert!(matches!(raw.receive(), Some(Packet::MessagePushed(pushed)) if pushed.message_id == 2));
    // A wrong SHA-256, sent by the client.
    raw.push(
        size,
        [7; 32],
        &[&file[..MIB], &file[MIB..2 * MIB], &file[2 * MIB..]],
    );
    raw.refused(ErrorCode::DataMismatch);

    // From a part on, as a cut download goes on.
    let get = |from_part| GetAttachment {
        topic: "logs".into(),
        node: "kitchen".into(),
        message_id: 2,
        from_part,
    };
    raw.send(get(1));
    match raw.receive() {
        Some(Packet::Attachment(attachment)) => assert_eq!(attachment.sha256, sha256(&file)),
        other => panic!("{other:?}"),
    }
    let mut rest = Vec::new();
    for _ in 1..3 {
        let Some(Packet::AttachmentPart(part)) = raw.receive() else {
            panic!("a part")
        };
        rest.extend(part.data);
    }
    assert_eq!(rest, file[MIB..]);
    raw.send(get(3));
    raw.refused(ErrorCode::InvalidRequest);

    // Something else than a part: the connection is closed, the upload
    // dropped.
    raw.push(size, sha256(&file), &[&file[..MIB]]);
    raw.send(PushMessage {
        topic: "logs".into(),
        data: "{}".into(),
        attachment: None,
    });
    assert!(raw.receive().is_none(), "closed");
    let started = Instant::now();
    while uploads(&mut analyst) != none_left {
        assert!(
            started.elapsed() < Duration::from_secs(10),
            "the upload stays"
        );
        std::thread::sleep(Duration::from_millis(50));
    }
    let messages = analyst
        .query("SELECT message_id FROM messages ORDER BY 1")
        .unwrap();
    assert_eq!(
        messages,
        r#"{"columns":["message_id"],"rows":[["1"],["2"]]}"#
    );
}

#[test]
fn stops_cleanly() {
    // 8 nodes pushing flat out, the server stopped under them: every push
    // answered is stored, the ones after refused as the server stopping.
    let running = Running::start("stop");
    let threads: Vec<_> = (0..8)
        .map(|n| {
            let mut client = running
                .connect(&running.issue(&format!("n{n}"), &["sensor"]))
                .unwrap();
            std::thread::spawn(move || {
                let mut answered = 0;
                loop {
                    match client.push("logs", "{}") {
                        Ok(id) => answered = id,
                        Err(error) => return (answered, error.code()),
                    }
                }
            })
        })
        .collect();
    std::thread::sleep(Duration::from_millis(300));
    running.runtime.block_on(running.server.stop());
    let stopped: Vec<(u64, u32)> = threads.into_iter().map(|t| t.join().unwrap()).collect();

    let running = running.restart_after(|| {});
    let mut reader = running
        .connect(&running.issue("reader", &["reader"]))
        .unwrap();
    for (n, (answered, code)) in stopped.into_iter().enumerate() {
        assert_eq!(code, ErrorCode::ServerError.code(), "n{n}");
        assert!(answered > 0, "n{n} pushed nothing");
        let latest = reader.get_messages("logs", &format!("n{n}"), None, 1);
        // The last push may have been committed after its answer was lost.
        assert!(latest.unwrap().messages[0].id >= answered, "n{n}");
    }
}

#[test]
fn retention() {
    // logs kept 2 s, sensors forever; looked at every second.
    let running = Running::start_with(
        "retention",
        "retention_interval = \"1s\"\n\n[retention]\nlogs = \"2s\"\n",
    );
    let mut kitchen = running
        .connect(&running.issue("kitchen", &["sensor", "reader"]))
        .unwrap();
    let mut analyst = running
        .connect(&running.issue("analyst", &["analyst"]))
        .unwrap();
    let mut count = |sql: &str| {
        let result = analyst.query(sql).unwrap();
        result
            .strip_prefix(r#"{"columns":["n"],"rows":[[""#)
            .and_then(|rest| rest.strip_suffix(r#""]]}"#))
            .unwrap_or_else(|| panic!("{result}"))
            .parse::<u64>()
            .unwrap()
    };
    let logs = "SELECT COUNT(*) AS n FROM messages WHERE topic = 'logs'";
    let attachments = "SELECT (SELECT COUNT(*) FROM attachments) \
                       + (SELECT COUNT(*) FROM attachment_parts) AS n";

    let file = bytes(2 * MIB + 5, 7);
    kitchen
        .push_with_attachment("logs", "{}", &mut Cursor::new(&file))
        .unwrap();
    kitchen.push("logs", "{}").unwrap();
    assert_eq!(kitchen.push("logs", "{}").unwrap(), 3);
    kitchen.push("sensors", "{}").unwrap();
    assert_eq!((count(logs), count(attachments)), (3, 4));

    // Gone past their age, the attachment with them; sensors' kept.
    let deadline = Instant::now() + Duration::from_secs(15);
    while (count(logs), count(attachments)) != (0, 0) {
        assert!(Instant::now() < deadline, "logs not deleted");
        std::thread::sleep(Duration::from_millis(100));
    }
    assert_eq!(
        count("SELECT COUNT(*) AS n FROM messages WHERE topic = 'sensors'"),
        1
    );

    // Ids go on; a younger message stays through a pass.
    assert_eq!(kitchen.push("logs", "{}").unwrap(), 4);
    std::thread::sleep(Duration::from_millis(1100));
    assert_eq!(count(logs), 1);
    let latest = kitchen.get_messages("logs", "kitchen", None, 1).unwrap();
    assert_eq!(latest.messages[0].id, 4);
}

/// Replication flat out, as the old `Tests/Bench/Bench-Replication.ps1`
/// (`-Parts Ramp -Ramp 10x0`): 4 servers in a Y (a hub pushing to 3
/// leaves, each pushing to the hub), `NODES` nodes (10) pushing to each
/// as fast as they're answered for `SECONDS` (30), then how far behind
/// each server is and how long until every one has every message. Run
/// with `cargo test --release -p bakashrot-server --test end_to_end
/// replication_rate -- --ignored --nocapture` (`SYNC`: `full`, the
/// default, or `normal`).
#[test]
#[ignore]
fn replication_rate() {
    let env =
        |name: &str, default: u64| std::env::var(name).map_or(default, |v| v.parse().unwrap());
    let (nodes, seconds) = (env("NODES", 10), env("SECONDS", 30));
    let sync = std::env::var("SYNC").unwrap_or_else(|_| "full".into());
    let batch = env("BATCH", 1000);
    // Free ports first: every server's push_to names the others.
    let addresses: Vec<String> = (0..4)
        .map(|_| {
            let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
            listener.local_addr().unwrap().to_string()
        })
        .collect();
    let ca = Ca::create("Bench CA", 10).unwrap();
    let servers: Vec<Running> = (0..4)
        .map(|n| {
            let push_to = match n {
                0 => addresses[1..].join("\", \""),
                _ => addresses[0].clone(),
            };
            let settings = format!(
                "synchronous = \"{sync}\"\n\n[replication]\npush_to = [\"{push_to}\"]\n\
                 accept_from = [\"127.0.0.1\"]\nbatch_size = {batch}\n"
            );
            let name = format!("server-{n}");
            Running::start_in(folder(&name), ca.clone(), &name, &settings, &addresses[n])
        })
        .collect();
    let json = format!(
        r#"{{"kind":"temp","value":21.37,"pad":"{}"}}"#,
        "x".repeat(160)
    );
    let clients: Vec<Client> = servers
        .iter()
        .enumerate()
        .flat_map(|(s, server)| {
            (0..nodes).map(move |n| {
                server
                    .connect(&server.issue(&format!("s{s}n{n}"), &["sensor"]))
                    .unwrap()
            })
        })
        .collect();
    let mut analysts: Vec<Client> = servers
        .iter()
        .map(|server| {
            server
                .connect(&server.issue("analyst", &["analyst"]))
                .unwrap()
        })
        .collect();
    let mut counts = || -> Vec<u64> {
        analysts
            .iter_mut()
            .map(|analyst| {
                let result = analyst.query("SELECT COUNT(*) AS n FROM data").unwrap();
                result[r#"{"columns":["n"],"rows":[[""#.len()..result.len() - 4]
                    .parse()
                    .unwrap()
            })
            .collect()
    };

    let start = Instant::now();
    let until = start + Duration::from_secs(seconds);
    let threads: Vec<_> = clients
        .into_iter()
        .map(|mut client| {
            let json = json.clone();
            std::thread::spawn(move || {
                let (mut pushed, mut slowest) = (0u64, Duration::ZERO);
                while Instant::now() < until {
                    let push = Instant::now();
                    client.push("logs", &json).unwrap();
                    slowest = slowest.max(push.elapsed());
                    pushed += 1;
                }
                (pushed, slowest)
            })
        })
        .collect();
    let results: Vec<(u64, Duration)> = threads.into_iter().map(|t| t.join().unwrap()).collect();
    let pushing = start.elapsed().as_secs_f64();
    let total: u64 = results.iter().map(|(pushed, _)| pushed).sum();
    let slowest = results.iter().map(|(_, slowest)| *slowest).max().unwrap();
    let at_end = counts();
    let drain = Instant::now();
    while counts().iter().any(|&count| count < total) {
        assert!(drain.elapsed() < Duration::from_secs(300), "not drained");
        std::thread::sleep(Duration::from_millis(200));
    }
    let drained = drain.elapsed().as_secs_f64();
    let behind: Vec<String> = at_end
        .iter()
        .map(|&count| format!("{:.1} s", (total - count) as f64 / (total as f64 / pushing)))
        .collect();
    println!(
        "{sync}, 4 servers x {nodes} nodes, {seconds} s: {total} pushes, {:.0}/s, slowest {} ms; \
         behind at the end (s of pushes; hub, leaves): {}; all everywhere {drained:.1} s later",
        total as f64 / pushing,
        slowest.as_millis(),
        behind.join(", ")
    );
}

/// Waits up to 15 s for `done`, every 100 ms.
fn wait_for(what: &str, mut done: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(15);
    while !done() {
        assert!(Instant::now() < deadline, "{what}: not in time");
        std::thread::sleep(Duration::from_millis(100));
    }
}

#[test]
fn replication() {
    // a pushes to b (and c); b takes from 127.0.0.1, c from elsewhere only.
    let b = Running::start_with(
        "replication-b",
        "\n[replication]\naccept_from = [\"127.0.0.1\"]\n",
    );
    let c = b.peer(
        "replication-c",
        "server-c",
        "\n[replication]\naccept_from = [\"10.9.9.9\"]\n",
    );
    let a = b.peer(
        "replication-a",
        "server-a",
        &format!(
            "\n[replication]\npush_to = [\"{}\", \"{}\"]\nsync_interval = \"1s\"\n\
             retry_delay = \"1s\"\n",
            b.address, c.address
        ),
    );
    let kitchen = a.issue("kitchen", &["sensor", "reader"]);
    let mut on_a = a.connect(&kitchen).unwrap();
    let file = bytes(2 * MIB + 5, 9);
    on_a.push_with_attachment("logs", "{\"n\":1}", &mut Cursor::new(&file))
        .unwrap();
    on_a.push("logs", "{\"n\":2}").unwrap();
    on_a.push("logs", "not json").unwrap();
    on_a.push("sensors", "{}").unwrap();

    // b gets them all, by name, with their ids, times and attachment.
    let mut on_b = b.connect(&b.issue("watcher", &["reader"])).unwrap();
    let read = |client: &mut Client, topic: &str| {
        client
            .get_messages(topic, "kitchen", Some(0), 100)
            .map(|answer| answer.messages)
            .unwrap_or_default()
    };
    wait_for("the messages on b", || {
        read(&mut on_b, "logs").len() == 3 && read(&mut on_b, "sensors").len() == 1
    });
    let (sent, got) = (read(&mut on_a, "logs"), read(&mut on_b, "logs"));
    let fields = |m: &bakashrot_proto::packets::MessageEntry| (m.id, m.pushed_at, m.data.clone());
    assert_eq!(
        sent.iter().map(fields).collect::<Vec<_>>(),
        got.iter().map(fields).collect::<Vec<_>>()
    );
    wait_for("the attachment on b", || {
        let mut out = Vec::new();
        on_b.get_attachment("logs", "kitchen", 1, &mut out).is_ok() && out == file
    });

    // c doesn't take from a: not in its accept_from.
    let mut analyst = c.connect(&c.issue("analyst", &["analyst"])).unwrap();
    assert_eq!(
        analyst.query("SELECT COUNT(*) AS n FROM messages").unwrap(),
        r#"{"columns":["n"],"rows":[["0"]]}"#
    );

    // One way: b's own pushes don't go to a (b has no push_to).
    let mut garage = b.connect(&b.issue("garage", &["sensor"])).unwrap();
    garage.push("logs", "{}").unwrap();
    std::thread::sleep(Duration::from_millis(2500));
    assert_eq!(
        code(
            on_a.get_messages("logs", "garage", Some(0), 10)
                .unwrap_err()
        ),
        ErrorCode::UnknownName.code()
    );

    // b stopped: a links again once it's back, sends what came meanwhile,
    // ids go on. Meanwhile a's copy of #6's attachment got damaged.
    drop((on_b, garage));
    let b = b.restart_after(|| {
        assert_eq!(on_a.push("logs", "{\"n\":4}").unwrap(), 4);
        assert_eq!(on_a.push("logs", "{\"n\":5}").unwrap(), 5);
        let other = bytes(MIB + 1, 3);
        let id = on_a
            .push_with_attachment("logs", "{\"n\":6}", &mut Cursor::new(&other))
            .unwrap();
        assert_eq!(id, 6);
        let raw = rusqlite::Connection::open(a.folder.join("bakashrot.sqlite")).unwrap();
        raw.execute(
            "UPDATE attachment_parts SET part_data = zeroblob(length(part_data)) \
             WHERE key = (SELECT max(key) FROM attachment_parts)",
            [],
        )
        .unwrap();
    });
    let mut on_b = b.connect(&b.issue("watcher", &["reader"])).unwrap();
    wait_for("the messages on b, restarted", || {
        read(&mut on_b, "logs")
            .iter()
            .map(|m| m.id)
            .collect::<Vec<_>>()
            == [1, 2, 3, 4, 5, 6]
    });

    // b refuses the damaged copy; a finds its own damaged and asks for it
    // again, instead of sending it again and again.
    wait_for("a's damaged copy noticed", || {
        on_a.get_attachment("logs", "kitchen", 6, &mut Vec::new())
            .is_err_and(|error| error.code() == ErrorCode::NotReady.code())
    });
    assert_eq!(
        code(
            on_b.get_attachment("logs", "kitchen", 6, &mut Vec::new())
                .unwrap_err()
        ),
        ErrorCode::NotReady.code()
    );
}

/// A server's `SyncState`, asked over `raw`.
fn sync_state(raw: &mut Raw) -> SyncState {
    raw.send(SyncStateRequest {});
    match raw.receive() {
        Some(Packet::SyncState(state)) => state,
        other => panic!("expected a SyncState, got {other:?}"),
    }
}

#[test]
fn replication_edges() {
    // The test plays the peer, over a raw connection.
    let running = Running::start_with(
        "replication-edges",
        "\n[replication]\naccept_from = [\"127.0.0.1\"]\n\n[retention]\nold = \"1h\"\n",
    );
    let peer = running.issue("server-x", &["peer"]);
    let mut raw = Raw::connect(&running, &peer);
    let state = sync_state(&mut raw);
    assert_eq!(
        (state.topics, state.nodes),
        (vec!["*".into()], vec!["*".into()])
    );
    assert!(state.heads.is_empty() && state.missing.is_empty());

    let file = bytes(2 * MIB + 1, 5);
    let message = |id, pushed_at, attachment| ReplicatedMessage {
        id,
        pushed_at,
        data: format!("m{id}"),
        attachment,
    };
    let now = 1_800_000_000_000;
    raw.send(ReplicateMessages {
        topic: "logs".into(),
        node: "far".into(),
        messages: vec![
            message(
                3,
                now,
                Some(Attachment {
                    size: file.len() as u64,
                    sha256: sha256(&file),
                }),
            ),
            message(7, now, None),
        ],
    });
    assert_eq!(raw.receive(), Some(MessagePushed { message_id: 7 }.into()));
    // Past its age here: not stored, but counted as received.
    raw.send(ReplicateMessages {
        topic: "old".into(),
        node: "far".into(),
        messages: vec![message(1, 1000, None)],
    });
    assert_eq!(raw.receive(), Some(MessagePushed { message_id: 1 }.into()));
    let mut analyst = running
        .connect(&running.issue("analyst", &["analyst"]))
        .unwrap();
    assert_eq!(
        analyst
            .query("SELECT group_concat(topic || '#' || message_id) AS n FROM messages")
            .unwrap(),
        r#"{"columns":["n"],"rows":[["logs#3,logs#7"]]}"#
    );
    let state = sync_state(&mut raw);
    let heads: Vec<_> = state
        .heads
        .iter()
        .map(|head| (head.topic.as_str(), head.last_id))
        .collect();
    assert_eq!(heads, [("logs", 7), ("old", 1)]);
    let missing: Vec<_> = state
        .missing
        .iter()
        .map(|missing| (missing.message_id, missing.next_part))
        .collect();
    assert_eq!(missing, [(3, 0)]);

    // From the part it needs only.
    let ask = |raw: &mut Raw, message_id, from_part| {
        raw.send(ReplicateAttachment {
            topic: "logs".into(),
            node: "far".into(),
            message_id,
            from_part,
        })
    };
    ask(&mut raw, 3, 1);
    raw.refused(ErrorCode::InvalidRequest);
    ask(&mut raw, 7, 0);
    raw.refused(ErrorCode::NotFound);

    // Cut after its first part: it goes on from the second.
    ask(&mut raw, 3, 0);
    assert!(matches!(raw.receive(), Some(Packet::Continue(_))));
    raw.send(AttachmentPart {
        data: file[..MIB].to_vec(),
    });
    drop(raw);
    let mut raw = Raw::connect(&running, &peer);
    wait_for("the first part kept", || {
        sync_state(&mut raw).missing[0].next_part == 1
    });
    ask(&mut raw, 3, 1);
    assert!(matches!(raw.receive(), Some(Packet::Continue(_))));
    for part in file[MIB..].chunks(MIB) {
        raw.send(AttachmentPart {
            data: part.to_vec(),
        });
    }
    assert_eq!(raw.receive(), Some(MessagePushed { message_id: 3 }.into()));
    let mut reader = running
        .connect(&running.issue("watcher", &["reader"]))
        .unwrap();
    let mut out = Vec::new();
    reader.get_attachment("logs", "far", 3, &mut out).unwrap();
    assert!(out == file);
    assert!(sync_state(&mut raw).missing.is_empty());

    // Not matching its SHA-256: refused, asked for again from the start.
    raw.send(ReplicateMessages {
        topic: "logs".into(),
        node: "far".into(),
        messages: vec![message(
            8,
            now,
            Some(Attachment {
                size: 10,
                sha256: [0; 32],
            }),
        )],
    });
    assert_eq!(raw.receive(), Some(MessagePushed { message_id: 8 }.into()));
    ask(&mut raw, 8, 0);
    assert!(matches!(raw.receive(), Some(Packet::Continue(_))));
    raw.send(AttachmentPart { data: vec![1; 10] });
    raw.refused(ErrorCode::DataMismatch);
    assert_eq!(sync_state(&mut raw).missing[0].next_part, 0);

    // A topic nobody pushed here: it's there from its first replicated
    // message, read and listed by the roles that name it.
    raw.send(ReplicateMessages {
        topic: "elsewhere".into(),
        node: "far".into(),
        messages: vec![message(1, now, None)],
    });
    assert_eq!(raw.receive(), Some(MessagePushed { message_id: 1 }.into()));
    let mut reader = running
        .connect(&running.issue("screen", &["reader"]))
        .unwrap();
    let got = reader
        .get_messages("elsewhere", "far", Some(0), 10)
        .unwrap();
    assert_eq!(got.messages[0].data, "m1");
    // (`old` had a message, past its age.)
    assert_eq!(
        reader.list_names(NameKind::Topic).unwrap().names,
        ["elsewhere", "logs", "old"]
    );
    let mut logs_only = running
        .connect(&running.issue("lounge", &["logs"]))
        .unwrap();
    assert_eq!(
        logs_only.list_names(NameKind::Topic).unwrap().names,
        ["logs"]
    );
    assert_eq!(
        code(
            logs_only
                .get_messages("elsewhere", "far", Some(0), 10)
                .unwrap_err()
        ),
        ErrorCode::NotAllowed.code()
    );

    // A certificate whose roles take nothing: refused.
    let mut other = Raw::connect(&running, &running.issue("nosy", &["reader"]));
    let state = sync_state(&mut other);
    assert!(state.topics.is_empty() && state.heads.is_empty());
    other.send(ReplicateMessages {
        topic: "logs".into(),
        node: "far".into(),
        messages: vec![message(9, now, None)],
    });
    other.refused(ErrorCode::NotAllowed);
}
