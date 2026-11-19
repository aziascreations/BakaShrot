//! BakaShrot's client: one connection to a server, blocking, one request
//! at a time (no async runtime: the C DLL wraps this as it is).
//!
//! ```no_run
//! # fn main() -> Result<(), bakashrot_client::Error> {
//! use bakashrot_client::{Client, Settings};
//! let (ca, certificate, key) = (String::new(), String::new(), String::new()); // PEM
//! let settings = Settings { ca: &ca, certificate: &certificate, key: &key, crl: None };
//! let mut client = Client::connect("10.0.0.2:7000", &settings)?;
//! let id = client.push("logs", r#"{"temp": 21}"#)?;
//! let node = client.node().to_owned();
//! let latest = client.get_messages("logs", &node, None, 1)?;
//! # Ok(()) }
//! ```
//!
//! The connection: TLS 1.3 with the CA's certificates (`bakashrot-pki`),
//! ALPN `bakashrot`, both ends' protocol versions, then the server's
//! `Welcome` (`docs/protocol.md`). Errors carry the protocol's codes
//! (`bakashrot_proto::ErrorCode`): a server's refusal keeps its own.
//!
//! **A failure that leaves the connection out of step closes it:** an
//! I/O error, an answer that didn't come in time ([`Client::answer_timeout`]),
//! one that isn't the request's, a part cut short. Every request after
//! fails with `NotConnected` at once, without reading: a late answer is
//! never taken for the next request's. Connect again. A refusal, or an
//! argument refused before sending, keeps it.

use aws_lc_rs::digest;
use bakashrot_pki::{Revocations, tls};
use bakashrot_proto::limits::{
    ALPN, ATTACHMENT_PART_SIZE, MAX_ATTACHMENT_SIZE, MAX_MESSAGE_ID, MAX_MESSAGE_SIZE,
    MAX_MESSAGES_PER_PACKET, MAX_PACKET_SIZE,
};
use bakashrot_proto::names::{is_valid_name, is_valid_name_or_pattern};
use bakashrot_proto::packets::{
    Attachment, AttachmentPart, GetAttachment, GetMessages, ListNames, Messages, NameKind,
    NamesList, Ping, PushMessage, Query,
};
use bakashrot_proto::{ErrorCode, Packet, frame};
use rustls::{ClientConnection, StreamOwned};
use std::fmt;
use std::fs::{self, File};
use std::io::{self, Read, Seek, Write};
use std::net::{Shutdown, TcpStream, ToSocketAddrs};
use std::path::{Path, PathBuf};
use std::time::Duration;

/// How long connecting may take: TCP, TLS, the versions, the welcome.
pub const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);

/// How long an answer may take.
pub const ANSWER_TIMEOUT: Duration = Duration::from_secs(30);

/// What a client connects with, PEM text as files hold it.
#[derive(Debug, Clone, Copy)]
pub struct Settings<'a> {
    /// The CA's certificate: servers are taken if it issued theirs.
    pub ca: &'a str,
    /// This client's certificate: its node, its roles.
    pub certificate: &'a str,
    /// Its key.
    pub key: &'a str,
    /// The CA's CRL, if given: servers it revokes are refused.
    pub crl: Option<&'a str>,
}

/// What went wrong: a protocol error code (a server's refusal, 1-99, or
/// the client's own, 100 and up) and why.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Error {
    code: u32,
    message: String,
}

impl Error {
    /// An error of `code`, saying why.
    pub fn new(code: ErrorCode, message: impl Into<String>) -> Error {
        Error {
            code: code.code(),
            message: message.into(),
        }
    }

    /// Its code (`bakashrot_proto::error`).
    pub fn code(&self) -> u32 {
        self.code
    }

    /// Why, in words.
    pub fn message(&self) -> &str {
        &self.message
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let name = bakashrot_proto::error::code_name(self.code);
        write!(f, "{} ({}): {}", name, self.code, self.message)
    }
}

