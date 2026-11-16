//! `bakashrot`: pushes messages, reads them and their attachments, runs
//! queries and lists names from the command line, connecting with a
//! `client.toml`. The old `BakaShrot*` tools in one program; see
//! `docs/client.md`, "The tools".

use bakashrot_client::{Client, Error, Settings};
use bakashrot_proto::error::{code_name, is_refusal_code};
use bakashrot_proto::limits::MAX_MESSAGES_PER_PACKET;
use bakashrot_proto::packets::{MessageEntry, NameKind};
use clap::{Parser, Subcommand, ValueEnum};
use serde::Deserialize;
use std::fs;
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::Duration;

#[derive(Parser)]
#[command(
    name = "bakashrot",
    version,
    about = "Pushes and reads BakaShrot's messages",
    after_help = "Exits with 0 on success, 1 on a failure, 2 on bad arguments."
)]
struct Cli {
    /// The client's settings: the server, the CA's certificate, this
    /// client's certificate and key, the CRL.
    #[arg(short, long, global = true, default_value = "client.toml")]
    config: PathBuf,
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Pushes a message as this client's node, prints its id.
    Push {
        /// The topic to push to.
        topic: String,
        /// The message (JSON or any text), @FILE for a file's, - for the
        /// standard input's (PowerShell before 7.3 drops the double quotes
        /// inside arguments: use @FILE or - there).
        message: String,
        /// A file to attach (1 byte and up, as much as the server takes):
        /// the message is stored once all of it came.
        #[arg(short, long)]
        attachment: Option<PathBuf>,
    },
    /// Prints a topic and node's latest message: its id, when it was pushed
    /// (UTC), its attachment if it has one, then its data.
    Latest {
        /// The topic.
        topic: String,
        /// The node that pushed it.
        node: String,
    },
    /// Saves a message's attachment as FILE (replaced), checked with its
    /// SHA-256, and prints its size. A failed one leaves no file.
    Attachment {
        /// The topic.
        topic: String,
        /// The node that pushed it.
        node: String,
        /// The message's id.
        id: u64,
        /// Where to save it.
        file: PathBuf,
    },
    /// Prints a topic and node's messages in order, a line each: its id, a
    /// tab, its data as stored (a line break in it spans lines).
    Messages {
        /// The topic.
        topic: String,
        /// The node that pushed them.
        node: String,
        /// Starts after this message id: 0 from the first one, "latest"
        /// after the latest one (only new ones, with --follow).
        #[arg(long, default_value = "0", value_parser = after)]
        after: After,
        /// Stops after this many, 0 for no limit [default: 100, none with
        /// --follow].
        #[arg(long)]
        limit: Option<u64>,
        /// Keeps going once caught up, checking every --interval, until
        /// stopped (Ctrl+C) or the connection fails.
        #[arg(short, long)]
        follow: bool,
        /// How often --follow checks, in milliseconds.
        #[arg(long, default_value_t = 500, value_parser = clap::value_parser!(u64).range(10..=3_600_000))]
        interval: u64,
        /// Also prints when each was pushed (UTC), between its id and its
        /// data.
        #[arg(short, long)]
        time: bool,
    },
    /// Runs read-only SQL on the server, prints its result as JSON:
    /// {"columns":[...],"rows":[[...],...]}. The client's roles must allow
    /// queries.
    Query {
        /// One SELECT (or WITH ... SELECT), @FILE for a file's, - for the
        /// standard input's.
        sql: String,
    },
    /// Lists the topics this client may use and the nodes of those it may
    /// read; every one if its roles have list_topics / list_nodes, or query.
    List {
        /// What to list.
        #[arg(value_enum, default_value_t = What::All)]
        what: What,
        /// Prints JSON, a line per list: {"kind":...,"names":[...],"truncated":...}.
        #[arg(long)]
        json: bool,
    },
}

/// Where `messages` starts.
#[derive(Clone, Copy)]
enum After {
    Id(u64),
    Latest,
}

