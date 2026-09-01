use std::{fmt, sync::Arc, time::Duration};

use async_trait::async_trait;
use chrono::{DateTime, Utc};
use quickmail_core::{
    Account, Address, Attachment, AttachmentData, MailAction, MailProvider, Mailbox, MailboxRole,
    Message, MessagePage, MessageQuery, MessageSummary, OutgoingMessage, ProviderCapabilities,
    ProviderError, normalized_message_id,
};
use serde::{Deserialize, Serialize};
use thiserror::Error;
use tokio::{sync::Semaphore, task::JoinSet};
use url::Url;

use super::{
    MAX_MAIL_ATTACHMENT_BYTES, MAX_MAIL_MESSAGE_BYTES,
    auth::{TokenError, TokenSource},
    mime::{MimeCodec, MimeError, sanitize_filename},
};

const DEFAULT_API_ROOT: &str = "https://gmail.googleapis.com/gmail/v1/";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum HttpMethod {
    Get,
    Post,
}

pub(crate) struct HttpRequest {
    pub(crate) method: HttpMethod,
    pub(crate) url: Url,
    pub(crate) headers: Vec<(String, String)>,
    pub(crate) body: Option<Vec<u8>>,
}

impl fmt::Debug for HttpRequest {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let headers = self
            .headers
            .iter()
            .map(|(name, value)| {
                if name.eq_ignore_ascii_case("authorization") {
                    (name.as_str(), "[REDACTED]")
                } else {
                    (name.as_str(), value.as_str())
                }
            })
            .collect::<Vec<_>>();
        formatter
            .debug_struct("HttpRequest")
            .field("method", &self.method)
            .field("url", &self.url)
            .field("headers", &headers)
            .field("body_length", &self.body.as_ref().map(Vec::len))
            .finish()
    }
}

#[derive(Debug)]
pub(crate) struct HttpResponse {
    pub(crate) status: u16,
    pub(crate) body: Vec<u8>,
}

#[derive(Debug, Error)]
#[error("HTTP transport failed")]
pub(crate) struct HttpTransportError {
    source: Option<anyhow::Error>,
}

impl HttpTransportError {
    #[allow(dead_code)]
    pub(crate) fn new(source: anyhow::Error) -> Self {
        Self {
            source: Some(source),
        }
    }
}

#[async_trait]
pub(crate) trait HttpTransport: Send + Sync {
    /// Production implementations should retain one pooled HTTP client rather
    /// than constructing a client for each call.
    async fn execute(&self, request: HttpRequest) -> Result<HttpResponse, HttpTransportError>;
}

/// Pooled production HTTP transport for Gmail REST calls.
pub(crate) struct ReqwestHttpTransport {
    client: reqwest::Client,
    max_response_bytes: usize,
}

impl ReqwestHttpTransport {
    pub(crate) fn new() -> Result<Self, HttpTransportError> {
        let client = reqwest::Client::builder()
            .connect_timeout(Duration::from_secs(15))
            .timeout(Duration::from_secs(90))
            .pool_idle_timeout(Duration::from_secs(90))
            .pool_max_idle_per_host(8)
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .map_err(|error| HttpTransportError::new(error.into()))?;
        Ok(Self {
            client,
            max_response_bytes: MAX_MAIL_MESSAGE_BYTES,
        })
    }
}

#[async_trait]
impl HttpTransport for ReqwestHttpTransport {
    async fn execute(&self, request: HttpRequest) -> Result<HttpResponse, HttpTransportError> {
        if request.url.scheme() != "https" {
            return Err(HttpTransportError::new(anyhow::anyhow!(
                "Gmail transport rejected a non-HTTPS endpoint"
            )));
        }
        let method = match request.method {
            HttpMethod::Get => reqwest::Method::GET,
            HttpMethod::Post => reqwest::Method::POST,
        };
        let mut builder = self.client.request(method, request.url);
        for (name, value) in request.headers {
            builder = builder.header(name, value);
        }
        if let Some(body) = request.body {
            builder = builder.body(body);
        }
        let mut response = builder
            .send()
            .await
            .map_err(|error| HttpTransportError::new(error.into()))?;
        let status = response.status().as_u16();
        if response
            .content_length()
            .is_some_and(|length| length > self.max_response_bytes as u64)
        {
            return Err(HttpTransportError::new(anyhow::anyhow!(
                "Gmail response exceeded the configured size limit"
            )));
        }
        let initial_capacity = response
            .content_length()
            .unwrap_or_default()
            .min(self.max_response_bytes as u64) as usize;
        let mut body = Vec::with_capacity(initial_capacity);
        while let Some(chunk) = response
            .chunk()
            .await
            .map_err(|error| HttpTransportError::new(error.into()))?
        {
            append_bounded_response_chunk(&mut body, &chunk, self.max_response_bytes)?;
        }
        Ok(HttpResponse { status, body })
    }
}