impl std::error::Error for Error {}

/// A result of this crate.
pub type Result<T> = std::result::Result<T, Error>;

/// A connection to a server.
pub struct Client {
    stream: StreamOwned<ClientConnection, TcpStream>,
    server: String,
    node: String,
    /// How long an answer may take: [`ANSWER_TIMEOUT`] until changed.
    answer_timeout: Duration,
    /// Closed, after a failure that left it out of step: requests fail
    /// with `NotConnected`.
    closed: bool,
}

impl fmt::Debug for Client {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Client")
            .field("server", &self.server)
            .field("node", &self.node)
            .finish_non_exhaustive()
    }
}

impl Client {
    /// Connects to the server at `address` (`host:port`): any of the CA's
    /// servers, whatever its address.
    pub fn connect(address: &str, settings: &Settings<'_>) -> Result<Client> {
        let invalid = |what: &str| {
            let what = what.to_owned();
            move |error: bakashrot_pki::Error| {
                Error::new(ErrorCode::InvalidArgument, format!("{what}: {error}"))
            }
        };
        let revocations = match settings.crl {
            Some(crl) => Revocations::load(crl, settings.ca).map_err(invalid("the CRL"))?,
            None => Revocations::none(),
        };
        let config = tls::client_config(
            settings.ca,
            settings.certificate,
            settings.key,
            revocations.shared(),
        )
        .map_err(invalid("the certificates"))?;

        let tcp = connect_tcp(address)?;
        let connection = ClientConnection::new(config, tls::server_name())
            .map_err(|error| Error::new(ErrorCode::InvalidArgument, error.to_string()))?;
        let mut stream = StreamOwned::new(connection, tcp);
        while stream.conn.is_handshaking() {
            stream.conn.complete_io(&mut stream.sock).map_err(lost)?;
        }
        if stream.conn.alpn_protocol() != Some(ALPN) {
            return Err(Error::new(
                ErrorCode::AuthRejected,
                "the server doesn't speak BakaShrot",
            ));
        }

        frame::write_version(&mut stream).map_err(lost)?;
        stream.flush().map_err(lost)?;
        let theirs = frame::read_version(&mut stream).map_err(lost)?;
        if let Err(version) = frame::check_version(theirs) {
            return Err(Error::new(
                ErrorCode::VersionMismatch,
                format!(
                    "the server speaks protocol {version}, this client {}",
                    bakashrot_proto::limits::PROTOCOL_VERSION
                ),
            ));
        }

        let mut client = Client {
            stream,
            server: String::new(),
            node: String::new(),
            answer_timeout: CONNECT_TIMEOUT,
            closed: false,
        };
        match client.answer()? {
            Packet::Welcome(welcome) => {
                client.server = welcome.server;
                client.node = welcome.node;
            }
            other => return Err(client.unexpected(&other)),
        }
        client.set_answer_timeout(ANSWER_TIMEOUT)?;
        Ok(client)
    }

    /// How long an answer may take before its request fails
    /// (`ConnectionLost`, the connection closed): [`ANSWER_TIMEOUT`] (30 s)
    /// until changed.
    pub fn answer_timeout(&self) -> Duration {
        self.answer_timeout
    }

    /// Sets how long an answer may take, more than 0: longer for a slow
    /// query, say. It's also how long sending a packet may take. Past it,
    /// the request fails and the connection is closed (a late answer would
    /// be taken for the next request's).
    pub fn set_answer_timeout(&mut self, timeout: Duration) -> Result<()> {
        require(!timeout.is_zero(), || "an answer timeout of 0".to_owned())?;
        self.check_open()?;
        let tcp = &self.stream.sock;
        let set = tcp
            .set_read_timeout(Some(timeout))
            .and_then(|()| tcp.set_write_timeout(Some(timeout)));
        set.map_err(|error| self.io_failed(error))?;
        self.answer_timeout = timeout;
        Ok(())
    }

