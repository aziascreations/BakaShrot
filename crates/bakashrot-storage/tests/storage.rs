//! The storage, end to end on database files: every request's SQL, the
//! limits, refused databases, and readers and writers at once.

use bakashrot_config::Synchronous;
use bakashrot_proto::limits::{ATTACHMENT_PART_SIZE, MAX_MESSAGE_ID};
use bakashrot_proto::packets::{Attachment as Sent, ReplicatedMessage};
use bakashrot_storage::{AttachmentState, Database, Error, MAX_QUERY_ROWS, MAX_STREAMS};
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};

const PART: usize = ATTACHMENT_PART_SIZE as usize;

/// A fresh database file of its own (in target/, not the temp folder).
fn path(name: &str) -> PathBuf {
    static COUNT: AtomicUsize = AtomicUsize::new(0);
    let folder = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join(format!(
        "storage-{}-{}-{name}",
        std::process::id(),
        COUNT.fetch_add(1, Ordering::Relaxed)
    ));
    let _ = std::fs::remove_dir_all(&folder);
    std::fs::create_dir_all(&folder).unwrap();
    folder.join("bakashrot.sqlite")
}

fn open(name: &str) -> (Database, PathBuf) {
    let path = path(name);
    (Database::open(&path, Synchronous::Normal).unwrap(), path)
}

fn ids(messages: &bakashrot_proto::packets::Messages) -> Vec<u64> {
    messages.messages.iter().map(|m| m.id).collect()
}

fn replicated(id: u64, pushed_at: u64, attachment: Option<(u64, [u8; 32])>) -> ReplicatedMessage {
    ReplicatedMessage {
        id,
        pushed_at,
        data: format!("r{id}"),
        attachment: attachment.map(|(size, sha256)| Sent { size, sha256 }),
    }
}

#[test]
fn opening() {
    let (database, path) = open("opening");
    let raw = rusqlite::Connection::open(&path).unwrap();
    let meta = |name: &str| -> String {
        raw.query_row(
            "SELECT CAST(value AS TEXT) FROM metadata WHERE name = ?1",
            [name],
            |r| r.get(0),
        )
        .unwrap()
    };
    assert_eq!(meta("schema_version"), "9");
    assert!(meta("created_by").starts_with("bakashrot-storage "));
    assert!(meta("created_at").parse::<u64>().unwrap() > 1_700_000_000_000);
    let mode: String = raw
        .query_row("PRAGMA journal_mode", [], |r| r.get(0))
        .unwrap();
    assert_eq!(mode, "wal");
    drop(database);
    // Opened again as it is.
    Database::open(&path, Synchronous::Full).unwrap();

    // An empty file is made a database.
    let empty = self::path("empty");
    std::fs::write(&empty, b"").unwrap();
    Database::open(&empty, Synchronous::Full).unwrap();
}

#[test]
fn refused_databases() {
    let refused = |setup: &str, expected: &str| {
        let path = path("refused");
        rusqlite::Connection::open(&path)
            .unwrap()
            .execute_batch(setup)
            .unwrap();
        match Database::open(&path, Synchronous::Full) {
            Err(Error::Unusable(why)) => assert!(why.contains(expected), "{why}"),
            other => panic!("{setup}: {other:?}"),
        }
    };
    refused("CREATE TABLE other (x);", "not a BakaShrot database");
    refused(
        "PRAGMA application_id = 1112754260; CREATE TABLE x (y);",
        "without its schema version",
    );

    // A newer version's.
    let (database, path) = open("newer");
    drop(database);
    rusqlite::Connection::open(&path)
        .unwrap()
        .execute(
            "UPDATE metadata SET value = 10 WHERE name = 'schema_version'",
            [],
        )
        .unwrap();
    match Database::open(&path, Synchronous::Full) {
        Err(Error::Unusable(why)) => assert!(why.contains("schema v10, made by a newer"), "{why}"),
        other => panic!("{other:?}"),
    }
}

