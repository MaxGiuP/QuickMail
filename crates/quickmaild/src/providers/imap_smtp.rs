use std::{collections::BTreeSet, fmt, sync::Arc, time::Duration};

use async_imap::{
    Authenticator, Session,
    types::{Capability, Flag, NameAttribute},
};
use async_trait::async_trait;
use base64::Engine;
use chrono::{DateTime, Utc};
use futures_util::{TryStreamExt, future::BoxFuture};
use lettre::{
    AsyncSmtpTransport, AsyncTransport, Tokio1Executor,
    address::Envelope as LettreEnvelope,
    transport::smtp::{
        authentication::Credentials,
        client::{Tls, TlsParameters},
    },
};
use quickmail_core::{
    Account, Address, Attachment, AttachmentData, MailAction, MailProvider, Mailbox, MailboxRole,
    MailboxSyncPage, MailboxSyncQuery, Message, MessagePage, MessageQuery, MessageSummary,
    OutgoingMessage, ProviderCapabilities, ProviderError, normalized_message_id,
};
use serde_json::json;
use thiserror::Error;
use tokio::{
    io::{AsyncBufReadExt, AsyncRead, AsyncWrite, AsyncWriteExt, BufStream},
    net::TcpStream,
    sync::Mutex,
};
use tokio_rustls::{TlsConnector, client::TlsStream};
use uuid::Uuid;

use super::{
    MAX_MAIL_MESSAGE_BYTES,
    auth::{SecretString, TokenSource},
    mime::{MimeCodec, MimeError, ProductionMimeCodec, reply_reference_chain},
};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ConnectionSecurity {
    ImplicitTls,
    StartTls,
}

#[derive(Clone)]
pub(crate) enum ImapAuthentication {
    Password {
        username: String,
        password: SecretString,
    },
    OAuthBearer {
        username: String,
        access_token: SecretString,
    },
    OAuthSource {
        username: String,
        tokens: Arc<dyn TokenSource>,
    },
}

impl fmt::Debug for ImapAuthentication {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Password { username, .. } => formatter
                .debug_struct("Password")
                .field("username", username)
                .field("password", &"[REDACTED]")
                .finish(),
            Self::OAuthBearer { username, .. } => formatter
                .debug_struct("OAuthBearer")
                .field("username", username)
                .field("access_token", &"[REDACTED]")
                .finish(),
            Self::OAuthSource { username, .. } => formatter
                .debug_struct("OAuthSource")
                .field("username", username)
                .field("tokens", &"[REDACTED]")
                .finish(),
        }
    }
}

#[derive(Clone, Debug)]
pub(crate) struct ImapSmtpConfig {
    pub(crate) imap_host: String,
    pub(crate) imap_port: u16,
    pub(crate) imap_security: ConnectionSecurity,
    pub(crate) smtp_host: String,
    pub(crate) smtp_port: u16,
    pub(crate) smtp_security: ConnectionSecurity,
    pub(crate) imap_authentication: ImapAuthentication,
    pub(crate) smtp_authentication: ImapAuthentication,
    pub(crate) discover_special_use: bool,
    pub(crate) archive_mailbox: Option<String>,
    pub(crate) trash_mailbox: Option<String>,
}

