# Usage

[← README](../README.md) · [Connections](connections.md) · [Configuration](configuration.md) · [Security](security.md)

Type SQL at the prompt, or start a command with `/`. Press `tab` to accept a completion suggestion. Suggestions use the connected database's dialect and schema; exact matches remain visible, followed by prefixes and substrings. Type `/help` when you need a reminder of the keys.

## Commands

| Command | Action |
| --- | --- |
| `/tables` | Pick a table and open `/browse` |
| `/browse <table> [where …]` | Explore rows; omit the name to pick a table |
| `/views`, `/functions`, `/triggers` | Pick an object and see its SQL definition |
| `/types` | Pick a custom type and see its values |
| `/describe <table>` | Show columns, indexes, and constraints |
| `/def <name>` | Complete an object name and show its view, function, trigger, or enum definition |
| `/databases` | List databases |
| `/refresh` | Reload table, column, and definition names for completion |
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

The `/triggers` picker shows each trigger's table and, where supported, event and status. Search by trigger or table name. PostgreSQL trigger definitions include the backing function body.

Type `/def ` followed by part of an object name to see suggestions, or press `tab` to complete it. Names are loaded when connecting and refreshed after schema changes; use `/refresh` after changes made outside zpeek.

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

Open `/tables` and choose a table to browse its rows. The current row is highlighted across the table, and the active cell has its own color.

Headers identify key columns: `PK` means primary key, `UQ` means a column belongs to a unique index, and `↗` marks a foreign key. A column in a composite unique index may still contain duplicates on its own. Ordinary values use your terminal's text color; `NULL` appears in italics.

| Key | Action |
| --- | --- |
| Arrow keys | Move between rows and columns |
| `s` | Cycle sorting on the selected column: ascending, descending, off |
| `/` | Filter with a SQL `WHERE` condition |
| `t` | Count matching rows |
| `w` | Show the table's columns, indexes and constraints, as in `/describe`; `esc` returns to the same browse view |
| `n` / `p` | Next / previous page |
| `enter` | Show the full cell value |
| `f` on an FK cell | Preview the referenced row below the table |
| `↑` / `↓` or `J` / `K` in FK preview | Select a field in the related row |
| `enter` / `y` in FK preview | Show the full selected value / copy it |
| `f` / `esc` / `q` in FK preview | Close the related row |
| `c` | Open columns; `space` hides/shows a column, `enter` jumps to it (showing it if hidden) |
| `y` / `Y` | Copy a cell / row |
| `d` | Prepare selected-row deletion for confirmation |
| `e` | Export retained rows in the current sort/filter order and visible columns |
| `q` / `esc` | Return to the console |

