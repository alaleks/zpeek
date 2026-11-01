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
| `/save [name]`, `/queries [name]` | Save SQL or find a saved query; omit the name to open a dialog |
| `/unsave <name>` | Delete a saved query |
| `/copy` | Copy the last SQL query or displayed object definition to the clipboard |
| `/connect [name\|url]`, `/disconnect` | Switch or close a connection |
| `/config`, `/config edit`, `/config add <name> <#RRGGBB> <url\|path>`, `/config remove <name>` | List, edit, save or remove configured connections |
| `/help` | Show all commands and keys |

In a picker, type to filter and press `enter` to open the selected item. SQL completion knows your database dialect and schema; `tab` accepts a suggestion. Use `ctrl+o` to open the last result as a table, `ctrl+y` to copy the input (or the last SQL query or displayed definition when the input is empty), `ctrl+c` to cancel a running query, and `ctrl+d` on an empty prompt to exit. After selecting a view in `/views`, use `/copy` or `ctrl+y` with an empty input to copy its definition. Clipboard copying requires a terminal that allows OSC 52 clipboard writes.

**Inside `/browse`:** `NULL`, booleans, numbers, and FK values have distinct colors; the selected cell keeps a high-contrast style. FK columns are marked `↗`; select a cell and press `f` to preview its referenced row below the table (`J`/`K` scroll its fields). `/` filters with a SQL `WHERE` condition, `t` counts matching rows, `s` sorts the selected column, `n`/`p` change pages, and `enter` shows a full cell value. Use `c` to choose columns, `y`/`Y` to copy a cell/row, and `q` or `esc` to return. `d` shows a row deletion for confirmation; it requires a primary key and is unavailable for ClickHouse and read-only connections. zpeek refuses `DELETE` without `WHERE`.

Press `ctrl+s` to save the SQL currently in the editor without executing it. With an empty editor, the last executed SQL is saved instead. Type a name in the save dialog and press `enter`; `tab` selects an existing name, and replacing an existing query requires confirmation. `esc` cancels without changing your input. Press `ctrl+r` to search saved queries by name or SQL text, preview the selected SQL, and press `enter` to load it into the editor for review. Loading replaces the current input and does not execute SQL. Queries remain ordinary `.sql` files in the `queries` directory beside the active config.

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
access = "read_delete"
```

Set `access` for each connection, including through `/config edit`:

| Value | Allowed operations |
| --- | --- |
| `"read_only"` | Reading queries; row deletion in `/browse` is disabled |
| `"read_delete"` | Reading queries and `DELETE … WHERE …`, including confirmed row deletion in `/browse` |
| `"full"` | All operations; this is the default when no access setting is present |

`read_delete` blocks `INSERT`, `UPDATE`, `TRUNCATE`, and schema changes such as creating, altering or dropping tables, views, indexes and keys. zpeek checks the entire SQL script before executing it; a forbidden statement prevents the whole script from running. `DELETE` requires `WHERE`; `WHERE true` explicitly deletes every row. Browse filters may only read in either restricted mode. ClickHouse row deletion through `/browse` remains unavailable. Restricted modes accept only known metadata-reading PRAGMAs and reject executable MySQL comments and deletes nested in CTEs.

The older `read_only = true` remains equivalent to `access = "read_only"`; `false` means `"full"`. Put these settings inside `[connections.<name>]`; top-level access settings and conflicting `access`/`read_only` values are rejected. Saving an access change through `/config edit` closes the old session; reconnect with `/connect <name>` to apply the saved mode. Named connections and the connection picker reload the config before connecting, so external edits are also picked up. The connection message and footer show the active access mode. Connecting directly by URL creates an ad-hoc connection with `full` access; use the saved connection name to apply its configured restrictions.

In `read_only`, PostgreSQL and MySQL also get a read-only session, SQLite opens the file read-only, and ClickHouse sends `readonly=2` with each request. If the server rejects the read-only setting, connection fails. In `read_delete`, SQLite additionally uses its authorizer to reject other writes, including writes hidden in triggers. For server databases, client SQL checks are not a security boundary: functions and triggers can have side effects. Use a database role with only the required `SELECT` and `DELETE` grants, without schema ownership or DDL privileges, and review any callable routines or triggers with elevated privileges.

Save connections directly in the console with `/config add local #2F6B43 postgres://postgres@localhost:5432/app`, then use `/connect local`. The URL or path is the rest of the line, so SQLite paths may contain spaces; do not add quotes. Existing names are rejected; remove an entry before adding it again. `/config remove local` removes the saved entry and its `default` reference, without closing an open connection. Changes use the active config path (including `--config`) and update the connection picker immediately. The file is replaced atomically; settings and `password_env` references are retained, but comments and formatting are rewritten. URLs containing passwords are saved as plain text in the config; new/replaced files are private to the user on Unix. `/config add` arguments are redacted in the transcript and command history.

Use `/config edit` to edit the active TOML file inside zpeek. `enter` inserts a new line; `ctrl+s` validates, saves and returns to the console. `esc` cancels; with unsaved changes, press it again to discard. Your SQL input is restored when the editor closes. Invalid TOML or connection settings remain in the editor with an error message; the file is unchanged. Comments and formatting are preserved when editing this way. Saving also refuses to overwrite a file changed outside zpeek since opening it. The connection list updates immediately; reconnect to apply changed connection parameters to an open session. Config text is not added to command history.

The config editor displays supported parameters with examples and allowed values in a help panel, beside the editor in wide terminals or below it otherwise. A divider and padding separate it from the editor; long connection strings wrap with indented continuation lines, and help text wraps within its panel. `PageUp`/`PageDown` scroll the reference; `F1` hides or shows it to make more room for editing. These visual line wraps do not change the config text.

Setting names complete while typing or with `tab`. Value lists are available for `access`, `driver`, `sslmode`, `read_only`, and saved connection names for `default`. Use arrows to select, `enter`/`tab` to accept, and `esc` to dismiss the list. Completion preserves quotes and trailing comments, including when editing the middle of a value. Color, connection strings, passwords and other free-form values are entered manually. Completion supports ordinary fields in TOML sections; inline tables and multiline values are left alone.

Results in the console show 50 rows; `ctrl+o` opens the full result. Ad-hoc queries retain up to 10,000 rows and 16 MiB of row data.

## Memory use

In a macOS arm64 test with Zig 0.17.0 `ReleaseSafe`, zpeek peaked at **4.92 MiB RSS** while opening the sample SQLite database, listing tables, running `select name, city from customers order by name`, and viewing the result with `ctrl+o` (October 2026). Reproduce it with `/usr/bin/time -l ./zig-out/bin/zpeek /tmp/zpeek-demo.db`; memory use varies with platform and result size.

See [CONTRIBUTING.md](CONTRIBUTING.md) to build and contribute. Licensed under [MIT](LICENSE).