    /// The server's name.
    pub fn server(&self) -> &str {
        &self.server
    }

    /// The node this client writes as: its certificate's name.
    pub fn node(&self) -> &str {
        &self.node
    }

    /// Whether the connection still looks open: the server hasn't closed
    /// it (after its idle timeout, say). Only a request tells for sure.
    pub fn is_open(&self) -> bool {
        if self.closed {
            return false;
        }
        let tcp = &self.stream.sock;
        if tcp.set_nonblocking(true).is_err() {
            return false;
        }
        let open = match tcp.peek(&mut [0]) {
            Ok(read) => read > 0,
            Err(error) => error.kind() == io::ErrorKind::WouldBlock,
        };
        // Blocking again whatever it found: the next request waits for
        // its answer.
        let blocking = tcp.set_nonblocking(false).is_ok();
        open && blocking
    }

    /// Whether a failure closed the connection: every request fails with
    /// `NotConnected` now, connect again. Unlike [`Client::is_open`], it
    /// doesn't look at the socket.
    pub fn is_closed(&self) -> bool {
        self.closed
    }

    /// Keeps the connection open: the server closes one silent for
    /// `IDLE_TIMEOUT_SECS` (5 min). An app waiting longer than that
    /// between requests calls this every `KEEPALIVE_SECS` (1 min) or so.
    pub fn ping(&mut self) -> Result<()> {
        match self.request(Ping {}.into())? {
            Packet::Pong(_) => Ok(()),
            other => Err(self.unexpected(&other)),
        }
    }

    /// Pushes a message to `topic`, as this client's node: its id.
    pub fn push(&mut self, topic: &str, data: &str) -> Result<u64> {
        check_name(topic, "topic")?;
        check_size(data, "a message")?;
        let push = PushMessage {
            topic: topic.to_owned(),
            data: data.to_owned(),
            attachment: None,
        };
        match self.request(push.into())? {
            Packet::MessagePushed(pushed) => Ok(pushed.message_id),
            other => Err(self.unexpected(&other)),
        }
    }

    /// Pushes a message with an attachment read from `source` (a `File`, a
    /// `Cursor` over bytes), from its start to its end: twice, for its
    /// SHA-256, then to send it (a source changed in between is refused,
    /// `DataMismatch`). 1 byte to `MAX_ATTACHMENT_SIZE` (servers may take
    /// less, `TooBig`). A source failing while it's sent closes the
    /// connection (`FileError`).
    pub fn push_with_attachment(
        &mut self,
        topic: &str,
        data: &str,
        source: &mut (impl Read + Seek),
    ) -> Result<u64> {
        check_name(topic, "topic")?;
        check_size(data, "a message")?;
        source.rewind().map_err(file_error)?;
        let mut sha256 = digest::Context::new(&digest::SHA256);
        let mut buffer = vec![0; ATTACHMENT_PART_SIZE as usize];
        let mut size = 0;
        loop {
            let read = source.read(&mut buffer).map_err(file_error)?;
            if read == 0 {
                break;
            }
            sha256.update(&buffer[..read]);
            size += read as u64;
        }
        require((1..=MAX_ATTACHMENT_SIZE).contains(&size), || {
            format!("an attachment of {size} bytes: 1 to {MAX_ATTACHMENT_SIZE}")
        })?;
        source.rewind().map_err(file_error)?;
        let mut digest = [0; 32];
        digest.copy_from_slice(sha256.finish().as_ref());
        let attachment = Attachment {
            size,
            sha256: digest,
        };
        let push = PushMessage {
            topic: topic.to_owned(),
            data: data.to_owned(),
            attachment: Some(attachment.clone()),
        };
        match self.request(push.into())? {
            Packet::Continue(_) => {}
            other => return Err(self.unexpected(&other)),
        }
        for part in 0..attachment.part_count() {
            let part = &mut buffer[..attachment.part_len(part) as usize];
            if let Err(error) = source.read_exact(part) {
                // The server waits for parts that won't come.
                return Err(self.out_of_step(file_error(error)));
            }
            self.send(&Packet::from(AttachmentPart {
                data: part.to_vec(),
            }))?;
        }
        self.flush()?;
        match self.answer()? {
            Packet::MessagePushed(pushed) => Ok(pushed.message_id),
            other => Err(self.unexpected(&other)),
        }
    }

