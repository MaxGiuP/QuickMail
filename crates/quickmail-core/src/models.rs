use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;

pub type AccountId = String;
pub type MailboxId = String;
pub type MessageId = String;
pub type ThreadId = String;
pub type TaskId = String;
pub type EventId = String;

/// Produces the daemon's globally stable message key from an account key and
/// the provider-native identifier (for example an IMAP UID).
pub fn normalized_message_id(account_id: &str, provider_id: &str) -> MessageId {
    format!("{account_id}:{provider_id}")
}

pub fn is_normalized_message_id(account_id: &str, id: &str) -> bool {
    id.strip_prefix(account_id)
        .is_some_and(|suffix| suffix.starts_with(':') && suffix.len() > 1)
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Account {
    pub id: AccountId,
    pub address: String,
    #[serde(default)]
    pub display_name: String,
    pub provider: String,
    pub protocol: String,
    #[serde(default)]
    pub host: String,
    #[serde(default)]
    pub unread: u64,
    #[serde(default)]
    pub total: u64,
    #[serde(default = "default_true")]
    pub enabled: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Mailbox {
    pub id: MailboxId,
    pub account_id: AccountId,
    pub name: String,
    #[serde(default)]
    pub role: Option<MailboxRole>,
    #[serde(default)]
    pub unread: u64,
    #[serde(default)]
    pub total: u64,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum MailboxRole {
    Inbox,
    Drafts,
    Sent,
    Archive,
    Trash,
    Spam,
    Other,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Address {
    #[serde(default)]
    pub name: String,
    pub address: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct MessageSummary {
    pub id: MessageId,
    pub account_id: AccountId,
    #[serde(default)]
    pub mailbox_id: Option<MailboxId>,
    #[serde(default)]
    pub thread_id: Option<ThreadId>,
    #[serde(alias = "title")]
    pub subject: String,
    #[serde(default)]
    pub author: Option<Address>,
    #[serde(with = "chrono::serde::ts_milliseconds")]
    pub timestamp: DateTime<Utc>,
    #[serde(default)]
    pub read: bool,
    #[serde(default)]
    pub starred: bool,
    #[serde(default)]
    pub snippet: String,
    #[serde(default)]
    pub has_attachments: bool,
    #[serde(default)]
    pub labels: Vec<String>,
    #[serde(default)]
    pub provider_data: Value,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Message {
    #[serde(flatten)]
    pub summary: MessageSummary,
    #[serde(default)]
    pub to: Vec<Address>,
    #[serde(default)]
    pub cc: Vec<Address>,
    #[serde(default)]
    pub bcc: Vec<Address>,
    #[serde(default)]
    pub body_text: Option<String>,
    #[serde(default)]
    pub body_html: Option<String>,
    #[serde(default)]
    pub attachments: Vec<Attachment>,
}

/// A bounded, chronological view of one cached mail conversation.
///
/// Threads intentionally contain summaries only. Clients fetch the selected
/// message body with `mail.get`, keeping this response small even for long or
/// attachment-heavy conversations.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ThreadConversation {
    pub id: ThreadId,
    pub messages: Vec<MessageSummary>,
    #[serde(default)]
    pub truncated: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Attachment {
    pub id: String,
    pub filename: String,
    pub content_type: String,
    pub size: u64,
    #[serde(default)]
    pub inline: bool,
    #[serde(default)]
    pub content_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Task {
    pub id: TaskId,
    pub title: String,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub done: bool,
    #[serde(default)]
    #[serde(with = "chrono::serde::ts_milliseconds_option")]
    pub due_at: Option<DateTime<Utc>>,
    #[serde(with = "chrono::serde::ts_milliseconds")]
    pub created_at: DateTime<Utc>,
    #[serde(default = "default_local")]
    pub source: String,
    #[serde(default)]
    pub external_id: String,
    #[serde(default)]
    pub account: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct CalendarEvent {
    pub id: EventId,
    #[serde(default)]
    pub external_id: String,
    #[serde(default)]
    pub calendar_id: String,
    #[serde(default)]
    pub calendar_name: String,
    pub title: String,
    #[serde(default)]
    pub description: String,
    #[serde(with = "chrono::serde::ts_milliseconds")]
    pub start_at: DateTime<Utc>,
    #[serde(with = "chrono::serde::ts_milliseconds")]
    pub end_at: DateTime<Utc>,
    #[serde(default)]
    pub all_day: bool,
    #[serde(default)]
    pub read_only: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct SyncStatus {
    #[serde(default)]
    pub running: bool,
    #[serde(default)]
    #[serde(with = "chrono::serde::ts_milliseconds_option")]
    pub last_sync_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct DashboardSnapshot {
    pub revision: u64,
    pub accounts: Vec<Account>,
    pub recent_mail: Vec<MessageSummary>,
    pub tasks: Vec<Task>,
    pub events: Vec<CalendarEvent>,
    pub sync: SyncStatus,
}

const fn default_true() -> bool {
    true
}

fn default_local() -> String {
    "local".into()
}