#[test]
fn pushing_and_reading() {
    let (database, _) = open("push");
    let mut writer = database.writer().unwrap();
    let reader = database.reader().unwrap();

    // A group commit: ids per topic and node, names without case.
    let ids_pushed = writer
        .batch(|batch| {
            Ok(vec![
                batch.push("logs", "kitchen", 1000, "{\"t\":1}")?,
                batch.push("logs", "kitchen", 1001, "not json")?,
                batch.push("LOGS", "Kitchen", 1002, "{}")?,
                batch.push("logs", "garage", 1003, "{}")?,
                batch.push("sensors", "kitchen", 1004, "{}")?,
            ])
        })
        .unwrap();
    assert_eq!(ids_pushed, [1, 2, 3, 1, 1]);

    let all = reader.messages("logs", "kitchen", Some(0), 100).unwrap();
    assert_eq!(ids(&all), [1, 2, 3]);
    assert!(!all.more);
    assert_eq!(all.messages[1].data, "not json");
    assert_eq!(all.messages[0].pushed_at, 1000);
    assert!(all.messages[0].attachment.is_none());

    // after, limit, more; the latest ones, in order.
    let some = reader.messages("logs", "kitchen", Some(1), 1).unwrap();
    assert_eq!((ids(&some), some.more), (vec![2], true));
    let latest = reader.messages("Logs", "KITCHEN", None, 2).unwrap();
    assert_eq!((ids(&latest), latest.more), (vec![2, 3], false));
    assert!(
        reader
            .messages("logs", "kitchen", Some(3), 10)
            .unwrap()
            .messages
            .is_empty()
    );
    // A node without any message, in any topic: unknown.
    assert!(matches!(
        reader.messages("logs", "nobody", None, 10),
        Err(Error::UnknownName(_))
    ));
    assert!(
        reader
            .messages("logs", "kitchen", Some(MAX_MESSAGE_ID), 10)
            .unwrap()
            .messages
            .is_empty()
    );

    // Names, heads.
    assert_eq!(reader.topics().unwrap(), ["logs", "sensors"]);
    let heads: Vec<_> = reader
        .heads()
        .unwrap()
        .into_iter()
        .map(|h| (h.topic, h.node, h.last_id))
        .collect();
    assert_eq!(
        heads,
        [
            ("logs".into(), "garage".into(), 1),
            ("logs".into(), "kitchen".into(), 3),
            ("sensors".into(), "kitchen".into(), 1)
        ]
    );
    // In pages: after a pair (its names without case), so many at most.
    let page = |after, limit| -> Vec<_> {
        reader
            .heads_after(after, limit)
            .unwrap()
            .into_iter()
            .map(|h| (h.topic, h.node))
            .collect()
    };
    assert_eq!(
        page(None, 2),
        [
            ("logs".into(), "garage".into()),
            ("logs".into(), "kitchen".into())
        ]
    );
    assert_eq!(
        page(Some(("LOGS", "Kitchen")), 2),
        [("sensors".into(), "kitchen".into())]
    );
    assert_eq!(
        page(Some(("logs", "h")), 1),
        [("logs".into(), "kitchen".into())]
    );
    assert!(page(Some(("sensors", "kitchen")), 2).is_empty());
    assert_eq!(reader.last_id("logs", "kitchen").unwrap(), 3);
    assert_eq!(reader.last_id("nope", "kitchen").unwrap(), 0);
}

#[test]
fn answers_stop_at_about_a_megabyte() {
    let (database, _) = open("bytes");
    let mut writer = database.writer().unwrap();
    let big = "x".repeat(400 * 1024);
    writer
        .batch(|batch| {
            for _ in 0..5 {
                batch.push("logs", "kitchen", 1, &big)?;
            }
            batch.push("logs", "kitchen", 1, &"y".repeat(3 * 1024 * 1024))?;
            Ok(())
        })
        .unwrap();
    let reader = database.reader().unwrap();
    let first = reader.messages("logs", "kitchen", Some(0), 100).unwrap();
    assert_eq!((ids(&first), first.more), (vec![1, 2], true));
    let next = reader.messages("logs", "kitchen", Some(4), 100).unwrap();
    assert_eq!((ids(&next), next.more), (vec![5], true));
    // A bigger message goes alone.
    let alone = reader.messages("logs", "kitchen", Some(5), 100).unwrap();
    assert_eq!((ids(&alone), alone.more), (vec![6], false));
}

