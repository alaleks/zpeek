//! Dialect-specific SQL for browsing the schema. Everything here is plain SQL
//! executed through `Connection.query`, so drivers stay small.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Kind = @import("../conninfo.zig").Kind;

pub const Object = enum {
    tables,
    views,
    types,
    functions,
    triggers,

    pub fn title(o: Object) []const u8 {
        return switch (o) {
            .tables => "Tables",
            .views => "Views",
            .types => "Types",
            .functions => "Functions",
            .triggers => "Triggers",
        };
    }
};

// Leading space: it is concatenated right after multi-line string literals.
// crdb_internal / pg_extension: CockroachDB's system schemas.
const pg_user_ns = " n.nspname not in ('pg_catalog', 'information_schema', 'crdb_internal', 'pg_extension') and n.nspname not like 'pg\\_toast%' and n.nspname not like 'pg\\_temp%'";

/// SQL listing objects of one kind, or null when the database has no such objects.
pub fn listSql(kind: Kind, obj: Object) ?[]const u8 {
    return switch (kind) {
        .postgres => switch (obj) {
            .tables =>
            \\select n.nspname as schema, c.relname as name,
            \\  case c.relkind when 'p' then 'partitioned' when 'f' then 'foreign' else 'table' end as kind,
            \\  greatest(c.reltuples, 0)::bigint as est_rows,
            \\  pg_size_pretty(pg_total_relation_size(c.oid)) as size,
            \\  obj_description(c.oid, 'pg_class') as comment
            \\from pg_class c join pg_namespace n on n.oid = c.relnamespace
            \\where c.relkind in ('r', 'p', 'f') and not coalesce(c.relispartition, false) and
            ++ pg_user_ns ++
                \\
                \\order by 1, 2
            ,
            .views =>
            \\select n.nspname as schema, c.relname as name,
            \\  case c.relkind when 'm' then 'materialized' else 'view' end as kind,
            \\  obj_description(c.oid, 'pg_class') as comment, c.oid::text as oid
            \\from pg_class c join pg_namespace n on n.oid = c.relnamespace
            \\where c.relkind in ('v', 'm') and
            ++ pg_user_ns ++
                \\
                \\order by 1, 2
            ,
            .types =>
            \\select n.nspname as schema, t.typname as name,
            \\  case t.typtype when 'e' then 'enum' when 'd' then 'domain' when 'c' then 'composite'
            \\    when 'r' then 'range' when 'm' then 'multirange' end as kind,
            \\  case t.typtype
            \\    when 'e' then (select string_agg(quote_literal(e.enumlabel), ', ' order by e.enumsortorder) from pg_enum e where e.enumtypid = t.oid)
            \\    when 'd' then format_type(t.typbasetype, t.typtypmod) ||
            \\      coalesce(' ' || (select string_agg(pg_get_constraintdef(k.oid), ' ') from pg_constraint k where k.contypid = t.oid), '')
            \\    when 'c' then (select string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod), ', ' order by a.attnum)
            \\      from pg_attribute a where a.attrelid = t.typrelid and a.attnum > 0 and not a.attisdropped)
            \\    when 'r' then (select format_type(r.rngsubtype, null) from pg_range r where r.rngtypid = t.oid)
            \\  end as values,
            \\  obj_description(t.oid, 'pg_type') as comment
            \\from pg_type t join pg_namespace n on n.oid = t.typnamespace
            \\where (t.typtype in ('e', 'd', 'r', 'm')
            \\    or (t.typtype = 'c' and (select c.relkind from pg_class c where c.oid = t.typrelid) = 'c'))
            \\  and not exists (select 1 from pg_depend d where d.objid = t.oid and d.deptype = 'e') and
            ++ pg_user_ns ++
                \\
                \\order by 1, 3, 2
            ,
            .functions =>
            \\select n.nspname as schema, p.proname as name,
            \\  case p.prokind when 'p' then 'procedure' when 'a' then 'aggregate' when 'w' then 'window' else 'function' end as kind,
            \\  pg_get_function_arguments(p.oid) as arguments,
            \\  pg_get_function_result(p.oid) as returns,
            \\  l.lanname as language, p.oid::text as oid
            \\from pg_proc p
            \\  join pg_namespace n on n.oid = p.pronamespace
            \\  join pg_language l on l.oid = p.prolang
            \\where not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e') and
            ++ pg_user_ns ++
                \\
                \\order by 1, 2
            ,
            .triggers =>
            \\select n.nspname as schema, c.relname as "table", t.tgname as name,
            \\  case t.tgenabled when 'D' then 'disabled' else 'enabled' end as status,
            \\  regexp_replace(pg_get_triggerdef(t.oid, true), '^CREATE (CONSTRAINT )?TRIGGER \S+ ', '') as definition,
            \\  t.oid::text as oid
            \\from pg_trigger t
            \\  join pg_class c on c.oid = t.tgrelid
            \\  join pg_namespace n on n.oid = c.relnamespace
            \\where not t.tgisinternal
            \\order by 1, 2, 3
            ,
        },
        .mysql => switch (obj) {
            .tables =>
            \\select table_name as name, engine, table_rows as est_rows,
            \\  concat(round((data_length + index_length) / 1024 / 1024, 2), ' MB') as size,
            \\  table_comment as comment
            \\from information_schema.tables
            \\where table_schema = database() and table_type = 'BASE TABLE'
            \\order by 1
            ,
            .views =>
            \\select table_name as name, is_updatable as updatable, security_type as security
            \\from information_schema.views
            \\where table_schema = database()
            \\order by 1
            ,
            .types =>
            \\select table_name as `table`, column_name as `column`, data_type as kind,
            \\  substring(column_type, length(data_type) + 2, length(column_type) - length(data_type) - 2) as `values`
            \\from information_schema.columns
            \\where table_schema = database() and data_type in ('enum', 'set')
            \\order by 1, 2
            ,
            .functions =>
            \\select r.routine_name as name, lower(r.routine_type) as kind,
            \\  (select group_concat(concat_ws(' ', p.parameter_mode, p.parameter_name, p.dtd_identifier)
            \\     order by p.ordinal_position separator ', ')
            \\   from information_schema.parameters p
            \\   where p.specific_schema = r.routine_schema and p.specific_name = r.specific_name
            \\     and p.ordinal_position > 0) as arguments,
            \\  r.dtd_identifier as returns,
            \\  r.is_deterministic as `deterministic`
            \\from information_schema.routines r
            \\where r.routine_schema = database()
            \\order by 1
            ,
            .triggers =>
            \\select event_object_table as `table`, trigger_name as name,
            \\  concat(action_timing, ' ', event_manipulation) as event, action_orientation as `for each`
            \\from information_schema.triggers
            \\where trigger_schema = database()
            \\order by 1, 2
            ,
        },
        .sqlite => switch (obj) {
            .tables =>
            \\select name, case when sql like '%WITHOUT ROWID%' then 'without rowid' else 'table' end as kind
            \\from sqlite_schema
            \\where type = 'table' and name not like 'sqlite\_%' escape '\'
            \\order by 1
            ,
            .views => "select name from sqlite_schema where type = 'view' order by 1",
            .triggers => "select tbl_name as \"table\", name from sqlite_schema where type = 'trigger' order by 1, 2",
            .types, .functions => null,
        },
        .clickhouse => switch (obj) {
            .tables =>
            \\select name, engine, total_rows as rows, formatReadableSize(total_bytes) as size, comment
            \\from system.tables
            \\where database = currentDatabase() and not is_temporary
            \\  and engine not in ('View', 'MaterializedView', 'LiveView')
            \\order by name
            ,
            .views =>
            \\select name, engine as kind, as_select as query
            \\from system.tables
            \\where database = currentDatabase() and engine in ('View', 'MaterializedView', 'LiveView')
            \\order by name
            ,
            // ClickHouse has no named types; enum columns carry their values in the type.
            .types =>
            \\select table, name as column, type
            \\from system.columns
            \\where database = currentDatabase() and match(type, 'Enum(8|16)?\\(')
            \\order by table, name
            ,
            .functions =>
            \\select name, create_query as definition
            \\from system.functions
            \\where origin = 'SQLUserDefined'
            \\order by name
            ,
            .triggers => null,
        },
    };
}

