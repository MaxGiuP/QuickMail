use std::{
    collections::{HashMap, HashSet},
    fs::File,
    future::Future,
    io,
    os::{
        fd::AsRawFd,
        unix::{
            fs::{FileTypeExt, MetadataExt, OpenOptionsExt, PermissionsExt},
            net::UnixStream as StdUnixStream,
        },
    },
    path::{Path, PathBuf},
    sync::{Arc, LazyLock},
};

use async_trait::async_trait;
use chrono::Utc;
use quickmail_core::{
    AccountAddParams, AccountIdParams, AttachmentData, AttachmentDownloadParams,
    AttachmentDownloaded, CalendarEvent, CalendarListParams, DraftIdParams, DraftListParams,
    DraftSaveParams, EventIdParams, JSONRPC_VERSION, MailAction, MailProvider, MailboxSyncQuery,
    MessageIdParams, MessageQuery, OutgoingMessage, ProviderError, RpcError, RpcId,
    RpcNotification, RpcRequest, RpcResponse, SubscribeParams, Task, TaskCompleteParams,
    TaskIdParams, TaskListParams, method,
};
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use serde_json::{Value, json};
use thiserror::Error;
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    net::{UnixListener, UnixStream},
    sync::{Mutex, RwLock, broadcast, watch},
    task::JoinSet,
};
use tracing::{debug, warn};
use uuid::Uuid;

use crate::{
    providers::MAX_MAIL_ATTACHMENT_BYTES,
    storage::{Database, StorageError},
};

const EVENT_QUEUE_CAPACITY: usize = 128;
const MAX_REQUEST_BYTES: usize = 1024 * 1024;
const SYNC_PAGE_SIZE: u32 = 200;
const SYNC_FLAG_RECONCILE_SIZE: u32 = 64;

static HTML_SANITIZER: LazyLock<ammonia::Builder<'static>> = LazyLock::new(|| {
    let mut builder = ammonia::Builder::default();
    builder
        .url_schemes(HashSet::from(["http", "https", "mailto"]))
        .url_relative(ammonia::UrlRelative::Deny)
        .add_generic_attributes(&["style"])
        .filter_style_properties(HashSet::from([
            "background-color",
            "border",
            "border-bottom",
            "border-bottom-color",
            "border-bottom-style",
            "border-bottom-width",
            "border-collapse",
            "border-color",
            "border-left",
            "border-left-color",
            "border-left-style",
            "border-left-width",
            "border-right",
            "border-right-color",
            "border-right-style",
            "border-right-width",
            "border-style",
            "border-top",
            "border-top-color",
            "border-top-style",
            "border-top-width",
            "border-width",
            "color",
            "float",
            "font",
            "font-family",
            "font-kerning",
            "font-size",
            "font-style",
            "font-variant",
            "font-weight",
            "line-height",
            "margin-bottom",
            "margin-left",
            "margin-right",
            "margin-top",
            "padding",
            "padding-bottom",
            "padding-left",
            "padding-right",
            "padding-top",
            "text-decoration",
            "text-indent",
            "text-transform",
            "vertical-align",
            "white-space",
            "word-spacing",
        ]))
        .attribute_filter(|element, attribute, value| {
            if element == "img" && attribute == "src" {
                let allowed = ammonia::Url::parse(value)
                    .map(|url| matches!(url.scheme(), "http" | "https"))
                    .unwrap_or(false);
                return allowed.then(|| value.into());
            }
            Some(value.into())
        });
    builder
});

