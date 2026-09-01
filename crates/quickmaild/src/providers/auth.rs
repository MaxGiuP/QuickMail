use std::{fmt, time::Duration};

use async_trait::async_trait;
use chrono::{DateTime, Utc};
use thiserror::Error;
use zbus::fdo::ObjectManagerProxy;

/// Secret text which is always redacted from debug output.
///
/// This type intentionally does not implement `Serialize`, `Display`, or
/// `AsRef<str>` so credentials cannot accidentally cross RPC or log boundaries.
#[derive(Clone, PartialEq, Eq)]
pub(crate) struct SecretString(String);

impl SecretString {
    pub(crate) fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    pub(crate) fn expose_secret(&self) -> &str {
        &self.0
    }

    pub(crate) fn is_empty(&self) -> bool {
        self.0.is_empty()
    }
}

impl fmt::Debug for SecretString {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("SecretString([REDACTED])")
    }
}

#[derive(Clone)]
pub(crate) struct AccessToken {
    pub(crate) value: SecretString,
    pub(crate) expires_at: Option<DateTime<Utc>>,
}

impl fmt::Debug for AccessToken {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("AccessToken")
            .field("value", &"[REDACTED]")
            .field("expires_at", &self.expires_at)
            .finish()
    }
}

#[derive(Debug, Error)]
pub(crate) enum TokenError {
    #[error("the credential store is unavailable")]
    StoreUnavailable,
    #[error("authorization is required")]
    AuthorizationRequired,
    #[error("the token endpoint rejected the refresh request")]
    RefreshRejected,
    #[error("token acquisition failed: {0}")]
    Other(String),
}

/// Supplies short-lived access tokens without exposing refresh tokens to a
/// provider adapter.
#[async_trait]
pub(crate) trait TokenSource: Send + Sync {
    async fn access_token(&self, force_refresh: bool) -> Result<AccessToken, TokenError>;
}

