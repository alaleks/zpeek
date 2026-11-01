# Security and access modes

[← README](../README.md) · [Connections](connections.md) · [Configuration](configuration.md) · [Usage](usage.md)

## Security boundary

**Client-side SQL checks are not a security boundary.** On server databases, functions and triggers can have side effects, including through routines with elevated privileges. A client cannot turn a broadly privileged database account into a reliably restricted one simply by inspecting SQL text.

For hard guarantees, use database permissions: a role with only the required `SELECT` and, when needed, `DELETE` grants, without schema ownership or DDL privileges. Review callable routines and triggers with elevated privileges too. The configured modes below provide additional safeguards within zpeek.

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

Interactive SQL containing `DROP`, `TRUNCATE`, `UPDATE`, or `DELETE` opens a review dialog before anything runs. Cancel is selected by default; select **Run SQL** and press `enter` to approve the exact script. A canceled batch executes no statements. All UPDATE/DELETE statements require confirmation because a WHERE clause alone does not guarantee a small change. `DO`, `CALL`, `EXECUTE`, and executable MySQL comments also request confirmation because they can hide other actions.

For CLI execution, approval is explicit:

```sh
zpeek prod -e 'update users set active = false where last_seen < current_date - 365' --allow-dangerous
```

Without `--allow-dangerous`, these scripts are refused. The flag does not bypass `read_only`/`read_delete` restrictions or the DELETE-without-WHERE safeguard. Selected-row deletion in `/browse` retains its own confirmation. `/explain` generates a plan without ANALYZE; it does not use confirmation to execute the underlying write.

These safeguards do not discover arbitrary side effects in database functions; the [security boundary](#security-boundary) still applies.

The older `read_only = true` remains equivalent to `access = "read_only"`; `false` means `"full"`. Top-level access settings and conflicting `access`/`read_only` values are rejected.

## Applying a changed mode

Saving an access change through `/config edit` closes the old session. Reconnect with `/connect <name>` to apply the saved mode. Named connections and the connection picker reload the config before connecting, so external edits are picked up too. The connection message and footer show the active mode.

Connecting directly by URL creates an ad-hoc connection with `full` access. Use the saved connection name to apply its configured restrictions.

## Driver enforcement

In `read_only`, PostgreSQL and MySQL also get a read-only session. SQLite opens the file read-only. ClickHouse sends `readonly=2` with every request. If the server rejects the read-only setting, connection fails instead of opening writable.

In `read_delete`, SQLite additionally uses its authorizer to reject other writes, including writes hidden in existing triggers. A deletion that fires a trigger which inserts or updates data can therefore fail. Server databases still need the permissions described in [Security boundary](#security-boundary).

## Deleting rows

zpeek refuses `DELETE` without a top-level `WHERE` clause. A `WHERE` inside a subquery, string, or comment does not satisfy the safeguard. `WHERE true` explicitly deletes every row; this check is protection against accidental omission, not a promise that a deletion affects only a few rows.

In `/browse`, `d` prepares deletion of the selected row for confirmation. It requires a primary key and is unavailable for ClickHouse or `read_only` connections.

## Credentials and local files

URLs containing passwords and `password` fields are saved as plain text in the configuration. Prefer `password_env` when appropriate. New or replaced config files are private to the user on Unix.

Connection strings entered through `/connect` and `/config add` are redacted in the transcript and command history. Text edited through `/config edit` is not added to history. Clipboard copying uses OSC 52 and requires a terminal that permits clipboard writes.
