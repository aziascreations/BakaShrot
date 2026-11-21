//! Reading: messages, names, what replication compares, attachments.
//! Answers are the protocol's own types where it has them.

use crate::{
    AttachmentState, Error, Result, find_stream, message_id, message_key, part_key, stream_keys,
};
use bakashrot_proto::limits::{ATTACHMENT_PART_SIZE, MAX_MESSAGE_ID};
use bakashrot_proto::packets::{
    Attachment as Sent, Head, MessageEntry, Messages, MissingAttachment, Pair, ReplicatedMessage,
    StoredAttachment,
};
use rusqlite::{Connection, OptionalExtension, Row, params};

/// About how many bytes of messages one answer carries: past it, the rest
/// is left for the next request (`more`). A bigger message goes alone.
pub const MESSAGES_BYTES: usize = 1024 * 1024;

/// A stream's messages after a key, in order (`?1` that key, `?2` the
/// stream's last possible one), with their attachments.
const AFTER: &str = "SELECT d.key, d.pushed_at, d.message_data, a.size, a.state \
                     FROM data d LEFT JOIN attachments a ON a.message_key = d.key \
                     WHERE d.key > ?1 AND d.key <= ?2 ORDER BY d.key LIMIT ?3";

/// A stream's last messages, newest first (`?1`, `?2`: its key range).
const LATEST: &str = "SELECT d.key, d.pushed_at, d.message_data, a.size, a.state \
                      FROM data d LEFT JOIN attachments a ON a.message_key = d.key \
                      WHERE d.key >= ?1 AND d.key <= ?2 ORDER BY d.key DESC LIMIT ?3";

/// A stream's messages after a key, as replication sends them.
const TO_REPLICATE: &str = "SELECT d.key, d.pushed_at, d.message_data, a.size, a.sha256 \
                            FROM data d LEFT JOIN attachments a ON a.message_key = d.key \
                            WHERE d.key > ?1 AND d.key <= ?2 ORDER BY d.key LIMIT ?3";

/// A connection that reads.
#[derive(Debug)]
pub struct Reader {
    connection: Connection,
}

/// A message's attachment, as stored.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Attachment {
    /// Its id in this database, for [`Reader::read_part`] and the writer.
    pub id: i64,
    /// Its size.
    pub size: u64,
    /// Its SHA-256.
    pub sha256: [u8; 32],
    /// The bytes of it here so far.
    pub received: u64,
    /// Where it's at.
    pub state: AttachmentState,
}

impl Reader {
    pub(crate) fn new(connection: Connection) -> Reader {
        Reader { connection }
    }

    /// A topic and node's messages: `after` an id (0 for the first ones),
    /// in order, or the last ones (`None`); `limit` at most, about
    /// [`MESSAGES_BYTES`] at most. `more` if others follow (asking `after`
    /// the last one gets them). None for a topic and node without any,
    /// [`Error::UnknownName`] for a node without any in every topic.
    pub fn messages(
        &self,
        topic: &str,
        node: &str,
        after: Option<u64>,
        limit: u32,
    ) -> Result<Messages> {
        let mut answer = Messages {
            more: false,
            messages: Vec::new(),
        };
        let Some((stream, _)) = find_stream(&self.connection, topic, node)? else {
            return match self.has_node(node)? {
                true => Ok(answer),
                false => Err(Error::UnknownName(format!("unknown node '{node}'"))),
            };
        };
        let (first, last) = stream_keys(stream);
        let (sql, from) = match after {
            Some(after) => (AFTER, message_key(stream, after.min(MAX_MESSAGE_ID))),
            None => (LATEST, first),
        };
        let mut statement = self.connection.prepare_cached(sql)?;
        // One more than asked: whether more follow.
        let mut rows = statement.query((from, last, i64::from(limit) + 1))?;
        let mut bytes = 0;
        while let Some(row) = rows.next()? {
            let message = entry(row)?;
            let full = answer.messages.len() == limit as usize
                || (!answer.messages.is_empty() && bytes + message.data.len() > MESSAGES_BYTES);
            if full {
                answer.more = after.is_some();
                break;
            }
            bytes += message.data.len();
            answer.messages.push(message);
        }
        if after.is_none() {
            answer.messages.reverse();
        }
        Ok(answer)
    }

    /// A topic and node's messages after an id, as replication sends them:
    /// `limit` at most, about [`MESSAGES_BYTES`] at most (a bigger one
    /// alone). None once there are no more.
    pub fn to_replicate(
        &self,
        topic: &str,
        node: &str,
        after: u64,
        limit: u32,
    ) -> Result<Vec<ReplicatedMessage>> {
        let mut messages = Vec::new();
        let Some((stream, _)) = find_stream(&self.connection, topic, node)? else {
            return Ok(messages);
        };
        let (_, last) = stream_keys(stream);
        let mut statement = self.connection.prepare_cached(TO_REPLICATE)?;
        let from = message_key(stream, after.min(MAX_MESSAGE_ID));
        let mut rows = statement.query((from, last, i64::from(limit)))?;
        let mut bytes = 0;
        while let Some(row) = rows.next()? {
            let data: String = row.get(2)?;
            if !messages.is_empty() && bytes + data.len() > MESSAGES_BYTES {
                break;
            }
            bytes += data.len();
            let attachment = match row.get::<_, Option<u64>>(3)? {
                Some(size) => Some(Sent {
                    size,
                    sha256: row.get(4)?,
                }),
                None => None,
            };
            messages.push(ReplicatedMessage {
                id: message_id(row.get(0)?),
                pushed_at: row.get(1)?,
                data,
                attachment,
            });
        }
        Ok(messages)
    }

