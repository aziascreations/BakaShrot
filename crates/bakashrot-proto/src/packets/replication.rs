//! Replication, between servers: at each check-in a peer (P) asks the
//! server (S) what it takes and has, then sends what it's missing,
//! messages first, then attachments (`OldSource/Design/Packets.md`,
//! "Replication"). Servers only ever send each other names: each has its
//! own ids.

use super::rules;
use super::{Attachment, Check, DecodeError};
use crate::limits::{
    MAX_ATTACHMENT_PARTS, MAX_MESSAGE_ID, MAX_MESSAGES_PER_PACKET, MAX_MISSING_ATTACHMENTS,
    MAX_NAMES_LIST_ENTRIES,
};
use crate::names;
use serde::{Deserialize, Serialize};

/// What the server takes from this peer, how far it is, and the
/// attachments it lacks.
///
/// `[15, []]`
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct SyncStateRequest {}

impl Check for SyncStateRequest {}

/// How far the server is in a topic/node pair.
///
/// `[topic, node, last_id]`
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Head {
    /// The topic.
    pub topic: String,
    /// The node.
    pub node: String,
    /// The highest message id it has (deleted ones included).
    pub last_id: u64,
}

/// An attachment the server lacks, and where to go on from.
///
/// `[topic, node, message_id, next_part]`
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MissingAttachment {
    /// The topic.
    pub topic: String,
    /// The node.
    pub node: String,
    /// The message.
    pub message_id: u64,
    /// The next part it needs (it keeps what it got).
    pub next_part: u64,
}

/// What the server takes from this peer, how far it is, and the
/// attachments it lacks: all a check-in needs.
///
/// `[16, [[topic...], [node...], [head...], [missing...]]]`
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SyncState {
    /// The topics it takes from this peer: names, and wildcards (it takes
    /// the names they match, even those it doesn't have yet).
    pub topics: Vec<String>,
    /// The nodes it takes from this peer, the same way.
    pub nodes: Vec<String>,
    /// Its highest message id in each topic/node pair of those.
    pub heads: Vec<Head>,
    /// The attachments it lacks among those, `MAX_MISSING_ATTACHMENTS` at
    /// most.
    pub missing: Vec<MissingAttachment>,
}

impl Check for SyncState {
    fn check(&self) -> Result<(), DecodeError> {
        for (list, field) in [
            (&self.topics, "SyncState.topics"),
            (&self.nodes, "SyncState.nodes"),
        ] {
            rules::most(list.len(), MAX_NAMES_LIST_ENTRIES, field)?;
            for item in list {
                rules::require(
                    names::is_valid_name_or_pattern(item),
                    field,
                    "must be a name or a pattern",
                )?;
            }
        }
        for head in &self.heads {
            rules::name(&head.topic, "SyncState.heads.topic")?;
            rules::name(&head.node, "SyncState.heads.node")?;
            rules::range(head.last_id, 0, MAX_MESSAGE_ID, "SyncState.heads.last_id")?;
        }
        rules::most(
            self.missing.len(),
            MAX_MISSING_ATTACHMENTS,
            "SyncState.missing",
        )?;
        for missing in &self.missing {
            rules::name(&missing.topic, "SyncState.missing.topic")?;
            rules::name(&missing.node, "SyncState.missing.node")?;
            rules::message_id(missing.message_id, "SyncState.missing.message_id")?;
            rules::range(
                missing.next_part,
                0,
                MAX_ATTACHMENT_PARTS - 1,
                "SyncState.missing.next_part",
            )?;
        }
        Ok(())
    }
}

/// A message as replication carries it.
///
/// `[id, pushed_at, data, attachment]`
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReplicatedMessage {
    /// Its id, as on its origin.
    pub id: u64,
    /// When it was pushed to its origin.
    pub pushed_at: u64,
    /// The message.
    pub data: String,
    /// Its attachment's size and SHA-256, if it has one: its parts come
    /// later, by `ReplicateAttachment`.
    pub attachment: Option<Attachment>,
}

/// Messages of a topic/node pair the server is missing, in id order.
///
/// `[17, [topic, node, [message...]]]`
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReplicateMessages {
    /// The topic.
    pub topic: String,
    /// The node.
    pub node: String,
    /// The messages, 1 to `MAX_MESSAGES_PER_PACKET`, ids strictly
    /// increasing.
    pub messages: Vec<ReplicatedMessage>,
}

impl Check for ReplicateMessages {
    fn check(&self) -> Result<(), DecodeError> {
        rules::name(&self.topic, "ReplicateMessages.topic")?;
        rules::name(&self.node, "ReplicateMessages.node")?;
        rules::require(
            !self.messages.is_empty(),
            "ReplicateMessages.messages",
            "one at least",
        )?;
        rules::most(
            self.messages.len(),
            MAX_MESSAGES_PER_PACKET as usize,
            "ReplicateMessages.messages",
        )?;
        rules::increasing(
            self.messages.iter().map(|m| m.id),
            "ReplicateMessages.messages",
        )?;
        for message in &self.messages {
            rules::message_id(message.id, "ReplicateMessages.id")?;
            rules::timestamp(message.pushed_at, "ReplicateMessages.pushed_at")?;
            if let Some(attachment) = &message.attachment {
                attachment.check()?;
            }
        }
        Ok(())
    }
}

/// An attachment the server is missing: the server answers `Continue` (or
/// refuses), the peer sends its parts from `from_part` to the last, the
/// server checks it all and answers `MessagePushed` with the message's id.
///
/// `[18, [topic, node, message_id, from_part]]`
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReplicateAttachment {
    /// The topic.
    pub topic: String,
    /// The node.
    pub node: String,
    /// The message.
    pub message_id: u64,
    /// The first part sent: the `next_part` the server listed.
    pub from_part: u64,
}

impl Check for ReplicateAttachment {
    fn check(&self) -> Result<(), DecodeError> {
        rules::name(&self.topic, "ReplicateAttachment.topic")?;
        rules::name(&self.node, "ReplicateAttachment.node")?;
        rules::message_id(self.message_id, "ReplicateAttachment.message_id")?;
        rules::range(
            self.from_part,
            0,
            MAX_ATTACHMENT_PARTS - 1,
            "ReplicateAttachment.from_part",
        )
    }
}
