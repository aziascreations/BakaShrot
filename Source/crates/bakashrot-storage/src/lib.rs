//! BakaShrot's database: SQLite, schema v9 (`schema_v9.sql`).
//!
//! - [`Database`]: opens one (creating it, or checking it's a v9 one),
//!   and hands out connections.
//! - [`Writer`]: the one connection that writes. Everything is written in
//!   a [`Batch`], one transaction: pushes, replication, attachments,
//!   retention. Many pushes in one batch is a group commit. And
//!   [`Writer::vacuum`], to shrink the file.
//! - [`Reader`]: as many as needed, reading while the writer writes (WAL).
//! - [`QueryRunner`]: clients' read-only SQL, on a read-only connection.
//!
//! **Everything is by name:** topics, nodes, message ids, times, as on the
//! wire. Streams (one node's messages in one topic) and the packed keys
//! that store them stay inside this crate: `Source/docs/storage.md`.
//!
//! **Blocking:** SQLite is. The server runs these on threads of their own
//! (the writer on one, readers on a pool), not on its async tasks.

mod batch;
mod database;
mod query;
mod reader;

pub use batch::{Batch, Writer};
pub use database::{Checkpointer, Database, WRITER_CHECKPOINT_PAGES};
pub use query::{MAX_QUERY_BYTES, MAX_QUERY_ROWS, QueryRunner};
pub use reader::{Attachment, MESSAGES_BYTES, Reader};

use bakashrot_proto::limits::{MAX_ATTACHMENT_PARTS, MAX_MESSAGE_ID};
use rusqlite::types::{FromSql, FromSqlError, FromSqlResult, ToSql, ToSqlOutput, ValueRef};
use rusqlite::{Connection, OptionalExtension};
use std::fmt;

/// The schema version this crate makes and reads.
pub const SCHEMA_VERSION: i64 = 9;

/// The most streams (topic and node pairs) a database holds: 2^20 - 1.
pub const MAX_STREAMS: i64 = (1 << STREAM_BITS) - 1;

/// What went wrong. The server answers each with its own refusal code.
#[derive(Debug)]
pub enum Error {
    /// SQLite failed (the disk, a lock held too long...): `ServerError`.
    Sqlite(rusqlite::Error),
    /// A database this version doesn't open: another program's, the old
    /// server's, a newer schema's. Said at start.
    Unusable(String),
    /// A request that doesn't fit what's stored: a part out of order or of
    /// the wrong size, an attachment in the wrong state: `InvalidRequest`.
    Invalid(String),
    /// No such attachment: `NotFound`.
    NotFound(String),
    /// A node without any message, in any topic: `UnknownName`.
    UnknownName(String),
    /// Over a limit: streams, message ids, a query's result: `TooBig`.
    TooBig(String),
    /// A client's query that failed or isn't read-only: `QueryFailed`.
    Query(String),
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Sqlite(error) => write!(f, "database: {error}"),
            Error::Unusable(what)
            | Error::Invalid(what)
            | Error::NotFound(what)
            | Error::UnknownName(what)
            | Error::TooBig(what)
            | Error::Query(what) => f.write_str(what),
        }
    }
}

impl std::error::Error for Error {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Error::Sqlite(error) => Some(error),
            _ => None,
        }
    }
}

impl From<rusqlite::Error> for Error {
    fn from(error: rusqlite::Error) -> Self {
        Error::Sqlite(error)
    }
}

/// A result of this crate.
pub type Result<T> = std::result::Result<T, Error>;

/// Where an attachment is at (`Source/docs/storage.md`, "Attachments").
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AttachmentState {
    /// Pushed, its parts coming, no message yet.
    Uploading,
    /// Its message came from a peer, its parts come after.
    Replicating,
    /// All here, checked.
    Ready,
    /// Bigger than this server keeps: never asked for.
    TooBig,
    /// Its message was deleted, its parts go in the background.
    Deleting,
}

impl AttachmentState {
    const ALL: [AttachmentState; 5] = [
        AttachmentState::Uploading,
        AttachmentState::Replicating,
        AttachmentState::Ready,
        AttachmentState::TooBig,
        AttachmentState::Deleting,
    ];

    /// As the database writes it.
    pub fn as_str(self) -> &'static str {
        match self {
            AttachmentState::Uploading => "uploading",
            AttachmentState::Replicating => "replicating",
            AttachmentState::Ready => "ready",
            AttachmentState::TooBig => "too_big",
            AttachmentState::Deleting => "deleting",
        }
    }
}

impl fmt::Display for AttachmentState {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl ToSql for AttachmentState {
    fn to_sql(&self) -> rusqlite::Result<ToSqlOutput<'_>> {
        Ok(self.as_str().into())
    }
}