    /// Every topic with messages (or that had some), in order.
    pub fn topics(&self) -> Result<Vec<String>> {
        self.strings("SELECT DISTINCT topic FROM streams ORDER BY topic")
    }

    /// Whether `node` has messages in any topic (or had some).
    fn has_node(&self, node: &str) -> Result<bool> {
        self.connection
            .prepare_cached("SELECT EXISTS (SELECT 1 FROM streams WHERE node = ?1)")?
            .query_row([node], |row| row.get(0))
            .map_err(Error::from)
    }

    /// Every topic and node's last id, in the order of their names
    /// (without case).
    pub fn heads(&self) -> Result<Vec<Head>> {
        self.heads_after(None, usize::MAX)
    }

    /// Topics and nodes' last ids, what `SyncState` compares: `limit` at
    /// most, in the order of their names (without case), those after the
    /// pair `after` (from the first without).
    pub fn heads_after(&self, after: Option<&Pair>, limit: usize) -> Result<Vec<Head>> {
        // No name is empty: ("", "") comes before every pair.
        let (topic, node) = after.map_or(("", ""), |pair| (&pair.topic, &pair.node));
        let limit = i64::try_from(limit).unwrap_or(i64::MAX);
        self.connection
            .prepare_cached(
                "SELECT topic, node, last_id FROM streams WHERE (topic, node) > (?1, ?2) \
                 ORDER BY topic, node LIMIT ?3",
            )?
            .query_map(params![topic, node, limit], |row| {
                Ok(Head {
                    topic: row.get(0)?,
                    node: row.get(1)?,
                    last_id: row.get(2)?,
                })
            })?
            .collect::<rusqlite::Result<_>>()
            .map_err(Error::from)
    }

    /// A topic and node's last id: 0 if it has none.
    pub fn last_id(&self, topic: &str, node: &str) -> Result<u64> {
        Ok(find_stream(&self.connection, topic, node)?.map_or(0, |(_, last_id)| last_id))
    }

    /// The replicated attachments not all here yet, oldest first, `limit`
    /// at most: what `SyncState` asks for, and from which part.
    pub fn missing_attachments(&self, limit: usize) -> Result<Vec<MissingAttachment>> {
        self.connection
            .prepare_cached(
                "SELECT s.topic, s.node, d.message_id, a.received, a.size FROM attachments a \
                 JOIN data d ON d.key = a.message_key \
                 JOIN streams s ON s.stream_id = d.stream_id \
                 WHERE a.state = 'replicating' ORDER BY a.attachment_id LIMIT ?1",
            )?
            .query_map([limit as i64], |row| {
                let (received, size): (u64, u64) = (row.get(3)?, row.get(4)?);
                Ok(MissingAttachment {
                    topic: row.get(0)?,
                    node: row.get(1)?,
                    message_id: row.get(2)?,
                    // Whole but not checked: it starts over from the first.
                    next_part: if received == size {
                        0
                    } else {
                        received / ATTACHMENT_PART_SIZE
                    },
                })
            })?
            .collect::<rusqlite::Result<_>>()
            .map_err(Error::from)
    }

    /// A message's attachment, if it has one (none once the message was
    /// deleted).
    pub fn attachment(
        &self,
        topic: &str,
        node: &str,
        message_id: u64,
    ) -> Result<Option<Attachment>> {
        let Some((stream, _)) = find_stream(&self.connection, topic, node)? else {
            return Ok(None);
        };
        self.connection
            .prepare_cached(
                "SELECT attachment_id, size, sha256, received, state FROM attachments \
                 WHERE message_key = ?1 AND state <> 'deleting'",
            )?
            .query_row(
                [message_key(stream, message_id.min(MAX_MESSAGE_ID))],
                |row| {
                    Ok(Attachment {
                        id: row.get(0)?,
                        size: row.get(1)?,
                        sha256: row.get(2)?,
                        received: row.get(3)?,
                        state: row.get(4)?,
                    })
                },
            )
            .optional()
            .map_err(Error::from)
    }

    /// One part of an attachment, if it's here.
    pub fn read_part(&self, attachment_id: i64, part: u64) -> Result<Vec<u8>> {
        self.connection
            .prepare_cached("SELECT part_data FROM attachment_parts WHERE key = ?1")?
            .query_row([part_key(attachment_id, part)], |row| row.get(0))
            .optional()?
            .ok_or_else(|| Error::NotFound(format!("part {part} of attachment {attachment_id}")))
    }

    fn strings(&self, sql: &str) -> Result<Vec<String>> {
        self.connection
            .prepare_cached(sql)?
            .query_map([], |row| row.get(0))?
            .collect::<rusqlite::Result<_>>()
            .map_err(Error::from)
    }
}

/// A row of `messages()`'s query, as the protocol carries it.
fn entry(row: &Row<'_>) -> rusqlite::Result<MessageEntry> {
    let attachment = match row.get::<_, Option<u64>>(3)? {
        Some(size) => Some(StoredAttachment {
            size,
            ready: row.get::<_, AttachmentState>(4)? == AttachmentState::Ready,
        }),
        None => None,
    };
    Ok(MessageEntry {
        id: message_id(row.get(0)?),
        pushed_at: row.get(1)?,
        data: row.get(2)?,
        attachment,
    })
}
