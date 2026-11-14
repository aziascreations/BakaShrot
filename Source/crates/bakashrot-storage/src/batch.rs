//! Writing: the writer's connection, and what a batch (one transaction)
//! does.

use crate::{
    AttachmentState, Error, MAX_STREAMS, Result, find_stream, message_key, part_key, part_keys,
    stream_keys,
};
use bakashrot_proto::limits::{
    ATTACHMENT_PART_SIZE, MAX_ATTACHMENT_SIZE, MAX_MESSAGE_ID, attachment_part_len,
};
use bakashrot_proto::packets::ReplicatedMessage;
use rusqlite::{Connection, OptionalExtension, Transaction, TransactionBehavior};

/// The connection that writes (one per database).
#[derive(Debug)]
pub struct Writer {
    connection: Connection,
}

impl Writer {
    pub(crate) fn new(connection: Connection) -> Writer {
        Writer { connection }
    }

    /// Runs `write` in one transaction, committed if it returns `Ok`,
    /// rolled back otherwise. Each operation of a [`Batch`] is all or
    /// nothing on its own, so `write` may go on after one fails: many
    /// pushes in one batch are a group commit, one disk flush for all.
    pub fn batch<T>(&mut self, write: impl FnOnce(&mut Batch<'_>) -> Result<T>) -> Result<T> {
        let mut batch = Batch {
            transaction: self
                .connection
                .transaction_with_behavior(TransactionBehavior::Immediate)?,
        };
        let value = write(&mut batch)?;
        batch.transaction.commit()?;
        Ok(value)
    }

    /// Gives the space of deleted messages back to the disk: rewrites the
    /// database (`VACUUM`), then empties the WAL. SQLite reuses that space
    /// by itself; this only shrinks the file. Slow on a big database, and
    /// every other write waits meanwhile: the old server's `vacuum`
    /// command.
    pub fn vacuum(&mut self) -> Result<()> {
        self.connection.execute_batch("VACUUM")?;
        self.connection
            .query_row("PRAGMA wal_checkpoint(TRUNCATE)", [], |_| Ok(()))?;
        Ok(())
    }
}

/// What's written in one transaction ([`Writer::batch`]). Names come
/// checked (`bakashrot_proto`'s decoding). Attachment ids are this
/// database's own, from [`Batch::start_upload`] or
/// [`Reader::attachment`](crate::Reader::attachment).
#[derive(Debug)]
pub struct Batch<'c> {
    transaction: Transaction<'c>,
}

