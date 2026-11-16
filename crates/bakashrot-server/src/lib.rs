//! BakaShrot's server: takes TLS connections from the CA's clients and
//! peers, knows each by its certificate (its node, its roles), and answers
//! their requests from the database.
//!
//! - [`Server::start`]: reads the certificates, opens the database, starts
//!   the writer's thread.
//! - [`Server::serve`]: takes connections, a task each
//!   (`connection.rs`); pushes go to the writer's thread (`writer.rs`),
//!   reads and queries to pools of connections.
//! - [`Server::watch_revocations`]: reloads the CRL file when it changes;
//!   a revoked certificate's connection is dropped at its next request.
//! - [`Server::apply_retention`]: deletes messages past their topic's age
//!   (`retention.rs`).
//! - [`Server::replicate`]: sends what the servers of `push_to` lack
//!   (`push_to.rs`); those dialing in, if in `accept_from`, are answered
//!   by `accept_from.rs`.
//! - [`Server::stop`]: commits what was queued for the writer, refuses
//!   the rest.

mod accept_from;
mod connection;
mod push_to;
mod retention;
mod writer;

use bakashrot_config::Config;
use bakashrot_pki::{Revocations, SharedRevocations, summarize, tls};
use bakashrot_proto::ErrorCode;
use bakashrot_proto::packets::RequestRefused;
use bakashrot_storage::{Database, QueryRunner, Reader};
use std::net::SocketAddr;
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::net::TcpListener;
use tokio_rustls::{TlsAcceptor, TlsConnector};
use tracing::{info, warn};
use writer::Pushes;

/// How often the CRL file is looked at.
const CRL_POLL: Duration = Duration::from_secs(5);

/// How often the WAL is checkpointed.
const CHECKPOINT_INTERVAL: Duration = Duration::from_secs(1);

/// A server, ready to take connections.
#[derive(Clone)]
pub struct Server {
    shared: Arc<Shared>,
}

/// What every connection uses.
struct Shared {
    config: Config,
    /// The server's own name: its certificate's.
    name: String,
    acceptor: TlsAcceptor,
    /// To dial the servers of `push_to`.
    connector: TlsConnector,
    revocations: SharedRevocations,
    /// The CA's certificate, to check CRLs with.
    ca: String,
    database: Database,
    pushes: Pushes,
    /// Read connections not in use.
    readers: Mutex<Vec<Reader>>,
    /// Query connections not in use.
    queries: Mutex<Vec<QueryRunner>>,
}

impl Server {
    /// Reads the server's certificates and CRL, opens its database, starts
    /// its writer. Errors say which file and why.
    pub fn start(config: Config) -> Result<Server, String> {
        check_clock(SystemTime::now())?;
        let server = &config.server;
        let ca = read(&server.ca)?;
        let certificate = read(&server.certificate)?;
        let key = read(&server.key)?;
        let name = summarize(&certificate)
            .ok()
            .and_then(|summary| summary.identity)
            .map(|identity| identity.name)
            .ok_or_else(|| {
                format!(
                    "{}: not a BakaShrot certificate",
                    server.certificate.display()
                )
            })?;
        let revocations = load_revocations(server.crl.as_deref(), &ca)?.shared();
        let tls = tls::server_config(&ca, &certificate, &key, revocations.clone())
            .map_err(|error| format!("the server's TLS: {error}"))?;
        let dialing = tls::client_config(&ca, &certificate, &key, revocations.clone())
            .map_err(|error| format!("the TLS to peers: {error}"))?;
        let database = Database::open(&server.database, server.synchronous)
            .map_err(|error| error.to_string())?;
        let pushes = Pushes::start(database.writer().map_err(|error| error.to_string())?)
            .map_err(|error| format!("the writer's thread: {error}"))?;
        start_checkpoints(&database)?;
        Ok(Server {
            shared: Arc::new(Shared {
                name,
                acceptor: TlsAcceptor::from(tls),
                connector: TlsConnector::from(dialing),
                revocations,
                ca,
                database,
                pushes,
                readers: Mutex::new(Vec::new()),
                queries: Mutex::new(Vec::new()),
                config,
            }),
        })
    }

