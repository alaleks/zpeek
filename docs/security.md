# Security and access modes

[← README](../README.md) · [Connections](connections.md) · [Configuration](configuration.md) · [Usage](usage.md)

## Security boundary

**Use database permissions to control what an account can do.** zpeek checks SQL before sending it, but those checks cannot catch every side effect of a function or trigger. Some routines also run with privileges that the calling account does not normally have.

For a restricted account, grant only the required `SELECT` permissions and add `DELETE` if needed. Avoid schema ownership and DDL privileges. Review callable routines and triggers with elevated privileges as well. zpeek's access modes add checks on top of those permissions.

## Access modes

Set `access` inside each saved connection:

```toml
[connections.prod]
url = "postgres://user@host:5432/app"
access = "read_delete"
```

| Mode | Allowed operations |
| --- | --- |
| `"read_only"` | Reading queries such as `SELECT`, `WITH`, `SHOW`, and `EXPLAIN`; row deletion in `/browse` is disabled |
| `"read_delete"` | Reading queries and `DELETE … WHERE …`, including confirmed row deletion in `/browse` |
| `"full"` | All operations; the default when no access setting is present |

`read_delete` blocks `INSERT`, `UPDATE`, `TRUNCATE`, and schema changes: creating, altering, or dropping tables, views, indexes, keys, and schemas. **`DROP` and `CREATE` require `full`.** For example, this whole script is refused in either restricted mode before it is sent to the database:

```sql
DROP SCHEMA IF EXISTS public CASCADE;
CREATE SCHEMA IF NOT EXISTS public;
```

zpeek checks an entire SQL script before executing it. A forbidden statement prevents the whole script from running. Browse filters may only read in every mode; use the SQL prompt for writes. Restricted modes accept only known metadata-reading PRAGMAs, and reject executable MySQL comments and deletes nested in CTEs.

## Confirmation in full mode

SQL containing `DROP`, `TRUNCATE`, `UPDATE`, or `DELETE` opens a confirmation dialog. **Cancel** is selected by default. Choose **Run SQL** and press `enter` to run the script shown. Canceling runs none of it.

Even an UPDATE or DELETE with a WHERE clause needs confirmation: the condition could match every row. Commands that can hide other actions also need approval, including `DO`, `CALL`, `EXECUTE` and executable MySQL comments.

For CLI execution, approval is explicit:

```sh
zpeek prod -e 'update users set active = false where last_seen < current_date - 365' --allow-dangerous
```

Without `--allow-dangerous`, zpeek refuses these scripts. The flag does not override a restricted access mode or allow DELETE without WHERE. Deleting a row in `/browse` still asks for confirmation.

`/explain` asks for a plan without ANALYZE. It does not execute the write to obtain runtime statistics.

These safeguards do not discover arbitrary side effects in database functions; the [security boundary](#security-boundary) still applies.

The older `read_only = true` remains equivalent to `access = "read_only"`; `false` means `"full"`. Top-level access settings and conflicting `access`/`read_only` values are rejected.

## Applying a changed mode

Saving an access change through `/config edit` closes the old session. Reconnect with `/connect <name>` to apply the saved mode. Named connections and the connection picker reload the config before connecting, so external edits are picked up too. The connection message and footer show the active mode.

Connecting directly by URL creates an ad-hoc connection with `full` access. Use the saved connection name to apply its configured restrictions.

## Driver enforcement

In `read_only`, PostgreSQL and MySQL also get a read-only session. SQLite opens the file read-only. ClickHouse sends `readonly=2` with every request. If the server rejects the read-only setting, connection fails instead of opening writable.

In `read_delete`, SQLite additionally uses its authorizer to reject other writes, including writes hidden in existing triggers. A deletion that fires a trigger which inserts or updates data can therefore fail. Server databases still need the permissions described in [Security boundary](#security-boundary).

## Deleting rows

zpeek refuses `DELETE` without a top-level `WHERE` clause. A WHERE inside a subquery does not count; neither does one in quoted text or a comment. This catches a missing condition, but it cannot judge the condition itself. `WHERE true` still deletes every row.

In `/browse`, `d` prepares deletion of the selected row for confirmation. It requires a primary key and is unavailable for ClickHouse or `read_only` connections.

## Credentials and local files

URLs containing passwords and `password` fields are saved as plain text in the configuration. Prefer `password_env` when appropriate. New or replaced config files are private to the user on Unix.

Connection strings entered through `/connect` and `/config add` are redacted in the transcript and command history. Text edited through `/config edit` is not added to history. Clipboard copying uses OSC 52 and requires a terminal that permits clipboard writes.
