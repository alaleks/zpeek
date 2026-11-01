# Usage

[← README](../README.md) · [Connections](connections.md) · [Configuration](configuration.md) · [Security](security.md)

Type SQL or a `/command` at the prompt. SQL completion uses the connected database's dialect and schema; `tab` accepts a suggestion. `/help` lists commands and keys inside the app.

## Commands

| Command | Action |
| --- | --- |
| `/tables` | Pick a table and open `/browse` |
| `/browse <table> [where …]` | Explore rows; omit the name to pick a table |
| `/views`, `/functions`, `/triggers` | Pick an object and see its SQL definition |
| `/types` | Pick a custom type and see its values |
| `/describe <table>` | Show columns, indexes, and constraints |
| `/def <name>` | Show the definition of a view, function, trigger, or enum |
| `/databases` | List databases |
| `/refresh` | Reload table and column names for completion |
| `/save [name]`, `/queries [name]` | Save SQL or find a saved query; omit the name to open a dialog |
| `/unsave <name>` | Delete a saved query |
| `/history [search]` | Search SQL history and load an input for review |
| `/export <csv\|json> [path]` | Export the last retained result; omit the path for a dialog |
| `/explain [SQL]` | Open a query plan without `ANALYZE`; omit SQL to explain the last query |
| `/copy` | Copy the last SQL query or displayed object definition |
| `/connect [name\|url]`, `/disconnect` | Switch or close a connection |
| `/config`, `/config edit`, `/config add …`, `/config remove …` | [Manage configuration](configuration.md) |
| `/clear`, `/quit` | Clear the transcript or exit |
| `/help` | Show commands and keys |

In a picker, type to filter and press `enter` to open the selected item.

## Console keys

