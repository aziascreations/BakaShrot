//! Attachments: one per message at most, in parts of `ATTACHMENT_PART_SIZE`
//! (the last one what's left), checked with their SHA-256 once all came.
//!
//! Parts are streamed, without a request or an answer each:
//! - **Pushing:** `PushMessage` with its `Attachment`, the server's
//!   `Continue`, every part, then `MessagePushed` (or `RequestRefused`,
//!   `DataMismatch` if the SHA-256 doesn't match). Once it said `Continue`,
//!   the server reads every part even if storing them failed, then refuses.
//! - **Reading:** `GetAttachment`, the server's `Attachment`, then the
//!   parts from the one asked to the last. A server that fails while
//!   sending them closes the connection.
//! - **Replicating:** `ReplicateAttachment`, the server's `Continue`, the
//!   parts from the one it lacks, then `MessagePushed`.
//!
//! A part is its data alone: its index follows from the order, its size
//! from the attachment's ([`Attachment::part_len`]), which the receiver
//! checks.

use super::rules;
use super::{Check, DecodeError};
use crate::limits::{
    ATTACHMENT_PART_SIZE, MAX_ATTACHMENT_PARTS, MAX_ATTACHMENT_SIZE, attachment_part_count,
    attachment_part_len,
};
use serde::{Deserialize, Serialize};

/// An attachment's size and checksum: in a `PushMessage` or a replicated
/// message, and on its own before the parts of a `GetAttachment`.
///
/// `[9, [size, sha256]]`
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Attachment {
    /// Its size, 1 to `MAX_ATTACHMENT_SIZE` (servers may take less).
    pub size: u64,
    /// Its SHA-256.
    #[serde(with = "serde_bytes")]
    pub sha256: [u8; 32],
}

impl Attachment {
    /// How many parts it takes.
    pub const fn part_count(&self) -> u64 {
        attachment_part_count(self.size)
    }

    /// The size its part `index` must have, 0 if it has no such part.
    pub const fn part_len(&self, index: u64) -> u64 {
        attachment_part_len(self.size, index)
    }
}

impl Check for Attachment {
    fn check(&self) -> Result<(), DecodeError> {
        rules::range(self.size, 1, MAX_ATTACHMENT_SIZE, "Attachment.size")
    }
}

/// A part of an attachment, the next one.
///
/// `[10, [data]]`
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AttachmentPart {
    /// The part, 1 to `ATTACHMENT_PART_SIZE` bytes (its exact size is the
    /// receiver's to check).
    #[serde(with = "serde_bytes")]
    pub data: Vec<u8>,
}

impl Check for AttachmentPart {
    fn check(&self) -> Result<(), DecodeError> {
        rules::range(
            self.data.len() as u64,
            1,
            ATTACHMENT_PART_SIZE,
            "AttachmentPart.data",
        )
    }
}

/// A message's attachment, from a part on (0 for all of it).
///
/// `[8, [topic, node, message_id, from_part]]`
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GetAttachment {
    /// The topic.
    pub topic: String,
    /// The node.
    pub node: String,
    /// The message.
    pub message_id: u64,
    /// The first part to send: a client going on from where a lost
    /// connection stopped.
    pub from_part: u64,
}

impl Check for GetAttachment {
    fn check(&self) -> Result<(), DecodeError> {
        rules::name(&self.topic, "GetAttachment.topic")?;
        rules::name(&self.node, "GetAttachment.node")?;
        rules::message_id(self.message_id, "GetAttachment.message_id")?;
        rules::range(
            self.from_part,
            0,
            MAX_ATTACHMENT_PARTS - 1,
            "GetAttachment.from_part",
        )
    }
}
