# QuickMail

QuickMail is a fast, local-first desktop email client for Hyprland and
Quickshell. It pairs a Rust synchronization daemon with a responsive,
Windows Mail-inspired QML interface.

## What works

- Gmail, Outlook, Hotmail, and Microsoft 365 setup with only an email address.
  Browser login and token refresh are delegated to GNOME Online Accounts;
  QuickMail never asks for an OAuth client ID or client secret.
- Gmail over secure IMAP/SMTP XOAUTH2, current Microsoft accounts over Graph,
  legacy brokered Microsoft accounts over capability-gated IMAP/SMTP XOAUTH2,
  and generic or Exchange-server IMAP/SMTP with system-keyring storage.
- Inbox and bounded recent-folder synchronization, cached search, cursor
  pagination, lazy message bodies, attachment download/open, drafts, compose,
  send, reply, archive, trash, read/unread, star/unstar, and bounded
  provider-neutral conversation threads.
- A Gmail-style bottom-right composer that minimizes into a tab while the mail
  list and reader remain available.
- Rich HTML mail with allowlist sanitization, viewport-aware fixed-width table
  handling, best-effort sender avatars, remote content enabled by default, and
  a persisted reader toggle to block every remote image and avatar lookup.
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

For Outlook, Hotmail, or Microsoft 365, choose **Microsoft**. The equivalent
system-managed Microsoft sign-in supplies Graph mail access without exposing
application credentials to QuickMail.

Generic providers use IMAP and SMTP server details plus a password or app
password. The manual Exchange preset fills Exchange Online's encrypted mail
server addresses; it is IMAP/SMTP, not EWS or Graph, and works only when the
mailbox administrator permits password authentication. Manual credentials are
sent once to the local daemon and stored in Secret Service, never SQLite.

## Design

```text
Google IMAP/SMTP · Microsoft Graph · generic IMAP/SMTP
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