/// Explains why `listSql` returned null.
pub fn unsupportedReason(kind: Kind, obj: Object) []const u8 {
    if (kind == .clickhouse) return "ClickHouse has no triggers (use materialized views)";
    return switch (obj) {
        .types => "SQLite has no user-defined types",
        .functions => "SQLite has no stored functions",
        else => "not supported",
    };
}

/// Queries describing a table: columns first, then indexes (and foreign keys).
pub fn describeSql(a: Allocator, kind: Kind, table: []const u8) Allocator.Error![]const []const u8 {
    switch (kind) {
        .postgres => {
            const reg = try quoteLiteral(a, kind, try quoteName(a, kind, table));
            return a.dupe([]const u8, &.{
                try std.fmt.allocPrint(a,
                    \\select a.attname as column, format_type(a.atttypid, a.atttypmod) as type,
                    \\  case when a.attnotnull then 'NO' else 'YES' end as nullable,
                    \\  pg_get_expr(d.adbin, d.adrelid) as default,
                    \\  (select 'PK' from pg_index i where i.indrelid = a.attrelid and i.indisprimary and a.attnum = any(i.indkey)) as key,
                    \\  col_description(a.attrelid, a.attnum) as comment
                    \\from pg_attribute a
                    \\  left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
                    \\where a.attrelid = {s}::regclass and a.attnum > 0 and not a.attisdropped
                    \\order by a.attnum
                , .{reg}),
                try std.fmt.allocPrint(a,
                    \\select c.relname as index, pg_get_indexdef(i.indexrelid) as definition
                    \\from pg_index i join pg_class c on c.oid = i.indexrelid
                    \\where i.indrelid = {s}::regclass
                    \\order by i.indisprimary desc, 1
                , .{reg}),
                try std.fmt.allocPrint(a,
                    \\select conname as constraint, pg_get_constraintdef(oid, true) as definition
                    \\from pg_constraint
                    \\where conrelid = {s}::regclass and contype in ('f', 'c', 'u', 'x')
                    \\order by contype, 1
                , .{reg}),
            });
        },
        .mysql => {
            const lit = try quoteLiteral(a, kind, table);
            return a.dupe([]const u8, &.{
                try std.fmt.allocPrint(a,
                    \\select column_name as `column`, column_type as type, is_nullable as nullable,
                    \\  column_default as `default`, column_key as `key`, extra, column_comment as comment
                    \\from information_schema.columns
                    \\where table_schema = database() and table_name = {s}
                    \\order by ordinal_position
                , .{lit}),
                try std.fmt.allocPrint(a,
                    \\select index_name as `index`, if(non_unique = 0, 'unique', '') as uniq,
                    \\  group_concat(column_name order by seq_in_index separator ', ') as columns
                    \\from information_schema.statistics
                    \\where table_schema = database() and table_name = {s}
                    \\group by index_name, non_unique
                    \\order by index_name = 'PRIMARY' desc, 1
                , .{lit}),
                try std.fmt.allocPrint(a,
                    \\select constraint_name as `constraint`,
                    \\  concat(group_concat(column_name order by ordinal_position separator ', '), ' -> ',
                    \\    referenced_table_name, '(', group_concat(referenced_column_name order by ordinal_position separator ', '), ')') as `references`
                    \\from information_schema.key_column_usage
                    \\where table_schema = database() and table_name = {s} and referenced_table_name is not null
                    \\group by constraint_name, referenced_table_name
                    \\order by 1
                , .{lit}),
            });
        },
        .sqlite => {
            const lit = try quoteLiteral(a, kind, table);
            return a.dupe([]const u8, &.{
                try std.fmt.allocPrint(a,
                    \\select name as "column", type, case when "notnull" then 'NO' else 'YES' end as nullable,
                    \\  dflt_value as "default", case when pk > 0 then 'PK' end as "key"
                    \\from pragma_table_info({s})
                    \\order by cid
                , .{lit}),
                try std.fmt.allocPrint(a,
                    \\select il.name as "index", case when il."unique" then 'unique' else '' end as uniq,
                    \\  (select group_concat(ii.name, ', ') from pragma_index_info(il.name) ii) as columns
                    \\from pragma_index_list({s}) il
                    \\order by 1
                , .{lit}),
                try std.fmt.allocPrint(a,
                    \\select "from" as "column", "table" || '(' || coalesce("to", '?') || ')' as "references",
                    \\  on_update, on_delete
                    \\from pragma_foreign_key_list({s})
                , .{lit}),
            });
        },
        .clickhouse => {
            const where = try chWhere(a, table, "table");
            return a.dupe([]const u8, &.{
                try std.fmt.allocPrint(a,
                    \\select name as column, type, default_kind, default_expression as default,
                    \\  multiIf(is_in_primary_key, 'PK', is_in_sorting_key, 'sort', '') as key, comment
                    \\from system.columns
                    \\where {s}
                    \\order by position
                , .{where}),
                try std.fmt.allocPrint(a,
                    \\select name as index, type, expr
                    \\from system.data_skipping_indices
                    \\where {s}
                    \\order by name
                , .{where}),
                try std.fmt.allocPrint(a,
                    \\select engine, sorting_key, primary_key, partition_key
                    \\from system.tables
                    \\where {s}
                , .{try chWhere(a, table, "name")}),
            });
        },
    }
}