#[test]
fn uploads() {
    let (database, path) = open("uploads");
    let mut writer = database.writer().unwrap();
    let size = (2 * PART + 10) as u64;
    let sha = [7; 32];
    let upload = writer.batch(|b| b.start_upload(size, &sha)).unwrap();

    let part = |n: usize| vec![n as u8; if n == 2 { 10 } else { PART }];
    // Only in order, each its size.
    assert!(matches!(
        writer.batch(|b| b.write_part(upload, 1, &part(1))),
        Err(Error::Invalid(_))
    ));
    assert!(matches!(
        writer.batch(|b| b.write_part(upload, 0, &[0; 10])),
        Err(Error::Invalid(_))
    ));
    assert!(!writer.batch(|b| b.write_part(upload, 0, &part(0))).unwrap());
    assert!(!writer.batch(|b| b.write_part(upload, 1, &part(1))).unwrap());
    // Not complete: no push with it, and the batch goes on after.
    let pushed = writer
        .batch(|b| {
            assert!(matches!(
                b.push_with_attachment(upload, "logs", "kitchen", 1, "{}"),
                Err(Error::Invalid(_))
            ));
            b.push("logs", "kitchen", 1, "without")
        })
        .unwrap();
    assert_eq!(pushed, 1);
    assert!(writer.batch(|b| b.write_part(upload, 2, &part(2))).unwrap());
    assert!(matches!(
        writer.batch(|b| b.write_part(upload, 3, &[1])),
        Err(Error::Invalid(_))
    ));
    let id = writer
        .batch(|b| b.push_with_attachment(upload, "logs", "kitchen", 2, "with"))
        .unwrap();
    assert_eq!(id, 2);

    let reader = database.reader().unwrap();
    let message = &reader
        .messages("logs", "kitchen", Some(1), 1)
        .unwrap()
        .messages[0];
    let stored = message.attachment.as_ref().unwrap();
    assert_eq!((stored.size, stored.ready), (size, true));
    let attachment = reader.attachment("logs", "kitchen", 2).unwrap().unwrap();
    assert_eq!(
        (attachment.state, attachment.sha256, attachment.received),
        (AttachmentState::Ready, sha, size)
    );
    assert_eq!(reader.read_part(attachment.id, 1).unwrap(), part(1));
    assert_eq!(reader.read_part(attachment.id, 2).unwrap(), part(2));
    assert!(matches!(
        reader.read_part(attachment.id, 3),
        Err(Error::NotFound(_))
    ));
    assert!(reader.attachment("logs", "kitchen", 1).unwrap().is_none());

    // Cancelled, or left over at a restart: gone with their parts.
    let cancelled = writer.batch(|b| b.start_upload(5, &sha)).unwrap();
    writer
        .batch(|b| b.write_part(cancelled, 0, &[1; 5]))
        .unwrap();
    writer.batch(|b| b.cancel_upload(cancelled)).unwrap();
    assert!(matches!(
        writer.batch(|b| b.cancel_upload(cancelled)),
        Err(Error::NotFound(_))
    ));
    let left = writer.batch(|b| b.start_upload(5, &sha)).unwrap();
    writer.batch(|b| b.write_part(left, 0, &[1; 5])).unwrap();
    drop((writer, reader, database));
    Database::open(&path, Synchronous::Normal).unwrap();
    let raw = rusqlite::Connection::open(&path).unwrap();
    let count = |sql: &str| raw.query_row(sql, [], |r| r.get::<_, i64>(0)).unwrap();
    assert_eq!(count("SELECT count(*) FROM attachments"), 1);
    assert_eq!(count("SELECT count(*) FROM attachment_parts"), 3);

    // Sizes.
    let database = Database::open(&path, Synchronous::Normal).unwrap();
    let mut writer = database.writer().unwrap();
    assert!(matches!(
        writer.batch(|b| b.start_upload(0, &sha)),
        Err(Error::TooBig(_))
    ));
    assert!(matches!(
        writer.batch(|b| b.start_upload((1 << 40) + 1, &sha)),
        Err(Error::TooBig(_))
    ));
}

