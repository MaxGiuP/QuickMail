# Contributing

Install the pinned Rust toolchain, Qt 6.8 or newer development tools, CMake,
Quickshell (for the QML smoke harness), GNOME Online Accounts, SQLite, and a
Secret Service provider. Then run:

```bash
cargo fmt --all --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
cmake -S ui -B target/quickmail-ui-build -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=ON
cmake --build target/quickmail-ui-build
ctest --test-dir target/quickmail-ui-build --output-on-failure
./ui/test-ui.sh
./packaging/test-qml.sh
```

Provider changes should include deterministic fixtures. Tests must never use a
developer's real mailbox or credentials.