/// `database = … and <name_column> = …` for an optionally qualified ClickHouse table.
fn chWhere(a: Allocator, table: []const u8, name_column: []const u8) Allocator.Error![]const u8 {
    const parts = splitName(table);
    const db_expr = if (parts.schema) |s| try quoteLiteral(a, .clickhouse, s) else "currentDatabase()";
    return std.fmt.allocPrint(a, "database = {s} and {s} = {s}", .{ db_expr, name_column, try quoteLiteral(a, .clickhouse, parts.name) });
}

/// SQL returning (kind, name, definition) for views, functions and triggers named `name`.
pub fn definitionSql(a: Allocator, kind: Kind, name: []const u8) Allocator.Error![]const u8 {
    switch (kind) {
        .postgres => {
            const parts = splitName(name);
            const obj = try quoteLiteral(a, kind, parts.name);
            const schema_filter = if (parts.schema) |s|
                try std.fmt.allocPrint(a, "n.nspname = {s}", .{try quoteLiteral(a, kind, s)})
            else
                pg_user_ns;
            return std.fmt.allocPrint(a,
                \\select 'view' as kind, n.nspname || '.' || c.relname as name,
                \\  'CREATE ' || case c.relkind when 'm' then 'MATERIALIZED ' else '' end || 'VIEW ' ||
                \\  quote_ident(n.nspname) || '.' || quote_ident(c.relname) || E' AS\n' || pg_get_viewdef(c.oid, true) as definition
                \\from pg_class c join pg_namespace n on n.oid = c.relnamespace
                \\where c.relkind in ('v', 'm') and c.relname = {[obj]s} and {[sf]s}
                \\union all
                \\select case p.prokind when 'p' then 'procedure' else 'function' end, n.nspname || '.' || p.proname,
                \\  pg_get_functiondef(p.oid)
                \\from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                \\where p.prokind in ('f', 'p', 'w') and p.proname = {[obj]s} and {[sf]s}
                \\union all
                \\select 'trigger', n.nspname || '.' || c.relname || '.' || t.tgname, pg_get_triggerdef(t.oid, true)
                \\from pg_trigger t join pg_class c on c.oid = t.tgrelid join pg_namespace n on n.oid = c.relnamespace
                \\where not t.tgisinternal and t.tgname = {[obj]s} and {[sf]s}
                \\union all
                \\select 'type', n.nspname || '.' || t.typname,
                \\  'CREATE TYPE ' || quote_ident(n.nspname) || '.' || quote_ident(t.typname) || ' AS ENUM (' ||
                \\  (select string_agg(quote_literal(e.enumlabel), ', ' order by e.enumsortorder) from pg_enum e where e.enumtypid = t.oid) || ')'
                \\from pg_type t join pg_namespace n on n.oid = t.typnamespace
                \\where t.typtype = 'e' and t.typname = {[obj]s} and {[sf]s}
            , .{ .obj = obj, .sf = schema_filter });
        },
        .mysql => {
            const lit = try quoteLiteral(a, kind, name);
            return std.fmt.allocPrint(a,
                \\select 'view' as kind, table_name as name, concat('CREATE VIEW ', table_name, ' AS\n', view_definition) as definition
                \\from information_schema.views where table_schema = database() and table_name = {[n]s}
                \\union all
                \\select lower(r.routine_type), r.routine_name,
                \\  concat('CREATE ', r.routine_type, ' ', r.routine_name, '(',
                \\    coalesce((select group_concat(concat_ws(' ', p.parameter_mode, p.parameter_name, p.dtd_identifier)
                \\       order by p.ordinal_position separator ', ')
                \\     from information_schema.parameters p
                \\     where p.specific_schema = r.routine_schema and p.specific_name = r.specific_name
                \\       and p.ordinal_position > 0), ''), ')',
                \\    if(r.routine_type = 'FUNCTION', concat(' RETURNS ', r.dtd_identifier), ''), '\n', r.routine_definition)
                \\from information_schema.routines r where r.routine_schema = database() and r.routine_name = {[n]s}
                \\union all
                \\select 'trigger', trigger_name,
                \\  concat('CREATE TRIGGER ', trigger_name, ' ', action_timing, ' ', event_manipulation, ' ON ',
                \\    event_object_table, ' FOR EACH ROW\n', action_statement)
                \\from information_schema.triggers where trigger_schema = database() and trigger_name = {[n]s}
            , .{ .n = lit });
        },
        .sqlite => return std.fmt.allocPrint(a,
            \\select type as kind, name, sql as definition from sqlite_schema where name = {s} and sql is not null
        , .{try quoteLiteral(a, kind, name)}),
        .clickhouse => return std.fmt.allocPrint(a,
            \\select if(engine in ('View', 'MaterializedView', 'LiveView'), 'view', 'table') as kind, name,
            \\  create_table_query as definition
            \\from system.tables where {[w]s}
            \\union all
            \\select 'function', name, create_query from system.functions
            \\where origin = 'SQLUserDefined' and name = {[n]s}
        , .{ .w = try chWhere(a, name, "name"), .n = try quoteLiteral(a, kind, splitName(name).name) }),
    }
}

