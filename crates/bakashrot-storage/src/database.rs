//! Opening a database: making a new one, or checking and migrating one,
//! and the connections to it.

use crate::{Error, QueryRunner, Reader, Result, SCHEMA_VERSION, Writer};
use bakashrot_config::Synchronous;
use rusqlite::hooks::{AuthAction, AuthContext, Authorization};
use rusqlite::{Connection, OpenFlags, OptionalExtension, TransactionBehavior};
use std::path::{Path, PathBuf};
use std::time::Duration;

/// `PRAGMA application_id` of a BakaShrot database: "BSHT".
const APPLICATION_ID: i64 = 0x4253_4854;

/// The schema, made in one go.
const SCHEMA: &str = include_str!("schema_v9.sql");

/// Migrations from v9 on: the version each makes, and its SQL. Applied in
/// order from the database's version, each in one transaction with
/// `schema_version` set. None yet.
const MIGRATIONS: &[(i64, &str)] = &[];

/// How long a connection waits for another's lock before failing.
const BUSY_TIMEOUT: Duration = Duration::from_secs(5);

/// The WAL's size, in pages, past which the writer checkpoints it itself
/// (SQLite's default is 1000): a backstop when the [`Checkpointer`] can't
/// keep up.
pub const WRITER_CHECKPOINT_PAGES: u32 = 10_000;

/// Copies the WAL into the database on a connection of its own, so the
/// writer doesn't do it in the middle of a commit.
#[derive(Debug)]
pub struct Checkpointer {
    connection: Connection,
}

impl Checkpointer {
    /// Copies what it can without waiting for anyone (`PASSIVE`).
    pub fn checkpoint(&self) -> Result<()> {
        self.connection
            .query_row("PRAGMA wal_checkpoint(PASSIVE)", [], |_| Ok(()))?;
        Ok(())
    }
}

/// A database, opened and checked once: hands out connections to it.
#[derive(Debug, Clone)]
pub struct Database {
    path: PathBuf,
    synchronous: Synchronous,
}

impl Database {
    /// Opens the database at `path`: makes it if there's none (or it's an
    /// empty file), migrates an older one, refuses one that isn't a
    /// BakaShrot database of a version this one reads. Then deletes the
    /// uploads left over (their pushes never finished).
    pub fn open(path: &Path, synchronous: Synchronous) -> Result<Database> {
        let database = Database {
            path: path.to_owned(),
            synchronous,
        };
        let mut connection = database.connect()?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let application_id: i64 =
            transaction.query_row("PRAGMA application_id", [], |row| row.get(0))?;
        let tables: i64 =
            transaction.query_row("SELECT count(*) FROM sqlite_schema", [], |row| row.get(0))?;
        if application_id == 0 && tables == 0 {
            transaction.execute_batch(SCHEMA)?;
            transaction.execute(
                "INSERT INTO metadata (name, value) VALUES ('created_by', ?1)",
                [concat!("bakashrot-storage ", env!("CARGO_PKG_VERSION"))],
            )?;
        } else if application_id != APPLICATION_ID {
            return Err(Error::Unusable(format!(
                "{}: not a BakaShrot database",
                path.display()
            )));
        }
        let mut version = schema_version(&transaction)?;
        if version > SCHEMA_VERSION {
            return Err(Error::Unusable(format!(
                "{}: schema v{version}, made by a newer version (this one reads v{SCHEMA_VERSION})",
                path.display()
            )));
        }
        for (made, sql) in MIGRATIONS {
            if *made == version + 1 {
                transaction.execute_batch(sql)?;
                transaction.execute(
                    "UPDATE metadata SET value = ?1 WHERE name = 'schema_version'",
                    [made],
                )?;
                version = *made;
            }
        }
        if version != SCHEMA_VERSION {
            return Err(Error::Unusable(format!(
                "{}: schema v{version}, which this version can't migrate",
                path.display()
            )));
        }
        crate::batch::clean_up(&transaction)?;
        transaction.commit()?;
        Ok(database)
    }

    /// The connection that writes. Only one at a time should: a second
    /// waits for the first's transactions (up to 5 s, then fails). It only
    /// checkpoints the WAL itself past [`WRITER_CHECKPOINT_PAGES`]: a
    /// [`Checkpointer`] keeps that off its way.
    pub fn writer(&self) -> Result<Writer> {
        let connection = self.connect()?;
        connection.pragma_update(None, "wal_autocheckpoint", WRITER_CHECKPOINT_PAGES)?;
        Ok(Writer::new(connection))
    }

    /// A connection that copies the WAL into the database, off the
    /// writer's way: call [`Checkpointer::checkpoint`] every second or so.
    pub fn checkpointer(&self) -> Result<Checkpointer> {
        Ok(Checkpointer {
            connection: self.connect()?,
        })
    }

    /// A connection that reads, as many as needed.
    pub fn reader(&self) -> Result<Reader> {
        Ok(Reader::new(self.connect()?))
    }

    /// A connection for clients' queries: the file opened read-only
    /// (`SQLITE_OPEN_READONLY`: the file handle can't write), `query_only`,
    /// and every PRAGMA refused from then on (SQLite's authorizer). Some
    /// take effect when they're prepared, before a statement can be
    /// refused for what it is: `PRAGMA query_only = 0` turned
    /// `query_only` off for the connection's next queries. The database is
    /// in WAL mode already (the writer made it so), which a read-only
    /// connection can't change and doesn't need to.
    pub fn query_runner(&self) -> Result<QueryRunner> {
        let flags = OpenFlags::SQLITE_OPEN_READ_ONLY
            | OpenFlags::SQLITE_OPEN_URI
            | OpenFlags::SQLITE_OPEN_NO_MUTEX;
        let mut connection = Connection::open_with_flags(&self.path, flags)?;
        connection.busy_timeout(BUSY_TIMEOUT)?;
        connection.pragma_update(None, "query_only", true)?;
        connection.authorizer(Some(|context: AuthContext<'_>| match context.action {
            AuthAction::Pragma { .. } => Authorization::Deny,
            _ => Authorization::Allow,
        }))?;
        QueryRunner::new(connection)
    }

    /// A connection with this database's settings: WAL, `synchronous`, the
    /// busy timeout.
    fn connect(&self) -> Result<Connection> {
        let connection = Connection::open(&self.path)?;
        connection.busy_timeout(BUSY_TIMEOUT)?;
        let mode: String =
            connection.query_row("PRAGMA journal_mode = WAL", [], |row| row.get(0))?;
        if !mode.eq_ignore_ascii_case("wal") {
            return Err(Error::Unusable(format!(
                "{}: can't be put in WAL mode (it's in {mode})",
                self.path.display()
            )));
        }
        let synchronous = match self.synchronous {
            Synchronous::Full => "FULL",
            Synchronous::Normal => "NORMAL",
        };
        connection.pragma_update(None, "synchronous", synchronous)?;
        Ok(connection)
    }
}

/// `metadata`'s `schema_version`.
fn schema_version(connection: &Connection) -> Result<i64> {
    let has_metadata: bool = connection.query_row(
        "SELECT count(*) > 0 FROM sqlite_schema WHERE type = 'table' AND name = 'metadata'",
        [],
        |row| row.get(0),
    )?;
    let version = if has_metadata {
        connection
            .query_row(
                "SELECT value FROM metadata WHERE name = 'schema_version'",
                [],
                |row| row.get(0),
            )
            .optional()?
    } else {
        None
    };
    version.ok_or_else(|| Error::Unusable("a BakaShrot database without its schema version".into()))
}