    /// The server's name: its certificate's.
    pub fn name(&self) -> &str {
        &self.shared.name
    }

    /// Where the config says to listen.
    pub fn listen(&self) -> SocketAddr {
        self.shared.config.server.listen
    }

    /// Takes connections on `listener`, each in a task of its own, until
    /// the listener fails.
    pub async fn serve(&self, listener: TcpListener) -> std::io::Result<()> {
        loop {
            let (tcp, peer) = listener.accept().await?;
            tokio::spawn(connection::handle(self.shared.clone(), tcp, peer));
        }
    }

    /// Reloads the CRL file whenever it changes (its time or size, looked
    /// at every few seconds). A CRL that can't be read or isn't the CA's is
    /// refused: the previous one stays. Never returns.
    pub async fn watch_revocations(&self) {
        let Some(path) = self.shared.config.server.crl.clone() else {
            return std::future::pending().await;
        };
        let mut seen = stamp(&path);
        loop {
            tokio::time::sleep(CRL_POLL).await;
            let now = stamp(&path);
            if now != seen {
                seen = now;
                match self.reload_revocations() {
                    Ok(count) => info!("{}: reloaded, {count} revoked", path.display()),
                    Err(error) => warn!("{error}: the previous CRL stays"),
                }
            }
        }
    }

    /// Deletes each topic's messages past its age (`[retention]`), then
    /// their attachments: right away, then every `retention_interval`.
    /// Never returns.
    pub async fn apply_retention(&self) {
        retention::run(&self.shared).await
    }

    /// Keeps a link to each server of `[replication] push_to`, sending
    /// each what it lacks (again at once after sending, after `sync_interval`
    /// when there was nothing). Never returns.
    pub async fn replicate(&self) {
        push_to::run(self.shared.clone()).await
    }

    /// Stops writing: every write queued before is committed (and so
    /// answered), the ones after are refused (`ServerError`, the server
    /// stopping). Then the server can be dropped, its runtime stopped.
    pub async fn stop(&self) {
        self.shared.pushes.stop().await;
    }

    /// Reloads the CRL file now: how many certificates it revokes.
    pub fn reload_revocations(&self) -> Result<usize, String> {
        let shared = &self.shared;
        let revocations = load_revocations(shared.config.server.crl.as_deref(), &shared.ca)?;
        let count = revocations.len();
        // A poisoned lock: the TLS checks refuse everyone, replace it all.
        match shared.revocations.write() {
            Ok(mut current) => *current = revocations,
            Err(poisoned) => *poisoned.into_inner() = revocations,
        }
        Ok(count)
    }
}

impl Shared {
    /// Runs `read` on a read connection, off the async threads.
    async fn read<T: Send + 'static>(
        self: &Arc<Self>,
        read: impl FnOnce(&Reader) -> bakashrot_storage::Result<T> + Send + 'static,
    ) -> Result<T, RequestRefused> {
        self.pooled(|shared| &shared.readers, Database::reader, read)
            .await
    }

    /// The SHA-256 of an attachment's stored `parts`, read back one at a
    /// time (to go on with more, or to compare).
    async fn hash_parts(
        self: &Arc<Self>,
        attachment_id: i64,
        parts: std::ops::Range<u64>,
    ) -> Result<aws_lc_rs::digest::Context, RequestRefused> {
        let mut sha256 = aws_lc_rs::digest::Context::new(&aws_lc_rs::digest::SHA256);
        for part in parts {
            let data = self
                .read(move |reader| reader.read_part(attachment_id, part))
                .await?;
            sha256.update(&data);
        }
        Ok(sha256)
    }

    /// Runs a client's SQL on a query connection, off the async threads.
    async fn query(self: &Arc<Self>, sql: String) -> Result<String, RequestRefused> {
        self.pooled(
            |shared| &shared.queries,
            Database::query_runner,
            move |runner: &QueryRunner| runner.run(&sql),
        )
        .await
    }

    /// Runs `work` on an idle connection of `pool`, or a new one, then
    /// puts it back.
    async fn pooled<C: Send + 'static, T: Send + 'static>(
        self: &Arc<Self>,
        pool: fn(&Shared) -> &Mutex<Vec<C>>,
        open: fn(&Database) -> bakashrot_storage::Result<C>,
        work: impl FnOnce(&C) -> bakashrot_storage::Result<T> + Send + 'static,
    ) -> Result<T, RequestRefused> {
        let shared = self.clone();
        tokio::task::spawn_blocking(move || {
            let idle = pool(&shared).lock().ok().and_then(|mut idle| idle.pop());
            let connection = match idle {
                Some(connection) => connection,
                None => open(&shared.database).map_err(refusal)?,
            };
            let value = work(&connection).map_err(refusal);
            if let Ok(mut idle) = pool(&shared).lock() {
                idle.push(connection);
            }
            value
        })
        .await
        .unwrap_or_else(|_| Err(server_error("a read failed")))
    }
}

