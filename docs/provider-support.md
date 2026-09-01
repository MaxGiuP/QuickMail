# Provider support

QuickMail keeps a shared user-facing model while preserving native provider
semantics.

| Capability | Gmail through GOA | Generic IMAP/SMTP |
| --- | --- | --- |
| Authentication | Email-only browser login managed by GNOME Online Accounts | App password stored in Secret Service |
| Read and search | IMAP folders with local cached search | IMAP folders with local cached search |
| Send/reply | SMTP XOAUTH2 | SMTP password authentication |
| Archive/trash/star | IMAP flags and MOVE/copy fallback | IMAP flags and MOVE/copy fallback |
| Incremental identity | UIDVALIDITY and UID cursors | UIDVALIDITY and UID cursors |
| Refresh behavior | Inbox-first foreground sync, then bounded recent-message background folders | Inbox-first foreground sync, then bounded recent-message background folders |
| Attachments | Lazy IMAP retrieval | Lazy IMAP retrieval |

The codebase includes a separately tested Gmail REST adapter, but production
Gmail accounts intentionally use the mail endpoints advertised by GNOME Online
Accounts. This avoids asking users to create or paste OAuth application
credentials and works with the scopes granted to the system account broker.

Microsoft Graph/Exchange and CalDAV can be added as provider adapters without
changing the UI or exposing provider credentials through RPC.