#[derive(Debug, Error)]
pub enum DaemonError {
    #[error("socket I/O error: {0}")]
    Io(#[from] io::Error),
    #[error("storage error: {0}")]
    Storage(#[from] StorageError),
    #[error("refusing unsafe socket path: {0}")]
    UnsafeSocket(String),
    #[error("another QuickMail daemon already owns socket: {0}")]
    SocketInUse(String),
}

#[derive(Debug, Clone)]
struct ServerEvent {
    topic: String,
    method: String,
    params: Value,
}

#[derive(Deserialize)]
struct InboundRpcRequest {
    jsonrpc: String,
    #[serde(default)]
    id: InboundRpcId,
    method: String,
    #[serde(default)]
    params: Value,
}

#[derive(Default)]
enum InboundRpcId {
    #[default]
    Missing,
    Present(RpcId),
}

impl<'de> Deserialize<'de> for InboundRpcId {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        RpcId::deserialize(deserializer).map(Self::Present)
    }
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SyncStartParams {
    account_id: Option<String>,
}

#[derive(Clone)]
pub struct Daemon {
    database: Database,
    events: broadcast::Sender<ServerEvent>,
    providers: Arc<RwLock<HashMap<String, Arc<dyn MailProvider>>>>,
    provider_factory: Arc<dyn ProviderFactory>,
    attachment_cache: PathBuf,
    background_syncing: Arc<Mutex<HashSet<String>>>,
    background_tasks: Arc<Mutex<JoinSet<()>>>,
    background_shutdown: watch::Sender<bool>,
    removed_accounts: Arc<Mutex<HashSet<String>>>,
    account_mutations: Arc<Mutex<()>>,
}

/// Constructs a provider and moves plaintext setup secrets into the system
/// keyring. Implementations must never retain or log the setup object.
#[async_trait]
pub trait ProviderFactory: Send + Sync {
    async fn create(&self, setup: AccountAddParams)
    -> Result<Arc<dyn MailProvider>, ProviderError>;

    async fn restore(
        &self,
        account: &quickmail_core::Account,
        config: &Value,
    ) -> Result<Arc<dyn MailProvider>, ProviderError>;

    async fn reauthorize(
        &self,
        account: &quickmail_core::Account,
        config: &Value,
    ) -> Result<Arc<dyn MailProvider>, ProviderError>;

    async fn remove(&self, account_id: &str) -> Result<(), ProviderError>;
}

struct UnavailableProviderFactory;

#[async_trait]
impl ProviderFactory for UnavailableProviderFactory {
    async fn create(
        &self,
        _setup: AccountAddParams,
    ) -> Result<Arc<dyn MailProvider>, ProviderError> {
        Err(ProviderError::Unsupported(
            "account provider factory".into(),
        ))
    }

    async fn restore(
        &self,
        _account: &quickmail_core::Account,
        _config: &Value,
    ) -> Result<Arc<dyn MailProvider>, ProviderError> {
        Err(ProviderError::Unsupported(
            "account provider factory".into(),
        ))
    }

    async fn reauthorize(
        &self,
        _account: &quickmail_core::Account,
        _config: &Value,
    ) -> Result<Arc<dyn MailProvider>, ProviderError> {
        Err(ProviderError::Unsupported(
            "account provider factory".into(),
        ))
    }

    async fn remove(&self, _account_id: &str) -> Result<(), ProviderError> {
        Ok(())
    }
}

impl Daemon {
    pub fn new(database: Database) -> Self {
        Self::with_attachment_cache(database, std::env::temp_dir().join("quickmail-attachments"))
    }

    pub fn with_attachment_cache(database: Database, attachment_cache: PathBuf) -> Self {
        Self::with_provider_factory(
            database,
            Arc::new(UnavailableProviderFactory),
            attachment_cache,
        )
    }

    pub fn with_provider_factory(
        database: Database,
        provider_factory: Arc<dyn ProviderFactory>,
        attachment_cache: PathBuf,
    ) -> Self {
        let (events, _) = broadcast::channel(EVENT_QUEUE_CAPACITY);
        let (background_shutdown, _) = watch::channel(false);
        Self {
            database,
            events,
            providers: Arc::new(RwLock::new(HashMap::new())),
            provider_factory,
            attachment_cache,
            background_syncing: Arc::new(Mutex::new(HashSet::new())),
            background_tasks: Arc::new(Mutex::new(JoinSet::new())),
            background_shutdown,
            removed_accounts: Arc::new(Mutex::new(HashSet::new())),
            account_mutations: Arc::new(Mutex::new(())),
        }
    }

    pub fn database(&self) -> &Database {
        &self.database
    }

    pub async fn restore_providers(&self) -> Result<usize, DaemonError> {
        let configs = self.database.list_account_configs().await?;
        let mut restored = 0;
        for (account, config) in configs {
            match self.provider_factory.restore(&account, &config).await {
                Ok(provider) => {
                    self.removed_accounts.lock().await.remove(&account.id);
                    self.providers
                        .write()
                        .await
                        .insert(account.id.clone(), provider);
                    self.database
                        .set_account_auth_state(&account.id, "ready", None)
                        .await?;
                    restored += 1;
                }
                Err(ProviderError::Unsupported(_)) if account.protocol == "LOCAL" => {}
                Err(error) => {
                    let state = if matches!(error, ProviderError::Authentication(_)) {
                        "needs_auth"
                    } else {
                        "error"
                    };
                    let message = error.to_string();
                    self.database
                        .set_account_auth_state(&account.id, state, Some(&message))
                        .await?;
                    warn!(account_id = %account.id, %error, "could not restore provider");
                }
            }
        }
        Ok(restored)
    }

    pub async fn run_with_shutdown<F>(
        self,
        socket_path: impl AsRef<Path>,
        shutdown: F,
    ) -> Result<(), DaemonError>
    where
        F: Future<Output = ()> + Send,
    {
        let socket_path = socket_path.as_ref().to_owned();
        let bound_socket = bind_user_socket(&socket_path)?;
        let _socket_guard = bound_socket.guard;
        let listener = bound_socket.listener;
        let (shutdown_sender, shutdown_receiver) = watch::channel(false);
        tokio::pin!(shutdown);
        let mut connections = JoinSet::new();

        loop {
            tokio::select! {
                    _ = &mut shutdown => break,
                    accepted = listener.accept() => {
            let (stream, _) = accepted.map_err(|error| io_context("accept unix socket", error))?;
                        if !peer_is_current_user(&stream)? {
                            warn!("rejected unix socket peer owned by another user");
                            continue;
                        }
                        let daemon = self.clone();
                        let connection_shutdown = shutdown_receiver.clone();
                        connections.spawn(async move {
                            if let Err(error) = daemon.handle_connection(stream, connection_shutdown).await {
                                debug!(%error, "client connection closed with error");
                            }
                        });
                    }
                    Some(result) = connections.join_next(), if !connections.is_empty() => {
                        if let Err(error) = result {
                            debug!(%error, "client task ended unexpectedly");
                        }
                    }
                }
        }

        let _ = shutdown_sender.send(true);
        let _ = self.background_shutdown.send(true);
        while let Some(result) = connections.join_next().await {
            if let Err(error) = result {
                debug!(%error, "client task ended during shutdown");
            }
        }
        let mut background_tasks = self.background_tasks.lock().await;
        while let Some(result) = background_tasks.join_next().await {
            if let Err(error) = result {
                debug!(%error, "background sync task ended during shutdown");
            }
        }
        Ok(())
    }

    async fn handle_connection(
        &self,
        stream: UnixStream,
        mut shutdown: watch::Receiver<bool>,
    ) -> Result<(), io::Error> {
        let (reader, mut writer) = stream.into_split();
        let mut reader = BufReader::new(reader);
        let mut buffer = Vec::with_capacity(4096);
        let mut topics = HashSet::new();
        let mut events = self.events.subscribe();

        loop {
            buffer.clear();
            tokio::select! {
                changed = shutdown.changed() => {
                    if changed.is_err() || *shutdown.borrow() {
                        break;
                    }
                }
                event = events.recv() => {
                    match event {
                        Ok(event) if topics.contains("*") || topics.contains(&event.topic) => {
                            let notification = RpcNotification::new(event.method, event.params)
                                .expect("JSON values always serialize");
                            write_json_line(&mut writer, &notification).await?;
                        }
                        Ok(_) => {}
                        Err(broadcast::error::RecvError::Lagged(skipped)) => {
                            let notification = RpcNotification::new(
                                "system.resync_required",
                                json!({"skipped": skipped}),
                            ).expect("JSON values always serialize");
                            write_json_line(&mut writer, &notification).await?;
                        }
                        Err(broadcast::error::RecvError::Closed) => break,
                    }
                }
                read = reader.read_until(b'\n', &mut buffer) => {
                    let read = read?;
                    if read == 0 {
                        break;
                    }
                    if buffer.len() > MAX_REQUEST_BYTES {
                        write_json_line(
                            &mut writer,
                            &RpcResponse::failure(RpcId::Null, RpcError::invalid_request("request exceeds 1 MiB")),
                        ).await?;
                        break;
                    }
                    let response = match serde_json::from_slice::<InboundRpcRequest>(&buffer) {
                        Ok(request) => tokio::select! {
                            _ = wait_for_shutdown(&mut shutdown) => break,
                            response = self.dispatch_inbound(request, &mut topics) => response,
                        },
                        Err(error) => Some(RpcResponse::failure(
                            RpcId::Null,
                            RpcError { code: -32700, message: "parse error".into(), data: Some(json!({"detail": error.to_string()})) },
                        )),
                    };
                    if let Some(response) = response {
                        write_json_line(&mut writer, &response).await?;
                    }
                }
            }
        }
        Ok(())
    }

    async fn dispatch_inbound(
        &self,
        request: InboundRpcRequest,
        topics: &mut HashSet<String>,
    ) -> Option<RpcResponse> {
        let InboundRpcRequest {
            jsonrpc,
            id,
            method,
            params,
        } = request;
        if let InboundRpcId::Present(id) = id {
            return Some(
                self.dispatch(
                    RpcRequest {
                        jsonrpc,
                        id,
                        method,
                        params,
                    },
                    topics,
                )
                .await,
            );
        }
        // JSON-RPC notifications are dispatched but never receive a response,
        // including when their version, method, or params are invalid.
        if jsonrpc == JSONRPC_VERSION {
            let _ = self.dispatch_inner(&method, params, topics).await;
        }
        None
    }

    async fn dispatch(&self, request: RpcRequest, topics: &mut HashSet<String>) -> RpcResponse {
        let id = request.id.clone();
        if request.jsonrpc != JSONRPC_VERSION {
            return RpcResponse::failure(id, RpcError::invalid_request("jsonrpc must be 2.0"));
        }
        let result = self
            .dispatch_inner(&request.method, request.params, topics)
            .await;
        match result {
            Ok(value) => RpcResponse::success(id.clone(), value).unwrap_or_else(|error| {
                RpcResponse::failure(id, RpcError::internal(error.to_string()))
            }),
            Err(error) => RpcResponse::failure(id, error),
        }
    }

    async fn dispatch_inner(
        &self,
        rpc_method: &str,
        params: Value,
        topics: &mut HashSet<String>,
    ) -> Result<Value, RpcError> {
        match rpc_method {
            method::PING => Ok(json!({"pong": true})),
            method::SUBSCRIBE => {
                let params: SubscribeParams = decode(params)?;
                topics.extend(params.topics);
                Ok(json!({"topics": topics.iter().collect::<Vec<_>>() }))
            }
            method::DASHBOARD_SNAPSHOT => encode(
                self.database
                    .dashboard_snapshot()
                    .await
                    .map_err(storage_rpc_error)?,
            ),
            method::ACCOUNTS_LIST => encode(
                self.database
                    .list_accounts()
                    .await
                    .map_err(storage_rpc_error)?,
            ),
            method::ACCOUNTS_ADD => {
                let params: AccountAddParams = decode(params)?;
                validate_account_setup(&params)?;
                let _mutation = self.account_mutations.lock().await;
                if params.provider.eq_ignore_ascii_case("gmail") {
                    let requested_address = params.address.trim();
                    let existing = self
                        .database
                        .list_accounts()
                        .await
                        .map_err(storage_rpc_error)?
                        .into_iter()
                        .find(|account| {
                            account.provider.eq_ignore_ascii_case("gmail")
                                && account
                                    .address
                                    .trim()
                                    .eq_ignore_ascii_case(requested_address)
                        });
                    if let Some(account) = existing {
                        let revision = self.database.revision().await.map_err(storage_rpc_error)?;
                        return Ok(json!({
                            "accountId": account.id,
                            "revision": revision,
                            "existing": true
                        }));
                    }
                }
                let config = nonsecret_account_config(&params);
                let provider = self
                    .provider_factory
                    .create(params)
                    .await
                    .map_err(provider_rpc_error)?;
                let account = provider.account().clone();
                self.removed_accounts.lock().await.remove(&account.id);
                let revision = self
                    .database
                    .upsert_account_config(&account, config)
                    .await
                    .map_err(storage_rpc_error)?;
                self.providers
                    .write()
                    .await
                    .insert(account.id.clone(), provider);
                self.publish("accounts", "accounts.changed", revision);
                Ok(json!({"accountId": account.id, "revision": revision, "existing": false}))
            }
            method::ACCOUNTS_REMOVE => {
                let params: AccountIdParams = decode(params)?;
                let _mutation = self.account_mutations.lock().await;
                self.removed_accounts
                    .lock()
                    .await
                    .insert(params.account_id.clone());
                let provider = self.providers.write().await.remove(&params.account_id);
                if let Err(error) = purge_attachment_cache(&self.attachment_cache).await {
                    self.removed_accounts
                        .lock()
                        .await
                        .remove(&params.account_id);
                    if let Some(provider) = provider {
                        self.providers
                            .write()
                            .await
                            .insert(params.account_id.clone(), provider);
                    }
                    return Err(error);
                }
                if let Err(error) = self.provider_factory.remove(&params.account_id).await {
                    self.removed_accounts
                        .lock()
                        .await
                        .remove(&params.account_id);
                    if let Some(provider) = provider {
                        self.providers
                            .write()
                            .await
                            .insert(params.account_id.clone(), provider);
                    }
                    return Err(provider_rpc_error(error));
                }
                let revision = match self.database.remove_account(&params.account_id).await {
                    Ok(revision) => revision,
                    Err(error) => {
                        self.removed_accounts
                            .lock()
                            .await
                            .remove(&params.account_id);
                        if let Some(provider) = provider {
                            self.providers
                                .write()
                                .await
                                .insert(params.account_id.clone(), provider);
                        }
                        return Err(storage_rpc_error(error));
                    }
                };
                self.publish("accounts", "accounts.changed", revision);
                Ok(json!({"revision": revision}))
            }
            method::ACCOUNTS_REAUTH => {
                let params: AccountIdParams = decode(params)?;
                let (account, config) = self
                    .database
                    .account_config(&params.account_id)
                    .await
                    .map_err(storage_rpc_error)?
                    .ok_or_else(|| RpcError {
                        code: -32004,
                        message: "account not found".into(),
                        data: None,
                    })?;
                let provider = self.provider_factory.reauthorize(&account, &config).await;
                let provider = match provider {
                    Ok(provider) => provider,
                    Err(error) => {
                        let message = error.to_string();
                        self.database
                            .set_account_auth_state(
                                &account.id,
                                if matches!(error, ProviderError::Authentication(_)) {
                                    "needs_auth"
                                } else {
                                    "error"
                                },
                                Some(&message),
                            )
                            .await
                            .map_err(storage_rpc_error)?;
                        return Err(provider_rpc_error(error));
                    }
                };
                self.providers
                    .write()
                    .await
                    .insert(account.id.clone(), provider);
                self.database
                    .set_account_auth_state(&account.id, "ready", None)
                    .await
                    .map_err(storage_rpc_error)?;
                Ok(json!({"accountId": account.id, "status": "ready"}))
            }
            method::MAILBOXES_LIST => {
                let params: AccountIdParams = decode(params)?;
                encode(
                    self.database
                        .list_mailboxes(&params.account_id)
                        .await
                        .map_err(storage_rpc_error)?,
                )
            }
            method::MAIL_LIST => {
                let query: MessageQuery = decode(params)?;
                encode(
                    self.database
                        .list_messages(&query)
                        .await
                        .map_err(storage_rpc_error)?,
                )
            }
            method::MAIL_GET => {
                let params: MessageIdParams = decode(params)?;
                if let Some((mut message, true)) = self
                    .database
                    .get_cached_message(&params.message_id)
                    .await
                    .map_err(storage_rpc_error)?
                {
                    sanitize_message_html(&mut message);
                    return encode(message);
                }
                let provider = self.provider_for_message(&params.message_id).await?;
                let mut message = provider
                    .get_message(&params.message_id)
                    .await
                    .map_err(provider_rpc_error)?;
                sanitize_message_html(&mut message);
                self.database
                    .upsert_messages(std::slice::from_ref(&message))
                    .await
                    .map_err(storage_rpc_error)?;
                encode(message)
            }
            method::MAIL_ACTION => {
                let action: MailAction = decode(params)?;
                let (operation_id, revision) = self
                    .database
                    .apply_mail_action(&action)
                    .await
                    .map_err(storage_rpc_error)?;
                let provider_result = self.apply_provider_action(action).await;
                self.database
                    .finish_operation(
                        &operation_id,
                        provider_result
                            .as_ref()
                            .map(|_| ())
                            .map_err(ToString::to_string),
                    )
                    .await
                    .map_err(storage_rpc_error)?;
                provider_result.map_err(provider_rpc_error)?;
                self.publish("mail", "mail.changed", revision);
                Ok(json!({"revision": revision, "operationId": operation_id, "queued": false}))
            }
            method::MAIL_SEND => {
                let message: OutgoingMessage = decode(params)?;
                let draft_id = message.draft_id.clone();
                let (operation_id, revision) = self
                    .database
                    .queue_outgoing(&message)
                    .await
                    .map_err(storage_rpc_error)?;
                let provider = self.provider_for_account(&message.account_id).await?;
                let send_result = provider.send(message).await;
                self.database
                    .finish_operation(
                        &operation_id,
                        send_result
                            .as_ref()
                            .map(|_| ())
                            .map_err(ToString::to_string),
                    )
                    .await
                    .map_err(storage_rpc_error)?;
                let message_id = send_result.map_err(provider_rpc_error)?;
                let mut draft_cleanup = "notRequested";
                let revision = if let Some(draft_id) = draft_id {
                    match self.database.delete_draft(&draft_id).await {
                        Ok(cleanup_revision) => {
                            draft_cleanup = "deleted";
                            cleanup_revision
                        }
                        Err(StorageError::NotFound) => {
                            draft_cleanup = "notFound";
                            revision
                        }
                        Err(error) => {
                            draft_cleanup = "failed";
                            warn!(%error, "message sent but local draft cleanup failed");
                            revision
                        }
                    }
                } else {
                    revision
                };
                self.publish("mail", "mail.changed", revision);
                Ok(
                    json!({"operationId": operation_id, "messageId": message_id, "revision": revision, "queued": false, "draftCleanup": draft_cleanup}),
                )
            }
            method::ATTACHMENT_DOWNLOAD => {
                let params: AttachmentDownloadParams = decode(params)?;
                validate_opaque_id(&params.message_id, "messageId")?;
                validate_opaque_id(&params.attachment_id, "attachmentId")?;
                let provider = self.provider_for_message(&params.message_id).await?;
                let account_id = provider.account().id.clone();
                if !provider.capabilities().attachment_retrieval {
                    return Err(RpcError {
                        code: -32005,
                        message: "provider does not support attachment retrieval".into(),
                        data: None,
                    });
                }
                let attachment = provider
                    .get_attachment(&params.message_id, &params.attachment_id)
                    .await
                    .map_err(provider_rpc_error)?;
                // Serialize the cache write with account removal. A download
                // that finishes after removal (or after the same ID is added
                // with a new provider instance) must not repopulate the cache.
                let _mutation = self.account_mutations.lock().await;
                let still_active = self
                    .providers
                    .read()
                    .await
                    .get(&account_id)
                    .is_some_and(|active| Arc::ptr_eq(active, &provider));
                if self.removed_accounts.lock().await.contains(&account_id) || !still_active {
                    return Err(RpcError {
                        code: -32004,
                        message: "account was removed before attachment download completed".into(),
                        data: None,
                    });
                }
                encode(cache_attachment(&self.attachment_cache, attachment).await?)
            }
            method::DRAFT_SAVE => {
                let params: DraftSaveParams = decode(params)?;
                let (saved, revision) = self
                    .database
                    .save_draft(params.draft_id.as_deref(), &params.message)
                    .await
                    .map_err(storage_rpc_error)?;
                self.publish("mail", "mail.changed", revision);
                encode(json!({"draft": saved, "revision": revision}))
            }
            method::DRAFT_LIST => {
                let params: DraftListParams = decode_or_default(params)?;
                encode(
                    self.database
                        .list_drafts(params.account_id.as_deref())
                        .await
                        .map_err(storage_rpc_error)?,
                )
            }
            method::DRAFT_GET => {
                let params: DraftIdParams = decode(params)?;
                encode(
                    self.database
                        .get_draft(&params.draft_id)
                        .await
                        .map_err(storage_rpc_error)?,
                )
            }
            method::DRAFT_DELETE => {
                let params: DraftIdParams = decode(params)?;
                let revision = self
                    .database
                    .delete_draft(&params.draft_id)
                    .await
                    .map_err(storage_rpc_error)?;
                self.publish("mail", "mail.changed", revision);
                Ok(json!({"revision": revision}))
            }
            method::TASK_LIST => {
                let params: TaskListParams = decode_or_default(params)?;
                encode(
                    self.database
                        .list_tasks(params.include_done)
                        .await
                        .map_err(storage_rpc_error)?,
                )
            }
            method::TASK_CREATE | method::TASK_UPDATE => {
                let mut task: Task = decode(params)?;
                if task.id.is_empty() {
                    task.id = Uuid::new_v4().to_string();
                }
                let revision = self
                    .database
                    .upsert_task(&task)
                    .await
                    .map_err(storage_rpc_error)?;
                self.publish("agenda", "agenda.changed", revision);
                Ok(json!({"task": task, "revision": revision}))
            }
            method::TASK_COMPLETE => {
                let params: TaskCompleteParams = decode(params)?;
                let revision = self
                    .database
                    .complete_task(&params.task_id, params.done)
                    .await
                    .map_err(storage_rpc_error)?;
                self.publish("agenda", "agenda.changed", revision);
                Ok(json!({"revision": revision}))
            }
            method::TASK_DELETE => {
                let params: TaskIdParams = decode(params)?;
                let revision = self
                    .database
                    .delete_task(&params.task_id)
                    .await
                    .map_err(storage_rpc_error)?;
                self.publish("agenda", "agenda.changed", revision);
                Ok(json!({"revision": revision}))
            }
            method::CALENDAR_LIST => {
                let params: CalendarListParams = decode(params)?;
                encode(
                    self.database
                        .list_events(params.start_at, params.end_at)
                        .await
                        .map_err(storage_rpc_error)?,
                )
            }
            method::CALENDAR_CREATE | method::CALENDAR_UPDATE => {
                let mut event: CalendarEvent = decode(params)?;
                if event.id.is_empty() {
                    event.id = Uuid::new_v4().to_string();
                }
                let revision = self
                    .database
                    .upsert_events(&[event.clone()])
                    .await
                    .map_err(storage_rpc_error)?;
                self.publish("agenda", "agenda.changed", revision);
                Ok(json!({"event": event, "revision": revision}))
            }
            method::CALENDAR_DELETE => {
                let params: EventIdParams = decode(params)?;
                let revision = self
                    .database
                    .delete_event(&params.event_id)
                    .await
                    .map_err(storage_rpc_error)?;
                self.publish("agenda", "agenda.changed", revision);
                Ok(json!({"revision": revision}))
            }
            method::SYNC_START => {
                let params: SyncStartParams = decode_or_default(params)?;
                let (revision, background_started) = self
                    .sync_selected_accounts(params.account_id.as_deref())
                    .await?;
                self.publish("mail", "mail.changed", revision);
                self.publish_sync_state(params.account_id.as_deref(), revision, None)
                    .await;
                Ok(json!({
                    "accepted": true,
                    "completed": !background_started,
                    "backgroundStarted": background_started,
                    "revision": revision
                }))
            }
            _ => Err(RpcError::method_not_found(rpc_method)),
        }
    }

    fn publish(&self, topic: &str, event_method: &str, revision: u64) {
        let _ = self.events.send(ServerEvent {
            topic: topic.into(),
            method: event_method.into(),
            params: json!({"revision": revision, "at": Utc::now().timestamp_millis()}),
        });
    }

    async fn provider_for_account(
        &self,
        account_id: &str,
    ) -> Result<Arc<dyn MailProvider>, RpcError> {
        self.providers
            .read()
            .await
            .get(account_id)
            .cloned()
            .ok_or_else(|| RpcError {
                code: -32006,
                message: format!("provider is not active for account {account_id}"),
                data: None,
            })
    }

    async fn provider_for_message(
        &self,
        message_id: &str,
    ) -> Result<Arc<dyn MailProvider>, RpcError> {
        self.providers
            .read()
            .await
            .iter()
            .filter(|(account_id, _)| {
                quickmail_core::is_normalized_message_id(account_id, message_id)
            })
            .max_by_key(|(account_id, _)| account_id.len())
            .map(|(_, provider)| provider.clone())
            .ok_or_else(|| RpcError {
                code: -32006,
                message: "no active provider owns this message".into(),
                data: None,
            })
    }

    async fn apply_provider_action(&self, action: MailAction) -> Result<(), ProviderError> {
        let ids = action_message_ids(&action);
        let work = {
            let providers = self.providers.read().await;
            let mut grouped: HashMap<String, Vec<String>> = HashMap::new();
            for id in ids {
                let account_id = providers
                    .keys()
                    .filter(|account_id| quickmail_core::is_normalized_message_id(account_id, id))
                    .max_by_key(|account_id| account_id.len())
                    .ok_or_else(|| {
                        ProviderError::Other(format!("no provider owns message {id}"))
                    })?;
                grouped
                    .entry(account_id.clone())
                    .or_default()
                    .push(id.clone());
            }
            grouped
                .into_iter()
                .map(|(account_id, ids)| {
                    (
                        providers
                            .get(&account_id)
                            .expect("grouped provider exists")
                            .clone(),
                        action_with_ids(&action, ids),
                    )
                })
                .collect::<Vec<_>>()
        };
        for (provider, provider_action) in work {
            provider.apply_action(provider_action).await?;
        }
        Ok(())
    }

    async fn sync_selected_accounts(
        &self,
        account_id: Option<&str>,
    ) -> Result<(u64, bool), RpcError> {
        let providers = if let Some(account_id) = account_id {
            vec![self.provider_for_account(account_id).await?]
        } else {
            self.providers
                .read()
                .await
                .values()
                .cloned()
                .collect::<Vec<_>>()
        };
        let mut background_started = false;
        for provider in providers {
            let account_id = provider.account().id.clone();
            {
                let mut syncing = self.background_syncing.lock().await;
                if !syncing.insert(account_id.clone()) {
                    background_started = true;
                    continue;
                }
            }
            let mut mailboxes = match provider.list_mailboxes().await {
                Ok(mailboxes) => mailboxes,
                Err(error) => {
                    self.persist_provider_failure(&account_id, &error).await;
                    self.background_syncing.lock().await.remove(&account_id);
                    return Err(provider_rpc_error(error));
                }
            };
            mailboxes.sort_by_key(|mailbox| {
                if mailbox.role == Some(quickmail_core::MailboxRole::Inbox)
                    || mailbox.name.eq_ignore_ascii_case("inbox")
                {
                    0
                } else {
                    1
                }
            });
            let _mutation = self.account_mutations.lock().await;
            if self.removed_accounts.lock().await.contains(&account_id) {
                self.background_syncing.lock().await.remove(&account_id);
                continue;
            }
            if let Err(error) = self.database.upsert_mailboxes(&mailboxes).await {
                self.background_syncing.lock().await.remove(&account_id);
                return Err(storage_rpc_error(error));
            }
            let (unread, total) = account_counts_from_mailboxes(&mailboxes);
            if let Err(error) = self
                .database
                .update_account_counts(&account_id, unread, total)
                .await
            {
                self.background_syncing.lock().await.remove(&account_id);
                return Err(storage_rpc_error(error));
            }
            drop(_mutation);
            if let Some(inbox) = mailboxes.first()
                && let Err(error) = self.sync_mailbox_page(provider.as_ref(), inbox).await
            {
                self.persist_provider_failure(&account_id, &error).await;
                self.background_syncing.lock().await.remove(&account_id);
                return Err(provider_rpc_error(error));
            }
            background_started |= self
                .schedule_background_sync(provider, mailboxes.into_iter().skip(1).collect())
                .await;
        }
        Ok((
            self.database.revision().await.map_err(storage_rpc_error)?,
            background_started,
        ))
    }

    async fn sync_mailbox_page(
        &self,
        provider: &dyn MailProvider,
        mailbox: &quickmail_core::Mailbox,
    ) -> Result<(), ProviderError> {
        if self
            .removed_accounts
            .lock()
            .await
            .contains(&mailbox.account_id)
        {
            return Ok(());
        }
        let cursor = self
            .database
            .mailbox_sync_cursor(&mailbox.account_id, &mailbox.id)
            .await
            .map_err(|error| {
                ProviderError::Other(format!("could not read mailbox sync state: {error}"))
            })?;
        let reconcile_message_ids = self
            .database
            .list_messages(&MessageQuery {
                account_id: Some(mailbox.account_id.clone()),
                mailbox_id: Some(mailbox.id.clone()),
                limit: SYNC_FLAG_RECONCILE_SIZE,
                ..MessageQuery::default()
            })
            .await
            .map_err(|error| {
                ProviderError::Other(format!("could not read cached mailbox page: {error}"))
            })?
            .messages
            .into_iter()
            .map(|message| message.id)
            .collect();
        let page = provider
            .sync_mailbox(MailboxSyncQuery {
                account_id: mailbox.account_id.clone(),
                mailbox_id: mailbox.id.clone(),
                cursor,
                limit: SYNC_PAGE_SIZE,
                reconcile_message_ids,
            })
            .await?;
        let _mutation = self.account_mutations.lock().await;
        if self
            .removed_accounts
            .lock()
            .await
            .contains(&mailbox.account_id)
        {
            return Ok(());
        }
        self.database
            .apply_mailbox_sync_page(&mailbox.account_id, &mailbox.id, &page)
            .await
            .map_err(|error| ProviderError::Other(format!("could not cache sync page: {error}")))?;
        Ok(())
    }

    async fn schedule_background_sync(
        &self,
        provider: Arc<dyn MailProvider>,
        mailboxes: Vec<quickmail_core::Mailbox>,
    ) -> bool {
        if mailboxes.is_empty() || *self.background_shutdown.borrow() {
            self.background_syncing
                .lock()
                .await
                .remove(&provider.account().id);
            return false;
        }
        let account_id = provider.account().id.clone();
        let daemon = self.clone();
        let mut shutdown = self.background_shutdown.subscribe();
        let mut tasks = self.background_tasks.lock().await;
        while let Some(result) = tasks.try_join_next() {
            if let Err(error) = result {
                debug!(%error, "background sync task ended unexpectedly");
            }
        }
        tasks.spawn(async move {
            let result = daemon
                .run_background_sync(provider, mailboxes, &mut shutdown)
                .await;
            // Update the aggregate before publishing completion. With multiple
            // accounts, finishing one background task must not tell clients
            // that all synchronization has stopped.
            daemon.background_syncing.lock().await.remove(&account_id);
            match result {
                Ok(Some(revision)) => {
                    daemon.publish("mail", "mail.changed", revision);
                    daemon
                        .publish_sync_state(Some(&account_id), revision, None)
                        .await;
                }
                Ok(None) => {
                    let revision = daemon.database.revision().await.unwrap_or_default();
                    daemon
                        .publish_sync_state(Some(&account_id), revision, None)
                        .await;
                    debug!(%account_id, "background sync cancelled");
                }
                Err(error) => {
                    let revision = daemon.database.revision().await.unwrap_or_default();
                    daemon.publish("mail", "mail.changed", revision);
                    daemon
                        .publish_sync_state(Some(&account_id), revision, Some(&error.message))
                        .await;
                    warn!(%account_id, message = %error.message, "background sync failed");
                }
            }
        });
        true
    }

    async fn run_background_sync(
        &self,
        provider: Arc<dyn MailProvider>,
        mailboxes: Vec<quickmail_core::Mailbox>,
        shutdown: &mut watch::Receiver<bool>,
    ) -> Result<Option<u64>, RpcError> {
        let account_id = provider.account().id.clone();
        for mailbox in mailboxes {
            let result = tokio::select! {
                _ = wait_for_shutdown(shutdown) => return Ok(None),
                result = self.sync_mailbox_page(provider.as_ref(), &mailbox) => result,
            };
            if let Err(error) = result {
                self.persist_provider_failure(&account_id, &error).await;
                return Err(provider_rpc_error(error));
            }
            if self.removed_accounts.lock().await.contains(&account_id) {
                return Ok(None);
            }
        }
        let _mutation = self.account_mutations.lock().await;
        if self.removed_accounts.lock().await.contains(&account_id) {
            return Ok(None);
        }
        self.database
            .set_account_auth_state(&account_id, "ready", None)
            .await
            .map_err(storage_rpc_error)?;
        self.database
            .revision()
            .await
            .map(Some)
            .map_err(storage_rpc_error)
    }

    async fn persist_provider_failure(&self, account_id: &str, error: &ProviderError) {
        let _mutation = self.account_mutations.lock().await;
        if self.removed_accounts.lock().await.contains(account_id) {
            return;
        }
        let state = if matches!(error, ProviderError::Authentication(_)) {
            "needs_auth"
        } else {
            "error"
        };
        if let Err(storage_error) = self
            .database
            .set_account_auth_state(account_id, state, Some(&error.to_string()))
            .await
        {
            warn!(%account_id, %storage_error, "could not persist provider sync failure");
        }
    }

    async fn publish_sync_state(
        &self,
        account_id: Option<&str>,
        revision: u64,
        error: Option<&str>,
    ) {
        let background_remaining = self.background_syncing.lock().await.len();
        let running = background_remaining > 0;
        let status = if error.is_some() {
            "error"
        } else if running {
            "running"
        } else {
            "idle"
        };
        let mut params = json!({
            "revision": revision,
            "at": Utc::now().timestamp_millis(),
            "status": status,
            "running": running,
            "backgroundRemaining": background_remaining,
        });
        if let Some(account_id) = account_id {
            params["accountId"] = Value::String(account_id.to_owned());
        }
        if let Some(error) = error {
            params["error"] = Value::String(error.to_owned());
        }
        let _ = self.events.send(ServerEvent {
            topic: "sync".into(),
            method: "sync.changed".into(),
            params,
        });
    }
}

async fn wait_for_shutdown(shutdown: &mut watch::Receiver<bool>) {
    if *shutdown.borrow() {
        return;
    }
    let _ = shutdown.changed().await;
}

fn account_counts_from_mailboxes(mailboxes: &[quickmail_core::Mailbox]) -> (u64, u64) {
    mailboxes
        .iter()
        .find(|mailbox| mailbox.role == Some(quickmail_core::MailboxRole::Inbox))
        .or_else(|| {
            mailboxes
                .iter()
                .find(|mailbox| mailbox.name.eq_ignore_ascii_case("inbox"))
        })
        // Some servers expose overlapping folders without SPECIAL-USE roles.
        // The largest single mailbox is a safer fallback than double-counting
        // every folder or Gmail label.
        .or_else(|| mailboxes.iter().max_by_key(|mailbox| mailbox.total))
        .map_or((0, 0), |mailbox| (mailbox.unread, mailbox.total))
}

fn action_message_ids(action: &MailAction) -> &Vec<String> {
    match action {
        MailAction::MarkRead { message_ids, .. }
        | MailAction::Star { message_ids, .. }
        | MailAction::Archive { message_ids }
        | MailAction::Trash { message_ids }
        | MailAction::Move { message_ids, .. }
        | MailAction::SetLabels { message_ids, .. } => message_ids,
    }
}

fn action_with_ids(action: &MailAction, message_ids: Vec<String>) -> MailAction {
    match action {
        MailAction::MarkRead { read, .. } => MailAction::MarkRead {
            message_ids,
            read: *read,
        },
        MailAction::Star { starred, .. } => MailAction::Star {
            message_ids,
            starred: *starred,
        },
        MailAction::Archive { .. } => MailAction::Archive { message_ids },
        MailAction::Trash { .. } => MailAction::Trash { message_ids },
        MailAction::Move { mailbox_id, .. } => MailAction::Move {
            message_ids,
            mailbox_id: mailbox_id.clone(),
        },
        MailAction::SetLabels { labels, .. } => MailAction::SetLabels {
            message_ids,
            labels: labels.clone(),
        },
    }
}

fn decode<T: DeserializeOwned>(params: Value) -> Result<T, RpcError> {
    serde_json::from_value(params).map_err(|error| RpcError::invalid_params(error.to_string()))
}

fn decode_or_default<T: DeserializeOwned + Default>(params: Value) -> Result<T, RpcError> {
    if params.is_null() || params.as_object().is_some_and(serde_json::Map::is_empty) {
        Ok(T::default())
    } else {
        decode(params)
    }
}

fn encode(value: impl Serialize) -> Result<Value, RpcError> {
    serde_json::to_value(value).map_err(|error| RpcError::internal(error.to_string()))
}

fn storage_rpc_error(error: StorageError) -> RpcError {
    match error {
        StorageError::NotFound => RpcError {
            code: -32004,
            message: "resource not found".into(),
            data: None,
        },
        StorageError::InvalidCursor | StorageError::InvalidData(_) => {
            RpcError::invalid_params(error.to_string())
        }
        _ => RpcError::internal(error.to_string()),
    }
}

fn provider_rpc_error(error: ProviderError) -> RpcError {
    let code = match error {
        ProviderError::Authentication(_) => -32010,
        ProviderError::Unsupported(_) => -32005,
        ProviderError::NotFound => -32004,
        ProviderError::Temporary(_) => -32011,
        ProviderError::ResourceTooLarge(_) => -32013,
        ProviderError::Other(_) => -32012,
    };
    RpcError {
        code,
        message: error.to_string(),
        data: None,
    }
}

fn sanitize_message_html(message: &mut quickmail_core::Message) {
    if let Some(html) = message.body_html.take() {
        message.body_html = Some(sanitize_html_body(&html));
    }
}

fn sanitize_html_body(html: &str) -> String {
    HTML_SANITIZER.clean(html).to_string()
}

fn validate_account_setup(setup: &AccountAddParams) -> Result<(), RpcError> {
    if setup.provider.trim().is_empty() || setup.address.trim().is_empty() {
        return Err(RpcError::invalid_params(
            "provider and address are required",
        ));
    }
    let is_gmail = setup.provider.eq_ignore_ascii_case("gmail");
    if !is_gmail && (setup.imap.is_none() || setup.smtp.is_none()) {
        return Err(RpcError::invalid_params(
            "account setup requires both imap and smtp settings",
        ));
    }
    for server in setup.imap.iter().chain(setup.smtp.iter()) {
        if server.host.trim().is_empty()
            || server.username.trim().is_empty()
            || server.port == 0
            || !matches!(server.security.as_str(), "tls" | "starttls" | "none")
        {
            return Err(RpcError::invalid_params("invalid mail server settings"));
        }
    }
    Ok(())
}

fn nonsecret_account_config(setup: &AccountAddParams) -> Value {
    if setup.provider.eq_ignore_ascii_case("gmail") {
        return json!({"provider": "gmail"});
    }
    json!({
        "provider": setup.provider,
        "imap": setup.imap.as_ref().map(|server| json!({
            "host": server.host, "port": server.port, "security": server.security,
            "username": server.username,
        })),
        "smtp": setup.smtp.as_ref().map(|server| json!({
            "host": server.host, "port": server.port, "security": server.security,
            "username": server.username,
        })),
    })
}

fn validate_opaque_id(id: &str, name: &str) -> Result<(), RpcError> {
    if id.is_empty()
        || id.len() > 512
        || id
            .bytes()
            .any(|byte| byte == 0 || byte == b'/' || byte == b'\\')
    {
        return Err(RpcError::invalid_params(format!("invalid {name}")));
    }
    Ok(())
}

async fn cache_attachment(
    cache_directory: &Path,
    attachment: AttachmentData,
) -> Result<AttachmentDownloaded, RpcError> {
    cache_attachment_with_limit(cache_directory, attachment, MAX_MAIL_ATTACHMENT_BYTES).await
}

async fn cache_attachment_with_limit(
    cache_directory: &Path,
    attachment: AttachmentData,
    max_bytes: usize,
) -> Result<AttachmentDownloaded, RpcError> {
    if attachment.bytes.len() > max_bytes {
        return Err(RpcError {
            code: -32013,
            message: "attachment exceeds the configured size limit".into(),
            data: None,
        });
    }
    let directory = cache_directory.to_owned();
    let friendly_name = safe_attachment_name(&attachment.filename);
    let path = directory.join(Uuid::new_v4().to_string());
    let write_path = path.clone();
    let bytes = attachment.bytes;
    let size = bytes.len() as u64;
    tokio::task::spawn_blocking(move || -> io::Result<()> {
        use std::{io::Write, os::unix::fs::OpenOptionsExt};
        ensure_private_directory(&directory)?;
        let mut file = std::fs::OpenOptions::new()
            .create_new(true)
            .write(true)
            .mode(0o600)
            .open(write_path)?;
        file.write_all(&bytes)
    })
    .await
    .map_err(|error| RpcError::internal(error.to_string()))?
    .map_err(|error| RpcError::internal(error.to_string()))?;
    Ok(AttachmentDownloaded {
        path: path.to_string_lossy().into_owned(),
        filename: friendly_name,
        content_type: attachment.content_type,
        size,
    })
}

async fn purge_attachment_cache(cache_directory: &Path) -> Result<usize, RpcError> {
    let directory = cache_directory.to_owned();
    tokio::task::spawn_blocking(move || purge_attachment_cache_files(&directory))
        .await
        .map_err(|error| RpcError::internal(error.to_string()))?
        .map_err(|error| RpcError::internal(error.to_string()))
}

fn purge_attachment_cache_files(cache_directory: &Path) -> io::Result<usize> {
    let metadata = match std::fs::symlink_metadata(cache_directory) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(0),
        Err(error) => return Err(error),
    };
    if !metadata.file_type().is_dir()
        || metadata.uid() != current_uid()
        || metadata.permissions().mode() & 0o077 != 0
    {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            format!(
                "attachment cache is not private and user-owned: {}",
                cache_directory.display()
            ),
        ));
    }

    let mut removed = 0;
    for entry in std::fs::read_dir(cache_directory)? {
        let entry = entry?;
        if !entry.file_type()?.is_file() {
            continue;
        }
        let file_name = entry.file_name();
        let Some(file_name) = file_name.to_str() else {
            continue;
        };
        let Ok(cache_id) = Uuid::parse_str(file_name) else {
            continue;
        };
        if cache_id.to_string() != file_name {
            continue;
        }
        if entry.metadata()?.uid() != current_uid() {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "attachment cache file is not user-owned",
            ));
        }
        std::fs::remove_file(entry.path())?;
        removed += 1;
    }
    Ok(removed)
}