/// Resolve a selected PostgreSQL row by OID, so overloaded routines and
/// triggers with the same name on different tables remain distinct.
pub fn definitionSqlForOid(a: Allocator, obj: Object, oid_text: []const u8) (Allocator.Error || error{InvalidOid})![]const u8 {
    const oid = std.fmt.parseInt(u32, oid_text, 10) catch return error.InvalidOid;
    return switch (obj) {
        .views => std.fmt.allocPrint(a,
            \\select 'view', n.nspname || '.' || c.relname,
            \\  'CREATE ' || case c.relkind when 'm' then 'MATERIALIZED ' else '' end || 'VIEW ' ||
            \\  quote_ident(n.nspname) || '.' || quote_ident(c.relname) || E' AS\n' || pg_get_viewdef(c.oid, true)
            \\from pg_class c join pg_namespace n on n.oid = c.relnamespace
            \\where c.oid = {d} and c.relkind in ('v', 'm')
        , .{oid}),
        .functions => std.fmt.allocPrint(a,
            \\select case p.prokind when 'p' then 'procedure' when 'a' then 'aggregate' else 'function' end,
            \\  n.nspname || '.' || p.proname,
            \\  case when p.prokind = 'a' then '-- aggregate definition is not available' else pg_get_functiondef(p.oid) end
            \\from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            \\where p.oid = {d}
        , .{oid}),
        .triggers => std.fmt.allocPrint(a,
            \\select 'trigger', n.nspname || '.' || c.relname || '.' || t.tgname, pg_get_triggerdef(t.oid, true)
            \\from pg_trigger t join pg_class c on c.oid = t.tgrelid join pg_namespace n on n.oid = c.relnamespace
            \\where t.oid = {d} and not t.tgisinternal
        , .{oid}),
        else => error.InvalidOid,
    };
}

