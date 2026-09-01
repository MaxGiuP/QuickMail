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
    #[error("{0}")]
    UnsupportedMailTransport(String),
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

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum GoaProviderFamily {
    Google,
    Microsoft,
}

impl GoaProviderFamily {
    pub(crate) const fn add_provider_type(self) -> &'static str {
        match self {
            Self::Google => "google",
            Self::Microsoft => "ms_graph",
        }
    }

    pub(crate) const fn display_name(self) -> &'static str {
        match self {
            Self::Google => "Google",
            Self::Microsoft => "Microsoft",
        }
    }

    fn matches_provider_type(self, provider_type: &str) -> bool {
        match self {
            Self::Google => provider_type.eq_ignore_ascii_case("google"),
            Self::Microsoft => {
                provider_type.eq_ignore_ascii_case("ms_graph")
                    || provider_type.eq_ignore_ascii_case("windows_live")
            }
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct GoaMailAccount {
    pub(crate) id: String,
    pub(crate) object_path: String,
    pub(crate) provider_type: String,
    pub(crate) email: String,
    pub(crate) mail_disabled: bool,
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
    pub(crate) async fn discover(
        email: &str,
        family: GoaProviderFamily,
    ) -> Result<Option<Self>, TokenError> {
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
            if !is_goa_oauth_mail_account(interfaces.keys().map(|name| name.as_str())) {
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
            if !family.matches_provider_type(&provider_type) {
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
            let discovered_email: String =
                mail.get_property("EmailAddress").await.unwrap_or_default();
            let identity: String = account.get_property("Identity").await.unwrap_or_default();
            let presentation_identity: String = account
                .get_property("PresentationIdentity")
                .await
                .unwrap_or_default();
            if !goa_identity_matches(
                email,
                [
                    discovered_email.as_str(),
                    identity.as_str(),
                    presentation_identity.as_str(),
                ],
            ) {
                continue;
            }
            let Some(mail_address) =
                preferred_mail_address(email, &presentation_identity, &discovered_email)
            else {
                continue;
            };
            return Ok(Some(Self {
                id: path
                    .as_str()
                    .rsplit('/')
                    .next()
                    .unwrap_or_default()
                    .to_owned(),
                object_path: path.as_str().to_owned(),
                provider_type,
                email: mail_address,
                mail_disabled: account.get_property("MailDisabled").await.unwrap_or(false),
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

    pub(crate) fn launch_add(family: GoaProviderFamily) -> Result<(), TokenError> {
        std::process::Command::new("gnome-control-center")
            .args(["online-accounts", "add", family.add_provider_type()])
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
        let smtp_use_auth: bool = mail.get_property("SmtpUseAuth").await.unwrap_or(false);
        let smtp_xoauth2: bool = mail.get_property("SmtpAuthXoauth2").await.unwrap_or(false);
        validate_mail_capabilities(
            &self.provider_type,
            mail_disabled,
            imap_supported,
            smtp_supported,
            smtp_use_auth,
            smtp_xoauth2,
        )?;
        let imap_host: String = mail
            .get_property("ImapHost")
            .await
            .map_err(|_| TokenError::StoreUnavailable)?;
        let mut imap_username: String = mail
            .get_property("ImapUserName")
            .await
            .map_err(|_| TokenError::StoreUnavailable)?;
        if imap_username.trim().is_empty() {
            imap_username.clone_from(&self.email);
        }
        let imap_implicit_tls: bool = mail.get_property("ImapUseSsl").await.unwrap_or(false);
        let imap_starttls: bool = mail.get_property("ImapUseTls").await.unwrap_or(false);
        let smtp_host: String = mail
            .get_property("SmtpHost")
            .await
            .map_err(|_| TokenError::StoreUnavailable)?;
        let mut smtp_username: String = mail
            .get_property("SmtpUserName")
            .await
            .map_err(|_| TokenError::StoreUnavailable)?;
        if smtp_username.trim().is_empty() {
            smtp_username.clone_from(&self.email);
        }
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

fn is_goa_oauth_mail_account<'a>(interfaces: impl IntoIterator<Item = &'a str>) -> bool {
    let mut account = false;
    let mut mail = false;
    let mut oauth2 = false;
    for interface in interfaces {
        account |= interface == "org.gnome.OnlineAccounts.Account";
        mail |= interface == "org.gnome.OnlineAccounts.Mail";
        oauth2 |= interface == "org.gnome.OnlineAccounts.OAuth2Based";
    }
    account && mail && oauth2
}

fn goa_identity_matches<'a>(
    requested: &str,
    identities: impl IntoIterator<Item = &'a str>,
) -> bool {
    let requested = requested.trim();
    !requested.is_empty()
        && identities
            .into_iter()
            .any(|identity| identity.trim().eq_ignore_ascii_case(requested))
}

fn preferred_mail_address(
    requested: &str,
    presentation_identity: &str,
    discovered: &str,
) -> Option<String> {
    [requested, presentation_identity, discovered]
        .into_iter()
        .map(str::trim)
        .find(|candidate| is_syntactic_mail_address(candidate))
        .map(str::to_owned)
}

fn is_syntactic_mail_address(value: &str) -> bool {
    let value = value.trim();
    if value.is_empty() || value.len() > 320 || value.chars().any(char::is_whitespace) {
        return false;
    }
    let Some((local, domain)) = value.split_once('@') else {
        return false;
    };
    !local.is_empty() && !domain.is_empty() && !domain.contains('@')
}

fn validate_mail_capabilities(
    provider_type: &str,
    mail_disabled: bool,
    imap_supported: bool,
    smtp_supported: bool,
    smtp_use_auth: bool,
    smtp_xoauth2: bool,
) -> Result<(), TokenError> {
    if !mail_disabled && imap_supported && smtp_supported && smtp_use_auth && smtp_xoauth2 {
        return Ok(());
    }
    if provider_type.eq_ignore_ascii_case("ms_graph") {
        return Err(TokenError::UnsupportedMailTransport(
            "this Microsoft Online Account exposes mail through Microsoft Graph and must use QuickMail's Graph provider, not IMAP/SMTP XOAUTH2"
                .into(),
        ));
    }
    Err(TokenError::UnsupportedMailTransport(
        "GOA account does not expose enabled IMAP/SMTP XOAUTH2".into(),
    ))
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

        let token = AccessToken {
            value: SecretString::new("microsoft-access-token"),
            expires_at: None,
        };
        let debug = format!("{token:?}");
        assert!(!debug.contains("microsoft-access-token"));
        assert!(debug.contains("[REDACTED]"));
    }

    #[test]
    fn goa_discovery_skips_manager_and_incomplete_objects() {
        assert!(!is_goa_oauth_mail_account([
            "org.gnome.OnlineAccounts.Manager"
        ]));
        assert!(!is_goa_oauth_mail_account([
            "org.gnome.OnlineAccounts.Account",
            "org.gnome.OnlineAccounts.Mail",
        ]));
        assert!(is_goa_oauth_mail_account([
            "org.gnome.OnlineAccounts.Account",
            "org.gnome.OnlineAccounts.Mail",
            "org.gnome.OnlineAccounts.OAuth2Based",
        ]));
    }

    #[test]
    fn provider_and_identity_matching_is_narrow_and_case_insensitive() {
        assert!(GoaProviderFamily::Google.matches_provider_type("GOOGLE"));
        assert!(GoaProviderFamily::Microsoft.matches_provider_type("ms_graph"));
        assert!(GoaProviderFamily::Microsoft.matches_provider_type("WINDOWS_LIVE"));
        assert!(!GoaProviderFamily::Microsoft.matches_provider_type("exchange"));
        assert!(!GoaProviderFamily::Microsoft.matches_provider_type("imap_smtp"));

        assert!(goa_identity_matches(
            " Person@Example.com ",
            ["", "person@example.com"]
        ));
        assert!(!goa_identity_matches(
            "person@example.com",
            ["other@example.com"]
        ));
        assert_eq!(
            preferred_mail_address(" person@example.com ", "opaque-identity", "also-opaque")
                .as_deref(),
            Some("person@example.com")
        );
        assert_eq!(
            preferred_mail_address("opaque-identity", " real@example.com ", "opaque-mail-id")
                .as_deref(),
            Some("real@example.com")
        );
        assert_eq!(
            preferred_mail_address("opaque", "also-opaque", "mail-id"),
            None
        );
    }

    #[test]
    fn microsoft_graph_mail_is_not_misrepresented_as_imap() {
        let error = validate_mail_capabilities("ms_graph", false, false, false, false, false)
            .unwrap_err()
            .to_string();
        assert!(error.contains("Microsoft Graph"));
        assert!(error.contains("Graph provider"));
        assert!(error.contains("not IMAP/SMTP"));

        validate_mail_capabilities("windows_live", false, true, true, true, true).unwrap();
    }
}