impl Batch<'_> {
    /// Stores a pushed message: the next id of its topic and node (from 1),
    /// which it returns. Without a savepoint, the hot path: a push that
    /// fails leaves at most its topic and node's (empty) stream.
    pub fn push(&mut self, topic: &str, node: &str, pushed_at: u64, data: &str) -> Result<u64> {
        Ok(insert_pushed(&self.transaction, topic, node, pushed_at, data)?.0)
    }

    /// Stores a pushed message with its attachment, an upload all of whose
    /// parts came ([`Batch::write_part`] said so) and whose SHA-256 the
    /// caller checked: the attachment is then `ready`.
    pub fn push_with_attachment(
        &mut self,
        upload: i64,
        topic: &str,
        node: &str,
        pushed_at: u64,
        data: &str,
    ) -> Result<u64> {
        self.atomic(|db| {
            let (state, size, received) = attachment(db, upload)?;
            if state != AttachmentState::Uploading || received != size {
                return Err(Error::Invalid(format!(
                    "attachment {upload} isn't a complete upload"
                )));
            }
            let (id, key) = insert_pushed(db, topic, node, pushed_at, data)?;
            set_attachment(db, upload, "message_key = ?2, state = 'ready'", key)?;
            Ok(id)
        })
    }

    /// Starts an upload: an attachment pushed with its message, whose parts
    /// come next. Returns its id.
    pub fn start_upload(&mut self, size: u64, sha256: &[u8; 32]) -> Result<i64> {
        if !(1..=MAX_ATTACHMENT_SIZE).contains(&size) {
            return Err(Error::TooBig(format!(
                "an attachment of {size} bytes: 1 to {MAX_ATTACHMENT_SIZE}"
            )));
        }
        self.atomic(|db| {
            db.execute(
                "INSERT INTO attachments (size, sha256, state) VALUES (?1, ?2, 'uploading')",
                (size, sha256),
            )?;
            Ok(db.last_insert_rowid())
        })
    }

    /// Stores the next part of an upload or of a replicated attachment: in
    /// order, each of its exact size (`attachment_part_len`). Returns
    /// whether that was the last one.
    pub fn write_part(&mut self, attachment_id: i64, part: u64, data: &[u8]) -> Result<bool> {
        self.atomic(|db| {
            let (state, size, received) = attachment(db, attachment_id)?;
            if state != AttachmentState::Uploading && state != AttachmentState::Replicating {
                return Err(Error::Invalid(format!(
                    "attachment {attachment_id} is {state}, it takes no parts"
                )));
            }
            // Every part but the last is whole: what came is whole parts.
            let next = received / ATTACHMENT_PART_SIZE;
            if received == size || part != next {
                return Err(Error::Invalid(format!(
                    "part {part} of attachment {attachment_id}: part {next} is next"
                )));
            }
            let expected = attachment_part_len(size, part);
            if data.len() as u64 != expected {
                return Err(Error::Invalid(format!(
                    "part {part} of attachment {attachment_id}: {} bytes, {expected} expected",
                    data.len()
                )));
            }
            db.prepare_cached("INSERT INTO attachment_parts (key, part_data) VALUES (?1, ?2)")?
                .execute((part_key(attachment_id, part), data))?;
            set_attachment(db, attachment_id, "received = received + ?2", expected)?;
            Ok(received + expected == size)
        })
    }

    /// Drops an upload that won't be pushed: cut short, or not matching its
    /// SHA-256.
    pub fn cancel_upload(&mut self, upload: i64) -> Result<()> {
        self.atomic(|db| {
            if attachment(db, upload)?.0 != AttachmentState::Uploading {
                return Err(Error::Invalid(format!(
                    "attachment {upload} isn't an upload"
                )));
            }
            delete_attachment(db, upload)
        })
    }

    /// Stores messages a peer sent for `topic` and `node`, with their own
    /// ids, in order; ones already here are kept as they are. Their
    /// attachments are noted, to be asked for (`replicating`), or never if
    /// bigger than `max_attachment_size` (`too_big`). Returns the topic and
    /// node's last id.
    pub fn replicate(
        &mut self,
        topic: &str,
        node: &str,
        messages: &[ReplicatedMessage],
        max_attachment_size: u64,
    ) -> Result<u64> {
        self.atomic(|db| {
            let (stream, mut last_id) = stream(db, topic, node)?;
            let mut insert = db.prepare_cached(
                "INSERT OR IGNORE INTO data (key, pushed_at, message_data) VALUES (?1, ?2, ?3)",
            )?;
            let mut attach = db.prepare_cached(
                "INSERT INTO attachments (message_key, size, sha256, state) VALUES (?1, ?2, ?3, ?4)",
            )?;
            for message in messages {
                if !(1..=MAX_MESSAGE_ID).contains(&message.id) {
                    return Err(Error::Invalid(format!("message id {}", message.id)));
                }
                let key = message_key(stream, message.id);
                let stored = insert.execute((key, message.pushed_at, &message.data))? == 1;
                if let (true, Some(attachment)) = (stored, &message.attachment) {
                    let state = if attachment.size > max_attachment_size {
                        AttachmentState::TooBig
                    } else {
                        AttachmentState::Replicating
                    };
                    attach.execute((key, attachment.size, &attachment.sha256, state))?;
                }
                // What the trigger keeps: one ignored was here, below it.
                last_id = last_id.max(message.id);
            }
            Ok(last_id)
        })
    }

    /// A replicated attachment all of whose parts came: `matches` its
    /// SHA-256 (the caller checked), it's `ready`; otherwise its parts are
    /// dropped and it's asked for again from the start.
    pub fn finish_replicated(&mut self, attachment_id: i64, matches: bool) -> Result<()> {
        self.atomic(|db| {
            let (state, size, received) = attachment(db, attachment_id)?;
            if state != AttachmentState::Replicating || received != size {
                return Err(Error::Invalid(format!(
                    "attachment {attachment_id} isn't a complete replicated one"
                )));
            }
            if matches {
                set_attachment(db, attachment_id, "state = ?2", AttachmentState::Ready)
            } else {
                delete_parts(db, attachment_id, None)?;
                set_attachment(db, attachment_id, "received = ?2", 0)
            }
        })
    }

    /// Retention: deletes `topic`'s messages pushed before `cutoff` (ms),
    /// `limit` at most (call again while it returns `limit`). Each stream
    /// is read from its oldest message and stops at the first one it keeps:
    /// only what's deleted is read. So messages go in id order: one stamped
    /// earlier than the one before it (a clock set back) waits for it.
    pub fn delete_before(&mut self, topic: &str, cutoff: u64, limit: usize) -> Result<usize> {
        self.atomic(|db| {
            let streams: Vec<i64> = db
                .prepare_cached("SELECT stream_id FROM streams WHERE topic = ?1")?
                .query_map([topic], |row| row.get(0))?
                .collect::<rusqlite::Result<_>>()?;
            let mut oldest = db.prepare_cached(
                "SELECT key, pushed_at FROM data WHERE key BETWEEN ?1 AND ?2 ORDER BY key",
            )?;
            let mut deleted = 0;
            for stream in streams {
                let (first, last) = stream_keys(stream);
                let mut up_to = None;
                let mut rows = oldest.query((first, last))?;
                while deleted < limit {
                    let Some(row) = rows.next()? else { break };
                    if row.get::<_, u64>(1)? >= cutoff {
                        break;
                    }
                    up_to = Some(row.get::<_, i64>(0)?);
                    deleted += 1;
                }
                drop(rows);
                if let Some(up_to) = up_to {
                    db.execute(
                        "DELETE FROM data WHERE key BETWEEN ?1 AND ?2",
                        (first, up_to),
                    )?;
                }
                if deleted == limit {
                    break;
                }
            }
            Ok(deleted)
        })
    }

    /// Deletes the parts of attachments whose message was deleted,
    /// `max_parts` at most (call again while it returns `max_parts`), and
    /// their rows once they have none left.
    pub fn purge_attachments(&mut self, max_parts: usize) -> Result<usize> {
        self.atomic(|db| {
            let deleting: Vec<i64> = db
                .prepare_cached(
                    "SELECT attachment_id FROM attachments WHERE state = 'deleting' \
                     ORDER BY attachment_id",
                )?
                .query_map([], |row| row.get(0))?
                .collect::<rusqlite::Result<_>>()?;
            let mut purged = 0;
            for attachment_id in deleting {
                purged += delete_parts(db, attachment_id, Some(max_parts - purged))?;
                if purged == max_parts {
                    break;
                }
                db.execute(
                    "DELETE FROM attachments WHERE attachment_id = ?1",
                    [attachment_id],
                )?;
            }
            Ok(purged)
        })
    }

    /// Runs one operation all or nothing (a savepoint), so the batch can go
    /// on after it fails.
    fn atomic<T>(&mut self, operation: impl FnOnce(&Connection) -> Result<T>) -> Result<T> {
        let savepoint = self.transaction.savepoint()?;
        let value = operation(&savepoint)?;
        savepoint.commit()?;
        Ok(value)
    }
}