#[test]
fn replication() {
    let (database, _) = open("replication");
    let mut writer = database.writer().unwrap();
    let reader = database.reader().unwrap();
    let sha = [3; 32];
    let last = writer
        .batch(|b| {
            b.replicate(
                "logs",
                "kitchen",
                &[
                    replicated(5, 100, None),
                    replicated(9, 200, Some((PART as u64 + 1, sha))),
                    replicated(12, 300, Some((50, sha))),
                ],
                1000,
                0,
            )
        })
        .unwrap();
    assert_eq!(last, 12);
    // Ones already here are kept as they are; the head never goes back.
    let again = writer
        .batch(|b| {
            b.replicate(
                "logs",
                "kitchen",
                &[ReplicatedMessage {
                    data: "other".into(),
                    ..replicated(5, 1, None)
                }],
                1000,
                0,
            )
        })
        .unwrap();
    assert_eq!(again, 12);
    let stored = reader.messages("logs", "kitchen", Some(0), 10).unwrap();
    assert_eq!(ids(&stored), [5, 9, 12]);
    assert_eq!(stored.messages[0].data, "r5");
    // A push goes on after the replicated ids.
    assert_eq!(
        writer
            .batch(|b| b.push("logs", "kitchen", 400, "{}"))
            .unwrap(),
        13
    );

    // Attachments: too big here, or to ask for.
    let big = reader.attachment("logs", "kitchen", 9).unwrap().unwrap();
    assert_eq!(big.state, AttachmentState::TooBig);
    assert!(!stored.messages[1].attachment.as_ref().unwrap().ready);
    let missing = reader.missing_attachments(256).unwrap();
    assert_eq!(missing.len(), 1);
    assert_eq!((missing[0].message_id, missing[0].next_part), (12, 0));

    // Its parts; a mismatch starts it over; a match makes it ready.
    let small = reader.attachment("logs", "kitchen", 12).unwrap().unwrap();
    assert!(
        writer
            .batch(|b| b.write_part(small.id, 0, &[1; 50]))
            .unwrap()
    );
    writer
        .batch(|b| b.finish_replicated(small.id, false))
        .unwrap();
    assert_eq!(
        reader
            .attachment("logs", "kitchen", 12)
            .unwrap()
            .unwrap()
            .received,
        0
    );
    assert_eq!(reader.missing_attachments(256).unwrap()[0].next_part, 0);
    assert!(
        writer
            .batch(|b| b.write_part(small.id, 0, &[2; 50]))
            .unwrap()
    );
    writer
        .batch(|b| b.finish_replicated(small.id, true))
        .unwrap();
    assert_eq!(
        reader
            .attachment("logs", "kitchen", 12)
            .unwrap()
            .unwrap()
            .state,
        AttachmentState::Ready
    );
    assert!(reader.missing_attachments(256).unwrap().is_empty());
    assert!(matches!(
        writer.batch(|b| b.finish_replicated(small.id, true)),
        Err(Error::Invalid(_))
    ));
    assert!(matches!(
        writer.batch(|b| b.write_part(big.id, 0, &[0; PART])),
        Err(Error::Invalid(_))
    ));

    // A resumed one: next_part follows what came.
    writer
        .batch(|b| {
            b.replicate(
                "logs",
                "garage",
                &[replicated(1, 1, Some((2 * PART as u64, sha)))],
                u64::MAX,
                0,
            )
        })
        .unwrap();
    let resumed = reader.attachment("logs", "garage", 1).unwrap().unwrap();
    writer
        .batch(|b| b.write_part(resumed.id, 0, &[0; PART]))
        .unwrap();
    let missing = reader.missing_attachments(256).unwrap();
    assert_eq!(
        (missing[0].node.as_str(), missing[0].next_part),
        ("garage", 1)
    );

    // What's sent on: after an id, with its attachments' SHA-256s.
    let sent = reader.to_replicate("logs", "kitchen", 5, 10).unwrap();
    let sent_ids: Vec<u64> = sent.iter().map(|m| m.id).collect();
    assert_eq!(sent_ids, [9, 12, 13]);
    assert_eq!(
        sent[0].attachment,
        Some(Sent {
            size: PART as u64 + 1,
            sha256: sha
        })
    );
    assert_eq!(sent[2].attachment, None);
    assert_eq!(
        reader.to_replicate("logs", "kitchen", 9, 1).unwrap()[0].id,
        12
    );
    assert!(
        reader
            .to_replicate("logs", "kitchen", 13, 10)
            .unwrap()
            .is_empty()
    );
    assert!(
        reader
            .to_replicate("logs", "nobody", 0, 10)
            .unwrap()
            .is_empty()
    );

    // A damaged ready copy: its parts go, asked for again.
    writer.batch(|b| b.damaged(small.id)).unwrap();
    let again = reader.attachment("logs", "kitchen", 12).unwrap().unwrap();
    assert_eq!(
        (again.state, again.received),
        (AttachmentState::Replicating, 0)
    );
    assert!(reader.read_part(small.id, 0).is_err());
    assert!(matches!(
        writer.batch(|b| b.damaged(small.id)),
        Err(Error::Invalid(_))
    ));

    // Past their age here: not stored, but counted.
    let last = writer
        .batch(|b| {
            b.replicate(
                "logs",
                "attic",
                &[
                    replicated(1, 100, Some((50, sha))),
                    replicated(2, 200, None),
                    replicated(3, 300, None),
                ],
                1000,
                201,
            )
        })
        .unwrap();
    assert_eq!(last, 3);
    assert_eq!(
        ids(&reader.messages("logs", "attic", Some(0), 10).unwrap()),
        [3]
    );
    assert_eq!(reader.last_id("logs", "attic").unwrap(), 3);
    let skipped = writer
        .batch(|b| b.replicate("logs", "cellar", &[replicated(7, 100, None)], 1000, 201))
        .unwrap();
    assert_eq!((skipped, reader.last_id("logs", "cellar").unwrap()), (7, 7));

    // Ids out of range.
    assert!(matches!(
        writer.batch(|b| b.replicate("logs", "kitchen", &[replicated(0, 1, None)], 0, 0)),
        Err(Error::Invalid(_))
    ));
}

