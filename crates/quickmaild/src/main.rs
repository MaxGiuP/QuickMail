use std::{path::PathBuf, sync::Arc};

use anyhow::{Context, Result, anyhow};
use clap::Parser;
use directories::BaseDirs;
use quickmaild::{daemon::Daemon, providers::ProductionProviderFactory, storage::Database};
use tracing::info;
use tracing_subscriber::EnvFilter;

#[derive(Debug, Parser)]
#[command(version, about = "QuickMail local mail and agenda daemon")]
struct Args {
    /// Unix socket path. Defaults below XDG_RUNTIME_DIR.
    #[arg(long, env = "QUICKMAIL_SOCKET")]
    socket: Option<PathBuf>,

    /// SQLite database path. Defaults below XDG_STATE_HOME.
    #[arg(long, env = "QUICKMAIL_DATABASE")]
    database: Option<PathBuf>,

    /// Attachment cache directory. Defaults below XDG_CACHE_HOME.
    #[arg(long, env = "QUICKMAIL_ATTACHMENT_CACHE")]
    attachment_cache: Option<PathBuf>,

    /// Explicitly seed harmless local fixtures for visual UI testing.
    #[arg(long)]
    demo: bool,
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .init();
    let args = Args::parse();
    validate_demo_paths(&args)?;
    let base = BaseDirs::new().ok_or_else(|| anyhow!("could not resolve XDG directories"))?;
    let runtime = base
        .runtime_dir()
        .ok_or_else(|| anyhow!("XDG_RUNTIME_DIR is required for the private daemon socket"))?;
    let socket = args
        .socket
        .unwrap_or_else(|| runtime.join("quickmail/daemon.sock"));
    let database_path = args.database.unwrap_or_else(|| {
        base.state_dir()
            .unwrap_or_else(|| base.data_local_dir())
            .join("quickmail/mail.db")
    });
    let attachment_cache = args
        .attachment_cache
        .unwrap_or_else(|| base.cache_dir().join("quickmail/attachments"));

    let database = Database::open(&database_path)
        .with_context(|| format!("could not open {}", database_path.display()))?;
    if args.demo {
        database
            .seed_demo()
            .await
            .context("could not seed demo data")?;
        info!("demo fixtures enabled by explicit --demo flag");
    }
    let daemon = Daemon::with_provider_factory(
        database,
        Arc::new(ProductionProviderFactory::new()),
        attachment_cache,
    );
    let restored = daemon.restore_providers().await?;
    info!(restored, "restored account providers");
    info!(socket = %socket.display(), "daemon ready");
    daemon.run_with_shutdown(socket, shutdown_signal()).await?;
    Ok(())
}

fn validate_demo_paths(args: &Args) -> Result<()> {
    if args.demo
        && (args.socket.is_none() || args.database.is_none() || args.attachment_cache.is_none())
    {
        return Err(anyhow!(
            "--demo requires explicit --socket, --database, and --attachment-cache paths"
        ));
    }
    Ok(())
}

async fn shutdown_signal() {
    #[cfg(unix)]
    {
        use tokio::signal::unix::{SignalKind, signal};
        let mut terminate = signal(SignalKind::terminate()).expect("SIGTERM handler");
        tokio::select! {
            _ = tokio::signal::ctrl_c() => {}
            _ = terminate.recv() => {}
        }
    }
    #[cfg(not(unix))]
    let _ = tokio::signal::ctrl_c().await;
}

#[cfg(test)]
mod tests {
    use super::{Args, validate_demo_paths};
    use clap::Parser;

    #[test]
    fn demo_refuses_implicit_production_paths() {
        let args = Args::try_parse_from(["quickmaild", "--demo"]).unwrap();
        assert!(validate_demo_paths(&args).is_err());
    }

    #[test]
    fn demo_accepts_three_isolated_paths() {
        let args = Args::try_parse_from([
            "quickmaild",
            "--demo",
            "--socket",
            "/tmp/quickmail-demo/socket",
            "--database",
            "/tmp/quickmail-demo/mail.db",
            "--attachment-cache",
            "/tmp/quickmail-demo/attachments",
        ])
        .unwrap();
        assert!(validate_demo_paths(&args).is_ok());
    }
}