impl ImapSmtpConfig {
    pub(crate) fn validate(&self) -> Result<(), ImapError> {
        if self.imap_host.trim().is_empty() || self.smtp_host.trim().is_empty() {
            return Err(ImapError::InvalidConfiguration("server host is empty"));
        }
        if self.imap_port == 0 || self.smtp_port == 0 {
            return Err(ImapError::InvalidConfiguration("server port is zero"));
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct ImapCapabilities(BTreeSet<String>);

impl ImapCapabilities {
    pub(crate) fn parse(responses: &[String]) -> Self {
        let mut capabilities = BTreeSet::new();
        for response in responses {
            let words = response.split_ascii_whitespace().collect::<Vec<_>>();
            if let Some(index) = words.iter().position(|word| {
                word.trim_start_matches('[')
                    .eq_ignore_ascii_case("CAPABILITY")
            }) {
                for capability in words.iter().skip(index + 1) {
                    capabilities.insert(capability.trim_end_matches(']').to_ascii_uppercase());
                }
            }
        }
        Self(capabilities)
    }

    pub(crate) fn contains(&self, capability: &str) -> bool {
        self.0.contains(&capability.to_ascii_uppercase())
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct SelectedMailbox {
    pub(crate) uid_validity: u64,
    pub(crate) uid_next: u64,
    pub(crate) highest_mod_sequence: Option<u64>,
}

impl SelectedMailbox {
    pub(crate) fn from_responses(responses: &[String]) -> Result<Self, ImapError> {
        let uid_validity =
            response_code_number(responses, "UIDVALIDITY").ok_or(ImapError::MissingUidValidity)?;
        let uid_next = response_code_number(responses, "UIDNEXT").unwrap_or(1);
        let highest_mod_sequence = response_code_number(responses, "HIGHESTMODSEQ");
        Ok(Self {
            uid_validity,
            uid_next,
            highest_mod_sequence,
        })
    }
}

fn response_code_number(responses: &[String], code: &str) -> Option<u64> {
    responses.iter().find_map(|response| {
        let start = response.to_ascii_uppercase().find(&format!("[{code} "))?;
        let suffix = &response[start + code.len() + 2..];
        suffix
            .split(|character: char| !character.is_ascii_digit())
            .next()?
            .parse()
            .ok()
    })
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct ImapMailboxInfo {
    pub(crate) name: String,
    pub(crate) role: Option<MailboxRole>,
    pub(crate) unread: u64,
    pub(crate) total: u64,
}

#[derive(Clone, Debug)]
pub(crate) struct ImapEnvelope {
    pub(crate) uid: u64,
    pub(crate) subject: String,
    pub(crate) from: Option<Address>,
    pub(crate) timestamp: DateTime<Utc>,
    pub(crate) flags: BTreeSet<String>,
    pub(crate) snippet: String,
    pub(crate) has_attachments: bool,
    pub(crate) message_id: Option<String>,
    pub(crate) in_reply_to: Vec<String>,
    pub(crate) references: Vec<String>,
}

#[derive(Clone, Debug)]
pub(crate) struct ImapFetchedMessage {
    pub(crate) uid: u64,
    pub(crate) uid_validity: u64,
    pub(crate) flags: BTreeSet<String>,
    pub(crate) raw: Vec<u8>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct IncrementalUidPage {
    pub(crate) uids: Vec<u64>,
    /// Every UID up to this value was covered by the SEARCH, including gaps.
    pub(crate) high_uid: u64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum ImapIdleEvent {
    Exists(u64),
    Expunge(u64),
    FlagsChanged(u64),
    ReconnectRequired,
}

/// Semantic transport implemented by the production async IMAP connection.
/// Fetches are UID-based; sequence numbers never leave the transport.
#[async_trait]
pub(crate) trait ImapTransport: Send + Sync {
    async fn capabilities(&self) -> Result<ImapCapabilities, ImapError>;
    async fn list_mailboxes(&self) -> Result<Vec<ImapMailboxInfo>, ImapError>;
    async fn select(&self, mailbox: &str) -> Result<SelectedMailbox, ImapError>;
    async fn search_uids(
        &self,
        mailbox: &str,
        before_uid: u64,
        search: Option<&str>,
        unread_only: bool,
        limit: u32,
    ) -> Result<Vec<u64>, ImapError>;
    async fn search_recent_uids(
        &self,
        mailbox: &str,
        through_uid: u64,
        limit: u32,
    ) -> Result<Vec<u64>, ImapError>;
    async fn search_uids_since(
        &self,
        mailbox: &str,
        after_uid: u64,
        through_uid: u64,
        limit: u32,
    ) -> Result<IncrementalUidPage, ImapError>;
    async fn fetch_envelopes(
        &self,
        mailbox: &str,
        uids: &[u64],
    ) -> Result<Vec<ImapEnvelope>, ImapError>;
    /// Full bodies are fetched only when the user opens or downloads from a
    /// message. The UIDVALIDITY check and body read are one atomic operation,
    /// so a mailbox reset cannot return a different message for a stale UID.
    async fn fetch_message(
        &self,
        mailbox: &str,
        uid: u64,
        expected_uid_validity: u64,
    ) -> Result<ImapFetchedMessage, ImapError>;
    async fn store_flags(
        &self,
        mailbox: &str,
        uids: &[u64],
        add: &[String],
        remove: &[String],
    ) -> Result<(), ImapError>;
    async fn move_uids(
        &self,
        mailbox: &str,
        uids: &[u64],
        destination: &str,
    ) -> Result<(), ImapError>;
    /// A production implementation keeps one long-lived IDLE connection and
    /// reconnects on server timeout; it must not spawn a subprocess per poll.
    async fn idle(
        &self,
        mailbox: &str,
        known_uid_next: u64,
    ) -> Result<Vec<ImapIdleEvent>, ImapError>;
}

type ImapSession = Session<TlsStream<TcpStream>>;
const IMAP_COMMAND_TIMEOUT: Duration = Duration::from_secs(10);
const IMAP_STATUS_BUDGET: Duration = Duration::from_secs(3);
const IMAP_INCREMENTAL_UID_SEARCH_SPAN: u64 = 4_096;
const IMAP_BOOTSTRAP_MAX_SEARCH_WINDOWS: usize = 16;
const IMAP_SUMMARY_FETCH: &str = "(UID FLAGS RFC822.SIZE BODY.PEEK[HEADER.FIELDS (SUBJECT FROM DATE MESSAGE-ID IN-REPLY-TO REFERENCES CONTENT-TYPE CONTENT-DISPOSITION)])";

fn bounded_raw_fetch_query(limit: usize) -> String {
    // Request one byte beyond the accepted limit so a missing or dishonest
    // RFC822.SIZE response still cannot make a truncated message look valid.
    format!(
        "(UID FLAGS RFC822.SIZE BODY.PEEK[]<0.{}>)",
        limit.saturating_add(1)
    )
}

fn validate_raw_message_size(size: usize, limit: usize) -> Result<(), ImapError> {
    if size > limit {
        Err(ImapError::MessageTooLarge)
    } else {
        Ok(())
    }
}

async fn bounded_imap<T>(
    duration: Duration,
    operation: impl std::future::Future<Output = Result<T, ImapError>>,
) -> Result<T, ImapError> {
    tokio::time::timeout(duration, operation)
        .await
        .map_err(|_| ImapError::CommandTimeout)?
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum SessionErrorAction {
    Return,
    InvalidateAndReturn,
    InvalidateAndRetry,
}

fn session_error_action(
    error: &ImapError,
    retry_safe: bool,
    already_retried: bool,
) -> SessionErrorAction {
    if !matches!(error, ImapError::Connection(_) | ImapError::CommandTimeout) {
        return SessionErrorAction::Return;
    }
    if retry_safe && !already_retried {
        SessionErrorAction::InvalidateAndRetry
    } else {
        SessionErrorAction::InvalidateAndReturn
    }
}

/// A long-lived, TLS-only IMAP transport. All commands share one authenticated
/// session, which avoids reconnecting (or spawning a process) per request.
pub(crate) struct AsyncImapTransport {
    config: ImapSmtpConfig,
    tls: TlsConnector,
    session: Mutex<Option<ImapSession>>,
    detail_session: Mutex<Option<ImapSession>>,
    idle_session: Mutex<Option<ImapSession>>,
}

impl AsyncImapTransport {
    pub(crate) fn new(config: ImapSmtpConfig) -> Result<Self, ImapError> {
        config.validate()?;
        let mut roots = rustls::RootCertStore::empty();
        let native = rustls_native_certs::load_native_certs();
        for certificate in native.certs {
            roots.add(certificate).map_err(|_| {
                ImapError::InvalidConfiguration("platform certificate store is invalid")
            })?;
        }
        if roots.is_empty() {
            return Err(ImapError::InvalidConfiguration(
                "platform certificate store is empty",
            ));
        }
        let client_config = rustls::ClientConfig::builder()
            .with_root_certificates(roots)
            .with_no_client_auth();
        Ok(Self {
            config,
            tls: TlsConnector::from(Arc::new(client_config)),
            session: Mutex::new(None),
            detail_session: Mutex::new(None),
            idle_session: Mutex::new(None),
        })
    }

    async fn connect(&self) -> Result<ImapSession, ImapError> {
        let address = (self.config.imap_host.as_str(), self.config.imap_port);
        let tcp = TcpStream::connect(address)
            .await
            .map_err(|error| ImapError::Connection(error.to_string()))?;
        let server_name = rustls::pki_types::ServerName::try_from(self.config.imap_host.clone())
            .map_err(|_| ImapError::InvalidConfiguration("invalid IMAP TLS server name"))?;

        let tls = match self.config.imap_security {
            ConnectionSecurity::ImplicitTls => self
                .tls
                .connect(server_name, tcp)
                .await
                .map_err(|error| ImapError::Connection(error.to_string()))?,
            ConnectionSecurity::StartTls => {
                let mut client = async_imap::Client::new(tcp);
                client
                    .read_response()
                    .await
                    .map_err(|error| ImapError::Connection(error.to_string()))?
                    .ok_or_else(|| {
                        ImapError::Connection("IMAP server closed before greeting".into())
                    })?;
                client
                    .run_command_and_check_ok("STARTTLS", None)
                    .await
                    .map_err(imap_protocol_error)?;
                self.tls
                    .connect(server_name, client.into_inner())
                    .await
                    .map_err(|error| ImapError::Connection(error.to_string()))?
            }
        };

        let mut client = async_imap::Client::new(tls);
        if matches!(self.config.imap_security, ConnectionSecurity::ImplicitTls) {
            client
                .read_response()
                .await
                .map_err(|error| ImapError::Connection(error.to_string()))?
                .ok_or_else(|| {
                    ImapError::Connection("IMAP server closed before greeting".into())
                })?;
        }
        match &self.config.imap_authentication {
            ImapAuthentication::Password { username, password } => client
                .login(username, password.expose_secret())
                .await
                .map_err(|(error, _client)| imap_authentication_error(error)),
            ImapAuthentication::OAuthBearer {
                username,
                access_token,
            } => {
                let mut authenticator = Xoauth2 {
                    username,
                    access_token: access_token.expose_secret(),
                };
                client
                    .authenticate("XOAUTH2", &mut authenticator)
                    .await
                    .map_err(|(error, _client)| imap_authentication_error(error))
            }
            ImapAuthentication::OAuthSource { username, tokens } => {
                let token = tokens
                    .access_token(false)
                    .await
                    .map_err(|_| ImapError::Authentication)?;
                let mut authenticator = Xoauth2 {
                    username,
                    access_token: token.value.expose_secret(),
                };
                client
                    .authenticate("XOAUTH2", &mut authenticator)
                    .await
                    .map_err(|(error, _client)| imap_authentication_error(error))
            }
        }
    }

    async fn lock_session<'a>(
        &self,
        lane: &'a Mutex<Option<ImapSession>>,
    ) -> Result<tokio::sync::MutexGuard<'a, Option<ImapSession>>, ImapError> {
        let mut guard = lane.lock().await;
        if guard.is_none() {
            *guard = Some(bounded_imap(IMAP_COMMAND_TIMEOUT, self.connect()).await?);
        }
        Ok(guard)
    }

    async fn run_session_operation_on<T, F>(
        &self,
        lane: &Mutex<Option<ImapSession>>,
        retry_safe: bool,
        mut operation: F,
    ) -> Result<T, ImapError>
    where
        F: for<'session> FnMut(
            &'session mut ImapSession,
        ) -> BoxFuture<'session, Result<T, ImapError>>,
    {
        let mut already_retried = false;
        loop {
            let mut guard = match self.lock_session(lane).await {
                Ok(guard) => guard,
                Err(error) => match session_error_action(&error, retry_safe, already_retried) {
                    SessionErrorAction::InvalidateAndRetry => {
                        already_retried = true;
                        continue;
                    }
                    SessionErrorAction::Return | SessionErrorAction::InvalidateAndReturn => {
                        return Err(error);
                    }
                },
            };
            let result = operation(guard.as_mut().expect("session initialized")).await;
            let Some(error) = result.as_ref().err() else {
                return result;
            };
            match session_error_action(error, retry_safe, already_retried) {
                SessionErrorAction::Return => return result,
                SessionErrorAction::InvalidateAndReturn => {
                    *guard = None;
                    return result;
                }
                SessionErrorAction::InvalidateAndRetry => {
                    *guard = None;
                    already_retried = true;
                }
            }
        }
    }

    async fn run_session_operation<T, F>(
        &self,
        retry_safe: bool,
        operation: F,
    ) -> Result<T, ImapError>
    where
        F: for<'session> FnMut(
            &'session mut ImapSession,
        ) -> BoxFuture<'session, Result<T, ImapError>>,
    {
        self.run_session_operation_on(&self.session, retry_safe, operation)
            .await
    }
}

struct Xoauth2<'a> {
    username: &'a str,
    access_token: &'a str,
}

impl Authenticator for &mut Xoauth2<'_> {
    type Response = Vec<u8>;

    fn process(&mut self, _challenge: &[u8]) -> Self::Response {
        format!(
            "user={}\x01auth=Bearer {}\x01\x01",
            self.username, self.access_token
        )
        .into_bytes()
    }
}

#[async_trait]
impl ImapTransport for AsyncImapTransport {
    async fn capabilities(&self) -> Result<ImapCapabilities, ImapError> {
        self.run_session_operation(true, |session| {
            Box::pin(async move {
                let capabilities =
                    tokio::time::timeout(IMAP_COMMAND_TIMEOUT, session.capabilities())
                        .await
                        .map_err(|_| ImapError::CommandTimeout)?
                        .map_err(imap_protocol_error)?;
                let values = capabilities
                    .iter()
                    .map(|capability| match capability {
                        Capability::Imap4rev1 => "IMAP4REV1".to_owned(),
                        Capability::Auth(name) => format!("AUTH={name}"),
                        Capability::Atom(name) => name.to_ascii_uppercase(),
                    })
                    .collect();
                Ok(ImapCapabilities(values))
            })
        })
        .await
    }

    async fn list_mailboxes(&self) -> Result<Vec<ImapMailboxInfo>, ImapError> {
        let names = self
            .run_session_operation(true, |session| {
                Box::pin(async move {
                    tokio::time::timeout(IMAP_COMMAND_TIMEOUT, async {
                        session
                            .list(None, Some("*"))
                            .await
                            .map_err(imap_protocol_error)?
                            .try_collect::<Vec<_>>()
                            .await
                            .map_err(imap_protocol_error)
                    })
                    .await
                    .map_err(|_| ImapError::CommandTimeout)?
                })
            })
            .await?;
        let mut mailboxes = names
            .into_iter()
            .filter(|name| !name.attributes().contains(&NameAttribute::NoSelect))
            .map(|name| ImapMailboxInfo {
                role: mailbox_role(name.name(), name.attributes()),
                name: name.name().to_owned(),
                unread: 0,
                total: 0,
            })
            .collect::<Vec<_>>();
        // STATUS does not select the mailbox and therefore does not disturb
        // UID sync state. Prioritize Inbox, then bound the entire count pass so
        // one slow folder cannot stall account loading indefinitely.
        mailboxes.sort_by_key(|mailbox| mailbox.role != Some(MailboxRole::Inbox));
        let mut already_retried = false;
        loop {
            let mut guard = match self.lock_session(&self.session).await {
                Ok(guard) => guard,
                Err(error) => match session_error_action(&error, true, already_retried) {
                    SessionErrorAction::InvalidateAndRetry => {
                        already_retried = true;
                        continue;
                    }
                    SessionErrorAction::Return | SessionErrorAction::InvalidateAndReturn => {
                        return Err(error);
                    }
                },
            };
            let session = guard.as_mut().expect("session initialized");
            let mut current = mailboxes.clone();
            let deadline = tokio::time::Instant::now() + IMAP_STATUS_BUDGET;
            let mut connection_error = None;
            let mut status_timed_out = false;
            for mailbox in &mut current {
                let status = tokio::time::timeout_at(
                    deadline,
                    session.status(&mailbox.name, "(MESSAGES UNSEEN UIDNEXT UIDVALIDITY)"),
                )
                .await;
                match status {
                    Ok(Ok(status)) => {
                        let (total, unread) = mailbox_counts(&status);
                        mailbox.total = total;
                        mailbox.unread = unread;
                    }
                    Ok(Err(error)) if imap_connection_failed(&error) => {
                        connection_error = Some(imap_protocol_error(error));
                        break;
                    }
                    Ok(Err(_)) => continue,
                    Err(_) => {
                        status_timed_out = true;
                        break;
                    }
                }
            }
            if status_timed_out {
                // Cancelling an in-flight IMAP command leaves its tagged
                // response pending, so the pooled connection cannot be reused.
                *guard = None;
                return Ok(current);
            }
            if let Some(error) = connection_error {
                *guard = None;
                if !already_retried {
                    already_retried = true;
                    continue;
                }
                return Err(error);
            }
            return Ok(current);
        }
    }

    async fn select(&self, mailbox: &str) -> Result<SelectedMailbox, ImapError> {
        let mailbox = mailbox.to_owned();
        self.run_session_operation(true, move |session| {
            let mailbox = mailbox.clone();
            Box::pin(async move {
                tokio::time::timeout(IMAP_COMMAND_TIMEOUT, select_mailbox(session, &mailbox))
                    .await
                    .map_err(|_| ImapError::CommandTimeout)?
            })
        })
        .await
    }

    async fn search_uids(
        &self,
        mailbox: &str,
        before_uid: u64,
        search: Option<&str>,
        unread_only: bool,
        limit: u32,
    ) -> Result<Vec<u64>, ImapError> {
        let uid_range = if before_uid == 0 {
            "UID 1:*".to_owned()
        } else if before_uid <= 1 {
            return Ok(Vec::new());
        } else {
            format!("UID 1:{}", before_uid - 1)
        };
        let mut terms = vec![uid_range];
        if unread_only {
            terms.push("UNSEEN".to_owned());
        }
        if let Some(search) = search.filter(|value| !value.trim().is_empty()) {
            terms.push(format!("TEXT {}", quote_imap(search)?));
        }
        let mailbox = mailbox.to_owned();
        let uids = self
            .run_session_operation(true, move |session| {
                let mailbox = mailbox.clone();
                let terms = terms.clone();
                Box::pin(async move {
                    tokio::time::timeout(IMAP_COMMAND_TIMEOUT, async {
                        select_mailbox(session, &mailbox).await?;
                        Ok::<_, ImapError>(
                            session
                                .uid_search(terms.join(" "))
                                .await
                                .map_err(imap_protocol_error)?
                                .into_iter()
                                .map(u64::from)
                                .collect::<Vec<_>>(),
                        )
                    })
                    .await
                    .map_err(|_| ImapError::CommandTimeout)?
                })
            })
            .await?;
        Ok(newest_uid_page(uids, before_uid, limit))
    }

    async fn search_recent_uids(
        &self,
        mailbox: &str,
        through_uid: u64,
        limit: u32,
    ) -> Result<Vec<u64>, ImapError> {
        let windows = recent_uid_search_windows(through_uid)?;
        if windows.is_empty() {
            return Ok(Vec::new());
        }
        let limit = limit.max(1) as usize;
        let mailbox = mailbox.to_owned();
        let uids = self
            .run_session_operation(true, move |session| {
                let mailbox = mailbox.clone();
                let windows = windows.clone();
                Box::pin(async move {
                    tokio::time::timeout(IMAP_COMMAND_TIMEOUT, async {
                        select_mailbox(session, &mailbox).await?;
                        let mut uids = BTreeSet::new();
                        for (first_uid, last_uid) in windows {
                            let window = session
                                .uid_search(format!("UID {first_uid}:{last_uid}"))
                                .await
                                .map_err(imap_protocol_error)?;
                            uids.extend(window.into_iter().map(u64::from));
                            if uids.len() >= limit {
                                break;
                            }
                        }
                        Ok::<_, ImapError>(uids.into_iter().collect::<Vec<_>>())
                    })
                    .await
                    .map_err(|_| ImapError::CommandTimeout)?
                })
            })
            .await?;
        Ok(newest_uid_page(uids, 0, limit as u32))
    }

    async fn search_uids_since(
        &self,
        mailbox: &str,
        after_uid: u64,
        through_uid: u64,
        limit: u32,
    ) -> Result<IncrementalUidPage, ImapError> {
        let Some((uid_range, covered_through_uid)) =
            incremental_uid_search_range(after_uid, through_uid)?
        else {
            return Ok(IncrementalUidPage {
                uids: Vec::new(),
                high_uid: after_uid,
            });
        };
        let mailbox = mailbox.to_owned();
        let uids = self
            .run_session_operation(true, move |session| {
                let mailbox = mailbox.clone();
                let uid_range = uid_range.clone();
                Box::pin(async move {
                    tokio::time::timeout(IMAP_COMMAND_TIMEOUT, async {
                        select_mailbox(session, &mailbox).await?;
                        Ok::<_, ImapError>(
                            session
                                .uid_search(uid_range)
                                .await
                                .map_err(imap_protocol_error)?
                                .into_iter()
                                .map(u64::from)
                                .collect::<Vec<_>>(),
                        )
                    })
                    .await
                    .map_err(|_| ImapError::CommandTimeout)?
                })
            })
            .await?;
        Ok(incremental_uid_page(
            uids,
            after_uid,
            covered_through_uid,
            limit,
        ))
    }

    async fn fetch_envelopes(
        &self,
        mailbox: &str,
        uids: &[u64],
    ) -> Result<Vec<ImapEnvelope>, ImapError> {
        if uids.is_empty() {
            return Ok(Vec::new());
        }
        let uid_set = uid_set(uids)?;
        let mailbox = mailbox.to_owned();
        let fetches = self
            .run_session_operation(true, move |session| {
                let mailbox = mailbox.clone();
                let uid_set = uid_set.clone();
                Box::pin(async move {
                    tokio::time::timeout(IMAP_COMMAND_TIMEOUT, async {
                        select_mailbox(session, &mailbox).await?;
                        session
                            .uid_fetch(uid_set, IMAP_SUMMARY_FETCH)
                            .await
                            .map_err(imap_protocol_error)?
                            .try_collect::<Vec<_>>()
                            .await
                            .map_err(imap_protocol_error)
                    })
                    .await
                    .map_err(|_| ImapError::CommandTimeout)?
                })
            })
            .await?;
        let mut envelopes = fetches
            .into_iter()
            .map(|fetch| {
                let uid = fetch
                    .uid
                    .ok_or_else(|| ImapError::Protocol("UID FETCH response omitted UID".into()))?;
                let headers = parse_summary_headers(fetch.header().unwrap_or_default());
                let flags = fetch.flags().map(flag_string).collect::<BTreeSet<_>>();
                Ok(ImapEnvelope {
                    uid: u64::from(uid),
                    subject: headers.subject,
                    from: headers.from,
                    timestamp: headers.timestamp.unwrap_or_else(Utc::now),
                    flags,
                    snippet: String::new(),
                    has_attachments: headers.has_attachments,
                    message_id: headers.message_id,
                    in_reply_to: headers.in_reply_to,
                    references: headers.references,
                })
            })
            .collect::<Result<Vec<_>, ImapError>>()?;
        sort_envelopes_newest_first(&mut envelopes);
        Ok(envelopes)
    }

    async fn fetch_message(
        &self,
        mailbox: &str,
        uid: u64,
        expected_uid_validity: u64,
    ) -> Result<ImapFetchedMessage, ImapError> {
        let mailbox = mailbox.to_owned();
        self.run_session_operation_on(&self.detail_session, true, move |session| {
            let mailbox = mailbox.clone();
            Box::pin(async move {
                tokio::time::timeout(IMAP_COMMAND_TIMEOUT, async {
                    let selected = select_mailbox(session, &mailbox).await?;
                    if selected.uid_validity != expected_uid_validity {
                        return Err(ImapError::NotFound);
                    }
                    let query = bounded_raw_fetch_query(MAX_MAIL_MESSAGE_BYTES);
                    let mut fetches = session
                        .uid_fetch(uid.to_string(), query)
                        .await
                        .map_err(imap_protocol_error)?;
                    let fetch = fetches
                        .try_next()
                        .await
                        .map_err(imap_protocol_error)?
                        .ok_or(ImapError::NotFound)?;
                    if fetch.uid.map(u64::from) != Some(uid) {
                        return Err(ImapError::NotFound);
                    }
                    let declared_size = fetch
                        .size
                        .map(|size| size as usize)
                        .ok_or(ImapError::MissingMessageSize)?;
                    validate_raw_message_size(declared_size, MAX_MAIL_MESSAGE_BYTES)?;
                    let flags = fetch.flags().map(flag_string).collect::<BTreeSet<_>>();
                    let raw = fetch
                        .body()
                        .map(ToOwned::to_owned)
                        .ok_or(ImapError::NotFound)?;
                    validate_raw_message_size(raw.len(), MAX_MAIL_MESSAGE_BYTES)?;
                    Ok(ImapFetchedMessage {
                        uid,
                        uid_validity: selected.uid_validity,
                        flags,
                        raw,
                    })
                })
                .await
                .map_err(|_| ImapError::CommandTimeout)?
            })
        })
        .await
    }

    async fn store_flags(
        &self,
        mailbox: &str,
        uids: &[u64],
        add: &[String],
        remove: &[String],
    ) -> Result<(), ImapError> {
        if uids.is_empty() {
            return Ok(());
        }
        let uid_set = uid_set(uids)?;
        let add = validated_flags(add)?;
        let remove = validated_flags(remove)?;
        let mailbox = mailbox.to_owned();
        self.run_session_operation(false, move |session| {
            let mailbox = mailbox.clone();
            let uid_set = uid_set.clone();
            let add = add.clone();
            let remove = remove.clone();
            Box::pin(async move {
                tokio::time::timeout(IMAP_COMMAND_TIMEOUT, async {
                    select_mailbox(session, &mailbox).await?;
                    if !add.is_empty() {
                        session
                            .uid_store(&uid_set, format!("+FLAGS.SILENT ({})", add.join(" ")))
                            .await
                            .map_err(imap_protocol_error)?
                            .try_collect::<Vec<_>>()
                            .await
                            .map_err(imap_protocol_error)?;
                    }
                    if !remove.is_empty() {
                        session
                            .uid_store(&uid_set, format!("-FLAGS.SILENT ({})", remove.join(" ")))
                            .await
                            .map_err(imap_protocol_error)?
                            .try_collect::<Vec<_>>()
                            .await
                            .map_err(imap_protocol_error)?;
                    }
                    Ok(())
                })
                .await
                .map_err(|_| ImapError::CommandTimeout)?
            })
        })
        .await
    }

    async fn move_uids(
        &self,
        mailbox: &str,
        uids: &[u64],
        destination: &str,
    ) -> Result<(), ImapError> {
        if uids.is_empty() {
            return Ok(());
        }
        let uid_set = uid_set(uids)?;
        validate_imap_text(destination)?;
        let mailbox = mailbox.to_owned();
        let destination = destination.to_owned();
        self.run_session_operation(false, move |session| {
            let mailbox = mailbox.clone();
            let destination = destination.clone();
            let uid_set = uid_set.clone();
            Box::pin(async move {
                tokio::time::timeout(IMAP_COMMAND_TIMEOUT, async {
                    select_mailbox(session, &mailbox).await?;
                    let capabilities = session.capabilities().await.map_err(imap_protocol_error)?;
                    if capabilities.has_str("MOVE") {
                        session
                            .run_command_and_check_ok(format!(
                                "UID MOVE {uid_set} {}",
                                quote_imap(&destination)?
                            ))
                            .await
                            .map_err(imap_protocol_error)?;
                        return Ok(());
                    }
                    session
                        .uid_copy(&uid_set, &destination)
                        .await
                        .map_err(imap_protocol_error)?;
                    session
                        .uid_store(&uid_set, "+FLAGS.SILENT (\\Deleted)")
                        .await
                        .map_err(imap_protocol_error)?
                        .try_collect::<Vec<_>>()
                        .await
                        .map_err(imap_protocol_error)?;
                    if capabilities.has_str("UIDPLUS") {
                        session
                            .uid_expunge(&uid_set)
                            .await
                            .map_err(imap_protocol_error)?
                            .try_collect::<Vec<_>>()
                            .await
                            .map_err(imap_protocol_error)?;
                    }
                    Ok(())
                })
                .await
                .map_err(|_| ImapError::CommandTimeout)?
            })
        })
        .await
    }

    async fn idle(
        &self,
        mailbox: &str,
        known_uid_next: u64,
    ) -> Result<Vec<ImapIdleEvent>, ImapError> {
        // IDLE deliberately owns a second connection so mailbox reads and
        // actions never queue behind a long-running push wait.
        let mut guard = self.idle_session.lock().await;
        let mut session = match guard.take() {
            Some(session) => session,
            None => tokio::time::timeout(IMAP_COMMAND_TIMEOUT, self.connect())
                .await
                .map_err(|_| ImapError::CommandTimeout)??,
        };
        let (selected, capabilities) = tokio::time::timeout(IMAP_COMMAND_TIMEOUT, async {
            let selected = select_mailbox(&mut session, mailbox).await?;
            let capabilities = session.capabilities().await.map_err(imap_protocol_error)?;
            Ok::<_, ImapError>((selected, capabilities))
        })
        .await
        .map_err(|_| ImapError::CommandTimeout)??;
        if selected.uid_next > known_uid_next {
            *guard = Some(session);
            return Ok(vec![ImapIdleEvent::Exists(selected.uid_next)]);
        }
        if !capabilities.has_str("IDLE") {
            *guard = Some(session);
            return Ok(Vec::new());
        }
        let mut idle = session.idle();
        tokio::time::timeout(IMAP_COMMAND_TIMEOUT, idle.init())
            .await
            .map_err(|_| ImapError::CommandTimeout)?
            .map_err(imap_protocol_error)?;
        let (wait, interrupt) = idle.wait_with_timeout(Duration::from_secs(60));
        let result = wait.await.map_err(imap_protocol_error);
        drop(interrupt);
        let session = tokio::time::timeout(IMAP_COMMAND_TIMEOUT, idle.done())
            .await
            .map_err(|_| ImapError::CommandTimeout)?
            .map_err(imap_protocol_error)?;
        *guard = Some(session);
        result.map(|response| match response {
            async_imap::extensions::idle::IdleResponse::Timeout => Vec::new(),
            async_imap::extensions::idle::IdleResponse::ManualInterrupt => Vec::new(),
            async_imap::extensions::idle::IdleResponse::NewData(_) => {
                vec![ImapIdleEvent::ReconnectRequired]
            }
        })
    }
}

async fn select_mailbox(
    session: &mut ImapSession,
    mailbox: &str,
) -> Result<SelectedMailbox, ImapError> {
    validate_imap_text(mailbox)?;
    let selected = session.select(mailbox).await.map_err(imap_protocol_error)?;
    Ok(SelectedMailbox {
        uid_validity: selected
            .uid_validity
            .map(u64::from)
            .ok_or(ImapError::MissingUidValidity)?,
        uid_next: selected.uid_next.map(u64::from).unwrap_or(1),
        highest_mod_sequence: selected.highest_modseq,
    })
}

fn mailbox_role(name: &str, attributes: &[NameAttribute<'_>]) -> Option<MailboxRole> {
    if attributes.contains(&NameAttribute::Archive) || attributes.contains(&NameAttribute::All) {
        return Some(MailboxRole::Archive);
    }
    if attributes.contains(&NameAttribute::Drafts) {
        return Some(MailboxRole::Drafts);
    }
    if attributes.contains(&NameAttribute::Junk) {
        return Some(MailboxRole::Spam);
    }
    if attributes.contains(&NameAttribute::Sent) {
        return Some(MailboxRole::Sent);
    }
    if attributes.contains(&NameAttribute::Trash) {
        return Some(MailboxRole::Trash);
    }
    if attributes.contains(&NameAttribute::Flagged)
        || attributes.iter().any(
            |attribute| matches!(attribute, NameAttribute::Extension(value) if value.eq_ignore_ascii_case("\\Important")),
        )
    {
        return Some(MailboxRole::Other);
    }
    name.eq_ignore_ascii_case("INBOX")
        .then_some(MailboxRole::Inbox)
}

fn mailbox_counts(status: &async_imap::types::Mailbox) -> (u64, u64) {
    (
        u64::from(status.exists),
        u64::from(status.unseen.unwrap_or(0)),
    )
}

fn validate_imap_text(value: &str) -> Result<(), ImapError> {
    if value.contains(['\r', '\n', '\0']) {
        return Err(ImapError::InvalidConfiguration(
            "IMAP value contains prohibited control characters",
        ));
    }
    Ok(())
}

fn quote_imap(value: &str) -> Result<String, ImapError> {
    validate_imap_text(value)?;
    Ok(format!(
        "\"{}\"",
        value.replace('\\', "\\\\").replace('\"', "\\\"")
    ))
}

fn uid_set(uids: &[u64]) -> Result<String, ImapError> {
    if uids
        .iter()
        .any(|uid| *uid == 0 || *uid > u64::from(u32::MAX))
    {
        return Err(ImapError::InvalidStableId);
    }
    Ok(uids
        .iter()
        .map(u64::to_string)
        .collect::<Vec<_>>()
        .join(","))
}

fn newest_uid_page(mut uids: Vec<u64>, before_uid: u64, limit: u32) -> Vec<u64> {
    uids.retain(|uid| before_uid == 0 || *uid < before_uid);
    uids.sort_unstable_by(|left, right| right.cmp(left));
    uids.truncate(limit as usize);
    uids
}

fn recent_uid_search_windows(through_uid: u64) -> Result<Vec<(u64, u64)>, ImapError> {
    if through_uid == 0 {
        return Ok(Vec::new());
    }
    if through_uid > u64::from(u32::MAX) {
        return Err(ImapError::InvalidCursor);
    }

    let mut windows = Vec::with_capacity(IMAP_BOOTSTRAP_MAX_SEARCH_WINDOWS);
    let mut last_uid = through_uid;
    for _ in 0..IMAP_BOOTSTRAP_MAX_SEARCH_WINDOWS {
        let first_uid = last_uid
            .saturating_sub(IMAP_INCREMENTAL_UID_SEARCH_SPAN - 1)
            .max(1);
        windows.push((first_uid, last_uid));
        if first_uid == 1 {
            break;
        }
        last_uid = first_uid - 1;
    }
    Ok(windows)
}

fn incremental_uid_search_range(
    after_uid: u64,
    through_uid: u64,
) -> Result<Option<(String, u64)>, ImapError> {
    if through_uid <= after_uid {
        return Ok(None);
    }
    let first_uid = after_uid.checked_add(1).ok_or(ImapError::InvalidCursor)?;
    let covered_through_uid = through_uid.min(
        after_uid
            .checked_add(IMAP_INCREMENTAL_UID_SEARCH_SPAN)
            .ok_or(ImapError::InvalidCursor)?,
    );
    if first_uid > u64::from(u32::MAX) || covered_through_uid > u64::from(u32::MAX) {
        return Err(ImapError::InvalidCursor);
    }
    Ok(Some((
        format!("UID {first_uid}:{covered_through_uid}"),
        covered_through_uid,
    )))
}

fn incremental_uid_page(
    mut uids: Vec<u64>,
    after_uid: u64,
    through_uid: u64,
    limit: u32,
) -> IncrementalUidPage {
    uids.retain(|uid| *uid > after_uid && *uid <= through_uid);
    uids.sort_unstable();
    uids.dedup();

    let limit = limit.max(1) as usize;
    let has_more = uids.len() > limit;
    uids.truncate(limit);
    let high_uid = if has_more {
        uids.last().copied().unwrap_or(after_uid)
    } else {
        // SEARCH covered the whole requested interval, so absent/expunged UIDs
        // are safe to step over without querying the same gap forever.
        through_uid
    };
    IncrementalUidPage { uids, high_uid }
}

fn missing_reconciled_message_ids(
    requested: Vec<(u64, String)>,
    returned_uids: &BTreeSet<u64>,
) -> Vec<String> {
    requested
        .into_iter()
        .filter_map(|(uid, message_id)| (!returned_uids.contains(&uid)).then_some(message_id))
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect()
}

fn validated_flags(flags: &[String]) -> Result<Vec<String>, ImapError> {
    flags
        .iter()
        .map(|flag| {
            let valid = !flag.is_empty()
                && flag.bytes().all(|byte| {
                    byte.is_ascii_alphanumeric() || matches!(byte, b'\\' | b'-' | b'_' | b'.')
                });
            valid
                .then(|| flag.clone())
                .ok_or(ImapError::InvalidConfiguration("invalid IMAP flag"))
        })
        .collect()
}

fn flag_string(flag: Flag<'_>) -> String {
    match flag {
        Flag::Seen => "\\Seen".into(),
        Flag::Answered => "\\Answered".into(),
        Flag::Flagged => "\\Flagged".into(),
        Flag::Deleted => "\\Deleted".into(),
        Flag::Draft => "\\Draft".into(),
        Flag::Recent => "\\Recent".into(),
        Flag::MayCreate => "\\*".into(),
        Flag::Custom(value) => value.into_owned(),
    }
}

#[derive(Default)]
struct SummaryHeaders {
    subject: String,
    from: Option<Address>,
    timestamp: Option<DateTime<Utc>>,
    message_id: Option<String>,
    in_reply_to: Vec<String>,
    references: Vec<String>,
    has_attachments: bool,
}

fn parse_summary_headers(raw: &[u8]) -> SummaryHeaders {
    let mut message = raw.to_vec();
    if !message.ends_with(b"\r\n\r\n") {
        if !message.ends_with(b"\r\n") {
            message.extend_from_slice(b"\r\n");
        }
        message.extend_from_slice(b"\r\n");
    }
    let parsed = ProductionMimeCodec.parse(&message).unwrap_or_default();
    let header_text = String::from_utf8_lossy(raw).to_ascii_lowercase();
    let has_attachments = header_text.contains("content-disposition: attachment")
        || header_text.contains("content-type: multipart/mixed");
    SummaryHeaders {
        subject: parsed.subject,
        from: parsed.from,
        timestamp: parsed.date,
        message_id: parsed.message_id,
        in_reply_to: parsed.in_reply_to,
        references: parsed.references,
        has_attachments,
    }
}

fn imap_connection_failed(error: &async_imap::error::Error) -> bool {
    matches!(
        error,
        async_imap::error::Error::Io(_)
            | async_imap::error::Error::ConnectionLost
            | async_imap::error::Error::Parse(_)
    )
}

fn imap_protocol_error(error: async_imap::error::Error) -> ImapError {
    let reason = error.to_string();
    if imap_connection_failed(&error) {
        ImapError::Connection(reason)
    } else {
        ImapError::Protocol(reason)
    }
}

fn imap_authentication_error(error: async_imap::error::Error) -> ImapError {
    let reason = error.to_string();
    if imap_connection_failed(&error) {
        ImapError::Connection(reason)
    } else {
        ImapError::Authentication
    }
}

#[derive(Clone, Debug)]
pub(crate) struct SmtpEnvelope {
    pub(crate) from: String,
    pub(crate) recipients: Vec<String>,
}

#[async_trait]
pub(crate) trait SmtpTransport: Send + Sync {
    async fn send(&self, envelope: &SmtpEnvelope, rfc822: &[u8]) -> Result<(), SmtpError>;
}

pub(crate) struct LettreSmtpTransport {
    transport: AsyncSmtpTransport<Tokio1Executor>,
}

impl LettreSmtpTransport {
    pub(crate) fn new(config: &ImapSmtpConfig) -> Result<Self, SmtpError> {
        let (username, password) = match &config.smtp_authentication {
            ImapAuthentication::Password { username, password } => {
                (username.clone(), password.expose_secret().to_owned())
            }
            ImapAuthentication::OAuthBearer { .. } => {
                return Err(SmtpError {
                    reason: "XOAUTH2 SMTP requires an OAuth-capable SMTP transport".into(),
                    authentication: false,
                });
            }
            ImapAuthentication::OAuthSource { .. } => {
                return Err(SmtpError {
                    reason: "XOAUTH2 SMTP requires the native OAuth SMTP transport".into(),
                    authentication: false,
                });
            }
        };
        let tls_parameters =
            TlsParameters::new(config.smtp_host.clone()).map_err(|_| SmtpError {
                reason: "invalid SMTP TLS server name".into(),
                authentication: false,
            })?;
        let tls = match config.smtp_security {
            ConnectionSecurity::ImplicitTls => Tls::Wrapper(tls_parameters),
            ConnectionSecurity::StartTls => Tls::Required(tls_parameters),
        };
        let transport = AsyncSmtpTransport::<Tokio1Executor>::builder_dangerous(&config.smtp_host)
            .port(config.smtp_port)
            .tls(tls)
            .credentials(Credentials::new(username, password))
            .build();
        Ok(Self { transport })
    }
}

#[async_trait]
impl SmtpTransport for LettreSmtpTransport {
    async fn send(&self, envelope: &SmtpEnvelope, rfc822: &[u8]) -> Result<(), SmtpError> {
        let from = envelope.from.parse().map_err(|_| SmtpError {
            reason: "invalid SMTP envelope sender".into(),
            authentication: false,
        })?;
        let recipients = envelope
            .recipients
            .iter()
            .map(|address| address.parse())
            .collect::<Result<Vec<_>, _>>()
            .map_err(|_| SmtpError {
                reason: "invalid SMTP envelope recipient".into(),
                authentication: false,
            })?;
        let envelope = LettreEnvelope::new(Some(from), recipients).map_err(|_| SmtpError {
            reason: "invalid SMTP envelope".into(),
            authentication: false,
        })?;
        self.transport
            .send_raw(&envelope, rfc822)
            .await
            .map(|_| ())
            .map_err(|_| SmtpError {
                reason: "SMTP server rejected delivery".into(),
                authentication: false,
            })
    }
}

/// Native SMTP XOAUTH2 transport for GOA-backed accounts. It keeps one TLS
/// connection alive and never places tokens in errors, logs, or process args.
pub(crate) struct Xoauth2SmtpTransport<S> {
    host: String,
    port: u16,
    security: ConnectionSecurity,
    username: String,
    tokens: Arc<S>,
    connection: Mutex<Option<BufStream<TlsStream<TcpStream>>>>,
    tls: TlsConnector,
}

impl<S: TokenSource> Xoauth2SmtpTransport<S> {
    pub(crate) fn new(
        host: String,
        port: u16,
        security: ConnectionSecurity,
        username: String,
        tokens: Arc<S>,
    ) -> Result<Self, SmtpError> {
        let mut roots = rustls::RootCertStore::empty();
        for certificate in rustls_native_certs::load_native_certs().certs {
            roots.add(certificate).map_err(|_| SmtpError {
                reason: "platform certificate store is invalid".into(),
                authentication: false,
            })?;
        }
        let tls = rustls::ClientConfig::builder()
            .with_root_certificates(roots)
            .with_no_client_auth();
        Ok(Self {
            host,
            port,
            security,
            username,
            tokens,
            connection: Mutex::new(None),
            tls: TlsConnector::from(Arc::new(tls)),
        })
    }

    async fn connect(&self) -> Result<BufStream<TlsStream<TcpStream>>, SmtpError> {
        let tcp = timeout_smtp(TcpStream::connect((self.host.as_str(), self.port))).await?;
        let server_name =
            rustls::pki_types::ServerName::try_from(self.host.clone()).map_err(|_| SmtpError {
                reason: "invalid SMTP TLS server name".into(),
                authentication: false,
            })?;
        let tls = match self.security {
            ConnectionSecurity::ImplicitTls => self
                .tls
                .connect(server_name, tcp)
                .await
                .map_err(|_| smtp_failure())?,
            ConnectionSecurity::StartTls => {
                let mut plain = BufStream::new(tcp);
                expect_smtp(&mut plain, 220).await?;
                smtp_line(&mut plain, "EHLO quickmail.local").await?;
                expect_smtp(&mut plain, 250).await?;
                smtp_line(&mut plain, "STARTTLS").await?;
                expect_smtp(&mut plain, 220).await?;
                plain.flush().await.map_err(|_| smtp_failure())?;
                self.tls
                    .connect(server_name, plain.into_inner())
                    .await
                    .map_err(|_| smtp_failure())?
            }
        };
        let mut stream = BufStream::new(tls);
        if matches!(self.security, ConnectionSecurity::ImplicitTls) {
            expect_smtp(&mut stream, 220).await?;
        }
        smtp_line(&mut stream, "EHLO quickmail.local").await?;
        expect_smtp(&mut stream, 250).await?;
        let token = self
            .tokens
            .access_token(false)
            .await
            .map_err(|_| SmtpError {
                reason: "SMTP authorization required".into(),
                authentication: true,
            })?;
        let response = format!(
            "user={}\x01auth=Bearer {}\x01\x01",
            self.username,
            token.value.expose_secret()
        );
        let encoded = base64::engine::general_purpose::STANDARD.encode(response);
        smtp_line(&mut stream, &format!("AUTH XOAUTH2 {encoded}"))
            .await
            .map_err(|_| smtp_failure())?;
        expect_smtp(&mut stream, 235).await.map_err(|_| SmtpError {
            reason: "SMTP authorization failed".into(),
            authentication: true,
        })?;
        Ok(stream)
    }
}

#[async_trait]
impl<S: TokenSource + 'static> SmtpTransport for Xoauth2SmtpTransport<S> {
    async fn send(&self, envelope: &SmtpEnvelope, rfc822: &[u8]) -> Result<(), SmtpError> {
        validate_smtp_address(&envelope.from)?;
        for recipient in &envelope.recipients {
            validate_smtp_address(recipient)?;
        }
        let mut guard = self.connection.lock().await;
        for attempt in 0..2 {
            let reused = guard.is_some();
            if guard.is_none() {
                *guard = Some(self.connect().await?);
            }
            let result = smtp_transaction(
                guard.as_mut().expect("SMTP connection initialized"),
                envelope,
                rfc822,
            )
            .await;
            let Err((error, after_data)) = result else {
                return Ok(());
            };
            *guard = None;
            // A stale pooled connection is safe to retry before DATA. Once
            // DATA has begun, delivery may have succeeded despite a lost reply.
            if after_data || !reused || attempt == 1 {
                return Err(error);
            }
        }
        unreachable!()
    }
}

async fn smtp_transaction<R: AsyncRead + AsyncWrite + Unpin>(
    stream: &mut BufStream<R>,
    envelope: &SmtpEnvelope,
    rfc822: &[u8],
) -> Result<(), (SmtpError, bool)> {
    smtp_line(stream, &format!("MAIL FROM:<{}>", envelope.from))
        .await
        .map_err(|error| (error, false))?;
    expect_smtp(stream, 250)
        .await
        .map_err(|error| (error, false))?;
    for recipient in &envelope.recipients {
        smtp_line(stream, &format!("RCPT TO:<{recipient}>"))
            .await
            .map_err(|error| (error, false))?;
        expect_smtp(stream, 250)
            .await
            .map_err(|error| (error, false))?;
    }
    smtp_line(stream, "DATA")
        .await
        .map_err(|error| (error, false))?;
    expect_smtp(stream, 354)
        .await
        .map_err(|error| (error, false))?;
    let stuffed = dot_stuff(rfc822);
    timeout_smtp(stream.write_all(&stuffed))
        .await
        .map_err(|error| (error, true))?;
    timeout_smtp(stream.write_all(b"\r\n.\r\n"))
        .await
        .map_err(|error| (error, true))?;
    timeout_smtp(stream.flush())
        .await
        .map_err(|error| (error, true))?;
    expect_smtp(stream, 250)
        .await
        .map_err(|error| (error, true))
}

async fn smtp_line<W: AsyncWrite + Unpin>(stream: &mut W, line: &str) -> Result<(), SmtpError> {
    if line.contains(['\r', '\n', '\0']) || line.len() > 8192 {
        return Err(SmtpError {
            reason: "invalid SMTP command".into(),
            authentication: false,
        });
    }
    timeout_smtp(stream.write_all(line.as_bytes())).await?;
    timeout_smtp(stream.write_all(b"\r\n")).await?;
    timeout_smtp(stream.flush()).await
}

async fn expect_smtp<R: AsyncRead + AsyncWrite + Unpin>(
    stream: &mut BufStream<R>,
    expected: u16,
) -> Result<(), SmtpError> {
    let mut total = 0usize;
    loop {
        let mut line = String::new();
        let read = timeout_smtp(stream.read_line(&mut line)).await?;
        if read == 0 || read > 8192 {
            return Err(smtp_failure());
        }
        total += read;
        if total > 65_536 || line.len() < 4 {
            return Err(smtp_failure());
        }
        let code = line[..3].parse::<u16>().map_err(|_| smtp_failure())?;
        if code != expected {
            return Err(smtp_failure());
        }
        match line.as_bytes()[3] {
            b'-' => continue,
            b' ' => return Ok(()),
            _ => return Err(smtp_failure()),
        }
    }
}

async fn timeout_smtp<T>(
    future: impl std::future::Future<Output = std::io::Result<T>>,
) -> Result<T, SmtpError> {
    tokio::time::timeout(Duration::from_secs(30), future)
        .await
        .map_err(|_| smtp_failure())?
        .map_err(|_| smtp_failure())
}

fn smtp_failure() -> SmtpError {
    SmtpError {
        reason: "SMTP protocol or connection failure".into(),
        authentication: false,
    }
}

fn validate_smtp_address(address: &str) -> Result<(), SmtpError> {
    if address.is_empty()
        || address.len() > 320
        || address.contains(['\r', '\n', '\0', '<', '>'])
        || !address.contains('@')
    {
        Err(SmtpError {
            reason: "invalid SMTP envelope address".into(),
            authentication: false,
        })
    } else {
        Ok(())
    }
}

fn dot_stuff(message: &[u8]) -> Vec<u8> {
    let mut output = Vec::with_capacity(message.len() + 16);
    let mut line_start = true;
    for &byte in message {
        if line_start && byte == b'.' {
            output.push(b'.');
        }
        output.push(byte);
        line_start = byte == b'\n';
    }
    while output.ends_with(b"\r\n") || output.ends_with(b"\n") {
        if output.ends_with(b"\r\n") {
            output.truncate(output.len() - 2);
        } else {
            output.pop();
        }
    }
    output
}

pub(crate) struct ImapSmtpProvider<I, S, M> {
    account: Account,
    config: ImapSmtpConfig,
    imap: Arc<I>,
    smtp: Arc<S>,
    mime: M,
    special_use: Mutex<SpecialUseMailboxes>,
}

#[derive(Default)]
struct SpecialUseMailboxes {
    archive: Option<String>,
    trash: Option<String>,
}

impl<I, S, M> ImapSmtpProvider<I, S, M>
where
    I: ImapTransport,
    S: SmtpTransport,
    M: MimeCodec,
{
    pub(crate) fn new(
        account: Account,
        config: ImapSmtpConfig,
        imap: Arc<I>,
        smtp: Arc<S>,
        mime: M,
    ) -> Result<Self, ImapError> {
        config.validate()?;
        Ok(Self {
            account,
            config,
            imap,
            smtp,
            mime,
            special_use: Mutex::new(SpecialUseMailboxes::default()),
        })
    }

    async fn remember_special_use(&self, mailboxes: &[ImapMailboxInfo]) {
        let mut special_use = self.special_use.lock().await;
        special_use.archive = mailboxes
            .iter()
            .find(|mailbox| mailbox.role == Some(MailboxRole::Archive))
            .map(|mailbox| mailbox.name.clone());
        special_use.trash = mailboxes
            .iter()
            .find(|mailbox| mailbox.role == Some(MailboxRole::Trash))
            .map(|mailbox| mailbox.name.clone());
    }

    async fn action_mailbox(
        &self,
        role: MailboxRole,
        configured: Option<&str>,
    ) -> Result<String, ProviderError> {
        let cached = {
            let special_use = self.special_use.lock().await;
            match role {
                MailboxRole::Archive => special_use.archive.clone(),
                MailboxRole::Trash => special_use.trash.clone(),
                _ => None,
            }
        };
        if let Some(mailbox) = cached {
            return Ok(mailbox);
        }

        let mailboxes = self.imap.list_mailboxes().await.map_err(provider_error)?;
        let discovered = special_use_mailbox(&mailboxes, role);
        self.remember_special_use(&mailboxes).await;
        discovered
            .or_else(|| configured.map(str::to_owned))
            .ok_or_else(|| ProviderError::Unsupported(format!("{role:?} mailbox is not available")))
    }

    async fn validate_ids(
        &self,
        message_ids: &[String],
    ) -> Result<(String, Vec<u64>), ProviderError> {
        let mut mailbox = None;
        let mut expected_uid_validity = None;
        let mut uids = Vec::with_capacity(message_ids.len());
        for id in message_ids {
            let native_id = provider_native_id(&self.account.id, id)?;
            let parsed = StableImapId::parse(native_id).map_err(provider_error)?;
            if mailbox
                .as_ref()
                .is_some_and(|mailbox| mailbox != &parsed.mailbox)
                || expected_uid_validity.is_some_and(|value| value != parsed.uid_validity)
            {
                return Err(ProviderError::Unsupported(
                    "one action cannot span IMAP mailboxes".into(),
                ));
            }
            mailbox = Some(parsed.mailbox);
            expected_uid_validity = Some(parsed.uid_validity);
            uids.push(parsed.uid);
        }
        let mailbox =
            mailbox.ok_or_else(|| ProviderError::Other("message list is empty".into()))?;
        let selected = self.imap.select(&mailbox).await.map_err(provider_error)?;
        if Some(selected.uid_validity) != expected_uid_validity {
            return Err(ProviderError::Temporary(
                "mailbox UIDVALIDITY changed; a full mailbox resync is required".into(),
            ));
        }
        Ok((mailbox, uids))
    }
}

#[async_trait]
impl<I, S, M> MailProvider for ImapSmtpProvider<I, S, M>
where
    I: ImapTransport + 'static,
    S: SmtpTransport + 'static,
    M: MimeCodec + 'static,
{
    fn kind(&self) -> &'static str {
        "imap_smtp"
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
            archive: self.config.discover_special_use || self.config.archive_mailbox.is_some(),
            spam: false,
            push: true,
            attachment_retrieval: true,
        }
    }

    async fn list_mailboxes(&self) -> Result<Vec<Mailbox>, ProviderError> {
        let mailboxes = self.imap.list_mailboxes().await.map_err(provider_error)?;
        self.remember_special_use(&mailboxes).await;
        Ok(mailboxes
            .into_iter()
            .map(|mailbox| Mailbox {
                id: mailbox.name.clone(),
                account_id: self.account.id.clone(),
                name: mailbox.name,
                role: mailbox.role,
                unread: mailbox.unread,
                total: mailbox.total,
            })
            .collect())
    }

    async fn list_messages(&self, query: MessageQuery) -> Result<MessagePage, ProviderError> {
        let mailbox = query.mailbox_id.as_deref().unwrap_or("INBOX");
        let selected = self.imap.select(mailbox).await.map_err(provider_error)?;
        let cursor = match query.cursor.as_deref() {
            Some(cursor) => {
                let cursor = UidCursor::parse(cursor).map_err(provider_error)?;
                if cursor.uid_validity != selected.uid_validity {
                    0
                } else {
                    cursor.last_uid
                }
            }
            None => 0,
        };
        let limit = query.limit.clamp(1, 500);
        let mut uids = self
            .imap
            .search_uids(
                mailbox,
                cursor,
                query.search.as_deref(),
                query.unread_only,
                limit.saturating_add(1),
            )
            .await
            .map_err(provider_error)?;
        let has_more = uids.len() > limit as usize;
        uids.truncate(limit as usize);
        let envelopes = self
            .imap
            .fetch_envelopes(mailbox, &uids)
            .await
            .map_err(provider_error)?;
        let next_cursor = has_more.then(|| {
            UidCursor {
                uid_validity: selected.uid_validity,
                last_uid: *uids.last().unwrap_or(&cursor),
            }
            .to_string()
        });
        let messages = envelopes
            .into_iter()
            .map(|envelope| {
                imap_message_summary(&self.account.id, mailbox, selected.uid_validity, envelope)
            })
            .collect();
        Ok(MessagePage {
            messages,
            next_cursor,
        })
    }

    async fn sync_mailbox(
        &self,
        query: MailboxSyncQuery,
    ) -> Result<MailboxSyncPage, ProviderError> {
        if query.account_id != self.account.id {
            return Err(ProviderError::Other(
                "mailbox sync account does not match provider".into(),
            ));
        }

        let mailbox = query.mailbox_id.as_str();
        let selected = self.imap.select(mailbox).await.map_err(provider_error)?;
        let previous = query
            .cursor
            .as_deref()
            .map(UidCursor::parse)
            .transpose()
            .map_err(provider_error)?;
        let plan = uid_sync_plan(previous, &selected);
        let limit = query.limit.clamp(1, 500);

        let (new_uids, high_uid) = if let Some(after_uid) = plan.after_uid {
            let page = self
                .imap
                .search_uids_since(mailbox, after_uid, plan.through_uid, limit)
                .await
                .map_err(provider_error)?;
            (page.uids, page.high_uid)
        } else {
            // First sync and UIDVALIDITY resets intentionally retain the
            // bounded newest-message bootstrap behavior.
            (
                self.imap
                    .search_recent_uids(mailbox, plan.through_uid, limit)
                    .await
                    .map_err(provider_error)?,
                plan.through_uid,
            )
        };

        let mut fetch_uids = new_uids.into_iter().collect::<BTreeSet<_>>();
        let mut reconciled_message_ids = Vec::new();
        if plan.after_uid.is_some() {
            for message_id in query.reconcile_message_ids {
                let Ok(native_id) = provider_native_id(&self.account.id, &message_id) else {
                    continue;
                };
                let Ok(parsed) = StableImapId::parse(native_id) else {
                    continue;
                };
                if parsed.mailbox == mailbox && parsed.uid_validity == selected.uid_validity {
                    fetch_uids.insert(parsed.uid);
                    reconciled_message_ids.push((parsed.uid, message_id));
                }
            }
        }
        let fetch_uids = fetch_uids.into_iter().collect::<Vec<_>>();
        let envelopes = self
            .imap
            .fetch_envelopes(mailbox, &fetch_uids)
            .await
            .map_err(provider_error)?;
        let confirmed = self.imap.select(mailbox).await.map_err(provider_error)?;
        if confirmed.uid_validity != selected.uid_validity {
            return Err(ProviderError::Temporary(
                "mailbox UIDVALIDITY changed during synchronization; retry required".into(),
            ));
        }
        let returned_uids = envelopes
            .iter()
            .map(|envelope| envelope.uid)
            .collect::<BTreeSet<_>>();
        let removed_message_ids =
            missing_reconciled_message_ids(reconciled_message_ids, &returned_uids);
        let messages = envelopes
            .into_iter()
            .map(|envelope| {
                imap_message_summary(&self.account.id, mailbox, selected.uid_validity, envelope)
            })
            .collect();

        Ok(MailboxSyncPage {
            messages,
            removed_message_ids,
            cursor: Some(
                UidCursor {
                    uid_validity: selected.uid_validity,
                    last_uid: high_uid,
                }
                .to_string(),
            ),
            reset: plan.reset,
        })
    }

    async fn get_message(&self, id: &str) -> Result<Message, ProviderError> {
        let native_id = provider_native_id(&self.account.id, id)?;
        let parsed_id = StableImapId::parse(native_id).map_err(provider_error)?;
        let fetched = self
            .imap
            .fetch_message(&parsed_id.mailbox, parsed_id.uid, parsed_id.uid_validity)
            .await
            .map_err(provider_error)?;
        if fetched.uid != parsed_id.uid || fetched.uid_validity != parsed_id.uid_validity {
            return Err(ProviderError::NotFound);
        }
        let parsed = self.mime.parse(&fetched.raw).map_err(mime_provider_error)?;
        let thread_id = imap_thread_id(
            &self.account.id,
            parsed.message_id.as_deref(),
            &parsed.references,
            &parsed.in_reply_to,
        )
        .or_else(|| {
            Some(imap_singleton_thread_id(
                &self.account.id,
                &parsed_id.to_string(),
            ))
        });
        Ok(Message {
            summary: MessageSummary {
                id: id.to_owned(),
                account_id: self.account.id.clone(),
                mailbox_id: Some(parsed_id.mailbox),
                thread_id,
                subject: parsed.subject,
                author: parsed.from,
                timestamp: parsed.date.unwrap_or_else(Utc::now),
                read: fetched.flags.contains("\\Seen"),
                starred: fetched.flags.contains("\\Flagged"),
                snippet: parsed
                    .text_body
                    .as_deref()
                    .unwrap_or_default()
                    .chars()
                    .take(180)
                    .collect(),
                has_attachments: !parsed.attachments.is_empty(),
                labels: fetched
                    .flags
                    .into_iter()
                    .filter(|flag| !flag.starts_with('\\'))
                    .collect(),
                provider_data: json!({
                    "messageId": parsed.message_id,
                    "references": parsed.references,
                    "inReplyTo": parsed.in_reply_to,
                }),
            },
            to: parsed.to,
            cc: parsed.cc,
            bcc: parsed.bcc,
            body_text: parsed.text_body,
            body_html: parsed.html_body,
            attachments: parsed
                .attachments
                .into_iter()
                .enumerate()
                .map(|(index, attachment)| Attachment {
                    id: index.to_string(),
                    filename: attachment.filename,
                    content_type: attachment.content_type,
                    size: attachment.data.len() as u64,
                    inline: attachment.inline,
                    content_id: attachment.content_id,
                })
                .collect(),
        })
    }

    async fn apply_action(&self, action: MailAction) -> Result<(), ProviderError> {
        match action {
            MailAction::MarkRead { message_ids, read } => {
                let (mailbox, uids) = self.validate_ids(&message_ids).await?;
                let seen = vec!["\\Seen".to_owned()];
                let (add, remove) = if read {
                    (seen.as_slice(), &[][..])
                } else {
                    (&[][..], seen.as_slice())
                };
                self.imap
                    .store_flags(&mailbox, &uids, add, remove)
                    .await
                    .map_err(provider_error)
            }
            MailAction::Star {
                message_ids,
                starred,
            } => {
                let (mailbox, uids) = self.validate_ids(&message_ids).await?;
                let flagged = vec!["\\Flagged".to_owned()];
                let (add, remove) = if starred {
                    (flagged.as_slice(), &[][..])
                } else {
                    (&[][..], flagged.as_slice())
                };
                self.imap
                    .store_flags(&mailbox, &uids, add, remove)
                    .await
                    .map_err(provider_error)
            }
            MailAction::Archive { message_ids } => {
                let destination = self
                    .action_mailbox(MailboxRole::Archive, self.config.archive_mailbox.as_deref())
                    .await?;
                let (mailbox, uids) = self.validate_ids(&message_ids).await?;
                self.imap
                    .move_uids(&mailbox, &uids, &destination)
                    .await
                    .map_err(provider_error)
            }
            MailAction::Trash { message_ids } => {
                let destination = self
                    .action_mailbox(MailboxRole::Trash, self.config.trash_mailbox.as_deref())
                    .await?;
                let (mailbox, uids) = self.validate_ids(&message_ids).await?;
                self.imap
                    .move_uids(&mailbox, &uids, &destination)
                    .await
                    .map_err(provider_error)
            }
            MailAction::Move {
                message_ids,
                mailbox_id,
            } => {
                let (mailbox, uids) = self.validate_ids(&message_ids).await?;
                self.imap
                    .move_uids(&mailbox, &uids, &mailbox_id)
                    .await
                    .map_err(provider_error)
            }
            MailAction::SetLabels { .. } => Err(ProviderError::Unsupported(
                "Gmail labels are not available over generic IMAP".into(),
            )),
        }
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
        let (reply_message_id, reply_references) = match message.in_reply_to.as_deref() {
            Some(parent_id) => {
                let parent = self.get_message(parent_id).await?;
                let message_id = parent
                    .summary
                    .provider_data
                    .get("messageId")
                    .and_then(|value| value.as_str())
                    .ok_or_else(|| {
                        ProviderError::Other("reply target has no RFC Message-ID".into())
                    })?
                    .to_owned();
                let references = reply_reference_chain(&parent.summary.provider_data);
                (Some(message_id), references)
            }
            None => (None, Vec::new()),
        };
        let raw = self
            .mime
            .build_reply(
                &from,
                &message,
                reply_message_id.as_deref(),
                &reply_references,
            )
            .map_err(mime_provider_error)?;
        let recipients = message
            .to
            .iter()
            .chain(message.cc.iter())
            .chain(message.bcc.iter())
            .map(|address| address.address.clone())
            .collect();
        self.smtp
            .send(
                &SmtpEnvelope {
                    from: from.address,
                    recipients,
                },
                &raw,
            )
            .await
            .map_err(smtp_provider_error)?;
        Ok(normalized_message_id(
            &self.account.id,
            &format!("smtp:{}", Uuid::new_v4()),
        ))
    }

    async fn get_attachment(
        &self,
        message_id: &str,
        attachment_id: &str,
    ) -> Result<AttachmentData, ProviderError> {
        let native_id = provider_native_id(&self.account.id, message_id)?;
        let parsed_id = StableImapId::parse(native_id).map_err(provider_error)?;
        let index = attachment_id
            .parse::<usize>()
            .map_err(|_| ProviderError::NotFound)?;
        let fetched = self
            .imap
            .fetch_message(&parsed_id.mailbox, parsed_id.uid, parsed_id.uid_validity)
            .await
            .map_err(provider_error)?;
        let parsed = self.mime.parse(&fetched.raw).map_err(mime_provider_error)?;
        let attachment = parsed
            .attachments
            .into_iter()
            .nth(index)
            .ok_or(ProviderError::NotFound)?;
        Ok(AttachmentData {
            filename: attachment.filename,
            content_type: attachment.content_type,
            bytes: attachment.data,
        })
    }
}

fn imap_message_summary(
    account_id: &str,
    mailbox: &str,
    uid_validity: u64,
    envelope: ImapEnvelope,
) -> MessageSummary {
    let native_id = StableImapId {
        mailbox: mailbox.to_owned(),
        uid_validity,
        uid: envelope.uid,
    }
    .to_string();
    let thread_id = imap_thread_id(
        account_id,
        envelope.message_id.as_deref(),
        &envelope.references,
        &envelope.in_reply_to,
    )
    .or_else(|| Some(imap_singleton_thread_id(account_id, &native_id)));
    MessageSummary {
        id: normalized_message_id(account_id, &native_id),
        account_id: account_id.to_owned(),
        mailbox_id: Some(mailbox.to_owned()),
        thread_id,
        subject: envelope.subject,
        author: envelope.from,
        timestamp: envelope.timestamp,
        read: envelope.flags.contains("\\Seen"),
        starred: envelope.flags.contains("\\Flagged"),
        snippet: envelope.snippet,
        has_attachments: envelope.has_attachments,
        labels: envelope
            .flags
            .iter()
            .filter(|flag| !flag.starts_with('\\'))
            .cloned()
            .collect(),
        provider_data: json!({
            "uid": envelope.uid,
            "messageId": envelope.message_id,
            "references": envelope.references,
            "inReplyTo": envelope.in_reply_to,
        }),
    }
}

fn imap_thread_id(
    account_id: &str,
    message_id: Option<&str>,
    references: &[String],
    in_reply_to: &[String],
) -> Option<String> {
    // RFC 5256 REFERENCES: use References when valid, otherwise the first
    // valid In-Reply-To ID, with the message's own ID as a new root.
    let root = references
        .iter()
        .find_map(|value| canonical_rfc_message_id(value))
        .or_else(|| {
            in_reply_to
                .iter()
                .find_map(|value| canonical_rfc_message_id(value))
        })
        .or_else(|| message_id.and_then(canonical_rfc_message_id))?;
    let name = format!("quickmail:rfc822-thread:{account_id}:{root}");
    let id = Uuid::new_v5(&Uuid::NAMESPACE_OID, name.as_bytes());
    Some(normalized_message_id(account_id, &format!("thread:{id}")))
}

fn imap_singleton_thread_id(account_id: &str, native_id: &str) -> String {
    let name = format!("quickmail:imap-singleton:{account_id}:{native_id}");
    let id = Uuid::new_v5(&Uuid::NAMESPACE_OID, name.as_bytes());
    normalized_message_id(account_id, &format!("thread:{id}"))
}

fn canonical_rfc_message_id(value: &str) -> Option<String> {
    let value = value.trim();
    let value = value
        .strip_prefix('<')
        .and_then(|value| value.strip_suffix('>'))
        .unwrap_or(value)
        .trim();
    if value.is_empty() || value.len() > 998 || value.chars().any(char::is_control) {
        return None;
    }
    let (local, domain) = value.rsplit_once('@')?;
    if local.is_empty() || domain.is_empty() || domain.chars().any(char::is_whitespace) {
        return None;
    }
    let local = if local.starts_with('"') && local.ends_with('"') && local.len() >= 2 {
        let mut unquoted = String::with_capacity(local.len() - 2);
        let mut characters = local[1..local.len() - 1].chars();
        while let Some(character) = characters.next() {
            if character == '\\' {
                unquoted.push(characters.next()?);
            } else {
                unquoted.push(character);
            }
        }
        unquoted
    } else {
        local.to_owned()
    };
    Some(format!("{local}@{}", domain.to_ascii_lowercase()))
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct StableImapId {
    mailbox: String,
    uid_validity: u64,
    uid: u64,
}

impl StableImapId {
    fn parse(value: &str) -> Result<Self, ImapError> {
        let mut parts = value.split(':');
        if parts.next() != Some("imap") {
            return Err(ImapError::InvalidStableId);
        }
        let uid_validity = parts
            .next()
            .and_then(|value| value.parse().ok())
            .ok_or(ImapError::InvalidStableId)?;
        let uid = parts
            .next()
            .and_then(|value| value.parse().ok())
            .filter(|uid| *uid > 0)
            .ok_or(ImapError::InvalidStableId)?;
        let mailbox = parts
            .next()
            .and_then(decode_hex)
            .ok_or(ImapError::InvalidStableId)?;
        if parts.next().is_some() {
            return Err(ImapError::InvalidStableId);
        }
        Ok(Self {
            mailbox,
            uid_validity,
            uid,
        })
    }
}

impl fmt::Display for StableImapId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            formatter,
            "imap:{}:{}:{}",
            self.uid_validity,
            self.uid,
            encode_hex(self.mailbox.as_bytes())
        )
    }
}