    /// Writes a message's attachment into `out`, a part at a time, checked
    /// with its SHA-256 once all came (`AttachmentMismatch`): its size.
    /// What `out` has when it fails is to be thrown away.
    pub fn get_attachment(
        &mut self,
        topic: &str,
        node: &str,
        message_id: u64,
        out: &mut impl Write,
    ) -> Result<u64> {
        check_name(topic, "topic")?;
        check_name(node, "node")?;
        require((1..=MAX_MESSAGE_ID).contains(&message_id), || {
            format!("message {message_id}: 1 to {MAX_MESSAGE_ID}")
        })?;
        let get = GetAttachment {
            topic: topic.to_owned(),
            node: node.to_owned(),
            message_id,
            from_part: 0,
        };
        let attachment = match self.request(get.into())? {
            Packet::Attachment(attachment) => attachment,
            other => return Err(self.unexpected(&other)),
        };
        let mut sha256 = digest::Context::new(&digest::SHA256);
        // A failing `out`: the parts are still all read, the connection
        // stays usable.
        let mut failed = None;
        for part in 0..attachment.part_count() {
            // Parts come without a request each: anything else, a refusal
            // too, leaves the rest of them unread.
            let data = match self.answer() {
                Ok(Packet::AttachmentPart(part)) => part.data,
                Ok(other) => return Err(self.unexpected(&other)),
                Err(error) => return Err(self.out_of_step(error)),
            };
            let expected = attachment.part_len(part);
            if data.len() as u64 != expected {
                return Err(self.out_of_step(Error::new(
                    ErrorCode::ProtocolError,
                    format!("part {part}: {} bytes, {expected} expected", data.len()),
                )));
            }
            sha256.update(&data);
            if failed.is_none() {
                failed = out.write_all(&data).err();
            }
        }
        if let Some(error) = failed {
            return Err(file_error(error));
        }
        out.flush().map_err(file_error)?;
        if sha256.finish().as_ref() != attachment.sha256 {
            return Err(Error::new(
                ErrorCode::AttachmentMismatch,
                "the attachment doesn't match its SHA-256",
            ));
        }
        Ok(attachment.size)
    }

    /// Saves a message's attachment as `path` ([`Client::get_attachment`]):
    /// written aside (`path` and `.download`), then moved over it, so a
    /// failed one leaves no file.
    pub fn save_attachment(
        &mut self,
        topic: &str,
        node: &str,
        message_id: u64,
        path: &Path,
    ) -> Result<u64> {
        let mut aside = path.as_os_str().to_owned();
        aside.push(".download");
        let aside = PathBuf::from(aside);
        let mut file = File::create(&aside).map_err(file_error)?;
        let saved = self.get_attachment(topic, node, message_id, &mut file);
        drop(file);
        let saved = saved.and_then(|size| {
            fs::rename(&aside, path).map_err(file_error)?;
            Ok(size)
        });
        if saved.is_err() {
            let _ = fs::remove_file(&aside);
        }
        saved
    }

    /// A topic and node's messages: `after` an id (0 for the first ones),
    /// or the last ones (`None`); `limit` at most (1-10000). `more` if
    /// others follow.
    pub fn get_messages(
        &mut self,
        topic: &str,
        node: &str,
        after: Option<u64>,
        limit: u32,
    ) -> Result<Messages> {
        check_name(topic, "topic")?;
        check_name(node, "node")?;
        require((1..=MAX_MESSAGES_PER_PACKET).contains(&limit), || {
            format!("a limit of {limit}: 1 to {MAX_MESSAGES_PER_PACKET}")
        })?;
        require(after.is_none_or(|after| after <= MAX_MESSAGE_ID), || {
            format!("after {}: {MAX_MESSAGE_ID} at most", after.unwrap_or(0))
        })?;
        let get = GetMessages {
            topic: topic.to_owned(),
            node: node.to_owned(),
            after,
            limit,
        };
        match self.request(get.into())? {
            Packet::Messages(messages) => Ok(messages),
            other => Err(self.unexpected(&other)),
        }
    }

