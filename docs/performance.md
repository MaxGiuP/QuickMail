# Performance design

The UI never performs mail-protocol or database work. It requests
cursor-paginated summaries over one persistent local socket and retrieves a
body only when the user opens a message. The one optional UI-side network path
is remote image loading when remote content is enabled: allowlisted HTTP(S)
images from sanitized HTML, plus cached best-effort sender-avatar lookups for
visible rows. Avatar lookups use Gravatar for normalized address hashes and a
domain favicon for recognized automated/brand senders; they never delay the
message list and fall back to initials.

The daemon uses:

- bounded foreground synchronization, with Inbox prioritized;
- UIDVALIDITY/UID cursors for incremental IMAP synchronization;
- pooled TLS connections and short-lived GOA tokens acquired only when needed;
- a bounded SQLite worker, WAL mode, prepared statements, batched
  transactions, covering indexes, FTS5, and keyset pagination;
- lazy message-body and attachment retrieval with explicit cache-completeness
  tracking;
- durable operation records for observable mutations;
- bounded event channels so a stalled frontend cannot stall synchronization;
- strict protocol sizes and deadlines so a remote server cannot hold a client
  operation forever.

Release builds enable thin LTO, one code-generation unit, symbol stripping,
and abort-on-panic. Correctness and crash-safe storage take priority over
micro-optimizations that risk duplicate or lost operations.

## Incremental IMAP refresh

The daemon stores one provider-opaque cursor for each account/mailbox pair in
the same SQLite transaction as the summaries returned for that cursor. For
IMAP, the cursor contains the selected mailbox's `UIDVALIDITY` and the highest
UID whose range has been covered. A routine refresh starts at
`highest_uid + 1` but searches at most 4,096 consecutive UID values toward
`UIDNEXT - 1`, so even a very large backlog cannot produce an unbounded SEARCH
response. If a window contains more than 200 messages, the cursor stops at the
last fetched UID so later refreshes cannot skip the remainder. Otherwise it
advances through the complete window, including gaps left by expunged UIDs.

The first refresh walks backward from `UIDNEXT - 1` in the same 4,096-UID
windows, stopping after 200 matches, UID 1, 16 windows, or the shared ten-second
command deadline. This preserves the bounded recent bootstrap without a
`UID 1:*` response; an exceptionally sparse mailbox can intentionally cache
fewer than 200 old messages. If `UIDVALIDITY` changes, identifiers from the
previous generation are no longer valid, so the daemon atomically removes that
mailbox's cached messages, stores a bounded recent bootstrap from the new
generation, and replaces the cursor.

New-only UID searches do not report flag changes on existing messages. Each
routine refresh therefore also re-fetches envelopes for the newest 64 cached
messages in that mailbox, reconciling `\\Seen`, `\\Flagged`, and keyword flags.
If a requested stable UID is absent from a well-formed FETCH response, its
scoped cache row is treated as expunged and removed in the same transaction as
the summaries and cursor. Opening a full IMAP message also fetches its current
envelope flags before caching the body, so body loading cannot reset read/star
state to defaults.

This is an intentional bounded tradeoff: external flag changes on older
messages can remain stale in the local cache until a broader reconciliation or
mailbox rebuild, while recent mail and all locally initiated read/star actions
remain synchronized without turning every refresh into a full-mailbox scan.