fn provider_native_id<'a>(account_id: &str, id: &'a str) -> Result<&'a str, ProviderError> {
    id.strip_prefix(account_id)
        .and_then(|suffix| suffix.strip_prefix(':'))
        .filter(|native| native.starts_with("imap:"))
        .ok_or(ProviderError::NotFound)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct UidCursor {
    uid_validity: u64,
    last_uid: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct UidSyncPlan {
    /// Present only when the persisted cursor belongs to this UID generation.
    after_uid: Option<u64>,
    through_uid: u64,
    reset: bool,
}

fn uid_sync_plan(previous: Option<UidCursor>, selected: &SelectedMailbox) -> UidSyncPlan {
    let same_generation = previous.filter(|cursor| cursor.uid_validity == selected.uid_validity);
    UidSyncPlan {
        after_uid: same_generation.map(|cursor| cursor.last_uid),
        through_uid: selected.uid_next.saturating_sub(1),
        reset: previous.is_some() && same_generation.is_none(),
    }
}

impl UidCursor {
    fn parse(value: &str) -> Result<Self, ImapError> {
        let (uid_validity, last_uid) = value.split_once(':').ok_or(ImapError::InvalidCursor)?;
        let uid_validity = uid_validity.parse().map_err(|_| ImapError::InvalidCursor)?;
        let last_uid = last_uid.parse().map_err(|_| ImapError::InvalidCursor)?;
        if uid_validity == 0 || uid_validity > u64::from(u32::MAX) || last_uid > u64::from(u32::MAX)
        {
            return Err(ImapError::InvalidCursor);
        }
        Ok(Self {
            uid_validity,
            last_uid,
        })
    }
}

impl fmt::Display for UidCursor {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{}:{}", self.uid_validity, self.last_uid)
    }
}

