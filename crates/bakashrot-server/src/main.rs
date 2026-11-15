//! `bakashrot-server <config.toml>`: runs a server until it's told to stop
//! (SIGTERM or SIGINT on Linux; Ctrl+C, Ctrl+Break or its console closed
//! on Windows), then stops cleanly: what was queued for the database is
//! committed first.
//!
//! Logs go to the console (stdout), `BAKASHROT_LOG` sets their level
//! (`error`, `warn`, `info` by default, `debug`, `trace`).

use bakashrot_config::Config;
use bakashrot_server::Server;
use std::io::IsTerminal;
use std::path::PathBuf;
use std::process::ExitCode;
use tokio::net::TcpListener;
use tracing::level_filters::LevelFilter;
use tracing::{error, info};

#[tokio::main]
async fn main() -> ExitCode {
    let level = std::env::var("BAKASHROT_LOG").ok();
    let filter = level.as_deref().map_or(Ok(LevelFilter::INFO), str::parse);
    tracing_subscriber::fmt()
        .with_target(false)
        .with_max_level(*filter.as_ref().unwrap_or(&LevelFilter::INFO))
        // No colour codes in a file or a journal.
        .with_ansi(std::io::stdout().is_terminal())
        .init();
    if filter.is_err() {
        error!("BAKASHROT_LOG: not a level (error, warn, info, debug, trace), logging info");
    }
    let Some(path) = std::env::args_os().nth(1).map(PathBuf::from) else {
        eprintln!("usage: bakashrot-server <config.toml>");
        return ExitCode::from(2);
    };
    match run(&path).await {
        Ok(()) => ExitCode::SUCCESS,
        Err(why) => {
            error!("{why}");
            ExitCode::FAILURE
        }
    }
}

async fn run(path: &std::path::Path) -> Result<(), String> {
    let config = Config::load(path).map_err(|error| error.to_string())?;
    let server = Server::start(config)?;
    let listener = TcpListener::bind(server.listen())
        .await
        .map_err(|error| format!("listening on {}: {error}", server.listen()))?;
    info!("{} listening on {}", server.name(), server.listen());
    let outcome = tokio::select! {
        served = server.serve(listener) => served.map_err(|error| format!("accepting: {error}")),
        _ = server.watch_revocations() => Ok(()),
        _ = server.apply_retention() => Ok(()),
        _ = server.replicate() => Ok(()),
        signal = stop_signal() => {
            info!("{}, stopping", signal?);
            Ok(())
        }
    };
    server.stop().await;
    info!("stopped");
    outcome
}

/// The first stop signal: its name.
#[cfg(unix)]
async fn stop_signal() -> Result<&'static str, String> {
    use tokio::signal::unix::{SignalKind, signal};
    let listen = |kind| signal(kind).map_err(|error| format!("listening for signals: {error}"));
    let (mut terminate, mut interrupt) = (
        listen(SignalKind::terminate())?,
        listen(SignalKind::interrupt())?,
    );
    Ok(tokio::select! {
        _ = terminate.recv() => "SIGTERM",
        _ = interrupt.recv() => "SIGINT",
    })
}

/// The first stop signal: its name. Closing the console leaves a few
/// seconds before Windows ends the process, enough to commit.
#[cfg(windows)]
async fn stop_signal() -> Result<&'static str, String> {
    use tokio::signal::windows;
    let failed = |error: std::io::Error| format!("listening for Ctrl+C: {error}");
    let mut c = windows::ctrl_c().map_err(failed)?;
    let mut r#break = windows::ctrl_break().map_err(failed)?;
    let mut close = windows::ctrl_close().map_err(failed)?;
    Ok(tokio::select! {
        _ = c.recv() => "Ctrl+C",
        _ = r#break.recv() => "Ctrl+Break",
        _ = close.recv() => "the console closed",
    })
}
