//! `bakashrot` end to end against a server on a free port: the old suites'
//! tool checks (GetMessages, Names, BigMessages).

use bakashrot_client::{Client, Settings};
use bakashrot_config::Config;
use bakashrot_pki::{Ca, Identity, Usage};
use bakashrot_server::Server;
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::time::{Duration, Instant};

const CONFIG: &str = r#"
[server]
listen = "127.0.0.1:0"
ca = "ca.crt"
certificate = "server.crt"
key = "server.key"
topics = ["logs", "secret"]
synchronous = "normal"

[roles.home]
push_topics = ["logs", "secret"]
read_topics = ["*"]
query = true

[roles.lounge]
read_topics = ["logs"]
"#;

/// A server in a folder of its own, with `kitchen` (home) and `lounge`
/// (lounge) issued: `<name>.crt`, `.key` and `.toml`.
struct Running {
    folder: PathBuf,
    port: u16,
    runtime: Option<tokio::runtime::Runtime>,
}

impl Running {
    fn start(name: &str) -> Running {
        let folder = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join(format!("tool-{name}"));
        let _ = fs::remove_dir_all(&folder);
        fs::create_dir_all(&folder).unwrap();
        let issued = Ca::create("Test CA", 10).unwrap();
        let ca = Ca::load(&issued.certificate, &issued.key).unwrap();
        let server = ca
            .issue(
                &Identity::new("server-1", &["peer"]).unwrap(),
                Usage::Server,
                10,
            )
            .unwrap();
        fs::write(folder.join("ca.crt"), &issued.certificate).unwrap();
        fs::write(folder.join("server.crt"), &server.certificate).unwrap();
        fs::write(folder.join("server.key"), &server.key).unwrap();
        fs::write(folder.join("server.toml"), CONFIG).unwrap();
        let server = Server::start(Config::load(&folder.join("server.toml")).unwrap()).unwrap();

        let runtime = tokio::runtime::Runtime::new().unwrap();
        let listener = runtime
            .block_on(tokio::net::TcpListener::bind("127.0.0.1:0"))
            .unwrap();
        let port = listener.local_addr().unwrap().port();
        runtime.spawn(async move { server.serve(listener).await });

        for (name, role) in [("kitchen", "home"), ("lounge", "lounge")] {
            let issued = ca
                .issue(&Identity::new(name, &[role]).unwrap(), Usage::Client, 10)
                .unwrap();
            fs::write(folder.join(format!("{name}.crt")), &issued.certificate).unwrap();
            fs::write(folder.join(format!("{name}.key")), &issued.key).unwrap();
            let toml = format!(
                "server = \"127.0.0.1:{port}\"\nca = \"ca.crt\"\ncertificate = \"{name}.crt\"\nkey = \"{name}.key\"\n"
            );
            fs::write(folder.join(format!("{name}.toml")), toml).unwrap();
        }
        Running {
            folder,
            port,
            runtime: Some(runtime),
        }
    }

    /// Runs the tool as `who` (`kitchen`, `lounge`).
    fn tool(&self, who: &str, args: &[&str]) -> Run {
        run(&self.folder, who, args, None)
    }

    /// A client of the library's, as kitchen: pushing many is quicker.
    fn client(&self) -> Client {
        let read = |name: &str| fs::read_to_string(self.folder.join(name)).unwrap();
        let (ca, certificate, key) = (read("ca.crt"), read("kitchen.crt"), read("kitchen.key"));
        let settings = Settings {
            ca: &ca,
            certificate: &certificate,
            key: &key,
            crl: None,
        };
        Client::connect(&format!("127.0.0.1:{}", self.port), &settings).unwrap()
    }

    /// Stops the server: its connections close.
    fn stop(&mut self) {
        if let Some(runtime) = self.runtime.take() {
            runtime.shutdown_background();
        }
    }
}

/// What a run printed, and its exit code.
#[derive(Debug)]
struct Run {
    code: i32,
    out: String,
    err: String,
}

impl Run {
    fn lines(&self) -> Vec<&str> {
        self.out.lines().collect()
    }

    /// The ids `messages` printed.
    fn ids(&self) -> Vec<u64> {
        self.lines()
            .iter()
            .filter_map(|line| line.split('\t').next()?.parse().ok())
            .collect()
    }

    #[track_caller]
    fn ok(&self) -> &Run {
        assert_eq!(self.code, 0, "{self:?}");
        self
    }

    #[track_caller]
    fn fails(&self, code: i32, text: &str) {
        assert_eq!(self.code, code, "{self:?}");
        assert!(self.err.contains(text), "expected '{text}': {self:?}");
    }
}

