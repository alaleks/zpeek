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
| `q` / `esc` | Return to the console |

Row deletion requires a primary key and is unavailable for ClickHouse or read-only connections. See [deletion safeguards](security.md#deleting-rows).

## Save and select SQL

Press `ctrl+s` to save SQL from the editor without executing it. With empty input, zpeek saves the last executed SQL instead. Type a name and press `enter`; `tab` selects an existing name. Replacing an existing query requires confirmation. `esc` cancels without changing your input.

Press `ctrl+r` or run `/queries` to search by name or SQL text and preview the selected query. `enter` loads it into the editor for review. Loading replaces current input and **does not execute SQL**. `/queries <name>` loads a query directly; `/save <name>` saves without the naming dialog.

Queries are ordinary `<name>.sql` files in the `queries` directory beside the active config. Names use letters, digits, `_`, `-`, and `.`; queries can also be edited outside zpeek.

## Result limits

The console shows 50 rows. `ctrl+o` opens the retained result in the full-screen viewer. Ad-hoc queries retain up to 10,000 rows and 16 MiB of row data.

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