Row deletion requires a primary key and is unavailable for ClickHouse or read-only connections. See [deletion safeguards](security.md#deleting-rows).

Browse mode asks the database to sort rows. The query-result viewer sorts its saved rows locally. In ascending order, numbers come first, followed by text, with NULLs last. Descending order reverses that order. Large signed 64-bit integers keep their exact order; values such as NaN are treated as text.

## Save and select SQL

Press `ctrl+s` to save SQL from the editor without executing it. With empty input, zpeek saves the last executed SQL instead. Type a name and press `enter`; `tab` selects an existing name. Replacing an existing query requires confirmation. `esc` cancels without changing your input.

Press `ctrl+r` or run `/queries` to find a saved query by name or SQL text. You can preview it before pressing `enter` to load it. This replaces your current input without running the query. `/queries <name>` loads a known query directly; `/save <name>` skips the naming dialog.

Queries are ordinary `<name>.sql` files in the `queries` directory beside the active config. Names use letters, digits, `_`, `-`, and `.`; queries can also be edited outside zpeek.

## SQL history

Press `alt+r` or run `/history [search]` to find earlier SQL, including multiline queries. The newest entries appear first. Press `enter` to load an entry without running it, or `esc` to keep your draft. Slash commands do not appear here. An entry may have been canceled or refused, so its presence does not mean it ran successfully.

History retains at most 1,000 console entries and 16 MiB. It is streamed to a temporary file and atomically replaced on exit at `$XDG_STATE_HOME/zpeek/history`, otherwise `$HOME/.local/state/zpeek/history`, or `%LOCALAPPDATA%\zpeek\history` on Windows without `HOME`. Connection commands remain redacted.

## CSV and JSON export

Export the last retained query result:

```text
/export csv ./result
/export json ./result
```

Omit the path to enter it in a dialog. In a table or plan viewer, press `e`, choose CSV or JSON, and enter a new file path. The selected format's `.csv` or `.json` extension is appended automatically unless the filename already ends with it (case-insensitive). Table export includes the current visible columns and retained rows in their displayed sort/filter order. In `/browse`, that means the current page, not the entire database table.

The export command refuses to overwrite an existing file. It writes a temporary file and moves it into place when complete. On Unix, the new file is private to your user.

CSV includes a header row and preserves quotes and newlines inside values. SQL NULL becomes an empty field. JSON exports an array of objects, with ordinary values stored as strings so numeric precision is preserved. SQL NULL becomes JSON `null`. Use SQL aliases if your result has duplicate column names: JSON export requires unique names.

For scripts, CSV/JSON go to stdout while timing and status go to stderr:

```sh
zpeek prod -e 'select id, name from users' --format csv > users.csv
zpeek prod -e 'select id, name from users' --format json > users.json
```

Shell redirection controls these files and can overwrite them. Export uses retained results, with the limits below; it does not rerun SQL. Truncated source results are reported explicitly.

## Timing and affected rows

Interactive statement results show elapsed milliseconds and the affected-row count when the driver reports it, including zero affected rows. Table and plan viewers also show the query duration in their footer. CLI table output shows these metrics; `--format csv`/`json` sends them to stderr so exported data stays parseable.

The duration includes transferring and decoding the response. It is not a measurement of server CPU time. In the console, each statement gets its own timing. For a CLI script with several statements, the displayed result and affected count come from the driver's final result.

SQLite finishes a `RETURNING` write even if zpeek has reached its row limit. The affected-row count therefore includes all rows changed by that statement.

## Query plans

```text
/explain select * from users where id = 42
/explain
```

The second form uses your last submitted query. Supply one SELECT or DML statement. PRAGMAs are not supported here, and an existing EXPLAIN command cannot be wrapped in another one. Your connection's access checks still apply. The database decides which statements it can explain.

Plans open in the full-screen table viewer. Move between steps and columns, use `enter` to read a full step, `y` to copy a cell, `e` to export, and `q` to return. zpeek uses `EXPLAIN QUERY PLAN` for SQLite, `EXPLAIN PLAN` for ClickHouse, and `EXPLAIN` for PostgreSQL/MySQL. It never adds `ANALYZE`; normal EXPLAIN plans a statement rather than executing it. See the official [SQLite](https://www.sqlite.org/eqp.html), [PostgreSQL](https://www.postgresql.org/docs/18/sql-explain.html), [MySQL](https://dev.mysql.com/doc/refman/8.4/en/explain.html), and [ClickHouse](https://clickhouse.com/docs/reference/statements/explain) references.

## Result limits

The console shows 50 rows. `ctrl+o` opens the retained result in the full-screen viewer. Ad-hoc queries retain up to 10,000 rows and 16 MiB of row data.

Once a newer result arrives, older results keep only cell previews for the first 50 rows. Full cell values, viewing and export remain available for the newest retained result.

An interactive SQL batch has a 32 MiB budget for saved results, including their row indexes and allocated capacity. Each query also has to fit within the remaining row-data budget. If a returned result exceeds the budget, zpeek discards it, reports an error and skips the remaining statements.

The statement that produced that result has already run. Earlier changes are not rolled back. The process can use more than 32 MiB because active queries and the interface need memory too.

Cell previews inspect at most 4 KiB of each value before normalization and clipping. Full retained values remain available in the detail viewer and exports. Temporary rendering and completion arenas retain at most 256 KiB on reset; a larger individual frame can still allocate more. CLI table rendering keeps column widths and one normalized cell at a time.

## Reproduce the demo

From a source checkout, with Zig 0.17.0 and `sqlite3` installed:

```sh
zig build -Doptimize=ReleaseSafe
sqlite3 /tmp/zpeek-demo.db < examples/demo.sql
./zig-out/bin/zpeek /tmp/zpeek-demo.db
```

Use a disposable database file: the sample script recreates `customers` and `orders`. The [video shot list](../examples/demo-video.md) describes the full demo. The [VHS tape](../examples/demo.tape) records its terminal portion as a GIF and silent MP4. To record it again, install VHS and its dependencies, then run this from the repository root:

```sh
vhs examples/demo.tape
```

## Memory use

PostgreSQL and MySQL release protocol buffers larger than 256 KiB after a query finishes, including on errors. Oversized editor buffers are released on clearing or trimmed after replacement; active SQL and drafts remain intact. ClickHouse parses successful HTTP responses incrementally with a reusable line buffer instead of keeping the entire response body alongside decoded values. A single large line can still require a large temporary buffer, within the response byte limit.

In a macOS arm64 test with Zig 0.17.0 `ReleaseSafe`, zpeek peaked at **4.92 MiB RSS** while opening the sample SQLite database, listing tables, running `select name, city from customers order by name`, and viewing the result with `ctrl+o` (October 2026). Reproduce it with `/usr/bin/time -l ./zig-out/bin/zpeek /tmp/zpeek-demo.db`; memory use varies with platform and result size.
