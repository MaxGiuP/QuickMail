# Provider support

QuickMail keeps one mail model while preserving the authentication and protocol
boundaries advertised by each provider.

| Capability | Gmail through GOA | Microsoft through GOA | Manual IMAP/SMTP |
| --- | --- | --- | --- |
| Setup aliases | `gmail` | `outlook`, `hotmail`, `microsoft365` | `imap`, `exchange` |
| Authentication | Google sign-in managed by GNOME Online Accounts | Microsoft sign-in managed by GNOME Online Accounts | Password or app password stored in Secret Service |
| Required GOA interfaces | Account + Mail + OAuth2Based | Account + Mail + OAuth2Based | None |
| Required mail transport | GOA must advertise IMAP, authenticated SMTP, TLS, and SMTP XOAUTH2 | Current `ms_graph`: Microsoft Graph Mail; legacy `windows_live`: advertised secure IMAP/SMTP XOAUTH2 | Explicit TLS or STARTTLS IMAP and SMTP settings |
| Read and search | IMAP folders with local cached search | Graph folders and bounded server-side search; legacy accounts use IMAP | IMAP folders with local cached search |
| Send/reply | SMTP XOAUTH2 | Microsoft Graph draft/send and create-reply; legacy accounts use SMTP XOAUTH2 | SMTP password authentication |
| Archive/trash/star | IMAP flags and MOVE/copy fallback | Graph message update/move; legacy accounts use IMAP flags and MOVE/copy fallback | IMAP flags and MOVE/copy fallback |
| Incremental identity | UIDVALIDITY and UID cursors | Immutable Graph message IDs and native conversation IDs; legacy accounts use UIDVALIDITY and UID cursors | UIDVALIDITY and UID cursors |
| Attachments | Lazy IMAP retrieval | Lazy Graph file-attachment retrieval; legacy accounts use IMAP | Lazy IMAP retrieval |

## Brokered Google and Microsoft accounts

QuickMail launches GNOME Settings' Online Accounts flow and discovers the
result over the documented GOA D-Bus interfaces. It calls `EnsureCredentials`
and `OAuth2Based.GetAccessToken`; it never reads GOA's OAuth client ID or client
secret properties and never asks the user to paste either value. Refresh tokens
stay with GOA. Short-lived access tokens exist only in the daemon's redacted
in-memory token wrapper and are never serialized, logged, or stored by
QuickMail.

Account restore is deliberately non-interactive. If GOA is unavailable or the
account needs attention, QuickMail preserves the registered account and reports
that authorization is required. Only explicit account creation or Reconnect can
open GNOME Settings.

GOA's Mail interface is a service marker as well as a protocol description, so
QuickMail also checks the provider type before choosing a transport. The
current GNOME `ms_graph` provider requests `Mail.ReadWrite` and `Mail.Send`
permissions and supplies a GOA-managed OAuth2 access token; QuickMail uses that
token only with `https://graph.microsoft.com/v1.0/`. See the [GNOME Microsoft
Graph provider source](https://github.com/GNOME/gnome-online-accounts/blob/master/src/goabackend/goamsgraphprovider.c).

The Graph path supports bounded folder and message paging, full text or HTML
message reads, server search, read/star/move/archive/trash actions, new mail,
replies, and file attachments. Every request that returns or consumes a message
ID asks Graph for [immutable Outlook IDs](https://learn.microsoft.com/en-us/graph/outlook-immutable-id),
and native conversation IDs are scoped to the QuickMail account. Continuation
links are accepted only when they remain HTTPS on `graph.microsoft.com`, match
the requested collection, and stay inside configured page and response-size
bounds. Graph `fileAttachment` values can be downloaded; `itemAttachment` and
`referenceAttachment` values are reported as unsupported rather than being
misrepresented as ordinary files. Microsoft documents the [message paging
contract](https://learn.microsoft.com/en-us/graph/api/user-list-messages?view=graph-rest-1.0)
and [attachment resource types](https://learn.microsoft.com/en-us/graph/api/resources/attachment?view=graph-rest-1.0).

Older `windows_live` GOA accounts are kept on their real advertised protocol:
QuickMail uses IMAP/SMTP XOAUTH2 only when GOA exposes enabled IMAP,
authenticated SMTP, TLS, and XOAUTH2 capabilities. It never relabels a Graph
token as an IMAP/SMTP token. This follows the [GOA Mail interface
contract](https://gnome.pages.gitlab.gnome.org/gnome-online-accounts/dbus-org.gnome.OnlineAccounts.Mail.html)
and [Microsoft's OAuth protocol guidance](https://learn.microsoft.com/en-us/exchange/client-developer/legacy-protocols/how-to-authenticate-an-imap-pop-smtp-application-by-using-oauth).

## Exchange and manual server setup

The `exchange` alias is an honest manual IMAP/SMTP route. It is not a claim of
Microsoft Graph, EWS, Exchange ActiveSync, calendar, contacts, or directory
support. The UI's Exchange Online preset fills Microsoft's published encrypted
mail endpoints:

- IMAP: `outlook.office365.com:993` with TLS
- SMTP: `smtp.office365.com:587` with STARTTLS

These values come from [Microsoft's Exchange Online IMAP/SMTP
documentation](https://learn.microsoft.com/en-us/exchange/clients-and-mobile-in-exchange-online/pop3-and-imap4/pop3-and-imap4).
On-premises Exchange servers require administrator-provided host names.

Manual setup uses password authentication. Many Microsoft 365 organizations
disable IMAP, SMTP AUTH, or all basic authentication, especially when security
defaults are enabled; in that case this path will not work and QuickMail does
not weaken the tenant policy. Microsoft documents the SMTP AUTH policy boundary
in [Enable or disable authenticated client SMTP
submission](https://learn.microsoft.com/en-us/exchange/clients-and-mobile-in-exchange-online/authenticated-client-smtp-submission).
Outlook.com itself requires Modern Auth/OAuth2 and may have IMAP disabled until
the user enables it, so Outlook.com and Hotmail default to the brokered GOA
flow, not the password preset. See [Microsoft's Outlook.com settings](https://support.microsoft.com/en-US/Outlook/pop-imap-and-smtp-settings-for-outlook-com).

GNOME's supported user flow is documented in [Add an online
account](https://help.gnome.org/gnome-help/accounts-add.html), and GOA's account
properties and credential lifecycle are documented in the [Account D-Bus
interface](https://gnome.pages.gitlab.gnome.org/gnome-online-accounts/dbus-org.gnome.OnlineAccounts.Account.html).
