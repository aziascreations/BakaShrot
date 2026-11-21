//! The writer's thread: every write goes through one queue, and the thread
//! writes whatever is queued in one transaction (a group commit): the
//! busier, the bigger the groups. [`Pushes::stop`] ends it once what was
//! queued before is committed.

use crate::refusal;
use bakashrot_proto::packets::{ReplicatedMessage, RequestRefused};
use bakashrot_storage::{Batch, Writer};
use std::sync::mpsc;
use tokio::sync::oneshot;

/// Most writes in one transaction.
const MAX_GROUP: usize = 1000;

/// A write's outcome: a number (a message's id, an upload's), or the
/// refusal to answer.
pub(crate) type Outcome = Result<u64, RequestRefused>;

/// What the writer does (`bakashrot_storage::Batch`'s).
pub(crate) enum Write {
    /// A message: its id.
    Push {
        topic: String,
        node: String,
        pushed_at: u64,
        data: String,
    },
    /// An attachment's upload: its id.
    StartUpload { size: u64, sha256: [u8; 32] },
    /// An upload's next part: 1 if it was the last, 0 otherwise.
    Part {
        upload: u64,
        part: u64,
        data: Vec<u8>,
    },
    /// A message with its whole, checked upload: its id.
    PushWithUpload {
        upload: u64,
        topic: String,
        node: String,
        pushed_at: u64,
        data: String,
    },
    /// Drops an upload: 0.
    CancelUpload { upload: u64 },
    /// Retention: deletes a topic's messages pushed before `cutoff`,
    /// `limit` at most: how many.
    DeleteBefore {
        topic: String,
        cutoff: u64,
        limit: usize,
    },
    /// Deletes deleted messages' attachment parts, `max_parts` at most:
    /// how many.
    PurgeAttachments { max_parts: usize },
    /// A peer's messages: the topic and node's last id.
    Replicate {
        topic: String,
        node: String,
        messages: Vec<ReplicatedMessage>,
        max_attachment_size: u64,
        skip_before: u64,
    },
    /// A replicated attachment all of whose parts came: ready if it
    /// `matches` its SHA-256, started over otherwise. 0.
    FinishReplicated { attachment: u64, matches: bool },
    /// This server's own copy found damaged: asked for again. 0.
    Damaged { attachment: u64 },
}

impl Write {
    fn run(&self, batch: &mut Batch<'_>) -> bakashrot_storage::Result<u64> {
        // Upload ids are SQLite rowids: positive.
        match self {
            Write::Push {
                topic,
                node,
                pushed_at,
                data,
            } => batch.push(topic, node, *pushed_at, data),
            Write::StartUpload { size, sha256 } => {
                batch.start_upload(*size, sha256).map(|id| id as u64)
            }
            Write::Part { upload, part, data } => {
                batch.write_part(*upload as i64, *part, data).map(u64::from)
            }
            Write::PushWithUpload {
                upload,
                topic,
                node,
                pushed_at,
                data,
            } => batch.push_with_attachment(*upload as i64, topic, node, *pushed_at, data),
            Write::CancelUpload { upload } => batch.cancel_upload(*upload as i64).map(|()| 0),
            Write::DeleteBefore {
                topic,
                cutoff,
                limit,
            } => batch
                .delete_before(topic, *cutoff, *limit)
                .map(|count| count as u64),
            Write::PurgeAttachments { max_parts } => batch
                .purge_attachments(*max_parts)
                .map(|count| count as u64),
            Write::Replicate {
                topic,
                node,
                messages,
                max_attachment_size,
                skip_before,
            } => batch.replicate(topic, node, messages, *max_attachment_size, *skip_before),
            Write::FinishReplicated {
                attachment,
                matches,
            } => batch
                .finish_replicated(*attachment as i64, *matches)
                .map(|()| 0),
            Write::Damaged { attachment } => batch.damaged(*attachment as i64).map(|()| 0),
        }
    }
}

/// What the writer's thread is sent.
enum Job {
    Write {
        write: Write,
        done: oneshot::Sender<Outcome>,
    },
    /// Stop once the writes queued before are committed, then say so.
    Stop(oneshot::Sender<()>),
}

/// The queue to the writer's thread.
pub(crate) struct Pushes {
    queue: mpsc::Sender<Job>,
}

impl Pushes {
    /// Starts the writer's thread on `writer`. It ends with the queue, or
    /// at [`Pushes::stop`].
    pub(crate) fn start(mut writer: Writer) -> std::io::Result<Pushes> {
        let (queue, pending) = mpsc::channel::<Job>();
        std::thread::Builder::new()
            .name("writer".into())
            .spawn(move || {
                while let Ok(first) = pending.recv() {
                    let (mut group, mut stopped) = (Vec::new(), None);
                    for job in std::iter::once(first).chain(pending.try_iter()) {
                        match job {
                            Job::Write { write, done } => group.push((write, done)),
                            Job::Stop(done) => stopped = Some(done),
                        }
                        if stopped.is_some() || group.len() == MAX_GROUP {
                            break;
                        }
                    }
                    write(&mut writer, group);
                    if let Some(done) = stopped {
                        // Writes queued after are dropped with the queue,
                        // refused as the server stopping.
                        let _ = done.send(());
                        return;
                    }
                }
            })?;
        Ok(Pushes { queue })
    }

    /// Stops the writer's thread once every write queued before is
    /// committed; the ones after are refused, the server stopping.
    pub(crate) async fn stop(&self) {
        let (done, stopped) = oneshot::channel();
        if self.queue.send(Job::Stop(done)).is_ok() {
            let _ = stopped.await;
        }
    }

    /// Queues a write now (writes are done in the order queued), its
    /// outcome once its group is committed. Dropping the future doesn't
    /// take the write back.
    pub(crate) fn send(&self, write: Write) -> impl Future<Output = Outcome> + use<> {
        let (done, outcome) = oneshot::channel();
        let queued = self.queue.send(Job::Write { write, done });
        async move {
            queued.map_err(|_| stopped())?;
            outcome.await.unwrap_or_else(|_| Err(stopped()))
        }
    }
}

/// Writes a group in one transaction, then answers each write.
fn write(writer: &mut Writer, group: Vec<(Write, oneshot::Sender<Outcome>)>) {
    if group.is_empty() {
        return;
    }
    let mut outcomes = Vec::with_capacity(group.len());
    let committed = writer.batch(|batch| {
        // SQLite rolling the group back (a full disk...) fails the batch:
        // every write in it is refused below, none stored.
        for (write, _) in &group {
            outcomes.push(write.run(batch).map_err(refusal));
        }
        Ok(())
    });
    if let Err(error) = committed {
        let refused = refusal(error);
        outcomes = group.iter().map(|_| Err(refused.clone())).collect();
    }
    for ((_, done), outcome) in group.into_iter().zip(outcomes) {
        // Its connection may be gone: nothing to answer then.
        let _ = done.send(outcome);
    }
}

fn stopped() -> RequestRefused {
    RequestRefused::new(
        bakashrot_proto::ErrorCode::ServerError,
        "the server is stopping",
    )
}