fn append_bounded_response_chunk(
    body: &mut Vec<u8>,
    chunk: &[u8],
    limit: usize,
) -> Result<(), HttpTransportError> {
    if chunk.len() > limit.saturating_sub(body.len()) {
        return Err(HttpTransportError::new(anyhow::anyhow!(
            "Gmail response exceeded the configured size limit"
        )));
    }
    body.extend_from_slice(chunk);
    Ok(())
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum GmailMessageFormat {
    Minimal,
    Metadata,
    Full,
    Raw,
}

impl GmailMessageFormat {
    fn as_api_value(self) -> &'static str {
        match self {
            Self::Minimal => "minimal",
            Self::Metadata => "metadata",
            Self::Full => "full",
            Self::Raw => "raw",
        }
    }
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct GmailMessageRef {
    pub(crate) id: String,
    pub(crate) thread_id: String,
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct GmailMessageList {
    #[serde(default)]
    pub(crate) messages: Vec<GmailMessageRef>,
    pub(crate) next_page_token: Option<String>,
    pub(crate) result_size_estimate: Option<u64>,
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct GmailMessage {
    pub(crate) id: String,
    pub(crate) thread_id: String,
    #[serde(default)]
    pub(crate) label_ids: Vec<String>,
    pub(crate) snippet: Option<String>,
    pub(crate) history_id: Option<String>,
    pub(crate) internal_date: Option<String>,
    pub(crate) payload: Option<GmailMessagePart>,
    pub(crate) raw: Option<String>,
    pub(crate) size_estimate: Option<u64>,
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct GmailMessagePart {
    pub(crate) part_id: Option<String>,
    pub(crate) mime_type: Option<String>,
    pub(crate) filename: Option<String>,
    #[serde(default)]
    pub(crate) headers: Vec<GmailHeader>,
    pub(crate) body: Option<GmailMessagePartBody>,
    #[serde(default)]
    pub(crate) parts: Vec<GmailMessagePart>,
}

#[derive(Clone, Debug, Default, Deserialize)]
pub(crate) struct GmailHeader {
    pub(crate) name: String,
    pub(crate) value: String,
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct GmailMessagePartBody {
    pub(crate) attachment_id: Option<String>,
    pub(crate) size: Option<u64>,
    /// Gmail base64url content. It remains encoded until explicitly requested,
    /// keeping list/detail synchronization lazy.
    pub(crate) data: Option<String>,
}

#[derive(Clone, Debug, Default, Deserialize)]
pub(crate) struct GmailLabelList {
    #[serde(default)]
    pub(crate) labels: Vec<GmailLabel>,
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct GmailLabel {
    pub(crate) id: String,
    pub(crate) name: String,
    pub(crate) label_list_visibility: Option<String>,
    pub(crate) messages_total: Option<u64>,
    pub(crate) messages_unread: Option<u64>,
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct GmailHistoryPage {
    #[serde(default)]
    pub(crate) history: Vec<GmailHistoryRecord>,
    pub(crate) next_page_token: Option<String>,
    pub(crate) history_id: Option<String>,
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct GmailHistoryRecord {
    pub(crate) id: String,
    #[serde(default)]
    pub(crate) messages_added: Vec<GmailHistoryMessage>,
    #[serde(default)]
    pub(crate) messages_deleted: Vec<GmailHistoryMessage>,
    #[serde(default)]
    pub(crate) labels_added: Vec<GmailHistoryLabelChange>,
    #[serde(default)]
    pub(crate) labels_removed: Vec<GmailHistoryLabelChange>,
}

#[derive(Clone, Debug, Default, Deserialize)]
pub(crate) struct GmailHistoryMessage {
    pub(crate) message: GmailMessage,
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct GmailHistoryLabelChange {
    pub(crate) message: GmailMessage,
    #[serde(default)]
    pub(crate) label_ids: Vec<String>,
}

#[derive(Clone, Debug)]
pub(crate) enum HistorySync {
    Changes {
        records: Vec<GmailHistoryRecord>,
        new_history_id: String,
    },
    /// Gmail returns 404 when the saved cursor has fallen outside its retained
    /// history window. The caller must perform a full message sync.
    FullSyncRequired,
}

pub(crate) struct GmailRestClient<T, S> {
    transport: Arc<T>,
    tokens: Arc<S>,
    api_root: Url,
}

impl<T, S> Clone for GmailRestClient<T, S> {
    fn clone(&self) -> Self {
        Self {
            transport: self.transport.clone(),
            tokens: self.tokens.clone(),
            api_root: self.api_root.clone(),
        }
    }
}

impl<T, S> GmailRestClient<T, S>
where
    T: HttpTransport + 'static,
    S: TokenSource + 'static,
{
    pub(crate) fn new(transport: Arc<T>, tokens: Arc<S>) -> Self {
        Self {
            transport,
            tokens,
            api_root: Url::parse(DEFAULT_API_ROOT).expect("Gmail API root is static and valid"),
        }
    }

    #[cfg(test)]
    fn with_api_root(transport: Arc<T>, tokens: Arc<S>, api_root: Url) -> Self {
        Self {
            transport,
            tokens,
            api_root,
        }
    }

    pub(crate) async fn list_message_page(
        &self,
        query: Option<&str>,
        label_ids: &[String],
        page_token: Option<&str>,
        max_results: u32,
    ) -> Result<GmailMessageList, GmailError> {
        let max_results = max_results.clamp(1, 500).to_string();
        let mut query_pairs = vec![("maxResults", max_results.as_str())];
        if let Some(query) = query.filter(|query| !query.trim().is_empty()) {
            query_pairs.push(("q", query));
        }
        if let Some(page_token) = page_token {
            query_pairs.push(("pageToken", page_token));
        }
        for label_id in label_ids {
            query_pairs.push(("labelIds", label_id));
        }
        self.json_request(HttpMethod::Get, "users/me/messages", &query_pairs, None)
            .await
    }

    pub(crate) async fn list_all_message_ids(
        &self,
        query: Option<&str>,
        label_ids: &[String],
    ) -> Result<Vec<GmailMessageRef>, GmailError> {
        let mut messages = Vec::new();
        let mut page_token = None;
        loop {
            let page = self
                .list_message_page(query, label_ids, page_token.as_deref(), 500)
                .await?;
            messages.extend(page.messages);
            match page.next_page_token {
                Some(next) if Some(&next) != page_token.as_ref() => page_token = Some(next),
                Some(_) => return Err(GmailError::RepeatedPageToken),
                None => return Ok(messages),
            }
        }
    }

    pub(crate) async fn get_message(
        &self,
        message_id: &str,
        format: GmailMessageFormat,
    ) -> Result<GmailMessage, GmailError> {
        validate_resource_id(message_id)?;
        let path = format!("users/me/messages/{message_id}");
        self.json_request(
            HttpMethod::Get,
            &path,
            &[("format", format.as_api_value())],
            None,
        )
        .await
    }

    pub(crate) async fn get_attachment_bytes(
        &self,
        message_id: &str,
        attachment_id: &str,
    ) -> Result<Vec<u8>, GmailError> {
        validate_resource_id(message_id)?;
        validate_resource_id(attachment_id)?;
        let path = format!("users/me/messages/{message_id}/attachments/{attachment_id}");
        let body: GmailMessagePartBody =
            self.json_request(HttpMethod::Get, &path, &[], None).await?;
        base64_url_decode(body.data.as_deref().ok_or(GmailError::InvalidBase64)?)
    }

    pub(crate) async fn list_labels(&self) -> Result<Vec<GmailLabel>, GmailError> {
        Ok(self
            .json_request::<GmailLabelList>(HttpMethod::Get, "users/me/labels", &[], None)
            .await?
            .labels)
    }

    /// Fetches details with an explicit upper bound. The shared transport is
    /// retained across tasks, enabling a production reqwest adapter to reuse its
    /// connection pool.
    pub(crate) async fn get_messages_bounded(
        &self,
        message_ids: &[String],
        format: GmailMessageFormat,
        concurrency: usize,
    ) -> Result<Vec<GmailMessage>, GmailError> {
        if concurrency == 0 {
            return Err(GmailError::InvalidConcurrency);
        }
        let semaphore = Arc::new(Semaphore::new(concurrency));
        let mut tasks = JoinSet::new();
        for (index, message_id) in message_ids.iter().cloned().enumerate() {
            let client = self.clone();
            let semaphore = semaphore.clone();
            tasks.spawn(async move {
                let _permit = semaphore
                    .acquire_owned()
                    .await
                    .map_err(|_| GmailError::TaskCancelled)?;
                client
                    .get_message(&message_id, format)
                    .await
                    .map(|message| (index, message))
            });
        }

        let mut messages = Vec::with_capacity(message_ids.len());
        while let Some(result) = tasks.join_next().await {
            messages.push(result.map_err(|_| GmailError::TaskCancelled)??);
        }
        messages.sort_unstable_by_key(|(index, _)| *index);
        Ok(messages.into_iter().map(|(_, message)| message).collect())
    }

    pub(crate) async fn history_since(
        &self,
        start_history_id: &str,
    ) -> Result<HistorySync, GmailError> {
        if start_history_id.is_empty()
            || !start_history_id.bytes().all(|byte| byte.is_ascii_digit())
        {
            return Err(GmailError::InvalidResourceId);
        }

        let mut records = Vec::new();
        let mut page_token = None;
        let mut newest_history_id = start_history_id.to_owned();
        loop {
            let mut pairs = vec![("startHistoryId", start_history_id)];
            if let Some(page_token) = page_token.as_deref() {
                pairs.push(("pageToken", page_token));
            }
            let response = self
                .request(HttpMethod::Get, "users/me/history", &pairs, None)
                .await?;
            if response.status == 404 {
                return Ok(HistorySync::FullSyncRequired);
            }
            let page: GmailHistoryPage = decode_success(response)?;
            records.extend(page.history);
            if let Some(history_id) = page.history_id {
                newest_history_id = history_id;
            }
            match page.next_page_token {
                Some(next) if Some(&next) != page_token.as_ref() => page_token = Some(next),
                Some(_) => return Err(GmailError::RepeatedPageToken),
                None => {
                    return Ok(HistorySync::Changes {
                        records,
                        new_history_id: newest_history_id,
                    });
                }
            }
        }
    }

    pub(crate) async fn modify_labels(
        &self,
        message_id: &str,
        add: &[String],
        remove: &[String],
    ) -> Result<GmailMessage, GmailError> {
        validate_resource_id(message_id)?;
        #[derive(Serialize)]
        #[serde(rename_all = "camelCase")]
        struct ModifyRequest<'a> {
            add_label_ids: &'a [String],
            remove_label_ids: &'a [String],
        }

        let path = format!("users/me/messages/{message_id}/modify");
        let body = serde_json::to_vec(&ModifyRequest {
            add_label_ids: add,
            remove_label_ids: remove,
        })?;
        self.json_request(HttpMethod::Post, &path, &[], Some(body))
            .await
    }

    pub(crate) async fn set_read(
        &self,
        message_id: &str,
        read: bool,
    ) -> Result<GmailMessage, GmailError> {
        let unread = "UNREAD".to_owned();
        if read {
            self.modify_labels(message_id, &[], &[unread]).await
        } else {
            self.modify_labels(message_id, &[unread], &[]).await
        }
    }

    pub(crate) async fn archive(&self, message_id: &str) -> Result<GmailMessage, GmailError> {
        self.modify_labels(message_id, &[], &["INBOX".to_owned()])
            .await
    }

    pub(crate) async fn trash(&self, message_id: &str) -> Result<GmailMessage, GmailError> {
        validate_resource_id(message_id)?;
        let path = format!("users/me/messages/{message_id}/trash");
        self.json_request(HttpMethod::Post, &path, &[], Some(b"{}".to_vec()))
            .await
    }

    pub(crate) async fn send_raw(&self, rfc822: &[u8]) -> Result<GmailMessage, GmailError> {
        #[derive(Serialize)]
        struct SendRequest {
            raw: String,
        }
        let body = serde_json::to_vec(&SendRequest {
            raw: base64_url_encode(rfc822),
        })?;
        self.json_request(HttpMethod::Post, "users/me/messages/send", &[], Some(body))
            .await
    }

    async fn json_request<R: for<'de> Deserialize<'de>>(
        &self,
        method: HttpMethod,
        path: &str,
        query: &[(&str, &str)],
        body: Option<Vec<u8>>,
    ) -> Result<R, GmailError> {
        decode_success(self.request(method, path, query, body).await?)
    }

    async fn request(
        &self,
        method: HttpMethod,
        path: &str,
        query: &[(&str, &str)],
        body: Option<Vec<u8>>,
    ) -> Result<HttpResponse, GmailError> {
        let first = self
            .execute_authorized(method, path, query, body.clone(), false)
            .await?;
        if first.status == 401 {
            self.execute_authorized(method, path, query, body, true)
                .await
        } else {
            Ok(first)
        }
    }

    async fn execute_authorized(
        &self,
        method: HttpMethod,
        path: &str,
        query: &[(&str, &str)],
        body: Option<Vec<u8>>,
        force_refresh: bool,
    ) -> Result<HttpResponse, GmailError> {
        let token = self.tokens.access_token(force_refresh).await?;
        let mut url = self.api_root.join(path)?;
        url.query_pairs_mut().extend_pairs(query.iter().copied());
        let mut headers = vec![(
            "Authorization".to_owned(),
            format!("Bearer {}", token.value.expose_secret()),
        )];
        if body.is_some() {
            headers.push(("Content-Type".to_owned(), "application/json".to_owned()));
        }
        self.transport
            .execute(HttpRequest {
                method,
                url,
                headers,
                body,
            })
            .await
            .map_err(GmailError::Transport)
    }
}

pub(crate) struct GmailProvider<T, S, M> {
    account: Account,
    rest: GmailRestClient<T, S>,
    mime: M,
    detail_concurrency: usize,
}

impl<T, S, M> GmailProvider<T, S, M>
where
    T: HttpTransport + 'static,
    S: TokenSource + 'static,
    M: MimeCodec,
{
    pub(crate) fn new(
        account: Account,
        transport: Arc<T>,
        tokens: Arc<S>,
        mime: M,
        detail_concurrency: usize,
    ) -> Result<Self, GmailError> {
        if detail_concurrency == 0 {
            return Err(GmailError::InvalidConcurrency);
        }
        Ok(Self {
            account,
            rest: GmailRestClient::new(transport, tokens),
            mime,
            detail_concurrency,
        })
    }

    fn map_summary(&self, message: &GmailMessage) -> MessageSummary {
        let headers = message
            .payload
            .as_ref()
            .map(|payload| payload.headers.as_slice())
            .unwrap_or_default();
        MessageSummary {
            id: normalized_message_id(&self.account.id, &message.id),
            account_id: self.account.id.clone(),
            mailbox_id: message
                .label_ids
                .iter()
                .find(|label| label.as_str() == "INBOX")
                .cloned(),
            thread_id: Some(message.thread_id.clone()),
            subject: gmail_header(headers, "Subject")
                .unwrap_or_default()
                .to_owned(),
            author: gmail_header(headers, "From").and_then(parse_address),
            timestamp: message
                .internal_date
                .as_deref()
                .and_then(|value| value.parse::<i64>().ok())
                .and_then(DateTime::<Utc>::from_timestamp_millis)
                .unwrap_or_else(Utc::now),
            read: !message.label_ids.iter().any(|label| label == "UNREAD"),
            starred: message.label_ids.iter().any(|label| label == "STARRED"),
            snippet: message.snippet.clone().unwrap_or_default(),
            has_attachments: message.payload.as_ref().is_some_and(part_has_attachment),
            labels: message.label_ids.clone(),
            provider_data: serde_json::json!({
                "nativeId": message.id,
                "messageId": gmail_header(headers, "Message-ID"),
                "historyId": message.history_id,
                "sizeEstimate": message.size_estimate,
            }),
        }
    }
}

#[async_trait]
impl<T, S, M> MailProvider for GmailProvider<T, S, M>
where
    T: HttpTransport + 'static,
    S: TokenSource + 'static,
    M: MimeCodec + 'static,
{
    fn kind(&self) -> &'static str {
        "gmail"
    }

    fn account(&self) -> &Account {
        &self.account
    }

    fn capabilities(&self) -> ProviderCapabilities {
        ProviderCapabilities {
            folders: false,
            labels: true,
            threads: true,
            server_search: true,
            archive: true,
            spam: true,
            push: true,
            attachment_retrieval: true,
        }
    }

    async fn list_mailboxes(&self) -> Result<Vec<Mailbox>, ProviderError> {
        Ok(self
            .rest
            .list_labels()
            .await
            .map_err(gmail_provider_error)?
            .into_iter()
            .filter(|label| label.label_list_visibility.as_deref() != Some("labelHide"))
            .map(|label| Mailbox {
                id: label.id.clone(),
                account_id: self.account.id.clone(),
                name: label.name,
                role: gmail_label_role(&label.id),
                unread: label.messages_unread.unwrap_or(0),
                total: label.messages_total.unwrap_or(0),
            })
            .collect())
    }

    async fn list_messages(&self, query: MessageQuery) -> Result<MessagePage, ProviderError> {
        let mut gmail_query = query.search.clone();
        if query.unread_only {
            let existing = gmail_query.take().unwrap_or_default();
            gmail_query = Some(format!("is:unread {existing}").trim().to_owned());
        }
        let label_ids = query.mailbox_id.into_iter().collect::<Vec<_>>();
        let page = self
            .rest
            .list_message_page(
                gmail_query.as_deref(),
                &label_ids,
                query.cursor.as_deref(),
                query.limit,
            )
            .await
            .map_err(gmail_provider_error)?;
        let ids = page
            .messages
            .into_iter()
            .map(|message| message.id)
            .collect::<Vec<_>>();
        let details = self
            .rest
            .get_messages_bounded(&ids, GmailMessageFormat::Metadata, self.detail_concurrency)
            .await
            .map_err(gmail_provider_error)?;
        Ok(MessagePage {
            messages: details
                .iter()
                .map(|message| self.map_summary(message))
                .collect(),
            next_cursor: page.next_page_token,
        })
    }

    async fn get_message(&self, id: &str) -> Result<Message, ProviderError> {
        let native_id = provider_native_id(&self.account.id, id)?;
        let wire = self
            .rest
            .get_message(native_id, GmailMessageFormat::Full)
            .await
            .map_err(gmail_provider_error)?;
        let mut text_body = None;
        let mut html_body = None;
        let mut attachments = Vec::new();
        if let Some(payload) = wire.payload.as_ref() {
            collect_gmail_parts(payload, &mut text_body, &mut html_body, &mut attachments);
        }
        let headers = wire
            .payload
            .as_ref()
            .map(|payload| payload.headers.as_slice())
            .unwrap_or_default();
        Ok(Message {
            summary: self.map_summary(&wire),
            to: gmail_header(headers, "To")
                .map(parse_addresses)
                .unwrap_or_default(),
            cc: gmail_header(headers, "Cc")
                .map(parse_addresses)
                .unwrap_or_default(),
            bcc: gmail_header(headers, "Bcc")
                .map(parse_addresses)
                .unwrap_or_default(),
            body_text: text_body,
            body_html: html_body,
            attachments,
        })
    }

    async fn apply_action(&self, action: MailAction) -> Result<(), ProviderError> {
        match action {
            MailAction::MarkRead { message_ids, read } => {
                for id in message_ids {
                    let id = provider_native_id(&self.account.id, &id)?;
                    self.rest
                        .set_read(id, read)
                        .await
                        .map_err(gmail_provider_error)?;
                }
            }
            MailAction::Star {
                message_ids,
                starred,
            } => {
                let starred_label = vec!["STARRED".to_owned()];
                for id in message_ids {
                    let id = provider_native_id(&self.account.id, &id)?;
                    let (add, remove) = if starred {
                        (starred_label.as_slice(), &[][..])
                    } else {
                        (&[][..], starred_label.as_slice())
                    };
                    self.rest
                        .modify_labels(id, add, remove)
                        .await
                        .map_err(gmail_provider_error)?;
                }
            }
            MailAction::Archive { message_ids } => {
                for id in message_ids {
                    let id = provider_native_id(&self.account.id, &id)?;
                    self.rest.archive(id).await.map_err(gmail_provider_error)?;
                }
            }
            MailAction::Trash { message_ids } => {
                for id in message_ids {
                    let id = provider_native_id(&self.account.id, &id)?;
                    self.rest.trash(id).await.map_err(gmail_provider_error)?;
                }
            }
            MailAction::Move {
                message_ids,
                mailbox_id,
            } => {
                let add = vec![mailbox_id];
                let remove = vec!["INBOX".to_owned()];
                for id in message_ids {
                    let id = provider_native_id(&self.account.id, &id)?;
                    self.rest
                        .modify_labels(id, &add, &remove)
                        .await
                        .map_err(gmail_provider_error)?;
                }
            }
            MailAction::SetLabels {
                message_ids,
                labels,
            } => {
                for id in message_ids {
                    let id = provider_native_id(&self.account.id, &id)?;
                    let current = self
                        .rest
                        .get_message(id, GmailMessageFormat::Minimal)
                        .await
                        .map_err(gmail_provider_error)?;
                    let current_labels = current.label_ids;
                    let remove = current_labels
                        .iter()
                        .filter(|label| !labels.contains(label))
                        .cloned()
                        .collect::<Vec<_>>();
                    let add = labels
                        .iter()
                        .filter(|label| !current_labels.contains(label))
                        .cloned()
                        .collect::<Vec<_>>();
                    self.rest
                        .modify_labels(id, &add, &remove)
                        .await
                        .map_err(gmail_provider_error)?;
                }
            }
        }
        Ok(())
    }

    async fn send(&self, message: OutgoingMessage) -> Result<String, ProviderError> {
        if message.account_id != self.account.id {
            return Err(ProviderError::Other(
                "outgoing message belongs to another account".into(),
            ));
        }
        let from = Address {
            name: self.account.display_name.clone(),
            address: self.account.address.clone(),
        };
        let reply_message_id = match message.in_reply_to.as_deref() {
            Some(parent_id) => Some(
                self.get_message(parent_id)
                    .await?
                    .summary
                    .provider_data
                    .get("messageId")
                    .and_then(|value| value.as_str())
                    .ok_or_else(|| {
                        ProviderError::Other("reply target has no RFC Message-ID".into())
                    })?
                    .to_owned(),
            ),
            None => None,
        };
        let raw = self
            .mime
            .build_reply(&from, &message, reply_message_id.as_deref())
            .map_err(mime_provider_error)?;
        let native_id = self
            .rest
            .send_raw(&raw)
            .await
            .map_err(gmail_provider_error)?
            .id;
        Ok(normalized_message_id(&self.account.id, &native_id))
    }

    async fn get_attachment(
        &self,
        message_id: &str,
        attachment_id: &str,
    ) -> Result<AttachmentData, ProviderError> {
        let native_id = provider_native_id(&self.account.id, message_id)?;
        let wire = self
            .rest
            .get_message(native_id, GmailMessageFormat::Full)
            .await
            .map_err(gmail_provider_error)?;
        let part = wire
            .payload
            .as_ref()
            .and_then(|part| find_attachment_part(part, attachment_id))
            .ok_or(ProviderError::NotFound)?;
        let body = part.body.as_ref().ok_or(ProviderError::NotFound)?;
        let bytes = if let Some(data) = body.data.as_deref() {
            base64_url_decode(data).map_err(gmail_provider_error)?
        } else if let Some(remote_id) = body.attachment_id.as_deref() {
            self.rest
                .get_attachment_bytes(native_id, remote_id)
                .await
                .map_err(gmail_provider_error)?
        } else {
            return Err(ProviderError::NotFound);
        };
        validate_attachment_size(bytes.len())?;
        Ok(AttachmentData {
            filename: sanitize_filename(part.filename.as_deref()),
            content_type: part
                .mime_type
                .clone()
                .unwrap_or_else(|| "application/octet-stream".into()),
            bytes,
        })
    }
}

fn provider_native_id<'a>(account_id: &str, id: &'a str) -> Result<&'a str, ProviderError> {
    id.strip_prefix(account_id)
        .and_then(|suffix| suffix.strip_prefix(':'))
        .filter(|native| !native.is_empty() && !native.contains(':'))
        .ok_or(ProviderError::NotFound)
}

fn gmail_header<'a>(headers: &'a [GmailHeader], name: &str) -> Option<&'a str> {
    headers
        .iter()
        .find(|header| header.name.eq_ignore_ascii_case(name))
        .map(|header| header.value.as_str())
}

fn parse_addresses(value: &str) -> Vec<Address> {
    value.split(',').filter_map(parse_address).collect()
}

fn parse_address(value: &str) -> Option<Address> {
    let value = value.trim();
    if let Some((name, address)) = value.rsplit_once('<') {
        Some(Address {
            name: name.trim().trim_matches('"').to_owned(),
            address: address.trim_end_matches('>').trim().to_owned(),
        })
    } else {
        value.contains('@').then(|| Address {
            name: String::new(),
            address: value.to_owned(),
        })
    }
}

fn collect_gmail_parts(
    part: &GmailMessagePart,
    text_body: &mut Option<String>,
    html_body: &mut Option<String>,
    attachments: &mut Vec<Attachment>,
) {
    let mime_type = part
        .mime_type
        .as_deref()
        .unwrap_or("application/octet-stream");
    let body = part.body.as_ref();
    if !part.filename.as_deref().unwrap_or_default().is_empty()
        || body.and_then(|body| body.attachment_id.as_ref()).is_some()
    {
        attachments.push(Attachment {
            id: body
                .and_then(|body| body.attachment_id.clone())
                .unwrap_or_else(|| format!("inline:{}", part.part_id.as_deref().unwrap_or("0"))),
            filename: sanitize_filename(part.filename.as_deref()),
            content_type: mime_type.to_owned(),
            size: body.and_then(|body| body.size).unwrap_or(0),
            inline: gmail_header(&part.headers, "Content-Disposition")
                .is_some_and(|value| value.to_ascii_lowercase().starts_with("inline")),
            content_id: gmail_header(&part.headers, "Content-ID").map(str::to_owned),
        });
    } else if let Some(data) = body.and_then(|body| body.data.as_deref())
        && let Ok(decoded) = base64_url_decode(data)
    {
        if mime_type.eq_ignore_ascii_case("text/plain") && text_body.is_none() {
            *text_body = Some(String::from_utf8_lossy(&decoded).into_owned());
        } else if mime_type.eq_ignore_ascii_case("text/html") && html_body.is_none() {
            *html_body = Some(String::from_utf8_lossy(&decoded).into_owned());
        }
    }
    for child in &part.parts {
        collect_gmail_parts(child, text_body, html_body, attachments);
    }
}

fn find_attachment_part<'a>(
    part: &'a GmailMessagePart,
    attachment_id: &str,
) -> Option<&'a GmailMessagePart> {
    let matches = part
        .body
        .as_ref()
        .and_then(|body| body.attachment_id.as_deref())
        .is_some_and(|id| id == attachment_id)
        || (attachment_id.starts_with("inline:")
            && part.part_id.as_deref() == attachment_id.strip_prefix("inline:"));
    matches.then_some(part).or_else(|| {
        part.parts
            .iter()
            .find_map(|part| find_attachment_part(part, attachment_id))
    })
}

fn part_has_attachment(part: &GmailMessagePart) -> bool {
    !part.filename.as_deref().unwrap_or_default().is_empty()
        || part
            .body
            .as_ref()
            .and_then(|body| body.attachment_id.as_ref())
            .is_some()
        || part.parts.iter().any(part_has_attachment)
}

fn gmail_label_role(id: &str) -> Option<MailboxRole> {
    match id {
        "INBOX" => Some(MailboxRole::Inbox),
        "DRAFT" => Some(MailboxRole::Drafts),
        "SENT" => Some(MailboxRole::Sent),
        "TRASH" => Some(MailboxRole::Trash),
        "SPAM" => Some(MailboxRole::Spam),
        "ALL" => Some(MailboxRole::Archive),
        _ => None,
    }
}

fn gmail_provider_error(error: GmailError) -> ProviderError {
    match error {
        GmailError::Token(error) => ProviderError::Authentication(error.to_string()),
        GmailError::Api { status: 404, .. } => ProviderError::NotFound,
        GmailError::Api { status, reason } if status == 429 || status >= 500 => {
            ProviderError::Temporary(reason)
        }
        other => ProviderError::Other(other.to_string()),
    }
}

fn mime_provider_error(error: MimeError) -> ProviderError {
    match error {
        MimeError::MessageTooLarge => ProviderError::ResourceTooLarge("message"),
        MimeError::AttachmentLimitExceeded => {
            ProviderError::ResourceTooLarge("message attachment data")
        }
        other => ProviderError::Other(format!("MIME processing failed: {other}")),
    }
}

fn validate_attachment_size(size: usize) -> Result<(), ProviderError> {
    if size > MAX_MAIL_ATTACHMENT_BYTES {
        Err(ProviderError::ResourceTooLarge("attachment"))
    } else {
        Ok(())
    }
}

fn validate_resource_id(id: &str) -> Result<(), GmailError> {
    if id.is_empty()
        || !id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
    {
        return Err(GmailError::InvalidResourceId);
    }
    Ok(())
}

fn decode_success<R: for<'de> Deserialize<'de>>(response: HttpResponse) -> Result<R, GmailError> {
    if !(200..300).contains(&response.status) {
        let reason = serde_json::from_slice::<GoogleErrorEnvelope>(&response.body)
            .ok()
            .and_then(|body| body.error.message)
            .unwrap_or_else(|| "Gmail rejected the request".to_owned());
        return Err(GmailError::Api {
            status: response.status,
            reason,
        });
    }
    serde_json::from_slice(&response.body).map_err(GmailError::Json)
}

#[derive(Deserialize)]
struct GoogleErrorEnvelope {
    error: GoogleErrorBody,
}

#[derive(Deserialize)]
struct GoogleErrorBody {
    message: Option<String>,
}

fn base64_url_encode(input: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let mut output = String::with_capacity(input.len().div_ceil(3) * 4);
    for chunk in input.chunks(3) {
        let value = (u32::from(chunk[0]) << 16)
            | (u32::from(*chunk.get(1).unwrap_or(&0)) << 8)
            | u32::from(*chunk.get(2).unwrap_or(&0));
        output.push(TABLE[((value >> 18) & 63) as usize] as char);
        output.push(TABLE[((value >> 12) & 63) as usize] as char);
        if chunk.len() > 1 {
            output.push(TABLE[((value >> 6) & 63) as usize] as char);
        }
        if chunk.len() > 2 {
            output.push(TABLE[(value & 63) as usize] as char);
        }
    }
    output
}

fn base64_url_decode(input: &str) -> Result<Vec<u8>, GmailError> {
    let mut accumulator = 0_u32;
    let mut bits = 0_u8;
    let mut output = Vec::with_capacity(input.len() * 3 / 4);
    for byte in input.bytes().filter(|byte| !byte.is_ascii_whitespace()) {
        if byte == b'=' {
            break;
        }
        let value = match byte {
            b'A'..=b'Z' => byte - b'A',
            b'a'..=b'z' => byte - b'a' + 26,
            b'0'..=b'9' => byte - b'0' + 52,
            b'-' | b'+' => 62,
            b'_' | b'/' => 63,
            _ => return Err(GmailError::InvalidBase64),
        };
        accumulator = (accumulator << 6) | u32::from(value);
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            output.push((accumulator >> bits) as u8);
            accumulator &= (1 << bits) - 1;
        }
    }
    Ok(output)
}