fn safe_attachment_name(filename: &str) -> String {
    let basename = Path::new(filename)
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("attachment");
    let filtered = basename
        .chars()
        .filter(|character| !character.is_control() && *character != '/' && *character != '\\')
        .take(160)
        .collect::<String>();
    if filtered.trim().is_empty() {
        "attachment".into()
    } else {
        filtered
    }
}

async fn write_json_line(
    writer: &mut tokio::net::unix::OwnedWriteHalf,
    value: &impl Serialize,
) -> Result<(), io::Error> {
    let mut payload = serde_json::to_vec(value).map_err(io::Error::other)?;
    payload.push(b'\n');
    writer.write_all(&payload).await
}

struct BoundUserSocket {
    listener: UnixListener,
    guard: SocketGuard,
}

fn bind_user_socket(path: &Path) -> Result<BoundUserSocket, DaemonError> {
    let parent = path
        .parent()
        .ok_or_else(|| DaemonError::UnsafeSocket("missing parent".into()))?;
    ensure_private_directory(parent)
        .map_err(|_| DaemonError::UnsafeSocket(parent.display().to_string()))?;

    // Serialize stale-socket recovery. Without this lock, two daemons can both
    // observe ECONNREFUSED and one can unlink the listener the other just bound.
    let lock = acquire_socket_lock(path)?;
    match std::fs::symlink_metadata(path) {
        Ok(metadata) => {
            validate_socket_metadata(path, &metadata, current_uid())?;
            match StdUnixStream::connect(path) {
                Ok(_) => return Err(DaemonError::SocketInUse(path.display().to_string())),
                Err(error) if error.kind() == io::ErrorKind::ConnectionRefused => {
                    std::fs::remove_file(path)
                        .map_err(|error| io_context("remove stale socket", error))?;
                }
                Err(error) if error.kind() == io::ErrorKind::NotFound => {}
                Err(_) => return Err(DaemonError::UnsafeSocket(path.display().to_string())),
            }
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(io_context("inspect unix socket", error).into()),
    }

    let listener = std::os::unix::net::UnixListener::bind(path)
        .map_err(|error| io_context("bind unix socket", error))?;
    listener
        .set_nonblocking(true)
        .map_err(|error| io_context("set unix socket nonblocking", error))?;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))
        .map_err(|error| io_context("secure unix socket", error))?;
    let metadata = std::fs::symlink_metadata(path)
        .map_err(|error| io_context("inspect bound unix socket", error))?;
    let guard = SocketGuard {
        path: path.to_owned(),
        device: metadata.dev(),
        inode: metadata.ino(),
        _lock: lock,
    };
    let listener = UnixListener::from_std(listener)?;
    Ok(BoundUserSocket { listener, guard })
}

