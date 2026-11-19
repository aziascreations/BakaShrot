//! Clients' read-only SQL (`Query`).
//!
//! Read-only four ways: the file is opened read-only (the handle itself
//! can't write), the connection has `query_only` on (SQLite refuses any
//! write), the statement must be one SQLite says only reads
//! (`sqlite3_stmt_readonly`), and only one statement runs (more is an
//! error, not ignored). PRAGMAs are refused as they're prepared
//! (`Database::query_runner`'s authorizer): some would change the
//! connection, `query_only` included, before the statement is looked
//! at. The result is JSON, every value a string or null:
//! `{"columns":[...],"rows":[[...],...]}`.

use crate::{Error, Result};
use bakashrot_proto::limits::MAX_MESSAGE_SIZE;
use rusqlite::Connection;
use rusqlite::types::ValueRef;
use serde_json::Value;

/// The most rows a query returns, as before.
pub const MAX_QUERY_ROWS: usize = 10_000;

/// The biggest result, in bytes of JSON: what a packet carries.
pub const MAX_QUERY_BYTES: usize = MAX_MESSAGE_SIZE;

/// A read-only connection for clients' queries.
#[derive(Debug)]
pub struct QueryRunner {
    connection: Connection,
}

impl QueryRunner {
    pub(crate) fn new(connection: Connection) -> QueryRunner {
        QueryRunner { connection }
    }

    /// Runs one read-only statement: its result as JSON. Refused
    /// ([`Error::Query`]) if it isn't one, or fails (SQLite's message, a
    /// failing row included: never a partial result); [`Error::TooBig`]
    /// past [`MAX_QUERY_ROWS`] or [`MAX_QUERY_BYTES`].
    pub fn run(&self, sql: &str) -> Result<String> {
        let failed = |error: rusqlite::Error| Error::Query(explain(error.to_string()));
        let mut statement = self.connection.prepare(sql).map_err(failed)?;
        if !statement.readonly() || statement.column_count() == 0 {
            return Err(Error::Query("only queries that read are allowed".into()));
        }
        let columns: Vec<String> = statement.column_names().map(str::to_owned).collect();
        let width = columns.len();
        let mut rows: Vec<Vec<Value>> = Vec::new();
        let mut bytes = 0;
        let mut results = statement.query([]).map_err(failed)?;
        while let Some(row) = results.next().map_err(failed)? {
            if rows.len() == MAX_QUERY_ROWS {
                return Err(Error::TooBig(format!(
                    "more than {MAX_QUERY_ROWS} rows: narrow the query (LIMIT)"
                )));
            }
            let mut values = Vec::with_capacity(width);
            for column in 0..width {
                let value = text(row.get_ref(column).map_err(failed)?);
                // Its JSON's size, about: quotes, escapes aside.
                bytes += value.as_str().map_or(5, |text| text.len() + 3);
                values.push(value);
            }
            if bytes > MAX_QUERY_BYTES {
                return Err(Error::TooBig(format!(
                    "a result over {MAX_QUERY_BYTES} bytes: narrow the query"
                )));
            }
            rows.push(values);
        }
        let json = serde_json::json!({ "columns": columns, "rows": rows }).to_string();
        if json.len() > MAX_QUERY_BYTES {
            return Err(Error::TooBig(format!(
                "a result over {MAX_QUERY_BYTES} bytes: narrow the query"
            )));
        }
        Ok(json)
    }
}

/// SQLite's error, with a hint where one helps.
fn explain(why: String) -> String {
    if why.contains("malformed JSON") {
        format!("{why} (a row isn't JSON: add is_json = 1 to the WHERE)")
    } else {
        why
    }
}

/// A value as text, or null: numbers as SQLite writes them, blobs in hex.
fn text(value: ValueRef<'_>) -> Value {
    match value {
        ValueRef::Null => Value::Null,
        ValueRef::Integer(number) => Value::String(number.to_string()),
        ValueRef::Real(number) => Value::String(format!("{number:?}")),
        ValueRef::Text(text) => Value::String(String::from_utf8_lossy(text).into_owned()),
        ValueRef::Blob(bytes) => Value::String(bytes.iter().map(|b| format!("{b:02x}")).collect()),
    }
}

#[cfg(test)]
mod tests {
    use crate::Database;
    use bakashrot_config::Synchronous;
    use rusqlite::MAIN_DB;
    use std::path::PathBuf;

    /// The fifth guard, which the others hide from a test of what's
    /// refused: SQLite says the file itself is read-only on it.
    #[test]
    fn the_file_is_opened_read_only() {
        let folder = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../target/storage-unit");
        std::fs::create_dir_all(&folder).unwrap();
        let path = folder.join(format!("query-{}.sqlite", std::process::id()));
        let database = Database::open(&path, Synchronous::Normal).unwrap();
        // The server's writer is always open: the WAL's files are there.
        let writer = database.writer().unwrap();
        let runner = database.query_runner().unwrap();
        assert!(runner.connection.is_readonly(MAIN_DB).unwrap());
        assert_eq!(
            runner.run("SELECT 1 AS one").unwrap(),
            r#"{"columns":["one"],"rows":[["1"]]}"#
        );
        drop((runner, writer, database));
        for suffix in ["", "-wal", "-shm"] {
            let _ = std::fs::remove_file(format!("{}{suffix}", path.display()));
        }
    }
}