#[derive(Debug, Error)]
pub(crate) enum GmailError {
    #[error(transparent)]
    Token(#[from] TokenError),
    #[error(transparent)]
    Transport(#[from] HttpTransportError),
    #[error("Gmail API returned HTTP {status}: {reason}")]
    Api { status: u16, reason: String },
    #[error("Gmail returned malformed JSON")]
    Json(#[from] serde_json::Error),
    #[error("invalid Gmail resource ID")]
    InvalidResourceId,
    #[error("Gmail repeated a pagination token")]
    RepeatedPageToken,
    #[error("detail fetch concurrency must be greater than zero")]
    InvalidConcurrency,
    #[error("a detail fetch task was cancelled")]
    TaskCancelled,
    #[error("invalid Gmail URL")]
    Url(#[from] url::ParseError),
    #[error("Gmail body contains invalid base64url data")]
    InvalidBase64,
}

#[cfg(test)]
mod tests {
    use std::{collections::VecDeque, sync::Mutex};

    use super::*;
    use crate::providers::auth::{AccessToken, SecretString};

    #[test]
    fn chunked_response_reader_rejects_before_crossing_the_limit() {
        let mut body = b"123".to_vec();
        append_bounded_response_chunk(&mut body, b"45", 5).unwrap();
        assert_eq!(body, b"12345");
        assert!(append_bounded_response_chunk(&mut body, b"6", 5).is_err());
        assert_eq!(body, b"12345", "a rejected chunk must not be retained");
    }

    #[test]
    fn gmail_attachment_limit_maps_to_a_safe_provider_error() {
        assert!(matches!(
            validate_attachment_size(MAX_MAIL_ATTACHMENT_BYTES + 1),
            Err(ProviderError::ResourceTooLarge("attachment"))
        ));
    }

    #[derive(Default)]
    struct MockTransport {
        responses: Mutex<VecDeque<HttpResponse>>,
        requests: Mutex<Vec<HttpRequest>>,
    }

    impl MockTransport {
        fn with_responses(responses: impl IntoIterator<Item = HttpResponse>) -> Self {
            Self {
                responses: Mutex::new(responses.into_iter().collect()),
                requests: Mutex::new(Vec::new()),
            }
        }
    }

    #[async_trait]
    impl HttpTransport for MockTransport {
        async fn execute(&self, request: HttpRequest) -> Result<HttpResponse, HttpTransportError> {
            self.requests.lock().unwrap().push(request);
            Ok(self.responses.lock().unwrap().pop_front().unwrap())
        }
    }

    #[derive(Default)]
    struct MockTokens {
        refreshes: Mutex<Vec<bool>>,
    }

    #[async_trait]
    impl TokenSource for MockTokens {
        async fn access_token(&self, force_refresh: bool) -> Result<AccessToken, TokenError> {
            self.refreshes.lock().unwrap().push(force_refresh);
            Ok(AccessToken {
                value: SecretString::new("access-secret"),
                expires_at: None,
            })
        }
    }

    fn response(status: u16, body: &str) -> HttpResponse {
        HttpResponse {
            status,
            body: body.as_bytes().to_vec(),
        }
    }

    fn client(
        responses: impl IntoIterator<Item = HttpResponse>,
    ) -> GmailRestClient<MockTransport, MockTokens> {
        GmailRestClient::with_api_root(
            Arc::new(MockTransport::with_responses(responses)),
            Arc::new(MockTokens::default()),
            Url::parse("https://example.invalid/gmail/v1/").unwrap(),
        )
    }

    #[tokio::test]
    async fn pagination_collects_every_message_once() {
        let client = client([
            response(
                200,
                r#"{"messages":[{"id":"m1","threadId":"t1"}],"nextPageToken":"next"}"#,
            ),
            response(200, r#"{"messages":[{"id":"m2","threadId":"t2"}]}"#),
        ]);

        let messages = client.list_all_message_ids(None, &[]).await.unwrap();
        assert_eq!(
            messages
                .iter()
                .map(|message| message.id.as_str())
                .collect::<Vec<_>>(),
            ["m1", "m2"]
        );
        let requests = client.transport.requests.lock().unwrap();
        assert!(!requests[0].url.as_str().contains("pageToken"));
        assert!(requests[1].url.as_str().contains("pageToken=next"));
    }

    #[tokio::test]
    async fn stale_history_cursor_requests_full_sync() {
        let client = client([response(
            404,
            r#"{"error":{"message":"Requested entity was not found."}}"#,
        )]);

        assert!(matches!(
            client.history_since("12345").await.unwrap(),
            HistorySync::FullSyncRequired
        ));
    }

    #[tokio::test]
    async fn history_paginates_and_advances_cursor() {
        let client = client([
            response(
                200,
                r#"{"history":[{"id":"11"}],"nextPageToken":"p2","historyId":"11"}"#,
            ),
            response(200, r#"{"history":[{"id":"12"}],"historyId":"12"}"#),
        ]);

        let HistorySync::Changes {
            records,
            new_history_id,
        } = client.history_since("10").await.unwrap()
        else {
            panic!("expected incremental history");
        };
        assert_eq!(records.len(), 2);
        assert_eq!(new_history_id, "12");
    }

    #[tokio::test]
    async fn unauthorized_request_refreshes_once_and_redacts_auth_header() {
        let client = client([
            response(401, r#"{"error":{"message":"expired"}}"#),
            response(200, r#"{"messages":[]}"#),
        ]);

        client.list_message_page(None, &[], None, 10).await.unwrap();
        assert_eq!(*client.tokens.refreshes.lock().unwrap(), [false, true]);
        let debug = format!("{:?}", client.transport.requests.lock().unwrap()[0]);
        assert!(!debug.contains("access-secret"));
        assert!(debug.contains("[REDACTED]"));
    }

    #[test]
    fn raw_message_encoding_is_unpadded_base64url() {
        assert_eq!(base64_url_encode(b"subject:\xff"), "c3ViamVjdDr_");
    }

    #[test]
    fn account_scoped_ids_decode_only_for_the_owning_account() {
        let id = normalized_message_id("account-a", "18cafe123");
        assert_eq!(provider_native_id("account-a", &id).unwrap(), "18cafe123");
        assert!(provider_native_id("account-b", &id).is_err());
    }
}
