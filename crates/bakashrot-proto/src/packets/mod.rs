//! Every packet of protocol 7.
//!
//! A packet is a MessagePack array of two: its type, then its fields as an
//! array, `[type, [field, field, ...]]`. Structs inside are arrays of their
//! fields too, `Option`s nil or their value, bytes binaries. All of it is
//! derived with `serde` (`rmp-serde`'s compact form): the structs below
//! are the format, `docs/protocol.md` lists them.
//!
//! [`Packet::decode`] checks everything: the types and the number of
//! fields (`serde`), then each packet's rules ([`Check`]: ranges, names,
//! ids in order), and that nothing follows. (A struct given as a map of its
//! field names is taken too, `serde`'s derive: nothing writes that form, it
//! isn't part of the format, its values are checked all the same.) Whatever isn't right is a
//! [`DecodeError`]: the connection is aborted. What's well-formed but not
//! allowed or not found (a topic this server doesn't have) is the server's
//! to refuse, with a `RequestRefused`.
//!
//! Topics and nodes are names everywhere, never ids.
//!
//! Adding a packet: a struct deriving `Serialize` and `Deserialize`, with
//! its [`Check`], in the file of its family; a line in the `packets!` table
//! below with the next id (never reuse one); a sample in `tests/packets.rs`;
//! its row in `docs/protocol.md`.

mod attachments;
mod messages;
mod replication;
mod session;

pub use attachments::{Attachment, AttachmentPart, GetAttachment};
pub use messages::{
    GetMessages, ListNames, MessageEntry, MessagePushed, Messages, NameKind, NamesList,
    PushMessage, Query, QueryResult, StoredAttachment,
};
pub use replication::{
    Head, MissingAttachment, ReplicateAttachment, ReplicateMessages, ReplicatedMessage, SyncState,
    SyncStateRequest,
};
pub use session::{Continue, RequestRefused, Welcome};

use serde::de::{self, DeserializeOwned, IgnoredAny, SeqAccess, Visitor};
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use std::fmt;
use std::io::Cursor;

/// Why a packet couldn't be read. Any of these aborts the connection.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DecodeError {
    /// Not a packet: not MessagePack, a value of the wrong type, a field
    /// missing or one too many, a type this version doesn't know.
    Malformed(String),
    /// Bytes after the packet.
    TrailingBytes,
    /// A field breaking a rule of its packet.
    Invalid {
        /// The field.
        field: &'static str,
        /// The rule it breaks.
        rule: &'static str,
    },
}

impl fmt::Display for DecodeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            DecodeError::Malformed(why) => write!(f, "malformed packet: {why}"),
            DecodeError::TrailingBytes => f.write_str("bytes after the end of the packet"),
            DecodeError::Invalid { field, rule } => write!(f, "{field}: {rule}"),
        }
    }
}

impl std::error::Error for DecodeError {}

/// The rules a packet's fields follow beyond their types, checked by
/// [`Packet::decode`]. None by default.
pub trait Check {
    /// Fails on the first rule broken.
    fn check(&self) -> Result<(), DecodeError> {
        Ok(())
    }
}

/// What every packet's struct is, implemented by the `packets!` table.
pub trait Body: Serialize + DeserializeOwned + Check + Into<Packet> {
    /// Its type, the packet's first value.
    const TYPE: PacketType;

    /// The whole packet: `[type, [fields...]]`.
    fn encode(&self) -> Vec<u8> {
        rmp_serde::to_vec(&(Self::TYPE.id(), self)).expect("packets always serialize")
    }
}

