# Good first issue drafts

These are draft tasks for new contributors. Each can become a GitHub issue with the `good first issue` label.

## Add tests for config path precedence

**Files:** `src/config.zig`

Test the order in which `defaultPath` checks `ZPEEK_CONFIG`, `XDG_CONFIG_HOME`, `HOME`, and `APPDATA`. Include an empty `XDG_CONFIG_HOME` and a case where no path can be found. Build the environment map in the test so the result does not depend on the contributor's machine. Account for platform-specific path separators and check that `zig build test` passes on every CI platform.

## Smoke test `--list` on every CI platform

**Files:** `.github/workflows/release.yml`

The workflow already checks `--version` and a SQLite query. Extend the smoke test with a temporary TOML config containing one named SQLite connection. Run `zpeek --config <file> --list` and assert the name appears. Keep the test independent of a running database and compatible with the existing bash step on Windows, macOS, and Linux.

## Add queries to the SQLite demo

**Files:** `README.md`, `examples/demo.sql` if more sample rows are needed

Add copyable queries that help a new user explore the demo database. Start with a table query, then show how to join customers to orders and calculate an aggregate. Briefly describe each result in English and Russian. The existing GIF and recording tape should still work with the sample data. Use only local, fictional data.
