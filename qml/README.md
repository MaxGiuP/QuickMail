# QuickMail QML client

Run the client from this checkout with:

```sh
packaging/quickmail
```

The client connects to `$XDG_RUNTIME_DIR/quickmail/daemon.sock` using
newline-delimited JSON-RPC 2.0. `RpcClient.qml` is the single source of method
and notification names. It reconnects with capped exponential backoff,
resubscribes after reconnecting, and refuses to queue credential-bearing
account requests while offline. Password fields are cleared as soon as a
connected request is handed to the daemon.

Gmail setup asks only for the mailbox address and an optional display name.
The daemon opens Google sign-in through GNOME Online Accounts, which manages
authorization and token refresh. QuickMail never asks for or stores a Google
password, OAuth client ID, OAuth client secret, or access token. IMAP/SMTP
passwords are handed directly to the connected local daemon for keyring storage.

The desktop launcher starts the user service when available, hands `mailto:`
links to an already-running window over Quickshell IPC, and otherwise resolves
the QML tree from the installed `share/quickmail/qml` layout. Attachment
downloads are cached by the daemon; Open uses the desktop URL handler, while
Save prompts for a destination and copies without invoking a shell.

The reader renders `bodyHtml` with Qt's native rich-text document engine, so
formatting, tables, links, and inline images do not require a browser process.
Executable and interactive markup is removed, resource URLs use a positive
HTTP/HTTPS allowlist, and inline styles are filtered to Qt's safe presentation
properties. Remote images are enabled by default and can be disabled
persistently from the compact reader settings menu. Only HTTP, HTTPS, and
mailto links can leave the mail pane. Messages without HTML fall back to their
local plain text. Saved drafts use the daemon's account-scoped list/get/delete
lifecycle and carry their `draftId` through a successful send for cleanup.

Validate the UI with:

```sh
packaging/test-qml.sh
```

The script lints every component, loads the full responsive UI offscreen, and
exercises the exact three-field Gmail setup payload, RPC field contract,
account isolation, reply-all/forward construction, the full draft lifecycle,
sync error recovery, attachment disposition, and `mailto:` parsing.
