<p align="center">
  <img src="src/zpeek-icon-v2.png" alt="zpeek icon" width="140">
</p>

<h1 align="center">zpeek</h1>

<p align="center">Explore databases from your terminal. One fast interface for SQL, schema, and data.</p>

<p align="center"><strong>PostgreSQL · MySQL/MariaDB · SQLite · ClickHouse</strong></p>

![zpeek demo: connect to a sample SQLite database, run SQL, and filter rows in /browse](examples/demo.gif)

Type SQL or a `/command` at the prompt. Browse tables full-screen, inspect schema objects and their definitions, and keep useful queries for later. zpeek is a single binary with built-in drivers and SQLite; it needs no client libraries.

## Install

**macOS, Linux, WSL, Git Bash:**

```sh
curl -fsSL https://raw.githubusercontent.com/alaleks/zpeek/master/install.sh | bash
```

**Windows PowerShell:**

```powershell
irm https://raw.githubusercontent.com/alaleks/zpeek/master/install.ps1 | iex
```

The installers download the latest release and verify its checksum. Run them again to update. Set `ZPEEK_VERSION` for a specific release or `ZPEEK_INSTALL_DIR` for a different destination. To build from source, use Zig 0.17.0: `zig build -Doptimize=ReleaseSafe --prefix ~/.local`.

## Get started

```sh
zpeek ./data.sqlite
zpeek postgres://user:pass@host:5432/db
zpeek mysql://user:pass@host:3306/db
zpeek clickhouse://user:pass@host:8123/db
zpeek prod -e "select count(*) from users" # run SQL and exit
```

Run `zpeek` without an argument to use your default connection or pick one from your config. Run `zpeek --init-config` to create an example config at `~/.config/zpeek/config.toml`; `zpeek --list` shows saved connections. Passwords can also come from `--password`, `$PGPASSWORD`, `$MYSQL_PWD`, or `$CLICKHOUSE_PASSWORD`.

Try the database shown in the GIF:

```sh
zig build -Doptimize=ReleaseSafe
sqlite3 /tmp/zpeek-demo.db < examples/demo.sql
./zig-out/bin/zpeek /tmp/zpeek-demo.db
```

The [recording script](examples/demo.tape) shows `/tables`, a SQL query, and `/browse orders` with filtering, counting, sorting, and cell inspection.

## Explore

| Command | What it does |
| --- | --- |
| `/tables` | Pick a table and open `/browse` |
| `/browse <table>` | Explore rows with filters, sorting, and pages; omit the name to pick a table |
| `/views`, `/functions`, `/triggers` | Pick an object and see its SQL definition |
| `/types` | Pick a custom type and see its values |
| `/describe <table>` | Show columns, indexes, and constraints |
| `/save <name>`, `/queries` | Save the last SQL query or bring a saved query into the prompt |
| `/connect [name\|url]`, `/disconnect` | Switch or close a connection |
| `/help` | Show all commands and keys |

In a picker, type to filter and press `enter` to open the selected item. SQL completion knows your database dialect and schema; `tab` accepts a suggestion. Use `ctrl+o` to open the last result as a table, `ctrl+c` to cancel a running query, and `ctrl+d` on an empty prompt to exit.

**Inside `/browse`:** FK columns are marked `↗`; select a cell and press `f` to preview its referenced row below the table (`J`/`K` scroll its fields). `/` filters with a SQL `WHERE` condition, `t` counts matching rows, `s` sorts the selected column, `n`/`p` change pages, and `enter` shows a full cell value. Use `c` to choose columns, `y`/`Y` to copy a cell/row, and `q` or `esc` to return. `d` shows a row deletion for confirmation; it requires a primary key and is unavailable for ClickHouse. zpeek refuses `DELETE` without `WHERE`.

## Connections and limits

PostgreSQL, MySQL/MariaDB, SQLite, and ClickHouse are supported directly. CockroachDB and YugabyteDB work through the PostgreSQL protocol; TiDB works through the MySQL protocol. Other protocol-compatible services may work but have not been tested. SQLite has no stored functions or custom types; ClickHouse has no triggers.

Connection URLs accept `sslmode=disable|prefer|require|verify-ca|verify-full`; the default is `prefer`. ClickHouse uses HTTP on port 8123 or HTTPS on 8443. For named connections, use `~/.config/zpeek/config.toml`:

```toml
default = "local"

[connections.local]
url = "postgres://postgres@localhost:5432/app"
color = "#2F6B43"

[connections.shop]
driver = "mysql"
host = "127.0.0.1"
user = "root"
password_env = "SHOP_DB_PASSWORD"
database = "shop"
```

Results in the console show 50 rows; `ctrl+o` opens the full result. Ad-hoc queries retain up to 10,000 rows and 16 MiB of row data.

## Memory use

In a macOS arm64 test with Zig 0.17.0 `ReleaseSafe`, zpeek peaked at **4.92 MiB RSS** while opening the sample SQLite database, listing tables, running `select name, city from customers order by name`, and viewing the result with `ctrl+o` (October 2026). Reproduce it with `/usr/bin/time -l ./zig-out/bin/zpeek /tmp/zpeek-demo.db`; memory use varies with platform and result size.

See [CONTRIBUTING.md](CONTRIBUTING.md) to build and contribute. Licensed under [MIT](LICENSE).
