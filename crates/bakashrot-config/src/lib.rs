//! The server's config: a TOML file, read and checked in one go.
//!
//! - [`Server`]: where it listens, its files, its database.
//! - [`Retention`]: how long each topic's messages are kept.
//! - [`Replication`]: the servers it sends to and takes from, how often.
//! - [`Role`]: what certificates with a role may do; [`Permissions`]: what
//!   a certificate's roles allow together.
//!
//! Who connects is the certificate's (`bakashrot-pki`): its name is its
//! node, its roles are looked up here. Peers too: what's replicated with a
//! peer is its roles'. Topics aren't listed anywhere else: one exists
//! once a role let a message in. The file, every key and its default:
//! `docs/config.md`.
//!
//! Every value is checked as serde reads it, so a wrong one is refused with
//! its line.

mod roles;
mod values;

pub use roles::{NameList, Permissions, Role};

use bakashrot_proto::names::{is_valid_name, is_valid_pattern, names_equal, pattern_matches};
use indexmap::IndexMap;
use serde::{Deserialize, Deserializer, de::Error as _};
use std::fmt;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::time::Duration;
use values::{DURATION_HELP, NAME_HELP, parse_age};

/// What's wrong with a config, in words: where (the file, the line) and why.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Error(String);

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for Error {}

/// A result of this crate.
pub type Result<T> = std::result::Result<T, Error>;

/// A server's config.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Config {
    /// `[server]`.
    pub server: Server,
    /// `[retention]`.
    #[serde(default)]
    pub retention: Retention,
    /// `[replication]`.
    #[serde(default)]
    pub replication: Replication,
    /// `[roles.<name>]`, in the file's order.
    #[serde(default, deserialize_with = "roles")]
    pub roles: Vec<Role>,
}

/// `[server]`.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Server {
    /// The address and port it listens on.
    #[serde(deserialize_with = "values::listen")]
    pub listen: SocketAddr,
    /// The CA's certificate.
    pub ca: PathBuf,
    /// The server's certificate.
    pub certificate: PathBuf,
    /// The server's key.
    pub key: PathBuf,
    /// The CA's CRL, watched; none: nothing revoked.
    #[serde(default)]
    pub crl: Option<PathBuf>,
    /// The SQLite database; `bakashrot.sqlite` by default.
    #[serde(default = "defaults::database")]
    pub database: PathBuf,
    /// How hard a push is made sure to be on disk.
    #[serde(default)]
    pub synchronous: Synchronous,
    /// The biggest attachment taken, in bytes; 0: none. 1G by default.
    #[serde(
        default = "defaults::max_attachment_size",
        deserialize_with = "values::size"
    )]
    pub max_attachment_size: u64,
    /// How often messages past their age are deleted; 1m by default.
    #[serde(
        default = "defaults::retention_interval",
        deserialize_with = "values::duration"
    )]
    pub retention_interval: Duration,
}

/// How hard the database makes sure a push is on disk before answering it
/// (SQLite's `synchronous`).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Deserialize)]
#[serde(try_from = "String")]
pub enum Synchronous {
    /// Every commit flushed: an answered push survives a power loss. The
    /// default.
    #[default]
    Full,
    /// Flushed about once a second: faster, a power loss loses the last
    /// second or so of answered pushes.
    Normal,
}

impl TryFrom<String> for Synchronous {
    type Error = String;

    fn try_from(text: String) -> std::result::Result<Self, String> {
        match text.trim().to_ascii_lowercase().as_str() {
            "full" => Ok(Synchronous::Full),
            "normal" => Ok(Synchronous::Normal),
            "off" => Err(
                "\"off\" isn't allowed: a power loss could corrupt the database. \
                          \"full\", or \"normal\" to only risk the last second of messages"
                    .into(),
            ),
            "extra" => Err("\"extra\" does nothing more than \"full\" here: write \"full\"".into()),
            _ => Err(format!("'{text}' isn't \"full\" or \"normal\"")),
        }
    }
}

/// `[retention]`: how long each topic's messages are kept, from when they
/// were first pushed.
#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
#[serde(try_from = "IndexMap<String, toml::Value>")]
pub struct Retention {
    /// Names and patterns with their age (none: forever), in the file's
    /// order.
    lines: Vec<(String, Option<Duration>)>,
}

impl TryFrom<IndexMap<String, toml::Value>> for Retention {
    type Error = String;

    fn try_from(table: IndexMap<String, toml::Value>) -> std::result::Result<Self, String> {
        let mut lines: Vec<(String, Option<Duration>)> = Vec::with_capacity(table.len());
        for (key, value) in table {
            if !is_valid_pattern(&key) && !is_valid_name(&key) {
                return Err(format!(
                    "'{key}' isn't a topic name or a pattern ({NAME_HELP})"
                ));
            }
            if lines.iter().any(|(before, _)| names_equal(before, &key)) {
                return Err(format!("'{key}' is given twice"));
            }
            let age = match &value {
                toml::Value::String(text) => parse_age(text),
                toml::Value::Table(_) => {
                    return Err(format!(
                        "'{key}' is a table: quote names with dots, \"{key}.x\" = \"30d\""
                    ));
                }
                _ => None,
            };
            let age = age.ok_or_else(|| {
                format!("{key} = {value} isn't an age: {DURATION_HELP}, or \"forever\"")
            })?;
            lines.push((key, age));
        }
        Ok(Retention { lines })
    }
}

