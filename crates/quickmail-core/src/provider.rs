use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::{Account, Mailbox, Message, MessageId, MessageSummary};

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ProviderCapabilities {
    pub folders: bool,
    pub labels: bool,
    pub threads: bool,
    pub server_search: bool,
    pub archive: bool,
    pub spam: bool,
    pub push: bool,
    /// The provider can fetch attachment bytes on demand. False means clients
    /// must not expose download/open actions.
    pub attachment_retrieval: bool,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct MessageQuery {
    #[serde(default)]
    pub account_id: Option<String>,
    #[serde(default)]
    pub mailbox_id: Option<String>,
    #[serde(default)]
    pub search: Option<String>,
    #[serde(default)]
    pub unread_only: bool,
    #[serde(default)]
    pub cursor: Option<String>,
    #[serde(default = "default_page_size")]
    pub limit: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct MessagePage {
    pub messages: Vec<MessageSummary>,
    #[serde(default)]
    pub next_cursor: Option<String>,
}

/// Provider-opaque state used by the daemon for one mailbox's incremental
/// refresh. This is deliberately separate from `MessageQuery::cursor`, which
/// pages backwards through a user-visible result set.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct MailboxSyncQuery {
    pub account_id: String,
    pub mailbox_id: String,
    pub cursor: Option<String>,
    pub limit: u32,
    /// Stable IDs of cached messages whose mutable metadata should be
    /// reconciled even when there are no newly-arrived messages.
    pub reconcile_message_ids: Vec<MessageId>,
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct MailboxSyncPage {
    pub messages: Vec<MessageSummary>,
    /// Stable IDs that were explicitly reconciled but no longer exist in the
    /// provider mailbox. Storage removes them in the cursor transaction.
    pub removed_message_ids: Vec<MessageId>,
    /// The cursor is committed only after `messages` are cached successfully.
    pub cursor: Option<String>,
    /// A provider generation changed, so cached rows for this mailbox must be
    /// replaced rather than merged with identifiers from the old generation.
    pub reset: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(
    tag = "kind",
    rename_all = "snake_case",
    rename_all_fields = "camelCase"
)]
pub enum MailAction {
    MarkRead {
        #[serde(alias = "message_ids")]
        message_ids: Vec<MessageId>,
        read: bool,
    },
    Star {
        #[serde(alias = "message_ids")]
        message_ids: Vec<MessageId>,
        starred: bool,
    },
    Archive {
        #[serde(alias = "message_ids")]
        message_ids: Vec<MessageId>,
    },
    Trash {
        #[serde(alias = "message_ids")]
        message_ids: Vec<MessageId>,
    },
    Move {
        #[serde(alias = "message_ids")]
        message_ids: Vec<MessageId>,
        #[serde(alias = "mailbox_id")]
        mailbox_id: String,
    },
    SetLabels {
        #[serde(alias = "message_ids")]
        message_ids: Vec<MessageId>,
        labels: Vec<String>,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct OutgoingMessage {
    #[serde(default)]
    pub draft_id: Option<String>,
    pub account_id: String,
    pub to: Vec<crate::Address>,
    #[serde(default)]
    pub cc: Vec<crate::Address>,
    #[serde(default)]
    pub bcc: Vec<crate::Address>,
    pub subject: String,
    #[serde(default)]
    pub body_text: Option<String>,
    #[serde(default)]
    pub body_html: Option<String>,
    #[serde(default)]
    pub in_reply_to: Option<MessageId>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AttachmentData {
    pub filename: String,
    pub content_type: String,
    pub bytes: Vec<u8>,
}

#[derive(Debug, Error)]
pub enum ProviderError {
    #[error("authentication required: {0}")]
    Authentication(String),
    #[error("provider operation is not supported: {0}")]
    Unsupported(String),
    #[error("remote resource was not found")]
    NotFound,
    #[error("temporary provider failure: {0}")]
    Temporary(String),
    #[error("{0} exceeds the configured size limit")]
    ResourceTooLarge(&'static str),
    #[error("provider failure: {0}")]
    Other(String),
}

#[async_trait]
pub trait MailProvider: Send + Sync {
    fn kind(&self) -> &'static str;
    fn account(&self) -> &Account;
    fn capabilities(&self) -> ProviderCapabilities;

    async fn list_mailboxes(&self) -> Result<Vec<Mailbox>, ProviderError>;
    async fn list_messages(&self, query: MessageQuery) -> Result<MessagePage, ProviderError>;

    /// Fetches one bounded mailbox refresh. Providers without incremental
    /// cursors retain the existing bounded newest-message behavior.
    async fn sync_mailbox(
        &self,
        query: MailboxSyncQuery,
    ) -> Result<MailboxSyncPage, ProviderError> {
        let page = self
            .list_messages(MessageQuery {
                account_id: Some(query.account_id),
                mailbox_id: Some(query.mailbox_id),
                limit: query.limit,
                ..MessageQuery::default()
            })
            .await?;
        Ok(MailboxSyncPage {
            messages: page.messages,
            removed_message_ids: Vec::new(),
            cursor: None,
            reset: false,
        })
    }

    async fn get_message(&self, id: &str) -> Result<Message, ProviderError>;
    async fn apply_action(&self, action: MailAction) -> Result<(), ProviderError>;
    async fn send(&self, message: OutgoingMessage) -> Result<MessageId, ProviderError>;

    async fn get_attachment(
        &self,
        _message_id: &str,
        _attachment_id: &str,
    ) -> Result<AttachmentData, ProviderError> {
        Err(ProviderError::Unsupported("attachment retrieval".into()))
    }
}

const fn default_page_size() -> u32 {
    50
}

#[cfg(test)]
mod tests {
    use serde_json::{Value, json};

    use super::MailAction;

    #[test]
    fn mail_actions_use_camel_case_fields_and_accept_legacy_snake_case() {
        let cases = [
            (
                MailAction::MarkRead {
                    message_ids: vec!["account:message".into()],
                    read: true,
                },
                json!({
                    "kind": "mark_read",
                    "messageIds": ["account:message"],
                    "read": true
                }),
                json!({
                    "kind": "mark_read",
                    "message_ids": ["account:message"],
                    "read": true
                }),
            ),
            (
                MailAction::Star {
                    message_ids: vec!["account:message".into()],
                    starred: true,
                },
                json!({
                    "kind": "star",
                    "messageIds": ["account:message"],
                    "starred": true
                }),
                json!({
                    "kind": "star",
                    "message_ids": ["account:message"],
                    "starred": true
                }),
            ),
            (
                MailAction::Archive {
                    message_ids: vec!["account:message".into()],
                },
                json!({"kind": "archive", "messageIds": ["account:message"]}),
                json!({"kind": "archive", "message_ids": ["account:message"]}),
            ),
            (
                MailAction::Trash {
                    message_ids: vec!["account:message".into()],
                },
                json!({"kind": "trash", "messageIds": ["account:message"]}),
                json!({"kind": "trash", "message_ids": ["account:message"]}),
            ),
            (
                MailAction::Move {
                    message_ids: vec!["account:message".into()],
                    mailbox_id: "archive".into(),
                },
                json!({
                    "kind": "move",
                    "messageIds": ["account:message"],
                    "mailboxId": "archive"
                }),
                json!({
                    "kind": "move",
                    "message_ids": ["account:message"],
                    "mailbox_id": "archive"
                }),
            ),
        ];

        for (action, camel_case, snake_case) in cases {
            assert_eq!(serde_json::to_value(&action).unwrap(), camel_case);
            assert_eq!(
                serde_json::from_value::<MailAction>(camel_case).unwrap(),
                action
            );
            assert_eq!(
                serde_json::from_value::<MailAction>(snake_case).unwrap(),
                action
            );
        }

        let serialized = serde_json::to_value(MailAction::SetLabels {
            message_ids: vec!["account:message".into()],
            labels: vec!["important".into()],
        })
        .unwrap();
        assert_eq!(serialized["messageIds"], json!(["account:message"]));
        assert_eq!(serialized.get("message_ids"), None::<&Value>);
    }
}