#[test]
fn retention() {
    let (database, _) = open("retention");
    let mut writer = database.writer().unwrap();
    let reader = database.reader().unwrap();
    writer
        .batch(|b| {
            for at in 1..=10 {
                b.push("logs", "kitchen", at * 100, "{}")?;
                b.push("logs", "garage", at * 100 + 50, "{}")?;
                b.push("sensors", "kitchen", at * 100, "{}")?;
            }
            Ok(())
        })
        .unwrap();
    // An attachment on an old message.
    let upload = writer
        .batch(|b| b.start_upload(3 * PART as u64, &[1; 32]))
        .unwrap();
    for part in 0..3 {
        writer
            .batch(|b| b.write_part(upload, part, &[0; PART]))
            .unwrap();
    }
    writer
        .batch(|b| b.push_with_attachment(upload, "logs", "kitchen", 120, "{}"))
        .unwrap();

    // Before 500: kitchen 1-4 and 11 (pushed at 120, after 4: in id order, it
    // waits for 5-10), garage 1-4. A limit, then the rest.
    assert_eq!(
        writer.batch(|b| b.delete_before("logs", 500, 5)).unwrap(),
        5
    );
    assert_eq!(
        writer.batch(|b| b.delete_before("logs", 500, 100)).unwrap(),
        3
    );
    assert_eq!(
        writer.batch(|b| b.delete_before("logs", 500, 100)).unwrap(),
        0
    );
    assert_eq!(
        ids(&reader.messages("logs", "kitchen", Some(0), 100).unwrap()),
        [5, 6, 7, 8, 9, 10, 11]
    );
    assert_eq!(
        ids(&reader.messages("logs", "garage", Some(0), 100).unwrap()).len(),
        6
    );
    assert_eq!(
        ids(&reader.messages("sensors", "kitchen", Some(0), 100).unwrap()).len(),
        10
    );

    // Everything: the heads stay, ids go on.
    assert_eq!(
        writer
            .batch(|b| b.delete_before("logs", u64::MAX, 1000))
            .unwrap(),
        13
    );
    assert_eq!(reader.last_id("logs", "kitchen").unwrap(), 11);
    assert_eq!(
        writer
            .batch(|b| b.push("logs", "kitchen", 2000, "{}"))
            .unwrap(),
        12
    );

    // The attachment's parts go in batches, then its row.
    assert_eq!(reader.attachment("logs", "kitchen", 11).unwrap(), None);
    assert_eq!(writer.batch(|b| b.purge_attachments(2)).unwrap(), 2);
    assert_eq!(writer.batch(|b| b.purge_attachments(2)).unwrap(), 1);
    assert_eq!(writer.batch(|b| b.purge_attachments(2)).unwrap(), 0);
    assert!(matches!(
        reader.read_part(upload, 2),
        Err(Error::NotFound(_))
    ));
}