/// Checkpoints the WAL every second, on a thread and a connection of its
/// own, so the writer doesn't do it in the middle of a commit (2.5 times
/// the pushes: `docs/storage.md`, "Against the old storage").
fn start_checkpoints(database: &Database) -> Result<(), String> {
    let checkpointer = database.checkpointer().map_err(|error| error.to_string())?;
    std::thread::Builder::new()
        .name("checkpoints".into())
        .spawn(move || {
            loop {
                std::thread::sleep(CHECKPOINT_INTERVAL);
                if let Err(error) = checkpointer.checkpoint() {
                    warn!("checkpointing the database: {error}");
                }
            }
        })
        .map(|_| ())
        .map_err(|error| format!("the checkpoints' thread: {error}"))
}

/// A storage error as the refusal clients get.
fn refusal(error: bakashrot_storage::Error) -> RequestRefused {
    use bakashrot_storage::Error;
    let code = match &error {
        Error::Invalid(_) => ErrorCode::InvalidRequest,
        Error::NotFound(_) => ErrorCode::NotFound,
        Error::UnknownName(_) => ErrorCode::UnknownName,
        Error::TooBig(_) => ErrorCode::TooBig,
        Error::Query(_) => ErrorCode::QueryFailed,
        Error::Sqlite(_) | Error::Unusable(_) => {
            warn!("the database: {error}");
            return server_error("the database failed");
        }
    };
    RequestRefused::new(code, error.to_string())
}

fn server_error(reason: &str) -> RequestRefused {
    RequestRefused::new(ErrorCode::ServerError, reason)
}

fn read(path: &Path) -> Result<String, String> {
    std::fs::read_to_string(path).map_err(|error| format!("{}: {error}", path.display()))
}

/// The CRL file's revocations; none without one (not set, or no file:
/// warned, a CRL deleted by mistake would revoke nothing silently).
fn load_revocations(path: Option<&Path>, ca: &str) -> Result<Revocations, String> {
    let Some(path) = path else {
        return Ok(Revocations::none());
    };
    if !path.exists() {
        warn!("{}: no such file, nothing revoked", path.display());
        return Ok(Revocations::none());
    }
    Revocations::load(&read(path)?, ca).map_err(|error| format!("{}: {error}", path.display()))
}

/// Refuses a clock before 1970: messages would be stamped `pushed_at` 0,
/// which readers refuse.
fn check_clock(now: SystemTime) -> Result<(), String> {
    match now.duration_since(UNIX_EPOCH) {
        Ok(_) => Ok(()),
        Err(_) => Err("the system's clock is before 1970: set it right first".into()),
    }
}

/// Now, in ms since 1970 UTC: when a message is pushed.
fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |since| since.as_millis() as u64)
}

/// A file's time and size, to see it changed.
fn stamp(path: &Path) -> Option<(SystemTime, u64)> {
    let metadata = std::fs::metadata(path).ok()?;
    Some((metadata.modified().ok()?, metadata.len()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_clock_before_1970_is_refused() {
        assert!(check_clock(UNIX_EPOCH).is_ok());
        assert!(check_clock(SystemTime::now()).is_ok());
        let before = UNIX_EPOCH - Duration::from_secs(1);
        let error = check_clock(before).unwrap_err();
        assert!(error.contains("before 1970"), "{error}");
    }
}
