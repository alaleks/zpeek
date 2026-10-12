# Good first issue drafts

These tasks are ready to publish as separate GitHub issues with the `good first issue` label.

## Add tests for config path precedence

**Files:** `src/config.zig`

`defaultPath` chooses between `ZPEEK_CONFIG`, `XDG_CONFIG_HOME`, `HOME`, and `APPDATA`. Add focused tests for that order, including empty `XDG_CONFIG_HOME` and the no-path case. Use an in-memory environment map; do not read the contributor's real environment. Expected path separators must work on Windows, macOS, and Linux. `zig build test` should pass on all three CI platforms.

## Smoke test `--list` on every CI platform

**Files:** `.github/workflows/release.yml`

The workflow already checks `--version` and a SQLite query. Extend the smoke test with a temporary TOML config containing one named SQLite connection. Run `zpeek --config <file> --list` and assert the name appears. Keep the test independent of a running database and compatible with the existing bash step on Windows, macOS, and Linux.

## Document three queries for the SQLite demo

**Files:** `README.md`, `examples/demo.sql` if more sample rows are needed

Add three copyable queries against the demo database: a basic table query, a join, and an aggregate. Show the expected result shape briefly, in English and Russian. Keep the existing GIF and its recording tape reproducible. Do not use external services or real customer data.
