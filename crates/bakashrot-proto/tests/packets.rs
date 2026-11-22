//! Every packet: round trips, the exact bytes of a few, what decoding
//! refuses, and that no input makes it panic.

use bakashrot_proto::limits::{
    ATTACHMENT_PART_SIZE, MAX_ATTACHMENT_PARTS, MAX_ATTACHMENT_SIZE, MAX_HEADS_PER_PACKET,
    MAX_MESSAGE_ID, MAX_MESSAGES_PER_PACKET, MAX_MISSING_ATTACHMENTS, MAX_NAMES_LIST_ENTRIES,
    MAX_PACKET_SIZE, MAX_TIMESTAMP,
};
use bakashrot_proto::packets::*;
use bakashrot_proto::{Body, DecodeError, ErrorCode, Packet, PacketType};

fn message(id: u64) -> MessageEntry {
    MessageEntry {
        id,
        pushed_at: 1_763_000_000_000 + id,
        data: format!("{{\"n\":{id}}}"),
        attachment: None,
    }
}

fn attachment(size: u64) -> Attachment {
    Attachment {
        size,
        sha256: [0xab; 32],
    }
}

/// One packet of each type at least, with values at their limits here and
/// there.
fn samples() -> Vec<Packet> {
    vec![
        Welcome {
            server: "server-1".into(),
            node: "kitchen".into(),
        }
        .into(),
        RequestRefused::new(ErrorCode::UnknownName, "Unknown topic 'nope'").into(),
        Continue {}.into(),
        Ping {}.into(),
        Pong {}.into(),
        PushMessage {
            topic: "logs".into(),
            data: "é€ \u{1F600} {\"a\":[1,2]}".into(),
            attachment: None,
        }
        .into(),
        PushMessage {
            topic: "sensors".into(),
            data: String::new(),
            attachment: Some(attachment(MAX_ATTACHMENT_SIZE)),
        }
        .into(),
        MessagePushed {
            message_id: MAX_MESSAGE_ID,
        }
        .into(),
        GetMessages {
            topic: "logs".into(),
            node: "kitchen".into(),
            after: Some(0),
            limit: MAX_MESSAGES_PER_PACKET,
        }
        .into(),
        GetMessages {
            topic: "logs".into(),
            node: "kitchen".into(),
            after: None,
            limit: 1,
        }
        .into(),
        Messages {
            more: true,
            messages: (1..=20)
                .map(|i| MessageEntry {
                    attachment: (i % 3 == 0).then_some(StoredAttachment {
                        size: i,
                        ready: i % 2 == 0,
                    }),
                    ..message(i * 3)
                })
                .collect(),
        }
        .into(),
        Messages {
            more: false,
            messages: vec![],
        }
        .into(),
        GetAttachment {
            topic: "sensors".into(),
            node: "kitchen".into(),
            message_id: 4,
            from_part: 2,
        }
        .into(),
        attachment(2 * ATTACHMENT_PART_SIZE + 10).into(),
        AttachmentPart {
            data: vec![0x5a; ATTACHMENT_PART_SIZE as usize],
        }
        .into(),
        AttachmentPart { data: vec![1] }.into(),
        ListNames {
            kind: NameKind::Topic,
            topics: None,
            nodes: None,
        }
        .into(),
        ListNames {
            kind: NameKind::Node,
            topics: Some("sensors.*".into()),
            nodes: Some("kitchen".into()),
        }
        .into(),
        NamesList {
            kind: NameKind::Node,
            truncated: true,
            names: vec!["kitchen".into(), "garage-1".into()],
        }
        .into(),
        Query {
            sql: "SELECT * FROM messages WHERE topic = 'logs'".into(),
        }
        .into(),
        QueryResult {
            json: r#"{"columns":["a"],"rows":[[1],[null]]}"#.into(),
        }
        .into(),
        SyncStateRequest { after: None }.into(),
        SyncStateRequest {
            after: Some(Pair {
                topic: "logs".into(),
                node: "kitchen".into(),
            }),
        }
        .into(),
        SyncState {
            more: true,
            topics: vec!["logs".into(), "sensors.*".into()],
            nodes: vec!["*".into()],
            heads: vec![
                Head {
                    topic: "logs".into(),
                    node: "kitchen".into(),
                    last_id: 0,
                },
                Head {
                    topic: "sensors.a".into(),
                    node: "garage-1".into(),
                    last_id: 123_456_789,
                },
            ],
            missing: vec![MissingAttachment {
                topic: "logs".into(),
                node: "kitchen".into(),
                message_id: 11,
                next_part: 3,
            }],
        }
        .into(),
        ReplicateMessages {
            topic: "logs".into(),
            node: "kitchen".into(),
            messages: vec![
                ReplicatedMessage {
                    id: 10,
                    pushed_at: 1,
                    data: "not JSON".into(),
                    attachment: None,
                },
                ReplicatedMessage {
                    id: 11,
                    pushed_at: MAX_TIMESTAMP,
                    data: "{}".into(),
                    attachment: Some(attachment(5)),
                },
            ],
        }
        .into(),
        ReplicateAttachment {
            topic: "logs".into(),
            node: "kitchen".into(),
            message_id: 11,
            from_part: 3,
        }
        .into(),
    ]
}

