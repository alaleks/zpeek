# Contributing to zpeek

Thanks for helping improve zpeek. For a first change, look for a [good first issue](https://github.com/alaleks/zpeek/issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22) or one of the [starter task drafts](docs/good-first-issues.md), or open an issue describing the problem you found.

## Build and test

Install Zig 0.17.0. From the repository root:

```sh
zig build
zig build test
```

To try the sample database, install `sqlite3` and run:

```sh
sqlite3 /tmp/zpeek-demo.db < examples/demo.sql
./zig-out/bin/zpeek /tmp/zpeek-demo.db
```

The terminal demo is recorded from [examples/demo.tape](examples/demo.tape) with VHS. You only need VHS if you change the GIF.

## Send a change

1. Open an issue for larger changes so the approach can be discussed first.
2. Keep pull requests focused. Add or update a test for behavior changes, and update the README when user-facing behavior changes.
3. Run `zig fmt` on changed Zig files and `zig build test` before opening a pull request. Tell us which platforms you tested.

Never include real database URLs, passwords, customer data, or configuration files in an issue or pull request. Use the sample SQLite database for examples.