fn encode_hex(input: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut output = String::with_capacity(input.len() * 2);
    for byte in input {
        output.push(HEX[(byte >> 4) as usize] as char);
        output.push(HEX[(byte & 0xf) as usize] as char);
    }
    output
}

fn decode_hex(input: &str) -> Option<String> {
    if !input.len().is_multiple_of(2) {
        return None;
    }
    let bytes = input
        .as_bytes()
        .as_chunks::<2>()
        .0
        .iter()
        .map(|pair| Some(hex(pair[0])? << 4 | hex(pair[1])?))
        .collect::<Option<Vec<_>>>()?;
    String::from_utf8(bytes).ok()
}

fn hex(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
}

fn provider_error(error: ImapError) -> ProviderError {
    match error {
        ImapError::Authentication => ProviderError::Authentication("IMAP login failed".into()),
        ImapError::NotFound => ProviderError::NotFound,
        ImapError::MessageTooLarge => ProviderError::ResourceTooLarge("message"),
        other => ProviderError::Temporary(other.to_string()),
    }
}

fn smtp_provider_error(error: SmtpError) -> ProviderError {
    if error.authentication {
        ProviderError::Authentication(error.to_string())
    } else {
        ProviderError::Temporary(error.to_string())
    }
}

fn special_use_mailbox(mailboxes: &[ImapMailboxInfo], role: MailboxRole) -> Option<String> {
    mailboxes
        .iter()
        .find(|mailbox| mailbox.role == Some(role))
        .map(|mailbox| mailbox.name.clone())
}

