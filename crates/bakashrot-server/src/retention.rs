//! Retention: right away, then every `retention_interval`, each topic's
//! messages past its age (`[retention]`) are deleted, then their
//! attachments' parts. Every topic in the database, by its name (one no
//! longer in `topics` too). Through the writer's queue, a batch at a time,
//! so pushes go on in between.

use crate::Shared;
use crate::writer::Write;
use bakashrot_proto::packets::RequestRefused;
use std::sync::Arc;
use tracing::{info, warn};

/// Most messages deleted in one write.
const MESSAGES_PER_WRITE: usize = 10_000;

/// Most attachment parts (1 MiB each) deleted in one write.
const PARTS_PER_WRITE: usize = 64;

/// Deletes what's past its age at every interval. Never returns.
pub(crate) async fn run(shared: &Arc<Shared>) {
    loop {
        if let Err(refused) = once(shared).await {
            warn!("retention: {}", refused.reason);
        }
        tokio::time::sleep(shared.config.server.retention_interval).await;
    }
}

/// One pass: every topic, then the attachments (also what a pass cut short
/// left).
async fn once(shared: &Arc<Shared>) -> Result<(), RequestRefused> {
    let now = crate::now();
    for topic in shared.read(|reader| reader.topics()).await? {
        let Some(cutoff) = shared.config.retention.cutoff(&topic, now) else {
            continue;
        };
        let deleted = repeat(shared, MESSAGES_PER_WRITE, |limit| Write::DeleteBefore {
            topic: topic.clone(),
            cutoff,
            limit,
        })
        .await?;
        if deleted > 0 {
            info!("deleted {deleted} messages of topic '{topic}'");
        }
    }
    repeat(shared, PARTS_PER_WRITE, |max_parts| {
        Write::PurgeAttachments { max_parts }
    })
    .await?;
    Ok(())
}

/// Sends `write(limit)` until one does less than `limit`: how many in all.
async fn repeat(
    shared: &Shared,
    limit: usize,
    write: impl Fn(usize) -> Write,
) -> Result<u64, RequestRefused> {
    let mut total = 0;
    loop {
        let count = shared.pushes.send(write(limit)).await?;
        total += count;
        if count < limit as u64 {
            return Ok(total);
        }
    }
}
