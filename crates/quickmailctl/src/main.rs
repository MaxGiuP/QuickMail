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
    /// Synchronize calendars and tasks without refreshing mailboxes.
    AgendaSync {
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
    /// List cached tasks from local, Google, and Microsoft accounts.
    Tasks {
        #[arg(long)]
        include_done: bool,
    },
    /// Create a task locally or in an account selected by its QuickMail ID.
    TaskCreate {
        title: String,
        #[arg(long, default_value = "")]
        description: String,
        /// Due time as Unix epoch milliseconds.
        #[arg(long)]
        due_at: Option<i64>,
        #[arg(long)]
        account: Option<String>,
    },
    /// Mark a task complete (or reopen it with --open).
    TaskComplete {
        id: String,
        #[arg(long)]
        open: bool,
    },
    /// Delete a task.
    TaskDelete { id: String },
    /// List cached events in an epoch-millisecond range.
    Events {
        #[arg(long)]
        start_at: i64,
        #[arg(long)]
        end_at: i64,
    },
    /// Create an event locally or in an account selected by its QuickMail ID.
    EventCreate {
        title: String,
        #[arg(long, default_value = "")]
        description: String,
        #[arg(long)]
        start_at: i64,
        #[arg(long)]
        end_at: i64,
        #[arg(long)]
        account: Option<String>,
        #[arg(long, default_value = "")]
        calendar_name: String,
        #[arg(long)]
        all_day: bool,
    },
    /// Delete an event.
    EventDelete { id: String },
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
        Command::AgendaSync { account } => {
            quickmailctl::call(&socket, "agenda.sync", json!({ "accountId": account })).await?
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
        Command::Tasks { include_done } => {
            quickmailctl::call(&socket, "task.list", json!({ "includeDone": include_done })).await?
        }
        Command::TaskCreate {
            title,
            description,
            due_at,
            account,
        } => {
            let params = task_create_params(title, description, due_at, account)?;
            quickmailctl::call(&socket, "task.create", params).await?
        }
        Command::TaskComplete { id, open } => {
            quickmailctl::call(
                &socket,
                "task.complete",
                json!({ "taskId": id, "done": !open }),
            )
            .await?
        }
        Command::TaskDelete { id } => {
            quickmailctl::call(&socket, "task.delete", json!({ "taskId": id })).await?
        }
        Command::Events { start_at, end_at } => {
            validate_time_range(start_at, end_at)?;
            quickmailctl::call(
                &socket,
                "calendar.list",
                json!({ "startAt": start_at, "endAt": end_at }),
            )
            .await?
        }
        Command::EventCreate {
            title,
            description,
            start_at,
            end_at,
            account,
            calendar_name,
            all_day,
        } => {
            let params = event_create_params(
                title,
                description,
                start_at,
                end_at,
                account,
                calendar_name,
                all_day,
            )?;
            quickmailctl::call(&socket, "calendar.create", params).await?
        }
        Command::EventDelete { id } => {
            quickmailctl::call(&socket, "calendar.delete", json!({ "eventId": id })).await?
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

fn now_millis() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};

    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| i64::try_from(duration.as_millis()).unwrap_or(i64::MAX))
        .unwrap_or_default()
}

fn task_create_params(
    title: String,
    description: String,
    due_at: Option<i64>,
    account: Option<String>,
) -> Result<Value> {
    let title = title.trim();
    if title.is_empty() {
        bail!("task title must not be empty");
    }
    if due_at.is_some_and(|due| due <= 0) {
        bail!("--due-at must be a positive epoch-millisecond value");
    }
    let account = account.unwrap_or_default();
    Ok(json!({
        "id": "",
        "title": title,
        "description": description,
        "done": false,
        "dueAt": due_at,
        "createdAt": now_millis(),
        "source": if account.is_empty() { "local" } else { "account" },
        "externalId": "",
        "account": account,
    }))
}

fn validate_time_range(start_at: i64, end_at: i64) -> Result<()> {
    if start_at <= 0 || end_at <= start_at {
        bail!("event end must be after its positive epoch-millisecond start");
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn event_create_params(
    title: String,
    description: String,
    start_at: i64,
    end_at: i64,
    account: Option<String>,
    calendar_name: String,
    all_day: bool,
) -> Result<Value> {
    let title = title.trim();
    if title.is_empty() {
        bail!("event title must not be empty");
    }
    validate_time_range(start_at, end_at)?;
    let account = account.unwrap_or_default();
    Ok(json!({
        "id": "",
        "externalId": "",
        "calendarId": if account.is_empty() { "local" } else { account.as_str() },
        "calendarName": if calendar_name.trim().is_empty() && account.is_empty() {
            "Local"
        } else {
            calendar_name.trim()
        },
        "title": title,
        "description": description,
        "startAt": start_at,
        "endAt": end_at,
        "allDay": all_day,
        "readOnly": false,
    }))
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

    #[test]
    fn task_creation_uses_the_daemon_agenda_contract() {
        let params = task_create_params(
            " Plan trip ".into(),
            "Book train".into(),
            Some(1_700_000_000_000),
            Some("account-1".into()),
        )
        .unwrap();
        assert_eq!(params["title"], "Plan trip");
        assert_eq!(params["account"], "account-1");
        assert_eq!(params["dueAt"], 1_700_000_000_000_i64);
        assert!(params["createdAt"].as_i64().unwrap() > 0);
        assert_eq!(params["externalId"], "");
    }

    #[test]
    fn event_creation_validates_and_selects_local_calendar() {
        let params = event_create_params(
            "Focus time".into(),
            String::new(),
            1_700_000_000_000,
            1_700_003_600_000,
            None,
            String::new(),
            false,
        )
        .unwrap();
        assert_eq!(params["calendarId"], "local");
        assert_eq!(params["calendarName"], "Local");
        assert!(
            event_create_params(
                "Broken".into(),
                String::new(),
                20,
                10,
                None,
                String::new(),
                false,
            )
            .is_err()
        );
    }
}