fn acquire_socket_lock(socket_path: &Path) -> Result<File, DaemonError> {
    let mut lock_name = socket_path.as_os_str().to_os_string();
    lock_name.push(".lock");
    let lock_path = PathBuf::from(lock_name);
    let lock = std::fs::OpenOptions::new()
        .create(true)
        .read(true)
        .write(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(&lock_path)
        .map_err(|_| DaemonError::UnsafeSocket(lock_path.display().to_string()))?;
    let metadata = lock
        .metadata()
        .map_err(|_| DaemonError::UnsafeSocket(lock_path.display().to_string()))?;
    if !metadata.file_type().is_file()
        || metadata.uid() != current_uid()
        || metadata.permissions().mode() & 0o077 != 0
    {
        return Err(DaemonError::UnsafeSocket(lock_path.display().to_string()));
    }

    // SAFETY: `lock` owns a valid file descriptor for the duration of this call.
    let result = unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
    if result == 0 {
        return Ok(lock);
    }
    let error = io::Error::last_os_error();
    if error.kind() == io::ErrorKind::WouldBlock {
        Err(DaemonError::SocketInUse(socket_path.display().to_string()))
    } else {
        Err(io_context("lock unix socket", error).into())
    }
}

fn validate_socket_metadata(
    path: &Path,
    metadata: &std::fs::Metadata,
    expected_uid: u32,
) -> Result<(), DaemonError> {
    if !metadata.file_type().is_socket()
        || metadata.uid() != expected_uid
        || metadata.permissions().mode() & 0o077 != 0
    {
        return Err(DaemonError::UnsafeSocket(path.display().to_string()));
    }
    Ok(())
}

fn ensure_private_directory(path: &Path) -> io::Result<()> {
    let mut missing = Vec::<PathBuf>::new();
    let mut cursor = path;
    while !cursor.exists() {
        missing.push(cursor.to_owned());
        cursor = cursor.parent().ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("could not find an existing parent for {}", path.display()),
            )
        })?;
    }
    for directory in missing.iter().rev() {
        std::fs::create_dir(directory)?;
        std::fs::set_permissions(directory, std::fs::Permissions::from_mode(0o700))?;
    }
    let metadata = std::fs::symlink_metadata(path)?;
    if !metadata.file_type().is_dir()
        || metadata.uid() != current_uid()
        || metadata.permissions().mode() & 0o077 != 0
    {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            format!(
                "directory is not private and user-owned: {}",
                path.display()
            ),
        ));
    }
    Ok(())
}

fn io_context(action: &str, error: io::Error) -> io::Error {
    io::Error::new(error.kind(), format!("{action}: {error}"))
}

fn peer_is_current_user(stream: &UnixStream) -> Result<bool, io::Error> {
    Ok(stream.peer_cred()?.uid() == current_uid())
}

fn current_uid() -> u32 {
    // SAFETY: geteuid takes no pointers and has no preconditions.
    unsafe { libc::geteuid() }
}

struct SocketGuard {
    path: PathBuf,
    device: u64,
    inode: u64,
    _lock: File,
}

impl Drop for SocketGuard {
    fn drop(&mut self) {
        let still_owned = std::fs::symlink_metadata(&self.path)
            .is_ok_and(|metadata| metadata.dev() == self.device && metadata.ino() == self.inode);
        if still_owned {
            let _ = std::fs::remove_file(&self.path);
        }
    }
}

#[cfg(test)]
mod tests {
    use std::{
        os::unix::{
            fs::{MetadataExt, PermissionsExt},
            net::{UnixListener as StdUnixListener, UnixStream as StdUnixStream},
        },
        sync::{
            Arc, Mutex as StdMutex,
            atomic::{AtomicUsize, Ordering},
        },
        time::Duration,
    };

    use async_trait::async_trait;
    use chrono::Utc;
    use quickmail_core::{
        Account, Address, AttachmentData, Mailbox, MailboxRole, MailboxSyncPage, Message,
        MessagePage, MessageSummary, ProviderCapabilities,
    };
    use serde_json::json;
    use tempfile::tempdir;
    use tokio::{
        io::AsyncBufReadExt,
        sync::{Semaphore, oneshot},
    };

    use super::*;

    struct MockProvider {
        account: Account,
        list_calls: AtomicUsize,
        get_calls: AtomicUsize,
        endless: bool,
        fail_send: bool,
    }

    impl MockProvider {
        fn message(&self) -> Message {
            Message {
                summary: MessageSummary {
                    id: quickmail_core::normalized_message_id(&self.account.id, "42"),
                    account_id: self.account.id.clone(),
                    mailbox_id: Some("mock-inbox".into()),
                    thread_id: None,
                    subject: "Provider-backed message".into(),
                    author: Some(Address {
                        name: "Maya".into(),
                        address: "maya@example.com".into(),
                    }),
                    timestamp: Utc::now(),
                    read: false,
                    starred: false,
                    snippet: "Fetched through the provider seam".into(),
                    has_attachments: true,
                    labels: vec!["Inbox".into()],
                    provider_data: json!({"nativeId": "42"}),
                },
                to: vec![],
                cc: vec![],
                bcc: vec![],
                body_text: None,
                body_html: None,
                attachments: vec![],
            }
        }
    }