    /// The topics with messages that this client may push to or read, or
    /// the nodes with messages in the topics it may read; every one if its
    /// roles have `list_topics` / `list_nodes`, or `query`. `topics` and
    /// `nodes` (a name or a pattern, `None` for any) keep those of the
    /// topic and node pairs they match: the topics a node pushed to, the
    /// nodes that pushed to a topic. `truncated` if some didn't fit.
    pub fn list_names(
        &mut self,
        kind: NameKind,
        topics: Option<&str>,
        nodes: Option<&str>,
    ) -> Result<NamesList> {
        for (filter, what) in [(topics, "topic"), (nodes, "node")] {
            if let Some(filter) = filter {
                require(is_valid_name_or_pattern(filter), || {
                    format!("'{filter}' isn't a {what} name or pattern")
                })?;
            }
        }
        let list = ListNames {
            kind,
            topics: topics.map(str::to_owned),
            nodes: nodes.map(str::to_owned),
        };
        match self.request(list.into())? {
            Packet::NamesList(names) => Ok(names),
            other => Err(self.unexpected(&other)),
        }
    }

    /// Runs read-only SQL: `{"columns":[...],"rows":[[...],...]}`, every
    /// value a string or null (`docs/storage.md`, "The query surface").
    pub fn query(&mut self, sql: &str) -> Result<String> {
        check_size(sql, "a query")?;
        let query = Query {
            sql: sql.to_owned(),
        };
        match self.request(query.into())? {
            Packet::QueryResult(result) => Ok(result.json),
            other => Err(self.unexpected(&other)),
        }
    }

    /// Closes the connection for good: every request fails then
    /// (`NotConnected`).
    fn close(&mut self) {
        self.closed = true;
        let _ = self.stream.sock.shutdown(Shutdown::Both);
    }

    /// `NotConnected` once closed.
    fn check_open(&self) -> Result<()> {
        match self.closed {
            false => Ok(()),
            true => Err(Error::new(
                ErrorCode::NotConnected,
                "the connection was closed after an earlier failure: connect again",
            )),
        }
    }

    /// `error`, which left the connection out of step: closed.
    fn out_of_step(&mut self, error: Error) -> Error {
        self.close();
        error
    }

    /// An I/O error on the connection: closed. A timeout says so (its
    /// answer may still come, after the next request).
    fn io_failed(&mut self, error: io::Error) -> Error {
        let timed_out = matches!(
            error.kind(),
            io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
        );
        let error = match timed_out {
            true => Error::new(
                ErrorCode::ConnectionLost,
                format!(
                    "no answer within {:?}: the connection is closed",
                    self.answer_timeout
                ),
            ),
            false => lost(error),
        };
        self.out_of_step(error)
    }

    /// An answer that isn't the request's: `ProtocolError`, closed.
    fn unexpected(&mut self, packet: &Packet) -> Error {
        self.out_of_step(unexpected(packet))
    }

    /// Writes a packet's frame (not flushed).
    fn send(&mut self, packet: &Packet) -> Result<()> {
        self.check_open()?;
        // Refused before anything is written: the connection stays.
        let frame = frame::encode(&packet.encode())
            .map_err(|error| Error::new(ErrorCode::InvalidArgument, error.to_string()))?;
        let written = self.stream.write_all(&frame);
        written.map_err(|error| self.io_failed(error))
    }

