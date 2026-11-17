//! The exports called as C would, against a server. `exports`: one client,
//! the `W` exports (what PureBasic uses; Python's check covers the `A`
//! ones), the buffers, the errors. `clients`: several clients at once, bad
//! handles, threads.

#![allow(unsafe_code)]

mod common;

use bakashrot::*;
use bakashrot_proto::ErrorCode;
use std::ffi::{CString, c_char};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

fn w(text: &str) -> Vec<u16> {
    text.encode_utf16().chain([0]).collect()
}

fn a(text: &str) -> CString {
    CString::new(text).unwrap()
}

/// A `W` getter's string: asks for the size, then copies.
fn get_w(client: i64, getter: unsafe extern "C" fn(i64, *mut u16, isize) -> isize) -> String {
    let size = unsafe { getter(client, std::ptr::null_mut(), 0) };
    if size == 0 {
        return String::new();
    }
    let mut buffer = vec![0u16; size as usize / 2];
    unsafe { getter(client, buffer.as_mut_ptr(), size) };
    String::from_utf16(&buffer[..buffer.len() - 1]).unwrap()
}

fn get_a(client: i64, getter: unsafe extern "C" fn(i64, *mut c_char, isize) -> isize) -> String {
    let size = unsafe { getter(client, std::ptr::null_mut(), 0) };
    let mut buffer = vec![0u8; size as usize];
    unsafe { getter(client, buffer.as_mut_ptr().cast(), size) };
    String::from_utf8(buffer[..buffer.len() - 1].to_vec()).unwrap()
}

/// The client's last error: its code and reason.
fn error(client: i64) -> (u32, String) {
    (
        BakaShrot_GetLastError(client) as u32,
        get_w(client, BakaShrot_GetRefusalReasonW),
    )
}

fn code(code: ErrorCode) -> u32 {
    code.code()
}

