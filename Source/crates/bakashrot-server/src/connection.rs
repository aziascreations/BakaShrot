//! One connection: TLS, the versions, who it is, then its requests, one at
//! a time (`Source/docs/protocol.md`).

use crate::writer::Write;
use crate::{Shared, accept_from, now};
use aws_lc_rs::digest;
use bakashrot_config::Permissions;
use bakashrot_pki::Identity;
use bakashrot_proto::limits::{MAX_MESSAGE_SIZE, MAX_NAMES_LIST_ENTRIES, MAX_PACKET_SIZE};
use bakashrot_proto::names::names_equal;
use bakashrot_proto::packets::{
    Attachment, AttachmentPart, Continue, GetAttachment, GetMessages, ListNames, MessagePushed,
    Messages, NameKind, NamesList, PushMessage, Query, QueryResult, RequestRefused, Welcome,
};
use bakashrot_proto::{ErrorCode, Packet, frame};
use bakashrot_storage::AttachmentState;
use futures_util::{SinkExt, StreamExt};
use std::collections::VecDeque;
use std::net::{IpAddr, SocketAddr};
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::time::timeout;
use tokio_rustls::server::TlsStream;
use tokio_util::codec::{Framed, LengthDelimitedCodec};
use tracing::{debug, info};

/// How long TLS and the versions may take.
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(10);

/// How long a connection may stay silent between requests.
const IDLE_TIMEOUT: Duration = Duration::from_secs(300);

/// How long an attachment's next part may take to come.
const PART_TIMEOUT: Duration = Duration::from_secs(30);

/// An upload's parts given to the writer and not written yet, at most: the
/// next ones wait (the client with them, through TCP).
const PARTS_IN_FLIGHT: usize = 4;

pub(crate) type Frames = Framed<TlsStream<TcpStream>, LengthDelimitedCodec>;

/// Serves one connection until it ends, logging why.
pub(crate) async fn handle(shared: Arc<Shared>, tcp: TcpStream, peer: SocketAddr) {
    match serve(&shared, tcp, peer.ip()).await {
        Ok(node) => debug!("{peer} ({node}): closed"),
        Err(why) => info!("{peer}: {why}"),
    }
}

/// Who it is once checked: its node, its certificate's serial (for later
/// revocations), what it may do, where it connects from.
pub(crate) struct Peer {
    pub(crate) node: String,
    serial: Vec<u8>,
    pub(crate) permissions: Permissions,
    pub(crate) address: IpAddr,
    /// Whether `accept_from` has it, once a replication request asked.
    pub(crate) accepted: Option<bool>,
}

async fn serve(shared: &Arc<Shared>, tcp: TcpStream, address: IpAddr) -> Result<String, String> {
    tcp.set_nodelay(true).map_err(|error| error.to_string())?;
    let (mut frames, mut peer) = timeout(HANDSHAKE_TIMEOUT, open(shared, tcp, address))
        .await
        .map_err(|_| "too slow to connect".to_owned())??;
    debug!("{} connected", peer.node);

    loop {
        let bytes = match timeout(IDLE_TIMEOUT, frames.next()).await {
            Err(_) => return Err(format!("{}: idle too long", peer.node)),
            Ok(None) => return Ok(peer.node),
            Ok(Some(bytes)) => bytes.map_err(|error| format!("{}: {error}", peer.node))?,
        };
        let revoked = shared
            .revocations
            .read()
            .map_or(true, |revocations| revocations.revokes_serial(&peer.serial));
        if revoked {
            return Err(format!("{}: its certificate was revoked", peer.node));
        }
        let packet = Packet::decode(&bytes).map_err(|error| format!("{}: {error}", peer.node))?;
        let failed = |why: String| format!("{}: {why}", peer.node);
        let answer = match packet {
            Packet::PushMessage(push) => self::push(shared, &peer, &mut frames, push)
                .await
                .map_err(failed)?,
            Packet::GetAttachment(get) => {
                match get_attachment(shared, &peer, &mut frames, get)
                    .await
                    .map_err(failed)?
                {
                    Some(refusal) => refusal,
                    None => continue,
                }
            }
            Packet::GetMessages(get) => get_messages(shared, &peer, get).await,
            Packet::ListNames(list) => list_names(shared, &peer, list).await,
            Packet::Query(query) => self::query(shared, &peer, query).await,
            Packet::SyncStateRequest(_) => accept_from::sync_state(shared, &mut peer).await,
            Packet::ReplicateMessages(batch) => {
                accept_from::replicate_messages(shared, &mut peer, batch).await
            }
            Packet::ReplicateAttachment(request) => {
                accept_from::replicate_attachment(shared, &mut peer, &mut frames, request)
                    .await
                    .map_err(|why| format!("{}: {why}", peer.node))?
            }
            other => {
                return Err(format!(
                    "{}: sent {}, not a request",
                    peer.node,
                    other.packet_type().name()
                ));
            }
        };
        send(&mut frames, answer)
            .await
            .map_err(|error| format!("{}: {error}", peer.node))?;
    }
}

