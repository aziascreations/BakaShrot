//! Replication's sending end: a link to each server of
//! `[replication] push_to`, kept up (dialed again after `retry_delay`).
//! It checks in: asks what the other server takes and has (`SyncState`),
//! sends the messages it lacks, by topic and node name, then the
//! attachments it lacks; again at once if it sent any (it keeps up under
//! load), after `sync_interval` otherwise. Only what the other server's roles'
//! `send_*` allow. `accept_from.rs` is the other end.

use crate::Shared;
use crate::connection::SEND_TIMEOUT;
use crate::writer::Write;
use bakashrot_config::Permissions;
use bakashrot_pki::tls;
use bakashrot_proto::limits::{ALPN, KEEPALIVE_SECS, MAX_PACKET_SIZE};
use bakashrot_proto::names::name_matches;
use bakashrot_proto::packets::{
    Attachment, AttachmentPart, MissingAttachment, Pair, Ping, ReplicateAttachment,
    ReplicateMessages, RequestRefused, SyncState, SyncStateRequest,
};
use bakashrot_proto::{ErrorCode, Packet, frame};
use bakashrot_storage::AttachmentState;
use futures_util::{SinkExt, StreamExt};
use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::task::JoinSet;
use tokio::time::{sleep, timeout};
use tokio_rustls::client::TlsStream;
use tokio_util::codec::{Framed, LengthDelimitedCodec};
use tracing::{debug, info, warn};

/// How long connecting may take: TCP, TLS, the versions, the welcome.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);

/// How long an answer may take.
const ANSWER_TIMEOUT: Duration = Duration::from_secs(30);

/// Keeps a link to each server of `push_to`. Never returns.
pub(crate) async fn run(shared: Arc<Shared>) {
    let mut links = JoinSet::new();
    for address in &shared.config.replication.push_to {
        links.spawn(keep_linked(shared.clone(), address.clone()));
    }
    while links.join_next().await.is_some() {}
    std::future::pending().await
}

/// Links to `address`, checks in until the link fails, then again after
/// `retry_delay`. A failure is logged once until it changes.
async fn keep_linked(shared: Arc<Shared>, address: String) {
    let replication = &shared.config.replication;
    let mut last_failure = String::new();
    loop {
        let failure = match Link::open(&shared, &address).await {
            Ok(mut link) => {
                info!("{address}: linked to {}", link.name);
                last_failure.clear();
                loop {
                    let checked = match link.check_in(&shared).await {
                        Ok(true) => Ok(()),
                        Ok(false) => link.wait(replication.sync_interval).await,
                        Err(why) => Err(why),
                    };
                    if let Err(why) = checked {
                        break format!("{} ({address}): {why}", link.name);
                    }
                }
            }
            Err(why) => format!("{address}: {why}"),
        };
        if failure != last_failure {
            warn!("{failure}");
            last_failure = failure;
        }
        sleep(replication.retry_delay).await;
    }
}

/// A link to a server: what it is, what it may be sent.
struct Link {
    frames: Framed<TlsStream<TcpStream>, LengthDelimitedCodec>,
    name: String,
    permissions: Permissions,
    /// Whether this check-in sent something it took.
    sent: bool,
}

impl Link {
    async fn open(shared: &Shared, address: &str) -> Result<Link, String> {
        timeout(CONNECT_TIMEOUT, Link::connect(shared, address))
            .await
            .map_err(|_| "too slow to connect".to_owned())?
    }