/// Encodes anything serializable as a packet's body, `[type, body]`: to make
/// packets that break rules or have the wrong shape.
fn raw(packet_type: PacketType, body: impl serde::Serialize) -> Vec<u8> {
    rmp_serde::to_vec(&(packet_type.id(), body)).unwrap()
}

fn refused(bytes: &[u8]) -> DecodeError {
    Packet::decode(bytes).expect_err("must be refused")
}

fn invalid(bytes: &[u8]) -> bool {
    matches!(refused(bytes), DecodeError::Invalid { .. })
}

fn malformed(bytes: &[u8]) -> bool {
    matches!(refused(bytes), DecodeError::Malformed(_))
}

#[test]
fn every_type_has_a_sample() {
    let samples = samples();
    for packet_type in PacketType::ALL {
        assert!(
            samples.iter().any(|p| p.packet_type() == *packet_type),
            "no sample of {}",
            packet_type.name()
        );
    }
    for (index, packet_type) in PacketType::ALL.iter().enumerate() {
        assert_eq!(
            usize::from(packet_type.id()),
            index + 1,
            "ids follow each other"
        );
        assert_eq!(
            PacketType::from_id(packet_type.id().into()),
            Some(*packet_type)
        );
    }
}

#[test]
fn round_trips() {
    for packet in samples() {
        let bytes = packet.encode();
        assert_eq!(
            Packet::decode(&bytes),
            Ok(packet.clone()),
            "{}",
            packet.packet_type().name()
        );
        assert_eq!(bytes[1], packet.packet_type().id(), "the type comes first");
    }
}

#[test]
fn golden_bytes() {
    // [4, ["logs", "{}", nil]]: what protocol.md shows.
    let push = PushMessage {
        topic: "logs".into(),
        data: "{}".into(),
        attachment: None,
    };
    assert_eq!(
        push.encode(),
        [
            0x92, 0x04, 0x93, 0xa4, b'l', b'o', b'g', b's', 0xa2, b'{', b'}', 0xc0
        ]
    );
    assert_eq!(Continue {}.encode(), [0x92, 0x03, 0x90]);
    assert_eq!(Ping {}.encode(), [0x92, 0x13, 0x90]);
    assert_eq!(Pong {}.encode(), [0x92, 0x14, 0x90]);
    assert_eq!(
        MessagePushed { message_id: 300 }.encode(),
        [0x92, 0x05, 0x91, 0xcd, 0x01, 0x2c]
    );
    // Bytes are binaries, not arrays of numbers.
    assert_eq!(
        AttachmentPart { data: vec![7, 8] }.encode(),
        [0x92, 0x0a, 0x91, 0xc4, 0x02, 7, 8]
    );
    let sha = attachment(1).encode();
    assert_eq!(sha[..6], [0x92, 0x09, 0x92, 0x01, 0xc4, 0x20]);
}

#[test]
fn every_truncation_is_refused() {
    for packet in samples() {
        let bytes = packet.encode();
        // The 1 MB part's prefixes are all alike past its header.
        let step = if bytes.len() > 4096 { 4093 } else { 1 };
        for len in (0..bytes.len()).step_by(step) {
            assert!(
                Packet::decode(&bytes[..len]).is_err(),
                "{} cut at {len}",
                packet.packet_type().name()
            );
        }
    }
}

#[test]
fn trailing_bytes_are_refused() {
    for packet in samples() {
        let mut bytes = packet.encode();
        bytes.push(0);
        assert_eq!(Packet::decode(&bytes), Err(DecodeError::TrailingBytes));
    }
}