/// After a refused handshake (its alert sent): a close the client reads,
/// not a reset that can beat the alert to it. In TLS 1.3 the client has
/// already sent its version when the server refuses its certificate, and
/// a socket closed with data unread is reset (Windows drops what the
/// client hadn't read yet then). So: shut down, and read until the client
/// closes, 1 s at most.
async fn close_gently(mut tcp: TcpStream) {
    let _ = tcp.shutdown().await;
    let mut unread = [0; 1024];
    let _ = timeout(Duration::from_secs(1), async {
        while tcp.read(&mut unread).await.is_ok_and(|read| read > 0) {}
    })
    .await;
}

/// TLS, the versions, the identity, the welcome (or the refusal).
async fn open(
    shared: &Arc<Shared>,
    tcp: TcpStream,
    address: IpAddr,
) -> Result<(Frames, Peer), String> {
    let mut stream = match shared.acceptor.accept(tcp).into_fallible().await {
        Ok(stream) => stream,
        Err((error, tcp)) => {
            close_gently(tcp).await;
            return Err(format!("TLS: {error}"));
        }
    };

    stream
        .write_all(&frame::version_bytes())
        .await
        .map_err(|error| error.to_string())?;
    stream.flush().await.map_err(|error| error.to_string())?;
    let mut theirs = [0; frame::VERSION_SIZE];
    stream
        .read_exact(&mut theirs)
        .await
        .map_err(|error| error.to_string())?;
    frame::check_version(theirs).map_err(|version| format!("speaks protocol {version}"))?;

    let (_, connection) = stream.get_ref();
    let certificate = connection
        .peer_certificates()
        .and_then(<[_]>::first)
        .map(|certificate| certificate.to_vec())
        .unwrap_or_default();
    let identity = Identity::from_certificate(&certificate).map_err(|error| error.to_string())?;
    let serial = bakashrot_pki::serial(&certificate).map_err(|error| error.to_string())?;
    let mut frames = Framed::new(stream, frame::codec(MAX_PACKET_SIZE));

    let Some(permissions) = shared.config.permissions(&identity.roles) else {
        let refused = RequestRefused::new(
            ErrorCode::NotAllowed,
            format!(
                "none of {}'s roles ({}) is allowed on this server",
                identity.name,
                identity.roles.join(", ")
            ),
        );
        let _ = send(&mut frames, refused.into()).await;
        return Err(format!(
            "{}: refused, none of its roles is allowed",
            identity.name
        ));
    };
    let welcome = Welcome {
        server: shared.name.clone(),
        node: identity.name.clone(),
    };
    send(&mut frames, welcome.into())
        .await
        .map_err(|error| error.to_string())?;
    Ok((
        frames,
        Peer {
            node: identity.name,
            serial,
            permissions,
            address,
            accepted: None,
        },
    ))
}