#[test]
fn limits() {
    let (database, path) = open("limits");
    let mut writer = database.writer().unwrap();
    writer
        .batch(|b| b.push("logs", "kitchen", 1, "{}"))
        .unwrap();
    let raw = rusqlite::Connection::open(&path).unwrap();
    // A topic and node with no id left.
    raw.execute("UPDATE streams SET last_id = ?1", [MAX_MESSAGE_ID as i64])
        .unwrap();
    assert!(matches!(
        writer.batch(|b| b.push("logs", "kitchen", 1, "{}")),
        Err(Error::TooBig(_))
    ));
    // No stream left.
    raw.execute(
        "INSERT INTO streams (stream_id, topic, node) VALUES (?1, 'x', 'y')",
        [MAX_STREAMS],
    )
    .unwrap();
    assert!(matches!(
        writer.batch(|b| b.push("new", "kitchen", 1, "{}")),
        Err(Error::TooBig(_))
    ));
    // The highest key there is.
    raw.execute(
        "UPDATE streams SET last_id = ?1 - 1 WHERE topic = 'x'",
        [MAX_MESSAGE_ID as i64],
    )
    .unwrap();
    assert_eq!(
        writer.batch(|b| b.push("x", "y", 1, "last")).unwrap(),
        MAX_MESSAGE_ID
    );
    let reader = database.reader().unwrap();
    let last = reader.messages("x", "y", None, 1).unwrap();
    assert_eq!(
        (last.messages[0].id, last.messages[0].data.as_str()),
        (MAX_MESSAGE_ID, "last")
    );
}

#[test]
fn queries() {
    let (database, _) = open("queries");
    let mut writer = database.writer().unwrap();
    writer
        .batch(|b| {
            b.push("logs", "kitchen", 1_700_000_000_000, "{\"t\": 21.5}")?;
            b.push("logs", "kitchen", 1_700_000_000_001, "not json")?;
            b.push("logs", "garage", 1_700_000_000_002, "{\"t\": 3}")
        })
        .unwrap();
    let runner = database.query_runner().unwrap();
    let json = |sql: &str| -> serde_json::Value {
        serde_json::from_str(&runner.run(sql).unwrap()).unwrap()
    };

    let result = json(
        "SELECT topic, node, message_id, is_json, pushed_utc, message_data ->> '$.t' AS t, \
         attachment_size FROM messages WHERE topic = 'logs' AND node = 'kitchen' AND is_json = 1",
    );
    assert_eq!(
        result,
        serde_json::json!({
            "columns": ["topic", "node", "message_id", "is_json", "pushed_utc", "t", "attachment_size"],
            "rows": [["logs", "kitchen", "1", "1", "2023-11-14T22:13:20.000Z", "21.5", null]]
        })
    );
    assert_eq!(
        json("SELECT x'00ff', 1.0, NULL")["rows"],
        serde_json::json!([["00ff", "1.0", null]])
    );
    assert_eq!(
        json("SELECT count(*) FROM messages")["rows"],
        serde_json::json!([["3"]])
    );

    // Refused: writes, whatever their form, more than one statement, no rows to give.
    for sql in [
        "DELETE FROM data",
        "WITH x AS (SELECT 1) DELETE FROM data",
        "INSERT INTO browse VALUES (1, 'logs', NULL)",
        "PRAGMA query_only = 0",
        "SELECT 1; DELETE FROM data",
        "CREATE TABLE t (x)",
        "ATTACH 'other.sqlite' AS other",
        "SELEKT 1",
    ] {
        assert!(matches!(runner.run(sql), Err(Error::Query(_))), "{sql}");
    }
    // PRAGMAs are refused as they're prepared, reading ones too: one that
    // changes the connection would have by the time it's looked at.
    for sql in [
        "PRAGMA query_only = 0",
        "PRAGMA query_only",
        "PRAGMA locking_mode = EXCLUSIVE",
        "PRAGMA database_list",
        "SELECT * FROM pragma_database_list",
    ] {
        match runner.run(sql) {
            Err(Error::Query(why)) => assert!(why.contains("not authorized"), "{sql}: {why}"),
            other => panic!("{sql}: {other:?}"),
        }
    }
    // Still read-only, still answering.
    assert_eq!(
        json("SELECT count(*) FROM messages")["rows"],
        serde_json::json!([["3"]])
    );
    // SQLite without what nothing here uses (LIBSQLITE3_FLAGS in
    // .cargo/config.toml): not built in, nor loadable.
    for option in [
        "ENABLE_FTS3",
        "ENABLE_FTS5",
        "ENABLE_RTREE",
        "ENABLE_DBSTAT_VTAB",
        "ENABLE_STAT4",
        "SOUNDEX",
        "ENABLE_LOAD_EXTENSION",
        "ENABLE_COLUMN_METADATA",
    ] {
        assert_eq!(
            json(&format!("SELECT sqlite_compileoption_used('{option}')"))["rows"],
            serde_json::json!([["0"]]),
            "{option}"
        );
    }
    assert!(matches!(
        runner.run("SELECT * FROM dbstat"),
        Err(Error::Query(_))
    ));
    // A failing row fails it all, with SQLite's message.
    match runner.run("SELECT message_data ->> '$.t' FROM messages") {
        Err(Error::Query(why)) => assert!(why.contains("malformed JSON"), "{why}"),
        other => panic!("{other:?}"),
    }
    // Too big.
    let rows = format!(
        "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i <= {MAX_QUERY_ROWS}) SELECT i FROM n"
    );
    assert!(matches!(runner.run(&rows), Err(Error::TooBig(_))));
    assert!(matches!(
        runner.run("WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 20) SELECT zeroblob(1000000) FROM n"),
        Err(Error::TooBig(_))
    ));
    // Still nothing written.
    assert_eq!(
        json("SELECT count(*) FROM data")["rows"],
        serde_json::json!([["3"]])
    );
}