#[test]
fn shapes() {
    // Unknown types, not a packet.
    assert!(malformed(&raw_unknown(0)));
    assert!(malformed(&raw_unknown(19)));
    assert!(malformed(&raw_unknown(255)));
    assert!(malformed(&[0x90]), "empty");
    assert!(malformed(&[0x91, 0x05]), "no body");
    assert!(malformed(&[0x05]), "not an array");
    assert!(malformed(&[0x93, 0x03, 0x90, 0x90]), "one value too many");
    // A field missing, one too many.
    assert!(malformed(&raw(PacketType::MessagePushed, ())));
    assert!(malformed(&raw(PacketType::MessagePushed, ((),))));
    assert!(malformed(&raw(PacketType::MessagePushed, (1u64, 2u64))));
    assert!(malformed(&raw(PacketType::Continue, (1u64,))));
    assert!(malformed(&raw(PacketType::Ping, (1u64,))));
    // The wrong types.
    assert!(malformed(&raw(PacketType::MessagePushed, ("1",))));
    assert!(malformed(&raw(PacketType::MessagePushed, (-1i64,))));
    assert!(malformed(&raw(
        PacketType::Messages,
        (1u8, Vec::<u8>::new())
    )));
    assert!(
        malformed(&raw(PacketType::ListNames, (3u8, (), ()))),
        "kind 3"
    );
    assert!(
        malformed(&raw(PacketType::ListNames, (0u8, (), ()))),
        "kind 0"
    );
    assert!(
        malformed(&raw(PacketType::ListNames, (1u8,))),
        "protocol 7's, no filters"
    );
    assert!(
        malformed(&raw(
            PacketType::Attachment,
            (1u64, serde_bytes::Bytes::new(&[0; 31]))
        )),
        "a 31-byte SHA-256"
    );
    // A strings that isn't UTF-8: "ab" -> 0xc3 0x28.
    let mut bytes = Query { sql: "ab".into() }.encode();
    let at = bytes.len() - 2;
    bytes[at] = 0xc3;
    bytes[at + 1] = 0x28;
    assert!(malformed(&bytes));
    // An integer written as a signed one, still taken.
    assert_eq!(
        Packet::decode(&raw(PacketType::MessagePushed, (300i64,))),
        Ok(MessagePushed { message_id: 300 }.into())
    );
    // A binary announcing 4 GiB: refused without allocating it.
    assert!(malformed(&[
        0x92, 0x0a, 0x91, 0xc6, 0xff, 0xff, 0xff, 0xff, 0x00
    ]));
    assert!(malformed(&[
        0x92, 0x07, 0x92, 0xc3, 0xdd, 0xff, 0xff, 0xff, 0xff
    ]));
}

fn raw_unknown(id: u8) -> Vec<u8> {
    rmp_serde::to_vec(&(id, ())).unwrap()
}

#[test]
fn ranges() {
    assert!(invalid(&raw(PacketType::MessagePushed, (0u64,))));
    assert!(invalid(&raw(PacketType::MessagePushed, (1u64 << 63,))));
    // Ids end where a server's 43 bits do.
    assert!(Packet::decode(&raw(PacketType::MessagePushed, (MAX_MESSAGE_ID,))).is_ok());
    assert!(invalid(&raw(
        PacketType::MessagePushed,
        (MAX_MESSAGE_ID + 1,)
    )));

    let refusal = |code: u32| raw(PacketType::RequestRefused, (code, "x"));
    assert!(
        Packet::decode(&refusal(99)).is_ok(),
        "an unknown refusal code still decodes"
    );
    assert!(invalid(&refusal(0)));
    assert!(invalid(&refusal(100)));

    let get = |after: Option<u64>, limit: u32| {
        GetMessages {
            topic: "t".into(),
            node: "n".into(),
            after,
            limit,
        }
        .encode()
    };
    assert!(Packet::decode(&get(None, 1)).is_ok());
    assert!(invalid(&get(None, 0)));
    assert!(invalid(&get(Some(0), 10_001)));
    assert!(invalid(&get(Some(1 << 63), 1)));
    assert!(Packet::decode(&get(Some(MAX_MESSAGE_ID), 1)).is_ok());
    assert!(invalid(&get(Some(MAX_MESSAGE_ID + 1), 1)));

    let list = |topics: Option<&str>, nodes: Option<&str>| {
        ListNames {
            kind: NameKind::Node,
            topics: topics.map(Into::into),
            nodes: nodes.map(Into::into),
        }
        .encode()
    };
    assert!(Packet::decode(&list(Some("sensors.*"), Some("kitchen"))).is_ok());
    assert!(invalid(&list(Some("a b"), None)));
    assert!(invalid(&list(None, Some(""))));
    assert!(invalid(&list(None, Some("12"))));

    let times = |pushed_at| {
        Messages {
            more: false,
            messages: vec![MessageEntry {
                pushed_at,
                ..message(1)
            }],
        }
        .encode()
    };
    assert!(Packet::decode(&times(MAX_TIMESTAMP)).is_ok());
    assert!(invalid(&times(0)));
    assert!(invalid(&times(MAX_TIMESTAMP + 1)));

    let sizes = |size| {
        PushMessage {
            topic: "logs".into(),
            data: String::new(),
            attachment: Some(attachment(size)),
        }
        .encode()
    };
    assert!(invalid(&sizes(0)));
    assert!(invalid(&sizes(MAX_ATTACHMENT_SIZE + 1)));

    let part = |len| AttachmentPart { data: vec![0; len] }.encode();
    assert!(invalid(&part(0)));
    assert!(invalid(&part(ATTACHMENT_PART_SIZE as usize + 1)));
}