impl Retention {
    /// How long `topic`'s messages are kept, `None` for forever: its name's
    /// line, else the first pattern matching it, else `*`'s, else forever.
    pub fn age(&self, topic: &str) -> Option<Duration> {
        let line = |found: fn(&str, &str) -> bool| {
            self.lines
                .iter()
                .find(|(key, _)| key != "*" && found(key, topic))
        };
        line(names_equal)
            .or_else(|| line(|key, topic| is_valid_pattern(key) && pattern_matches(key, topic)))
            .or_else(|| self.lines.iter().find(|(key, _)| key == "*"))
            .and_then(|(_, age)| *age)
    }
}

/// `[replication]`.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Replication {
    /// The servers it dials and sends to (`host:port`). What's sent to
    /// each is its roles' `send_*`.
    #[serde(deserialize_with = "values::peers")]
    pub push_to: Vec<String>,
    /// The servers it takes replicated messages from: IP addresses or
    /// hostnames, `*` for all; none by default. What's taken is their
    /// roles' `accept_*`.
    #[serde(deserialize_with = "values::hosts")]
    pub accept_from: Vec<String>,
    /// How long to wait before dialing a peer again; 10s by default.
    #[serde(deserialize_with = "values::duration")]
    pub retry_delay: Duration,
    /// How long a link waits, once nothing was left to send, before it
    /// looks again; 5s by default.
    #[serde(deserialize_with = "values::duration")]
    pub sync_interval: Duration,
    /// The most messages sent to a peer per packet; 1000 by default.
    #[serde(deserialize_with = "values::batch_size")]
    pub batch_size: u32,
}

impl Default for Replication {
    fn default() -> Self {
        Replication {
            push_to: Vec::new(),
            accept_from: Vec::new(),
            retry_delay: Duration::from_secs(10),
            sync_interval: Duration::from_secs(5),
            batch_size: 1000,
        }
    }
}

/// `[server]`'s defaults.
mod defaults {
    use std::path::PathBuf;
    use std::time::Duration;

    pub(crate) fn database() -> PathBuf {
        "bakashrot.sqlite".into()
    }
    pub(crate) fn max_attachment_size() -> u64 {
        1 << 30
    }
    pub(crate) fn retention_interval() -> Duration {
        Duration::from_secs(60)
    }
}

/// `[roles.*]`: each section's name is its role's, none twice.
fn roles<'de, D: Deserializer<'de>>(reader: D) -> std::result::Result<Vec<Role>, D::Error> {
    let table = IndexMap::<String, Role>::deserialize(reader)?;
    let mut roles: Vec<Role> = Vec::with_capacity(table.len());
    for (name, mut role) in table {
        if !is_valid_name(&name) {
            return Err(D::Error::custom(format!(
                "'{name}' isn't a role name ({NAME_HELP})"
            )));
        }
        if let Some(before) = roles.iter().find(|role| names_equal(&role.name, &name)) {
            return Err(D::Error::custom(format!(
                "'{}' and '{name}' are the same role (case doesn't matter)",
                before.name
            )));
        }
        role.name = name;
        roles.push(role);
    }
    Ok(roles)
}

impl Config {
    /// Reads the config file at `path`. Relative paths in it are from its
    /// folder.
    pub fn load(path: &Path) -> Result<Config> {
        let in_file = |error: &dyn fmt::Display| Error(format!("{}: {error}", path.display()));
        let text = std::fs::read_to_string(path).map_err(|error| in_file(&error))?;
        let mut config = Config::parse(&text).map_err(|error| in_file(&error))?;
        let folder = path.parent().unwrap_or(Path::new(""));
        let server = &mut config.server;
        for file in [
            &mut server.ca,
            &mut server.certificate,
            &mut server.key,
            &mut server.database,
        ]
        .into_iter()
        .chain(server.crl.as_mut())
        {
            *file = folder.join(&*file);
        }
        Ok(config)
    }

    /// Reads a config, paths as they're written.
    pub fn parse(text: &str) -> Result<Config> {
        toml::from_str(text).map_err(|error| Error(error.to_string().trim_end().to_owned()))
    }

    /// What a certificate with these roles may do: everything its roles
    /// with a section allow. `None` if none has one: it's refused.
    pub fn permissions<S: AsRef<str>>(&self, roles: &[S]) -> Option<Permissions> {
        let roles: Vec<Role> = self
            .roles
            .iter()
            .filter(|role| {
                roles
                    .iter()
                    .any(|own| names_equal(own.as_ref(), &role.name))
            })
            .cloned()
            .collect();
        (!roles.is_empty()).then_some(Permissions { roles })
    }
}