fn sort_envelopes_newest_first(envelopes: &mut [ImapEnvelope]) {
    envelopes.sort_by_key(|envelope| std::cmp::Reverse(envelope.uid));
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

#[derive(Debug, Error)]
pub(crate) enum ImapError {
    #[error("invalid IMAP/SMTP configuration: {0}")]
    InvalidConfiguration(&'static str),
    #[error("IMAP authentication failed")]
    Authentication,
    #[error("IMAP resource was not found")]
    NotFound,
    #[error("FETCH response did not include RFC822.SIZE")]
    MissingMessageSize,
    #[error("message exceeds the configured IMAP size limit")]
    MessageTooLarge,
    #[error("SELECT response did not include UIDVALIDITY")]
    MissingUidValidity,
    #[error("invalid stable IMAP message ID")]
    InvalidStableId,
    #[error("invalid IMAP UID cursor")]
    InvalidCursor,
    #[error("IMAP connection failure: {0}")]
    Connection(String),
    #[error("IMAP protocol failure: {0}")]
    Protocol(String),
    #[error("IMAP command timed out")]
    CommandTimeout,
}

#[derive(Debug, Error)]
#[error("SMTP delivery failed: {reason}")]
pub(crate) struct SmtpError {
    pub(crate) reason: String,
    authentication: bool,
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::AsyncReadExt;

    #[test]
    fn parses_capabilities_case_insensitively() {
        let capabilities = ImapCapabilities::parse(&[
            "* CAPABILITY IMAP4rev1 UIDPLUS MOVE IDLE CONDSTORE".into(),
            "A1 OK [CAPABILITY ESEARCH UTF8=ACCEPT] done".into(),
        ]);
        assert!(capabilities.contains("idle"));
        assert!(capabilities.contains("UIDPLUS"));
        assert!(capabilities.contains("esearch"));
    }

    #[test]
    fn stale_read_sessions_reconnect_once_then_surface_the_error() {
        let broken_pipe = ImapError::Connection("io: Broken pipe (os error 32)".into());
        assert_eq!(
            session_error_action(&broken_pipe, true, false),
            SessionErrorAction::InvalidateAndRetry
        );
        assert_eq!(
            session_error_action(&broken_pipe, true, true),
            SessionErrorAction::InvalidateAndReturn
        );
        assert_eq!(
            session_error_action(&ImapError::CommandTimeout, true, false),
            SessionErrorAction::InvalidateAndRetry
        );
    }

    #[test]
    fn stale_mutating_sessions_are_invalidated_without_replay() {
        let broken_pipe = ImapError::Connection("io: Broken pipe (os error 32)".into());
        assert_eq!(
            session_error_action(&broken_pipe, false, false),
            SessionErrorAction::InvalidateAndReturn
        );
        assert_eq!(
            session_error_action(&ImapError::CommandTimeout, false, false),
            SessionErrorAction::InvalidateAndReturn
        );
    }

    #[test]
    fn semantic_imap_failures_do_not_discard_a_healthy_connection() {
        let error = imap_protocol_error(async_imap::error::Error::No("mailbox denied".into()));
        assert!(matches!(error, ImapError::Protocol(_)));
        assert_eq!(
            session_error_action(&error, true, false),
            SessionErrorAction::Return
        );
    }

    #[test]
    fn async_imap_transport_failures_are_marked_as_stale() {
        let io_error = imap_protocol_error(async_imap::error::Error::Io(std::io::Error::new(
            std::io::ErrorKind::BrokenPipe,
            "broken pipe",
        )));
        let lost = imap_protocol_error(async_imap::error::Error::ConnectionLost);
        assert!(matches!(io_error, ImapError::Connection(_)));
        assert!(matches!(lost, ImapError::Connection(_)));
    }

    #[test]
    fn authentication_handshake_transport_failures_are_retryable_connections() {
        let io_error = imap_authentication_error(async_imap::error::Error::Io(
            std::io::Error::new(std::io::ErrorKind::BrokenPipe, "broken pipe"),
        ));
        let lost = imap_authentication_error(async_imap::error::Error::ConnectionLost);

        assert!(matches!(io_error, ImapError::Connection(_)));
        assert!(matches!(lost, ImapError::Connection(_)));
        assert_eq!(
            session_error_action(&io_error, true, false),
            SessionErrorAction::InvalidateAndRetry
        );
    }

    #[test]
    fn semantic_authentication_rejection_is_not_retried() {
        let rejected =
            imap_authentication_error(async_imap::error::Error::No("invalid credentials".into()));

        assert!(matches!(rejected, ImapError::Authentication));
        assert_eq!(
            session_error_action(&rejected, true, false),
            SessionErrorAction::Return
        );
    }

    #[test]
    fn select_metadata_tracks_uidvalidity_uidnext_and_modseq() {
        let selected = SelectedMailbox::from_responses(&[
            "* OK [UIDVALIDITY 777] stable".into(),
            "* OK [UIDNEXT 42] predicted".into(),
            "* OK [HIGHESTMODSEQ 9001] modseq".into(),
        ])
        .unwrap();
        assert_eq!(selected.uid_validity, 777);
        assert_eq!(selected.uid_next, 42);
        assert_eq!(selected.highest_mod_sequence, Some(9001));
    }

    #[test]
    fn summary_headers_decode_rfc2047_subject_and_author() {
        let headers = parse_summary_headers(
            b"Subject: =?UTF-8?B?R3LDvMOfZSBhdXMgS8O2bG4=?=\r\nFrom: =?UTF-8?Q?J=C3=B6rg_M=C3=BCller?= <joerg@example.com>\r\nDate: Tue, 01 Sep 2026 10:15:00 +0200\r\nMessage-ID: <encoded@example.com>\r\nIn-Reply-To: <parent@example.com>\r\nReferences: <root@example.com> <parent@example.com>\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n",
        );
        assert_eq!(headers.subject, "Grüße aus Köln");
        assert_eq!(headers.from.unwrap().name, "Jörg Müller");
        assert_eq!(headers.message_id.as_deref(), Some("encoded@example.com"));
        assert_eq!(headers.in_reply_to, ["parent@example.com"]);
        assert_eq!(
            headers.references,
            ["root@example.com", "parent@example.com"]
        );
        assert_eq!(
            headers.timestamp.unwrap().to_rfc3339(),
            "2026-09-01T08:15:00+00:00"
        );
    }

    #[test]
    fn special_use_roles_do_not_depend_on_localized_names() {
        assert_eq!(
            mailbox_role("[Gmail]/Tutti i messaggi", &[NameAttribute::All]),
            Some(MailboxRole::Archive)
        );
        assert_eq!(
            mailbox_role("[Gmail]/Posta indesiderata", &[NameAttribute::Junk]),
            Some(MailboxRole::Spam)
        );
        assert_eq!(
            mailbox_role("[Gmail]/Importanti", &[NameAttribute::Flagged]),
            Some(MailboxRole::Other)
        );
        let mailboxes = vec![
            ImapMailboxInfo {
                name: "[Gmail]/Tutti i messaggi".into(),
                role: Some(MailboxRole::Archive),
                unread: 0,
                total: 0,
            },
            ImapMailboxInfo {
                name: "[Gmail]/Cestino".into(),
                role: Some(MailboxRole::Trash),
                unread: 0,
                total: 0,
            },
        ];
        assert_eq!(
            special_use_mailbox(&mailboxes, MailboxRole::Archive).as_deref(),
            Some("[Gmail]/Tutti i messaggi")
        );
        assert_eq!(
            special_use_mailbox(&mailboxes, MailboxRole::Trash).as_deref(),
            Some("[Gmail]/Cestino")
        );
    }

    #[test]
    fn status_counts_map_messages_and_unseen() {
        let status = async_imap::types::Mailbox {
            exists: 868,
            unseen: Some(17),
            uid_next: Some(900),
            uid_validity: Some(42),
            ..Default::default()
        };
        assert_eq!(mailbox_counts(&status), (868, 17));
    }

    #[test]
    fn stable_ids_round_trip_non_ascii_mailboxes() {
        let id = StableImapId {
            mailbox: "Reise/日本".into(),
            uid_validity: 99,
            uid: 120,
        };
        assert_eq!(StableImapId::parse(&id.to_string()).unwrap(), id);
    }

    #[test]
    fn uid_pages_are_newest_first_without_overlap() {
        let all = (1..=500).collect::<Vec<_>>();
        let first = newest_uid_page(all.clone(), 0, 200);
        assert_eq!(first, (301..=500).rev().collect::<Vec<_>>());
        let second = newest_uid_page(all, *first.last().unwrap(), 200);
        assert_eq!(second, (101..=300).rev().collect::<Vec<_>>());
    }

    #[test]
    fn incremental_uid_search_never_falls_back_to_full_mailbox_range() {
        assert_eq!(
            incremental_uid_search_range(42, 49).unwrap(),
            Some(("UID 43:49".into(), 49))
        );
        assert_eq!(incremental_uid_search_range(49, 49).unwrap(), None);
        let bounded = incremental_uid_search_range(42, 100_000).unwrap().unwrap();
        assert_eq!(
            bounded,
            (
                format!("UID 43:{}", 42 + IMAP_INCREMENTAL_UID_SEARCH_SPAN),
                42 + IMAP_INCREMENTAL_UID_SEARCH_SPAN,
            )
        );
        assert!(!bounded.0.contains("1:*"));
        assert_eq!(
            incremental_uid_page(Vec::new(), 42, bounded.1, 200).high_uid,
            42 + IMAP_INCREMENTAL_UID_SEARCH_SPAN
        );
    }

    #[test]
    fn bootstrap_uid_search_uses_bounded_reverse_windows() {
        assert_eq!(
            recent_uid_search_windows(10_000).unwrap(),
            vec![(5_905, 10_000), (1_809, 5_904), (1, 1_808)]
        );
        let bounded = recent_uid_search_windows(1_000_000).unwrap();
        assert_eq!(bounded.len(), IMAP_BOOTSTRAP_MAX_SEARCH_WINDOWS);
        assert!(bounded.iter().all(|(first, last)| {
            first <= last && last - first < IMAP_INCREMENTAL_UID_SEARCH_SPAN
        }));
        assert!(bounded.windows(2).all(|pair| pair[1].1 + 1 == pair[0].0));
    }

    #[test]
    fn incremental_uid_pages_advance_over_gaps_without_skipping_batches() {
        let complete = incremental_uid_page(vec![20, 12, 12, 15, 9, 21], 10, 20, 10);
        assert_eq!(complete.uids, vec![12, 15, 20]);
        assert_eq!(complete.high_uid, 20);

        let bounded = incremental_uid_page((11..=20).rev().collect(), 10, 20, 3);
        assert_eq!(bounded.uids, vec![11, 12, 13]);
        assert_eq!(bounded.high_uid, 13);

        let remainder = incremental_uid_page((14..=20).collect(), bounded.high_uid, 20, 20);
        assert_eq!(remainder.uids, (14..=20).collect::<Vec<_>>());
        assert_eq!(remainder.high_uid, 20);
    }

    #[test]
    fn reconciliation_marks_only_missing_requested_uids_as_removed() {
        let returned = BTreeSet::from([42, 44]);
        assert_eq!(
            missing_reconciled_message_ids(
                vec![
                    (42, "account:present".into()),
                    (43, "account:expunged".into()),
                    (43, "account:expunged".into()),
                    (44, "account:also-present".into()),
                ],
                &returned,
            ),
            vec!["account:expunged"]
        );
    }

    #[test]
    fn uid_cursor_rejects_zero_generation_and_out_of_range_values() {
        assert!(UidCursor::parse("777:42").is_ok());
        assert!(UidCursor::parse("0:42").is_err());
        assert!(UidCursor::parse("777:4294967296").is_err());
        assert!(UidCursor::parse("777:42:extra").is_err());
    }

    #[test]
    fn uid_sync_plan_bootstraps_once_and_resets_on_uidvalidity_change() {
        let selected = SelectedMailbox {
            uid_validity: 777,
            uid_next: 50,
            highest_mod_sequence: None,
        };
        assert_eq!(
            uid_sync_plan(None, &selected),
            UidSyncPlan {
                after_uid: None,
                through_uid: 49,
                reset: false,
            }
        );
        assert_eq!(
            uid_sync_plan(
                Some(UidCursor {
                    uid_validity: 777,
                    last_uid: 42,
                }),
                &selected,
            ),
            UidSyncPlan {
                after_uid: Some(42),
                through_uid: 49,
                reset: false,
            }
        );
        assert_eq!(
            uid_sync_plan(
                Some(UidCursor {
                    uid_validity: 776,
                    last_uid: 900,
                }),
                &selected,
            ),
            UidSyncPlan {
                after_uid: None,
                through_uid: 49,
                reset: true,
            }
        );
    }

    #[test]
    fn fetched_envelopes_preserve_newest_first_page_order() {
        let envelope = |uid| ImapEnvelope {
            uid,
            subject: String::new(),
            from: None,
            timestamp: Utc::now(),
            flags: BTreeSet::new(),
            snippet: String::new(),
            has_attachments: false,
            message_id: None,
            in_reply_to: Vec::new(),
            references: Vec::new(),
        };
        let mut envelopes = vec![envelope(301), envelope(500), envelope(402)];
        sort_envelopes_newest_first(&mut envelopes);
        assert_eq!(
            envelopes
                .into_iter()
                .map(|item| item.uid)
                .collect::<Vec<_>>(),
            vec![500, 402, 301]
        );
    }

    #[test]
    fn smtp_authentication_failures_request_account_reauthorization() {
        let error = smtp_provider_error(SmtpError {
            reason: "SMTP authorization failed".into(),
            authentication: true,
        });
        assert!(matches!(error, ProviderError::Authentication(_)));
    }

    #[test]
    fn rfc_references_produce_stable_account_scoped_threads() {
        let none = Vec::new();
        let root = imap_thread_id("account-a", Some("root@example.com"), &none, &none);
        let reply = imap_thread_id(
            "account-a",
            Some("reply@example.com"),
            &["root@example.com".into()],
            &["root@example.com".into()],
        );
        let nested_reply = imap_thread_id(
            "account-a",
            Some("nested@example.com"),
            &["root@example.com".into(), "reply@example.com".into()],
            &["reply@example.com".into()],
        );
        assert_eq!(root, reply);
        assert_eq!(reply, nested_reply);
        assert_ne!(
            root,
            imap_thread_id("account-b", Some("root@example.com"), &none, &none)
        );
    }

    #[test]
    fn rfc_message_id_normalization_handles_quoted_local_parts() {
        assert_eq!(
            canonical_rfc_message_id("<\"01KF8JCEOCBS0045PS\"@XXX.YYY.COM>"),
            Some("01KF8JCEOCBS0045PS@xxx.yyy.com".into())
        );
        assert_eq!(canonical_rfc_message_id("not-a-message-id"), None);
    }

    #[test]
    fn auth_debug_never_exposes_credentials() {
        let auth = ImapAuthentication::Password {
            username: "alice@example.com".into(),
            password: SecretString::new("correct horse battery staple"),
        };
        let debug = format!("{auth:?}");
        assert!(!debug.contains("correct horse"));
        assert!(debug.contains("[REDACTED]"));
    }

    #[test]
    fn smtp_data_dot_stuffs_each_line_and_removes_terminal_newline() {
        assert_eq!(
            dot_stuff(b"first\r\n.second\r\n..third\r\n"),
            b"first\r\n..second\r\n...third"
        );
    }

    #[tokio::test]
    async fn smtp_parser_accepts_bounded_multiline_responses() {
        let (client, mut server) = tokio::io::duplex(256);
        let writer = tokio::spawn(async move {
            server
                .write_all(b"250-mail.example\r\n250-PIPELINING\r\n250 AUTH XOAUTH2\r\n")
                .await
                .unwrap();
        });
        let mut client = BufStream::new(client);
        expect_smtp(&mut client, 250).await.unwrap();
        writer.await.unwrap();
    }

    #[tokio::test]
    async fn smtp_parser_rejects_auth_failure_without_returning_server_text() {
        let (client, mut server) = tokio::io::duplex(128);
        let writer = tokio::spawn(async move {
            server
                .write_all(b"535 5.7.8 token-content-must-not-escape\r\n")
                .await
                .unwrap();
        });
        let mut client = BufStream::new(client);
        let error = expect_smtp(&mut client, 235).await.unwrap_err().to_string();
        assert!(!error.contains("token-content"));
        writer.await.unwrap();
    }

    #[tokio::test]
    async fn stalled_imap_response_hits_hard_deadline() {
        let (mut client, _stalled_server) = tokio::io::duplex(64);
        let result = bounded_imap(Duration::from_millis(20), async move {
            let mut byte = [0u8; 1];
            client
                .read_exact(&mut byte)
                .await
                .map_err(|error| ImapError::Connection(error.to_string()))?;
            Ok(())
        })
        .await;
        assert!(matches!(result, Err(ImapError::CommandTimeout)));
    }

    #[test]
    fn foreground_summary_fetch_is_headers_only_and_bounded_by_uid_page() {
        assert!(IMAP_SUMMARY_FETCH.contains("HEADER.FIELDS"));
        assert!(IMAP_SUMMARY_FETCH.contains("IN-REPLY-TO REFERENCES"));
        assert!(!IMAP_SUMMARY_FETCH.contains("BODY.PEEK[TEXT]"));
        assert_eq!(newest_uid_page((1..=10_000).collect(), 0, 201).len(), 201);
    }

    #[test]
    fn full_message_fetch_is_partial_and_enforces_the_declared_size() {
        let query = bounded_raw_fetch_query(MAX_MAIL_MESSAGE_BYTES);
        assert_eq!(
            query,
            format!(
                "(UID FLAGS RFC822.SIZE BODY.PEEK[]<0.{}>)",
                MAX_MAIL_MESSAGE_BYTES + 1
            )
        );
        assert!(!query.contains("BODY.PEEK[])"));
        assert!(validate_raw_message_size(MAX_MAIL_MESSAGE_BYTES, MAX_MAIL_MESSAGE_BYTES).is_ok());
        assert!(matches!(
            validate_raw_message_size(MAX_MAIL_MESSAGE_BYTES + 1, MAX_MAIL_MESSAGE_BYTES),
            Err(ImapError::MessageTooLarge)
        ));
        assert!(matches!(
            provider_error(ImapError::MessageTooLarge),
            ProviderError::ResourceTooLarge("message")
        ));
    }
}