#[test]
fn parts_of_an_attachment() {
    let attachment = attachment(2 * ATTACHMENT_PART_SIZE + 10);
    assert_eq!(attachment.part_count(), 3);
    assert_eq!(attachment.part_len(0), ATTACHMENT_PART_SIZE);
    assert_eq!(attachment.part_len(2), 10);
    assert_eq!(attachment.part_len(3), 0);
}

#[test]
fn ids_in_order() {
    let messages = |ids: &[u64]| {
        Messages {
            more: false,
            messages: ids.iter().map(|id| message(*id)).collect(),
        }
        .encode()
    };
    assert!(Packet::decode(&messages(&[1, 2, 5])).is_ok());
    assert!(invalid(&messages(&[1, 1])));
    assert!(invalid(&messages(&[3, 2])));
    assert!(invalid(&messages(&[0])));

    let replicated = |ids: &[u64]| {
        ReplicateMessages {
            topic: "logs".into(),
            node: "kitchen".into(),
            messages: ids
                .iter()
                .map(|id| ReplicatedMessage {
                    id: *id,
                    pushed_at: 1,
                    data: String::new(),
                    attachment: None,
                })
                .collect(),
        }
        .encode()
    };
    assert!(invalid(&replicated(&[2, 1])));
    assert!(invalid(&replicated(&[])));
}

#[test]
fn too_many_items() {
    let too_many = Messages {
        more: false,
        messages: (1..=u64::from(MAX_MESSAGES_PER_PACKET) + 1)
            .map(message)
            .collect(),
    };
    assert!(invalid(&too_many.encode()));

    let head = |n: usize| Head {
        topic: "t".into(),
        node: format!("n{n}"),
        last_id: 1,
    };
    let heads = |count: usize, more: bool| SyncState {
        more,
        topics: vec![],
        nodes: vec![],
        heads: (0..count).map(head).collect(),
        missing: vec![],
    };
    assert!(Packet::decode(&heads(MAX_HEADS_PER_PACKET, true).encode()).is_ok());
    assert!(invalid(&heads(MAX_HEADS_PER_PACKET + 1, false).encode()));
    assert!(Packet::decode(&heads(0, false).encode()).is_ok());
    // More to come, but no head to ask after.
    assert!(invalid(&heads(0, true).encode()));

    let missing = SyncState {
        more: false,
        topics: vec![],
        nodes: vec![],
        heads: vec![],
        missing: (1..=257)
            .map(|id| MissingAttachment {
                topic: "t".into(),
                node: "n".into(),
                message_id: id,
                next_part: 0,
            })
            .collect(),
    };
    assert!(invalid(&missing.encode()));
}

