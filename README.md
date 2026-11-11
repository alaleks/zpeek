<h1 align="center"><img src="src/zpeek-icon-v2.png" alt="" width="48"> zpeek</h1>

<p align="center"><strong>Your databases, one terminal.</strong></p>

<p align="center">PostgreSQL · MySQL/MariaDB · SQLite · ClickHouse</p>

![zpeek: browse orders, follow customer_id, run SQL with autocomplete, and switch between dev and prod demo databases](examples/demo.gif)

## Less setup, more time with your data

zpeek lets you work with a database without leaving your editor's terminal. Open a table and browse its rows with the keyboard. You can filter the results, hide columns you don't need, or open a cell to read its full value. When a value points to another table, press `f` to see the related record without writing a join.

For questions that need SQL, the editor provides syntax highlighting and autocomplete. Query history makes it easy to return to earlier work, and you can save queries you use often. Results can be exported as CSV or JSON. Schema inspection and query plans help when you need to understand how a query works.

Saved connections keep your databases close at hand. Each connection can have an access mode, while color badges help you tell dev from prod. zpeek also works over SSH, so you can use the same interface on a remote server.

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

Prefer to build it yourself? With Zig 0.17.1:

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

Type `/tables` to choose a table, then press `enter` to open it. Filter or sort the rows to find what you need. If a cell contains a foreign key, select it and press `f` to open the related record.

Press `q` to return to the SQL prompt. When you need another database, use `/connect` to switch between [saved connections](docs/connections.md#saved-connections).

## Why I built zpeek

My editor didn't have a database client, and I was tired of switching between windows just to connect to a database. The tools I used also consumed more system resources than I liked, even while sitting in the background.

I wanted to look up data from the terminal I already had open, including records in related tables. I chose Zig because it had worked well for me before, and built zpeek around that workflow.

The result is a single binary with built-in drivers that also works over SSH. Connections and saved SQL live in ordinary files you can edit yourself, so your setup stays yours.

## Benchmarks

In a local PostgreSQL benchmark, zpeek reached **10.27 MiB peak RSS** after 15 rounds of working with query results in the TUI. Each round included browsing and sorting before clearing the results.

Reading a SQL response containing 20 million IDs took **1.56 s median**, including startup and connection, with **35.18 MiB peak RSS**.

These local, warm-cache results came from Linux x86_64 with PostgreSQL 18.6 and Zig 0.17.0 `ReleaseSafe`, so your numbers may differ. The large-result test retained at most 16 MiB of row data.

To measure your own setup, use the [benchmark script](benchmarks/README.md).
It downloads the latest zpeek release and creates a test database on your server.
After measuring client CPU and memory with millions of rows, it drops the test database
it created.

## Documentation

Start with [Connections](docs/connections.md) to set up database access and save a profile. [Configuration](docs/configuration.md) explains how to adjust zpeek to the way you work.

The [Usage guide](docs/usage.md) covers everyday work in the TUI and serves as a reference for commands and keys. Read [Security](docs/security.md) to understand access modes and their limits.

One important caveat: client-side SQL checks **are not a security boundary**. Use database permissions for hard guarantees, and [read the limitations](docs/security.md#security-boundary) before relying on access modes.

Want to hack on zpeek? See [CONTRIBUTING.md](CONTRIBUTING.md). Licensed under [MIT](LICENSE).
