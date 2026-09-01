use std::{
    collections::{HashMap, HashSet, VecDeque},
    fmt,
    sync::Arc,
    time::Duration,
};

use async_trait::async_trait;
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use chrono::{DateTime, Utc};
use quickmail_core::{
    Account, Address, Attachment, AttachmentData, MailAction, MailProvider, Mailbox, MailboxRole,
    Message, MessagePage, MessageQuery, MessageSummary, OutgoingMessage, ProviderCapabilities,
    ProviderError, normalized_message_id,
};
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use serde_json::{Value, json};
use thiserror::Error;
use tokio::sync::RwLock;
use url::Url;

use super::{
    MAX_MAIL_ATTACHMENT_BYTES, MAX_MAIL_MESSAGE_BYTES, MAX_MIME_ATTACHMENTS,
    auth::{TokenError, TokenSource},
    mime::sanitize_filename,
};

const GRAPH_API_ROOT: &str = "https://graph.microsoft.com/v1.0/";
const GRAPH_MESSAGE_SELECT: &str = "id,conversationId,parentFolderId,subject,from,receivedDateTime,sentDateTime,isRead,flag,bodyPreview,hasAttachments,internetMessageId";
const GRAPH_MESSAGE_DETAIL_SELECT: &str = "id,conversationId,parentFolderId,subject,from,toRecipients,ccRecipients,bccRecipients,receivedDateTime,sentDateTime,isRead,flag,bodyPreview,body,hasAttachments,internetMessageId";
const GRAPH_ATTACHMENT_SELECT: &str = "id,name,contentType,size,isInline,contentId";
const MAX_GRAPH_PAGE_ITEMS: usize = 100;
const MAX_GRAPH_FOLDERS: usize = 512;
const MAX_GRAPH_FOLDER_PAGES: usize = 64;
const MAX_GRAPH_ATTACHMENT_PAGES: usize = 8;
const MAX_GRAPH_CONTINUATION_BYTES: usize = 8 * 1024;
const MAX_GRAPH_NATIVE_ID_BYTES: usize = 320;
const MAX_GRAPH_EXPOSED_ID_BYTES: usize = 512;
const MAX_GRAPH_SEARCH_BYTES: usize = 512;
const MAX_GRAPH_ACTION_MESSAGES: usize = 100;
const MAX_GRAPH_RECIPIENTS: usize = 500;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum GraphHttpMethod {
    Get,
    Post,
    Patch,
}

pub(crate) struct GraphHttpRequest {
    pub(crate) method: GraphHttpMethod,
    pub(crate) url: Url,
    pub(crate) headers: Vec<(String, String)>,
    pub(crate) body: Option<Vec<u8>>,
}

impl fmt::Debug for GraphHttpRequest {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let mut url = self.url.clone();
        // Graph search/filter query strings can contain mailbox content. Keep
        // diagnostics useful without making Debug output a data-leak path.
        url.set_query(None);
        url.set_fragment(None);
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
            .debug_struct("GraphHttpRequest")
            .field("method", &self.method)
            .field("url", &url)
            .field("headers", &headers)
            .field("body_length", &self.body.as_ref().map(Vec::len))
            .finish()
    }
}

#[derive(Debug)]
pub(crate) struct GraphHttpResponse {
    pub(crate) status: u16,
    pub(crate) body: Vec<u8>,
}

#[derive(Debug, Error)]
pub(crate) enum GraphTransportError {
    #[error("Microsoft Graph HTTP transport failed")]
    Failed,
    #[error("Microsoft Graph response exceeded the configured size limit")]
    ResponseTooLarge,
}

#[async_trait]
pub(crate) trait GraphHttpTransport: Send + Sync {
    async fn execute(
        &self,
        request: GraphHttpRequest,
    ) -> Result<GraphHttpResponse, GraphTransportError>;
}

/// A pooled, redirect-free HTTPS transport. Graph continuation URLs are also
/// validated by `MicrosoftGraphClient` before they reach this layer.
pub(crate) struct ReqwestGraphTransport {
    client: reqwest::Client,
    max_response_bytes: usize,
}

impl ReqwestGraphTransport {
    pub(crate) fn new() -> Result<Self, ProviderError> {
        let client = reqwest::Client::builder()
            .connect_timeout(Duration::from_secs(15))
            .timeout(Duration::from_secs(90))
            .pool_idle_timeout(Duration::from_secs(90))
            .pool_max_idle_per_host(8)
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .map_err(|_| {
                ProviderError::Temporary("Microsoft Graph transport unavailable".into())
            })?;
        Ok(Self {
            client,
            max_response_bytes: MAX_MAIL_MESSAGE_BYTES,
        })
    }
}

