# Contributing

Install the pinned Rust toolchain, Qt 6, Quickshell, GNOME Online Accounts,
SQLite, and a Secret Service provider. Then run:

```bash
cargo fmt --all --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
./packaging/test-qml.sh
```

Provider changes should include deterministic fixtures. Tests must never use a
developer's real mailbox or credentials.