pub fn definitionSqlForObject(a: Allocator, kind: Kind, obj: Object, name: []const u8, selected_kind: []const u8) Allocator.Error![]const u8 {
    const lit = try quoteLiteral(a, kind, name);
    return switch (kind) {
        .postgres => definitionSql(a, kind, name),
        .sqlite => std.fmt.allocPrint(
            a,
            "select type as kind, name, sql as definition from sqlite_schema where type = '{s}' and name = {s} and sql is not null",
            .{ if (obj == .triggers) @as([]const u8, "trigger") else "view", lit },
        ),
        .mysql => switch (obj) {
            .views => std.fmt.allocPrint(a,
                \\select 'view' as kind, table_name as name,
                \\  concat('CREATE VIEW ', table_name, ' AS\n', view_definition) as definition
                \\from information_schema.views where table_schema = database() and table_name = {s}
            , .{lit}),
            .functions => std.fmt.allocPrint(a,
                \\select lower(r.routine_type) as kind, r.routine_name as name,
                \\  concat('CREATE ', r.routine_type, ' ', r.routine_name, '(',
                \\    coalesce((select group_concat(concat_ws(' ', p.parameter_mode, p.parameter_name, p.dtd_identifier)
                \\       order by p.ordinal_position separator ', ')
                \\     from information_schema.parameters p
                \\     where p.specific_schema = r.routine_schema and p.specific_name = r.specific_name
                \\       and p.ordinal_position > 0), ''), ')',
                \\    if(r.routine_type = 'FUNCTION', concat(' RETURNS ', r.dtd_identifier), ''), '\n', r.routine_definition) as definition
                \\from information_schema.routines r where r.routine_schema = database() and r.routine_name = {s}
                \\  and lower(r.routine_type) = {s}
            , .{ lit, try quoteLiteral(a, kind, selected_kind) }),
            .triggers => std.fmt.allocPrint(a,
                \\select 'trigger' as kind, trigger_name as name,
                \\  concat('CREATE TRIGGER ', trigger_name, ' ', action_timing, ' ', event_manipulation, ' ON ',
                \\    event_object_table, ' FOR EACH ROW\n', action_statement) as definition
                \\from information_schema.triggers where trigger_schema = database() and trigger_name = {s}
            , .{lit}),
            else => definitionSql(a, kind, name),
        },
        .clickhouse => switch (obj) {
            .views => std.fmt.allocPrint(a,
                \\select 'view' as kind, name, create_table_query as definition
                \\from system.tables where {s} and engine in ('View', 'MaterializedView', 'LiveView')
            , .{try chWhere(a, name, "name")}),
            .functions => std.fmt.allocPrint(a,
                \\select 'function' as kind, name, create_query as definition
                \\from system.functions where origin = 'SQLUserDefined' and name = {s}
            , .{try quoteLiteral(a, kind, splitName(name).name)}),
            else => definitionSql(a, kind, name),
        },
    };
}

