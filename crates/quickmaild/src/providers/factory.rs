use std::{sync::Arc, time::Duration};

use async_trait::async_trait;
use quickmail_core::{Account, AccountAddParams, MailProvider, MailServerSetup, ProviderError};
use serde_json::Value;
use uuid::Uuid;

use crate::daemon::ProviderFactory;

use super::{
    auth::{GoaMailAccount, GoaProviderFamily, GoaTokenSource, TokenSource},
    imap_smtp::{
        AsyncImapTransport, ConnectionSecurity, ImapAuthentication, ImapSmtpConfig,
        ImapSmtpProvider, LettreSmtpTransport, Xoauth2SmtpTransport,
    },
    microsoft_graph::{MicrosoftGraphProvider, ReqwestGraphTransport},
    mime::ProductionMimeCodec,
};

const KEYRING_SERVICE: &str = "io.github.MaxGiuP.QuickMail";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ProviderRoute {
    GoogleGoa,
    MicrosoftGoa,
    PasswordImap,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum MicrosoftGoaTransport {
    Graph,
    LegacyImap,
}

fn microsoft_goa_transport(provider_type: &str) -> Result<MicrosoftGoaTransport, ProviderError> {
    if provider_type.eq_ignore_ascii_case("ms_graph") {
        Ok(MicrosoftGoaTransport::Graph)
    } else if provider_type.eq_ignore_ascii_case("windows_live") {
        Ok(MicrosoftGoaTransport::LegacyImap)
    } else {
        Err(ProviderError::Unsupported(
            "GNOME Online Accounts exposed an unknown Microsoft mail transport".into(),
        ))
    }
}

fn provider_route(provider: &str) -> ProviderRoute {
    match provider.trim().to_ascii_lowercase().as_str() {
        "gmail" => ProviderRoute::GoogleGoa,
        "outlook" | "hotmail" | "microsoft365" => ProviderRoute::MicrosoftGoa,
        _ => ProviderRoute::PasswordImap,
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum GoaInteraction {
    Interactive,
    SilentRestore,
}

impl GoaInteraction {
    const fn allows_ui(self) -> bool {
        matches!(self, Self::Interactive)
    }
}

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

    async fn authorized_goa(
        email: &str,
        family: GoaProviderFamily,
        interaction: GoaInteraction,
    ) -> Result<GoaMailAccount, ProviderError> {
        let mut opened = false;
        for _ in 0..300 {
            if let Some(account) = GoaMailAccount::discover(email, family)
                .await
                .map_err(auth_error)?
            {
                let source = GoaTokenSource::new(&account);
                if source.access_token(false).await.is_ok() {
                    return Ok(account);
                }
                if interaction.allows_ui() && !opened {
                    account.launch_control_center().map_err(auth_error)?;
                    opened = true;
                }
            } else if interaction.allows_ui() && !opened {
                GoaMailAccount::launch_add(family).map_err(auth_error)?;
                opened = true;
            }
            if !interaction.allows_ui() {
                return Err(ProviderError::Authentication(format!(
                    "{} account needs authorization in GNOME Online Accounts",
                    family.display_name()
                )));
            }
            tokio::time::sleep(Duration::from_secs(1)).await;
        }
        Err(ProviderError::Authentication(format!(
            "{} Online Accounts authorization timed out",
            family.display_name()
        )))
    }

    async fn goa_mail_provider(
        account: Account,
        family: GoaProviderFamily,
        interaction: GoaInteraction,
    ) -> Result<Arc<dyn MailProvider>, ProviderError> {
        let goa = Self::authorized_goa(&account.address, family, interaction).await?;
        Self::goa_imap_provider(account, goa).await
    }

    async fn goa_imap_provider(
        account: Account,
        goa: GoaMailAccount,
    ) -> Result<Arc<dyn MailProvider>, ProviderError> {
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

    async fn microsoft_provider(
        mut account: Account,
        interaction: GoaInteraction,
    ) -> Result<Arc<dyn MailProvider>, ProviderError> {
        let goa = Self::authorized_goa(&account.address, GoaProviderFamily::Microsoft, interaction)
            .await?;
        if goa.mail_disabled {
            return Err(ProviderError::Unsupported(
                "Mail is disabled for this Microsoft account in GNOME Online Accounts".into(),
            ));
        }
        match microsoft_goa_transport(&goa.provider_type)? {
            MicrosoftGoaTransport::Graph => {
                account.protocol = "microsoft_graph".into();
                let transport = Arc::new(ReqwestGraphTransport::new()?);
                let tokens = Arc::new(GoaTokenSource::new(&goa));
                Ok(Arc::new(MicrosoftGraphProvider::new(
                    account, transport, tokens,
                )))
            }
            MicrosoftGoaTransport::LegacyImap => {
                // Older windows_live GOA providers can still expose genuine
                // secure IMAP/SMTP XOAUTH2. Keep that transport only when its
                // Mail properties pass the existing capability gate.
                account.protocol = "imap_xoauth2".into();
                Self::goa_imap_provider(account, goa).await
            }
        }
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
            address: setup.address.trim().to_owned(),
            display_name: setup.display_name,
            provider: setup.provider.clone(),
            protocol: setup.provider.clone(),
            host: String::new(),
            unread: 0,
            total: 0,
            enabled: true,
        };
        match provider_route(&setup.provider) {
            ProviderRoute::GoogleGoa => {
                Self::goa_mail_provider(
                    account,
                    GoaProviderFamily::Google,
                    GoaInteraction::Interactive,
                )
                .await
            }
            ProviderRoute::MicrosoftGoa => {
                Self::microsoft_provider(account, GoaInteraction::Interactive).await
            }
            ProviderRoute::PasswordImap => {
                Self::imap_provider(
                    account,
                    setup.imap.ok_or_else(|| {
                        ProviderError::Other("IMAP configuration is required".into())
                    })?,
                    setup.smtp.ok_or_else(|| {
                        ProviderError::Other("SMTP configuration is required".into())
                    })?,
                    true,
                )
                .await
            }
        }
    }

    async fn restore(
        &self,
        account: &Account,
        config: &Value,
    ) -> Result<Arc<dyn MailProvider>, ProviderError> {
        match provider_route(&account.provider) {
            ProviderRoute::GoogleGoa => {
                return Self::goa_mail_provider(
                    account.clone(),
                    GoaProviderFamily::Google,
                    GoaInteraction::SilentRestore,
                )
                .await;
            }
            ProviderRoute::MicrosoftGoa => {
                return Self::microsoft_provider(account.clone(), GoaInteraction::SilentRestore)
                    .await;
            }
            ProviderRoute::PasswordImap => {}
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
        match provider_route(&account.provider) {
            ProviderRoute::GoogleGoa => {
                Self::goa_mail_provider(
                    account.clone(),
                    GoaProviderFamily::Google,
                    GoaInteraction::Interactive,
                )
                .await
            }
            ProviderRoute::MicrosoftGoa => {
                Self::microsoft_provider(account.clone(), GoaInteraction::Interactive).await
            }
            ProviderRoute::PasswordImap => self.restore(account, config).await,
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn provider_aliases_route_only_brokered_microsoft_accounts_to_goa() {
        assert_eq!(provider_route("gmail"), ProviderRoute::GoogleGoa);
        for alias in ["outlook", "HOTMAIL", " Microsoft365 "] {
            assert_eq!(provider_route(alias), ProviderRoute::MicrosoftGoa);
        }
        for manual in ["exchange", "imap", "custom"] {
            assert_eq!(provider_route(manual), ProviderRoute::PasswordImap);
        }
    }

    #[test]
    fn restore_mode_cannot_launch_online_accounts() {
        assert!(!GoaInteraction::SilentRestore.allows_ui());
        assert!(GoaInteraction::Interactive.allows_ui());
    }

    #[test]
    fn current_microsoft_goa_uses_graph_and_legacy_windows_live_uses_imap() {
        assert_eq!(
            microsoft_goa_transport("MS_GRAPH").unwrap(),
            MicrosoftGoaTransport::Graph
        );
        assert_eq!(
            microsoft_goa_transport("windows_live").unwrap(),
            MicrosoftGoaTransport::LegacyImap
        );
        assert!(microsoft_goa_transport("exchange").is_err());
    }
}