/// A push, with its attachment's parts if it has one. An error closes the
/// connection.
async fn push(
    shared: &Arc<Shared>,
    peer: &Peer,
    frames: &mut Frames,
    push: PushMessage,
) -> Result<Packet, String> {
    if !shared.config.server.has_topic(&push.topic) {
        return Ok(refused(
            ErrorCode::UnknownName,
            format!("unknown topic '{}'", push.topic),
        ));
    }
    if !peer.permissions.can_push(&push.topic) {
        return Ok(refused(
            ErrorCode::NotAllowed,
            format!("{} may not push to '{}'", peer.node, push.topic),
        ));
    }
    if push.data.len() > MAX_MESSAGE_SIZE {
        return Ok(refused(
            ErrorCode::TooBig,
            format!(
                "a message of {} bytes: {MAX_MESSAGE_SIZE} at most",
                push.data.len()
            ),
        ));
    }
    let PushMessage {
        topic,
        data,
        attachment,
    } = push;
    let Some(attachment) = attachment else {
        let write = Write::Push {
            topic,
            node: peer.node.clone(),
            pushed_at: now(),
            data,
        };
        return Ok(pushed(shared.pushes.send(write).await));
    };

    let max = shared.config.server.max_attachment_size;
    if attachment.size > max {
        return Ok(refused(
            ErrorCode::TooBig,
            format!(
                "an attachment of {} bytes: {max} at most on this server",
                attachment.size
            ),
        ));
    }
    let start = Write::StartUpload {
        size: attachment.size,
        sha256: attachment.sha256,
    };
    let upload = match shared.pushes.send(start).await {
        Ok(upload) => upload,
        Err(refusal) => return Ok(refusal.into()),
    };
    let sha256 = digest::Context::new(&digest::SHA256);
    let received = match send(frames, Continue {}.into()).await {
        Ok(()) => receive_parts(shared, frames, upload, &attachment, 0, sha256).await,
        Err(error) => Err(error.to_string()),
    };
    let refusal = match received {
        Ok(None) => {
            let write = Write::PushWithUpload {
                upload,
                topic,
                node: peer.node.clone(),
                pushed_at: now(),
                data,
            };
            match shared.pushes.send(write).await {
                Ok(message_id) => return Ok(MessagePushed { message_id }.into()),
                Err(refusal) => Ok(refusal),
            }
        }
        Ok(Some(refusal)) => Ok(refusal),
        Err(why) => Err(why),
    };
    // Not pushed: the upload goes (queued after its parts).
    drop(shared.pushes.send(Write::CancelUpload { upload }));
    refusal.map(Packet::from)
}

/// Reads an attachment's parts from `from_part` on (an upload's, or a
/// replicated one's), has the writer store them while the next ones come,
/// checks the SHA-256 (`sha256` has the parts before): the refusal if one
/// is due (the parts all read even then; `DataMismatch` for the SHA-256),
/// an error if the connection must close.
pub(crate) async fn receive_parts(
    shared: &Arc<Shared>,
    frames: &mut Frames,
    upload: u64,
    attachment: &Attachment,
    from_part: u64,
    mut sha256: digest::Context,
) -> Result<Option<RequestRefused>, String> {
    let mut writing = VecDeque::new();
    let mut refusal = None;
    for part in from_part..attachment.part_count() {
        let bytes = match timeout(PART_TIMEOUT, frames.next()).await {
            Err(_) => return Err(format!("part {part} of an attachment: too slow")),
            Ok(None) => return Err(format!("closed at part {part} of an attachment")),
            Ok(Some(bytes)) => bytes.map_err(|error| error.to_string())?,
        };
        let Packet::AttachmentPart(AttachmentPart { data }) =
            Packet::decode(&bytes).map_err(|error| error.to_string())?
        else {
            return Err(format!(
                "sent something else than part {part} of an attachment"
            ));
        };
        if refusal.is_some() {
            continue;
        }
        let expected = attachment.part_len(part);
        if data.len() as u64 != expected {
            refusal = Some(RequestRefused::new(
                ErrorCode::InvalidRequest,
                format!("part {part}: {} bytes, {expected} expected", data.len()),
            ));
            continue;
        }
        sha256.update(&data);
        writing.push_back(shared.pushes.send(Write::Part { upload, part, data }));
        if writing.len() >= PARTS_IN_FLIGHT
            && let Some(written) = writing.pop_front()
            && let Err(refused) = written.await
        {
            refusal = Some(refused);
        }
    }
    for written in writing {
        if let Err(refused) = written.await {
            refusal.get_or_insert(refused);
        }
    }
    if refusal.is_none() && sha256.finish().as_ref() != attachment.sha256 {
        refusal = Some(RequestRefused::new(
            ErrorCode::DataMismatch,
            "the attachment doesn't match its SHA-256",
        ));
    }
    Ok(refusal)
}

