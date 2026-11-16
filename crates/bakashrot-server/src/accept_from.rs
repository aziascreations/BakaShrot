//! Replication's receiving end: a server that dialed in sends what this
//! one lacks (`push_to.rs` is the other end). Taken only from addresses in
//! `[replication] accept_from`, and only what its roles' `accept_*` allow.

use crate::connection::{Frames, Peer, receive_parts, refused, send};
use crate::writer::Write;
use crate::{Shared, now};
use bakashrot_proto::limits::{ATTACHMENT_PART_SIZE, MAX_MESSAGE_SIZE, MAX_MISSING_ATTACHMENTS};
use bakashrot_proto::packets::{
    Attachment, Continue, MessagePushed, ReplicateAttachment, ReplicateMessages, SyncState,
};
use bakashrot_proto::{ErrorCode, Packet};
use bakashrot_storage::AttachmentState;
use std::net::IpAddr;
use std::sync::{Arc, PoisonError};
use tracing::warn;

/// A replicated attachment being received over one connection: another
/// asking for it is refused until this is dropped (finished, refused,
/// the connection gone).
struct Receiving<'a> {
    shared: &'a Shared,
    key: (String, String, u64),
}

impl<'a> Receiving<'a> {
    /// None when it's being received already. Names without case, as
    /// everywhere ("Logs" is "logs").
    fn claim(shared: &'a Shared, topic: &str, node: &str, message_id: u64) -> Option<Self> {
        let key = (
            topic.to_ascii_lowercase(),
            node.to_ascii_lowercase(),
            message_id,
        );
        let claimed = shared
            .receiving
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(key.clone());
        // Made only when claimed, the lock let go: dropping one releases it.
        claimed.then(|| Receiving { shared, key })
    }
}

impl Drop for Receiving<'_> {
    fn drop(&mut self) {
        let mut receiving = self
            .shared
            .receiving
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        receiving.remove(&self.key);
    }
}

/// Whether `address` is in `accept_from`: `*`, an address as written, or
/// a hostname resolving to it (looked up now).
async fn is_accepted(shared: &Shared, address: IpAddr) -> bool {
    let address = address.to_canonical();
    for host in &shared.config.replication.accept_from {
        if host == "*" {
            return true;
        }
        if let Ok(ip) = host.parse::<IpAddr>() {
            if ip.to_canonical() == address {
                return true;
            }
        } else if let Ok(found) = tokio::net::lookup_host((host.as_str(), 0)).await
            && found
                .into_iter()
                .any(|at| at.ip().to_canonical() == address)
        {
            return true;
        }
    }
    false
}

/// Refused unless the connection comes from `accept_from` (looked up at
/// its first replication request).
async fn check_address(shared: &Shared, peer: &mut Peer) -> Result<(), Packet> {
    let accepted = match peer.accepted {
        Some(accepted) => accepted,
        None => *peer
            .accepted
            .insert(is_accepted(shared, peer.address).await),
    };
    match accepted {
        true => Ok(()),
        false => Err(refused(
            ErrorCode::NotAllowed,
            format!(
                "this server doesn't take replication from {} ({}): not in its accept_from",
                peer.node, peer.address
            ),
        )),
    }
}

/// Refused unless the connection comes from `accept_from` and its roles
/// accept `node`'s messages in `topic`.
async fn check(shared: &Shared, peer: &mut Peer, topic: &str, node: &str) -> Result<(), Packet> {
    check_address(shared, peer).await?;
    match peer.permissions.accepts(topic, node) {
        true => Ok(()),
        false => Err(refused(
            ErrorCode::NotAllowed,
            format!("this server doesn't take {topic}:{node} from {}", peer.node),
        )),
    }
}

/// What it takes from this peer, how far it is in those, and the
/// attachments it lacks among them.
pub(crate) async fn sync_state(shared: &Arc<Shared>, peer: &mut Peer) -> Packet {
    if let Err(refusal) = check_address(shared, peer).await {
        return refusal;
    }
    let (topics, nodes) = peer.permissions.accepted();
    let found = shared
        .read(|reader| {
            Ok((
                reader.heads()?,
                reader.missing_attachments(MAX_MISSING_ATTACHMENTS)?,
            ))
        })
        .await;
    let (mut heads, mut missing) = match found {
        Ok(found) => found,
        Err(refusal) => return refusal.into(),
    };
    heads.retain(|head| peer.permissions.accepts(&head.topic, &head.node));
    missing.retain(|missing| peer.permissions.accepts(&missing.topic, &missing.node));
    SyncState {
        topics,
        nodes,
        heads,
        missing,
    }
    .into()
}