impl FromSql for AttachmentState {
    fn column_result(value: ValueRef<'_>) -> FromSqlResult<Self> {
        let text = value.as_str()?;
        Self::ALL
            .into_iter()
            .find(|state| state.as_str() == text)
            .ok_or(FromSqlError::InvalidType)
    }
}

/// A topic and node's stream, if it has one: its id and last id.
fn find_stream(db: &Connection, topic: &str, node: &str) -> rusqlite::Result<Option<(i64, u64)>> {
    db.prepare_cached("SELECT stream_id, last_id FROM streams WHERE topic = ?1 AND node = ?2")?
        .query_row((topic, node), |row| Ok((row.get(0)?, row.get(1)?)))
        .optional()
}

// The packed keys (storage.md, "Keys"). Only these know the layout (and
// the schema's generated columns, which a test checks against them).

/// Bits of a message id in `data.key`, below the stream's.
const ID_BITS: u32 = 43;
/// Bits of a stream id above them: 43 + 20 = 63, a positive i64.
const STREAM_BITS: u32 = 20;
/// Bits of a part's index in `attachment_parts.key`.
const PART_BITS: u32 = 20;
const ID_MASK: i64 = (1 << ID_BITS) - 1;

const _: () = assert!(MAX_MESSAGE_ID == ID_MASK as u64, "ids fill their bits");
const _: () = assert!(MAX_ATTACHMENT_PARTS == 1 << PART_BITS, "parts fill theirs");

/// `data.key` of a stream's message.
fn message_key(stream: i64, id: u64) -> i64 {
    (stream << ID_BITS) | id as i64
}

/// The message id in a `data.key`.
fn message_id(key: i64) -> u64 {
    (key & ID_MASK) as u64
}

/// The first and last `data.key` a stream can have.
fn stream_keys(stream: i64) -> (i64, i64) {
    (message_key(stream, 1), message_key(stream, MAX_MESSAGE_ID))
}

/// `attachment_parts.key` of an attachment's part.
fn part_key(attachment: i64, part: u64) -> i64 {
    (attachment << PART_BITS) | part as i64
}

/// The first and last `attachment_parts.key` an attachment can have.
fn part_keys(attachment: i64) -> (i64, i64) {
    (
        part_key(attachment, 0),
        part_key(attachment, MAX_ATTACHMENT_PARTS - 1),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keys() {
        let key = message_key(MAX_STREAMS, MAX_MESSAGE_ID);
        assert_eq!(key, i64::MAX);
        assert_eq!(message_id(key), MAX_MESSAGE_ID);
        assert_eq!(key >> ID_BITS, MAX_STREAMS);
        assert_eq!(message_id(message_key(5, 42)), 42);
        let (first, last) = stream_keys(2);
        assert!(stream_keys(1).1 < first && last < stream_keys(3).0);
        let (first, last) = part_keys(7);
        assert_eq!(last - first + 1, MAX_ATTACHMENT_PARTS as i64);
        assert!(part_keys(6).1 < first);
    }

    #[test]
    fn the_schema_unpacks_keys_the_same() {
        let db = Connection::open_in_memory().unwrap();
        db.execute_batch(include_str!("schema_v9.sql")).unwrap();
        db.execute(
            "INSERT INTO streams (stream_id, topic, node) VALUES (?1, 't', 'n')",
            [MAX_STREAMS],
        )
        .unwrap();
        for (stream, id) in [(1, 1), (MAX_STREAMS, MAX_MESSAGE_ID), (77, 123_456_789)] {
            let key = message_key(stream, id);
            db.execute(
                "INSERT INTO data (key, pushed_at, message_data) VALUES (?1, 1, '')",
                [key],
            )
            .unwrap();
            let (sql_stream, sql_id): (i64, u64) = db
                .query_row(
                    "SELECT stream_id, message_id FROM data WHERE key = ?1",
                    [key],
                    |r| Ok((r.get(0)?, r.get(1)?)),
                )
                .unwrap();
            assert_eq!((sql_stream, sql_id), (stream, id));
        }
        // The trigger reads the same id.
        let last: u64 = db
            .query_row(
                "SELECT last_id FROM streams WHERE stream_id = ?1",
                [MAX_STREAMS],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(last, MAX_MESSAGE_ID);
    }

    #[test]
    fn states_round_trip() {
        let db = Connection::open_in_memory().unwrap();
        for state in AttachmentState::ALL {
            let back: AttachmentState = db.query_row("SELECT ?1", [state], |r| r.get(0)).unwrap();
            assert_eq!(back, state);
        }
        let wrong: rusqlite::Result<AttachmentState> =
            db.query_row("SELECT 'lost'", [], |r| r.get(0));
        assert!(wrong.is_err());
    }
}
