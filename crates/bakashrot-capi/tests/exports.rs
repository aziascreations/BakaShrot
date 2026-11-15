//! The exports called as C would, against a server: the `W` ones (what
//! PureBasic uses; Python's check covers the `A` ones), the buffers, the
//! errors. One test: the DLL holds one connection per process.

#![allow(unsafe_code)]

mod common;

use bakashrot::*;
use bakashrot_proto::ErrorCode;
use std::ffi::{CString, c_char};

fn w(text: &str) -> Vec<u16> {
    text.encode_utf16().chain([0]).collect()
}

fn a(text: &str) -> CString {
    CString::new(text).unwrap()
}

/// A `W` getter's string: asks for the size, then copies.
fn get_w(getter: unsafe extern "C" fn(*mut u16, isize) -> isize) -> String {
    let size = unsafe { getter(std::ptr::null_mut(), 0) };
    let mut buffer = vec![0u16; size as usize / 2];
    unsafe { getter(buffer.as_mut_ptr(), size) };
    String::from_utf16(&buffer[..buffer.len() - 1]).unwrap()
}

fn get_a(getter: unsafe extern "C" fn(*mut c_char, isize) -> isize) -> String {
    let size = unsafe { getter(std::ptr::null_mut(), 0) };
    let mut buffer = vec![0u8; size as usize];
    unsafe { getter(buffer.as_mut_ptr().cast(), size) };
    String::from_utf8(buffer[..buffer.len() - 1].to_vec()).unwrap()
}