#[test]
fn exports() {
    let running = common::Running::start("exports");
    running.issue("kitchen", &["home"]);
    running.issue("lounge", &["lounge"]);
    let file = |name: &str| running.folder.join(name).display().to_string();
    let pem = |name: &str| std::fs::read_to_string(running.folder.join(name)).unwrap();
    let localhost = w("127.0.0.1");
    let port = i32::from(running.port);
    let client = BakaShrot_CreateClient();
    assert!(client >= 1);

    unsafe {
        // Nothing set, not connected.
        assert_eq!(
            BakaShrot_PushMessageToW(client, w("logs").as_ptr(), w("{}").as_ptr()),
            -1
        );
        assert_eq!(error(client).0, code(ErrorCode::NotConnected));
        assert_eq!(BakaShrot_ConnectW(client, localhost.as_ptr(), port), 0);
        let (failed, why) = error(client);
        assert_eq!(failed, code(ErrorCode::InvalidArgument));
        assert!(why.contains("BakaShrot_SetCaCertificate"), "{why}");

        // Files or PEM text; a missing file, an empty setting.
        assert_eq!(
            BakaShrot_SetCaCertificateW(client, w(&file("missing.crt")).as_ptr()),
            0
        );
        assert_eq!(error(client).0, code(ErrorCode::FileError));
        assert_eq!(BakaShrot_SetCertificateW(client, std::ptr::null()), 0);
        assert_eq!(error(client).0, code(ErrorCode::InvalidArgument));
        assert_eq!(
            BakaShrot_SetCaCertificateW(client, w(&file("ca.crt")).as_ptr()),
            1
        );
        assert_eq!(BakaShrot_GetLastError(client), 0);
        assert_eq!(
            BakaShrot_SetCertificateW(client, w(&pem("kitchen.crt")).as_ptr()),
            1
        );
        assert_eq!(
            BakaShrot_SetPrivateKeyA(client, a(&file("kitchen.key")).as_ptr()),
            1
        );
        // A CRL file asked for is needed (client.toml's may be missing).
        assert_eq!(
            BakaShrot_SetCrlW(client, w(&file("missing.crl")).as_ptr()),
            0
        );
        assert_eq!(error(client).0, code(ErrorCode::FileError));
        assert_eq!(BakaShrot_SetCrlW(client, std::ptr::null()), 1);
        assert_eq!(BakaShrot_ConnectW(client, localhost.as_ptr(), 0), 0);
        assert_eq!(error(client).0, code(ErrorCode::InvalidArgument));

        assert_eq!(
            BakaShrot_ConnectW(client, localhost.as_ptr(), port),
            1,
            "{:?}",
            error(client)
        );
        assert_eq!(BakaShrot_IsConnected(client), 1);
        assert_eq!(get_w(client, BakaShrot_GetNodeW), "kitchen");
        assert_eq!(BakaShrot_ConnectW(client, localhost.as_ptr(), port), 0);
        assert_eq!(error(client).0, code(ErrorCode::AlreadyConnected));
        assert_eq!(
            BakaShrot_SetCaCertificateW(client, w(&file("ca.crt")).as_ptr()),
            0
        );
        assert_eq!(error(client).0, code(ErrorCode::AlreadyConnected));

        // Pushes: UTF-16, a null message is an empty one.
        assert_eq!(
            BakaShrot_PushMessageToW(client, w("logs").as_ptr(), w(r#"{"i":1}"#).as_ptr()),
            1
        );
        assert_eq!(
            BakaShrot_PushMessageToW(client, w("logs").as_ptr(), w("héllo 🌍").as_ptr()),
            2
        );
        assert_eq!(
            BakaShrot_PushMessageToW(client, w("logs").as_ptr(), std::ptr::null()),
            3
        );
        assert_eq!(
            BakaShrot_PushMessageToW(client, std::ptr::null(), w("{}").as_ptr()),
            -1
        );
        assert_eq!(error(client).0, code(ErrorCode::InvalidArgument));
        assert_eq!(
            BakaShrot_PushMessageToW(client, w("nothing").as_ptr(), w("{}").as_ptr()),
            -1
        );
        let (failed, why) = error(client);
        assert_eq!(failed, code(ErrorCode::NotAllowed));
        assert!(why.contains("may not push to 'nothing'"), "{why}");

        // The latest; none yet in another topic.
        assert_eq!(
            BakaShrot_GetLatestMessageOfW(client, w("logs").as_ptr(), w("kitchen").as_ptr()),
            1
        );
        assert_eq!(
            (
                BakaShrot_GetMessageCount(client),
                BakaShrot_GetMessageId(client)
            ),
            (1, 3)
        );
        assert_eq!(get_w(client, BakaShrot_GetMessageDataW), "");
        assert!(BakaShrot_GetMessagePushedAt(client) > 1_700_000_000_000);
        assert_eq!(BakaShrot_GetMessageAttachmentSize(client), 0);
        assert_eq!(BakaShrot_IsMessageAttachmentReady(client), 0);
        assert_eq!(
            BakaShrot_GetLatestMessageOfW(client, w("secret").as_ptr(), w("kitchen").as_ptr()),
            0
        );
        assert_eq!(error(client).0, code(ErrorCode::NotFound));
        assert_eq!(BakaShrot_GetMessageCount(client), 0);

        // A run of messages, selected one by one.
        assert_eq!(
            BakaShrot_GetMessagesW(client, w("logs").as_ptr(), w("kitchen").as_ptr(), 0, 2),
            2
        );
        assert_eq!(BakaShrot_HasMoreMessages(client), 1);
        assert_eq!(get_w(client, BakaShrot_GetMessageTopicW), "logs");
        assert_eq!(get_w(client, BakaShrot_GetMessageNodeW), "kitchen");
        assert_eq!(BakaShrot_GetMessageId(client), 1);
        assert_eq!(BakaShrot_SelectMessage(client, 1), 1);
        assert_eq!(get_w(client, BakaShrot_GetMessageDataW), "héllo 🌍");
        assert_eq!(get_a(client, BakaShrot_GetMessageDataA), "héllo 🌍");
        assert_eq!(BakaShrot_SelectMessage(client, 2), 0);
        assert_eq!(error(client).0, code(ErrorCode::InvalidArgument));
        assert_eq!(BakaShrot_GetMessageId(client), 2, "the selection stays");
        assert_eq!(
            BakaShrot_GetMessagesW(client, w("logs").as_ptr(), w("kitchen").as_ptr(), 3, 10),
            0
        );
        assert_eq!(BakaShrot_HasMoreMessages(client), 0);
        assert_eq!(BakaShrot_GetMessageId(client), 0);
        for (after, limit) in [(-1, 10), (0, 0), (0, 10_001)] {
            assert_eq!(
                BakaShrot_GetMessagesW(
                    client,
                    w("logs").as_ptr(),
                    w("kitchen").as_ptr(),
                    after,
                    limit
                ),
                -1
            );
            assert_eq!(error(client).0, code(ErrorCode::InvalidArgument));
        }
        assert_eq!(
            BakaShrot_GetMessagesW(client, w("logs").as_ptr(), w("nobody").as_ptr(), 0, 10),
            -1
        );
        assert_eq!(error(client).0, code(ErrorCode::UnknownName));
        assert_eq!(
            BakaShrot_IsConnected(client),
            1,
            "a refusal keeps the connection"
        );

        // The buffers: the size needed, nothing copied if it doesn't fit.
        BakaShrot_GetMessagesW(client, w("logs").as_ptr(), w("kitchen").as_ptr(), 0, 1);
        assert_eq!(
            BakaShrot_GetMessageDataW(client, std::ptr::null_mut(), 0),
            16
        );
        assert_eq!(
            BakaShrot_GetMessageDataA(client, std::ptr::null_mut(), 0),
            8
        );
        let mut small = [7u16; 7];
        assert_eq!(
            BakaShrot_GetMessageDataW(client, small.as_mut_ptr(), 14),
            16
        );
        assert_eq!(small, [7; 7]);
        // Unaligned: a byte buffer.
        let mut bytes = [0u8; 17];
        assert_eq!(
            BakaShrot_GetMessageDataW(client, bytes[1..].as_mut_ptr().cast(), 16),
            16
        );
        assert_eq!(bytes[1..3], [b'{', 0]);

        // Names, queries.
        // Topics: those with messages (nothing in `secret` yet).
        assert_eq!(BakaShrot_ListTopics(client), 1);
        assert_eq!(
            get_w(client, BakaShrot_GetNamesListW),
            r#"{"kind":"topic","names":["logs"],"truncated":false}"#
        );
        assert_eq!(BakaShrot_ListNodes(client), 1);
        assert_eq!(
            BakaShrot_QueryW(client, w("SELECT COUNT(*) AS n FROM data").as_ptr()),
            1
        );
        assert_eq!(
            get_w(client, BakaShrot_GetQueryResultW),
            r#"{"columns":["n"],"rows":[["3"]]}"#
        );
        assert_eq!(BakaShrot_QueryW(client, w("SELECT nope").as_ptr()), 0);
        assert_eq!(error(client).0, code(ErrorCode::QueryFailed));
        assert_eq!(get_w(client, BakaShrot_GetQueryResultW), "");

        // Attachments: from a file or memory, saved or loaded back.
        let (logs, kitchen) = (w("logs"), w("kitchen"));
        let photo: Vec<u8> = (0..1_500_000u32).map(|i| (i % 251) as u8).collect();
        std::fs::write(running.folder.join("photo.bin"), &photo).unwrap();
        let photo_file = w(&file("photo.bin"));
        let pushed = BakaShrot_PushMessageWithFileW(
            client,
            logs.as_ptr(),
            w(r#"{"photo":1}"#).as_ptr(),
            photo_file.as_ptr(),
        );
        assert_eq!(pushed, 4, "{:?}", error(client));
        let tiny = b"tiny";
        let pushed = BakaShrot_PushMessageWithDataW(
            client,
            logs.as_ptr(),
            std::ptr::null(),
            tiny.as_ptr().cast(),
            4,
        );
        assert_eq!(pushed, 5, "{:?}", error(client));
        assert_eq!(
            BakaShrot_GetLatestMessageOfW(client, logs.as_ptr(), kitchen.as_ptr()),
            1
        );
        assert_eq!(
            (
                BakaShrot_GetMessageId(client),
                BakaShrot_GetMessageAttachmentSize(client),
                BakaShrot_IsMessageAttachmentReady(client)
            ),
            (5, 4, 1)
        );
        let saved = w(&file("saved.bin"));
        assert_eq!(
            BakaShrot_SaveAttachmentW(client, logs.as_ptr(), kitchen.as_ptr(), 4, saved.as_ptr()),
            1_500_000
        );
        assert_eq!(
            std::fs::read(running.folder.join("saved.bin")).unwrap(),
            photo
        );
        assert_eq!(
            BakaShrot_LoadAttachmentW(client, logs.as_ptr(), kitchen.as_ptr(), 5),
            4
        );
        assert_eq!(
            BakaShrot_GetAttachmentData(client, std::ptr::null_mut(), 0),
            4
        );
        let mut small = [9u8; 3];
        assert_eq!(
            BakaShrot_GetAttachmentData(client, small.as_mut_ptr().cast(), 3),
            4
        );
        assert_eq!(small, [9; 3], "nothing copied if it doesn't fit");
        let mut data = [0u8; 4];
        assert_eq!(
            BakaShrot_GetAttachmentData(client, data.as_mut_ptr().cast(), 4),
            4
        );
        assert_eq!(&data, tiny);
        assert_eq!(BakaShrot_FreeAttachmentData(client), 1);
        assert_eq!(
            BakaShrot_GetAttachmentData(client, std::ptr::null_mut(), 0),
            0
        );
        assert_eq!(
            BakaShrot_LoadAttachmentA(client, a("logs").as_ptr(), a("kitchen").as_ptr(), 4),
            1_500_000
        );
        BakaShrot_FreeAttachmentData(client);

        // Refused, or the client's own failures: -1, no file.
        let none = w(&file("none.bin"));
        assert_eq!(
            BakaShrot_SaveAttachmentW(client, logs.as_ptr(), kitchen.as_ptr(), 1, none.as_ptr()),
            -1
        );
        assert_eq!(error(client).0, code(ErrorCode::NotFound));
        assert!(!running.folder.join("none.bin").exists());
        assert_eq!(
            BakaShrot_SaveAttachmentW(client, logs.as_ptr(), kitchen.as_ptr(), -1, none.as_ptr()),
            -1
        );
        assert_eq!(error(client).0, code(ErrorCode::InvalidArgument));
        let missing = w(&file("missing.bin"));
        assert_eq!(
            BakaShrot_PushMessageWithFileW(
                client,
                logs.as_ptr(),
                std::ptr::null(),
                missing.as_ptr()
            ),
            -1
        );
        assert_eq!(error(client).0, code(ErrorCode::FileError));
        for (pointer, size) in [(std::ptr::null(), 4), (tiny.as_ptr(), 0)] {
            let pushed = BakaShrot_PushMessageWithDataW(
                client,
                logs.as_ptr(),
                std::ptr::null(),
                pointer.cast(),
                size,
            );
            assert_eq!(pushed, -1);
            assert_eq!(error(client).0, code(ErrorCode::InvalidArgument));
        }
        assert_eq!(BakaShrot_IsConnected(client), 1);

        // Closed: requests refused, the settings kept.
        assert_eq!(BakaShrot_Disconnect(client), 1);
        assert_eq!(BakaShrot_Disconnect(client), 0);
        assert_eq!(BakaShrot_IsConnected(client), 0);
        assert_eq!(get_w(client, BakaShrot_GetNodeW), "");
        assert_eq!(BakaShrot_QueryW(client, w("SELECT 1").as_ptr()), 0);
        assert_eq!(error(client).0, code(ErrorCode::NotConnected));

        // Another identity, by the A exports: not allowed to query.
        assert_eq!(
            BakaShrot_SetCertificateA(client, a(&file("lounge.crt")).as_ptr()),
            1
        );
        assert_eq!(
            BakaShrot_SetPrivateKeyA(client, a(&pem("lounge.key")).as_ptr()),
            1
        );
        assert_eq!(
            BakaShrot_ConnectA(client, a("localhost").as_ptr(), port),
            1,
            "{:?}",
            error(client)
        );
        assert_eq!(get_a(client, BakaShrot_GetNodeA), "lounge");
        assert_eq!(BakaShrot_QueryA(client, a("SELECT 1").as_ptr()), 0);
        let (failed, why) = error(client);
        assert_eq!(failed, code(ErrorCode::NotAllowed));
        assert_eq!(get_a(client, BakaShrot_GetRefusalReasonA), why);
        BakaShrot_Disconnect(client);

        // Nothing listening there.
        assert_eq!(BakaShrot_ConnectA(client, a("127.0.0.1").as_ptr(), 1), 0);
        assert_eq!(error(client).0, code(ErrorCode::ConnectFailed));
    }
    assert_eq!(BakaShrot_FreeClient(client), 1);
}

/// A new client, connected as `name` (its certificate and key in files).
fn connected(running: &common::Running, name: &str) -> i64 {
    let client = BakaShrot_CreateClient();
    assert!(client >= 1);
    let file = |name: &str| w(&running.folder.join(name).display().to_string());
    unsafe {
        assert_eq!(
            BakaShrot_SetCaCertificateW(client, file("ca.crt").as_ptr()),
            1
        );
        assert_eq!(
            BakaShrot_SetCertificateW(client, file(&format!("{name}.crt")).as_ptr()),
            1
        );
        assert_eq!(
            BakaShrot_SetPrivateKeyW(client, file(&format!("{name}.key")).as_ptr()),
            1
        );
        let host = w("127.0.0.1");
        let connected = BakaShrot_ConnectW(client, host.as_ptr(), i32::from(running.port));
        assert_eq!(connected, 1, "{name}: {:?}", error(client));
    }
    client
}

#[test]
fn clients() {
    let running = common::Running::start("clients");
    running.issue("kitchen", &["home"]);
    running.issue("lounge", &["lounge"]);

    unsafe {
        // Handles that aren't a client's: refused, never a crash.
        assert_eq!(
            BakaShrot_PushMessageToW(99, w("logs").as_ptr(), w("{}").as_ptr()),
            -1
        );
        let (failed, why) = error(99);
        assert_eq!(failed, code(ErrorCode::InvalidArgument));
        assert!(why.contains("no client 99"), "{why}");
        assert_eq!(BakaShrot_IsConnected(99), 0);
        assert_eq!(BakaShrot_GetMessageId(-5), 0);
        assert_eq!(get_w(99, BakaShrot_GetMessageDataW), "");
        assert_eq!(BakaShrot_FreeClient(99), 0);
        assert_eq!(BakaShrot_FreeClient(0), 0);
        let (failed, why) = error(0);
        assert_eq!(failed, code(ErrorCode::InvalidArgument), "0 is never one");
        assert!(why.contains("no client 0"), "{why}");

        // Two identities connected at once.
        let kitchen = connected(&running, "kitchen");
        let lounge = connected(&running, "lounge");
        assert_ne!(kitchen, lounge);
        assert_eq!(get_w(kitchen, BakaShrot_GetNodeW), "kitchen");
        assert_eq!(get_w(lounge, BakaShrot_GetNodeW), "lounge");

        for i in 1..=3 {
            let data = w(&format!(r#"{{"i":{i}}}"#));
            assert_eq!(
                BakaShrot_PushMessageToW(kitchen, w("logs").as_ptr(), data.as_ptr()),
                i
            );
        }

        // Each its answers: one reads, the other's selection stays.
        assert_eq!(
            BakaShrot_GetLatestMessageOfW(kitchen, w("logs").as_ptr(), w("kitchen").as_ptr()),
            1
        );
        assert_eq!(
            BakaShrot_GetMessagesW(lounge, w("logs").as_ptr(), w("kitchen").as_ptr(), 0, 10),
            3
        );
        assert_eq!(BakaShrot_SelectMessage(lounge, 1), 1);
        assert_eq!(get_w(lounge, BakaShrot_GetMessageDataW), r#"{"i":2}"#);
        assert_eq!(BakaShrot_GetMessageId(kitchen), 3);
        assert_eq!(get_w(kitchen, BakaShrot_GetMessageDataW), r#"{"i":3}"#);
        assert_eq!(BakaShrot_GetMessageCount(kitchen), 1);

        // Each its errors: lounge may only read logs.
        assert_eq!(
            BakaShrot_PushMessageToW(lounge, w("logs").as_ptr(), w("{}").as_ptr()),
            -1
        );
        let (failed, why) = error(lounge);
        assert_eq!(failed, code(ErrorCode::NotAllowed));
        assert!(why.contains("may not push"), "{why}");
        assert_eq!(error(kitchen), (0, String::new()));

        // Freed: closed, its handle refused, never given again.
        assert_eq!(BakaShrot_FreeClient(lounge), 1);
        assert_eq!(BakaShrot_FreeClient(lounge), 0);
        assert_eq!(BakaShrot_IsConnected(lounge), 0);
        assert_eq!(
            BakaShrot_GetMessagesW(lounge, w("logs").as_ptr(), w("kitchen").as_ptr(), 0, 10),
            -1
        );
        assert_eq!(error(lounge).0, code(ErrorCode::InvalidArgument));
        assert!(BakaShrot_CreateClient() > lounge.max(kitchen));
        assert_eq!(BakaShrot_IsConnected(kitchen), 1, "the other stays");
        assert_eq!(BakaShrot_Disconnect(kitchen), 1);
        assert_eq!(BakaShrot_IsConnected(kitchen), 0);
        assert_eq!(BakaShrot_FreeClient(kitchen), 1);
    }

    // Threads, each with its client, pushing at once: every push stored,
    // each id once.
    let threads: Vec<_> = (0..4)
        .map(|_| {
            let client = connected(&running, "kitchen");
            std::thread::spawn(move || {
                let ids: Vec<i64> = (0..50)
                    .map(|i| unsafe {
                        let data = w(&format!(r#"{{"t":{i}}}"#));
                        BakaShrot_PushMessageToW(client, w("logs").as_ptr(), data.as_ptr())
                    })
                    .collect();
                assert_eq!(BakaShrot_FreeClient(client), 1);
                ids
            })
        })
        .collect();
    let mut ids: Vec<i64> = threads
        .into_iter()
        .flat_map(|thread| thread.join().unwrap())
        .collect();
    ids.sort_unstable();
    assert_eq!(ids, (4..=203).collect::<Vec<i64>>());

    // A client freed while another thread uses it: that thread's calls
    // fail from then on, nothing crashes.
    let client = connected(&running, "kitchen");
    let started = Arc::new(AtomicBool::new(false));
    let reader = {
        let started = started.clone();
        std::thread::spawn(move || {
            let mut reads = 0;
            loop {
                let count = unsafe {
                    BakaShrot_GetMessagesW(client, w("logs").as_ptr(), w("kitchen").as_ptr(), 0, 50)
                };
                started.store(true, Ordering::SeqCst);
                if count < 0 {
                    return (reads, error(client).0);
                }
                reads += 1;
            }
        })
    };
    while !started.load(Ordering::SeqCst) {
        std::thread::yield_now();
    }
    assert_eq!(BakaShrot_FreeClient(client), 1);
    let (reads, failed) = reader.join().unwrap();
    assert!(reads >= 1);
    assert_eq!(failed, code(ErrorCode::InvalidArgument));
}
