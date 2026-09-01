use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::{CalendarEvent, OutgoingMessage, Task};

pub const JSONRPC_VERSION: &str = "2.0";

pub mod method {
    pub const PING: &str = "ping";
    pub const SUBSCRIBE: &str = "subscribe";
    pub const DASHBOARD_SNAPSHOT: &str = "dashboard.snapshot";
    pub const ACCOUNTS_LIST: &str = "accounts.list";
    pub const ACCOUNTS_ADD: &str = "accounts.add";
    pub const ACCOUNTS_REMOVE: &str = "accounts.remove";
    pub const ACCOUNTS_REAUTH: &str = "accounts.reauth";
    pub const MAIL_LIST: &str = "mail.list";
    pub const MAILBOXES_LIST: &str = "mailboxes.list";
    pub const MAIL_GET: &str = "mail.get";
    pub const THREAD_GET: &str = "thread.get";
    pub const MAIL_ACTION: &str = "mail.action";
    pub const MAIL_SEND: &str = "mail.send";
    pub const DRAFT_SAVE: &str = "draft.save";
    pub const DRAFT_LIST: &str = "draft.list";
    pub const DRAFT_GET: &str = "draft.get";
    pub const DRAFT_DELETE: &str = "draft.delete";
    pub const ATTACHMENT_DOWNLOAD: &str = "attachment.download";
    pub const TASK_LIST: &str = "task.list";
    pub const TASK_CREATE: &str = "task.create";
    pub const TASK_UPDATE: &str = "task.update";
    pub const TASK_COMPLETE: &str = "task.complete";
    pub const TASK_DELETE: &str = "task.delete";
    pub const CALENDAR_LIST: &str = "calendar.list";
    pub const CALENDAR_CREATE: &str = "calendar.create";
    pub const CALENDAR_UPDATE: &str = "calendar.update";
    pub const CALENDAR_DELETE: &str = "calendar.delete";
    pub const AGENDA_SYNC: &str = "agenda.sync";
    pub const SYNC_START: &str = "sync.start";
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Hash)]
#[serde(untagged)]
pub enum RpcId {
    Null,
    Number(i64),
    String(String),
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct RpcRequest {
    pub jsonrpc: String,
    pub id: RpcId,
    pub method: String,
    #[serde(default)]
    pub params: Value,
}

impl RpcRequest {
    pub fn new(id: impl Into<RpcId>, method: impl Into<String>, params: Value) -> Self {
        Self {
            jsonrpc: JSONRPC_VERSION.into(),
            id: id.into(),
            method: method.into(),
            params,
        }
    }
}

impl From<i64> for RpcId {
    fn from(value: i64) -> Self {
        Self::Number(value)
    }
}

impl From<String> for RpcId {
    fn from(value: String) -> Self {
        Self::String(value)
    }
}

impl From<&str> for RpcId {
    fn from(value: &str) -> Self {
        Self::String(value.into())
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct RpcResponse {
    pub jsonrpc: String,
    pub id: RpcId,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<RpcError>,
}

impl RpcResponse {
    pub fn success(id: RpcId, result: impl Serialize) -> Result<Self, serde_json::Error> {
        Ok(Self {
            jsonrpc: JSONRPC_VERSION.into(),
            id,
            result: Some(serde_json::to_value(result)?),
            error: None,
        })
    }

    pub fn failure(id: RpcId, error: RpcError) -> Self {
        Self {
            jsonrpc: JSONRPC_VERSION.into(),
            id,
            result: None,
            error: Some(error),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct RpcError {
    pub code: i32,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<Value>,
}

impl RpcError {
    pub fn invalid_request(message: impl Into<String>) -> Self {
        Self {
            code: -32600,
            message: message.into(),
            data: None,
        }
    }

    pub fn method_not_found(method: impl Into<String>) -> Self {
        Self {
            code: -32601,
            message: format!("method not found: {}", method.into()),
            data: None,
        }
    }

    pub fn invalid_params(message: impl Into<String>) -> Self {
        Self {
            code: -32602,
            message: message.into(),
            data: None,
        }
    }

    pub fn internal(message: impl Into<String>) -> Self {
        Self {
            code: -32603,
            message: message.into(),
            data: None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct RpcNotification {
    pub jsonrpc: String,
    pub method: String,
    pub params: Value,
}

impl RpcNotification {
    pub fn new(
        method: impl Into<String>,
        params: impl Serialize,
    ) -> Result<Self, serde_json::Error> {
        Ok(Self {
            jsonrpc: JSONRPC_VERSION.into(),
            method: method.into(),
            params: serde_json::to_value(params)?,
        })
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct SubscribeParams {
    #[serde(default)]
    pub topics: Vec<String>,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AccountAddParams {
    pub provider: String,
    pub address: String,
    #[serde(default)]
    pub display_name: String,
    #[serde(default)]
    pub imap: Option<MailServerSetup>,
    #[serde(default)]
    pub smtp: Option<MailServerSetup>,
}

impl std::fmt::Debug for AccountAddParams {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("AccountAddParams")
            .field("provider", &self.provider)
            .field("address", &self.address)
            .field("display_name", &self.display_name)
            .field("imap", &self.imap)
            .field("smtp", &self.smtp)
            .finish()
    }
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MailServerSetup {
    pub host: String,
    pub port: u16,
    pub security: String,
    pub username: String,
    #[serde(default)]
    pub password: String,
}

impl std::fmt::Debug for MailServerSetup {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("MailServerSetup")
            .field("host", &self.host)
            .field("port", &self.port)
            .field("security", &self.security)
            .field("username", &self.username)
            .field("password", &"[REDACTED]")
            .finish()
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct AccountIdParams {
    pub account_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct MessageIdParams {
    pub message_id: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct TaskListParams {
    #[serde(default)]
    pub include_done: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct TaskCompleteParams {
    pub task_id: String,
    pub done: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct TaskIdParams {
    pub task_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct CalendarListParams {
    #[serde(with = "chrono::serde::ts_milliseconds")]
    pub start_at: chrono::DateTime<chrono::Utc>,
    #[serde(with = "chrono::serde::ts_milliseconds")]
    pub end_at: chrono::DateTime<chrono::Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct EventIdParams {
    pub event_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct AttachmentDownloadParams {
    pub message_id: String,
    pub attachment_id: String,
    #[serde(default)]
    pub disposition: AttachmentDisposition,
}

#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum AttachmentDisposition {
    #[default]
    #[serde(alias = "save")]
    Download,
    Open,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct AttachmentDownloaded {
    pub path: String,
    pub filename: String,
    pub content_type: String,
    pub size: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct DraftSaveParams {
    #[serde(default)]
    pub draft_id: Option<String>,
    pub message: OutgoingMessage,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct DraftSaved {
    pub draft_id: String,
    #[serde(with = "chrono::serde::ts_milliseconds")]
    pub updated_at: chrono::DateTime<chrono::Utc>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DraftListParams {
    #[serde(default)]
    pub account_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DraftIdParams {
    pub draft_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct DraftRecord {
    pub draft_id: String,
    pub message: OutgoingMessage,
    #[serde(with = "chrono::serde::ts_milliseconds")]
    pub updated_at: chrono::DateTime<chrono::Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(untagged)]
pub enum TaskMutationParams {
    Task(Task),
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(untagged)]
pub enum CalendarMutationParams {
    Event(CalendarEvent),
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn request_and_notification_are_json_rpc_compatible() {
        let request = RpcRequest::new(7, method::MAIL_LIST, json!({"limit": 20}));
        let json = serde_json::to_value(&request).unwrap();
        assert_eq!(json["jsonrpc"], JSONRPC_VERSION);
        assert_eq!(json["id"], 7);

        let notification = RpcNotification::new("mail.changed", json!({"revision": 3})).unwrap();
        let json = serde_json::to_value(notification).unwrap();
        assert!(json.get("id").is_none());
    }

    #[test]
    fn response_never_contains_result_and_error_together() {
        let ok = RpcResponse::success(1.into(), json!({"pong": true})).unwrap();
        assert!(ok.result.is_some());
        assert!(ok.error.is_none());

        let failed = RpcResponse::failure(1.into(), RpcError::invalid_params("bad"));
        assert!(failed.result.is_none());
        assert!(failed.error.is_some());
    }

    #[test]
    fn gmail_account_setup_needs_no_application_oauth_credentials() {
        let setup: AccountAddParams = serde_json::from_value(json!({
            "provider": "gmail",
            "address": "person@gmail.com",
            "displayName": "Person"
        }))
        .unwrap();
        assert_eq!(setup.provider, "gmail");
        assert!(setup.imap.is_none());
        assert!(setup.smtp.is_none());

        assert!(
            serde_json::from_value::<AccountAddParams>(json!({
                "provider": "gmail",
                "address": "person@gmail.com",
                "oauth": {"clientId": "must-not-be-client-facing"}
            }))
            .is_err()
        );
    }
}