const GOA_DESTINATION: &str = "org.gnome.OnlineAccounts";
const GOA_ROOT: &str = "/org/gnome/OnlineAccounts";

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct GoaMailAccount {
    pub(crate) id: String,
    pub(crate) object_path: String,
    pub(crate) email: String,
    pub(crate) attention_needed: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct GoaMailSettings {
    pub(crate) imap_host: String,
    pub(crate) imap_port: u16,
    pub(crate) imap_implicit_tls: bool,
    pub(crate) imap_username: String,
    pub(crate) smtp_host: String,
    pub(crate) smtp_port: u16,
    pub(crate) smtp_implicit_tls: bool,
    pub(crate) smtp_username: String,
}

impl GoaMailAccount {
    pub(crate) async fn discover_google(email: &str) -> Result<Option<Self>, TokenError> {
        let connection = zbus::Connection::session()
            .await
            .map_err(|_| TokenError::StoreUnavailable)?;
        let manager = ObjectManagerProxy::builder(&connection)
            .destination(GOA_DESTINATION)
            .and_then(|builder| builder.path(GOA_ROOT))
            .map_err(|_| TokenError::StoreUnavailable)?
            .build()
            .await
            .map_err(|_| TokenError::StoreUnavailable)?;
        let objects = manager
            .get_managed_objects()
            .await
            .map_err(|_| TokenError::StoreUnavailable)?;
        for (path, interfaces) in &objects {
            if !is_goa_mail_account(interfaces.keys().map(|name| name.as_str())) {
                continue;
            }
            let account = zbus::Proxy::new(
                &connection,
                GOA_DESTINATION,
                path.as_str(),
                "org.gnome.OnlineAccounts.Account",
            )
            .await
            .map_err(|_| TokenError::StoreUnavailable)?;
            let provider_type: String = match account.get_property("ProviderType").await {
                Ok(value) => value,
                Err(_) => continue,
            };
            if !provider_type.eq_ignore_ascii_case("google") {
                continue;
            }
            let mail = zbus::Proxy::new(
                &connection,
                GOA_DESTINATION,
                path.as_str(),
                "org.gnome.OnlineAccounts.Mail",
            )
            .await;
            let Ok(mail) = mail else { continue };
            let discovered_email: String = match mail.get_property("EmailAddress").await {
                Ok(value) => value,
                Err(_) => continue,
            };
            if !discovered_email.eq_ignore_ascii_case(email) {
                continue;
            }
            return Ok(Some(Self {
                id: path
                    .as_str()
                    .rsplit('/')
                    .next()
                    .unwrap_or_default()
                    .to_owned(),
                object_path: path.as_str().to_owned(),
                email: discovered_email,
                attention_needed: account
                    .get_property("AttentionNeeded")
                    .await
                    .unwrap_or(false),
            }));
        }
        Ok(None)
    }

    /// Opens the exact GOA panel flow without a shell and without putting an
    /// email address or credential on the process command line.
    pub(crate) fn launch_control_center(&self) -> Result<(), TokenError> {
        std::process::Command::new("gnome-control-center")
            .args(["online-accounts", self.id.as_str()])
            .spawn()
            .map(|_| ())
            .map_err(|_| TokenError::AuthorizationRequired)
    }

    pub(crate) fn launch_add_google() -> Result<(), TokenError> {
        std::process::Command::new("gnome-control-center")
            .args(["online-accounts", "add", "google"])
            .spawn()
            .map(|_| ())
            .map_err(|_| TokenError::AuthorizationRequired)
    }

    pub(crate) async fn mail_settings(&self) -> Result<GoaMailSettings, TokenError> {
        let connection = zbus::Connection::session()
            .await
            .map_err(|_| TokenError::StoreUnavailable)?;
        let mail = zbus::Proxy::new(
            &connection,
            GOA_DESTINATION,
            self.object_path.as_str(),
            "org.gnome.OnlineAccounts.Mail",
        )
        .await
        .map_err(|_| TokenError::StoreUnavailable)?;
        let account = zbus::Proxy::new(
            &connection,
            GOA_DESTINATION,
            self.object_path.as_str(),
            "org.gnome.OnlineAccounts.Account",
        )
        .await
        .map_err(|_| TokenError::StoreUnavailable)?;
        let mail_disabled: bool = account.get_property("MailDisabled").await.unwrap_or(false);
        let imap_supported: bool = mail.get_property("ImapSupported").await.unwrap_or(false);
        let smtp_supported: bool = mail.get_property("SmtpSupported").await.unwrap_or(false);
        let smtp_xoauth2: bool = mail.get_property("SmtpAuthXoauth2").await.unwrap_or(false);
        if mail_disabled || !imap_supported || !smtp_supported || !smtp_xoauth2 {
            return Err(TokenError::Other(
                "GOA account does not expose enabled IMAP/SMTP XOAUTH2".into(),
            ));
        }
        let imap_host: String = mail
            .get_property("ImapHost")
            .await
            .map_err(|_| TokenError::StoreUnavailable)?;
        let imap_username: String = mail
            .get_property("ImapUserName")
            .await
            .map_err(|_| TokenError::StoreUnavailable)?;
        let imap_implicit_tls: bool = mail.get_property("ImapUseSsl").await.unwrap_or(false);
        let imap_starttls: bool = mail.get_property("ImapUseTls").await.unwrap_or(false);
        let smtp_host: String = mail
            .get_property("SmtpHost")
            .await
            .map_err(|_| TokenError::StoreUnavailable)?;
        let smtp_username: String = mail
            .get_property("SmtpUserName")
            .await
            .map_err(|_| TokenError::StoreUnavailable)?;
        let smtp_implicit_tls: bool = mail.get_property("SmtpUseSsl").await.unwrap_or(false);
        let smtp_starttls: bool = mail.get_property("SmtpUseTls").await.unwrap_or(false);
        if (!imap_implicit_tls && !imap_starttls) || (!smtp_implicit_tls && !smtp_starttls) {
            return Err(TokenError::Other(
                "GOA mail transport is not configured for TLS".into(),
            ));
        }
        let (imap_host, imap_port) =
            split_host_port(&imap_host, if imap_implicit_tls { 993 } else { 143 })?;
        let (smtp_host, smtp_port) =
            split_host_port(&smtp_host, if smtp_implicit_tls { 465 } else { 587 })?;
        Ok(GoaMailSettings {
            imap_host,
            imap_port,
            imap_implicit_tls,
            imap_username,
            smtp_host,
            smtp_port,
            smtp_implicit_tls,
            smtp_username,
        })
    }
}

fn is_goa_mail_account<'a>(interfaces: impl IntoIterator<Item = &'a str>) -> bool {
    let mut account = false;
    let mut mail = false;
    for interface in interfaces {
        account |= interface == "org.gnome.OnlineAccounts.Account";
        mail |= interface == "org.gnome.OnlineAccounts.Mail";
    }
    account && mail
}