    fn flush(&mut self) -> Result<()> {
        let flushed = self.stream.flush();
        flushed.map_err(|error| self.io_failed(error))
    }

    /// Sends a request, reads its answer.
    fn request(&mut self, packet: Packet) -> Result<Packet> {
        self.send(&packet)?;
        self.flush()?;
        self.answer()
    }

    /// Reads the server's next packet: a refusal is an error (the
    /// connection kept), anything else wrong closes it.
    fn answer(&mut self) -> Result<Packet> {
        self.check_open()?;
        let bytes = match frame::read(&mut self.stream, MAX_PACKET_SIZE) {
            Ok(Some(bytes)) => bytes,
            Ok(None) => {
                return Err(self.out_of_step(Error::new(
                    ErrorCode::ConnectionLost,
                    "the server closed the connection",
                )));
            }
            Err(error) => return Err(self.io_failed(error)),
        };
        match Packet::decode(&bytes) {
            Ok(Packet::RequestRefused(refused)) => Err(Error {
                code: refused.code,
                message: refused.reason,
            }),
            Ok(packet) => Ok(packet),
            Err(error) => {
                Err(self.out_of_step(Error::new(ErrorCode::ProtocolError, error.to_string())))
            }
        }
    }
}

/// A TCP connection to the first of `address`'s addresses that answers.
fn connect_tcp(address: &str) -> Result<TcpStream> {
    let failed = |why: String| Error::new(ErrorCode::ConnectFailed, format!("{address}: {why}"));
    let addresses = address
        .to_socket_addrs()
        .map_err(|error| failed(error.to_string()))?;
    let mut last = String::from("no address");
    for socket in addresses {
        match TcpStream::connect_timeout(&socket, CONNECT_TIMEOUT) {
            Ok(tcp) => {
                tcp.set_nodelay(true).map_err(lost)?;
                tcp.set_read_timeout(Some(CONNECT_TIMEOUT)).map_err(lost)?;
                tcp.set_write_timeout(Some(CONNECT_TIMEOUT)).map_err(lost)?;
                return Ok(tcp);
            }
            Err(error) => last = error.to_string(),
        }
    }
    Err(failed(last))
}

/// An I/O error's code: the TLS ones say who refused whom.
fn lost(error: io::Error) -> Error {
    let tls = error
        .get_ref()
        .and_then(|inner| inner.downcast_ref::<rustls::Error>());
    match tls {
        Some(rustls::Error::InvalidCertificate(why)) => Error::new(
            ErrorCode::ServerNotVerified,
            format!("the server's certificate: {why:?}"),
        ),
        Some(rustls::Error::AlertReceived(alert)) => Error::new(
            ErrorCode::AuthRejected,
            format!("the server refused this client's certificate ({alert:?})"),
        ),
        Some(other) => Error::new(ErrorCode::AuthRejected, other.to_string()),
        None => Error::new(ErrorCode::ConnectionLost, error.to_string()),
    }
}

/// An argument checked before sending: `InvalidArgument`, saying `why`,
/// if it isn't `ok`.
fn require(ok: bool, why: impl FnOnce() -> String) -> Result<()> {
    match ok {
        true => Ok(()),
        false => Err(Error::new(ErrorCode::InvalidArgument, why())),
    }
}

fn check_name(name: &str, what: &str) -> Result<()> {
    require(is_valid_name(name), || {
        format!("'{name}' isn't a {what} name")
    })
}

fn check_size(text: &str, what: &str) -> Result<()> {
    require(text.len() <= MAX_MESSAGE_SIZE, || {
        format!("{what} of {} bytes: {MAX_MESSAGE_SIZE} at most", text.len())
    })
}

fn file_error(error: io::Error) -> Error {
    Error::new(ErrorCode::FileError, format!("the attachment: {error}"))
}

fn unexpected(packet: &Packet) -> Error {
    Error::new(
        ErrorCode::ProtocolError,
        format!("the server answered {}", packet.packet_type().name()),
    )
}
