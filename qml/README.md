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

Gmail and Microsoft setup ask only for the mailbox address and an optional
display name. The daemon opens the matching sign-in through GNOME Online
Accounts, which manages authorization and token refresh. QuickMail never asks
for or stores a Google or Microsoft password, OAuth client ID, OAuth client
secret, or access token. Generic and manual Exchange IMAP/SMTP passwords are
handed directly to the connected local daemon for keyring storage.

The desktop launcher starts the user service when available, hands `mailto:`
links to an already-running window over Quickshell IPC, and otherwise resolves
the QML tree from the installed `share/quickmail/qml` layout. Attachment
downloads are cached privately by the daemon. Preview opens an in-app reader
for PDFs, raster images, text and source files, audio, video, and office
documents (converted to a temporary read-only PDF when LibreOffice is
available). Unknown formats receive a bounded 64 KiB binary inspection view,
so every attachment has a safe in-app surface. The original can still be handed
to the desktop URL handler explicitly, while Save prompts for a destination and
copies without invoking a shell.

The reader renders `bodyHtml` with Qt's native rich-text document engine, so
formatting, tables, links, background colors, and inline images do not require
a browser process. The daemon performs the authoritative HTML5 sanitization;
the client applies a second presentation-only CSS pass that retains colors,
alignment, and resource-free responsive dimensions while removing scripts,
interactive elements, positioning, and every CSS resource function. The
sanitized body background fills the message viewport, and fixed-width tables
that remain wider than a narrow reader are exposed through a clipped horizontal
viewport instead of being cut off. Image URLs use a positive HTTP/HTTPS
allowlist. Remote images and best-effort sender avatars are enabled by default;
avatar HTTPS is brokered through the daemon's bounded private cache so QML only
loads local files. Both can be disabled persistently from the compact reader
settings menu, and the saved opt-out is applied before any remote renderer is
enabled. Only HTTP,
HTTPS, and mailto links can leave the mail pane. Messages without HTML fall
back to their local plain text. Saved drafts
use the daemon's account-scoped list/get/delete lifecycle and carry their
`draftId` through a successful send for cleanup.

Validate the UI with:

```sh
packaging/test-qml.sh
```

The script lints every component, loads the full responsive UI offscreen, and
exercises brokered Google and Microsoft setup payloads, the RPC field contract,
account isolation, conversation rendering, the floating compose lifecycle,
reply-all/forward construction, sync error recovery, attachment disposition,
native PDF/text/binary attachment previews, safe HTML presentation, and
`mailto:` parsing.