#[derive(Clone)]
pub(crate) struct GoaTokenSource {
    object_path: String,
}

impl GoaTokenSource {
    pub(crate) fn new(account: &GoaMailAccount) -> Self {
        Self {
            object_path: account.object_path.clone(),
        }
    }
}

#[async_trait]
impl TokenSource for GoaTokenSource {
    async fn access_token(&self, _force_refresh: bool) -> Result<AccessToken, TokenError> {
        let connection = zbus::Connection::session()
            .await
            .map_err(|_| TokenError::StoreUnavailable)?;
        let account = zbus::Proxy::new(
            &connection,
            GOA_DESTINATION,
            self.object_path.as_str(),
            "org.gnome.OnlineAccounts.Account",
        )
        .await
        .map_err(|_| TokenError::StoreUnavailable)?;
        let attention_needed: bool = account
            .get_property("AttentionNeeded")
            .await
            .unwrap_or(true);
        if attention_needed {
            return Err(TokenError::AuthorizationRequired);
        }
        tokio::time::timeout(
            Duration::from_secs(15),
            account.call::<_, _, i32>("EnsureCredentials", &()),
        )
        .await
        .map_err(|_| TokenError::StoreUnavailable)?
        .map_err(|_| TokenError::AuthorizationRequired)?;
        let oauth = zbus::Proxy::new(
            &connection,
            GOA_DESTINATION,
            self.object_path.as_str(),
            "org.gnome.OnlineAccounts.OAuth2Based",
        )
        .await
        .map_err(|_| TokenError::StoreUnavailable)?;
        let (token, expires_in): (String, i32) =
            tokio::time::timeout(Duration::from_secs(15), oauth.call("GetAccessToken", &()))
                .await
                .map_err(|_| TokenError::StoreUnavailable)?
                .map_err(|_| TokenError::AuthorizationRequired)?;
        Ok(AccessToken {
            value: SecretString::new(token),
            expires_at: (expires_in > 0)
                .then(|| Utc::now() + chrono::Duration::seconds(i64::from(expires_in))),
        })
    }
}

fn split_host_port(host: &str, default_port: u16) -> Result<(String, u16), TokenError> {
    if host.is_empty() || host.contains(['\r', '\n', '\0']) {
        return Err(TokenError::Other(
            "GOA returned an invalid mail host".into(),
        ));
    }
    if let Some((name, port)) = host.rsplit_once(':')
        && !name.contains(':')
        && let Ok(port) = port.parse::<u16>()
        && port > 0
    {
        return Ok((name.to_owned(), port));
    }
    Ok((host.to_owned(), default_port))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn debug_output_redacts_every_secret() {
        let debug = format!("{:?}", SecretString::new("authorization-secret"));
        assert!(!debug.contains("authorization-secret"));
        assert!(debug.contains("[REDACTED]"));
    }

    #[test]
    fn goa_discovery_skips_manager_and_incomplete_objects() {
        assert!(!is_goa_mail_account(["org.gnome.OnlineAccounts.Manager"]));
        assert!(!is_goa_mail_account(["org.gnome.OnlineAccounts.Account"]));
        assert!(is_goa_mail_account([
            "org.gnome.OnlineAccounts.Account",
            "org.gnome.OnlineAccounts.Mail",
            "org.gnome.OnlineAccounts.OAuth2Based",
        ]));
    }
}
