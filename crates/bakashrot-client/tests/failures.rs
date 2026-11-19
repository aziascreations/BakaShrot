//! What a failure does to the connection, against a fake server that
//! answers late, wrongly or not at all: a refusal keeps it, anything that
//! leaves it out of step closes it, and nothing is read after (a late
//! answer is never taken for the next request's).

use bakashrot_client::{ANSWER_TIMEOUT, Client, Settings};
use bakashrot_pki::{Ca, Identity, Issued, Revocations, Usage, tls};
use bakashrot_proto::limits::{ATTACHMENT_PART_SIZE, MAX_PACKET_SIZE};
use bakashrot_proto::packets::{
    Attachment, AttachmentPart, Continue, MessagePushed, Pong, RequestRefused, Welcome,
};
use bakashrot_proto::{ErrorCode, Packet, frame};
use rustls::{ServerConnection, StreamOwned};
use std::io::{self, Cursor, Read, Seek, SeekFrom, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::mpsc;
use std::thread::{self, JoinHandle};
use std::time::Duration;

/// The fake server's end of the connection.
type Stream = StreamOwned<ServerConnection, TcpStream>;

/// A fake server for one connection, running its script once the client
/// is welcomed, and the client's certificates.
struct Fake {
    address: String,
    ca: String,
    client: Issued,
    script: Option<JoinHandle<()>>,
}

impl Fake {
    fn start(script: impl FnOnce(&mut Stream) + Send + 'static) -> Fake {
        let ca = Ca::create("Fake CA", 1).unwrap();
        let loaded = Ca::load(&ca.certificate, &ca.key).unwrap();
        let issue = |name: &str, usage| {
            loaded
                .issue(&Identity::new(name, &["sensor"]).unwrap(), usage, 1)
                .unwrap()
        };
        let server = issue("fake", Usage::Server);
        let client = issue("kitchen", Usage::Client);
        let config = tls::server_config(
            &ca.certificate,
            &server.certificate,
            &server.key,
            Revocations::none().shared(),
        )
        .unwrap();
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap().to_string();
        let script = thread::spawn(move || {
            let (tcp, _) = listener.accept().unwrap();
            tcp.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
            let mut stream = StreamOwned::new(ServerConnection::new(config).unwrap(), tcp);
            while stream.conn.is_handshaking() {
                stream.conn.complete_io(&mut stream.sock).unwrap();
            }
            frame::write_version(&mut stream).unwrap();
            frame::read_version(&mut stream).unwrap();
            answer(
                &mut stream,
                Welcome {
                    server: "fake".into(),
                    node: "kitchen".into(),
                },
            );
            script(&mut stream);
        });
        Fake {
            address,
            ca: ca.certificate,
            client,
            script: Some(script),
        }
    }

    fn connect(&self) -> Client {
        Client::connect(
            &self.address,
            &Settings {
                ca: &self.ca,
                certificate: &self.client.certificate,
                key: &self.client.key,
                crl: None,
            },
        )
        .unwrap()
    }

    /// Waits for the script to end (its asserts included).
    fn finish(mut self) {
        self.script.take().unwrap().join().unwrap();
    }
}

/// The client's next packet, none once it closed the connection.
fn request(stream: &mut Stream) -> Option<Packet> {
    let bytes = frame::read(stream, MAX_PACKET_SIZE).ok()??;
    Some(Packet::decode(&bytes).unwrap())
}

fn answer(stream: &mut Stream, packet: impl Into<Packet>) {
    frame::write(stream, &packet.into().encode()).unwrap();
    stream.flush().unwrap();
}

/// Whether the client closed the connection without sending anything
/// more: what the script reports after its answer.
fn nothing_more(stream: &mut Stream) -> bool {
    request(stream).is_none()
}

#[track_caller]
fn fails(result: Result<impl std::fmt::Debug, bakashrot_client::Error>, code: ErrorCode) {
    let error = result.unwrap_err();
    assert_eq!(error.code(), code.code(), "{error}");
}

#[test]
fn a_late_answer_is_never_taken_for_the_next_request() {
    let (report, reported) = mpsc::channel();
    let fake = Fake::start(move |stream| {
        assert!(matches!(request(stream), Some(Packet::PushMessage(_))));
        thread::sleep(Duration::from_millis(600));
        // Too late: the client gave up, and closed.
        let _ = frame::write(
            stream,
            &Packet::from(MessagePushed { message_id: 1 }).encode(),
        );
        let _ = stream.flush();
        report.send(nothing_more(stream)).unwrap();
    });
    let mut client = fake.connect();
    client
        .set_answer_timeout(Duration::from_millis(200))
        .unwrap();
    let error = client.push("logs", "{}").unwrap_err();
    assert_eq!(error.code(), ErrorCode::ConnectionLost.code(), "{error}");
    assert!(
        error.message().contains("no answer within 200ms"),
        "{error}"
    );
    assert!(!client.is_open() && client.is_closed());
    // Once the late answer is there, the next push mustn't read it as its
    // own (it got #1 before).
    thread::sleep(Duration::from_millis(700));
    fails(client.push("logs", "{}"), ErrorCode::NotConnected);
    fails(client.ping(), ErrorCode::NotConnected);
    assert!(reported.recv().unwrap(), "the client sent something more");
    fake.finish();
}

#[test]
fn a_wrong_answer_closes() {
    let (report, reported) = mpsc::channel();
    let fake = Fake::start(move |stream| {
        assert!(matches!(request(stream), Some(Packet::PushMessage(_))));
        answer(stream, Pong {});
        report.send(nothing_more(stream)).unwrap();
    });
    let mut client = fake.connect();
    fails(client.push("logs", "{}"), ErrorCode::ProtocolError);
    assert!(!client.is_open() && client.is_closed());
    fails(client.ping(), ErrorCode::NotConnected);
    assert!(reported.recv().unwrap());
    fake.finish();
}

#[test]
fn a_malformed_answer_closes() {
    let (report, reported) = mpsc::channel();
    let fake = Fake::start(move |stream| {
        assert!(matches!(request(stream), Some(Packet::Ping(_))));
        // 0xc1 is never MessagePack.
        frame::write(stream, &[0xc1]).unwrap();
        stream.flush().unwrap();
        report.send(nothing_more(stream)).unwrap();
    });
    let mut client = fake.connect();
    fails(client.ping(), ErrorCode::ProtocolError);
    fails(client.query("SELECT 1"), ErrorCode::NotConnected);
    assert!(reported.recv().unwrap());
    fake.finish();
}

#[test]
fn an_answer_cut_short_closes() {
    let fake = Fake::start(|stream| {
        assert!(matches!(request(stream), Some(Packet::GetMessages(_))));
        // A frame of 100 bytes, 3 of them sent, then the connection gone.
        stream.write_all(&[100, 0, 0, 0, 1, 2, 3]).unwrap();
        stream.flush().unwrap();
        stream.conn.send_close_notify();
        let _ = stream.conn.complete_io(&mut stream.sock);
    });
    let mut client = fake.connect();
    fails(
        client.get_messages("logs", "kitchen", Some(0), 10),
        ErrorCode::ConnectionLost,
    );
    fails(client.ping(), ErrorCode::NotConnected);
    fake.finish();
}

#[test]
fn a_refusal_keeps_the_connection() {
    let fake = Fake::start(|stream| {
        assert!(matches!(request(stream), Some(Packet::PushMessage(_))));
        answer(
            stream,
            RequestRefused::new(ErrorCode::NotAllowed, "not this topic"),
        );
        assert!(matches!(request(stream), Some(Packet::Ping(_))));
        answer(stream, Pong {});
        assert!(matches!(request(stream), Some(Packet::PushMessage(_))));
        answer(stream, MessagePushed { message_id: 7 });
    });
    let mut client = fake.connect();
    let error = client.push("logs", "{}").unwrap_err();
    assert_eq!(error.code(), ErrorCode::NotAllowed.code());
    assert_eq!(error.message(), "not this topic");
    assert!(client.is_open() && !client.is_closed());
    client.ping().unwrap();
    assert_eq!(client.push("logs", "{}").unwrap(), 7);
    fake.finish();
}

#[test]
fn an_argument_refused_before_sending_keeps_the_connection() {
    let fake = Fake::start(|stream| {
        assert!(matches!(request(stream), Some(Packet::Ping(_))));
        answer(stream, Pong {});
    });
    let mut client = fake.connect();
    fails(client.push("not a name", "{}"), ErrorCode::InvalidArgument);
    fails(
        client.get_messages("logs", "kitchen", Some(0), 0),
        ErrorCode::InvalidArgument,
    );
    fails(
        client.set_answer_timeout(Duration::ZERO),
        ErrorCode::InvalidArgument,
    );
    assert_eq!(client.answer_timeout(), ANSWER_TIMEOUT);
    client.ping().unwrap();
    fake.finish();
}

#[test]
fn a_longer_timeout_waits_for_a_slow_answer() {
    let fake = Fake::start(|stream| {
        assert!(matches!(request(stream), Some(Packet::Ping(_))));
        thread::sleep(Duration::from_millis(500));
        answer(stream, Pong {});
    });
    let mut client = fake.connect();
    client.set_answer_timeout(Duration::from_secs(5)).unwrap();
    assert_eq!(client.answer_timeout(), Duration::from_secs(5));
    client.ping().unwrap();
    fake.finish();
}

/// `is_open()` looks without blocking, then blocks again: the next
/// request waits for its answer, slow as it is.
#[test]
fn is_open_leaves_the_connection_blocking() {
    let fake = Fake::start(|stream| {
        assert!(matches!(request(stream), Some(Packet::Ping(_))));
        thread::sleep(Duration::from_millis(300));
        answer(stream, Pong {});
    });
    let mut client = fake.connect();
    assert!(client.is_open() && !client.is_closed());
    client.ping().unwrap();
    fake.finish();
}

/// The server gone (closed as it closes an idle one: the socket, no TLS
/// close_notify): `is_open()` says so, the next request fails as lost,
/// those after as not connected.
#[test]
fn a_connection_the_server_closed() {
    let fake = Fake::start(|stream| {
        let _ = stream.sock.shutdown(std::net::Shutdown::Both);
    });
    let mut client = fake.connect();
    let address = fake.address.clone();
    fake.finish();
    let mut waited = 0;
    while client.is_open() && waited < 50 {
        thread::sleep(Duration::from_millis(20));
        waited += 1;
    }
    assert!(!client.is_open(), "{address}: still open");
    fails(client.ping(), ErrorCode::ConnectionLost);
    fails(client.ping(), ErrorCode::NotConnected);
}

#[test]
fn a_part_of_the_wrong_size_closes() {
    let (report, reported) = mpsc::channel();
    let fake = Fake::start(move |stream| {
        assert!(matches!(request(stream), Some(Packet::GetAttachment(_))));
        answer(
            stream,
            Attachment {
                size: 10,
                sha256: [0; 32],
            },
        );
        answer(stream, AttachmentPart { data: vec![1; 5] });
        report.send(nothing_more(stream)).unwrap();
    });
    let mut client = fake.connect();
    let mut out = Vec::new();
    fails(
        client.get_attachment("logs", "kitchen", 1, &mut out),
        ErrorCode::ProtocolError,
    );
    fails(client.ping(), ErrorCode::NotConnected);
    assert!(reported.recv().unwrap());
    fake.finish();
}

/// A refusal where a part should be: the parts after it would be read as
/// the next request's answers.
#[test]
fn a_refusal_among_the_parts_closes() {
    let (report, reported) = mpsc::channel();
    let fake = Fake::start(move |stream| {
        assert!(matches!(request(stream), Some(Packet::GetAttachment(_))));
        answer(
            stream,
            Attachment {
                size: ATTACHMENT_PART_SIZE + 1,
                sha256: [0; 32],
            },
        );
        answer(
            stream,
            AttachmentPart {
                data: vec![1; ATTACHMENT_PART_SIZE as usize],
            },
        );
        answer(
            stream,
            RequestRefused::new(ErrorCode::ServerError, "a disk"),
        );
        report.send(nothing_more(stream)).unwrap();
    });
    let mut client = fake.connect();
    let mut out = Vec::new();
    fails(
        client.get_attachment("logs", "kitchen", 1, &mut out),
        ErrorCode::ServerError,
    );
    fails(client.ping(), ErrorCode::NotConnected);
    assert!(reported.recv().unwrap());
    fake.finish();
}

/// Bytes that read the first time through, and fail the second.
struct FailingSecondTime {
    data: Cursor<Vec<u8>>,
    rewinds: usize,
}

impl Read for FailingSecondTime {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        if self.rewinds > 1 {
            return Err(io::Error::other("the disk went away"));
        }
        self.data.read(buffer)
    }
}

impl Seek for FailingSecondTime {
    fn seek(&mut self, to: SeekFrom) -> io::Result<u64> {
        self.rewinds += 1;
        self.data.seek(to)
    }
}

/// The source failing once the server said `Continue`: the server waits
/// for parts that won't come, the connection closes.
#[test]
fn a_source_failing_mid_upload_closes() {
    let (report, reported) = mpsc::channel();
    let fake = Fake::start(move |stream| {
        assert!(matches!(request(stream), Some(Packet::PushMessage(_))));
        answer(stream, Continue {});
        report.send(nothing_more(stream)).unwrap();
    });
    let mut client = fake.connect();
    let mut source = FailingSecondTime {
        data: Cursor::new(vec![7; 100]),
        rewinds: 0,
    };
    let error = client
        .push_with_attachment("logs", "{}", &mut source)
        .unwrap_err();
    assert_eq!(error.code(), ErrorCode::FileError.code(), "{error}");
    assert!(!client.is_open() && client.is_closed());
    fails(client.ping(), ErrorCode::NotConnected);
    assert!(reported.recv().unwrap());
    fake.finish();
}