/// (table, column) pairs for autocompletion.
pub fn completionSql(kind: Kind) []const u8 {
    return switch (kind) {
        .postgres =>
        \\select case when n.nspname = any(current_schemas(false)) then c.relname else n.nspname || '.' || c.relname end,
        \\  a.attname
        \\from pg_class c
        \\  join pg_namespace n on n.oid = c.relnamespace
        \\  left join pg_attribute a on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
        \\where c.relkind in ('r', 'p', 'v', 'm', 'f') and
        ++ pg_user_ns ++
            \\
            \\order by 1, a.attnum
        ,
        .mysql =>
        \\select table_name, column_name from information_schema.columns
        \\where table_schema = database() order by table_name, ordinal_position
        ,
        .sqlite =>
        \\select m.name, p.name from sqlite_schema m join pragma_table_info(m.name) p
        \\where m.type in ('table', 'view') and m.name not like 'sqlite\_%' escape '\'
        \\order by m.name, p.cid
        ,
        .clickhouse =>
        \\select table, name from system.columns
        \\where database = currentDatabase() order by table, position
        ,
    };
}

/// SQL listing databases (MySQL) or schemas (PostgreSQL) for `/databases`.
pub fn databasesSql(kind: Kind) ?[]const u8 {
    return switch (kind) {
        .postgres => "select datname as database, pg_size_pretty(pg_database_size(datname)) as size from pg_database where not datistemplate order by 1",
        .mysql => "show databases",
        .sqlite => "select name, file from pragma_database_list",
        .clickhouse => "select name as database, engine from system.databases order by name",
    };
}

