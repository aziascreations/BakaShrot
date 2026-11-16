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

use aws_lc_rs::digest;
use bakashrot_pki::{Revocations, tls};
use bakashrot_proto::limits::{
    ALPN, ATTACHMENT_PART_SIZE, MAX_ATTACHMENT_SIZE, MAX_MESSAGE_ID, MAX_MESSAGE_SIZE,
    MAX_MESSAGES_PER_PACKET, MAX_PACKET_SIZE,
};
use bakashrot_proto::names::is_valid_name;
use bakashrot_proto::packets::{
    Attachment, AttachmentPart, GetAttachment, GetMessages, ListNames, Messages, NameKind,
    NamesList, PushMessage, Query,
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
        };
        match client.answer()? {
            Packet::Welcome(welcome) => {
                client.server = welcome.server;
                client.node = welcome.node;
            }
            other => return Err(unexpected(&other)),
        }
        let tcp = &client.stream.sock;
        tcp.set_read_timeout(Some(ANSWER_TIMEOUT)).map_err(lost)?;
        tcp.set_write_timeout(Some(ANSWER_TIMEOUT)).map_err(lost)?;
        Ok(client)
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
        let tcp = &self.stream.sock;
        if tcp.set_nonblocking(true).is_err() {
            return false;
        }
        let open = match tcp.peek(&mut [0]) {
            Ok(read) => read > 0,
            Err(error) => error.kind() == io::ErrorKind::WouldBlock,
        };
        open && tcp.set_nonblocking(false).is_ok()
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
            other => Err(unexpected(&other)),
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
        if !(1..=MAX_ATTACHMENT_SIZE).contains(&size) {
            return Err(Error::new(
                ErrorCode::InvalidArgument,
                format!("an attachment of {size} bytes: 1 to {MAX_ATTACHMENT_SIZE}"),
            ));
        }
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
            other => return Err(unexpected(&other)),
        }
        for part in 0..attachment.part_count() {
            let part = &mut buffer[..attachment.part_len(part) as usize];
            if let Err(error) = source.read_exact(part) {
                self.close();
                return Err(file_error(error));
            }
            let packet = Packet::from(AttachmentPart {
                data: part.to_vec(),
            });
            frame::write(&mut self.stream, &packet.encode()).map_err(lost)?;
        }
        self.stream.flush().map_err(lost)?;
        match self.answer()? {
            Packet::MessagePushed(pushed) => Ok(pushed.message_id),
            other => Err(unexpected(&other)),
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
        if !(1..=MAX_MESSAGE_ID).contains(&message_id) {
            return Err(Error::new(
                ErrorCode::InvalidArgument,
                format!("message {message_id}: 1 to {MAX_MESSAGE_ID}"),
            ));
        }
        let get = GetAttachment {
            topic: topic.to_owned(),
            node: node.to_owned(),
            message_id,
            from_part: 0,
        };
        let attachment = match self.request(get.into())? {
            Packet::Attachment(attachment) => attachment,
            other => return Err(unexpected(&other)),
        };
        let mut sha256 = digest::Context::new(&digest::SHA256);
        // A failing `out`: the parts are still all read, the connection
        // stays usable.
        let mut failed = None;
        for part in 0..attachment.part_count() {
            let data = match self.answer()? {
                Packet::AttachmentPart(part) => part.data,
                other => {
                    self.close();
                    return Err(unexpected(&other));
                }
            };
            let expected = attachment.part_len(part);
            if data.len() as u64 != expected {
                self.close();
                return Err(Error::new(
                    ErrorCode::ProtocolError,
                    format!("part {part}: {} bytes, {expected} expected", data.len()),
                ));
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
        if !(1..=MAX_MESSAGES_PER_PACKET).contains(&limit) {
            return Err(Error::new(
                ErrorCode::InvalidArgument,
                format!("a limit of {limit}: 1 to {MAX_MESSAGES_PER_PACKET}"),
            ));
        }
        if after.is_some_and(|after| after > MAX_MESSAGE_ID) {
            return Err(Error::new(
                ErrorCode::InvalidArgument,
                format!("after {}: {MAX_MESSAGE_ID} at most", after.unwrap_or(0)),
            ));
        }
        let get = GetMessages {
            topic: topic.to_owned(),
            node: node.to_owned(),
            after,
            limit,
        };
        match self.request(get.into())? {
            Packet::Messages(messages) => Ok(messages),
            other => Err(unexpected(&other)),
        }
    }

    /// The topics with messages that this client may push to or read
    /// (every one if it may query), or every node with messages.
    /// `truncated` if some didn't fit.
    pub fn list_names(&mut self, kind: NameKind) -> Result<NamesList> {
        match self.request(ListNames { kind }.into())? {
            Packet::NamesList(names) => Ok(names),
            other => Err(unexpected(&other)),
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
            other => Err(unexpected(&other)),
        }
    }

    /// Closes the connection: it's out of step (a part not sent, or not
    /// as expected). Every request fails then (`ConnectionLost`).
    fn close(&mut self) {
        let _ = self.stream.sock.shutdown(Shutdown::Both);
    }

    /// Sends a request, reads its answer.
    fn request(&mut self, packet: Packet) -> Result<Packet> {
        frame::write(&mut self.stream, &packet.encode()).map_err(lost)?;
        self.stream.flush().map_err(lost)?;
        self.answer()
    }

    /// Reads the server's next packet: a refusal is an error.
    fn answer(&mut self) -> Result<Packet> {
        let bytes = frame::read(&mut self.stream, MAX_PACKET_SIZE)
            .map_err(lost)?
            .ok_or_else(|| {
                Error::new(
                    ErrorCode::ConnectionLost,
                    "the server closed the connection",
                )
            })?;
        match Packet::decode(&bytes) {
            Ok(Packet::RequestRefused(refused)) => Err(Error {
                code: refused.code,
                message: refused.reason,
            }),
            Ok(packet) => Ok(packet),
            Err(error) => Err(Error::new(ErrorCode::ProtocolError, error.to_string())),
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

fn check_name(name: &str, what: &str) -> Result<()> {
    if is_valid_name(name) {
        Ok(())
    } else {
        Err(Error::new(
            ErrorCode::InvalidArgument,
            format!("'{name}' isn't a {what} name"),
        ))
    }
}

fn check_size(text: &str, what: &str) -> Result<()> {
    if text.len() <= MAX_MESSAGE_SIZE {
        Ok(())
    } else {
        Err(Error::new(
            ErrorCode::InvalidArgument,
            format!("{what} of {} bytes: {MAX_MESSAGE_SIZE} at most", text.len()),
        ))
    }
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