fn after(text: &str) -> Result<After, String> {
    if text.eq_ignore_ascii_case("latest") {
        return Ok(After::Latest);
    }
    text.parse()
        .map(After::Id)
        .map_err(|_| "a message id or \"latest\"".to_owned())
}

#[derive(Clone, Copy, ValueEnum)]
enum What {
    Topics,
    Nodes,
    All,
}

/// `client.toml`: paths are relative to its folder.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ClientToml {
    server: String,
    ca: PathBuf,
    certificate: PathBuf,
    key: PathBuf,
    crl: Option<PathBuf>,
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    match run(&cli.config, cli.command) {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("{message}");
            ExitCode::FAILURE
        }
    }
}

fn run(config: &Path, command: Command) -> Result<(), String> {
    match command {
        Command::Push {
            topic,
            message,
            attachment,
        } => {
            let message = input(&message)?;
            let Some(path) = attachment else {
                let id = connect(config)?.push(&topic, &message).map_err(failed)?;
                println!("Pushed as message #{id}");
                return Ok(());
            };
            let mut file = fs::File::open(&path)
                .map_err(|error| format!("Can't read {}: {error}", path.display()))?;
            let id = connect(config)?
                .push_with_attachment(&topic, &message, &mut file)
                .map_err(failed)?;
            let size = file.metadata().map_or(0, |metadata| metadata.len());
            println!("Pushed as message #{id}, with an attachment of {size} bytes");
        }
        Command::Attachment {
            topic,
            node,
            id,
            file,
        } => {
            let size = connect(config)?
                .save_attachment(&topic, &node, id, &file)
                .map_err(failed)?;
            println!("Saved {size} bytes as {}", file.display());
        }
        Command::Latest { topic, node } => {
            let message = latest(&mut connect(config)?, &topic, &node)?
                .ok_or_else(|| format!("No message yet in {topic}:{node}"))?;
            println!(
                "Message {topic}:{node}#{}, pushed {}",
                message.id,
                utc(message.pushed_at)
            );
            if let Some(attachment) = &message.attachment {
                let here = if attachment.ready {
                    ""
                } else {
                    ", not on this server yet"
                };
                println!("Attachment: {} bytes{here}", attachment.size);
            }
            println!("{}", message.data);
        }
        Command::Messages {
            topic,
            node,
            after,
            limit,
            follow,
            interval,
            time,
        } => {
            let mut client = connect(config)?;
            let mut after = match after {
                After::Id(id) => id,
                After::Latest => latest(&mut client, &topic, &node)?.map_or(0, |m| m.id),
            };
            let limit = limit.unwrap_or(if follow { 0 } else { 100 });
            let mut printed = 0;
            let mut out = io::BufWriter::new(io::stdout().lock());
            loop {
                let left = if limit > 0 { limit - printed } else { u64::MAX };
                let asked = left.min(u64::from(MAX_MESSAGES_PER_PACKET)) as u32;
                let batch = client
                    .get_messages(&topic, &node, Some(after), asked)
                    .map_err(failed)?;
                for message in &batch.messages {
                    after = message.id;
                    let written = if time {
                        let at = utc(message.pushed_at);
                        writeln!(out, "{after}\t{at}\t{}", message.data)
                    } else {
                        writeln!(out, "{after}\t{}", message.data)
                    };
                    written.map_err(cant_write)?;
                }
                out.flush().map_err(cant_write)?;
                printed += batch.messages.len() as u64;
                if (limit > 0 && printed >= limit) || (!batch.more && !follow) {
                    break;
                }
                if !batch.more {
                    std::thread::sleep(Duration::from_millis(interval));
                }
            }
        }
        Command::Query { sql } => {
            let sql = input(&sql)?;
            println!("{}", connect(config)?.query(&sql).map_err(failed)?);
        }
        Command::List { what, json } => {
            let mut client = connect(config)?;
            let kinds = [
                (NameKind::Topic, "topic", "Topics"),
                (NameKind::Node, "node", "Nodes"),
            ];
            for (kind, name, label) in kinds {
                if matches!(
                    (what, kind),
                    (What::Topics, NameKind::Node) | (What::Nodes, NameKind::Topic)
                ) {
                    continue;
                }
                let list = client.list_names(kind).map_err(failed)?;
                if json {
                    let json = serde_json::json!({
                        "kind": name,
                        "names": list.names,
                        "truncated": list.truncated,
                    });
                    println!("{json}");
                    continue;
                }
                println!("{label} ({}):", list.names.len());
                for name in &list.names {
                    println!("  {name}");
                }
                if list.truncated {
                    println!("  ... more than fit in one answer");
                }
            }
        }
    }
    Ok(())
}