#[test]
fn the_view_reads_by_key_range() {
    let (database, path) = open("plans");
    drop(database);
    let raw = rusqlite::Connection::open(&path).unwrap();
    for sql in [
        "SELECT * FROM messages WHERE topic = 'logs' AND node = 'kitchen'",
        "SELECT * FROM messages WHERE topic = 'logs' AND pushed_at > 5",
        "SELECT * FROM messages WHERE topic = 'logs' AND node = 'kitchen' ORDER BY message_id DESC LIMIT 5",
    ] {
        let plan: Vec<String> = raw
            .prepare(&format!("EXPLAIN QUERY PLAN {sql}"))
            .unwrap()
            .query_map([], |r| r.get(3))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        let plan = plan.join(" | ");
        assert!(
            plan.contains("INTEGER PRIMARY KEY (rowid>? AND rowid<?)"),
            "{sql}: {plan}"
        );
        assert!(!plan.contains("SCAN d"), "{sql}: {plan}");
    }
}

#[test]
fn readers_while_writing() {
    let (database, _) = open("concurrent");
    let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let readers: Vec<_> = (0..3)
        .map(|_| {
            let database = database.clone();
            let stop = stop.clone();
            std::thread::spawn(move || {
                let reader = database.reader().unwrap();
                let mut seen = 0;
                let mut reads = 0;
                while !stop.load(Ordering::Relaxed) {
                    let latest = match reader.messages("logs", "kitchen", None, 10) {
                        // Not pushed to yet.
                        Err(Error::UnknownName(_)) => continue,
                        latest => latest.unwrap(),
                    };
                    let ids = ids(&latest);
                    assert!(ids.windows(2).all(|w| w[1] == w[0] + 1), "{ids:?}");
                    let last = ids.last().copied().unwrap_or(0);
                    assert!(last >= seen, "went back: {last} < {seen}");
                    seen = last;
                    reads += 1;
                }
                reads
            })
        })
        .collect();
    // Two writers at once: the second waits for the first's transactions.
    let writers: Vec<_> = ["kitchen", "garage"]
        .into_iter()
        .map(|node| {
            let database = database.clone();
            std::thread::spawn(move || {
                let mut writer = database.writer().unwrap();
                for batch in 0..100 {
                    writer
                        .batch(|b| {
                            for i in 0..20 {
                                b.push("logs", node, batch * 20 + i, "{}")?;
                            }
                            Ok(())
                        })
                        .unwrap();
                }
            })
        })
        .collect();
    for writer in writers {
        writer.join().unwrap();
    }
    stop.store(true, Ordering::Relaxed);
    for reader in readers {
        assert!(reader.join().unwrap() > 0);
    }
    let reader = database.reader().unwrap();
    assert_eq!(reader.last_id("logs", "kitchen").unwrap(), 2000);
    assert_eq!(reader.last_id("logs", "garage").unwrap(), 2000);
}

