//! Clients' requests and their answers: pushing and reading messages,
//! names, queries.

use super::rules;
use super::{Attachment, Check, DecodeError};
use crate::limits::{
    MAX_ATTACHMENT_SIZE, MAX_MESSAGE_ID, MAX_MESSAGES_PER_PACKET, MAX_NAMES_LIST_ENTRIES,
};
use serde::{Deserialize, Serialize};

/// A message's attachment, as reads show it.
///
/// `[size, ready]`
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StoredAttachment {
    /// Its size, 1 and up.
    pub size: u64,
    /// Whether all of it is on this server (it may still be on its way from
    /// a peer).
    pub ready: bool,
}

/// A stored message, as `Messages` carries it.
///
/// `[id, pushed_at, data, attachment]`
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MessageEntry {
    /// Its id, in its topic/node pair (1 and up).
    pub id: u64,
    /// When it was pushed: milliseconds since 1970 UTC, by the server it was
    /// pushed to, kept as is by replication.
    pub pushed_at: u64,
    /// The message, as pushed (JSON or not).
    pub data: String,
    /// Its attachment, if it has one.
    pub attachment: Option<StoredAttachment>,
}

impl Check for MessageEntry {
    fn check(&self) -> Result<(), DecodeError> {
        rules::message_id(self.id, "message.id")?;
        rules::timestamp(self.pushed_at, "message.pushed_at")?;
        if let Some(attachment) = &self.attachment {
            rules::range(
                attachment.size,
                1,
                MAX_ATTACHMENT_SIZE,
                "message.attachment.size",
            )?;
        }
        Ok(())
    }
}

/// Stores a message under the client's node. With an attachment, the
/// server answers `Continue` (or refuses), the client sends all its parts,
/// then the server stores both and answers `MessagePushed`.
///
/// `[4, [topic, data, attachment]]`
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PushMessage {
    /// The topic: a push always names it.
    pub topic: String,
    /// The message (JSON or not), up to `MAX_MESSAGE_SIZE` bytes (the
    /// server refuses bigger ones).
    pub data: String,
    /// Its attachment, whose parts follow the server's `Continue`.
    pub attachment: Option<Attachment>,
}

impl Check for PushMessage {
    fn check(&self) -> Result<(), DecodeError> {
        rules::name(&self.topic, "PushMessage.topic")?;
        if let Some(attachment) = &self.attachment {
            attachment.check()?;
        }
        Ok(())
    }
}

/// The id a message was stored with (the last of a replicated batch).
///
/// `[5, [message_id]]`
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MessagePushed {
    /// The id.
    pub message_id: u64,
}

impl Check for MessagePushed {
    fn check(&self) -> Result<(), DecodeError> {
        rules::message_id(self.message_id, "MessagePushed.message_id")
    }
}

/// A topic/node's messages, in id order: those after an id, or its last
/// ones.
///
/// `[6, [topic, node, after, limit]]`
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GetMessages {
    /// The topic.
    pub topic: String,
    /// The node.
    pub node: String,
    /// Those with a higher id than this (0 for all), or nil for the last
    /// `limit` ones (the latest message: nil and 1).
    pub after: Option<u64>,
    /// At most this many, 1 to `MAX_MESSAGES_PER_PACKET`.
    pub limit: u32,
}

impl Check for GetMessages {
    fn check(&self) -> Result<(), DecodeError> {
        rules::name(&self.topic, "GetMessages.topic")?;
        rules::name(&self.node, "GetMessages.node")?;
        if let Some(after) = self.after {
            rules::range(after, 0, MAX_MESSAGE_ID, "GetMessages.after")?;
        }
        rules::range(
            self.limit.into(),
            1,
            MAX_MESSAGES_PER_PACKET.into(),
            "GetMessages.limit",
        )
    }
}

/// A run of a topic/node's messages, in id order. None isn't a refusal.
///
/// `[7, [more, [message...]]]`
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Messages {
    /// Whether more follow the last one: ask again after its id.
    pub more: bool,
    /// The messages, ids strictly increasing, `MAX_MESSAGES_PER_PACKET` at
    /// most; fewer than asked once they reach about a megabyte (the
    /// server's choice), a bigger message alone.
    pub messages: Vec<MessageEntry>,
}

impl Check for Messages {
    fn check(&self) -> Result<(), DecodeError> {
        rules::most(
            self.messages.len(),
            MAX_MESSAGES_PER_PACKET as usize,
            "Messages.messages",
        )?;
        rules::increasing(self.messages.iter().map(|m| m.id), "Messages.messages")?;
        self.messages.iter().try_for_each(Check::check)
    }
}

/// Raw read-only SQL.
///
/// `[13, [sql]]`
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Query {
    /// The query: one statement, starting with SELECT or WITH.
    pub sql: String,
}

impl Check for Query {}

/// A query's result.
///
/// `[14, [json]]`
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct QueryResult {
    /// `{"columns":[...],"rows":[[...],...]}`.
    pub json: String,
}

impl Check for QueryResult {}

/// Topics or nodes: 1 or 2 on the wire.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(into = "u8", try_from = "u8")]
pub enum NameKind {
    /// Topics.
    Topic = 1,
    /// Nodes.
    Node = 2,
}

impl From<NameKind> for u8 {
    fn from(kind: NameKind) -> u8 {
        kind as u8
    }
}

impl TryFrom<u8> for NameKind {
    type Error = &'static str;

    fn try_from(value: u8) -> Result<NameKind, Self::Error> {
        match value {
            1 => Ok(NameKind::Topic),
            2 => Ok(NameKind::Node),
            _ => Err("a name kind is 1 (topics) or 2 (nodes)"),
        }
    }
}

/// The topics or nodes the client may see, of the topic and node pairs
/// with messages that the filters match: the topics a node pushed to, the
/// nodes that pushed to a topic.
///
/// `[11, [kind, topics, nodes]]`
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ListNames {
    /// Topics or nodes.
    pub kind: NameKind,
    /// Only the pairs whose topic is this name or matches this pattern;
    /// nil for any.
    pub topics: Option<String>,
    /// Only the pairs whose node is this name or matches this pattern;
    /// nil for any.
    pub nodes: Option<String>,
}

impl Check for ListNames {
    fn check(&self) -> Result<(), DecodeError> {
        for (filter, field) in [
            (&self.topics, "ListNames.topics"),
            (&self.nodes, "ListNames.nodes"),
        ] {
            if let Some(filter) = filter {
                rules::name_or_pattern(filter, field)?;
            }
        }
        Ok(())
    }
}

/// Topics or nodes.
///
/// `[12, [kind, truncated, [name...]]]`
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NamesList {
    /// Topics or nodes.
    pub kind: NameKind,
    /// Whether some didn't fit.
    pub truncated: bool,
    /// The names, `MAX_NAMES_LIST_ENTRIES` at most.
    pub names: Vec<String>,
}

impl Check for NamesList {
    fn check(&self) -> Result<(), DecodeError> {
        rules::most(self.names.len(), MAX_NAMES_LIST_ENTRIES, "NamesList.names")?;
        self.names
            .iter()
            .try_for_each(|name| rules::name(name, "NamesList.names"))
    }
}