#[async_trait]
impl GraphHttpTransport for ReqwestGraphTransport {
    async fn execute(
        &self,
        request: GraphHttpRequest,
    ) -> Result<GraphHttpResponse, GraphTransportError> {
        if request.url.scheme() != "https" || request.url.host_str() != Some("graph.microsoft.com")
        {
            return Err(GraphTransportError::Failed);
        }
        let method = match request.method {
            GraphHttpMethod::Get => reqwest::Method::GET,
            GraphHttpMethod::Post => reqwest::Method::POST,
            GraphHttpMethod::Patch => reqwest::Method::PATCH,
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
            .map_err(|_| GraphTransportError::Failed)?;
        let status = response.status().as_u16();
        if response
            .content_length()
            .is_some_and(|length| length > self.max_response_bytes as u64)
        {
            return Err(GraphTransportError::ResponseTooLarge);
        }
        let initial_capacity = response
            .content_length()
            .unwrap_or_default()
            .min(self.max_response_bytes as u64) as usize;
        let mut body = Vec::with_capacity(initial_capacity);
        while let Some(chunk) = response
            .chunk()
            .await
            .map_err(|_| GraphTransportError::Failed)?
        {
            append_bounded_chunk(&mut body, &chunk, self.max_response_bytes)?;
        }
        Ok(GraphHttpResponse { status, body })
    }
}

fn append_bounded_chunk(
    body: &mut Vec<u8>,
    chunk: &[u8],
    limit: usize,
) -> Result<(), GraphTransportError> {
    if chunk.len() > limit.saturating_sub(body.len()) {
        return Err(GraphTransportError::ResponseTooLarge);
    }
    body.extend_from_slice(chunk);
    Ok(())
}

#[derive(Clone, Debug, Default, Deserialize)]
struct GraphCollection<T> {
    #[serde(default)]
    value: Vec<T>,
    #[serde(rename = "@odata.nextLink")]
    next_link: Option<String>,
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct GraphFolder {
    id: String,
    display_name: String,
    #[serde(default)]
    child_folder_count: u64,
    #[serde(default)]
    unread_item_count: u64,
    #[serde(default)]
    total_item_count: u64,
    #[serde(default)]
    is_hidden: bool,
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct GraphMessage {
    id: String,
    conversation_id: Option<String>,
    parent_folder_id: Option<String>,
    subject: Option<String>,
    from: Option<GraphRecipient>,
    #[serde(default)]
    to_recipients: Vec<GraphRecipient>,
    #[serde(default)]
    cc_recipients: Vec<GraphRecipient>,
    #[serde(default)]
    bcc_recipients: Vec<GraphRecipient>,
    received_date_time: Option<DateTime<Utc>>,
    sent_date_time: Option<DateTime<Utc>>,
    #[serde(default)]
    is_read: bool,
    flag: Option<GraphFlag>,
    body_preview: Option<String>,
    body: Option<GraphItemBody>,
    #[serde(default)]
    has_attachments: bool,
    internet_message_id: Option<String>,
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct GraphFlag {
    flag_status: Option<String>,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct GraphEmailAddress {
    #[serde(default, skip_serializing_if = "String::is_empty")]
    name: String,
    address: String,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct GraphRecipient {
    email_address: GraphEmailAddress,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct GraphItemBody {
    content_type: String,
    content: String,
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct GraphAttachment {
    #[serde(rename = "@odata.type")]
    odata_type: Option<String>,
    id: String,
    name: Option<String>,
    content_type: Option<String>,
    size: Option<u64>,
    #[serde(default)]
    is_inline: bool,
    content_id: Option<String>,
}

#[derive(Clone, Debug, Deserialize)]
struct GraphCreatedMessage {
    id: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct GraphDraftMessage {
    subject: String,
    body: GraphItemBody,
    to_recipients: Vec<GraphRecipient>,
    cc_recipients: Vec<GraphRecipient>,
    bcc_recipients: Vec<GraphRecipient>,
}

#[derive(Debug, Deserialize)]
struct GraphErrorEnvelope {
    error: GraphErrorBody,
}

#[derive(Debug, Deserialize)]
struct GraphErrorBody {
    code: Option<String>,
}

pub(crate) struct MicrosoftGraphClient<T, S> {
    transport: Arc<T>,
    tokens: Arc<S>,
    api_root: Url,
}

impl<T, S> Clone for MicrosoftGraphClient<T, S> {
    fn clone(&self) -> Self {
        Self {
            transport: self.transport.clone(),
            tokens: self.tokens.clone(),
            api_root: self.api_root.clone(),
        }
    }
}

impl<T, S> MicrosoftGraphClient<T, S>
where
    T: GraphHttpTransport + 'static,
    S: TokenSource + 'static,
{
    pub(crate) fn new(transport: Arc<T>, tokens: Arc<S>) -> Self {
        Self {
            transport,
            tokens,
            api_root: Url::parse(GRAPH_API_ROOT).expect("Microsoft Graph API root is static"),
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

    fn endpoint(&self, segments: &[&str]) -> Result<Url, GraphError> {
        let mut url = self.api_root.clone();
        {
            let mut path = url
                .path_segments_mut()
                .map_err(|_| GraphError::InvalidUrl)?;
            path.pop_if_empty();
            for segment in segments {
                if segment.is_empty() || segment.bytes().any(|byte| byte == 0) {
                    return Err(GraphError::InvalidResourceId);
                }
                path.push(segment);
            }
        }
        self.validate_api_url(&url)?;
        Ok(url)
    }

    fn validate_api_url(&self, url: &Url) -> Result<(), GraphError> {
        if url.as_str().len() > MAX_GRAPH_CONTINUATION_BYTES
            || url.scheme() != "https"
            || url.username() != ""
            || url.password().is_some()
            || url.host_str() != self.api_root.host_str()
            || url.port_or_known_default() != self.api_root.port_or_known_default()
            || !url.path().starts_with(self.api_root.path())
            || url.fragment().is_some()
        {
            return Err(GraphError::InvalidContinuation);
        }
        Ok(())
    }

    fn continuation_url(&self, cursor: &str) -> Result<Url, GraphError> {
        if cursor.is_empty() || cursor.len() > MAX_GRAPH_CONTINUATION_BYTES * 2 {
            return Err(GraphError::InvalidContinuation);
        }
        let bytes = URL_SAFE_NO_PAD
            .decode(cursor)
            .map_err(|_| GraphError::InvalidContinuation)?;
        let value = std::str::from_utf8(&bytes).map_err(|_| GraphError::InvalidContinuation)?;
        let url = Url::parse(value).map_err(|_| GraphError::InvalidContinuation)?;
        self.validate_api_url(&url)?;
        Ok(url)
    }

    fn continuation_cursor(&self, link: &str, current: &Url) -> Result<String, GraphError> {
        if link.len() > MAX_GRAPH_CONTINUATION_BYTES {
            return Err(GraphError::InvalidContinuation);
        }
        let url = Url::parse(link).map_err(|_| GraphError::InvalidContinuation)?;
        self.validate_api_url(&url)?;
        self.validate_next_url(&url, current)?;
        Ok(URL_SAFE_NO_PAD.encode(url.as_str()))
    }

    fn validate_next_url(&self, next: &Url, current: &Url) -> Result<(), GraphError> {
        self.validate_api_url(next)?;
        if next.path() != current.path() {
            return Err(GraphError::InvalidContinuation);
        }
        if next == current {
            return Err(GraphError::RepeatedContinuation);
        }
        Ok(())
    }

    async fn list_message_page(
        &self,
        query: &MessageQuery,
        native_folder_id: Option<&str>,
    ) -> Result<(Vec<GraphMessage>, Option<String>), GraphError> {
        let collection_url = if let Some(folder_id) = native_folder_id {
            self.endpoint(&["me", "mailFolders", folder_id, "messages"])?
        } else {
            self.endpoint(&["me", "messages"])?
        };
        let url = if let Some(cursor) = query.cursor.as_deref() {
            let url = self.continuation_url(cursor)?;
            if url.path() != collection_url.path() {
                return Err(GraphError::InvalidContinuation);
            }
            url
        } else {
            let mut url = collection_url;
            let limit = query
                .limit
                .clamp(1, MAX_GRAPH_PAGE_ITEMS as u32)
                .to_string();
            {
                let mut pairs = url.query_pairs_mut();
                pairs.append_pair("$top", &limit);
                pairs.append_pair("$select", GRAPH_MESSAGE_SELECT);
                if let Some(search) = query
                    .search
                    .as_deref()
                    .filter(|search| !search.trim().is_empty())
                {
                    pairs.append_pair("$search", &graph_search_value(search)?);
                    if query.unread_only {
                        pairs.append_pair("$filter", "isRead eq false");
                    }
                } else {
                    if query.unread_only {
                        pairs.append_pair(
                            "$filter",
                            "receivedDateTime ge 1900-01-01T00:00:00Z and isRead eq false",
                        );
                    }
                    pairs.append_pair("$orderby", "receivedDateTime desc");
                }
            }
            url
        };
        let page: GraphCollection<GraphMessage> = self
            .json_request(GraphHttpMethod::Get, url.clone(), None, &[])
            .await?;
        if page.value.len() > MAX_GRAPH_PAGE_ITEMS {
            return Err(GraphError::PageLimitExceeded);
        }
        let next_cursor = page
            .next_link
            .as_deref()
            .map(|link| self.continuation_cursor(link, &url))
            .transpose()?;
        Ok((page.value, next_cursor))
    }

    async fn list_all_folders(&self) -> Result<Vec<GraphFolder>, GraphError> {
        let mut initial = self.endpoint(&["me", "mailFolders"])?;
        initial
            .query_pairs_mut()
            .append_pair("includeHiddenFolders", "false")
            .append_pair("$top", &MAX_GRAPH_PAGE_ITEMS.to_string());
        let mut pending = VecDeque::from([initial]);
        let mut seen_urls = HashSet::new();
        let mut seen_ids = HashSet::new();
        let mut folders = Vec::new();
        let mut pages = 0_usize;
        while let Some(url) = pending.pop_front() {
            self.validate_api_url(&url)?;
            if !seen_urls.insert(url.as_str().to_owned()) {
                return Err(GraphError::RepeatedContinuation);
            }
            pages += 1;
            if pages > MAX_GRAPH_FOLDER_PAGES {
                return Err(GraphError::PageLimitExceeded);
            }
            let page: GraphCollection<GraphFolder> = self
                .json_request(GraphHttpMethod::Get, url.clone(), None, &[])
                .await?;
            if page.value.len() > MAX_GRAPH_PAGE_ITEMS {
                return Err(GraphError::PageLimitExceeded);
            }
            for folder in page.value {
                validate_native_id(&folder.id)?;
                if folder.child_folder_count > 0 {
                    let mut child_url =
                        self.endpoint(&["me", "mailFolders", &folder.id, "childFolders"])?;
                    child_url
                        .query_pairs_mut()
                        .append_pair("includeHiddenFolders", "false")
                        .append_pair("$top", &MAX_GRAPH_PAGE_ITEMS.to_string());
                    pending.push_back(child_url);
                }
                if !folder.is_hidden && seen_ids.insert(folder.id.clone()) {
                    folders.push(folder);
                    if folders.len() > MAX_GRAPH_FOLDERS {
                        return Err(GraphError::PageLimitExceeded);
                    }
                }
            }
            if let Some(link) = page.next_link {
                let next = Url::parse(&link).map_err(|_| GraphError::InvalidContinuation)?;
                self.validate_next_url(&next, &url)?;
                pending.push_back(next);
            }
        }
        Ok(folders)
    }

    async fn well_known_folder_roles(
        &self,
    ) -> Result<(HashMap<String, MailboxRole>, Vec<GraphFolder>), GraphError> {
        let mut roles = HashMap::new();
        let mut folders = Vec::new();
        for (well_known, role) in [
            ("inbox", MailboxRole::Inbox),
            ("drafts", MailboxRole::Drafts),
            ("sentitems", MailboxRole::Sent),
            ("archive", MailboxRole::Archive),
            ("deleteditems", MailboxRole::Trash),
            ("junkemail", MailboxRole::Spam),
        ] {
            let url = self.endpoint(&["me", "mailFolders", well_known])?;
            let response = self.request(GraphHttpMethod::Get, url, None, &[]).await?;
            if response.status == 404 {
                continue;
            }
            let folder: GraphFolder = decode_graph_json(response)?;
            validate_native_id(&folder.id)?;
            roles.insert(folder.id.clone(), role);
            folders.push(folder);
        }
        Ok((roles, folders))
    }

    async fn get_message(&self, native_id: &str) -> Result<GraphMessage, GraphError> {
        validate_native_id(native_id)?;
        let mut url = self.endpoint(&["me", "messages", native_id])?;
        url.query_pairs_mut()
            .append_pair("$select", GRAPH_MESSAGE_DETAIL_SELECT);
        self.json_request(
            GraphHttpMethod::Get,
            url,
            None,
            &["outlook.body-content-type=\"html\""],
        )
        .await
    }

    async fn list_attachments(
        &self,
        native_message_id: &str,
    ) -> Result<Vec<GraphAttachment>, GraphError> {
        validate_native_id(native_message_id)?;
        let mut initial = self.endpoint(&["me", "messages", native_message_id, "attachments"])?;
        initial
            .query_pairs_mut()
            .append_pair("$top", &MAX_GRAPH_PAGE_ITEMS.to_string())
            .append_pair("$select", GRAPH_ATTACHMENT_SELECT);
        let mut url = Some(initial);
        let mut seen = HashSet::new();
        let mut attachments = Vec::new();
        let mut pages = 0_usize;
        while let Some(current) = url.take() {
            if !seen.insert(current.as_str().to_owned()) {
                return Err(GraphError::RepeatedContinuation);
            }
            pages += 1;
            if pages > MAX_GRAPH_ATTACHMENT_PAGES {
                return Err(GraphError::PageLimitExceeded);
            }
            let page: GraphCollection<GraphAttachment> = self
                .json_request(GraphHttpMethod::Get, current.clone(), None, &[])
                .await?;
            attachments.extend(page.value);
            if attachments.len() > MAX_MIME_ATTACHMENTS {
                return Err(GraphError::AttachmentLimitExceeded);
            }
            url = page
                .next_link
                .map(|link| {
                    let next = Url::parse(&link).map_err(|_| GraphError::InvalidContinuation)?;
                    self.validate_next_url(&next, &current)?;
                    Ok::<Url, GraphError>(next)
                })
                .transpose()?;
            if let Some(next) = url.as_ref() {
                self.validate_api_url(next)?;
            }
        }
        Ok(attachments)
    }

    async fn get_attachment(
        &self,
        native_message_id: &str,
        native_attachment_id: &str,
    ) -> Result<(GraphAttachment, Vec<u8>), GraphError> {
        validate_native_id(native_message_id)?;
        validate_native_id(native_attachment_id)?;
        let mut metadata_url = self.endpoint(&[
            "me",
            "messages",
            native_message_id,
            "attachments",
            native_attachment_id,
        ])?;
        metadata_url
            .query_pairs_mut()
            .append_pair("$select", GRAPH_ATTACHMENT_SELECT);
        let attachment: GraphAttachment = self
            .json_request(GraphHttpMethod::Get, metadata_url, None, &[])
            .await?;
        if attachment.odata_type.as_deref() != Some("#microsoft.graph.fileAttachment") {
            return Err(GraphError::UnsupportedAttachment);
        }
        if attachment.size.unwrap_or_default() > MAX_MAIL_ATTACHMENT_BYTES as u64 {
            return Err(GraphError::AttachmentTooLarge);
        }
        let raw_url = self.endpoint(&[
            "me",
            "messages",
            native_message_id,
            "attachments",
            native_attachment_id,
            "$value",
        ])?;
        let response = self
            .request_with_accept(
                GraphHttpMethod::Get,
                raw_url,
                None,
                &[],
                "application/octet-stream",
            )
            .await?;
        let bytes = decode_graph_bytes(response)?;
        if bytes.len() > MAX_MAIL_ATTACHMENT_BYTES {
            return Err(GraphError::AttachmentTooLarge);
        }
        Ok((attachment, bytes))
    }

    async fn update_message(&self, native_id: &str, body: Value) -> Result<(), GraphError> {
        validate_native_id(native_id)?;
        let url = self.endpoint(&["me", "messages", native_id])?;
        let body = bounded_json(&body)?;
        let _: GraphMessage = self
            .json_request(GraphHttpMethod::Patch, url, Some(body), &[])
            .await?;
        Ok(())
    }

    async fn move_message(
        &self,
        native_id: &str,
        native_destination_id: &str,
    ) -> Result<(), GraphError> {
        validate_native_id(native_id)?;
        validate_native_id(native_destination_id)?;
        let url = self.endpoint(&["me", "messages", native_id, "move"])?;
        let body = bounded_json(&json!({"destinationId": native_destination_id}))?;
        let _: GraphMessage = self
            .json_request(GraphHttpMethod::Post, url, Some(body), &[])
            .await?;
        Ok(())
    }

    async fn create_draft(&self, message: &GraphDraftMessage) -> Result<String, GraphError> {
        let url = self.endpoint(&["me", "messages"])?;
        let body = bounded_json(message)?;
        let created: GraphCreatedMessage = self
            .json_request(GraphHttpMethod::Post, url, Some(body), &[])
            .await?;
        validate_native_id(&created.id)?;
        Ok(created.id)
    }

    async fn create_reply_draft(&self, parent_id: &str) -> Result<String, GraphError> {
        validate_native_id(parent_id)?;
        let url = self.endpoint(&["me", "messages", parent_id, "createReply"])?;
        let created: GraphCreatedMessage = self
            .json_request(GraphHttpMethod::Post, url, None, &[])
            .await?;
        validate_native_id(&created.id)?;
        Ok(created.id)
    }

    async fn update_draft(
        &self,
        native_draft_id: &str,
        message: &GraphDraftMessage,
    ) -> Result<(), GraphError> {
        validate_native_id(native_draft_id)?;
        let url = self.endpoint(&["me", "messages", native_draft_id])?;
        let body = bounded_json(message)?;
        let _: GraphCreatedMessage = self
            .json_request(GraphHttpMethod::Patch, url, Some(body), &[])
            .await?;
        Ok(())
    }

    async fn send_draft(&self, native_draft_id: &str) -> Result<(), GraphError> {
        validate_native_id(native_draft_id)?;
        let url = self.endpoint(&["me", "messages", native_draft_id, "send"])?;
        let response = self.request(GraphHttpMethod::Post, url, None, &[]).await?;
        decode_graph_empty(response)
    }

    async fn json_request<R: DeserializeOwned>(
        &self,
        method: GraphHttpMethod,
        url: Url,
        body: Option<Vec<u8>>,
        preferences: &[&str],
    ) -> Result<R, GraphError> {
        decode_graph_json(self.request(method, url, body, preferences).await?)
    }

    async fn request(
        &self,
        method: GraphHttpMethod,
        url: Url,
        body: Option<Vec<u8>>,
        preferences: &[&str],
    ) -> Result<GraphHttpResponse, GraphError> {
        self.request_with_accept(method, url, body, preferences, "application/json")
            .await
    }

    async fn request_with_accept(
        &self,
        method: GraphHttpMethod,
        url: Url,
        body: Option<Vec<u8>>,
        preferences: &[&str],
        accept: &str,
    ) -> Result<GraphHttpResponse, GraphError> {
        let first = self
            .execute_authorized(
                method,
                url.clone(),
                body.clone(),
                preferences,
                accept,
                false,
            )
            .await?;
        if first.status == 401 {
            self.execute_authorized(method, url, body, preferences, accept, true)
                .await
        } else {
            Ok(first)
        }
    }

    async fn execute_authorized(
        &self,
        method: GraphHttpMethod,
        url: Url,
        body: Option<Vec<u8>>,
        preferences: &[&str],
        accept: &str,
        force_refresh: bool,
    ) -> Result<GraphHttpResponse, GraphError> {
        self.validate_api_url(&url)?;
        let token = self.tokens.access_token(force_refresh).await?;
        let mut prefer = vec!["IdType=\"ImmutableId\""];
        prefer.extend_from_slice(preferences);
        let mut headers = vec![
            (
                "Authorization".to_owned(),
                format!("Bearer {}", token.value.expose_secret()),
            ),
            ("Accept".to_owned(), accept.to_owned()),
            ("Prefer".to_owned(), prefer.join(", ")),
        ];
        if body.is_some() {
            headers.push(("Content-Type".to_owned(), "application/json".to_owned()));
        }
        self.transport
            .execute(GraphHttpRequest {
                method,
                url,
                headers,
                body,
            })
            .await
            .map_err(GraphError::Transport)
    }
}

pub(crate) struct MicrosoftGraphProvider<T, S> {
    account: Account,
    client: MicrosoftGraphClient<T, S>,
    role_ids: RwLock<Option<HashMap<String, MailboxRole>>>,
}

impl<T, S> MicrosoftGraphProvider<T, S>
where
    T: GraphHttpTransport + 'static,
    S: TokenSource + 'static,
{
    pub(crate) fn new(account: Account, transport: Arc<T>, tokens: Arc<S>) -> Self {
        Self {
            account,
            client: MicrosoftGraphClient::new(transport, tokens),
            role_ids: RwLock::new(None),
        }
    }

    #[cfg(test)]
    fn with_client(account: Account, client: MicrosoftGraphClient<T, S>) -> Self {
        Self {
            account,
            client,
            role_ids: RwLock::new(None),
        }
    }

    fn map_summary(&self, message: &GraphMessage) -> Result<MessageSummary, GraphError> {
        let message_id = graph_message_id(&self.account.id, &message.id)?;
        let thread_native = message
            .conversation_id
            .as_deref()
            .filter(|value| !value.is_empty())
            .unwrap_or(&message.id);
        let thread_id = graph_thread_id(&self.account.id, thread_native)?;
        let mailbox_id = message
            .parent_folder_id
            .as_deref()
            .map(graph_folder_id)
            .transpose()?;
        Ok(MessageSummary {
            id: message_id,
            account_id: self.account.id.clone(),
            mailbox_id,
            thread_id: Some(thread_id),
            subject: message.subject.clone().unwrap_or_default(),
            author: message.from.as_ref().and_then(graph_address),
            timestamp: message
                .received_date_time
                .or(message.sent_date_time)
                .unwrap_or(DateTime::<Utc>::UNIX_EPOCH),
            read: message.is_read,
            starred: message
                .flag
                .as_ref()
                .and_then(|flag| flag.flag_status.as_deref())
                .is_some_and(|status| status.eq_ignore_ascii_case("flagged")),
            snippet: message.body_preview.clone().unwrap_or_default(),
            has_attachments: message.has_attachments,
            labels: Vec::new(),
            provider_data: json!({
                "messageId": message.internet_message_id,
                "provider": "microsoftGraph",
            }),
        })
    }
}

#[async_trait]
impl<T, S> MailProvider for MicrosoftGraphProvider<T, S>
where
    T: GraphHttpTransport + 'static,
    S: TokenSource + 'static,
{
    fn kind(&self) -> &'static str {
        "microsoft_graph"
    }

    fn account(&self) -> &Account {
        &self.account
    }

    fn capabilities(&self) -> ProviderCapabilities {
        ProviderCapabilities {
            folders: true,
            labels: false,
            threads: true,
            server_search: true,
            archive: true,
            spam: true,
            push: false,
            attachment_retrieval: true,
        }
    }

    async fn list_mailboxes(&self) -> Result<Vec<Mailbox>, ProviderError> {
        let mut folders = self
            .client
            .list_all_folders()
            .await
            .map_err(graph_provider_error)?;
        let roles = if let Some(roles) = self.role_ids.read().await.as_ref() {
            roles.clone()
        } else {
            let (roles, special_folders) = self
                .client
                .well_known_folder_roles()
                .await
                .map_err(graph_provider_error)?;
            let mut seen = folders
                .iter()
                .map(|folder| folder.id.clone())
                .collect::<HashSet<_>>();
            folders.extend(
                special_folders
                    .into_iter()
                    .filter(|folder| seen.insert(folder.id.clone())),
            );
            *self.role_ids.write().await = Some(roles.clone());
            roles
        };
        let mut mailboxes = folders
            .into_iter()
            .map(|folder| {
                Ok(Mailbox {
                    id: graph_folder_id(&folder.id)?,
                    account_id: self.account.id.clone(),
                    name: folder.display_name,
                    role: roles.get(&folder.id).copied(),
                    unread: folder.unread_item_count,
                    total: folder.total_item_count,
                })
            })
            .collect::<Result<Vec<_>, GraphError>>()
            .map_err(graph_provider_error)?;
        // The daemon foreground-syncs the first mailbox. Keep Inbox first even
        // when Graph returns a localized or arbitrary folder order, and make
        // the remaining order deterministic for predictable background work.
        mailboxes.sort_by(|left, right| {
            mailbox_role_rank(left.role)
                .cmp(&mailbox_role_rank(right.role))
                .then_with(|| left.name.to_lowercase().cmp(&right.name.to_lowercase()))
                .then_with(|| left.id.cmp(&right.id))
        });
        Ok(mailboxes)
    }

    async fn list_messages(&self, query: MessageQuery) -> Result<MessagePage, ProviderError> {
        if query
            .account_id
            .as_deref()
            .is_some_and(|account_id| account_id != self.account.id)
        {
            return Err(ProviderError::NotFound);
        }
        let native_folder_id = query
            .mailbox_id
            .as_deref()
            .map(graph_native_folder_id)
            .transpose()
            .map_err(graph_provider_error)?;
        let (messages, next_cursor) = self
            .client
            .list_message_page(&query, native_folder_id.as_deref())
            .await
            .map_err(graph_provider_error)?;
        Ok(MessagePage {
            messages: messages
                .iter()
                .map(|message| self.map_summary(message))
                .collect::<Result<Vec<_>, _>>()
                .map_err(graph_provider_error)?,
            next_cursor,
        })
    }

    async fn get_message(&self, id: &str) -> Result<Message, ProviderError> {
        let native_id =
            graph_native_message_id(&self.account.id, id).map_err(graph_provider_error)?;
        let message = self
            .client
            .get_message(&native_id)
            .await
            .map_err(graph_provider_error)?;
        let may_have_inline_attachments = message
            .body
            .as_ref()
            .is_some_and(|body| body.content.to_ascii_lowercase().contains("cid:"));
        let attachments = if message.has_attachments || may_have_inline_attachments {
            self.client
                .list_attachments(&native_id)
                .await
                .map_err(graph_provider_error)?
                .into_iter()
                .map(graph_attachment)
                .collect::<Result<Vec<_>, _>>()
                .map_err(graph_provider_error)?
        } else {
            Vec::new()
        };
        let (body_text, body_html) = match message.body.as_ref() {
            Some(body) if body.content_type.eq_ignore_ascii_case("html") => {
                (None, Some(body.content.clone()))
            }
            Some(body) => (Some(body.content.clone()), None),
            None => (None, None),
        };
        let mut summary = self.map_summary(&message).map_err(graph_provider_error)?;
        summary.has_attachments |= !attachments.is_empty();
        Ok(Message {
            summary,
            to: message
                .to_recipients
                .iter()
                .filter_map(graph_address)
                .collect(),
            cc: message
                .cc_recipients
                .iter()
                .filter_map(graph_address)
                .collect(),
            bcc: message
                .bcc_recipients
                .iter()
                .filter_map(graph_address)
                .collect(),
            body_text,
            body_html,
            attachments,
        })
    }

    async fn apply_action(&self, action: MailAction) -> Result<(), ProviderError> {
        if action_message_count(&action) > MAX_GRAPH_ACTION_MESSAGES {
            return Err(ProviderError::ResourceTooLarge("mail action batch"));
        }
        match action {
            MailAction::MarkRead { message_ids, read } => {
                for id in message_ids {
                    let native = graph_native_message_id(&self.account.id, &id)
                        .map_err(graph_provider_error)?;
                    self.client
                        .update_message(&native, json!({"isRead": read}))
                        .await
                        .map_err(graph_provider_error)?;
                }
            }
            MailAction::Star {
                message_ids,
                starred,
            } => {
                let flag_status = if starred { "flagged" } else { "notFlagged" };
                for id in message_ids {
                    let native = graph_native_message_id(&self.account.id, &id)
                        .map_err(graph_provider_error)?;
                    self.client
                        .update_message(&native, json!({"flag": {"flagStatus": flag_status}}))
                        .await
                        .map_err(graph_provider_error)?;
                }
            }
            MailAction::Archive { message_ids } => {
                for id in message_ids {
                    let native = graph_native_message_id(&self.account.id, &id)
                        .map_err(graph_provider_error)?;
                    self.client
                        .move_message(&native, "archive")
                        .await
                        .map_err(graph_provider_error)?;
                }
            }
            MailAction::Trash { message_ids } => {
                for id in message_ids {
                    let native = graph_native_message_id(&self.account.id, &id)
                        .map_err(graph_provider_error)?;
                    self.client
                        .move_message(&native, "deleteditems")
                        .await
                        .map_err(graph_provider_error)?;
                }
            }
            MailAction::Move {
                message_ids,
                mailbox_id,
            } => {
                let destination =
                    graph_native_folder_id(&mailbox_id).map_err(graph_provider_error)?;
                for id in message_ids {
                    let native = graph_native_message_id(&self.account.id, &id)
                        .map_err(graph_provider_error)?;
                    self.client
                        .move_message(&native, &destination)
                        .await
                        .map_err(graph_provider_error)?;
                }
            }
            MailAction::SetLabels { .. } => {
                return Err(ProviderError::Unsupported(
                    "Microsoft Graph uses folders instead of labels".into(),
                ));
            }
        }
        Ok(())
    }

    async fn send(&self, message: OutgoingMessage) -> Result<String, ProviderError> {
        if message.account_id != self.account.id {
            return Err(ProviderError::NotFound);
        }
        let draft = graph_draft_message(&message).map_err(graph_provider_error)?;
        let native_draft_id = if let Some(parent_id) = message.in_reply_to.as_deref() {
            let parent_native = graph_native_message_id(&self.account.id, parent_id)
                .map_err(graph_provider_error)?;
            let draft_id = self
                .client
                .create_reply_draft(&parent_native)
                .await
                .map_err(graph_provider_error)?;
            self.client
                .update_draft(&draft_id, &draft)
                .await
                .map_err(graph_provider_error)?;
            draft_id
        } else {
            self.client
                .create_draft(&draft)
                .await
                .map_err(graph_provider_error)?
        };
        self.client
            .send_draft(&native_draft_id)
            .await
            .map_err(graph_provider_error)?;
        graph_message_id(&self.account.id, &native_draft_id).map_err(graph_provider_error)
    }

    async fn get_attachment(
        &self,
        message_id: &str,
        attachment_id: &str,
    ) -> Result<AttachmentData, ProviderError> {
        let native_message =
            graph_native_message_id(&self.account.id, message_id).map_err(graph_provider_error)?;
        let native_attachment =
            graph_native_attachment_id(attachment_id).map_err(graph_provider_error)?;
        let (attachment, bytes) = self
            .client
            .get_attachment(&native_message, &native_attachment)
            .await
            .map_err(graph_provider_error)?;
        Ok(AttachmentData {
            filename: sanitize_filename(attachment.name.as_deref()),
            content_type: safe_content_type(attachment.content_type.as_deref()),
            bytes,
        })
    }
}

fn graph_draft_message(message: &OutgoingMessage) -> Result<GraphDraftMessage, GraphError> {
    let recipient_count = message.to.len() + message.cc.len() + message.bcc.len();
    if recipient_count == 0 || recipient_count > MAX_GRAPH_RECIPIENTS {
        return Err(GraphError::InvalidOutgoingMessage);
    }
    if message.subject.len() > 998
        || message
            .subject
            .bytes()
            .any(|byte| matches!(byte, b'\r' | b'\n' | 0))
    {
        return Err(GraphError::InvalidOutgoingMessage);
    }
    let body = if let Some(html) = message.body_html.as_ref() {
        GraphItemBody {
            content_type: "HTML".into(),
            content: html.clone(),
        }
    } else {
        GraphItemBody {
            content_type: "Text".into(),
            content: message.body_text.clone().unwrap_or_default(),
        }
    };
    if body.content.len() > MAX_MAIL_MESSAGE_BYTES {
        return Err(GraphError::RequestTooLarge);
    }
    Ok(GraphDraftMessage {
        subject: message.subject.clone(),
        body,
        to_recipients: graph_recipients(&message.to)?,
        cc_recipients: graph_recipients(&message.cc)?,
        bcc_recipients: graph_recipients(&message.bcc)?,
    })
}

fn graph_recipients(addresses: &[Address]) -> Result<Vec<GraphRecipient>, GraphError> {
    addresses
        .iter()
        .map(|address| {
            if !is_mail_address(&address.address)
                || address.name.len() > 998
                || address
                    .name
                    .bytes()
                    .any(|byte| matches!(byte, b'\r' | b'\n' | 0))
            {
                return Err(GraphError::InvalidOutgoingMessage);
            }
            Ok(GraphRecipient {
                email_address: GraphEmailAddress {
                    name: address.name.clone(),
                    address: address.address.trim().to_owned(),
                },
            })
        })
        .collect()
}

fn graph_address(recipient: &GraphRecipient) -> Option<Address> {
    let address = recipient.email_address.address.trim();
    if !is_mail_address(address) {
        return None;
    }
    Some(Address {
        name: recipient
            .email_address
            .name
            .chars()
            .filter(|character| !character.is_control())
            .take(998)
            .collect(),
        address: address.to_owned(),
    })
}

fn is_mail_address(value: &str) -> bool {
    let value = value.trim();
    if value.is_empty()
        || value.len() > 320
        || value
            .chars()
            .any(|character| character.is_whitespace() || character.is_control())
    {
        return false;
    }
    let Some((local, domain)) = value.split_once('@') else {
        return false;
    };
    !local.is_empty() && !domain.is_empty() && !domain.contains('@')
}

fn graph_attachment(attachment: GraphAttachment) -> Result<Attachment, GraphError> {
    Ok(Attachment {
        id: graph_attachment_id(&attachment.id)?,
        filename: sanitize_filename(attachment.name.as_deref()),
        content_type: safe_content_type(attachment.content_type.as_deref()),
        size: attachment.size.unwrap_or_default(),
        inline: attachment.is_inline,
        content_id: attachment.content_id.filter(|content_id| {
            content_id.len() <= 998 && !content_id.contains(['\r', '\n', '\0'])
        }),
    })
}

fn safe_content_type(content_type: Option<&str>) -> String {
    content_type
        .map(str::trim)
        .filter(|value| {
            !value.is_empty()
                && value.len() <= 255
                && !value.chars().any(char::is_control)
                && value.contains('/')
        })
        .unwrap_or("application/octet-stream")
        .to_owned()
}

fn action_message_count(action: &MailAction) -> usize {
    match action {
        MailAction::MarkRead { message_ids, .. }
        | MailAction::Star { message_ids, .. }
        | MailAction::Archive { message_ids }
        | MailAction::Trash { message_ids }
        | MailAction::Move { message_ids, .. }
        | MailAction::SetLabels { message_ids, .. } => message_ids.len(),
    }
}

const fn mailbox_role_rank(role: Option<MailboxRole>) -> u8 {
    match role {
        Some(MailboxRole::Inbox) => 0,
        Some(MailboxRole::Drafts) => 1,
        Some(MailboxRole::Sent) => 2,
        Some(MailboxRole::Archive) => 3,
        Some(MailboxRole::Trash) => 4,
        Some(MailboxRole::Spam) => 5,
        Some(MailboxRole::Other) | None => 6,
    }
}

fn graph_search_value(search: &str) -> Result<String, GraphError> {
    let search = search.trim();
    if search.is_empty()
        || search.len() > MAX_GRAPH_SEARCH_BYTES
        || search.chars().any(char::is_control)
    {
        return Err(GraphError::InvalidSearch);
    }
    let escaped = search.replace('\\', "\\\\").replace('"', "\\\"");
    Ok(format!("\"{escaped}\""))
}

fn graph_message_id(account_id: &str, native_id: &str) -> Result<String, GraphError> {
    let provider_id = encode_native_id("gm-", native_id)?;
    let id = normalized_message_id(account_id, &provider_id);
    if id.len() > MAX_GRAPH_EXPOSED_ID_BYTES {
        return Err(GraphError::InvalidResourceId);
    }
    Ok(id)
}

fn graph_native_message_id(account_id: &str, id: &str) -> Result<String, GraphError> {
    let provider_id = id
        .strip_prefix(account_id)
        .and_then(|suffix| suffix.strip_prefix(':'))
        .ok_or(GraphError::InvalidResourceId)?;
    decode_native_id("gm-", provider_id)
}

fn graph_thread_id(account_id: &str, native_id: &str) -> Result<String, GraphError> {
    let provider_id = encode_native_id("gt-", native_id)?;
    let id = normalized_message_id(account_id, &provider_id);
    if id.len() > MAX_GRAPH_EXPOSED_ID_BYTES {
        return Err(GraphError::InvalidResourceId);
    }
    Ok(id)
}

fn graph_folder_id(native_id: &str) -> Result<String, GraphError> {
    encode_native_id("gf-", native_id)
}

fn graph_native_folder_id(id: &str) -> Result<String, GraphError> {
    decode_native_id("gf-", id)
}

fn graph_attachment_id(native_id: &str) -> Result<String, GraphError> {
    encode_native_id("ga-", native_id)
}

fn graph_native_attachment_id(id: &str) -> Result<String, GraphError> {
    decode_native_id("ga-", id)
}

fn encode_native_id(prefix: &str, native_id: &str) -> Result<String, GraphError> {
    validate_native_id(native_id)?;
    let encoded = format!("{prefix}{}", URL_SAFE_NO_PAD.encode(native_id.as_bytes()));
    if encoded.len() > MAX_GRAPH_EXPOSED_ID_BYTES {
        return Err(GraphError::InvalidResourceId);
    }
    Ok(encoded)
}

fn decode_native_id(prefix: &str, id: &str) -> Result<String, GraphError> {
    let encoded = id
        .strip_prefix(prefix)
        .ok_or(GraphError::InvalidResourceId)?;
    let bytes = URL_SAFE_NO_PAD
        .decode(encoded)
        .map_err(|_| GraphError::InvalidResourceId)?;
    let native = String::from_utf8(bytes).map_err(|_| GraphError::InvalidResourceId)?;
    validate_native_id(&native)?;
    Ok(native)
}

fn validate_native_id(id: &str) -> Result<(), GraphError> {
    if id.is_empty() || id.len() > MAX_GRAPH_NATIVE_ID_BYTES || id.chars().any(char::is_control) {
        return Err(GraphError::InvalidResourceId);
    }
    Ok(())
}

fn bounded_json(value: &impl Serialize) -> Result<Vec<u8>, GraphError> {
    let bytes = serde_json::to_vec(value)?;
    if bytes.len() > MAX_MAIL_MESSAGE_BYTES {
        return Err(GraphError::RequestTooLarge);
    }
    Ok(bytes)
}

fn decode_graph_json<R: DeserializeOwned>(response: GraphHttpResponse) -> Result<R, GraphError> {
    if !(200..300).contains(&response.status) {
        return Err(graph_api_error(response));
    }
    serde_json::from_slice(&response.body).map_err(GraphError::Json)
}

fn decode_graph_bytes(response: GraphHttpResponse) -> Result<Vec<u8>, GraphError> {
    if !(200..300).contains(&response.status) {
        return Err(graph_api_error(response));
    }
    Ok(response.body)
}

fn decode_graph_empty(response: GraphHttpResponse) -> Result<(), GraphError> {
    if !(200..300).contains(&response.status) {
        return Err(graph_api_error(response));
    }
    Ok(())
}

fn graph_api_error(response: GraphHttpResponse) -> GraphError {
    let code = serde_json::from_slice::<GraphErrorEnvelope>(&response.body)
        .ok()
        .and_then(|envelope| envelope.error.code)
        .map(|code| {
            code.chars()
                .filter(|character| {
                    character.is_ascii_alphanumeric() || matches!(character, '.' | '_' | '-')
                })
                .take(64)
                .collect::<String>()
        })
        .filter(|code| !code.is_empty())
        .unwrap_or_else(|| "requestRejected".into());
    GraphError::Api {
        status: response.status,
        code,
    }
}

fn graph_provider_error(error: GraphError) -> ProviderError {
    match error {
        GraphError::Token(error) => ProviderError::Authentication(error.to_string()),
        GraphError::Api {
            status: 401 | 403, ..
        } => ProviderError::Authentication(
            "Microsoft Online Accounts authorization is missing required mail access".into(),
        ),
        GraphError::Api { status: 404, .. } | GraphError::InvalidResourceId => {
            ProviderError::NotFound
        }
        GraphError::Api { status, .. } if matches!(status, 408 | 425 | 429) || status >= 500 => {
            ProviderError::Temporary("Microsoft Graph is temporarily unavailable".into())
        }
        GraphError::Api { status: 413, .. }
        | GraphError::Transport(GraphTransportError::ResponseTooLarge)
        | GraphError::RequestTooLarge => ProviderError::ResourceTooLarge("Microsoft Graph data"),
        GraphError::AttachmentTooLarge => ProviderError::ResourceTooLarge("attachment"),
        GraphError::AttachmentLimitExceeded => {
            ProviderError::ResourceTooLarge("message attachment list")
        }
        GraphError::PageLimitExceeded => ProviderError::ResourceTooLarge("Microsoft Graph page"),
        GraphError::UnsupportedAttachment => ProviderError::Unsupported(
            "Microsoft Graph item and reference attachments cannot be downloaded as files".into(),
        ),
        GraphError::Transport(GraphTransportError::Failed) => {
            ProviderError::Temporary("Microsoft Graph transport failed".into())
        }
        other => ProviderError::Other(other.to_string()),
    }
}

#[derive(Debug, Error)]
pub(crate) enum GraphError {
    #[error(transparent)]
    Token(#[from] TokenError),
    #[error(transparent)]
    Transport(#[from] GraphTransportError),
    #[error("Microsoft Graph returned HTTP {status} ({code})")]
    Api { status: u16, code: String },
    #[error("Microsoft Graph returned malformed JSON")]
    Json(#[from] serde_json::Error),
    #[error("invalid Microsoft Graph URL")]
    InvalidUrl,
    #[error("invalid Microsoft Graph resource ID")]
    InvalidResourceId,
    #[error("invalid Microsoft Graph continuation URL")]
    InvalidContinuation,
    #[error("Microsoft Graph repeated a continuation URL")]
    RepeatedContinuation,
    #[error("Microsoft Graph result exceeded the page bound")]
    PageLimitExceeded,
    #[error("Microsoft Graph message exceeded the attachment-count bound")]
    AttachmentLimitExceeded,
    #[error("Microsoft Graph attachment is too large")]
    AttachmentTooLarge,
    #[error("Microsoft Graph attachment type is not a downloadable file")]
    UnsupportedAttachment,
    #[error("Microsoft Graph search text is invalid")]
    InvalidSearch,
    #[error("outgoing Microsoft Graph message is invalid")]
    InvalidOutgoingMessage,
    #[error("outgoing Microsoft Graph request is too large")]
    RequestTooLarge,
}

#[cfg(test)]
mod tests {
    use std::{collections::VecDeque, sync::Mutex};

    use super::*;
    use crate::providers::auth::{AccessToken, SecretString};

    #[derive(Default)]
    struct MockTransport {
        responses: Mutex<VecDeque<GraphHttpResponse>>,
        requests: Mutex<Vec<GraphHttpRequest>>,
    }

    impl MockTransport {
        fn with_responses(responses: impl IntoIterator<Item = GraphHttpResponse>) -> Self {
            Self {
                responses: Mutex::new(responses.into_iter().collect()),
                requests: Mutex::new(Vec::new()),
            }
        }
    }

    #[async_trait]
    impl GraphHttpTransport for MockTransport {
        async fn execute(
            &self,
            request: GraphHttpRequest,
        ) -> Result<GraphHttpResponse, GraphTransportError> {
            self.requests.lock().unwrap().push(request);
            self.responses
                .lock()
                .unwrap()
                .pop_front()
                .ok_or(GraphTransportError::Failed)
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
                value: SecretString::new("graph-access-secret"),
                expires_at: None,
            })
        }
    }

    fn response(status: u16, body: impl Into<Vec<u8>>) -> GraphHttpResponse {
        GraphHttpResponse {
            status,
            body: body.into(),
        }
    }

    fn json_response(status: u16, body: Value) -> GraphHttpResponse {
        response(status, serde_json::to_vec(&body).unwrap())
    }

    fn client(
        responses: impl IntoIterator<Item = GraphHttpResponse>,
    ) -> (
        MicrosoftGraphClient<MockTransport, MockTokens>,
        Arc<MockTransport>,
        Arc<MockTokens>,
    ) {
        let transport = Arc::new(MockTransport::with_responses(responses));
        let tokens = Arc::new(MockTokens::default());
        let client = MicrosoftGraphClient::with_api_root(
            transport.clone(),
            tokens.clone(),
            Url::parse("https://example.invalid/v1.0/").unwrap(),
        );
        (client, transport, tokens)
    }

    fn account() -> Account {
        Account {
            id: "account-a".into(),
            address: "person@outlook.com".into(),
            display_name: "Person".into(),
            provider: "outlook".into(),
            protocol: "microsoft_graph".into(),
            host: String::new(),
            unread: 0,
            total: 0,
            enabled: true,
        }
    }

    fn provider(
        responses: impl IntoIterator<Item = GraphHttpResponse>,
    ) -> (
        MicrosoftGraphProvider<MockTransport, MockTokens>,
        Arc<MockTransport>,
        Arc<MockTokens>,
    ) {
        let (client, transport, tokens) = client(responses);
        (
            MicrosoftGraphProvider::with_client(account(), client),
            transport,
            tokens,
        )
    }

    fn wire_message(id: &str) -> Value {
        json!({
            "id": id,
            "conversationId": "conversation/native",
            "parentFolderId": "folder/native",
            "subject": "A message",
            "from": {"emailAddress": {"name": "Sender", "address": "sender@example.com"}},
            "receivedDateTime": "2026-08-30T12:34:56Z",
            "isRead": false,
            "flag": {"flagStatus": "flagged"},
            "bodyPreview": "Preview",
            "hasAttachments": false,
            "internetMessageId": "<wire-id@example.com>"
        })
    }

    #[test]
    fn graph_ids_are_safe_account_scoped_and_reversible() {
        let message = graph_message_id("account-a", "opaque/id+=").unwrap();
        let thread = graph_thread_id("account-a", "conversation/id+=").unwrap();
        let folder = graph_folder_id("folder/id+=").unwrap();
        let attachment = graph_attachment_id("attachment/id+=").unwrap();

        assert!(message.starts_with("account-a:gm-"));
        assert!(thread.starts_with("account-a:gt-"));
        for exposed in [&message, &thread, &folder, &attachment] {
            assert!(exposed.len() <= MAX_GRAPH_EXPOSED_ID_BYTES);
            assert!(!exposed.contains(['/', '\\', '\0']));
        }
        assert_eq!(
            graph_native_message_id("account-a", &message).unwrap(),
            "opaque/id+="
        );
        assert!(graph_native_message_id("account-b", &message).is_err());
        assert_eq!(graph_native_folder_id(&folder).unwrap(), "folder/id+=");
        assert_eq!(
            graph_native_attachment_id(&attachment).unwrap(),
            "attachment/id+="
        );
    }

    #[tokio::test]
    async fn message_pagination_uses_bounded_same_collection_continuations() {
        let next = "https://example.invalid/v1.0/me/mailFolders/folder%2Fnative/messages?%24top=2&%24skip=2";
        let (client, transport, _) = client([
            json_response(
                200,
                json!({"value":[wire_message("message/one")],"@odata.nextLink":next}),
            ),
            json_response(200, json!({"value":[wire_message("message/two")]})),
        ]);
        let query = MessageQuery {
            mailbox_id: Some(graph_folder_id("folder/native").unwrap()),
            search: Some("quarterly \"report\"".into()),
            limit: 2,
            ..MessageQuery::default()
        };
        let (first, cursor) = client
            .list_message_page(&query, Some("folder/native"))
            .await
            .unwrap();
        assert_eq!(first[0].id, "message/one");
        let (second, next_cursor) = client
            .list_message_page(&MessageQuery { cursor, ..query }, Some("folder/native"))
            .await
            .unwrap();
        assert_eq!(second[0].id, "message/two");
        assert!(next_cursor.is_none());

        let requests = transport.requests.lock().unwrap();
        assert!(requests[0].url.as_str().contains("%24top=2"));
        assert!(requests[0].url.as_str().contains("%24search="));
        assert_eq!(requests[1].url.as_str(), next);
        assert!(requests.iter().all(|request| {
            request
                .headers
                .iter()
                .any(|(name, value)| name == "Prefer" && value.contains("ImmutableId"))
        }));
        let debug = format!("{:?}", requests[0]);
        assert!(!debug.contains("graph-access-secret"));
        assert!(!debug.contains("quarterly"));
        assert!(debug.contains("[REDACTED]"));
    }

    #[tokio::test]
    async fn continuation_rejects_non_https_cross_origin_and_cross_collection_urls() {
        for next in [
            "http://example.invalid/v1.0/me/messages?$skip=2",
            "https://evil.invalid/v1.0/me/messages?$skip=2",
            "https://example.invalid/v1.0/me/drive/root?$skip=2",
        ] {
            let (client, _, _) = client([json_response(
                200,
                json!({"value":[],"@odata.nextLink":next}),
            )]);
            assert!(
                client
                    .list_message_page(&MessageQuery::default(), None)
                    .await
                    .is_err()
            );
        }
    }

    #[tokio::test]
    async fn full_message_maps_html_addresses_thread_and_attachment_metadata() {
        let mut message = wire_message("message/native");
        message["toRecipients"] =
            json!([{"emailAddress":{"name":"Recipient","address":"to@example.com"}}]);
        message["ccRecipients"] =
            json!([{"emailAddress":{"name":"Copy","address":"cc@example.com"}}]);
        message["body"] = json!({"contentType":"html","content":"<p>Hello</p>"});
        message["hasAttachments"] = json!(true);
        let (provider, _, _) = provider([
            json_response(200, message),
            json_response(
                200,
                json!({"value":[{
                    "@odata.type":"#microsoft.graph.fileAttachment",
                    "id":"attachment/native",
                    "name":"../report.pdf",
                    "contentType":"application/pdf",
                    "size":42,
                    "isInline":false
                }]}),
            ),
        ]);
        let id = graph_message_id("account-a", "message/native").unwrap();
        let message = provider.get_message(&id).await.unwrap();

        assert_eq!(message.body_html.as_deref(), Some("<p>Hello</p>"));
        assert!(message.body_text.is_none());
        assert_eq!(message.to[0].address, "to@example.com");
        assert_eq!(message.cc[0].address, "cc@example.com");
        assert!(
            message
                .summary
                .thread_id
                .unwrap()
                .starts_with("account-a:gt-")
        );
        assert_eq!(
            message.summary.provider_data["messageId"],
            "<wire-id@example.com>"
        );
        assert_eq!(message.attachments[0].filename, "report.pdf");
        assert!(message.attachments[0].id.starts_with("ga-"));
    }

    #[tokio::test]
    async fn mailbox_roles_use_well_known_ids_not_localized_names() {
        let (provider, transport, _) = provider([
            json_response(
                200,
                json!({"value":[
                    {"id":"folder-archive","displayName":"Archiv","unreadItemCount":0,"totalItemCount":4},
                    {"id":"folder-inbox","displayName":"Posteingang","unreadItemCount":3,"totalItemCount":9}
                ]}),
            ),
            json_response(
                200,
                json!({"id":"folder-inbox","displayName":"Posteingang"}),
            ),
            json_response(404, json!({"error":{"code":"ErrorFolderNotFound"}})),
            json_response(404, json!({"error":{"code":"ErrorFolderNotFound"}})),
            json_response(200, json!({"id":"folder-archive","displayName":"Archiv"})),
            json_response(404, json!({"error":{"code":"ErrorFolderNotFound"}})),
            json_response(404, json!({"error":{"code":"ErrorFolderNotFound"}})),
        ]);

        let mailboxes = provider.list_mailboxes().await.unwrap();
        assert_eq!(mailboxes.len(), 2);
        assert_eq!(mailboxes[0].role, Some(MailboxRole::Inbox));
        assert_eq!(mailboxes[1].role, Some(MailboxRole::Archive));
        assert_eq!(mailboxes[0].unread, 3);
        assert_eq!(transport.requests.lock().unwrap().len(), 7);
    }

    #[tokio::test]
    async fn actions_map_to_patch_and_move_without_losing_immutable_ids() {
        let (provider, transport, _) = provider([
            json_response(200, json!({"id":"message/native"})),
            json_response(200, json!({"id":"message/native"})),
            json_response(201, json!({"id":"message/native"})),
            json_response(201, json!({"id":"message/native"})),
        ]);
        let message_id = graph_message_id("account-a", "message/native").unwrap();
        provider
            .apply_action(MailAction::MarkRead {
                message_ids: vec![message_id.clone()],
                read: true,
            })
            .await
            .unwrap();
        provider
            .apply_action(MailAction::Star {
                message_ids: vec![message_id.clone()],
                starred: true,
            })
            .await
            .unwrap();
        provider
            .apply_action(MailAction::Archive {
                message_ids: vec![message_id.clone()],
            })
            .await
            .unwrap();
        provider
            .apply_action(MailAction::Move {
                message_ids: vec![message_id],
                mailbox_id: graph_folder_id("custom/folder").unwrap(),
            })
            .await
            .unwrap();

        let requests = transport.requests.lock().unwrap();
        assert_eq!(requests[0].method, GraphHttpMethod::Patch);
        assert_eq!(
            serde_json::from_slice::<Value>(requests[0].body.as_ref().unwrap()).unwrap(),
            json!({"isRead":true})
        );
        assert_eq!(requests[1].method, GraphHttpMethod::Patch);
        assert_eq!(
            serde_json::from_slice::<Value>(requests[1].body.as_ref().unwrap()).unwrap(),
            json!({"flag":{"flagStatus":"flagged"}})
        );
        assert!(requests[2].url.path().ends_with("/move"));
        assert_eq!(
            serde_json::from_slice::<Value>(requests[2].body.as_ref().unwrap()).unwrap(),
            json!({"destinationId":"archive"})
        );
        assert_eq!(
            serde_json::from_slice::<Value>(requests[3].body.as_ref().unwrap()).unwrap(),
            json!({"destinationId":"custom/folder"})
        );
        assert!(requests.iter().all(|request| {
            request
                .headers
                .iter()
                .any(|(name, value)| name == "Prefer" && value.contains("ImmutableId"))
        }));
    }

    #[tokio::test]
    async fn send_creates_and_sends_an_immutable_draft() {
        let (provider, transport, _) = provider([
            json_response(201, json!({"id":"sent/native"})),
            response(202, Vec::new()),
        ]);
        let sent_id = provider
            .send(OutgoingMessage {
                draft_id: Some("local-draft".into()),
                account_id: "account-a".into(),
                to: vec![Address {
                    name: "Recipient".into(),
                    address: "to@example.com".into(),
                }],
                cc: Vec::new(),
                bcc: Vec::new(),
                subject: "Hello".into(),
                body_text: Some("Plain text".into()),
                body_html: None,
                in_reply_to: None,
            })
            .await
            .unwrap();
        assert_eq!(
            graph_native_message_id("account-a", &sent_id).unwrap(),
            "sent/native"
        );

        let requests = transport.requests.lock().unwrap();
        assert_eq!(requests.len(), 2);
        assert_eq!(requests[0].method, GraphHttpMethod::Post);
        assert_eq!(requests[0].url.path(), "/v1.0/me/messages");
        let body: Value = serde_json::from_slice(requests[0].body.as_ref().unwrap()).unwrap();
        assert_eq!(body["body"]["contentType"], "Text");
        assert_eq!(body["body"]["content"], "Plain text");
        assert_eq!(
            body["toRecipients"][0]["emailAddress"]["address"],
            "to@example.com"
        );
        assert!(requests[1].url.path().ends_with("/send"));
        assert!(requests[1].body.is_none());
    }

    #[tokio::test]
    async fn reply_uses_create_reply_updates_the_draft_and_then_sends() {
        let (provider, transport, _) = provider([
            json_response(201, json!({"id":"reply-draft"})),
            json_response(200, json!({"id":"reply-draft"})),
            response(202, Vec::new()),
        ]);
        let parent = graph_message_id("account-a", "parent/native").unwrap();
        let sent = provider
            .send(OutgoingMessage {
                draft_id: None,
                account_id: "account-a".into(),
                to: vec![Address {
                    name: String::new(),
                    address: "sender@example.com".into(),
                }],
                cc: Vec::new(),
                bcc: Vec::new(),
                subject: "Re: Hello".into(),
                body_text: None,
                body_html: Some("<p>Reply</p>".into()),
                in_reply_to: Some(parent),
            })
            .await
            .unwrap();
        assert_eq!(
            graph_native_message_id("account-a", &sent).unwrap(),
            "reply-draft"
        );

        let requests = transport.requests.lock().unwrap();
        assert!(requests[0].url.path().ends_with("/createReply"));
        assert!(requests[0].body.is_none());
        assert_eq!(requests[1].method, GraphHttpMethod::Patch);
        let body: Value = serde_json::from_slice(requests[1].body.as_ref().unwrap()).unwrap();
        assert_eq!(body["body"]["contentType"], "HTML");
        assert_eq!(body["body"]["content"], "<p>Reply</p>");
        assert!(requests[2].url.path().ends_with("/send"));
    }

    #[tokio::test]
    async fn unauthorized_requests_refresh_once_and_api_errors_do_not_leak_messages() {
        let (client, transport, tokens) = client([
            json_response(401, json!({"error":{"code":"InvalidAuthenticationToken"}})),
            json_response(200, json!({"value":[]})),
            json_response(
                400,
                json!({"error":{"code":"Bad<Request>","message":"private mailbox text"}}),
            ),
        ]);
        client
            .list_message_page(&MessageQuery::default(), None)
            .await
            .unwrap();
        assert_eq!(*tokens.refreshes.lock().unwrap(), [false, true]);
        let error = client
            .get_message("message-id")
            .await
            .unwrap_err()
            .to_string();
        assert!(!error.contains("private mailbox text"));
        assert!(error.contains("BadRequest"));
        assert_eq!(transport.requests.lock().unwrap().len(), 3);
    }

    #[tokio::test]
    async fn attachment_type_and_size_are_checked_before_fetching_raw_bytes() {
        let message_id = graph_message_id("account-a", "message-id").unwrap();
        let attachment_id = graph_attachment_id("attachment-id").unwrap();
        let (oversized, transport, _) = provider([json_response(
            200,
            json!({
                "@odata.type":"#microsoft.graph.fileAttachment",
                "id":"attachment-id",
                "name":"large.bin",
                "contentType":"application/octet-stream",
                "size":MAX_MAIL_ATTACHMENT_BYTES as u64 + 1
            }),
        )]);
        assert!(matches!(
            oversized.get_attachment(&message_id, &attachment_id).await,
            Err(ProviderError::ResourceTooLarge("attachment"))
        ));
        assert_eq!(transport.requests.lock().unwrap().len(), 1);

        let (item, transport, _) = provider([json_response(
            200,
            json!({
                "@odata.type":"#microsoft.graph.itemAttachment",
                "id":"attachment-id",
                "name":"attached-message.eml",
                "size":100
            }),
        )]);
        assert!(matches!(
            item.get_attachment(&message_id, &attachment_id).await,
            Err(ProviderError::Unsupported(_))
        ));
        assert_eq!(transport.requests.lock().unwrap().len(), 1);
    }

    #[tokio::test]
    async fn file_attachment_download_is_bounded_and_maps_safe_metadata() {
        let message_id = graph_message_id("account-a", "message-id").unwrap();
        let attachment_id = graph_attachment_id("attachment-id").unwrap();
        let (provider, transport, _) = provider([
            json_response(
                200,
                json!({
                    "@odata.type":"#microsoft.graph.fileAttachment",
                    "id":"attachment-id",
                    "name":"../invoice.pdf",
                    "contentType":"application/pdf",
                    "size":4
                }),
            ),
            response(200, b"data".to_vec()),
        ]);

        let downloaded = provider
            .get_attachment(&message_id, &attachment_id)
            .await
            .unwrap();
        assert_eq!(downloaded.filename, "invoice.pdf");
        assert_eq!(downloaded.content_type, "application/pdf");
        assert_eq!(downloaded.bytes, b"data");

        let requests = transport.requests.lock().unwrap();
        assert_eq!(requests.len(), 2);
        assert!(
            requests[1]
                .url
                .path()
                .ends_with("/attachments/attachment-id/$value")
        );
        assert!(
            requests[1]
                .headers
                .iter()
                .any(|(name, value)| name == "Accept" && value == "application/octet-stream")
        );
    }

    #[tokio::test]
    async fn oversized_graph_message_page_is_rejected() {
        let values = (0..=MAX_GRAPH_PAGE_ITEMS)
            .map(|index| wire_message(&format!("message-{index}")))
            .collect::<Vec<_>>();
        let (client, _, _) = client([json_response(200, json!({"value": values}))]);

        assert!(matches!(
            client
                .list_message_page(&MessageQuery::default(), None)
                .await,
            Err(GraphError::PageLimitExceeded)
        ));
    }

    #[test]
    fn transport_chunk_and_request_bounds_are_enforced() {
        let mut body = b"123".to_vec();
        append_bounded_chunk(&mut body, b"45", 5).unwrap();
        assert!(matches!(
            append_bounded_chunk(&mut body, b"6", 5),
            Err(GraphTransportError::ResponseTooLarge)
        ));
        assert_eq!(body, b"12345");

        let huge = "x".repeat(MAX_MAIL_MESSAGE_BYTES + 1);
        let outgoing = OutgoingMessage {
            draft_id: None,
            account_id: "account-a".into(),
            to: vec![Address {
                name: String::new(),
                address: "to@example.com".into(),
            }],
            cc: Vec::new(),
            bcc: Vec::new(),
            subject: "subject".into(),
            body_text: Some(huge),
            body_html: None,
            in_reply_to: None,
        };
        assert!(matches!(
            graph_draft_message(&outgoing),
            Err(GraphError::RequestTooLarge)
        ));
    }
}