    /// TCP, TLS, the versions, its roles here, the welcome.
    async fn connect(shared: &Shared, address: &str) -> Result<Link, String> {
        let text = |error: std::io::Error| error.to_string();
        let tcp = TcpStream::connect(address).await.map_err(text)?;
        tcp.set_nodelay(true).map_err(text)?;
        let mut stream = shared
            .connector
            .connect(tls::server_name(), tcp)
            .await
            .map_err(|error| format!("TLS: {error}"))?;
        if stream.get_ref().1.alpn_protocol() != Some(ALPN) {
            return Err("not a BakaShrot server".into());
        }
        stream
            .write_all(&frame::version_bytes())
            .await
            .map_err(text)?;
        stream.flush().await.map_err(text)?;
        let mut theirs = [0; frame::VERSION_SIZE];
        stream.read_exact(&mut theirs).await.map_err(text)?;
        frame::check_version(theirs).map_err(|version| format!("speaks protocol {version}"))?;

        let identity = tls::peer_identity(stream.get_ref().1.peer_certificates())
            .map_err(|error| error.to_string())?;
        let permissions = shared.config.permissions(&identity.roles).ok_or_else(|| {
            format!(
                "{}: none of its roles ({}) is in this server's config",
                identity.name,
                identity.roles.join(", ")
            )
        })?;
        let mut link = Link {
            frames: Framed::new(stream, frame::codec(MAX_PACKET_SIZE)),
            name: identity.name,
            permissions,
            sent: false,
        };
        match link.receive().await? {
            Packet::Welcome(_) => Ok(link),
            Packet::RequestRefused(refused) => Err(format!("refused: {}", refused.reason)),
            other => Err(unexpected(&other)),
        }
    }

    /// One check-in: what it lacks, the messages then the attachments.
    /// Whether it sent something it took.
    async fn check_in(&mut self, shared: &Arc<Shared>) -> Result<bool, String> {
        self.sent = false;
        let (state, theirs) = self.sync_state().await?;
        let heads = shared
            .read(|reader| reader.heads())
            .await
            .map_err(|refused| refused.reason)?;
        for head in heads {
            let (topic, node) = (head.topic, head.node);
            if !self.sends(&state, &topic, &node) {
                continue;
            }
            let after = theirs.get(&key(&topic, &node)).copied().unwrap_or(0);
            if after < head.last_id {
                self.send_messages(shared, topic, node, after).await?;
            }
        }
        for missing in state.missing {
            if self.permissions.sends(&missing.topic, &missing.node) {
                self.send_attachment(shared, missing).await?;
            }
        }
        Ok(self.sent)
    }

    /// Its `SyncState`, every page: the first (the lists), and the last
    /// id of each topic and node.
    async fn sync_state(&mut self) -> Result<(SyncState, HashMap<(String, String), u64>), String> {
        let mut first = self.sync_page(None).await?;
        let (mut heads, mut more) = (std::mem::take(&mut first.heads), first.more);
        let mut theirs = HashMap::new();
        loop {
            let after = heads.last().filter(|_| more).map(Pair::from);
            theirs.extend(
                heads
                    .into_iter()
                    .map(|head| (key(&head.topic, &head.node), head.last_id)),
            );
            let Some(after) = after else {
                return Ok((first, theirs));
            };
            let page = self.sync_page(Some(after)).await?;
            (heads, more) = (page.heads, page.more);
        }
    }

    /// A page of its `SyncState`, after the pair `after`.
    async fn sync_page(&mut self, after: Option<Pair>) -> Result<SyncState, String> {
        match self.ask(SyncStateRequest { after }.into()).await? {
            Packet::SyncState(page) => Ok(page),
            Packet::RequestRefused(refused) => Err(format!("refused: {}", refused.reason)),
            other => Err(unexpected(&other)),
        }
    }

    /// Whether it takes `node`'s messages in `topic` (its `SyncState`) and
    /// may be sent them (its roles here).
    fn sends(&self, state: &SyncState, topic: &str, node: &str) -> bool {
        let listed =
            |list: &[String], name: &str| list.iter().any(|entry| name_matches(entry, name));
        listed(&state.topics, topic)
            && listed(&state.nodes, node)
            && self.permissions.sends(topic, node)
    }

