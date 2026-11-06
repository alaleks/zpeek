# Configuration

[← README](../README.md) · [Connections](connections.md) · [Security](security.md) · [Usage](usage.md)

zpeek stores connections in a TOML file. Run `zpeek --init-config` to create an example. To change it inside zpeek, use `/config edit`. See [where the file lives](connections.md#configuration-location).

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

Fields such as `host` override the corresponding part of `url`. If you set `password_env`, its value replaces any password from the URL or `password` field. A missing variable leaves that password empty; see [password fallback](connections.md#passwords-and-environment-variables).

Put `access` and `read_only` inside a connection section. zpeek reports an error if they conflict or appear at the top level. It also rejects TOML that exceeds its nesting limit.

## Save and remove connections

```text
/config
/config add local #2F6B43 postgres://postgres@localhost:5432/app
/config remove local
```

`/config` lists your connections and shows command examples. The `add` syntax is `/config add <name> <color> <url-or-path>`. The path takes up the rest of the line, so spaces are allowed. Do not put quotes around it.

Existing names are rejected; remove an entry before adding it again, or edit it through `/config edit`. `/config remove local` removes the entry and its `default` reference without closing an open connection. These commands use the active config path, including `--config`, and update the connection picker immediately.

zpeek writes a replacement file before swapping it into place. The `add` and `remove` commands keep your settings, including `password_env`, but rewrite comments and formatting. Use `/config edit` if you want to keep those too. New or replaced files are private to your user on Unix. The transcript and history hide `/config add` arguments.

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

Press `F1` to see help for the settings. In a wide terminal, help appears beside the editor; in a narrow one, it appears below. Long lines wrap on screen without adding line breaks to the file.

The connection list updates immediately after saving. Changing the active connection's access mode, or removing its entry through the editor, closes the old session. Use `/connect <name>` to apply the saved settings. Other connection parameter changes require reconnecting as well.

## Autocomplete

Setting names complete while typing or with `tab`. Value lists are available for:

- `access`: `full`, `read_only`, `read_delete`.
- `driver`: `postgres`, `mysql`, `mariadb`, `sqlite`, `clickhouse`.
- `sslmode`: `disable`, `prefer`, `require`, `verify-ca`, `verify-full`.
- `read_only`: `true`, `false`.
- `default`: saved connection names.

Move through suggestions with the arrow keys and accept one with `enter` or `tab`. Press `esc` to close the list. Completion keeps existing quotes and trailing comments, even when you edit the middle of a value.

Enter free-form values such as passwords yourself. Completion works on ordinary fields in TOML sections. It does not change inline tables or multiline values.
