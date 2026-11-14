//! `bakashrot-server <config.toml>`: runs a server until Ctrl+C.

use bakashrot_config::Config;
use bakashrot_server::Server;
use std::path::PathBuf;
use std::process::ExitCode;
use tokio::net::TcpListener;
use tracing::{error, info};

#[tokio::main]
async fn main() -> ExitCode {
    tracing_subscriber::fmt().with_target(false).init();
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
    tokio::select! {
        served = server.serve(listener) => served.map_err(|error| format!("accepting: {error}"))?,
        _ = server.watch_revocations() => {}
        _ = server.apply_retention() => {}
        _ = tokio::signal::ctrl_c() => info!("stopping"),
    }
    Ok(())
}