    /// A topic and node's messages after `after`, in batches. A refusal
    /// leaves them for the next check-in.
    async fn send_messages(
        &mut self,
        shared: &Arc<Shared>,
        topic: String,
        node: String,
        mut after: u64,
    ) -> Result<(), String> {
        let limit = shared.config.replication.batch_size;
        loop {
            let (t, n) = (topic.clone(), node.clone());
            let messages = shared
                .read(move |reader| reader.to_replicate(&t, &n, after, limit))
                .await
                .map_err(|refused| refused.reason)?;
            let Some(last) = messages.last().map(|message| message.id) else {
                return Ok(());
            };
            let batch = ReplicateMessages {
                topic: topic.clone(),
                node: node.clone(),
                messages,
            };
            match self.ask(batch.into()).await? {
                Packet::MessagePushed(_) => {
                    after = last;
                    self.sent = true;
                }
                Packet::RequestRefused(refused) => {
                    debug!("{}: {topic}:{node} refused: {}", self.name, refused.reason);
                    return Ok(());
                }
                other => return Err(unexpected(&other)),
            }
        }
    }

    /// An attachment it lacks, from the part it needs, if this server has
    /// it. One it says doesn't match its SHA-256 is checked here: a
    /// damaged copy is asked for again from this server's own peers.
    async fn send_attachment(
        &mut self,
        shared: &Arc<Shared>,
        missing: MissingAttachment,
    ) -> Result<(), String> {
        let message = format!("{}:{}#{}", missing.topic, missing.node, missing.message_id);
        let (topic, node, id) = (
            missing.topic.clone(),
            missing.node.clone(),
            missing.message_id,
        );
        let stored = shared
            .read(move |reader| reader.attachment(&topic, &node, id))
            .await
            .map_err(|refused| refused.reason)?;
        let Some(stored) = stored.filter(|stored| stored.state == AttachmentState::Ready) else {
            return Ok(());
        };
        let attachment = Attachment {
            size: stored.size,
            sha256: stored.sha256,
        };
        let from_part = missing.next_part;
        if from_part >= attachment.part_count() {
            return Ok(());
        }
        let request = ReplicateAttachment {
            topic: missing.topic,
            node: missing.node,
            message_id: missing.message_id,
            from_part,
        };
        match self.ask(request.into()).await? {
            Packet::Continue(_) => {}
            Packet::RequestRefused(refused) => {
                debug!(
                    "{}: {message}'s attachment refused: {}",
                    self.name, refused.reason
                );
                return Ok(());
            }
            other => return Err(unexpected(&other)),
        }
        for part in from_part..attachment.part_count() {
            // A part that can't be read: the link closes, it asks again.
            let data = shared
                .read(move |reader| reader.read_part(stored.id, part))
                .await
                .map_err(|refused| format!("part {part} of {message}: {}", refused.reason))?;
            self.send(AttachmentPart { data }.into()).await?;
        }
        match self.receive().await? {
            Packet::MessagePushed(_) => {
                debug!("{}: sent {message}'s attachment", self.name);
                self.sent = true;
            }
            Packet::RequestRefused(refused) if refused.code == ErrorCode::DataMismatch.code() => {
                check_own_copy(shared, stored.id, &attachment, &message).await
            }
            Packet::RequestRefused(refused) => debug!(
                "{}: {message}'s attachment refused: {}",
                self.name, refused.reason
            ),
            other => return Err(unexpected(&other)),
        }
        Ok(())
    }

    /// Waits `duration` before the next check-in, with a `Ping` every
    /// `KEEPALIVE_SECS` meanwhile: the other server closes a link silent
    /// for `IDLE_TIMEOUT_SECS`.
    async fn wait(&mut self, duration: Duration) -> Result<(), String> {
        let keepalive = Duration::from_secs(KEEPALIVE_SECS);
        let mut left = duration;
        while left > keepalive {
            sleep(keepalive).await;
            left -= keepalive;
            match self.ask(Ping {}.into()).await? {
                Packet::Pong(_) => {}
                other => return Err(unexpected(&other)),
            }
        }
        sleep(left).await;
        Ok(())
    }

    async fn ask(&mut self, packet: Packet) -> Result<Packet, String> {
        self.send(packet).await?;
        self.receive().await
    }