/// A batch of a topic and node's messages: stored (those past their age
/// here only counted), answered with its last id.
pub(crate) async fn replicate_messages(
    shared: &Arc<Shared>,
    peer: &mut Peer,
    batch: ReplicateMessages,
) -> Packet {
    if let Err(refusal) = check(shared, peer, &batch.topic, &batch.node).await {
        return refusal;
    }
    if let Some(big) = batch
        .messages
        .iter()
        .find(|m| m.data.len() > MAX_MESSAGE_SIZE)
    {
        return refused(
            ErrorCode::TooBig,
            format!("message #{}: {MAX_MESSAGE_SIZE} bytes at most", big.id),
        );
    }
    let skip_before = shared
        .config
        .retention
        .age(&batch.topic)
        .map_or(0, |age| now().saturating_sub(age.as_millis() as u64));
    let write = Write::Replicate {
        topic: batch.topic,
        node: batch.node,
        messages: batch.messages,
        max_attachment_size: shared.config.server.max_attachment_size,
        skip_before,
    };
    match shared.pushes.send(write).await {
        Ok(message_id) => MessagePushed { message_id }.into(),
        Err(refusal) => refusal.into(),
    }
}

/// An attachment this server lacks: `Continue`, its parts from where it
/// stopped, checked with its SHA-256 (the parts it had read back for it).
/// An error closes the connection.
pub(crate) async fn replicate_attachment(
    shared: &Arc<Shared>,
    peer: &mut Peer,
    frames: &mut Frames,
    request: ReplicateAttachment,
) -> Result<Packet, String> {
    if let Err(refusal) = check(shared, peer, &request.topic, &request.node).await {
        return Ok(refusal);
    }
    let message = format!("{}:{}#{}", request.topic, request.node, request.message_id);
    // One peer at a time per attachment, until this returns (or the
    // connection goes): two at once would both be refused a part.
    let Some(_receiving) =
        Receiving::claim(shared, &request.topic, &request.node, request.message_id)
    else {
        return Ok(refused(
            ErrorCode::NotReady,
            format!("{message}: being received from another server"),
        ));
    };
    let ReplicateAttachment {
        topic,
        node,
        message_id,
        from_part,
    } = request;
    let stored = match shared
        .read(move |reader| reader.attachment(&topic, &node, message_id))
        .await
    {
        Ok(Some(stored)) if stored.state == AttachmentState::Replicating => stored,
        Ok(_) => {
            return Ok(refused(
                ErrorCode::NotFound,
                format!("{message}: no attachment missing here"),
            ));
        }
        Err(refusal) => return Ok(refusal.into()),
    };
    let attachment = Attachment {
        size: stored.size,
        sha256: stored.sha256,
    };
    // Every part came but nobody is checking them (finishing it failed):
    // started over, it's never taken unchecked.
    let mut received = stored.received;
    if received == stored.size {
        warn!("{message}: its attachment came whole but wasn't checked, asked for again");
        let restart = Write::FinishReplicated {
            attachment: stored.id as u64,
            matches: false,
        };
        if let Err(refusal) = shared.pushes.send(restart).await {
            return Ok(refusal.into());
        }
        received = 0;
    }
    let next = received / ATTACHMENT_PART_SIZE;
    if from_part != next {
        return Ok(refused(
            ErrorCode::InvalidRequest,
            format!("{message}: part {next} is the next one here, not {from_part}"),
        ));
    }

    // The parts it has, read back for the SHA-256.
    let sha256 = match shared.hash_parts(stored.id, 0..from_part).await {
        Ok(sha256) => sha256,
        Err(refusal) => return Ok(refusal.into()),
    };
    let attachment_id = stored.id as u64;
    send(frames, Continue {}.into())
        .await
        .map_err(|error| error.to_string())?;
    let refusal = receive_parts(
        shared,
        frames,
        attachment_id,
        &attachment,
        from_part,
        sha256,
    )
    .await?;
    if let Some(refusal) = &refusal
        && refusal.code != ErrorCode::DataMismatch.code()
    {
        // A part not written: it goes on from there next time.
        return Ok(refusal.clone().into());
    }
    let finish = Write::FinishReplicated {
        attachment: attachment_id,
        matches: refusal.is_none(),
    };
    Ok(match (shared.pushes.send(finish).await, refusal) {
        (Err(refusal), _) | (Ok(_), Some(refusal)) => refusal.into(),
        (Ok(_), None) => MessagePushed { message_id }.into(),
    })
}
