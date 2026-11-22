//! BakaShrot's protocol, version 8: what the server, the clients and the
//! tools share, and nothing else.
//!
//! No I/O of its own beyond reading and writing frames on a stream it's
//! given: everything here is tested on its own. Packets are MessagePack,
//! through `serde` and `rmp-serde`.
//!
//! - [`limits`]: the protocol's numbers (sizes, counts, the version).
//! - [`error`]: the error codes, never renumbered.
//! - [`names`]: topic and node names, wildcards.
//! - [`frame`]: frames, a 4-byte size then a packet.
//! - [`packets`]: every packet, and [`Packet`] to encode and decode them.
//!
//! The wire format is described in `docs/protocol.md`.

pub mod error;
pub mod frame;
pub mod limits;
pub mod names;
pub mod packets;

pub use error::ErrorCode;
pub use packets::{Body, DecodeError, Packet, PacketType};
