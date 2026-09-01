use std::{sync::Arc, time::Duration};

use async_trait::async_trait;
use quickmail_core::{Account, AccountAddParams, MailProvider, MailServerSetup, ProviderError};
use serde_json::Value;
use uuid::Uuid;

use crate::daemon::ProviderFactory;

use super::{
    auth::{GoaMailAccount, GoaTokenSource, TokenSource},
    imap_smtp::{
        AsyncImapTransport, ConnectionSecurity, ImapAuthentication, ImapSmtpConfig,
        ImapSmtpProvider, LettreSmtpTransport, Xoauth2SmtpTransport,
    },
    mime::ProductionMimeCodec,
};

const KEYRING_SERVICE: &str = "io.github.MaxGiuP.QuickMail";

pub struct ProductionProviderFactory;

impl Default for ProductionProviderFactory {
    fn default() -> Self {
        Self::new()
    }
}

impl ProductionProviderFactory {
    pub fn new() -> Self {
        Self
    }

    async fn authorized_goa(email: &str, open_ui: bool) -> Result<GoaMailAccount, ProviderError> {
        let mut opened = false;
        for _ in 0..300 {
            if let Some(account) = GoaMailAccount::discover_google(email)
                .await
                .map_err(auth_error)?
            {
                let source = GoaTokenSource::new(&account);
                if source.access_token(false).await.is_ok() {
                    return Ok(account);
                }
                if open_ui && !opened {
                    account.launch_control_center().map_err(auth_error)?;
                    opened = true;
                }
            } else if open_ui && !opened {
                GoaMailAccount::launch_add_google().map_err(auth_error)?;
                opened = true;
            }
            if !open_ui {
                return Err(ProviderError::Authentication(
                    "Google account needs authorization in Online Accounts".into(),
                ));
            }
            tokio::time::sleep(Duration::from_secs(1)).await;
        }
        Err(ProviderError::Authentication(
            "Google Online Accounts authorization timed out".into(),
        ))
    }

    async fn gmail_provider(
        account: Account,
        open_ui: bool,
    ) -> Result<Arc<dyn MailProvider>, ProviderError> {
        let goa = Self::authorized_goa(&account.address, open_ui).await?;
        let settings = goa.mail_settings().await.map_err(auth_error)?;
        let tokens = Arc::new(GoaTokenSource::new(&goa));
        let imap_security = if settings.imap_implicit_tls {
            ConnectionSecurity::ImplicitTls
        } else {
            ConnectionSecurity::StartTls
        };
        let smtp_security = if settings.smtp_implicit_tls {
            ConnectionSecurity::ImplicitTls
        } else {
            ConnectionSecurity::StartTls
        };
        let config = ImapSmtpConfig {
            imap_host: settings.imap_host.clone(),
            imap_port: settings.imap_port,
            imap_security,
            smtp_host: settings.smtp_host.clone(),
            smtp_port: settings.smtp_port,
            smtp_security,
            imap_authentication: ImapAuthentication::OAuthSource {
                username: settings.imap_username,
                tokens: tokens.clone(),
            },
            smtp_authentication: ImapAuthentication::OAuthSource {
                username: settings.smtp_username.clone(),
                tokens: tokens.clone(),
            },
            discover_special_use: true,
            archive_mailbox: None,
            trash_mailbox: None,
        };
        let imap = Arc::new(
            AsyncImapTransport::new(config.clone())
                .map_err(|error| ProviderError::Other(error.to_string()))?,
        );
        let smtp = Arc::new(
            Xoauth2SmtpTransport::new(
                settings.smtp_host,
                settings.smtp_port,
                smtp_security,
                settings.smtp_username,
                tokens,
            )
            .map_err(|error| ProviderError::Other(error.to_string()))?,
        );
        let provider = ImapSmtpProvider::new(account, config, imap, smtp, ProductionMimeCodec)
            .map_err(|error| ProviderError::Other(error.to_string()))?;
        Ok(Arc::new(provider))
    }

    async fn imap_provider(
        account: Account,
        imap: MailServerSetup,
        smtp: MailServerSetup,
        store_secrets: bool,
    ) -> Result<Arc<dyn MailProvider>, ProviderError> {
        let imap_security = security(&imap.security)?;
        let smtp_security = security(&smtp.security)?;
        let imap_password = if store_secrets {
            store_secret(&account.id, "imap-password", &imap.password).await?;
            imap.password
        } else {
            load_secret(&account.id, "imap-password").await?
        };
        let smtp_password = if store_secrets {
            if let Err(error) = store_secret(&account.id, "smtp-password", &smtp.password).await {
                return match delete_secret(&account.id, "imap-password").await {
                    Ok(()) => Err(error),
                    Err(cleanup_error) => Err(ProviderError::Other(format!(
                        "{error}; additionally, {cleanup_error}"
                    ))),
                };
            }
            smtp.password
        } else {
            load_secret(&account.id, "smtp-password").await?
        };
        let config = ImapSmtpConfig {
            imap_host: imap.host,
            imap_port: imap.port,
            imap_security,
            smtp_host: smtp.host,
            smtp_port: smtp.port,
            smtp_security,
            imap_authentication: ImapAuthentication::Password {
                username: imap.username,
                password: super::auth::SecretString::new(imap_password),
            },
            smtp_authentication: ImapAuthentication::Password {
                username: smtp.username,
                password: super::auth::SecretString::new(smtp_password),
            },
            discover_special_use: true,
            archive_mailbox: Some("Archive".into()),
            trash_mailbox: Some("Trash".into()),
        };
        let account_id = account.id.clone();
        let result = (|| -> Result<Arc<dyn MailProvider>, ProviderError> {
            let imap_transport = Arc::new(
                AsyncImapTransport::new(config.clone())
                    .map_err(|error| ProviderError::Other(error.to_string()))?,
            );
            let smtp_transport = Arc::new(
                LettreSmtpTransport::new(&config)
                    .map_err(|error| ProviderError::Other(error.to_string()))?,
            );
            let provider = ImapSmtpProvider::new(
                account,
                config,
                imap_transport,
                smtp_transport,
                ProductionMimeCodec,
            )
            .map_err(|error| ProviderError::Other(error.to_string()))?;
            Ok(Arc::new(provider))
        })();
        match result {
            Err(provider_error) if store_secrets => {
                match cleanup_account_secrets(&account_id).await {
                    Ok(()) => Err(provider_error),
                    Err(cleanup_error) => Err(ProviderError::Other(format!(
                        "{provider_error}; additionally, {cleanup_error}"
                    ))),
                }
            }
            other => other,
        }
    }
}