    async fn send(&mut self, packet: Packet) -> Result<(), String> {
        let sending = self.frames.send(bytes::Bytes::from(packet.encode()));
        match timeout(SEND_TIMEOUT, sending).await {
            Ok(sent) => sent.map_err(|error| error.to_string()),
            Err(_) => Err("too slow to take a packet".into()),
        }
    }

    async fn receive(&mut self) -> Result<Packet, String> {
        match timeout(ANSWER_TIMEOUT, self.frames.next()).await {
            Err(_) => Err("no answer in time".into()),
            Ok(None) => Err("closed the link".into()),
            Ok(Some(bytes)) => {
                let bytes = bytes.map_err(|error| error.to_string())?;
                Packet::decode(&bytes).map_err(|error| error.to_string())
            }
        }
    }
}

/// The other server said this server's copy doesn't match its SHA-256:
/// read it back; damaged, it's asked for again from this server's peers
/// (and not served meanwhile), instead of sent again and again.
async fn check_own_copy(
    shared: &Arc<Shared>,
    attachment_id: i64,
    attachment: &Attachment,
    message: &str,
) {
    let read = shared
        .hash_parts(attachment_id, 0..attachment.part_count())
        .await
        .map(|sha256| sha256.finish().as_ref() == attachment.sha256);
    match judge(read) {
        OwnCopy::Intact => return,
        OwnCopy::Damaged => {}
        OwnCopy::Unknown(why) => {
            warn!(
                "{message}: this server's copy of its attachment couldn't be read back ({why}): \
                 kept, checked again when a peer refuses it again"
            );
            return;
        }
    }
    let damaged = Write::Damaged {
        attachment: attachment_id as u64,
    };
    match shared.pushes.send(damaged).await {
        Ok(_) => {
            warn!("{message}: this server's copy of its attachment is damaged, asked for again")
        }
        Err(refused) => warn!("{message}: a damaged attachment: {}", refused.reason),
    }
}

/// What reading back this server's copy of an attachment says about it.
#[derive(Debug, PartialEq, Eq)]
enum OwnCopy {
    /// Read whole, matching its SHA-256.
    Intact,
    /// Read whole and not matching, or a part missing: dropped and asked
    /// for again.
    Damaged,
    /// The read failed (the database busy, a connection not opened...),
    /// saying why: nothing is known, the copy is kept. Dropping it then
    /// could lose the only one there is (this server the attachment's
    /// origin).
    Unknown(String),
}

/// The verdict on a read-back: whether its SHA-256 matched, or why it
/// failed.
fn judge(read: Result<bool, RequestRefused>) -> OwnCopy {
    match read {
        Ok(true) => OwnCopy::Intact,
        Ok(false) => OwnCopy::Damaged,
        Err(refused) if refused.code == ErrorCode::NotFound.code() => OwnCopy::Damaged,
        Err(refused) => OwnCopy::Unknown(refused.reason),
    }
}

/// A topic and node, to compare without case.
fn key(topic: &str, node: &str) -> (String, String) {
    (topic.to_ascii_lowercase(), node.to_ascii_lowercase())
}

fn unexpected(packet: &Packet) -> String {
    format!("answered {}", packet.packet_type().name())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_a_copy_read_whole_or_missing_a_part_is_damaged() {
        let refused = |code| Err(RequestRefused::new(code, "why"));
        let unknown = || OwnCopy::Unknown("why".into());
        assert_eq!(judge(Ok(true)), OwnCopy::Intact);
        assert_eq!(judge(Ok(false)), OwnCopy::Damaged);
        // A part missing (read_part's NotFound): damaged too.
        assert_eq!(judge(refused(ErrorCode::NotFound)), OwnCopy::Damaged);
        // A read that failed says nothing about the copy: kept, saying why.
        assert_eq!(judge(refused(ErrorCode::ServerError)), unknown());
        assert_eq!(judge(refused(ErrorCode::InvalidRequest)), unknown());
    }
}
