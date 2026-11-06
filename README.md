<h1 align="center"><img src="src/zpeek-icon-v2.png" alt="" width="48"> zpeek</h1>

<p align="center"><strong>Browse tables. Follow foreign keys. Keep working.</strong></p>

<p align="center">A keyboard-driven database client for your terminal.<br>PostgreSQL · MySQL/MariaDB · SQLite · ClickHouse</p>

![zpeek: browse orders, follow customer_id, run SQL with autocomplete, and switch between dev and prod demo databases](examples/demo.gif)

## Less setup, more time with your data

Sometimes you just want to check a row, follow a foreign key, or run a quick query. zpeek lets you do that without leaving your editor's terminal, and it works over SSH when the database is on a remote server.

- Filter and sort rows, choose which columns to show, and inspect full values in a readable TUI.
- Select a foreign-key value and press `f` to jump to the related record instead of writing a join by hand.
- Write SQL with built-in syntax highlighting, autocomplete, query history, and saved queries.
- Tell environments apart with named connections and color badges for dev and prod.
- Inspect schemas and query plans, export results as CSV or JSON, and set an access mode for each connection.

## Quick start

### 1. Install zpeek

Download a binary from [GitHub Releases](https://github.com/alaleks/zpeek/releases), or install it from the terminal:

**macOS, Linux, WSL, Git Bash:**

```sh
curl -fsSL https://raw.githubusercontent.com/alaleks/zpeek/master/install.sh | bash
```

**Windows PowerShell:**

```powershell
irm https://raw.githubusercontent.com/alaleks/zpeek/master/install.ps1 | iex
```

Prefer to build it yourself? With Zig 0.17.0:

```sh
zig build -Doptimize=ReleaseSafe --prefix ~/.local
```

### 2. Open a database

Already have a SQLite file? That is enough:

```sh
zpeek ./data.sqlite
```

Or connect to a database service:

```sh
zpeek 'postgres://user@host:5432/db'
zpeek 'mysql://user@host:3306/db'
zpeek 'clickhouse://user@host:8123/db'
```

See [connections and TLS](docs/connections.md) for passwords, connection options, and setup details.

### 3. Find your way around

A typical first session looks like this:

1. Type `/tables`, choose a table, and press `enter`.
2. Filter or sort the rows until you find something interesting.
3. Select a foreign-key value and press `f` to see the related record.
4. Press `q` to return to the prompt and run SQL.
5. Use `/connect` to jump between [saved connections](docs/connections.md#saved-connections).

## Why I built zpeek

My editor didn't have a database client, and I was tired of switching between windows just to connect to a database. The tools I used also consumed more system resources than I liked, even while sitting in the background.

I wanted to open a table, follow a relationship, and get back to work from the same terminal. I chose Zig because it had worked well for me before, and built zpeek around that workflow.

The result is a single binary with built-in drivers that also works over SSH. Connections and saved SQL live in ordinary files you can edit yourself, so your setup stays yours.

## Benchmarks

Here are two results from local PostgreSQL benchmarks:

- **10.27 MiB peak RSS** after 15 rounds of querying, browsing, sorting, and clearing results in the TUI.
- **1.56 s median** to read a 20-million-ID SQL response, including startup and connection, with **35.18 MiB peak RSS**.

These local, warm-cache results came from Linux x86_64 with PostgreSQL 18.6 and Zig 0.17.0 `ReleaseSafe`, so your numbers may differ. The large-result test retained at most 16 MiB of row data.

To measure your own setup, use the [benchmark script](benchmarks/README.md).
It downloads the latest zpeek release and creates a test database on your server.
After measuring client CPU and memory with millions of rows, it drops the tables
it created. The empty test database stays on the server.

## Documentation

| Guide | What you will find |
| --- | --- |
| [Connections](docs/connections.md) | URLs, saved profiles, TLS, environment variables, supported databases |
| [Configuration](docs/configuration.md) | TOML fields, `/config` commands, editor, help panel, autocomplete |
| [Security](docs/security.md) | Access modes, SQL checks, deletion safeguards, server-side permissions |
| [Usage](docs/usage.md) | Commands, keys, table browsing, saved queries, result limits, demo reproduction |

One important caveat: client-side SQL checks **are not a security boundary**. Use database permissions for hard guarantees, and [read the limitations](docs/security.md#security-boundary) before relying on access modes.

Want to hack on zpeek? See [CONTRIBUTING.md](CONTRIBUTING.md). Licensed under [MIT](LICENSE).
