use std::path::PathBuf;

use anyhow::{Context, Result, bail};
use clap::{Parser, Subcommand};
use quickmail_core::MailAction as CoreMailAction;
use serde_json::{Value, json};

#[derive(Debug, Parser)]
#[command(name = "quickmailctl", version, about = "Control the QuickMail daemon")]
struct Cli {
    /// Override the daemon socket path.
    #[arg(long, env = "QUICKMAIL_SOCKET")]
    socket: Option<PathBuf>,

    /// Print compact JSON instead of indented output.
    #[arg(long, global = true)]
    compact: bool,

    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Check whether the daemon is responding.
    Ping,
    /// Return accounts, unread totals, recent mail, tasks, and events.
    Snapshot,
    /// List configured accounts.
    Accounts,
    /// Start synchronization, optionally for one account.
    Sync {
        #[arg(long)]
        account: Option<String>,
    },
    /// List messages with cursor pagination.
    Messages {
        #[arg(long)]
        account: Option<String>,
        #[arg(long, visible_alias = "folder")]
        mailbox: Option<String>,
        #[arg(long, default_value_t = 50)]
        limit: u16,
        #[arg(long)]
        cursor: Option<String>,
        #[arg(long, visible_alias = "query")]
        search: Option<String>,
    },
    /// Retrieve one complete message.
    Message { id: String },
    /// Apply a common mail action.
    Action {
        #[command(subcommand)]
        action: MailAction,
    },
    /// Call an RPC method directly. PARAMS must be a JSON object.
    Raw {
        method: String,
        #[arg(default_value = "{}")]
        params: String,
    },
    /// Subscribe to daemon events and print one JSON object per line.
    Watch {
        #[arg(default_values = ["mail", "accounts", "sync", "agenda"])]
        topics: Vec<String>,
    },
    /// Check socket availability, permissions, and RPC responsiveness.
    Doctor,
}

#[derive(Debug, Subcommand)]
enum MailAction {
    Read { id: String },
    Unread { id: String },
    Star { id: String },
    Unstar { id: String },
    Archive { id: String },
    Trash { id: String },
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    let socket = quickmailctl::resolve_socket(cli.socket)?;

    if matches!(&cli.command, Command::Doctor) {
        return doctor(&socket).await;
    }

    let response = match cli.command {
        Command::Ping => quickmailctl::call(&socket, "ping", json!({})).await?,
        Command::Snapshot => quickmailctl::call(&socket, "dashboard.snapshot", json!({})).await?,
        Command::Accounts => quickmailctl::call(&socket, "accounts.list", json!({})).await?,
        Command::Sync { account } => {
            quickmailctl::call(&socket, "sync.start", json!({ "accountId": account })).await?
        }
        Command::Messages {
            account,
            mailbox,
            limit,
            cursor,
            search,
        } => {
            if !(1..=200).contains(&limit) {
                bail!("--limit must be between 1 and 200");
            }
            quickmailctl::call(
                &socket,
                "mail.list",
                message_list_params(account, mailbox, limit, cursor, search),
            )
            .await?
        }
        Command::Message { id } => {
            quickmailctl::call(&socket, "mail.get", message_get_params(id)).await?
        }
        Command::Action { action } => {
            let action = match action {
                MailAction::Read { id } => CoreMailAction::MarkRead {
                    message_ids: vec![id],
                    read: true,
                },
                MailAction::Unread { id } => CoreMailAction::MarkRead {
                    message_ids: vec![id],
                    read: false,
                },
                MailAction::Star { id } => CoreMailAction::Star {
                    message_ids: vec![id],
                    starred: true,
                },
                MailAction::Unstar { id } => CoreMailAction::Star {
                    message_ids: vec![id],
                    starred: false,
                },
                MailAction::Archive { id } => CoreMailAction::Archive {
                    message_ids: vec![id],
                },
                MailAction::Trash { id } => CoreMailAction::Trash {
                    message_ids: vec![id],
                },
            };
            quickmailctl::call(&socket, "mail.action", serde_json::to_value(action)?).await?
        }
        Command::Raw { method, params } => {
            let params: Value =
                serde_json::from_str(&params).context("PARAMS is not valid JSON")?;
            if !params.is_object() {
                bail!("PARAMS must be a JSON object");
            }
            quickmailctl::call(&socket, &method, params).await?
        }
        Command::Watch { topics } => {
            return quickmailctl::watch(&socket, topics).await;
        }
        Command::Doctor => unreachable!(),
    };

    quickmailctl::print_json(&response, cli.compact)?;
    Ok(())
}

fn message_list_params(
    account: Option<String>,
    mailbox: Option<String>,
    limit: u16,
    cursor: Option<String>,
    search: Option<String>,
) -> Value {
    json!({
        "accountId": account,
        "mailboxId": mailbox,
        "limit": limit,
        "cursor": cursor,
        "search": search,
    })
}

fn message_get_params(id: String) -> Value {
    json!({ "messageId": id })
}

async fn doctor(socket: &std::path::Path) -> Result<()> {
    use std::os::unix::fs::MetadataExt;

    let metadata = std::fs::metadata(socket)
        .with_context(|| format!("daemon socket is not available at {}", socket.display()))?;
    let exposed_bits = metadata.mode() & 0o077;
    if exposed_bits != 0 {
        bail!(
            "daemon socket has group/world permission bits {:03o}; expected 000",
            exposed_bits
        );
    }
    let response = quickmailctl::call(socket, "ping", json!({})).await?;
    println!("socket: {}", socket.display());
    println!("permissions: private");
    println!("rpc: {}", response);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn message_list_uses_rpc_contract_field_names() {
        let params = message_list_params(
            Some("account-1".into()),
            Some("inbox".into()),
            25,
            Some("cursor-1".into()),
            Some("from:alex".into()),
        );
        assert_eq!(params["accountId"], "account-1");
        assert_eq!(params["mailboxId"], "inbox");
        assert_eq!(params["search"], "from:alex");
        assert!(params.get("folderId").is_none());
        assert!(params.get("query").is_none());
    }

    #[test]
    fn message_get_uses_message_id() {
        let params = message_get_params("message-1".into());
        assert_eq!(params, json!({ "messageId": "message-1" }));
        assert!(params.get("id").is_none());
    }
}
