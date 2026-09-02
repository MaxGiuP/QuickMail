# QuickMail contributor guide

QuickMail is a performance-focused email client for this Hyprland desktop.

## Architecture

- `crates/quickmail-core`: provider-neutral models, RPC types, and traits. It must not depend on UI or storage implementations.
- `crates/quickmaild`: long-running Rust daemon, SQLite cache, provider implementations, keyring access, sync engine, and Unix-socket RPC.
- `crates/quickmailctl`: command-line setup, diagnostics, and RPC client.
- `ui`: standalone Qt Quick host, native platform adapters, and single-instance command routing.
- `qml`: host-neutral Qt Quick client plus optional adapters under `qml/host`. Business logic and secrets do not belong here.

## Quality bar

- Never log or serialize passwords, OAuth refresh tokens, or message bodies unintentionally.
- Persist secrets only through Secret Service/keyring.
- All mutations use stable IDs and a durable operation queue.
- Provider-specific capabilities remain explicit; do not pretend Gmail labels and IMAP folders are equivalent.
- Add tests for protocol parsing, migrations, RPC compatibility, and every fixed regression.
- Run `cargo fmt --all --check`, `cargo clippy --workspace --all-targets -- -D warnings`, and `cargo test --workspace` before committing.

## Coordination

Agents own distinct crates or directories. Do not reformat or rewrite another agent's files without coordinating first.