/// A message's attachment: its size and SHA-256, then its parts from
/// `from_part`, sent here; or the refusal to send. An error (a part that
/// can't be read, the connection) closes the connection: the client asks
/// again from the part it lacks.
async fn get_attachment(
    shared: &Arc<Shared>,
    peer: &Peer,
    frames: &mut Frames,
    get: GetAttachment,
) -> Result<Option<Packet>, String> {
    if !peer.permissions.can_read(&get.topic) {
        return Ok(Some(refused(
            ErrorCode::NotAllowed,
            format!("{} may not read '{}'", peer.node, get.topic),
        )));
    }
    if !shared.config.server.has_topic(&get.topic) {
        return Ok(Some(refused(
            ErrorCode::UnknownName,
            format!("unknown topic '{}'", get.topic),
        )));
    }
    let message = format!("{}:{}#{}", get.topic, get.node, get.message_id);
    let GetAttachment {
        topic,
        node,
        message_id,
        from_part,
    } = get;
    let found = shared
        .read(move |reader| reader.attachment(&topic, &node, message_id))
        .await;
    let stored = match found {
        Ok(Some(stored)) => stored,
        Ok(None) => {
            return Ok(Some(refused(
                ErrorCode::NotFound,
                format!("no attachment for {message}"),
            )));
        }
        Err(refusal) => return Ok(Some(refusal.into())),
    };
    let not_here = match stored.state {
        AttachmentState::Ready => None,
        AttachmentState::TooBig => Some((
            ErrorCode::TooBig,
            "bigger than this server keeps: get it from another one",
        )),
        AttachmentState::Replicating => Some((ErrorCode::NotReady, "isn't on this server yet")),
        AttachmentState::Uploading | AttachmentState::Deleting => {
            Some((ErrorCode::NotFound, "isn't there any more"))
        }
    };
    if let Some((code, why)) = not_here {
        return Ok(Some(refused(
            code,
            format!("the attachment of {message} {why}"),
        )));
    }
    let attachment = Attachment {
        size: stored.size,
        sha256: stored.sha256,
    };
    let count = attachment.part_count();
    if from_part >= count {
        return Ok(Some(refused(
            ErrorCode::InvalidRequest,
            format!("from part {from_part}: the attachment of {message} has {count}"),
        )));
    }
    send(frames, attachment.into())
        .await
        .map_err(|error| error.to_string())?;
    for part in from_part..count {
        let data = shared
            .read(move |reader| reader.read_part(stored.id, part))
            .await
            .map_err(|refusal| format!("part {part} of {message}: {}", refusal.reason))?;
        send(frames, AttachmentPart { data }.into())
            .await
            .map_err(|error| error.to_string())?;
    }
    Ok(None)
}

/// A push's answer.
fn pushed(outcome: crate::writer::Outcome) -> Packet {
    match outcome {
        Ok(message_id) => MessagePushed { message_id }.into(),
        Err(refusal) => refusal.into(),
    }
}

async fn get_messages(shared: &Arc<Shared>, peer: &Peer, get: GetMessages) -> Packet {
    if !peer.permissions.can_read(&get.topic) {
        return refused(
            ErrorCode::NotAllowed,
            format!("{} may not read '{}'", peer.node, get.topic),
        );
    }
    if !shared.config.server.has_topic(&get.topic) {
        return refused(
            ErrorCode::UnknownName,
            format!("unknown topic '{}'", get.topic),
        );
    }
    let GetMessages {
        topic,
        node,
        after,
        limit,
    } = get;
    // Its own node is known even before its first push.
    let own = names_equal(&node, &peer.node);
    match shared
        .read(move |reader| reader.messages(&topic, &node, after, limit))
        .await
    {
        Ok(messages) => messages.into(),
        Err(refused) if own && refused.code == ErrorCode::UnknownName.code() => Messages {
            more: false,
            messages: Vec::new(),
        }
        .into(),
        Err(refused) => refused.into(),
    }
}

/// Topics: the server's, those it may push to or read unless it may query
/// (queries read everything). Nodes: every one with messages.
async fn list_names(shared: &Arc<Shared>, peer: &Peer, list: ListNames) -> Packet {
    let mut names = match list.kind {
        NameKind::Topic => shared
            .config
            .server
            .topics
            .iter()
            .filter(|topic| {
                peer.permissions.can_query()
                    || peer.permissions.can_push(topic)
                    || peer.permissions.can_read(topic)
            })
            .cloned()
            .collect(),
        NameKind::Node => match shared.read(|reader| reader.nodes()).await {
            Ok(nodes) => nodes,
            Err(refused) => return refused.into(),
        },
    };
    let truncated = names.len() > MAX_NAMES_LIST_ENTRIES;
    names.truncate(MAX_NAMES_LIST_ENTRIES);
    NamesList {
        kind: list.kind,
        truncated,
        names,
    }
    .into()
}

async fn query(shared: &Arc<Shared>, peer: &Peer, query: Query) -> Packet {
    if !peer.permissions.can_query() {
        return refused(
            ErrorCode::NotAllowed,
            format!("{} may not run queries", peer.node),
        );
    }
    match shared.query(query.sql).await {
        Ok(json) => QueryResult { json }.into(),
        Err(refused) => refused.into(),
    }
}

pub(crate) fn refused(code: ErrorCode, reason: String) -> Packet {
    RequestRefused::new(code, reason).into()
}

pub(crate) async fn send(frames: &mut Frames, packet: Packet) -> std::io::Result<()> {
    frames.send(bytes::Bytes::from(packet.encode())).await
}
