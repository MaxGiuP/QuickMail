# QuickMail

QuickMail is a fast, local-first desktop email client for Hyprland and
Quickshell. It pairs a Rust synchronization daemon with a responsive,
Windows Mail-inspired QML interface.

## What works

- Gmail setup with only an email address. Google login and token refresh are
  delegated to GNOME Online Accounts; QuickMail never asks for an OAuth client
  ID or client secret.
- Gmail and generic IMAP/SMTP accounts over TLS, including XOAUTH2, separate
  incoming/outgoing credentials, and system-keyring storage.
- Inbox and bounded recent-folder synchronization, cached search, cursor
  pagination, lazy message bodies, attachment download/open, drafts, compose,
  send, reply, archive, trash, read/unread, and star/unstar.
- Rich HTML mail with allowlist sanitization, remote images enabled by default,
  and a persisted reader toggle to block them.
- SQLite WAL caching and FTS5 search behind a private JSON-RPC Unix socket.
- Dashboard, task, and calendar RPC APIs ready for Quickshell agenda widgets.
- mailto handling and a user systemd service.

## Install

QuickMail currently targets Arch Linux-style Hyprland desktops with
Quickshell, Qt 6, GNOME Online Accounts, GNOME Control Center, Secret Service,
Rust, systemd, and the Inter and Material Symbols Rounded fonts. On Arch, the
font packages used by the interface are `inter-font` and
`ttf-material-symbols-variable-git`.

```sh
git clone https://github.com/MaxGiuP/QuickMail.git
cd QuickMail
./packaging/install.sh
quickmail
```

For Gmail, choose **Gmail**, enter the address, and continue. QuickMail opens
the system-managed Google authorization page. Existing GNOME Online Accounts
are detected automatically.

Generic providers use IMAP and SMTP server details plus an app password. The
password is sent once to the local daemon and then stored in Secret Service;
it is never written to SQLite.

## Design

```text
Google / IMAP / SMTP
        │
  quickmaild (Rust)
  auth · sync · MIME · operation log
        │
 SQLite WAL + FTS5
        │
 private JSON-RPC socket
        │
 Quickshell / QML UI
```

The UI does no mail-protocol or database work. Message lists use cached
summaries; bodies and attachments are fetched only when opened. When the
reader's remote-content setting is enabled, Qt may fetch allowlisted HTTP(S)
images referenced by sanitized message HTML. Foreground sync is bounded so a
large mailbox cannot freeze the client.

See [architecture](docs/architecture.md),
[provider support](docs/provider-support.md), [performance](docs/performance.md),
and [security](docs/security.md) for the implementation details.

## Development

```sh
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
./packaging/test-qml.sh
```

QuickMail is licensed under the MIT License.