#[test]
fn names_everywhere() {
    for bad in ["12", "", "a b", "é"] {
        let get = GetMessages {
            topic: bad.into(),
            node: "kitchen".into(),
            after: None,
            limit: 1,
        };
        assert!(invalid(&get.encode()), "{bad:?}");
        let push = PushMessage {
            topic: bad.into(),
            data: String::new(),
            attachment: None,
        };
        assert!(invalid(&push.encode()), "{bad:?}");
        let replicate = ReplicateMessages {
            topic: "logs".into(),
            node: bad.into(),
            messages: vec![ReplicatedMessage {
                id: 1,
                pushed_at: 1,
                data: String::new(),
                attachment: None,
            }],
        };
        assert!(invalid(&replicate.encode()), "{bad:?}");
        let list = NamesList {
            kind: NameKind::Topic,
            truncated: false,
            names: vec![bad.into()],
        };
        assert!(invalid(&list.encode()), "{bad:?}");
    }

    let state = |topic: &str| {
        SyncState {
            more: false,
            topics: vec![topic.into()],
            nodes: vec![],
            heads: vec![],
            missing: vec![],
        }
        .encode()
    };
    assert!(Packet::decode(&state("*")).is_ok());
    assert!(Packet::decode(&state("logs")).is_ok());
    assert!(invalid(&state("12")));
    assert!(invalid(&state("a b*")));
    let after = |topic: &str, node: &str| {
        SyncStateRequest {
            after: Some(Pair {
                topic: topic.into(),
                node: node.into(),
            }),
        }
        .encode()
    };
    assert!(Packet::decode(&after("logs", "kitchen")).is_ok());
    assert!(invalid(&after("logs*", "kitchen")));
    assert!(invalid(&after("logs", "*")));
    assert!(invalid(&after("", "kitchen")));
    assert!(invalid(&after("logs", "12")));

    let welcome = Welcome {
        server: "s".into(),
        node: "7".into(),
    };
    assert!(invalid(&welcome.encode()));
}

/// The biggest `SyncState` there can be still fits in a packet: every list
/// full, every name 64 characters, every number its largest.
#[test]
fn the_biggest_sync_state_fits() {
    let name = |prefix: char, n: usize| format!("{prefix}{n:0>63}");
    let state = SyncState {
        more: true,
        topics: (0..MAX_NAMES_LIST_ENTRIES).map(|n| name('t', n)).collect(),
        nodes: (0..MAX_NAMES_LIST_ENTRIES).map(|n| name('n', n)).collect(),
        heads: (0..MAX_HEADS_PER_PACKET)
            .map(|n| Head {
                topic: name('t', n),
                node: name('n', n),
                last_id: MAX_MESSAGE_ID,
            })
            .collect(),
        missing: (0..MAX_MISSING_ATTACHMENTS)
            .map(|n| MissingAttachment {
                topic: name('t', n),
                node: name('n', n),
                message_id: MAX_MESSAGE_ID,
                next_part: MAX_ATTACHMENT_PARTS - 1,
            })
            .collect(),
    };
    let bytes = state.encode();
    assert!(
        bytes.len() <= MAX_PACKET_SIZE,
        "{} bytes, {MAX_PACKET_SIZE} at most",
        bytes.len()
    );
    assert_eq!(Packet::decode(&bytes), Ok(state.into()));
}

/// xorshift64*, enough to make bytes that look like anything.
struct Random(u64);

impl Random {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545_f491_4f6c_dd1d)
    }
}

#[test]
fn nothing_makes_it_panic() {
    let mut random = Random(0x9e37_79b9_7f4a_7c15);
    // Random bytes, often starting like a packet.
    for round in 0..200_000 {
        let len = (random.next() % 48) as usize;
        let mut bytes: Vec<u8> = (0..len).map(|_| random.next() as u8).collect();
        if round % 2 == 0 && bytes.len() > 2 {
            bytes[0] = 0x92;
            bytes[1] = 1 + (bytes[1] % PacketType::ALL.len() as u8);
            bytes[2] = 0x90 | (bytes[2] & 0x0f);
        }
        let _ = Packet::decode(&bytes);
    }
    // Every sample with bytes changed here and there.
    let samples: Vec<Vec<u8>> = samples()
        .iter()
        .map(Packet::encode)
        .filter(|bytes| bytes.len() < 4096)
        .collect();
    for _ in 0..50_000 {
        let mut bytes = samples[(random.next() % samples.len() as u64) as usize].clone();
        for _ in 0..1 + random.next() % 3 {
            let at = (random.next() % bytes.len() as u64) as usize;
            bytes[at] = random.next() as u8;
        }
        let _ = Packet::decode(&bytes);
    }
}