/// A topic and node's stream, made if new: its id and last id.
fn stream(db: &Connection, topic: &str, node: &str) -> Result<(i64, u64)> {
    if let Some(found) = find_stream(db, topic, node)? {
        return Ok(found);
    }
    let next: i64 = db.query_row(
        "SELECT coalesce(max(stream_id), 0) + 1 FROM streams",
        [],
        |row| row.get(0),
    )?;
    if next > MAX_STREAMS {
        return Err(Error::TooBig(format!(
            "{topic}/{node}: this database has {MAX_STREAMS} topic and node pairs already"
        )));
    }
    db.execute(
        "INSERT INTO streams (stream_id, topic, node) VALUES (?1, ?2, ?3)",
        (next, topic, node),
    )?;
    Ok((next, 0))
}

/// Inserts a pushed message with the next id of its stream: the id and the
/// message's key.
fn insert_pushed(
    db: &Connection,
    topic: &str,
    node: &str,
    pushed_at: u64,
    data: &str,
) -> Result<(u64, i64)> {
    let (stream, last_id) = stream(db, topic, node)?;
    let id = last_id + 1;
    if id > MAX_MESSAGE_ID {
        return Err(Error::TooBig(format!("{topic}/{node}: no message id left")));
    }
    let key = message_key(stream, id);
    db.prepare_cached("INSERT INTO data (key, pushed_at, message_data) VALUES (?1, ?2, ?3)")?
        .execute((key, pushed_at, data))?;
    Ok((id, key))
}

/// An attachment's state, size and bytes received.
fn attachment(db: &Connection, attachment_id: i64) -> Result<(AttachmentState, u64, u64)> {
    db.prepare_cached("SELECT state, size, received FROM attachments WHERE attachment_id = ?1")?
        .query_row([attachment_id], |row| {
            Ok((row.get(0)?, row.get(1)?, row.get(2)?))
        })
        .optional()?
        .ok_or_else(|| Error::NotFound(format!("no attachment {attachment_id}")))
}

/// `UPDATE attachments SET <set>` of one, `?2` being `value`.
fn set_attachment(
    db: &Connection,
    attachment_id: i64,
    set: &str,
    value: impl rusqlite::ToSql,
) -> Result<()> {
    db.prepare_cached(&format!(
        "UPDATE attachments SET {set} WHERE attachment_id = ?1"
    ))?
    .execute((attachment_id, value))?;
    Ok(())
}

/// Deletes an attachment's parts, `limit` at most: how many.
fn delete_parts(db: &Connection, attachment_id: i64, limit: Option<usize>) -> Result<usize> {
    let (first, last) = part_keys(attachment_id);
    let limit = limit.map_or(-1, |limit| limit as i64);
    Ok(db
        .prepare_cached(
            "DELETE FROM attachment_parts WHERE key IN \
             (SELECT key FROM attachment_parts WHERE key BETWEEN ?1 AND ?2 LIMIT ?3)",
        )?
        .execute((first, last, limit))?)
}

/// Deletes an attachment and its parts.
fn delete_attachment(db: &Connection, attachment_id: i64) -> Result<()> {
    delete_parts(db, attachment_id, None)?;
    db.execute(
        "DELETE FROM attachments WHERE attachment_id = ?1",
        [attachment_id],
    )?;
    Ok(())
}

/// Deletes every upload: at start, none of them can be pushed any more.
pub(crate) fn delete_uploads(db: &Connection) -> Result<()> {
    let uploads: Vec<i64> = db
        .prepare("SELECT attachment_id FROM attachments WHERE state = 'uploading'")?
        .query_map([], |row| row.get(0))?
        .collect::<rusqlite::Result<_>>()?;
    for upload in uploads {
        delete_attachment(db, upload)?;
    }
    Ok(())
}