/// The last error's code and reason.
fn error() -> (u32, String) {
    (
        BakaShrot_GetLastError() as u32,
        get_w(BakaShrot_GetRefusalReasonW),
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

    unsafe {
        // Nothing set, not connected.
        assert_eq!(
            BakaShrot_PushMessageToW(w("logs").as_ptr(), w("{}").as_ptr()),
            -1
        );
        assert_eq!(error().0, code(ErrorCode::NotConnected));
        assert_eq!(BakaShrot_ConnectW(localhost.as_ptr(), port), 0);
        let (failed, why) = error();
        assert_eq!(failed, code(ErrorCode::InvalidArgument));
        assert!(why.contains("BakaShrot_SetCaCertificate"), "{why}");

        // Files or PEM text; a missing file, an empty setting.
        assert_eq!(
            BakaShrot_SetCaCertificateW(w(&file("missing.crt")).as_ptr()),
            0
        );
        assert_eq!(error().0, code(ErrorCode::FileError));
        assert_eq!(BakaShrot_SetCertificateW(std::ptr::null()), 0);
        assert_eq!(error().0, code(ErrorCode::InvalidArgument));
        assert_eq!(BakaShrot_SetCaCertificateW(w(&file("ca.crt")).as_ptr()), 1);
        assert_eq!(BakaShrot_GetLastError(), 0);
        assert_eq!(
            BakaShrot_SetCertificateW(w(&pem("kitchen.crt")).as_ptr()),
            1
        );
        assert_eq!(
            BakaShrot_SetPrivateKeyA(a(&file("kitchen.key")).as_ptr()),
            1
        );
        assert_eq!(BakaShrot_SetCrlW(std::ptr::null()), 1);
        assert_eq!(BakaShrot_ConnectW(localhost.as_ptr(), 0), 0);
        assert_eq!(error().0, code(ErrorCode::InvalidArgument));

        assert_eq!(
            BakaShrot_ConnectW(localhost.as_ptr(), port),
            1,
            "{:?}",
            error()
        );
        assert_eq!(BakaShrot_IsConnected(), 1);
        assert_eq!(get_w(BakaShrot_GetNodeW), "kitchen");
        assert_eq!(BakaShrot_ConnectW(localhost.as_ptr(), port), 0);
        assert_eq!(error().0, code(ErrorCode::AlreadyConnected));
        assert_eq!(BakaShrot_SetCaCertificateW(w(&file("ca.crt")).as_ptr()), 0);
        assert_eq!(error().0, code(ErrorCode::AlreadyConnected));

        // Pushes: UTF-16, a null message is an empty one.
        assert_eq!(
            BakaShrot_PushMessageToW(w("logs").as_ptr(), w(r#"{"i":1}"#).as_ptr()),
            1
        );
        assert_eq!(
            BakaShrot_PushMessageToW(w("logs").as_ptr(), w("héllo 🌍").as_ptr()),
            2
        );
        assert_eq!(
            BakaShrot_PushMessageToW(w("logs").as_ptr(), std::ptr::null()),
            3
        );
        assert_eq!(
            BakaShrot_PushMessageToW(std::ptr::null(), w("{}").as_ptr()),
            -1
        );
        assert_eq!(error().0, code(ErrorCode::InvalidArgument));
        assert_eq!(
            BakaShrot_PushMessageToW(w("nothing").as_ptr(), w("{}").as_ptr()),
            -1
        );
        let (failed, why) = error();
        assert_eq!(failed, code(ErrorCode::UnknownName));
        assert!(why.contains("unknown topic"), "{why}");

        // The latest; none yet in another topic.
        assert_eq!(
            BakaShrot_GetLatestMessageOfW(w("logs").as_ptr(), w("kitchen").as_ptr()),
            1
        );
        assert_eq!(
            (BakaShrot_GetMessageCount(), BakaShrot_GetMessageId()),
            (1, 3)
        );
        assert_eq!(get_w(BakaShrot_GetMessageDataW), "");
        assert!(BakaShrot_GetMessagePushedAt() > 1_700_000_000_000);
        assert_eq!(BakaShrot_GetMessageAttachmentSize(), 0);
        assert_eq!(BakaShrot_IsMessageAttachmentReady(), 0);
        assert_eq!(
            BakaShrot_GetLatestMessageOfW(w("secret").as_ptr(), w("kitchen").as_ptr()),
            0
        );
        assert_eq!(error().0, code(ErrorCode::NotFound));
        assert_eq!(BakaShrot_GetMessageCount(), 0);

        // A run of messages, selected one by one.
        assert_eq!(
            BakaShrot_GetMessagesW(w("logs").as_ptr(), w("kitchen").as_ptr(), 0, 2),
            2
        );
        assert_eq!(BakaShrot_HasMoreMessages(), 1);
        assert_eq!(get_w(BakaShrot_GetMessageTopicW), "logs");
        assert_eq!(get_w(BakaShrot_GetMessageNodeW), "kitchen");
        assert_eq!(BakaShrot_GetMessageId(), 1);
        assert_eq!(BakaShrot_SelectMessage(1), 1);
        assert_eq!(get_w(BakaShrot_GetMessageDataW), "héllo 🌍");
        assert_eq!(get_a(BakaShrot_GetMessageDataA), "héllo 🌍");
        assert_eq!(BakaShrot_SelectMessage(2), 0);
        assert_eq!(error().0, code(ErrorCode::InvalidArgument));
        assert_eq!(BakaShrot_GetMessageId(), 2, "the selection stays");
        assert_eq!(
            BakaShrot_GetMessagesW(w("logs").as_ptr(), w("kitchen").as_ptr(), 3, 10),
            0
        );
        assert_eq!(BakaShrot_HasMoreMessages(), 0);
        assert_eq!(BakaShrot_GetMessageId(), 0);
        for (after, limit) in [(-1, 10), (0, 0), (0, 10_001)] {
            assert_eq!(
                BakaShrot_GetMessagesW(w("logs").as_ptr(), w("kitchen").as_ptr(), after, limit),
                -1
            );
            assert_eq!(error().0, code(ErrorCode::InvalidArgument));
        }
        assert_eq!(
            BakaShrot_GetMessagesW(w("logs").as_ptr(), w("nobody").as_ptr(), 0, 10),
            -1
        );
        assert_eq!(error().0, code(ErrorCode::UnknownName));
        assert_eq!(BakaShrot_IsConnected(), 1, "a refusal keeps the connection");

        // The buffers: the size needed, nothing copied if it doesn't fit.
        BakaShrot_GetMessagesW(w("logs").as_ptr(), w("kitchen").as_ptr(), 0, 1);
        assert_eq!(BakaShrot_GetMessageDataW(std::ptr::null_mut(), 0), 16);
        assert_eq!(BakaShrot_GetMessageDataA(std::ptr::null_mut(), 0), 8);
        let mut small = [7u16; 7];
        assert_eq!(BakaShrot_GetMessageDataW(small.as_mut_ptr(), 14), 16);
        assert_eq!(small, [7; 7]);
        // Unaligned: a byte buffer.
        let mut bytes = [0u8; 17];
        assert_eq!(
            BakaShrot_GetMessageDataW(bytes[1..].as_mut_ptr().cast(), 16),
            16
        );
        assert_eq!(bytes[1..3], [b'{', 0]);

        // Names, queries.
        assert_eq!(BakaShrot_ListTopics(), 2);
        assert_eq!(
            get_w(BakaShrot_GetNamesListW),
            r#"{"kind":"topic","names":["logs","secret"],"truncated":false}"#
        );
        assert_eq!(BakaShrot_ListNodes(), 1);
        assert_eq!(
            BakaShrot_QueryW(w("SELECT COUNT(*) AS n FROM data").as_ptr()),
            1
        );
        assert_eq!(
            get_w(BakaShrot_GetQueryResultW),
            r#"{"columns":["n"],"rows":[["3"]]}"#
        );
        assert_eq!(BakaShrot_QueryW(w("SELECT nope").as_ptr()), 0);
        assert_eq!(error().0, code(ErrorCode::QueryFailed));
        assert_eq!(get_w(BakaShrot_GetQueryResultW), "");

        // Attachments: from a file or memory, saved or loaded back.
        let (logs, kitchen) = (w("logs"), w("kitchen"));
        let photo: Vec<u8> = (0..1_500_000u32).map(|i| (i % 251) as u8).collect();
        std::fs::write(running.folder.join("photo.bin"), &photo).unwrap();
        let photo_file = w(&file("photo.bin"));
        let pushed = BakaShrot_PushMessageWithFileW(
            logs.as_ptr(),
            w(r#"{"photo":1}"#).as_ptr(),
            photo_file.as_ptr(),
        );
        assert_eq!(pushed, 4, "{:?}", error());
        let tiny = b"tiny";
        let pushed = BakaShrot_PushMessageWithDataW(
            logs.as_ptr(),
            std::ptr::null(),
            tiny.as_ptr().cast(),
            4,
        );
        assert_eq!(pushed, 5, "{:?}", error());
        assert_eq!(
            BakaShrot_GetLatestMessageOfW(logs.as_ptr(), kitchen.as_ptr()),
            1
        );
        assert_eq!(
            (
                BakaShrot_GetMessageId(),
                BakaShrot_GetMessageAttachmentSize(),
                BakaShrot_IsMessageAttachmentReady()
            ),
            (5, 4, 1)
        );
        let saved = w(&file("saved.bin"));
        assert_eq!(
            BakaShrot_SaveAttachmentW(logs.as_ptr(), kitchen.as_ptr(), 4, saved.as_ptr()),
            1_500_000
        );
        assert_eq!(
            std::fs::read(running.folder.join("saved.bin")).unwrap(),
            photo
        );
        assert_eq!(
            BakaShrot_LoadAttachmentW(logs.as_ptr(), kitchen.as_ptr(), 5),
            4
        );
        assert_eq!(BakaShrot_GetAttachmentData(std::ptr::null_mut(), 0), 4);
        let mut small = [9u8; 3];
        assert_eq!(BakaShrot_GetAttachmentData(small.as_mut_ptr().cast(), 3), 4);
        assert_eq!(small, [9; 3], "nothing copied if it doesn't fit");
        let mut data = [0u8; 4];
        assert_eq!(BakaShrot_GetAttachmentData(data.as_mut_ptr().cast(), 4), 4);
        assert_eq!(&data, tiny);
        assert_eq!(BakaShrot_FreeAttachmentData(), 1);
        assert_eq!(BakaShrot_GetAttachmentData(std::ptr::null_mut(), 0), 0);
        assert_eq!(
            BakaShrot_LoadAttachmentA(a("logs").as_ptr(), a("kitchen").as_ptr(), 4),
            1_500_000
        );
        BakaShrot_FreeAttachmentData();

        // Refused, or the client's own failures: -1, no file.
        let none = w(&file("none.bin"));
        assert_eq!(
            BakaShrot_SaveAttachmentW(logs.as_ptr(), kitchen.as_ptr(), 1, none.as_ptr()),
            -1
        );
        assert_eq!(error().0, code(ErrorCode::NotFound));
        assert!(!running.folder.join("none.bin").exists());
        assert_eq!(
            BakaShrot_SaveAttachmentW(logs.as_ptr(), kitchen.as_ptr(), -1, none.as_ptr()),
            -1
        );
        assert_eq!(error().0, code(ErrorCode::InvalidArgument));
        let missing = w(&file("missing.bin"));
        assert_eq!(
            BakaShrot_PushMessageWithFileW(logs.as_ptr(), std::ptr::null(), missing.as_ptr()),
            -1
        );
        assert_eq!(error().0, code(ErrorCode::FileError));
        for (pointer, size) in [(std::ptr::null(), 4), (tiny.as_ptr(), 0)] {
            let pushed = BakaShrot_PushMessageWithDataW(
                logs.as_ptr(),
                std::ptr::null(),
                pointer.cast(),
                size,
            );
            assert_eq!(pushed, -1);
            assert_eq!(error().0, code(ErrorCode::InvalidArgument));
        }
        assert_eq!(BakaShrot_IsConnected(), 1);

        // Closed: requests refused, the settings kept.
        assert_eq!(BakaShrot_Disconnect(), 1);
        assert_eq!(BakaShrot_Disconnect(), 0);
        assert_eq!(BakaShrot_IsConnected(), 0);
        assert_eq!(get_w(BakaShrot_GetNodeW), "");
        assert_eq!(BakaShrot_QueryW(w("SELECT 1").as_ptr()), 0);
        assert_eq!(error().0, code(ErrorCode::NotConnected));

        // Another identity, by the A exports: not allowed to query.
        assert_eq!(
            BakaShrot_SetCertificateA(a(&file("lounge.crt")).as_ptr()),
            1
        );
        assert_eq!(BakaShrot_SetPrivateKeyA(a(&pem("lounge.key")).as_ptr()), 1);
        assert_eq!(
            BakaShrot_ConnectA(a("localhost").as_ptr(), port),
            1,
            "{:?}",
            error()
        );
        assert_eq!(get_a(BakaShrot_GetNodeA), "lounge");
        assert_eq!(BakaShrot_QueryA(a("SELECT 1").as_ptr()), 0);
        let (failed, why) = error();
        assert_eq!(failed, code(ErrorCode::NotAllowed));
        assert_eq!(get_a(BakaShrot_GetRefusalReasonA), why);
        BakaShrot_Disconnect();

        // Nothing listening there.
        assert_eq!(BakaShrot_ConnectA(a("127.0.0.1").as_ptr(), 1), 0);
        assert_eq!(error().0, code(ErrorCode::ConnectFailed));
    }
}