pub const Order = struct {
    column: []const u8,
    descending: bool = false,
};

pub fn browseSql(
    a: Allocator,
    kind: Kind,
    table: []const u8,
    filter: ?[]const u8,
    order: ?Order,
    limit: usize,
    offset: usize,
) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(a, "select * from {s}", .{try quoteName(a, kind, table)});
    if (filter) |f| {
        if (std.mem.trim(u8, f, " \t").len > 0) try out.print(a, " where {s}", .{f});
    }
    if (order) |o| {
        try out.print(a, " order by {s}{s}", .{ try quoteIdent(a, kind, o.column), if (o.descending) " desc" else "" });
    }
    try out.print(a, " limit {d} offset {d}", .{ limit, offset });
    return out.items;
}

/// Primary key column names of `table`, in key order.
pub fn primaryKeySql(a: Allocator, kind: Kind, table: []const u8) Allocator.Error![]const u8 {
    return switch (kind) {
        .postgres => std.fmt.allocPrint(a,
            \\select a.attname from pg_index i
            \\  join pg_attribute a on a.attrelid = i.indrelid and a.attnum = any(i.indkey)
            \\where i.indrelid = {s}::regclass and i.indisprimary
            \\order by array_position(i.indkey::int2[], a.attnum)
        , .{try quoteLiteral(a, kind, try quoteName(a, kind, table))}),
        .mysql => std.fmt.allocPrint(a,
            \\select column_name from information_schema.key_column_usage
            \\where table_schema = database() and table_name = {s} and constraint_name = 'PRIMARY'
            \\order by ordinal_position
        , .{try quoteLiteral(a, kind, splitName(table).name)}),
        .sqlite => std.fmt.allocPrint(a,
            \\select name from pragma_table_info({s}) where pk > 0 order by pk
        , .{try quoteLiteral(a, kind, table)}),
        // Row deletion is disabled for ClickHouse (no point deletes); no key needed.
        .clickhouse => a.dupe(u8, "select 1 where 0"),
    };
}

/// `DELETE FROM table WHERE pk1 = v1 AND …` for one row. Values are passed as
/// literals (the server casts them to the column types); NULL becomes IS NULL.
pub fn deleteRowSql(
    a: Allocator,
    kind: Kind,
    table: []const u8,
    key_columns: []const []const u8,
    key_values: []const ?[]const u8,
) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(a, "DELETE FROM {s} WHERE ", .{try quoteName(a, kind, table)});
    for (key_columns, key_values, 0..) |col, value, i| {
        if (i > 0) try out.appendSlice(a, " AND ");
        try out.appendSlice(a, try quoteIdent(a, kind, col));
        if (value) |v| {
            try out.print(a, " = {s}", .{try quoteLiteral(a, kind, v)});
        } else {
            try out.appendSlice(a, " IS NULL");
        }
    }
    return out.items;
}

pub fn countSql(a: Allocator, kind: Kind, table: []const u8, filter: ?[]const u8) Allocator.Error![]const u8 {
    const where: []const u8 = if (filter) |f|
        (if (std.mem.trim(u8, f, " \t").len > 0) try std.fmt.allocPrint(a, " where {s}", .{f}) else "")
    else
        "";
    return std.fmt.allocPrint(a, "select count(*) from {s}{s}", .{ try quoteName(a, kind, table), where });
}

pub const Name = struct {
    schema: ?[]const u8,
    name: []const u8,
};

