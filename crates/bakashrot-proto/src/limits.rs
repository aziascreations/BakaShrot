//! The protocol's numbers: its version, sizes and counts. Servers may set
//! lower limits of their own (a smaller maximum attachment, say), never
//! higher ones.

/// The protocol's version. Both ends must have the same: they tell each
/// other first thing (`frame::write_version()`), and abandon the
/// connection if it differs. 6 was the last PureBasic one (`OldSource/`);
/// 7 runs over TLS.
pub const PROTOCOL_VERSION: u32 = 7;

/// The ALPN protocol name both ends offer during the TLS handshake: what
/// isn't BakaShrot doesn't get past it. Not versioned: the version is
/// checked once connected, so a mismatch is told as such.
pub const ALPN: &[u8] = b"bakashrot";

/// The biggest packet on the wire, in bytes (a frame's size field).
pub const MAX_PACKET_SIZE: usize = 16 * 1024 * 1024;

/// The biggest message a client may push, in UTF-8 bytes. It leaves room
/// for the fields around it, so a stored message fits in every packet that
/// carries one (a `Messages` or `ReplicateMessages` of one).
pub const MAX_MESSAGE_SIZE: usize = MAX_PACKET_SIZE - 4096;

/// The latest time a message can have been pushed: 9999-12-31 23:59:59.999
/// UTC, in milliseconds since 1970-01-01 00:00:00 UTC. Times on the wire go
/// from 1 to this.
pub const MAX_TIMESTAMP: u64 = 253_402_300_799_999;

/// The biggest message id: 2^43 - 1, about 8.8 trillion per topic and
/// node. Servers store it in 43 bits of a packed key
/// (`docs/storage.md`, "Keys").
pub const MAX_MESSAGE_ID: u64 = (1 << 43) - 1;

/// The longest topic or node name, in characters (ASCII only).
pub const MAX_NAME_LENGTH: usize = 64;

/// The most messages a `GetMessages` may ask for, a `Messages` may carry,
/// and a `ReplicateMessages` may hold.
pub const MAX_MESSAGES_PER_PACKET: u32 = 10_000;

/// The most names in a `NamesList`, and in each list of a `SyncState`.
pub const MAX_NAMES_LIST_ENTRIES: usize = 65_536;

/// The most attachments a `SyncState` lists as missing at once.
pub const MAX_MISSING_ATTACHMENTS: usize = 256;

/// Attachments go in parts of this many bytes, the last one what's left.
pub const ATTACHMENT_PART_SIZE: u64 = 1024 * 1024;

/// The biggest attachment the protocol allows (1 TiB).
pub const MAX_ATTACHMENT_SIZE: u64 = 1 << 40;

/// How many parts the biggest attachment takes.
pub const MAX_ATTACHMENT_PARTS: u64 = MAX_ATTACHMENT_SIZE / ATTACHMENT_PART_SIZE;

/// How many parts an attachment of `size` bytes takes.
pub const fn attachment_part_count(size: u64) -> u64 {
    size.div_ceil(ATTACHMENT_PART_SIZE)
}

/// The size of part `index` of an attachment of `size` bytes, 0 if it has
/// no such part.
pub const fn attachment_part_len(size: u64, index: u64) -> u64 {
    if index >= attachment_part_count(size) {
        0
    } else if index == attachment_part_count(size) - 1 {
        size - index * ATTACHMENT_PART_SIZE
    } else {
        ATTACHMENT_PART_SIZE
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parts() {
        assert_eq!(attachment_part_count(0), 0);
        assert_eq!(attachment_part_count(1), 1);
        assert_eq!(attachment_part_count(ATTACHMENT_PART_SIZE), 1);
        assert_eq!(attachment_part_count(ATTACHMENT_PART_SIZE + 1), 2);
        assert_eq!(
            attachment_part_count(MAX_ATTACHMENT_SIZE),
            MAX_ATTACHMENT_PARTS
        );

        let size = 2 * ATTACHMENT_PART_SIZE + 10;
        assert_eq!(attachment_part_len(size, 0), ATTACHMENT_PART_SIZE);
        assert_eq!(attachment_part_len(size, 1), ATTACHMENT_PART_SIZE);
        assert_eq!(attachment_part_len(size, 2), 10);
        assert_eq!(attachment_part_len(size, 3), 0);
        assert_eq!(attachment_part_len(0, 0), 0);
        assert_eq!(
            attachment_part_len(ATTACHMENT_PART_SIZE, 0),
            ATTACHMENT_PART_SIZE
        );
    }

    #[test]
    fn a_stored_message_fits_in_a_packet() {
        const { assert!(MAX_MESSAGE_SIZE + 4096 <= MAX_PACKET_SIZE) };
        assert!(MAX_PACKET_SIZE <= u32::MAX as usize);
    }
}