#[async_trait]
impl ProviderFactory for ProductionProviderFactory {
    async fn create(
        &self,
        setup: AccountAddParams,
    ) -> Result<Arc<dyn MailProvider>, ProviderError> {
        let account = Account {
            id: Uuid::new_v4().to_string(),
            address: setup.address.clone(),
            display_name: setup.display_name,
            provider: setup.provider.clone(),
            protocol: setup.provider.clone(),
            host: String::new(),
            unread: 0,
            total: 0,
            enabled: true,
        };
        if setup.provider.eq_ignore_ascii_case("gmail") {
            Self::gmail_provider(account, true).await
        } else {
            Self::imap_provider(
                account,
                setup
                    .imap
                    .ok_or_else(|| ProviderError::Other("IMAP configuration is required".into()))?,
                setup
                    .smtp
                    .ok_or_else(|| ProviderError::Other("SMTP configuration is required".into()))?,
                true,
            )
            .await
        }
    }

    async fn restore(
        &self,
        account: &Account,
        config: &Value,
    ) -> Result<Arc<dyn MailProvider>, ProviderError> {
        if account.provider.eq_ignore_ascii_case("gmail") {
            return Self::gmail_provider(account.clone(), false).await;
        }
        let imap = serde_json::from_value(config.get("imap").cloned().unwrap_or(Value::Null))
            .map_err(|_| ProviderError::Other("stored IMAP configuration is invalid".into()))?;
        let smtp = serde_json::from_value(config.get("smtp").cloned().unwrap_or(Value::Null))
            .map_err(|_| ProviderError::Other("stored SMTP configuration is invalid".into()))?;
        Self::imap_provider(account.clone(), imap, smtp, false).await
    }

    async fn reauthorize(
        &self,
        account: &Account,
        config: &Value,
    ) -> Result<Arc<dyn MailProvider>, ProviderError> {
        if account.provider.eq_ignore_ascii_case("gmail") {
            Self::gmail_provider(account.clone(), true).await
        } else {
            self.restore(account, config).await
        }
    }

    async fn remove(&self, account_id: &str) -> Result<(), ProviderError> {
        cleanup_account_secrets(account_id).await
    }
}

fn security(value: &str) -> Result<ConnectionSecurity, ProviderError> {
    match value.to_ascii_lowercase().as_str() {
        "tls" | "ssl" | "implicit_tls" | "implicit-tls" => Ok(ConnectionSecurity::ImplicitTls),
        "starttls" | "start_tls" | "start-tls" => Ok(ConnectionSecurity::StartTls),
        _ => Err(ProviderError::Unsupported(
            "unencrypted mail server connections are not supported".into(),
        )),
    }
}

async fn store_secret(account_id: &str, purpose: &str, secret: &str) -> Result<(), ProviderError> {
    let entry = keyring::Entry::new(KEYRING_SERVICE, &format!("{account_id}:{purpose}"))
        .map_err(|_| ProviderError::Other("credential store unavailable".into()))?;
    let secret = secret.to_owned();
    tokio::task::spawn_blocking(move || entry.set_password(&secret))
        .await
        .map_err(|_| ProviderError::Other("credential store unavailable".into()))?
        .map_err(|_| ProviderError::Other("credential store unavailable".into()))
}

async fn load_secret(account_id: &str, purpose: &str) -> Result<String, ProviderError> {
    let entry = keyring::Entry::new(KEYRING_SERVICE, &format!("{account_id}:{purpose}"))
        .map_err(|_| ProviderError::Other("credential store unavailable".into()))?;
    tokio::task::spawn_blocking(move || entry.get_password())
        .await
        .map_err(|_| ProviderError::Other("credential store unavailable".into()))?
        .map_err(|_| ProviderError::Authentication("mail server password is missing".into()))
}

async fn delete_secret(account_id: &str, purpose: &str) -> Result<(), ProviderError> {
    let entry = keyring::Entry::new(KEYRING_SERVICE, &format!("{account_id}:{purpose}"))
        .map_err(|_| ProviderError::Other("credential store unavailable".into()))?;
    match tokio::task::spawn_blocking(move || entry.delete_credential()).await {
        Ok(Ok(())) | Ok(Err(keyring::Error::NoEntry)) => Ok(()),
        Ok(Err(_)) | Err(_) => Err(ProviderError::Other(
            "could not remove account credentials".into(),
        )),
    }
}

async fn cleanup_account_secrets(account_id: &str) -> Result<(), ProviderError> {
    let mut first_error = None;
    for purpose in ["imap-password", "smtp-password"] {
        if let Err(error) = delete_secret(account_id, purpose).await
            && first_error.is_none()
        {
            first_error = Some(error);
        }
    }
    first_error.map_or(Ok(()), Err)
}

fn auth_error(error: super::auth::TokenError) -> ProviderError {
    ProviderError::Authentication(error.to_string())
}
