# Security model

Email is hostile input. QuickMail treats every remote field, MIME part,
attachment name, calendar invitation, and authorization response as
untrusted.

- Google and Microsoft refresh credentials remain in GNOME Online Accounts.
  QuickMail asks only for short-lived access tokens over the session D-Bus and
  never copies them into its database or keyring. Current `ms_graph` tokens are
  sent only to the HTTPS Microsoft Graph API host; legacy `windows_live` tokens
  stay on the TLS IMAP/SMTP endpoints and capabilities advertised by GOA.
- Generic and manual Exchange IMAP/SMTP passwords are stored only in Secret
  Service.
- The database, attachment cache, and runtime directories are mode `0700`;
  database, WAL/SHM, socket, and attachment files are mode `0600`.
- The local socket checks peer ownership and enforces a request-size limit.
- HTML bodies render through Qt's non-browser rich-text engine after an HTML5
  allowlist sanitizer strips executable/interactive markup, relative and local
  resource URLs, and non-presentation CSS. Resource-free layout properties such
  as bounded dimensions and text alignment are retained, but positioning and
  every CSS resource function remain blocked. A client-side defense-in-depth
  pass enforces the same boundary before rendering. Remote
  HTTP/HTTPS images load by default at the user's request and can be disabled
  persistently from the reader settings; plain text remains the fallback.
- Remote images are fetched directly by Qt from sender-selected HTTP(S) URLs.
  Loading them can disclose that a message was opened and can issue requests
  to HTTP services reachable from the machine, including private-network
  addresses. The reader toggle blocks all image/resource carriers before Qt
  sees the document; a future resource broker is required for finer-grained
  host, redirect, and download limits.
- Sender avatars are best-effort and do not request additional OAuth scopes.
  With remote content enabled, visible rows may send an MD5 hash of a
  normalized sender address to Gravatar, or the public domain of a recognized
  automated sender to DuckDuckGo's favicon service. Human senders fall back to
  initials when no provider URL or Gravatar exists. A persisted opt-out is
  applied fail-closed before settings finish loading and suppresses both avatar
  lookups and message-body images.
- MIME parsing and attachment names are bounded and sanitized. Attachment
  cache paths are generated inside an application-owned private directory.
- Provider and SMTP errors are deliberately redacted; tokens, passwords,
  authorization payloads, and complete message bodies are not logged.
- Account removal evicts live providers and deletes QuickMail-owned generic
  credentials. It never removes the user's GNOME Online Account.

Please report security problems privately to the repository owner rather than
opening a public issue containing account data.
