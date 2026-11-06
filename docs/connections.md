# Connections

[← README](../README.md) · [Configuration](configuration.md) · [Security](security.md) · [Usage](usage.md)

## Supported databases

PostgreSQL, MySQL/MariaDB, SQLite, and ClickHouse have built-in drivers. CockroachDB and YugabyteDB work through the PostgreSQL protocol; TiDB works through the MySQL protocol. Other protocol-compatible services may work but have not been tested.

SQLite has no stored functions or custom types. ClickHouse has no triggers, and row deletion through `/browse` is unavailable for ClickHouse.

## URLs and paths

```sh
zpeek ./data.sqlite
zpeek 'sqlite:///absolute/path/data.sqlite'
zpeek 'postgres://user:pass@host:5432/db'
zpeek 'mysql://user:pass@host:3306/db'
zpeek 'mariadb://user:pass@host:3306/db'
zpeek 'clickhouse://user:pass@host:8123/db'
```

PostgreSQL also accepts `postgresql://` and libpq-style parameters:

```sh
zpeek 'host=localhost port=5432 user=postgres dbname=app'
```

Use `/connect` to choose a connection. If you know its name or URL, enter `/connect <name|url>` directly. `/disconnect` closes the current connection. zpeek hides connection URLs and paths in its transcript and history.

A direct URL connection uses `full` access. Connect by a saved name to use that profile's restrictions. You can check the active mode in the footer. See [access modes](security.md#access-modes).

## Saved connections

Create an example configuration and list saved profiles:

```sh
zpeek --init-config
zpeek --list
```

Example `~/.config/zpeek/config.toml`:

```toml
default = "local"

[connections.local]
url = "postgres://postgres@localhost:5432/app"
color = "#2F6B43"
access = "read_only"

[connections.shop]
driver = "mysql"
host = "127.0.0.1"
user = "root"
password_env = "SHOP_DB_PASSWORD"
database = "shop"
access = "read_delete"
```

```sh
zpeek shop
zpeek shop -e 'select count(*) from users'
```

Running `zpeek` without an argument opens your `default` connection. Without a default, it opens the only saved connection if there is one; otherwise it asks you to choose. The config is read again before connecting to a saved profile, so you can edit it outside zpeek.

Connection fields such as `host`, `port`, `user`, `password`, and `database` override values from `url`. See the [complete field reference](configuration.md#toml-fields) and [in-app editor](configuration.md#edit-the-file-inside-zpeek).

## Configuration location

zpeek uses the first applicable path:

1. `--config <path>` / `-c <path>`.
2. `$ZPEEK_CONFIG`.
3. `$XDG_CONFIG_HOME/zpeek/config.toml`.
4. `$HOME/.config/zpeek/config.toml`.
5. On Windows without `HOME`, `%APPDATA%\zpeek\config.toml`.

Saved queries live in a `queries` directory beside the selected config file.

## Passwords and environment variables

Set `password_env = "SHOP_DB_PASSWORD"` to read a saved connection's password from that variable. It takes precedence over the URL password and the `password` field. If the variable is missing, the password is cleared and the rest of the config still loads.

An empty connection password can also be filled from the driver-specific variable:

| Driver | Variable |
| --- | --- |
| PostgreSQL | `PGPASSWORD` |
| MySQL/MariaDB | `MYSQL_PWD` |
| ClickHouse | `CLICKHOUSE_PASSWORD` |

The CLI also accepts `--password`. Passwords embedded in a saved URL or a `password` field are stored as plain text in the config; prefer `password_env` when appropriate.

## TLS

Connection URLs accept `sslmode=disable|prefer|require|verify-ca|verify-full`; the default is `prefer`.

```sh
zpeek 'postgres://user@host:5432/db?sslmode=verify-full'
```

Saved entries can use a separate `sslmode = "verify-full"` field. ClickHouse uses HTTP on port 8123 or HTTPS on 8443. The default `prefer` mode does not guarantee encryption. Set the mode explicitly when your connection requires TLS.

## CLI connection fields

You can supply or override connection fields with `--driver`, `--host`, `--port`, `--user`, `--password`, and `--database`:

```sh
zpeek --driver postgres --host localhost --port 5432 --user postgres --database app
```

`--driver` accepts `postgres`, `mysql`, `mariadb`, `sqlite`, or `clickhouse`. An unknown name is an argument error, including when overriding a saved profile. Run `zpeek --help` for all CLI options.