    #[async_trait]
    impl MailProvider for MockProvider {
        fn kind(&self) -> &'static str {
            "mock"
        }
        fn account(&self) -> &Account {
            &self.account
        }
        fn capabilities(&self) -> ProviderCapabilities {
            ProviderCapabilities {
                folders: true,
                attachment_retrieval: true,
                ..Default::default()
            }
        }
        async fn list_mailboxes(&self) -> Result<Vec<Mailbox>, ProviderError> {
            Ok(vec![Mailbox {
                id: "mock-inbox".into(),
                account_id: self.account.id.clone(),
                name: "Inbox".into(),
                role: Some(MailboxRole::Inbox),
                unread: 1,
                total: 1,
            }])
        }
        async fn list_messages(&self, _query: MessageQuery) -> Result<MessagePage, ProviderError> {
            self.list_calls.fetch_add(1, Ordering::SeqCst);
            Ok(MessagePage {
                messages: vec![self.message().summary],
                next_cursor: self.endless.then(|| Uuid::new_v4().to_string()),
            })
        }
        async fn get_message(&self, id: &str) -> Result<Message, ProviderError> {
            self.get_calls.fetch_add(1, Ordering::SeqCst);
            let message = self.message();
            if message.summary.id == id {
                Ok(message)
            } else {
                Err(ProviderError::NotFound)
            }
        }
        async fn apply_action(&self, _action: MailAction) -> Result<(), ProviderError> {
            Ok(())
        }
        async fn send(&self, _message: OutgoingMessage) -> Result<String, ProviderError> {
            if self.fail_send {
                return Err(ProviderError::Temporary("send failed".into()));
            }
            Ok(quickmail_core::normalized_message_id(
                &self.account.id,
                "sent-1",
            ))
        }
        async fn get_attachment(
            &self,
            _message_id: &str,
            _attachment_id: &str,
        ) -> Result<AttachmentData, ProviderError> {
            Ok(AttachmentData {
                filename: "../../unsafe report.txt".into(),
                content_type: "text/plain".into(),
                bytes: b"attachment bytes".to_vec(),
            })
        }
    }

    struct BlockingAttachmentProvider {
        account: Account,
        started: Arc<Semaphore>,
        release: Arc<Semaphore>,
    }

    #[async_trait]
    impl MailProvider for BlockingAttachmentProvider {
        fn kind(&self) -> &'static str {
            "blocking-attachment"
        }

        fn account(&self) -> &Account {
            &self.account
        }

        fn capabilities(&self) -> ProviderCapabilities {
            ProviderCapabilities {
                attachment_retrieval: true,
                ..ProviderCapabilities::default()
            }
        }

        async fn list_mailboxes(&self) -> Result<Vec<Mailbox>, ProviderError> {
            Ok(vec![])
        }

        async fn list_messages(&self, _query: MessageQuery) -> Result<MessagePage, ProviderError> {
            Ok(MessagePage {
                messages: vec![],
                next_cursor: None,
            })
        }

        async fn get_message(&self, _id: &str) -> Result<Message, ProviderError> {
            Err(ProviderError::NotFound)
        }

        async fn apply_action(&self, _action: MailAction) -> Result<(), ProviderError> {
            Ok(())
        }

        async fn send(&self, _message: OutgoingMessage) -> Result<String, ProviderError> {
            Err(ProviderError::Unsupported("send".into()))
        }

        async fn get_attachment(
            &self,
            _message_id: &str,
            _attachment_id: &str,
        ) -> Result<AttachmentData, ProviderError> {
            self.started.add_permits(1);
            self.release
                .acquire()
                .await
                .map_err(|_| ProviderError::Temporary("attachment test interrupted".into()))?
                .forget();
            Ok(AttachmentData {
                filename: "late.txt".into(),
                content_type: "text/plain".into(),
                bytes: b"must not survive removal".to_vec(),
            })
        }
    }

    struct MockFactory {
        provider: Arc<dyn MailProvider>,
        remove_calls: Arc<AtomicUsize>,
        fail_restore_auth: bool,
    }

    struct CursorSyncProvider {
        account: Account,
        calls: AtomicUsize,
        queries: StdMutex<Vec<MailboxSyncQuery>>,
    }

    impl CursorSyncProvider {
        fn summary(&self, reconciled: bool) -> MessageSummary {
            MessageSummary {
                id: quickmail_core::normalized_message_id(&self.account.id, "cursor-message"),
                account_id: self.account.id.clone(),
                mailbox_id: Some("inbox".into()),
                thread_id: None,
                subject: "Incremental message".into(),
                author: None,
                timestamp: Utc::now(),
                read: reconciled,
                starred: reconciled,
                snippet: String::new(),
                has_attachments: false,
                labels: Vec::new(),
                provider_data: json!({}),
            }
        }
    }

    #[async_trait]
    impl MailProvider for CursorSyncProvider {
        fn kind(&self) -> &'static str {
            "cursor-sync"
        }

        fn account(&self) -> &Account {
            &self.account
        }

        fn capabilities(&self) -> ProviderCapabilities {
            ProviderCapabilities::default()
        }

        async fn list_mailboxes(&self) -> Result<Vec<Mailbox>, ProviderError> {
            Ok(Vec::new())
        }

        async fn list_messages(&self, _query: MessageQuery) -> Result<MessagePage, ProviderError> {
            panic!("incremental daemon sync must call sync_mailbox")
        }

        async fn sync_mailbox(
            &self,
            query: MailboxSyncQuery,
        ) -> Result<MailboxSyncPage, ProviderError> {
            self.queries.lock().unwrap().push(query);
            let call = self.calls.fetch_add(1, Ordering::SeqCst);
            Ok(MailboxSyncPage {
                messages: vec![self.summary(call > 0)],
                removed_message_ids: Vec::new(),
                cursor: Some(if call == 0 { "777:42" } else { "777:43" }.into()),
                reset: false,
            })
        }

        async fn get_message(&self, _id: &str) -> Result<Message, ProviderError> {
            Err(ProviderError::NotFound)
        }

        async fn apply_action(&self, _action: MailAction) -> Result<(), ProviderError> {
            Ok(())
        }

        async fn send(&self, _message: OutgoingMessage) -> Result<String, ProviderError> {
            Err(ProviderError::Unsupported("send".into()))
        }
    }

    struct OrderedProvider {
        account: Account,
        calls: Arc<StdMutex<Vec<String>>>,
        background_gate: Arc<Semaphore>,
        active: Arc<AtomicUsize>,
        max_active: Arc<AtomicUsize>,
    }

    struct ActiveCall {
        active: Arc<AtomicUsize>,
    }

    impl Drop for ActiveCall {
        fn drop(&mut self) {
            self.active.fetch_sub(1, Ordering::SeqCst);
        }
    }

    impl OrderedProvider {
        fn begin_call(&self, name: String) -> ActiveCall {
            self.calls.lock().unwrap().push(name);
            let active = self.active.fetch_add(1, Ordering::SeqCst) + 1;
            self.max_active.fetch_max(active, Ordering::SeqCst);
            ActiveCall {
                active: self.active.clone(),
            }
        }
    }

    #[async_trait]
    impl MailProvider for OrderedProvider {
        fn kind(&self) -> &'static str {
            "ordered"
        }

        fn account(&self) -> &Account {
            &self.account
        }

        fn capabilities(&self) -> ProviderCapabilities {
            ProviderCapabilities::default()
        }

        async fn list_mailboxes(&self) -> Result<Vec<Mailbox>, ProviderError> {
            self.calls.lock().unwrap().push("mailboxes".into());
            Ok(vec![
                Mailbox {
                    id: "archive".into(),
                    account_id: self.account.id.clone(),
                    name: "Archive".into(),
                    role: Some(MailboxRole::Archive),
                    unread: 0,
                    total: 500,
                },
                Mailbox {
                    id: "inbox".into(),
                    account_id: self.account.id.clone(),
                    name: "Inbox".into(),
                    role: Some(MailboxRole::Inbox),
                    unread: 4,
                    total: 20,
                },
                Mailbox {
                    id: "sent".into(),
                    account_id: self.account.id.clone(),
                    name: "Sent".into(),
                    role: Some(MailboxRole::Sent),
                    unread: 0,
                    total: 300,
                },
            ])
        }

        async fn list_messages(&self, query: MessageQuery) -> Result<MessagePage, ProviderError> {
            let mailbox = query.mailbox_id.unwrap();
            let _active = self.begin_call(mailbox.clone());
            if mailbox != "inbox" {
                self.background_gate
                    .acquire()
                    .await
                    .map_err(|_| ProviderError::Temporary("test gate closed".into()))?
                    .forget();
            }
            Ok(MessagePage {
                messages: vec![],
                next_cursor: None,
            })
        }

        async fn get_message(&self, _id: &str) -> Result<Message, ProviderError> {
            Err(ProviderError::NotFound)
        }

        async fn apply_action(&self, _action: MailAction) -> Result<(), ProviderError> {
            Ok(())
        }

        async fn send(&self, _message: OutgoingMessage) -> Result<String, ProviderError> {
            Err(ProviderError::Unsupported("send".into()))
        }
    }

    #[async_trait]
    impl ProviderFactory for MockFactory {
        async fn create(
            &self,
            _setup: AccountAddParams,
        ) -> Result<Arc<dyn MailProvider>, ProviderError> {
            Ok(self.provider.clone())
        }

        async fn restore(
            &self,
            _account: &Account,
            _config: &Value,
        ) -> Result<Arc<dyn MailProvider>, ProviderError> {
            if self.fail_restore_auth {
                Err(ProviderError::Authentication(
                    "authorization expired".into(),
                ))
            } else {
                Ok(self.provider.clone())
            }
        }

        async fn reauthorize(
            &self,
            _account: &Account,
            _config: &Value,
        ) -> Result<Arc<dyn MailProvider>, ProviderError> {
            Ok(self.provider.clone())
        }

        async fn remove(&self, _account_id: &str) -> Result<(), ProviderError> {
            self.remove_calls.fetch_add(1, Ordering::SeqCst);
            Ok(())
        }
    }

    struct PendingFactory;

    #[async_trait]
    impl ProviderFactory for PendingFactory {
        async fn create(
            &self,
            _setup: AccountAddParams,
        ) -> Result<Arc<dyn MailProvider>, ProviderError> {
            std::future::pending().await
        }

        async fn restore(
            &self,
            _account: &Account,
            _config: &Value,
        ) -> Result<Arc<dyn MailProvider>, ProviderError> {
            Err(ProviderError::Unsupported("restore".into()))
        }

        async fn reauthorize(
            &self,
            _account: &Account,
            _config: &Value,
        ) -> Result<Arc<dyn MailProvider>, ProviderError> {
            std::future::pending().await
        }

        async fn remove(&self, _account_id: &str) -> Result<(), ProviderError> {
            Ok(())
        }
    }

    async fn send_request(
        writer: &mut tokio::net::unix::OwnedWriteHalf,
        reader: &mut BufReader<tokio::net::unix::OwnedReadHalf>,
        request: Value,
    ) -> RpcResponse {
        writer
            .write_all(format!("{request}\n").as_bytes())
            .await
            .unwrap();
        let mut line = String::new();
        reader.read_line(&mut line).await.unwrap();
        serde_json::from_str(&line).unwrap()
    }

    async fn wait_for_socket(path: &Path) {
        for _ in 0..200 {
            if path.exists() {
                return;
            }
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
        panic!("socket was not created: {}", path.display());
    }

    fn private_socket_path(root: &Path, name: &str) -> PathBuf {
        let runtime = root.join("runtime");
        std::fs::create_dir(&runtime).unwrap();
        std::fs::set_permissions(&runtime, std::fs::Permissions::from_mode(0o700)).unwrap();
        runtime.join(name)
    }

    #[tokio::test]
    async fn socket_is_private_and_shutdown_is_graceful() {
        let directory = tempdir().unwrap();
        let socket = directory.path().join("runtime/quickmail.sock");
        let database = Database::open_in_memory().unwrap();
        let daemon = Daemon::new(database);
        let (shutdown_sender, shutdown_receiver) = oneshot::channel();
        let server_socket = socket.clone();
        let server = tokio::spawn(async move {
            let result = daemon
                .run_with_shutdown(server_socket, async {
                    let _ = shutdown_receiver.await;
                })
                .await;
            if let Err(error) = &result {
                eprintln!("test daemon failed: {error}");
            }
            result
        });

        wait_for_socket(&socket).await;
        let mode = std::fs::metadata(&socket).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);

        let stream = UnixStream::connect(&socket).await.unwrap();
        let (reader, mut writer) = stream.into_split();
        let mut reader = BufReader::new(reader);
        writer
            .write_all(
                format!(
                    "{}\n",
                    json!({"jsonrpc":"2.0","id":1,"method":"ping","params":{}})
                )
                .as_bytes(),
            )
            .await
            .unwrap();
        let mut line = String::new();
        reader.read_line(&mut line).await.unwrap();
        let response: RpcResponse = serde_json::from_str(&line).unwrap();
        assert_eq!(response.result.unwrap()["pong"], true);

        shutdown_sender.send(()).unwrap();
        server.await.unwrap().unwrap();
        assert!(!socket.exists());
    }

    #[tokio::test]
    async fn second_daemon_does_not_displace_a_live_same_user_listener() {
        let directory = tempdir().unwrap();
        let socket = private_socket_path(directory.path(), "live.sock");
        let original = StdUnixListener::bind(&socket).unwrap();
        std::fs::set_permissions(&socket, std::fs::Permissions::from_mode(0o600)).unwrap();
        let original_inode = std::fs::symlink_metadata(&socket).unwrap().ino();

        let error = match bind_user_socket(&socket) {
            Err(error) => error,
            Ok(_) => panic!("a second daemon displaced the live listener"),
        };
        assert!(matches!(error, DaemonError::SocketInUse(_)));
        assert_eq!(
            std::fs::symlink_metadata(&socket).unwrap().ino(),
            original_inode
        );
        StdUnixStream::connect(&socket).unwrap();
        drop(original);
    }

    #[tokio::test]
    async fn stale_same_user_socket_is_replaced_by_a_connectable_listener() {
        let directory = tempdir().unwrap();
        let socket = private_socket_path(directory.path(), "stale.sock");
        let stale = StdUnixListener::bind(&socket).unwrap();
        std::fs::set_permissions(&socket, std::fs::Permissions::from_mode(0o600)).unwrap();
        drop(stale);

        let bound = bind_user_socket(&socket).unwrap();
        // A filesystem may immediately reuse the unlinked socket's inode, so
        // inode inequality is not evidence of successful stale recovery. A
        // connection to the newly returned listener is the portable check.
        let metadata = std::fs::symlink_metadata(&socket).unwrap();
        assert!(metadata.file_type().is_socket());
        assert_eq!(metadata.permissions().mode() & 0o777, 0o600);
        StdUnixStream::connect(&socket).unwrap();
        drop(bound);
        assert!(!socket.exists());
    }

    #[tokio::test]
    async fn daemon_lock_prevents_concurrent_stale_socket_recovery() {
        let directory = tempdir().unwrap();
        let socket = private_socket_path(directory.path(), "locked.sock");
        let first = bind_user_socket(&socket).unwrap();
        let original_inode = std::fs::symlink_metadata(&socket).unwrap().ino();

        let error = match bind_user_socket(&socket) {
            Err(error) => error,
            Ok(_) => panic!("a second daemon acquired the held socket lock"),
        };
        assert!(matches!(error, DaemonError::SocketInUse(_)));
        assert_eq!(
            std::fs::symlink_metadata(&socket).unwrap().ino(),
            original_inode
        );
        StdUnixStream::connect(&socket).unwrap();
        drop(first);
    }

    #[tokio::test]
    async fn socket_binding_rejects_non_socket_and_wrong_owner_metadata() {
        let directory = tempdir().unwrap();
        let path = private_socket_path(directory.path(), "not-a-socket");
        std::fs::write(&path, b"keep me").unwrap();
        assert!(matches!(
            bind_user_socket(&path),
            Err(DaemonError::UnsafeSocket(_))
        ));
        assert_eq!(std::fs::read(&path).unwrap(), b"keep me");

        let socket = directory.path().join("owner-check.sock");
        let listener = StdUnixListener::bind(&socket).unwrap();
        std::fs::set_permissions(&socket, std::fs::Permissions::from_mode(0o600)).unwrap();
        let metadata = std::fs::symlink_metadata(&socket).unwrap();
        assert!(validate_socket_metadata(&socket, &metadata, current_uid()).is_ok());
        assert!(matches!(
            validate_socket_metadata(&socket, &metadata, current_uid().wrapping_add(1)),
            Err(DaemonError::UnsafeSocket(_))
        ));
        drop(listener);
    }

    #[tokio::test]
    async fn socket_guard_never_removes_a_replacement_listener() {
        let directory = tempdir().unwrap();
        let socket = private_socket_path(directory.path(), "replacement.sock");
        let bound = bind_user_socket(&socket).unwrap();
        std::fs::remove_file(&socket).unwrap();
        let replacement = StdUnixListener::bind(&socket).unwrap();
        let replacement_inode = std::fs::symlink_metadata(&socket).unwrap().ino();

        drop(bound);
        assert_eq!(
            std::fs::symlink_metadata(&socket).unwrap().ino(),
            replacement_inode
        );
        StdUnixStream::connect(&socket).unwrap();
        drop(replacement);
    }

    #[tokio::test]
    async fn daemon_shutdown_cancels_and_joins_background_sync() {
        let directory = tempdir().unwrap();
        let socket = directory.path().join("runtime/background.sock");
        let account = Account {
            id: "shutdown-account".into(),
            address: "shutdown@example.com".into(),
            display_name: "Shutdown".into(),
            provider: "ordered".into(),
            protocol: "ORDERED".into(),
            host: "example.com".into(),
            unread: 0,
            total: 0,
            enabled: true,
        };
        let calls = Arc::new(StdMutex::new(Vec::new()));
        let active = Arc::new(AtomicUsize::new(0));
        let provider = Arc::new(OrderedProvider {
            account: account.clone(),
            calls: calls.clone(),
            background_gate: Arc::new(Semaphore::new(0)),
            active: active.clone(),
            max_active: Arc::new(AtomicUsize::new(0)),
        });
        let database = Database::open_in_memory().unwrap();
        database.upsert_account(&account).await.unwrap();
        let daemon = Daemon::new(database);
        daemon
            .providers
            .write()
            .await
            .insert(account.id.clone(), provider);
        assert!(daemon.sync_selected_accounts(None).await.unwrap().1);
        tokio::time::timeout(Duration::from_millis(100), async {
            while active.load(Ordering::SeqCst) == 0 {
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("background provider call did not start");

        let observer = daemon.clone();
        let (shutdown_sender, shutdown_receiver) = oneshot::channel();
        let server_socket = socket.clone();
        let server = tokio::spawn(async move {
            daemon
                .run_with_shutdown(server_socket, async {
                    let _ = shutdown_receiver.await;
                })
                .await
        });
        wait_for_socket(&socket).await;
        shutdown_sender.send(()).unwrap();
        tokio::time::timeout(Duration::from_secs(1), server)
            .await
            .expect("daemon did not join cancelled background sync")
            .unwrap()
            .unwrap();

        assert_eq!(active.load(Ordering::SeqCst), 0);
        assert!(observer.background_syncing.lock().await.is_empty());
        assert!(!socket.exists());
    }

    #[tokio::test]
    async fn daemon_shutdown_cancels_an_in_flight_rpc_dispatch() {
        let directory = tempdir().unwrap();
        let socket = directory.path().join("runtime/pending.sock");
        let daemon = Daemon::with_provider_factory(
            Database::open_in_memory().unwrap(),
            Arc::new(PendingFactory),
            directory.path().join("attachments"),
        );
        let (shutdown_sender, shutdown_receiver) = oneshot::channel();
        let server_socket = socket.clone();
        let server = tokio::spawn(async move {
            daemon
                .run_with_shutdown(server_socket, async {
                    let _ = shutdown_receiver.await;
                })
                .await
        });
        wait_for_socket(&socket).await;
        let mut stream = UnixStream::connect(&socket).await.unwrap();
        stream
            .write_all(
                format!(
                    "{}\n",
                    json!({
                        "jsonrpc":"2.0", "id":1, "method":"accounts.add",
                        "params":{"provider":"gmail", "address":"person@gmail.com", "displayName":"Person"}
                    })
                )
                .as_bytes(),
            )
            .await
            .unwrap();
        tokio::task::yield_now().await;
        shutdown_sender.send(()).unwrap();
        tokio::time::timeout(Duration::from_secs(1), server)
            .await
            .expect("shutdown waited for in-flight dispatch")
            .unwrap()
            .unwrap();
        assert!(!socket.exists());
    }

    #[test]
    fn received_html_uses_positive_resource_and_style_allowlists() {
        let cleaned = sanitize_html_body(
            r#"<div onclick="bad()" style="color:red; background-image:url(file:///secret); font-weight:bold">
                <script>bad()</script>
                <img src="https://images.example/pixel.png" onerror="bad()">
                <img src="f&#x69;le:///home/person/private.png">
                <a href="javascript:bad()">unsafe</a>
                <a href="mailto:person@example.com">mail</a>
                <a href="/relative">relative</a>
            </div>"#,
        );

        assert!(cleaned.contains("https://images.example/pixel.png"));
        assert_eq!(cleaned.matches("src=").count(), 1);
        assert!(cleaned.contains("color:red"));
        assert!(cleaned.contains("font-weight:bold"));
        assert!(cleaned.contains("mailto:person@example.com"));
        for forbidden in [
            "onclick",
            "onerror",
            "<script",
            "javascript:",
            "file:",
            "background-image",
            "href=\"/relative\"",
        ] {
            assert!(!cleaned.contains(forbidden), "survived: {forbidden}");
        }
    }

    #[tokio::test]
    async fn adding_an_existing_gmail_account_is_idempotent() {
        let database = Database::open_in_memory().unwrap();
        let account = Account {
            id: "existing-gmail".into(),
            address: "Person@Gmail.com".into(),
            display_name: "Person".into(),
            provider: "gmail".into(),
            protocol: "gmail".into(),
            host: String::new(),
            unread: 7,
            total: 42,
            enabled: true,
        };
        let revision = database.upsert_account(&account).await.unwrap();
        let daemon = Daemon::with_provider_factory(
            database.clone(),
            Arc::new(PendingFactory),
            std::env::temp_dir().join("quickmail-idempotent-account-test"),
        );
        let mut topics = HashSet::new();

        let result = tokio::time::timeout(
            Duration::from_millis(100),
            daemon.dispatch_inner(
                method::ACCOUNTS_ADD,
                json!({
                    "provider": "GMAIL",
                    "address": " person@gmail.com ",
                    "displayName": "Updated name"
                }),
                &mut topics,
            ),
        )
        .await
        .expect("duplicate Gmail setup called the provider factory")
        .unwrap();

        assert_eq!(result["accountId"], account.id);
        assert_eq!(result["revision"], revision);
        assert_eq!(result["existing"], true);
        assert_eq!(database.list_accounts().await.unwrap(), vec![account]);
    }

    #[tokio::test]
    async fn subscription_receives_bounded_change_events() {
        let database = Database::open_in_memory().unwrap();
        let daemon = Daemon::new(database);
        let mut topics = HashSet::new();
        daemon
            .dispatch_inner(method::SUBSCRIBE, json!({"topics":["agenda"]}), &mut topics)
            .await
            .unwrap();
        let mut events = daemon.events.subscribe();
        daemon.publish("agenda", "agenda.changed", 42);
        let event = events.recv().await.unwrap();
        assert_eq!(event.topic, "agenda");
        assert_eq!(event.params["revision"], 42);
    }

    #[tokio::test]
    async fn idless_json_rpc_notification_is_dispatched_without_a_response() {
        let directory = tempdir().unwrap();
        let socket = private_socket_path(directory.path(), "notification.sock");
        let daemon = Daemon::new(Database::open_in_memory().unwrap());
        let observer = daemon.clone();
        let (shutdown_sender, shutdown_receiver) = oneshot::channel();
        let server_socket = socket.clone();
        let server = tokio::spawn(async move {
            daemon
                .run_with_shutdown(server_socket, async {
                    let _ = shutdown_receiver.await;
                })
                .await
        });
        wait_for_socket(&socket).await;

        let stream = UnixStream::connect(&socket).await.unwrap();
        let (reader, mut writer) = stream.into_split();
        let mut reader = BufReader::new(reader);
        let frames = format!(
            "{}\n{}\n",
            json!({
                "jsonrpc": "2.0",
                "method": "subscribe",
                "params": {"topics": ["mail"]}
            }),
            json!({"jsonrpc": "2.0", "id": 41, "method": "ping", "params": {}})
        );
        writer.write_all(frames.as_bytes()).await.unwrap();

        let mut line = String::new();
        tokio::time::timeout(Duration::from_secs(1), reader.read_line(&mut line))
            .await
            .expect("notification caused the following request to hang")
            .unwrap();
        let response: RpcResponse = serde_json::from_str(&line).unwrap();
        assert_eq!(response.id, RpcId::Number(41));
        assert_eq!(response.result.unwrap()["pong"], true);

        // A present null id is still a request, not a notification. Keeping
        // this distinction avoids swallowing responses from compatible clients.
        writer
            .write_all(
                format!(
                    "{}\n",
                    json!({"jsonrpc": "2.0", "id": null, "method": "ping", "params": {}})
                )
                .as_bytes(),
            )
            .await
            .unwrap();
        line.clear();
        tokio::time::timeout(Duration::from_secs(1), reader.read_line(&mut line))
            .await
            .expect("request with a null id did not receive a response")
            .unwrap();
        let response: RpcResponse = serde_json::from_str(&line).unwrap();
        assert_eq!(response.id, RpcId::Null);
        assert_eq!(response.result.unwrap()["pong"], true);

        observer.publish("mail", "mail.changed", 9);
        line.clear();
        tokio::time::timeout(Duration::from_secs(1), reader.read_line(&mut line))
            .await
            .expect("idless subscribe notification was not dispatched")
            .unwrap();
        let notification: RpcNotification = serde_json::from_str(&line).unwrap();
        assert_eq!(notification.method, "mail.changed");
        assert_eq!(notification.params["revision"], 9);

        shutdown_sender.send(()).unwrap();
        server.await.unwrap().unwrap();
    }

    #[test]
    fn account_badges_use_inbox_instead_of_summing_overlapping_folders() {
        let mailboxes = vec![
            Mailbox {
                id: "archive".into(),
                account_id: "account".into(),
                name: "All Mail".into(),
                role: Some(MailboxRole::Archive),
                unread: 80,
                total: 50_000,
            },
            Mailbox {
                id: "inbox".into(),
                account_id: "account".into(),
                name: "Inbox".into(),
                role: Some(MailboxRole::Inbox),
                unread: 7,
                total: 320,
            },
        ];

        assert_eq!(account_counts_from_mailboxes(&mailboxes), (7, 320));
    }

    #[tokio::test]
    async fn socket_account_sync_list_and_attachment_flow_uses_provider() {
        let directory = tempdir().unwrap();
        let socket = directory.path().join("runtime/daemon.sock");
        let cache = directory.path().join("attachments");
        let account = Account {
            id: "mock:demo@example.com".into(),
            address: "demo@example.com".into(),
            display_name: "Demo".into(),
            provider: "mock".into(),
            protocol: "MOCK".into(),
            host: "example.com".into(),
            unread: 1,
            total: 1,
            enabled: true,
        };
        let provider = Arc::new(MockProvider {
            account: account.clone(),
            list_calls: AtomicUsize::new(0),
            get_calls: AtomicUsize::new(0),
            endless: false,
            fail_send: false,
        });
        let factory = Arc::new(MockFactory {
            provider: provider.clone(),
            remove_calls: Arc::new(AtomicUsize::new(0)),
            fail_restore_auth: false,
        });
        let daemon =
            Daemon::with_provider_factory(Database::open_in_memory().unwrap(), factory, cache);
        let (shutdown_sender, shutdown_receiver) = oneshot::channel();
        let server_socket = socket.clone();
        let server = tokio::spawn(async move {
            let result = daemon
                .run_with_shutdown(server_socket, async {
                    let _ = shutdown_receiver.await;
                })
                .await;
            if let Err(error) = &result {
                eprintln!("test daemon failed: {error}");
            }
            result
        });
        wait_for_socket(&socket).await;
        let stream = UnixStream::connect(&socket).await.unwrap();
        let (reader, mut writer) = stream.into_split();
        let mut reader = BufReader::new(reader);

        let added = send_request(&mut writer, &mut reader, json!({
            "jsonrpc":"2.0", "id":1, "method":"accounts.add", "params":{
                "provider":"mock", "address":"demo@example.com", "displayName":"Demo",
                "imap":{"host":"imap.example.com","port":993,"security":"tls","username":"demo","password":"secret"},
                "smtp":{"host":"smtp.example.com","port":465,"security":"tls","username":"demo","password":"secret"}
            }
        })).await;
        assert!(added.error.is_none(), "{:?}", added.error);
        assert_eq!(added.result.unwrap()["accountId"], account.id);

        let synced = send_request(
            &mut writer,
            &mut reader,
            json!({"jsonrpc":"2.0","id":2,"method":"sync.start","params":{}}),
        )
        .await;
        assert!(synced.error.is_none(), "{:?}", synced.error);
        let accounts = send_request(
            &mut writer,
            &mut reader,
            json!({"jsonrpc":"2.0","id":3,"method":"accounts.list","params":{}}),
        )
        .await;
        let accounts = accounts.result.unwrap();
        assert_eq!(accounts[0]["unread"], 1);
        assert_eq!(accounts[0]["total"], 1);
        let listed = send_request(
            &mut writer,
            &mut reader,
            json!({
                "jsonrpc":"2.0","id":4,"method":"mail.list",
                "params":{"accountId":"mock:demo@example.com","mailboxId":"mock-inbox","limit":50}
            }),
        )
        .await;
        let result = listed.result.unwrap();
        assert_eq!(result["messages"][0]["subject"], "Provider-backed message");
        assert!(result["messages"][0].get("bodyText").is_none());

        let message_id = "mock:demo@example.com:42";
        let actions = [
            json!({"kind":"mark_read", "messageIds":[message_id], "read":true}),
            json!({"kind":"star", "messageIds":[message_id], "starred":true}),
            json!({"kind":"archive", "messageIds":[message_id]}),
            json!({"kind":"trash", "messageIds":[message_id]}),
            json!({
                "kind":"move", "messageIds":[message_id], "mailboxId":"mock-inbox"
            }),
        ];
        for (offset, action) in actions.into_iter().enumerate() {
            let response = send_request(
                &mut writer,
                &mut reader,
                json!({
                    "jsonrpc":"2.0", "id":5 + offset, "method":"mail.action",
                    "params":action
                }),
            )
            .await;
            assert!(response.error.is_none(), "{:?}", response.error);
        }

        for id in [10, 11] {
            let fetched = send_request(
                &mut writer,
                &mut reader,
                json!({
                    "jsonrpc":"2.0", "id":id, "method":"mail.get",
                    "params":{"messageId":message_id}
                }),
            )
            .await;
            assert!(fetched.error.is_none(), "{:?}", fetched.error);
            assert!(fetched.result.unwrap()["bodyText"].is_null());
        }
        assert_eq!(provider.get_calls.load(Ordering::SeqCst), 1);

        let downloaded = send_request(
            &mut writer,
            &mut reader,
            json!({
                "jsonrpc":"2.0","id":12,"method":"attachment.download",
                "params":{"messageId":message_id,"attachmentId":"part-1","disposition":"download"}
            }),
        )
        .await;
        let result = downloaded.result.unwrap();
        let path = PathBuf::from(result["path"].as_str().unwrap());
        assert_eq!(std::fs::read(path).unwrap(), b"attachment bytes");
        assert_eq!(result["filename"], "unsafe report.txt");

        drop(writer);
        shutdown_sender.send(()).unwrap();
        server.await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn mailbox_sync_persists_cursor_and_reconciles_cached_flags() {
        let account = Account {
            id: "cursor-account".into(),
            address: "cursor@example.com".into(),
            display_name: "Cursor".into(),
            provider: "cursor-sync".into(),
            protocol: "IMAP".into(),
            host: "example.com".into(),
            unread: 0,
            total: 1,
            enabled: true,
        };
        let mailbox = Mailbox {
            id: "inbox".into(),
            account_id: account.id.clone(),
            name: "Inbox".into(),
            role: Some(MailboxRole::Inbox),
            unread: 0,
            total: 1,
        };
        let provider = CursorSyncProvider {
            account: account.clone(),
            calls: AtomicUsize::new(0),
            queries: StdMutex::new(Vec::new()),
        };
        let database = Database::open_in_memory().unwrap();
        database.upsert_account(&account).await.unwrap();
        database
            .upsert_mailboxes(std::slice::from_ref(&mailbox))
            .await
            .unwrap();
        let daemon = Daemon::new(database.clone());

        daemon.sync_mailbox_page(&provider, &mailbox).await.unwrap();
        daemon.sync_mailbox_page(&provider, &mailbox).await.unwrap();

        let queries = provider.queries.lock().unwrap().clone();
        assert_eq!(queries.len(), 2);
        assert_eq!(queries[0].cursor, None);
        assert!(queries[0].reconcile_message_ids.is_empty());
        assert_eq!(queries[1].cursor.as_deref(), Some("777:42"));
        assert_eq!(
            queries[1].reconcile_message_ids,
            vec![quickmail_core::normalized_message_id(
                &account.id,
                "cursor-message"
            )]
        );
        assert_eq!(
            database
                .mailbox_sync_cursor(&account.id, &mailbox.id)
                .await
                .unwrap()
                .as_deref(),
            Some("777:43")
        );
        let message = database
            .get_message(&quickmail_core::normalized_message_id(
                &account.id,
                "cursor-message",
            ))
            .await
            .unwrap()
            .unwrap();
        assert!(message.summary.read && message.summary.starred);
    }

    #[tokio::test]
    async fn foreground_sync_is_bounded_even_when_provider_never_ends() {
        let account = Account {
            id: "endless-account".into(),
            address: "endless@example.com".into(),
            display_name: "Endless".into(),
            provider: "mock".into(),
            protocol: "MOCK".into(),
            host: "example.com".into(),
            unread: 1,
            total: 100_000,
            enabled: true,
        };
        let provider = Arc::new(MockProvider {
            account: account.clone(),
            list_calls: AtomicUsize::new(0),
            get_calls: AtomicUsize::new(0),
            endless: true,
            fail_send: false,
        });
        let database = Database::open_in_memory().unwrap();
        database.upsert_account(&account).await.unwrap();
        let daemon = Daemon::new(database);
        daemon
            .providers
            .write()
            .await
            .insert(account.id.clone(), provider.clone());

        daemon.sync_selected_accounts(None).await.unwrap();

        assert_eq!(provider.list_calls.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn sync_start_scopes_work_to_the_requested_account() {
        let account = |id: &str| Account {
            id: id.into(),
            address: format!("{id}@example.com"),
            display_name: id.into(),
            provider: "mock".into(),
            protocol: "MOCK".into(),
            host: "example.com".into(),
            unread: 0,
            total: 0,
            enabled: true,
        };
        let first = Arc::new(MockProvider {
            account: account("first"),
            list_calls: AtomicUsize::new(0),
            get_calls: AtomicUsize::new(0),
            endless: false,
            fail_send: false,
        });
        let second = Arc::new(MockProvider {
            account: account("second"),
            list_calls: AtomicUsize::new(0),
            get_calls: AtomicUsize::new(0),
            endless: false,
            fail_send: false,
        });
        let database = Database::open_in_memory().unwrap();
        database.upsert_account(first.account()).await.unwrap();
        database.upsert_account(second.account()).await.unwrap();
        let daemon = Daemon::new(database);
        daemon.providers.write().await.extend([
            (
                first.account.id.clone(),
                first.clone() as Arc<dyn MailProvider>,
            ),
            (
                second.account.id.clone(),
                second.clone() as Arc<dyn MailProvider>,
            ),
        ]);

        daemon
            .dispatch_inner(
                method::SYNC_START,
                json!({"accountId": first.account.id}),
                &mut HashSet::new(),
            )
            .await
            .unwrap();
        assert_eq!(first.list_calls.load(Ordering::SeqCst), 1);
        assert_eq!(second.list_calls.load(Ordering::SeqCst), 0);
    }

    #[tokio::test]
    async fn draft_lifecycle_and_send_cleanup_preserve_failed_drafts() {
        let account = Account {
            id: "draft-account".into(),
            address: "draft@example.com".into(),
            display_name: "Draft".into(),
            provider: "mock".into(),
            protocol: "MOCK".into(),
            host: "example.com".into(),
            unread: 0,
            total: 0,
            enabled: true,
        };
        let message = OutgoingMessage {
            draft_id: Some("draft-success".into()),
            account_id: account.id.clone(),
            to: vec![Address {
                name: String::new(),
                address: "recipient@example.com".into(),
            }],
            cc: vec![],
            bcc: vec![],
            subject: "Draft subject".into(),
            body_text: Some("Body".into()),
            body_html: None,
            in_reply_to: None,
        };
        let database = Database::open_in_memory().unwrap();
        database.upsert_account(&account).await.unwrap();
        database
            .save_draft(Some("draft-success"), &message)
            .await
            .unwrap();
        database
            .save_draft(Some("draft-failure"), &message)
            .await
            .unwrap();
        assert_eq!(
            database.list_drafts(Some(&account.id)).await.unwrap().len(),
            2
        );
        assert_eq!(
            database
                .get_draft("draft-success")
                .await
                .unwrap()
                .message
                .subject,
            "Draft subject"
        );

        let daemon = Daemon::new(database.clone());
        let listed = daemon
            .dispatch_inner(
                method::DRAFT_LIST,
                json!({"accountId": account.id}),
                &mut HashSet::new(),
            )
            .await
            .unwrap();
        assert_eq!(listed.as_array().unwrap().len(), 2);
        let fetched = daemon
            .dispatch_inner(
                method::DRAFT_GET,
                json!({"draftId":"draft-success"}),
                &mut HashSet::new(),
            )
            .await
            .unwrap();
        assert_eq!(fetched["message"]["subject"], "Draft subject");
        let successful = Arc::new(MockProvider {
            account: account.clone(),
            list_calls: AtomicUsize::new(0),
            get_calls: AtomicUsize::new(0),
            endless: false,
            fail_send: false,
        });
        daemon
            .providers
            .write()
            .await
            .insert(account.id.clone(), successful);
        let sent = daemon
            .dispatch_inner(
                method::MAIL_SEND,
                serde_json::to_value(&message).unwrap(),
                &mut HashSet::new(),
            )
            .await
            .unwrap();
        assert_eq!(sent["draftCleanup"], "deleted");
        assert!(matches!(
            database.get_draft("draft-success").await,
            Err(StorageError::NotFound)
        ));

        let mut missing_draft = message.clone();
        missing_draft.draft_id = Some("already-removed".into());
        let sent = daemon
            .dispatch_inner(
                method::MAIL_SEND,
                serde_json::to_value(missing_draft).unwrap(),
                &mut HashSet::new(),
            )
            .await
            .expect("post-send missing draft must not turn delivery into an error");
        assert_eq!(sent["draftCleanup"], "notFound");

        let failed = Arc::new(MockProvider {
            account: account.clone(),
            list_calls: AtomicUsize::new(0),
            get_calls: AtomicUsize::new(0),
            endless: false,
            fail_send: true,
        });
        daemon
            .providers
            .write()
            .await
            .insert(account.id.clone(), failed);
        let mut failed_message = message;
        failed_message.draft_id = Some("draft-failure".into());
        assert!(
            daemon
                .dispatch_inner(
                    method::MAIL_SEND,
                    serde_json::to_value(failed_message).unwrap(),
                    &mut HashSet::new(),
                )
                .await
                .is_err()
        );
        assert!(database.get_draft("draft-failure").await.is_ok());

        daemon
            .dispatch_inner(
                method::DRAFT_DELETE,
                json!({"draftId":"draft-failure"}),
                &mut HashSet::new(),
            )
            .await
            .unwrap();
        assert!(database.list_drafts(None).await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn foreground_returns_after_inbox_and_background_is_sequential_and_deduplicated() {
        let account = Account {
            id: "ordered-account".into(),
            address: "ordered@example.com".into(),
            display_name: "Ordered".into(),
            provider: "ordered".into(),
            protocol: "ORDERED".into(),
            host: "example.com".into(),
            unread: 0,
            total: 0,
            enabled: true,
        };
        let calls = Arc::new(StdMutex::new(Vec::new()));
        let gate = Arc::new(Semaphore::new(0));
        let active = Arc::new(AtomicUsize::new(0));
        let max_active = Arc::new(AtomicUsize::new(0));
        let provider = Arc::new(OrderedProvider {
            account: account.clone(),
            calls: calls.clone(),
            background_gate: gate.clone(),
            active: active.clone(),
            max_active: max_active.clone(),
        });
        let database = Database::open_in_memory().unwrap();
        database.upsert_account(&account).await.unwrap();
        let daemon = Daemon::new(database.clone());
        daemon
            .providers
            .write()
            .await
            .insert(account.id.clone(), provider);
        let mut events = daemon.events.subscribe();

        let started = tokio::time::timeout(
            Duration::from_millis(100),
            daemon.dispatch_inner(method::SYNC_START, json!({}), &mut HashSet::new()),
        )
        .await
        .expect("foreground waited for non-Inbox folders")
        .unwrap();
        assert_eq!(started["completed"], false);
        assert_eq!(started["backgroundStarted"], true);
        let initial_mail = events.recv().await.unwrap();
        let initial_sync = events.recv().await.unwrap();
        assert_eq!(
            (initial_mail.topic.as_str(), initial_sync.topic.as_str()),
            ("mail", "sync")
        );
        assert_eq!(initial_sync.params["status"], "running");
        assert_eq!(initial_sync.params["running"], true);
        assert_eq!(initial_sync.params["backgroundRemaining"], 1);
        tokio::time::timeout(Duration::from_millis(100), async {
            while calls.lock().unwrap().len() < 3 {
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("background sync did not start");
        assert_eq!(
            calls.lock().unwrap().as_slice(),
            ["mailboxes", "inbox", "archive"]
        );
        assert!(daemon.background_syncing.lock().await.contains(&account.id));

        let (_, already_running) = daemon.sync_selected_accounts(None).await.unwrap();
        assert!(already_running);
        assert_eq!(
            calls
                .lock()
                .unwrap()
                .iter()
                .filter(|call| call.as_str() == "inbox")
                .count(),
            1
        );

        gate.add_permits(2);
        tokio::time::timeout(Duration::from_secs(1), async {
            while daemon.background_syncing.lock().await.contains(&account.id) {
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("background sync did not finish");

        assert_eq!(
            calls.lock().unwrap().as_slice(),
            ["mailboxes", "inbox", "archive", "sent"]
        );
        assert_eq!(max_active.load(Ordering::SeqCst), 1);
        let updated = database.list_accounts().await.unwrap().remove(0);
        assert_eq!((updated.unread, updated.total), (4, 20));
        let first = events.recv().await.unwrap();
        let second = events.recv().await.unwrap();
        assert_eq!(
            (first.topic.as_str(), second.topic.as_str()),
            ("mail", "sync")
        );
        assert_eq!(second.method, "sync.changed");
        assert_eq!(second.params["status"], "idle");
        assert_eq!(second.params["running"], false);
        assert_eq!(second.params["backgroundRemaining"], 0);
        assert_eq!(second.params["accountId"], account.id);
    }

    #[tokio::test]
    async fn sync_state_event_keeps_running_until_the_aggregate_is_empty() {
        let daemon = Daemon::new(Database::open_in_memory().unwrap());
        let mut events = daemon.events.subscribe();
        daemon
            .background_syncing
            .lock()
            .await
            .extend(["first".to_owned(), "second".to_owned()]);

        daemon.background_syncing.lock().await.remove("first");
        daemon.publish_sync_state(Some("first"), 7, None).await;
        let first = events.recv().await.unwrap();
        assert_eq!(first.params["status"], "running");
        assert_eq!(first.params["running"], true);
        assert_eq!(first.params["backgroundRemaining"], 1);
        assert_eq!(first.params["accountId"], "first");

        daemon.background_syncing.lock().await.remove("second");
        daemon.publish_sync_state(Some("second"), 8, None).await;
        let second = events.recv().await.unwrap();
        assert_eq!(second.params["status"], "idle");
        assert_eq!(second.params["running"], false);
        assert_eq!(second.params["backgroundRemaining"], 0);

        daemon
            .background_syncing
            .lock()
            .await
            .insert("failed".to_owned());
        daemon
            .publish_sync_state(Some("failed"), 9, Some("provider failed"))
            .await;
        let failed = events.recv().await.unwrap();
        assert_eq!(failed.params["status"], "error");
        assert_eq!(failed.params["running"], true);
        assert_eq!(failed.params["backgroundRemaining"], 1);
        assert_eq!(failed.params["error"], "provider failed");
    }

    #[tokio::test]
    async fn removing_account_cancels_background_results_before_storage() {
        let directory = tempdir().unwrap();
        let account = Account {
            id: "remove-during-sync".into(),
            address: "remove-sync@example.com".into(),
            display_name: "Remove Sync".into(),
            provider: "ordered".into(),
            protocol: "ORDERED".into(),
            host: "example.com".into(),
            unread: 0,
            total: 0,
            enabled: true,
        };
        let gate = Arc::new(Semaphore::new(0));
        let active = Arc::new(AtomicUsize::new(0));
        let provider = Arc::new(OrderedProvider {
            account: account.clone(),
            calls: Arc::new(StdMutex::new(Vec::new())),
            background_gate: gate.clone(),
            active: active.clone(),
            max_active: Arc::new(AtomicUsize::new(0)),
        });
        let database = Database::open_in_memory().unwrap();
        database
            .upsert_account_config(&account, json!({"provider":"ordered"}))
            .await
            .unwrap();
        let daemon = Daemon::with_provider_factory(
            database.clone(),
            Arc::new(MockFactory {
                provider: provider.clone(),
                remove_calls: Arc::new(AtomicUsize::new(0)),
                fail_restore_auth: false,
            }),
            directory.path().join("attachments"),
        );
        daemon
            .providers
            .write()
            .await
            .insert(account.id.clone(), provider);
        assert!(
            daemon
                .sync_selected_accounts(Some(&account.id))
                .await
                .unwrap()
                .1
        );
        tokio::time::timeout(Duration::from_millis(100), async {
            while active.load(Ordering::SeqCst) == 0 {
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("background sync did not start");

        daemon
            .dispatch_inner(
                method::ACCOUNTS_REMOVE,
                json!({"accountId": account.id}),
                &mut HashSet::new(),
            )
            .await
            .unwrap();
        gate.add_permits(2);
        tokio::time::timeout(Duration::from_secs(1), async {
            while daemon
                .background_syncing
                .lock()
                .await
                .contains("remove-during-sync")
            {
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("removed account background sync did not stop");
        assert!(database.list_accounts().await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn account_remove_evicts_provider_and_invokes_factory_cleanup() {
        let directory = tempdir().unwrap();
        let cache = directory.path().join("attachments");
        ensure_private_directory(&cache).unwrap();
        let cached_attachment = cache.join(Uuid::new_v4().to_string());
        let unrelated_cache_file = cache.join("keep.txt");
        std::fs::write(&cached_attachment, b"private cached attachment").unwrap();
        std::fs::write(&unrelated_cache_file, b"not a QuickMail cache object").unwrap();
        let saved_download = directory.path().join("saved-download.txt");
        std::fs::write(&saved_download, b"user-saved copy").unwrap();
        let account = Account {
            id: "remove-account".into(),
            address: "remove@example.com".into(),
            display_name: "Remove".into(),
            provider: "mock".into(),
            protocol: "MOCK".into(),
            host: "example.com".into(),
            unread: 0,
            total: 0,
            enabled: true,
        };
        let provider = Arc::new(MockProvider {
            account: account.clone(),
            list_calls: AtomicUsize::new(0),
            get_calls: AtomicUsize::new(0),
            endless: false,
            fail_send: false,
        });
        let remove_calls = Arc::new(AtomicUsize::new(0));
        let factory = Arc::new(MockFactory {
            provider: provider.clone(),
            remove_calls: remove_calls.clone(),
            fail_restore_auth: false,
        });
        let database = Database::open_in_memory().unwrap();
        database.upsert_account(&account).await.unwrap();
        let daemon = Daemon::with_provider_factory(database.clone(), factory, cache);
        daemon
            .providers
            .write()
            .await
            .insert(account.id.clone(), provider);

        daemon
            .dispatch_inner(
                method::ACCOUNTS_REMOVE,
                json!({"accountId": account.id}),
                &mut HashSet::new(),
            )
            .await
            .unwrap();

        assert!(daemon.providers.read().await.is_empty());
        assert_eq!(remove_calls.load(Ordering::SeqCst), 1);
        assert!(database.list_accounts().await.unwrap().is_empty());
        assert!(!cached_attachment.exists());
        assert_eq!(
            std::fs::read(unrelated_cache_file).unwrap(),
            b"not a QuickMail cache object"
        );
        assert_eq!(std::fs::read(saved_download).unwrap(), b"user-saved copy");
    }

    #[tokio::test]
    async fn attachment_finishing_after_account_removal_cannot_repopulate_cache() {
        let directory = tempdir().unwrap();
        let cache = directory.path().join("attachments");
        let account = Account {
            id: "late-attachment-account".into(),
            address: "late-attachment@example.com".into(),
            display_name: "Late attachment".into(),
            provider: "blocking-attachment".into(),
            protocol: "TEST".into(),
            host: "example.com".into(),
            unread: 0,
            total: 0,
            enabled: true,
        };
        let started = Arc::new(Semaphore::new(0));
        let release = Arc::new(Semaphore::new(0));
        let provider = Arc::new(BlockingAttachmentProvider {
            account: account.clone(),
            started: started.clone(),
            release: release.clone(),
        });
        let database = Database::open_in_memory().unwrap();
        database.upsert_account(&account).await.unwrap();
        let daemon = Daemon::with_provider_factory(
            database.clone(),
            Arc::new(MockFactory {
                provider: provider.clone(),
                remove_calls: Arc::new(AtomicUsize::new(0)),
                fail_restore_auth: false,
            }),
            cache.clone(),
        );
        daemon
            .providers
            .write()
            .await
            .insert(account.id.clone(), provider);

        let download_daemon = daemon.clone();
        let message_id = quickmail_core::normalized_message_id(&account.id, "message-1");
        let download = tokio::spawn(async move {
            download_daemon
                .dispatch_inner(
                    method::ATTACHMENT_DOWNLOAD,
                    json!({"messageId": message_id, "attachmentId": "part-1"}),
                    &mut HashSet::new(),
                )
                .await
        });
        tokio::time::timeout(Duration::from_secs(1), started.acquire())
            .await
            .expect("attachment fetch did not start")
            .unwrap()
            .forget();

        daemon
            .dispatch_inner(
                method::ACCOUNTS_REMOVE,
                json!({"accountId": account.id}),
                &mut HashSet::new(),
            )
            .await
            .unwrap();
        release.add_permits(1);

        let error = tokio::time::timeout(Duration::from_secs(1), download)
            .await
            .expect("attachment download did not finish")
            .unwrap()
            .unwrap_err();
        assert_eq!(error.code, -32004);
        assert!(database.list_accounts().await.unwrap().is_empty());
        assert!(!cache.exists());
    }

    #[tokio::test]
    async fn restore_auth_failure_is_persisted_and_does_not_abort_startup() {
        let account = Account {
            id: "expired-account".into(),
            address: "expired@example.com".into(),
            display_name: "Expired".into(),
            provider: "mock".into(),
            protocol: "MOCK".into(),
            host: "example.com".into(),
            unread: 0,
            total: 0,
            enabled: true,
        };
        let provider = Arc::new(MockProvider {
            account: account.clone(),
            list_calls: AtomicUsize::new(0),
            get_calls: AtomicUsize::new(0),
            endless: false,
            fail_send: false,
        });
        let database = Database::open_in_memory().unwrap();
        database
            .upsert_account_config(&account, json!({"provider":"mock"}))
            .await
            .unwrap();
        let daemon = Daemon::with_provider_factory(
            database.clone(),
            Arc::new(MockFactory {
                provider,
                remove_calls: Arc::new(AtomicUsize::new(0)),
                fail_restore_auth: true,
            }),
            std::env::temp_dir().join("quickmail-test-attachments"),
        );

        assert_eq!(daemon.restore_providers().await.unwrap(), 0);
        assert!(daemon.providers.read().await.is_empty());
        assert_eq!(
            database.account_auth_state(&account.id).await.unwrap(),
            Some((
                "needs_auth".into(),
                Some("authentication required: authorization expired".into())
            ))
        );
        assert_eq!(database.list_accounts().await.unwrap(), vec![account]);
    }

    #[test]
    fn private_directory_creation_never_chmods_an_existing_ancestor() {
        let directory = tempdir().unwrap();
        std::fs::set_permissions(directory.path(), std::fs::Permissions::from_mode(0o755)).unwrap();
        let leaf = directory.path().join("quickmail").join("attachments");
        ensure_private_directory(&leaf).unwrap();
        assert_eq!(
            std::fs::metadata(directory.path())
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o755
        );
        assert_eq!(
            std::fs::metadata(leaf).unwrap().permissions().mode() & 0o777,
            0o700
        );
    }

    #[tokio::test]
    async fn attachment_cache_rejects_oversized_bytes_before_creating_files() {
        let directory = tempdir().unwrap();
        let cache = directory.path().join("attachments");
        let error = cache_attachment_with_limit(
            &cache,
            AttachmentData {
                filename: "large.bin".into(),
                content_type: "application/octet-stream".into(),
                bytes: vec![0; 4],
            },
            3,
        )
        .await
        .unwrap_err();

        assert_eq!(error.code, -32013);
        assert_eq!(
            error.message,
            "attachment exceeds the configured size limit"
        );
        assert!(!cache.exists());
    }
}