/// The storage alone, flat out (`docs/storage.md`, "The benchmark"): pushes
/// over 100 topics x 5 nodes (an LCG picks them), 100 per batch, 200-byte
/// JSON; 2000 latest-message reads, 500 reads of 1000 messages after the
/// middle id, the file's size, retention of 10% of one topic. Not run by
/// default: `PUSHES=1000000 SYNC=normal cargo test --release -p
/// bakashrot-storage -- --ignored --nocapture`.
#[test]
#[ignore]
fn storage_rate() {
    use std::time::Instant;
    let count: u64 = std::env::var("PUSHES").map_or(1_000_000, |n| n.parse().unwrap());
    let sync = std::env::var("SYNC").unwrap_or_else(|_| "normal".into());
    let synchronous = if sync == "full" {
        Synchronous::Full
    } else {
        Synchronous::Normal
    };
    let path = path("rate");
    let database = Database::open(&path, synchronous).unwrap();
    let mut writer = database.writer().unwrap();

    let prefix = r#"{"kind":"temp","value":21.37,"ts":1700000000,"pad":""#;
    let json = format!("{prefix}{}\"}}", "x".repeat(200 - prefix.len() - 2));
    assert_eq!(json.len(), 200);
    let topics: Vec<String> = (0..100).map(|t| format!("topic{t}")).collect();
    let nodes: Vec<String> = (0..5).map(|n| format!("node{n}")).collect();

    // Checkpoints every second on their own connection, as the server's
    // thread does.
    let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let checkpoints = {
        let checkpointer = database.checkpointer().unwrap();
        let stop = stop.clone();
        std::thread::spawn(move || {
            while !stop.load(Ordering::Relaxed) {
                std::thread::sleep(std::time::Duration::from_secs(1));
                checkpointer.checkpoint().unwrap();
            }
        })
    };

    let mut state: u64 = 1;
    let start = Instant::now();
    for batch in 0..count / 100 {
        writer
            .batch(|b| {
                for i in 0..100 {
                    state = state
                        .wrapping_mul(6_364_136_223_846_793_005)
                        .wrapping_add(1_442_695_040_888_963_407);
                    let x = (state >> 33) & 0x7FFF_FFFF;
                    let at = 1_700_000_000_000 + (batch * 100 + i) * 10;
                    b.push(
                        &topics[(x % 100) as usize],
                        &nodes[(x / 100 % 5) as usize],
                        at,
                        &json,
                    )?;
                }
                Ok(())
            })
            .unwrap();
    }
    let pushing = start.elapsed().as_secs_f64();
    stop.store(true, Ordering::Relaxed);
    checkpoints.join().unwrap();

    let reader = database.reader().unwrap();
    let pick = |i: usize| (&topics[i * 37 % 100], &nodes[i * 3 % 5]);
    let middle: Vec<u64> = (0..500)
        .map(|i| reader.last_id(pick(i).0, pick(i).1).unwrap() / 2)
        .collect();
    let start = Instant::now();
    for i in 0..2000 {
        reader.messages(pick(i).0, pick(i).1, None, 1).unwrap();
    }
    let latest = start.elapsed().as_secs_f64() * 1000.0 / 2000.0;
    let start = Instant::now();
    let mut read = 0;
    for (i, after) in middle.iter().enumerate() {
        read += reader
            .messages(pick(i).0, pick(i).1, Some(*after), 1000)
            .unwrap()
            .messages
            .len();
    }
    let after = start.elapsed().as_secs_f64() * 1000.0 / 500.0;

    rusqlite::Connection::open(&path)
        .unwrap()
        .query_row("PRAGMA wal_checkpoint(TRUNCATE)", [], |_| Ok(()))
        .unwrap();
    let size = std::fs::metadata(&path).unwrap().len();

    let start = Instant::now();
    let cutoff = 1_700_000_000_000 + count / 10 * 10;
    let deleted = writer
        .batch(|b| b.delete_before("topic0", cutoff, 100_000_000))
        .unwrap();
    let retention = start.elapsed().as_secs_f64() * 1000.0;

    println!(
        "{sync}: {count} pushes in {pushing:.1} s = {:.0}/s | file {:.0} MB | latest {latest:.3} ms | 1000 after {after:.3} ms ({read} read) | retention {deleted} in {retention:.0} ms",
        count as f64 / pushing,
        size as f64 / 1e6
    );
}
