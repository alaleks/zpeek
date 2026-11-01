# Configuration

[← README](../README.md) · [Connections](connections.md) · [Security](security.md) · [Usage](usage.md)

The configuration is TOML. Run `zpeek --init-config` to create an example, or `/config edit` to edit the active file inside zpeek. See [configuration location](connections.md#configuration-location) for path selection.

## TOML fields

At the top level, `default = "local"` selects a saved connection. Each connection has its own `[connections.<name>]` section:

```toml
default = "local"

[connections.local]
url = "postgres://postgres@localhost:5432/app"
color = "#2F6B43"
access = "read_only"
```

| Connection field | Value / purpose |
| --- | --- |
| `url` | Connection URL; see [supported formats](connections.md#urls-and-paths) |
| `path` | SQLite file path, used instead of `url`; supports `~/` |
| `driver` | `"postgres"`, `"mysql"`, `"mariadb"`, `"sqlite"`, or `"clickhouse"`; needed when neither `url` nor `path` is provided |
| `host` | Hostname, IP address, or supported socket path |
| `port` | Numeric port; defaults to the driver's port |
| `user` | Database username |
| `database` | Database name, or the SQLite path |
| `password` | Plain text password |
| `password_env` | Name of an environment variable containing the password |
| `color` | Database badge color in `"#RRGGBB"` form |
| `sslmode` | `"disable"`, `"prefer"`, `"require"`, `"verify-ca"`, or `"verify-full"` |
| `access` | `"full"` (default), `"read_only"`, or `"read_delete"`; see [security](security.md) |
| `read_only` | Legacy boolean: `true` means `"read_only"`, `false` means `"full"`; prefer `access` |

Explicit connection fields override values parsed from `url`. Do not put `access` or `read_only` at the top level: they belong inside a connection section. Conflicting `access` and `read_only` values are rejected. Excessive TOML nesting is rejected with a diagnostic rather than parsed without a depth limit.

## Save and remove connections

```text
/config
/config add local #2F6B43 postgres://postgres@localhost:5432/app
/config remove local
```

`/config` lists saved connections and shows examples. `add` requires a name, a color, and a URL or SQLite path. The URL/path is the rest of the line, so SQLite paths may contain spaces; do not add quotes around it.

Existing names are rejected; remove an entry before adding it again, or edit it through `/config edit`. `/config remove local` removes the entry and its `default` reference without closing an open connection. These commands use the active config path, including `--config`, and update the connection picker immediately.

Changes replace the file atomically. Settings and `password_env` references are retained, but `add` and `remove` rewrite comments and formatting. New or replaced files are private to the user on Unix. `/config add` arguments are redacted in the transcript and command history.

## Edit the file inside zpeek

Open the editor with `/config edit`:

| Key | Action |
| --- | --- |
| `enter` | Insert a new line |
| `ctrl+s` | Validate, save, and return to the console |
| `esc` | Cancel; press again to discard unsaved changes |
| `F1` | Hide or show the parameter reference |
| `PageUp` / `PageDown` | Scroll the reference |
| `tab` | Complete a setting or value |

Your SQL input is restored when the editor closes. Invalid TOML or connection settings stay in the editor with an error message; the file is unchanged. Comments and formatting are preserved when editing this way. Saving refuses to overwrite a file changed outside zpeek since it was opened. Config text is not added to command history.

The parameter reference shows supported keys, examples, and allowed values. It sits beside the editor in a wide terminal or below it otherwise. A divider and padding separate the panels. Long connection strings wrap with indented continuation lines, and reference text wraps within its panel; visual wraps do not change the file.

The connection list updates immediately after saving. Changing the active connection's access mode, or removing its entry through the editor, closes the old session. Use `/connect <name>` to apply the saved settings. Other connection parameter changes require reconnecting as well.

## Autocomplete

Setting names complete while typing or with `tab`. Value lists are available for:

- `access`: `full`, `read_only`, `read_delete`.
- `driver`: `postgres`, `mysql`, `mariadb`, `sqlite`, `clickhouse`.
- `sslmode`: `disable`, `prefer`, `require`, `verify-ca`, `verify-full`.
- `read_only`: `true`, `false`.
- `default`: saved connection names.

Use arrows to select, `enter`/`tab` to accept, and `esc` to dismiss the list. Completion preserves quotes and trailing comments, including when editing the middle of a value. Color, connection strings, passwords, and other free-form values are entered manually. Completion supports ordinary fields in TOML sections; inline tables and multiline values are left alone.