// The one table of packets: their names (the struct's and the variant's)
// and ids. Protocol 7's own: protocol 6's ids don't apply (the versions are
// checked before any packet).
macro_rules! packets {
    ($( $(#[$doc:meta])* $name:ident = $id:literal, )*) => {
        /// The type of a packet: its first value.
        #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
        #[repr(u8)]
        pub enum PacketType {
            $( $(#[$doc])* $name = $id, )*
        }

        impl PacketType {
            /// Every type.
            pub const ALL: &'static [PacketType] = &[$(PacketType::$name),*];

            /// The type with this id, if there's one.
            pub const fn from_id(id: u64) -> Option<PacketType> {
                match id {
                    $( $id => Some(PacketType::$name), )*
                    _ => None,
                }
            }

            /// Its id.
            pub const fn id(self) -> u8 {
                self as u8
            }

            /// Its name: "PushMessage".
            pub const fn name(self) -> &'static str {
                match self {
                    $( PacketType::$name => stringify!($name), )*
                }
            }
        }

        /// Any packet.
        #[derive(Debug, Clone, PartialEq, Eq)]
        pub enum Packet {
            $( $(#[$doc])* $name($name), )*
        }

        $(
            impl Body for $name {
                const TYPE: PacketType = PacketType::$name;
            }

            impl From<$name> for Packet {
                fn from(body: $name) -> Packet {
                    Packet::$name(body)
                }
            }
        )*

        impl Packet {
            /// Its type.
            pub const fn packet_type(&self) -> PacketType {
                match self {
                    $( Packet::$name(_) => PacketType::$name, )*
                }
            }

            fn check(&self) -> Result<(), DecodeError> {
                match self {
                    $( Packet::$name(body) => body.check(), )*
                }
            }
        }

        impl Serialize for Packet {
            fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
                match self {
                    $( Packet::$name(body) => (PacketType::$name.id(), body).serialize(serializer), )*
                }
            }
        }

        impl<'de> Deserialize<'de> for Packet {
            fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Packet, D::Error> {
                struct PacketVisitor;

                impl<'de> Visitor<'de> for PacketVisitor {
                    type Value = Packet;

                    fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                        f.write_str("a packet, [type, [fields...]]")
                    }

                    fn visit_seq<A: SeqAccess<'de>>(self, mut seq: A) -> Result<Packet, A::Error> {
                        let id: u64 = seq
                            .next_element()?
                            .ok_or_else(|| de::Error::invalid_length(0, &self))?;
                        let packet = match PacketType::from_id(id) {
                            $(
                                Some(PacketType::$name) => Packet::$name(
                                    seq.next_element()?
                                        .ok_or_else(|| de::Error::invalid_length(1, &self))?,
                                ),
                            )*
                            None => return Err(de::Error::custom(format_args!("unknown packet type {id}"))),
                        };
                        if seq.next_element::<IgnoredAny>()?.is_some() {
                            return Err(de::Error::invalid_length(3, &self));
                        }
                        Ok(packet)
                    }
                }

                deserializer.deserialize_seq(PacketVisitor)
            }
        }
    };
}

packets! {
    /// S→C, S→P: the server's first packet, once TLS is up.
    Welcome = 1,
    /// S→C, S→P: a request refused, with an error code; the connection stays.
    RequestRefused = 2,
    /// S→C, S→P: send the attachment's parts now.
    Continue = 3,
    /// C→S: stores a message, its attachment's parts after it if it has one
    /// (`MessagePushed` / `RequestRefused`, `Continue` first for an attachment).
    PushMessage = 4,
    /// S→C, S→P: the stored message's id (the last one of a replicated batch).
    MessagePushed = 5,
    /// C→S: a topic/node's messages after an id, or its last ones (`Messages` / `RequestRefused`).
    GetMessages = 6,
    /// S→C: a run of messages.
    Messages = 7,
    /// C→S: a message's attachment, from a part on (`Attachment` then its parts / `RequestRefused`).
    GetAttachment = 8,
    /// S→C: the attachment whose parts follow.
    Attachment = 9,
    /// C→S, S→C, P→S: a part of an attachment, the next one.
    AttachmentPart = 10,
    /// C→S: every topic or node the client may see (`NamesList`).
    ListNames = 11,
    /// S→C: topics or nodes.
    NamesList = 12,
    /// C→S: read-only SQL (`QueryResult` / `RequestRefused`).
    Query = 13,
    /// S→C: a query's result.
    QueryResult = 14,
    /// P→S: what the server takes from this peer and has (`SyncState` / `RequestRefused`).
    SyncStateRequest = 15,
    /// S→P: what the server takes from this peer, how far it is, the attachments it lacks.
    SyncState = 16,
    /// P→S: messages of a topic/node the server is missing (`MessagePushed` / `RequestRefused`).
    ReplicateMessages = 17,
    /// P→S: an attachment the server is missing, its parts after it (`Continue`, then `MessagePushed` / `RequestRefused`).
    ReplicateAttachment = 18,
}

impl Packet {
    /// It, encoded: what goes in a frame.
    pub fn encode(&self) -> Vec<u8> {
        rmp_serde::to_vec(self).expect("packets always serialize")
    }

    /// Reads a packet, a frame's contents. See the [module](self) for what's
    /// checked.
    pub fn decode(bytes: &[u8]) -> Result<Packet, DecodeError> {
        // A reader that grows its buffers as the data comes, never from a
        // length the packet announces.
        let mut deserializer = rmp_serde::Deserializer::new(Cursor::new(bytes));
        let packet = Packet::deserialize(&mut deserializer)
            .map_err(|error| DecodeError::Malformed(error.to_string()))?;
        if deserializer.position() != bytes.len() as u64 {
            return Err(DecodeError::TrailingBytes);
        }
        packet.check()?;
        Ok(packet)
    }
}

// The rules fields follow, for the `Check`s.
pub(crate) mod rules {
    use super::DecodeError;
    use crate::limits::{MAX_MESSAGE_ID, MAX_TIMESTAMP};
    use crate::names;

    /// Fails with `rule` unless `ok`.
    pub fn require(ok: bool, field: &'static str, rule: &'static str) -> Result<(), DecodeError> {
        if ok {
            Ok(())
        } else {
            Err(DecodeError::Invalid { field, rule })
        }
    }

    /// From `min` to `max`.
    pub fn range(value: u64, min: u64, max: u64, field: &'static str) -> Result<(), DecodeError> {
        require((min..=max).contains(&value), field, "out of range")
    }

    /// At most `max` items.
    pub fn most(len: usize, max: usize, field: &'static str) -> Result<(), DecodeError> {
        require(len <= max, field, "too many")
    }

    /// A topic or node name.
    pub fn name(value: &str, field: &'static str) -> Result<(), DecodeError> {
        require(names::is_valid_name(value), field, "must be a name")
    }

    /// A message id: 1 and up.
    pub fn message_id(value: u64, field: &'static str) -> Result<(), DecodeError> {
        range(value, 1, MAX_MESSAGE_ID, field)
    }

    /// When a message was pushed: milliseconds since 1970 UTC, 1 to 9999-12-31.
    pub fn timestamp(value: u64, field: &'static str) -> Result<(), DecodeError> {
        range(value, 1, MAX_TIMESTAMP, field)
    }

    /// Strictly increasing ids.
    pub fn increasing(
        ids: impl Iterator<Item = u64>,
        field: &'static str,
    ) -> Result<(), DecodeError> {
        let mut last = 0;
        for id in ids {
            require(id > last, field, "ids must be strictly increasing")?;
            last = id;
        }
        Ok(())
    }
}