/// A topic and node's latest message, if any.
fn latest(client: &mut Client, topic: &str, node: &str) -> Result<Option<MessageEntry>, String> {
    let latest = client.get_messages(topic, node, None, 1).map_err(failed)?;
    Ok(latest.messages.into_iter().next_back())
}

/// Connects with the settings in `config`.
fn connect(config: &Path) -> Result<Client, String> {
    let text = fs::read_to_string(config).map_err(|error| {
        format!(
            "Can't read {}: {error} (the client's settings, see --help)",
            config.display()
        )
    })?;
    let settings: ClientToml =
        toml::from_str(&text).map_err(|error| format!("{}: {error}", config.display()))?;
    let folder = config.parent().unwrap_or(Path::new(""));
    let pem = |what: &str, path: &Path| {
        let path = folder.join(path);
        fs::read_to_string(&path)
            .map_err(|error| format!("Can't read the {what} {}: {error}", path.display()))
    };
    let ca = pem("CA's certificate", &settings.ca)?;
    let certificate = pem("certificate", &settings.certificate)?;
    let key = pem("key", &settings.key)?;
    let crl = settings
        .crl
        .as_deref()
        .map(|path| pem("CRL", path))
        .transpose()?;
    let pems = Settings {
        ca: &ca,
        certificate: &certificate,
        key: &key,
        crl: crl.as_deref(),
    };
    Client::connect(&settings.server, &pems).map_err(|error| {
        format!(
            "Failed to connect to {} ({}): {}",
            settings.server,
            code_name(error.code()),
            error.message()
        )
    })
}

/// A message or SQL from the command line: as is, `@FILE` for a file's,
/// `-` for the standard input's (a UTF-8 BOM dropped).
fn input(text: &str) -> Result<String, String> {
    let read = if text == "-" {
        let mut read = String::new();
        io::stdin()
            .read_to_string(&mut read)
            .map_err(|error| format!("Can't read the standard input: {error}"))?;
        read
    } else if let Some(path) = text.strip_prefix('@') {
        fs::read_to_string(path).map_err(|error| format!("Can't read {path}: {error}"))?
    } else {
        return Ok(text.to_owned());
    };
    Ok(match read.strip_prefix('\u{feff}') {
        Some(rest) => rest.to_owned(),
        None => read,
    })
}

fn failed(error: Error) -> String {
    let what = if is_refusal_code(error.code()) {
        "Refused by the server"
    } else {
        "Failed"
    };
    format!("{what} ({}): {}", code_name(error.code()), error.message())
}

fn cant_write(error: io::Error) -> String {
    format!("Can't write the output: {error}")
}

/// Milliseconds since 1970 as "2026-11-08T14:03:59.123Z".
fn utc(ms: u64) -> String {
    match time::OffsetDateTime::from_unix_timestamp_nanos(i128::from(ms) * 1_000_000) {
        Ok(t) => format!(
            "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}.{:03}Z",
            t.year(),
            u8::from(t.month()),
            t.day(),
            t.hour(),
            t.minute(),
            t.second(),
            t.millisecond()
        ),
        Err(_) => format!("{ms} ms"),
    }
}