fn run(folder: &Path, who: &str, args: &[&str], stdin: Option<&str>) -> Run {
    let mut child = Command::new(env!("CARGO_BIN_EXE_bakashrot"))
        .args(["-c", &format!("{who}.toml")])
        .args(args)
        .current_dir(folder)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut input = child.stdin.take().unwrap();
    if let Some(text) = stdin {
        input.write_all(text.as_bytes()).unwrap();
    }
    drop(input);
    let output = child.wait_with_output().unwrap();
    Run {
        code: output.status.code().unwrap_or(-1),
        out: String::from_utf8(output.stdout).unwrap(),
        err: String::from_utf8(output.stderr).unwrap(),
    }
}

fn range(from: u64, to: u64) -> Vec<u64> {
    (from..=to).collect()
}

#[test]
fn pushes_and_latest() {
    let server = Running::start("push");
    let push = |args: &[&str]| server.tool("kitchen", &[&["push"], args].concat());

    assert_eq!(
        push(&["logs", r#"{"t":21,"room":"kitchen"}"#]).ok().out,
        "Pushed as message #1\n"
    );
    fs::write(server.folder.join("m.json"), "\u{feff}{\"from\":\"file\"}").unwrap();
    assert_eq!(
        push(&["logs", "@m.json"]).ok().out,
        "Pushed as message #2\n"
    );
    let piped = run(
        &server.folder,
        "kitchen",
        &["push", "logs", "-"],
        Some("piped\ntext"),
    );
    assert_eq!(piped.ok().out, "Pushed as message #3\n");
    assert_eq!(push(&["secret", "{}"]).ok().out, "Pushed as message #1\n");

    let latest = server.tool("kitchen", &["latest", "logs", "kitchen"]);
    let lines = latest.ok().lines();
    assert!(
        lines[0].starts_with("Message logs:kitchen#3, pushed 20"),
        "{lines:?}"
    );
    assert!(
        lines[0].ends_with('Z')
            && lines[0].len() == "Message logs:kitchen#3, pushed 2026-11-08T14:03:59.123Z".len()
    );
    assert_eq!(lines[1..], ["piped", "text"]);
    let messages = server.tool("kitchen", &["messages", "logs", "kitchen"]);
    assert_eq!(
        messages.ok().lines()[..2],
        [r#"1	{"t":21,"room":"kitchen"}"#, r#"2	{"from":"file"}"#]
    );

    // Refusals, the client's own failures.
    server
        .tool("lounge", &["push", "logs", "{}"])
        .fails(1, "Refused by the server (NotAllowed)");
    push(&["nope", "{}"]).fails(1, "Refused by the server (UnknownName): ");
    push(&["bad name!", "{}"]).fails(1, "Failed (InvalidArgument)");
    push(&["logs", "@missing.json"]).fails(1, "Can't read missing.json");
    let big = "x".repeat(bakashrot_proto::limits::MAX_MESSAGE_SIZE + 1);
    fs::write(server.folder.join("big.txt"), big).unwrap();
    push(&["logs", "@big.txt"]).fails(1, "Failed (");
    server
        .tool("lounge", &["latest", "logs", "lounge"])
        .fails(1, "No message yet in logs:lounge");
    server
        .tool("lounge", &["latest", "secret", "kitchen"])
        .fails(1, "(NotAllowed)");
    server
        .tool("kitchen", &["push", "logs"])
        .fails(2, "MESSAGE");
}

#[test]
fn messages() {
    let server = Running::start("messages");
    assert!(
        server
            .tool("kitchen", &["messages", "logs", "kitchen"])
            .ok()
            .out
            .is_empty()
    );
    assert!(
        server
            .tool(
                "kitchen",
                &["messages", "logs", "kitchen", "--after", "latest"]
            )
            .ok()
            .out
            .is_empty()
    );

    let mut client = server.client();
    for i in 1..=120 {
        client.push("logs", &format!(r#"{{"i":{i}}}"#)).unwrap();
    }
    let messages = |who: &str, args: &[&str]| server.tool(who, &[&["messages"], args].concat());

    let first = messages("kitchen", &["logs", "kitchen"]);
    assert_eq!(first.ok().ids(), range(1, 100), "the first 100 by default");
    assert_eq!(first.lines()[0], r#"1	{"i":1}"#);
    assert_eq!(first.lines()[99], r#"100	{"i":100}"#);
    assert_eq!(
        messages("kitchen", &["logs", "kitchen", "--limit", "0"])
            .ok()
            .ids(),
        range(1, 120)
    );
    assert_eq!(
        messages("kitchen", &["logs", "kitchen", "--after", "115"])
            .ok()
            .ids(),
        range(116, 120)
    );
    assert_eq!(
        messages(
            "kitchen",
            &["logs", "kitchen", "--after", "10", "--limit", "7"]
        )
        .ok()
        .ids(),
        range(11, 17)
    );
    assert!(
        messages("kitchen", &["logs", "kitchen", "--after", "120"])
            .ok()
            .out
            .is_empty()
    );
    assert!(
        messages("kitchen", &["logs", "kitchen", "--after", "LATEST"])
            .ok()
            .out
            .is_empty()
    );
    assert_eq!(
        messages("kitchen", &["LOGS", "Kitchen", "--after", "118"])
            .ok()
            .ids(),
        range(119, 120)
    );
    assert_eq!(
        messages("lounge", &["logs", "kitchen", "--after", "100"])
            .ok()
            .ids(),
        range(101, 120)
    );
    let timed = messages("kitchen", &["logs", "kitchen", "--after", "119", "--time"]);
    let fields: Vec<&str> = timed.ok().out.trim_end().split('\t').collect();
    assert_eq!(
        (fields[0], fields[2], fields[1].len()),
        ("120", r#"{"i":120}"#, 24),
        "{fields:?}"
    );

    client.push("secret", "{}").unwrap();
    assert_eq!(messages("kitchen", &["secret", "kitchen"]).ok().ids(), [1]);
    messages("lounge", &["secret", "kitchen"]).fails(1, "(NotAllowed)");
    messages("kitchen", &["logs", "nobody"]).fails(1, "(UnknownName)");
    messages("kitchen", &["nothing", "kitchen"]).fails(1, "(UnknownName)");
    assert!(
        messages("lounge", &["logs", "lounge"]).ok().out.is_empty(),
        "its own node, none yet"
    );
    messages("kitchen", &["logs", "kitchen", "--after", "soon"])
        .fails(2, "a message id or \"latest\"");
    messages("kitchen", &["logs", "kitchen", "--nope"]).fails(2, "--nope");
    messages("kitchen", &["logs", "kitchen", "--interval", "5"]).fails(2, "--interval");

    // As stored: not JSON, a line break spanning lines; big ones over
    // several answers.
    client.push("logs", "plain\ntext").unwrap();
    let big: Vec<String> = (0..5)
        .map(|i| format!("{i}{}", "y".repeat(600_000)))
        .collect();
    for data in &big {
        client.push("logs", data).unwrap();
    }
    let read = messages("kitchen", &["logs", "kitchen", "--after", "120"]);
    let lines = read.ok().lines();
    assert_eq!(lines[..2], ["121\tplain", "text"]);
    for (i, data) in big.iter().enumerate() {
        assert_eq!(lines[2 + i], format!("{}\t{data}", 122 + i));
    }
    assert_eq!(
        messages(
            "kitchen",
            &["logs", "kitchen", "--after", "121", "--limit", "2"]
        )
        .ok()
        .ids(),
        [122, 123]
    );
}

#[test]
fn follows() {
    let mut server = Running::start("follow");
    let mut client = server.client();
    client.push("logs", "old").unwrap();

    let mut follower = Command::new(env!("CARGO_BIN_EXE_bakashrot"))
        .args([
            "-c",
            "lounge.toml",
            "messages",
            "logs",
            "kitchen",
            "-f",
            "--after",
            "latest",
            "--interval",
            "20",
        ])
        .current_dir(&server.folder)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let (lines, read) = mpsc::channel();
    let stdout = follower.stdout.take().unwrap();
    std::thread::spawn(move || {
        for line in BufReader::new(stdout).lines() {
            let _ = lines.send(line.unwrap());
        }
    });

    std::thread::sleep(Duration::from_millis(300));
    assert!(
        follower.try_wait().unwrap().is_none(),
        "keeps running once caught up"
    );
    for i in 1..=3 {
        client.push("logs", &format!("new {i}")).unwrap();
    }
    let got: Vec<String> = (0..3)
        .map(|_| read.recv_timeout(Duration::from_secs(10)).unwrap())
        .collect();
    assert_eq!(
        got,
        ["2\tnew 1", "3\tnew 2", "4\tnew 3"],
        "only the new ones"
    );

    drop(client);
    server.stop();
    let started = Instant::now();
    let status = loop {
        if let Some(status) = follower.try_wait().unwrap() {
            break status;
        }
        assert!(
            started.elapsed() < Duration::from_secs(20),
            "still following"
        );
        std::thread::sleep(Duration::from_millis(50));
    };
    assert_eq!(status.code(), Some(1), "fails once the server is gone");
}

#[test]
fn queries_and_lists() {
    let server = Running::start("query");
    server.client().push("logs", r#"{"t":1}"#).unwrap();

    let query = server.tool("kitchen", &["query", "SELECT 1 AS one"]);
    assert_eq!(
        query.ok().out,
        "{\"columns\":[\"one\"],\"rows\":[[\"1\"]]}\n"
    );
    fs::write(server.folder.join("q.sql"), r#"SELECT "two" AS "a b""#).unwrap();
    assert!(
        server
            .tool("kitchen", &["query", "@q.sql"])
            .ok()
            .out
            .contains(r#""a b""#)
    );
    let piped = run(&server.folder, "kitchen", &["query", "-"], Some("SELECT 3"));
    assert!(piped.ok().out.contains(r#"[["3"]]"#), "{piped:?}");
    server
        .tool("lounge", &["query", "SELECT 1"])
        .fails(1, "(NotAllowed)");
    server
        .tool("kitchen", &["query", "DELETE FROM messages"])
        .fails(1, "(QueryFailed)");

    let all = server.tool("kitchen", &["list"]);
    assert_eq!(
        all.ok().out,
        "Topics (2):\n  logs\n  secret\nNodes (1):\n  kitchen\n"
    );
    assert_eq!(
        server.tool("lounge", &["list", "topics"]).ok().out,
        "Topics (1):\n  logs\n"
    );
    let json = server.tool("kitchen", &["list", "nodes", "--json"]);
    assert_eq!(
        json.ok().out,
        "{\"kind\":\"node\",\"names\":[\"kitchen\"],\"truncated\":false}\n"
    );
    server
        .tool("kitchen", &["list", "everything"])
        .fails(2, "everything");
}

#[test]
fn attachments() {
    let server = Running::start("attachments");
    let photo: Vec<u8> = (0..2_500_000u32).map(|i| (i % 253) as u8).collect();
    fs::write(server.folder.join("photo.jpg"), &photo).unwrap();

    let pushed = server.tool(
        "kitchen",
        &["push", "logs", r#"{"photo":1}"#, "-a", "photo.jpg"],
    );
    assert_eq!(
        pushed.ok().out,
        "Pushed as message #1, with an attachment of 2500000 bytes\n"
    );
    server.tool("kitchen", &["push", "logs", "{}"]).ok();
    server
        .tool(
            "kitchen",
            &["push", "logs", "{}", "--attachment", "missing.jpg"],
        )
        .fails(1, "Can't read missing.jpg");

    let saved = server.tool(
        "lounge",
        &["attachment", "logs", "kitchen", "1", "copy.jpg"],
    );
    assert_eq!(saved.ok().out, "Saved 2500000 bytes as copy.jpg\n");
    assert_eq!(fs::read(server.folder.join("copy.jpg")).unwrap(), photo);
    server
        .tool(
            "lounge",
            &["attachment", "logs", "kitchen", "2", "none.jpg"],
        )
        .fails(
            1,
            "Refused by the server (NotFound): no attachment for logs:kitchen#2",
        );
    assert!(
        !server.folder.join("none.jpg").exists(),
        "a refused one leaves no file"
    );

    let mut client = server.client();
    client.push("logs", "{}").unwrap();
    let mut tiny = std::io::Cursor::new(b"tiny".to_vec());
    client
        .push_with_attachment("logs", "last", &mut tiny)
        .unwrap();
    let latest = server.tool("kitchen", &["latest", "logs", "kitchen"]);
    let lines = latest.ok().lines();
    assert!(lines[0].starts_with("Message logs:kitchen#4,"), "{lines:?}");
    assert_eq!(lines[1..], ["Attachment: 4 bytes", "last"]);
}

#[test]
fn settings() {
    let server = Running::start("settings");
    let folder = &server.folder;
    run(folder, "nobody", &["list"], None).fails(1, "Can't read nobody.toml");

    // Paths are relative to the file's folder, wherever it runs from.
    fs::create_dir_all(folder.join("elsewhere")).unwrap();
    let up = run(
        &folder.join("elsewhere"),
        "../kitchen",
        &["list", "topics"],
        None,
    );
    assert_eq!(up.ok().out, "Topics (2):\n  logs\n  secret\n");

    let kitchen = fs::read_to_string(folder.join("kitchen.toml")).unwrap();
    fs::write(
        folder.join("typo.toml"),
        kitchen.replace("certificate =", "certficate ="),
    )
    .unwrap();
    run(folder, "typo", &["list"], None).fails(1, "certficate");
    fs::write(
        folder.join("crl.toml"),
        format!("{kitchen}crl = \"none.crl\"\n"),
    )
    .unwrap();
    run(folder, "crl", &["list"], None).fails(1, "Can't read the CRL");
    let closed = kitchen.replace(&server.port.to_string(), "1");
    fs::write(folder.join("closed.toml"), closed).unwrap();
    run(folder, "closed", &["list"], None)
        .fails(1, "Failed to connect to 127.0.0.1:1 (ConnectFailed)");
}
