<h1 align="center"><img src="src/zpeek-icon-v2.png" alt="" width="48"> zpeek</h1>

<p align="center"><strong>Browse tables. Follow foreign keys. Run SQL.</strong></p>

<p align="center">A keyboard-driven database client for your terminal.<br>PostgreSQL · MySQL/MariaDB · SQLite · ClickHouse</p>

![zpeek: browse orders, follow customer_id, run SQL with autocomplete, and switch between dev and prod demo databases](examples/demo.gif)

## What you can do

- **Explore tables** in a readable TUI: filter and sort rows, choose columns, and inspect full values.
- **Follow foreign keys** with `f` to see the related record without writing a join.
- **Write SQL** with syntax highlighting and completion; reuse queries from history or saved files.
- **Switch databases** with named connections and color badges, so you can tell environments apart.
- **Inspect schemas and query plans**, export CSV/JSON, and choose access modes per connection.

## Quick start

Download a binary from [GitHub Releases](https://github.com/alaleks/zpeek/releases), or install it from the terminal:

**macOS, Linux, WSL, Git Bash:**

```sh
curl -fsSL https://raw.githubusercontent.com/alaleks/zpeek/master/install.sh | bash
```

**Windows PowerShell:**

```powershell
irm https://raw.githubusercontent.com/alaleks/zpeek/master/install.ps1 | iex
```

To build from source with Zig 0.17.0:

```sh
zig build -Doptimize=ReleaseSafe --prefix ~/.local
```

Open an existing SQLite database:

```sh
zpeek ./data.sqlite
```

Or connect to a database service:

```sh
zpeek 'postgres://user@host:5432/db'
zpeek 'mysql://user@host:3306/db'
zpeek 'clickhouse://user@host:8123/db'
```

Inside zpeek, type `/tables`, pick a table, and press `enter`. Select an FK value and press `f` to follow it, or type SQL at the prompt. Use `/connect` to switch between [saved connections](docs/connections.md#saved-connections). See [connections and TLS](docs/connections.md) for passwords and other options.

## Why zpeek?

I built zpeek to check data without leaving my editor's terminal. It also works over SSH: one binary with built-in drivers, with connections and saved SQL in ordinary files you can edit yourself.

## Benchmarks

In November 2026, separate Linux x86_64 runs with PostgreSQL 18.6 on localhost and Zig 0.17.0 `ReleaseSafe` builds measured:

- **10.27 MiB peak RSS** across 15 TUI cycles of querying, browsing, sorting, and clearing results ([TUI run](docs/benchmarks/linux-2026-11-03/REPORT.md)).
- **1.56 s median wall time** for a 20-million-ID SQL response, including startup and connection, with **35.18 MiB peak RSS** ([full-response run](docs/benchmarks/linux-2026-11-03/OPTIMIZATION.md)).

The large-result run read the full response but retained at most 16 MiB of row data. These were local, warm-cache measurements; the reports include the setup and raw results.

## Documentation

| Guide | Covers |
| --- | --- |
| [Connections](docs/connections.md) | URLs, saved profiles, TLS, environment variables, supported databases |
| [Configuration](docs/configuration.md) | TOML fields, `/config` commands, editor, help panel, autocomplete |
| [Security](docs/security.md) | Access modes, SQL checks, deletion safeguards, server-side permissions |
| [Usage](docs/usage.md) | Commands, keys, table browsing, saved queries, result limits, demo reproduction |

Client-side SQL checks **are not a security boundary**. Use database permissions for hard guarantees; [read the limitations](docs/security.md#security-boundary).

See [CONTRIBUTING.md](CONTRIBUTING.md) to build and contribute. Licensed under [MIT](LICENSE).