/// Splits `schema.table`; names already quoted by the user are unwrapped.
pub fn splitName(s: []const u8) Name {
    var in_quote: u8 = 0;
    for (s, 0..) |c, i| {
        if (in_quote != 0) {
            if (c == in_quote) in_quote = 0;
        } else if (c == '"' or c == '`') {
            in_quote = c;
        } else if (c == '.') {
            return .{ .schema = unquote(s[0..i]), .name = unquote(s[i + 1 ..]) };
        }
    }
    return .{ .schema = null, .name = unquote(s) };
}

fn unquote(s: []const u8) []const u8 {
    if (s.len >= 2 and (s[0] == '"' or s[0] == '`') and s[s.len - 1] == s[0]) return s[1 .. s.len - 1];
    return s;
}

/// Quotes a possibly schema-qualified name.
pub fn quoteName(a: Allocator, kind: Kind, name: []const u8) Allocator.Error![]const u8 {
    const parts = splitName(name);
    const n = try quoteIdent(a, kind, parts.name);
    if (parts.schema) |s| return std.fmt.allocPrint(a, "{s}.{s}", .{ try quoteIdent(a, kind, s), n });
    return n;
}

pub fn quoteIdent(a: Allocator, kind: Kind, ident: []const u8) Allocator.Error![]const u8 {
    const q: u8 = if (kind == .mysql or kind == .clickhouse) '`' else '"';
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, q);
    for (ident) |c| {
        if (c == q) try out.append(a, q);
        try out.append(a, c);
    }
    try out.append(a, q);
    return out.items;
}

pub fn quoteLiteral(a: Allocator, kind: Kind, s: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, '\'');
    for (s) |c| {
        if (c == '\'') try out.append(a, '\'');
        // MySQL and ClickHouse treat backslash as an escape inside literals.
        if (c == '\\' and (kind == .mysql or kind == .clickhouse)) try out.append(a, '\\');
        try out.append(a, c);
    }
    try out.append(a, '\'');
    return out.items;
}

const testing = std.testing;

test "delete row sql" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings(
        "DELETE FROM \"sales\".\"orders\" WHERE \"id\" = '42' AND \"part\" IS NULL",
        try deleteRowSql(a, .postgres, "sales.orders", &.{ "id", "part" }, &.{ "42", null }),
    );
    try testing.expectEqualStrings(
        "DELETE FROM `t` WHERE `name` = 'O''Brien\\\\'",
        try deleteRowSql(a, .mysql, "t", &.{"name"}, &.{"O'Brien\\"}),
    );
}

test "quoting" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("\"public\".\"Us\"\"ers\"", try quoteName(a, .postgres, "public.Us\"ers"));
    try testing.expectEqualStrings("`my.table`", try quoteName(a, .mysql, "`my.table`"));
    try testing.expectEqualStrings("'it''s'", try quoteLiteral(a, .postgres, "it's"));
    try testing.expectEqualStrings(
        "select * from \"t\" where id > 3 order by \"name\" desc limit 100 offset 200",
        try browseSql(a, .sqlite, "t", "id > 3", .{ .column = "name", .descending = true }, 100, 200),
    );
    try testing.expectEqualStrings(
        "select count(*) from \"t\" where id > 3",
        try countSql(a, .sqlite, "t", "id > 3"),
    );
}

test "selected definition resolves by PostgreSQL OID" {
    const a = testing.allocator;
    const sql = try definitionSqlForOid(a, .functions, "42");
    defer a.free(sql);
    try testing.expect(std.mem.indexOf(u8, sql, "where p.oid = 42") != null);
    try testing.expectError(error.InvalidOid, definitionSqlForOid(a, .triggers, "42; drop table x"));
}

test "selected definition filters object kind" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sql = try definitionSqlForObject(a, .sqlite, .triggers, "audit", "");
    try testing.expect(std.mem.indexOf(u8, sql, "type = 'trigger'") != null);
    const mysql = try definitionSqlForObject(a, .mysql, .functions, "calculate", "procedure");
    try testing.expect(std.mem.indexOf(u8, mysql, "lower(r.routine_type) = 'procedure'") != null);
    const clickhouse = try definitionSqlForObject(a, .clickhouse, .views, "report", "View");
    try testing.expect(std.mem.indexOf(u8, clickhouse, "engine in ('View', 'MaterializedView', 'LiveView')") != null);
}
