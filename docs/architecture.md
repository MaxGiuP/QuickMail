# Architecture

```text
GNOME Online Accounts ── short-lived Google or Microsoft token
                         │
Gmail IMAP/SMTP · Microsoft Graph · generic/Exchange IMAP/SMTP
                         │
      quickmaild (Rust)
 sync · MIME · operations · keyring
          │
       SQLite WAL + FTS5
          │
 private user-only Unix socket (JSON-RPC 2.0)
          │
       Quickshell/QML frontend
```

The daemon is the source of truth. The UI can restart without losing cached
mail, drafts, or recorded operation history. Provider adapters normalize common
actions while retaining provider-native IDs and explicit capabilities.

The socket lives below `$XDG_RUNTIME_DIR/quickmail`. Credentials never cross
the read API. Google and Microsoft refresh credentials stay owned by GNOME
Online Accounts; the daemon holds only short-lived access tokens in memory and
restricts Microsoft Graph tokens to `graph.microsoft.com`. Generic and manual
Exchange IMAP/SMTP passwords stay in Secret Service. SQLite contains cacheable
account metadata, messages, drafts, agenda entries, and operation state only.

QuickMail's dashboard RPC is the stable integration boundary available to
desktop calendar and todo widgets. Consumers can receive small account, mail,
task, and event summaries without direct access to credentials or message
bodies.