| Key | Action |
| --- | --- |
| `enter` | Run SQL or a command; separate SQL statements with `;` |
| `shift+enter`, `alt+enter`, `ctrl+j`, trailing `\` | Continue input on a new line |
| `tab` | Complete commands, SQL keywords, operators, tables, or columns |
| `tab` / `enter` with completion open | Insert the selected suggestion; `esc` dismisses the list |
| `↑` / `↓` | Browse history, or move between input lines |
| `ctrl+o` | Open the last result in the full-screen table viewer |
| `ctrl+s` | Save current SQL, or the last executed query if input is empty |
| `ctrl+r` | Search saved queries and preview their SQL |
| `alt+r` | Search SQL history, newest first |
| `ctrl+y` | Copy input, or the last SQL / displayed definition if input is empty |
| `ctrl+c` | Cancel a running query, dismiss completion, or clear input; press twice on empty input to exit |
| `ctrl+d` | Exit on an empty prompt |
| `ctrl+l` | Clear the screen |
| `PageUp` / `PageDown`, mouse wheel | Scroll the transcript |

After selecting a view in `/views`, use `/copy` or `ctrl+y` with empty input to copy its definition. Clipboard copying requires a terminal that permits OSC 52 clipboard writes.

## Browse tables

`NULL`, booleans, numbers, and FK values have distinct colors. The selected cell uses a high-contrast style; FK columns are marked `↗`.

| Key | Action |
| --- | --- |
| Arrow keys | Move between rows and columns |
| `s` | Cycle sorting on the selected column: ascending, descending, off |
| `/` | Filter with a SQL `WHERE` condition |
| `t` | Count matching rows |
| `n` / `p` | Next / previous page |
| `enter` | Show the full cell value |
| `f` on an FK cell | Preview the referenced row below the table |
| `J` / `K` | Scroll fields in the FK preview |
| `c` | Choose visible columns |
| `y` / `Y` | Copy a cell / row |
| `d` | Prepare selected-row deletion for confirmation |
| `e` | Export retained rows in the current sort/filter order and visible columns |
| `q` / `esc` | Return to the console |

Row deletion requires a primary key and is unavailable for ClickHouse or read-only connections. See [deletion safeguards](security.md#deleting-rows).

## Save and select SQL

Press `ctrl+s` to save SQL from the editor without executing it. With empty input, zpeek saves the last executed SQL instead. Type a name and press `enter`; `tab` selects an existing name. Replacing an existing query requires confirmation. `esc` cancels without changing your input.

Press `ctrl+r` or run `/queries` to search by name or SQL text and preview the selected query. `enter` loads it into the editor for review. Loading replaces current input and **does not execute SQL**. `/queries <name>` loads a query directly; `/save <name>` saves without the naming dialog.

Queries are ordinary `<name>.sql` files in the `queries` directory beside the active config. Names use letters, digits, `_`, `-`, and `.`; queries can also be edited outside zpeek.

## SQL history

Press `alt+r` or run `/history [search]` to search SQL inputs, including multiline SQL. The list shows newest inputs first with a SQL preview. `enter` loads the selection into the editor without executing it; `esc` preserves your draft. Slash commands are excluded from this picker. Canceled or refused SQL inputs may still appear: history records input, not proof of execution.

History retains at most 1,000 console entries and 16 MiB. It is streamed to a temporary file and atomically replaced on exit at `$XDG_STATE_HOME/zpeek/history`, otherwise `$HOME/.local/state/zpeek/history`, or `%LOCALAPPDATA%\zpeek\history` on Windows without `HOME`. Connection commands remain redacted.

## CSV and JSON export

Export the last retained query result:

```text
/export csv ./result.csv
/export json ./result.json
```

Omit the path to enter it in a dialog. In a table or plan viewer, press `e`, choose CSV or JSON, and enter a new file path. Table export includes the current visible columns and retained rows in their displayed sort/filter order. In `/browse`, that means the current page, not the entire database table.

Export writes through a fixed-size buffer to an atomic file and refuses to overwrite an existing path. Files created this way are private to the user on Unix. CSV includes headers, quotes text fields, preserves embedded newlines and quotes, and represents SQL NULL as an empty field. JSON is an array of objects: non-NULL database values remain strings, preserving numeric precision, and SQL NULL becomes JSON `null`. JSON requires unique column names; use SQL aliases for duplicate names.

For scripts, CSV/JSON go to stdout while timing and status go to stderr:

```sh
zpeek prod -e 'select id, name from users' --format csv > users.csv
zpeek prod -e 'select id, name from users' --format json > users.json
```

Shell redirection controls these files and can overwrite them. Export uses retained results, with the limits below; it does not rerun SQL. Truncated source results are reported explicitly.

## Timing and affected rows

Interactive statement results show elapsed milliseconds and the affected-row count when the driver reports it, including zero affected rows. Table and plan viewers also show the query duration in their footer. CLI table output shows these metrics; `--format csv`/`json` sends them to stderr so exported data stays parseable.

Duration measures the client-observed query call, including transfer and decoding, rather than server-only CPU time. Each interactive statement gets its own metrics. For a CLI script with multiple statements, the displayed result and affected count describe the driver's final result. SQLite `RETURNING` writes are finished even when retained rows are capped, so their affected count remains accurate.

## Query plans

```text
/explain select * from users where id = 42
/explain
```

The second form uses the last submitted query. One SELECT or DML statement is accepted; multiple statements, PRAGMAs, and nested EXPLAIN commands are refused. Connection access checks still apply, and individual databases determine which statement types they can explain.

Plans open in the full-screen table viewer. Move between steps and columns, use `enter` to read a full step, `y` to copy a cell, `e` to export, and `q` to return. zpeek uses `EXPLAIN QUERY PLAN` for SQLite, `EXPLAIN PLAN` for ClickHouse, and `EXPLAIN` for PostgreSQL/MySQL. It never adds `ANALYZE`; normal EXPLAIN plans a statement rather than executing it. See the official [SQLite](https://www.sqlite.org/eqp.html), [PostgreSQL](https://www.postgresql.org/docs/18/sql-explain.html), [MySQL](https://dev.mysql.com/doc/refman/8.4/en/explain.html), and [ClickHouse](https://clickhouse.com/docs/reference/statements/explain) references.

## Result limits

The console shows 50 rows. `ctrl+o` opens the retained result in the full-screen viewer. Ad-hoc queries retain up to 10,000 rows and 16 MiB of row data.

An interactive SQL batch retains at most 32 MiB of result arena capacity across its statements. Each query also respects the remaining row-data budget. If the returned arena exceeds that budget, its result is discarded and subsequent statements are skipped with an explicit error. The statement that produced that result has already executed; earlier changes are not rolled back. This is a retained-result limit, not a process memory limit: an in-flight result, SQL text, driver buffers and UI state consume additional memory.

Cell previews inspect at most 4 KiB of each value before normalization and clipping. Full retained values remain available in the detail viewer and exports. Temporary rendering and completion arenas retain at most 256 KiB on reset; a larger individual frame can still allocate more. CLI table rendering keeps column widths and one normalized cell at a time.

## Reproduce the demo

From a source checkout, with Zig 0.17.0 and `sqlite3` installed:

```sh
zig build -Doptimize=ReleaseSafe
sqlite3 /tmp/zpeek-demo.db < examples/demo.sql
./zig-out/bin/zpeek /tmp/zpeek-demo.db
```

The sample script recreates its `customers` and `orders` tables; use a disposable database file. The [recording script](../examples/demo.tape) selects `orders` through `/tables`, sorts by `total_usd`, previews the related customer through `customer_id`, and executes SQL. Regenerate the GIF from the repository root with VHS and its recording dependencies installed:

```sh
vhs examples/demo.tape
```

## Memory use

In a macOS arm64 test with Zig 0.17.0 `ReleaseSafe`, zpeek peaked at **4.92 MiB RSS** while opening the sample SQLite database, listing tables, running `select name, city from customers order by name`, and viewing the result with `ctrl+o` (October 2026). Reproduce it with `/usr/bin/time -l ./zig-out/bin/zpeek /tmp/zpeek-demo.db`; memory use varies with platform and result size.
