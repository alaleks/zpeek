<h1 align="center"><img src="src/zpeek-icon-v2.png" alt="" width="48"> zpeek</h1>

<p align="center"><strong>Browse tables. Follow foreign keys. Run SQL.</strong></p>

<p align="center">A keyboard-driven database browser and SQL client for your terminal.<br>PostgreSQL · MySQL/MariaDB · SQLite · ClickHouse</p>

![zpeek: choose a table, sort orders by price, preview a customer through a foreign key, then run SQL](examples/demo.gif)

## Features

- **Browse data:** filter, sort, page through rows, choose columns, and inspect full cell values.
- **Follow foreign keys:** select an FK cell and preview its related record with `f`.
- **Write SQL:** dialect-aware completion, searchable SQL history, and saved queries with previews.
- **Export results:** CSV or JSON from a query or the current table view.
- **Inspect queries:** an EXPLAIN viewer, execution duration, and affected-row counts.
- **Inspect schema:** columns, indexes, and constraints; definitions of views, functions, triggers, and custom types.
- **Keep connections handy:** named profiles, color badges, and a built-in TOML editor with completion.
- **Choose access per connection:** read-only, read + row deletion, or full access with confirmation for dangerous SQL. See the [security limits](docs/security.md).

## Quick start

### Install

Download a binary manually from [GitHub Releases](https://github.com/alaleks/zpeek/releases), or use an installer:

**macOS, Linux, WSL, Git Bash:**

```sh
curl -fsSL https://raw.githubusercontent.com/alaleks/zpeek/master/install.sh | bash
```

**Windows PowerShell:**

```powershell
irm https://raw.githubusercontent.com/alaleks/zpeek/master/install.ps1 | iex
```

Release builds target macOS, Linux, and Windows on x86_64 and arm64. The installers check SHA-256 checksums when `checksums.txt` is available and warn if it is unavailable. Run an installer again to update; use `ZPEEK_VERSION` to pin a release or `ZPEEK_INSTALL_DIR` to choose a destination.

To build from source with Zig 0.17.0:

```sh
zig build -Doptimize=ReleaseSafe --prefix ~/.local
```

### 1. Open an existing local SQLite database

```sh
zpeek ./data.sqlite
```

Type `/tables`, pick a table, and press `enter`. Use `s` to sort the selected column and `q` to return to the SQL prompt.

### 2. Connect to a database service

```sh
zpeek 'postgres://user@host:5432/db'
zpeek 'mysql://user@host:3306/db'
zpeek 'clickhouse://user@host:8123/db'
```

Passwords can come from `$PGPASSWORD`, `$MYSQL_PWD`, or `$CLICKHOUSE_PASSWORD`; URLs also accept a password, for example `postgres://user:pass@host:5432/db`. See [connections and TLS](docs/connections.md) for saved profiles and more options.

Run SQL and exit with `-e`:

```sh
zpeek prod -e 'select count(*) from users'
```

Here `prod` is a [saved connection](docs/connections.md#saved-connections). Run `zpeek` without an argument to use your default connection or open the connection picker.

### 3. Work on a remote host over SSH

```sh
ssh user@server
zpeek ./database.sqlite
```

Install a zpeek binary built for the server's supported OS and architecture. The database file must be accessible on that server; for a database service, its network endpoint must be reachable from there.

## Why zpeek?

My editor didn't have a database client, so checking data meant jumping between windows. I built zpeek as a lightweight database client I could run in my editor's terminal or on a server over SSH, keeping database work in the same place as everything else.

- One binary with built-in drivers and SQLite; no database client libraries to install.
- A shared keyboard workflow for browsing data, inspecting schema, and running SQL.
- Connections and saved SQL live in ordinary files you can edit yourself.

## Documentation

| Guide | Covers |
| --- | --- |
| [Connections](docs/connections.md) | URLs, saved profiles, TLS, environment variables, supported databases |
| [Configuration](docs/configuration.md) | TOML fields, `/config` commands, editor, help panel, autocomplete |
| [Security](docs/security.md) | Access modes, SQL checks, deletion safeguards, server-side permissions |
| [Usage](docs/usage.md) | Commands, keys, table browsing, saved queries, result limits, demo reproduction |

Client-side SQL checks **are not a security boundary**. Use database permissions for hard guarantees; [read the limitations](docs/security.md#security-boundary).

See [CONTRIBUTING.md](CONTRIBUTING.md) to build and contribute. Licensed under [MIT](LICENSE).
