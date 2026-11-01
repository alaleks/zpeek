//! A forgiving SQL tokenizer for highlighting and completion. It never fails:
//! unterminated strings and comments simply run to the end of input.

const std = @import("std");

pub const Dialect = enum { postgres, mysql, sqlite };

pub const Tag = enum {
    whitespace,
    keyword,
    /// Built-in function or type name (count, now, varchar, ...).
    builtin,
    identifier,
    quoted_identifier,
    string,
    number,
    comment,
    operator,
    punctuation,
    /// $1, ?, :name
    parameter,
};

pub const Token = struct {
    tag: Tag,
    start: usize,
    end: usize,

    pub fn text(t: Token, src: []const u8) []const u8 {
        return src[t.start..t.end];
    }
};

pub const Iterator = struct {
    src: []const u8,
    dialect: Dialect = .postgres,
    pos: usize = 0,

    pub fn init(src: []const u8) Iterator {
        return .{ .src = src };
    }

    pub fn initDialect(src: []const u8, dialect: Dialect) Iterator {
        return .{ .src = src, .dialect = dialect };
    }

    pub fn next(it: *Iterator) ?Token {
        const s = it.src;
        if (it.pos >= s.len) return null;
        const start = it.pos;
        const c = s[start];
        var tag: Tag = .punctuation;
        var i = start + 1;

        switch (c) {
            ' ', '\t', '\r', '\n' => {
                tag = .whitespace;
                while (i < s.len and std.ascii.isWhitespace(s[i])) i += 1;
            },
            '-' => if (i < s.len and s[i] == '-') {
                tag = .comment;
                while (i < s.len and s[i] != '\n') i += 1;
            } else {
                tag = .operator;
            },
            '#' => {
                // MySQL line comment; harmless elsewhere since '#' is rare in SQL.
                tag = .comment;
                while (i < s.len and s[i] != '\n') i += 1;
            },
            '/' => if (i < s.len and s[i] == '*') {
                tag = .comment;
                i += 1;
                while (i < s.len and !(s[i] == '/' and s[i - 1] == '*' and i - 1 > start + 1)) i += 1;
                if (i < s.len) i += 1;
            } else {
                tag = .operator;
            },
            '\'' => {
                tag = .string;
                i = scanQuoted(s, i, '\'', it.dialect == .mysql);
            },
            '"' => {
                tag = .quoted_identifier;
                i = scanQuoted(s, i, '"', it.dialect == .mysql);
            },
            '`' => {
                tag = .quoted_identifier;
                i = scanQuoted(s, i, '`', it.dialect == .mysql);
            },
            '[' => {
                tag = .punctuation;
            },
            '$' => {
                if (i < s.len and std.ascii.isDigit(s[i])) {
                    tag = .parameter;
                    while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
                } else if (dollarTag(s, start)) |tag_end| {
                    // PostgreSQL dollar quoting: $tag$ ... $tag$
                    tag = .string;
                    const delim = s[start..tag_end];
                    i = if (std.mem.indexOfPos(u8, s, tag_end, delim)) |close| close + delim.len else s.len;
                } else {
                    tag = .operator;
                }
            },
            '?' => tag = .parameter,
            ':' => if (i < s.len and s[i] == ':') {
                tag = .operator;
                i += 1;
            } else if (i < s.len and isIdentStart(s[i])) {
                tag = .parameter;
                while (i < s.len and isIdentChar(s[i])) i += 1;
            } else {
                tag = .operator;
            },
            '0'...'9' => {
                tag = .number;
                while (i < s.len and (std.ascii.isAlphanumeric(s[i]) or s[i] == '.' or s[i] == '_')) i += 1;
            },
            '.' => if (i < s.len and std.ascii.isDigit(s[i])) {
                tag = .number;
                while (i < s.len and (std.ascii.isDigit(s[i]) or s[i] == 'e' or s[i] == 'E')) i += 1;
            } else {
                tag = .punctuation;
            },
            '(', ')', ',', ';', ']', '{', '}' => tag = .punctuation,
            '+', '*', '%', '=', '<', '>', '!', '|', '&', '^', '~', '@' => {
                tag = .operator;
                while (i < s.len and std.mem.indexOfScalar(u8, "=<>!|&~", s[i]) != null) i += 1;
            },
            else => {
                if (isIdentStart(c)) {
                    // E'...' / X'...' / B'...' / N'...' string prefixes
                    if (i < s.len and s[i] == '\'' and std.mem.indexOfScalar(u8, "eExXbBnN", c) != null) {
                        tag = .string;
                        i = scanQuoted(s, i + 1, '\'', it.dialect == .mysql or c == 'e' or c == 'E');
                    } else {
                        while (i < s.len and isIdentChar(s[i])) i += 1;
                        const word = s[start..i];
                        tag = if (isKeyword(word)) .keyword else if (isBuiltin(word)) .builtin else .identifier;
                    }
                } else {
                    // Unknown byte (e.g. stray UTF-8 continuation): treat the
                    // whole UTF-8 sequence as an identifier character run.
                    tag = .identifier;
                    while (i < s.len and isIdentChar(s[i])) i += 1;
                }
            },
        }
        it.pos = i;
        return .{ .tag = tag, .start = start, .end = i };
    }
};

fn scanQuoted(s: []const u8, from: usize, q: u8, backslash_escapes: bool) usize {
    var i = from;
    while (i < s.len) : (i += 1) {
        if (backslash_escapes and s[i] == '\\' and i + 1 < s.len) {
            i += 1;
            continue;
        }
        if (s[i] == q) {
            if (i + 1 < s.len and s[i + 1] == q) {
                i += 1; // doubled quote
                continue;
            }
            return i + 1;
        }
    }
    return s.len;
}

fn dollarTag(s: []const u8, start: usize) ?usize {
    var i = start + 1;
    while (i < s.len and (std.ascii.isAlphanumeric(s[i]) or s[i] == '_')) i += 1;
    if (i < s.len and s[i] == '$') return i + 1;
    return null;
}

pub fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c >= 0x80;
}

pub fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$' or c >= 0x80;
}

pub const keywords = [_][]const u8{
    "add",            "all",           "alter",       "analyze",      "and",      "any",       "as",        "asc",
    "begin",          "between",       "by",          "cascade",      "case",     "cast",      "check",     "column",
    "commit",         "constraint",    "create",      "cross",        "database", "default",   "delete",    "desc",
    "describe",       "distinct",      "drop",        "else",         "end",      "except",    "exists",    "explain",
    "false",          "fetch",         "first",       "for",          "foreign",  "from",      "full",      "function",
    "grant",          "group",         "having",      "if",           "ilike",    "in",        "index",     "inner",
    "insert",         "intersect",     "into",        "is",           "join",     "key",       "last",      "lateral",
    "left",           "like",          "limit",       "materialized", "natural",  "not",       "null",      "nulls",
    "offset",         "on",            "or",          "order",        "outer",    "over",      "partition", "primary",
    "procedure",      "recursive",     "references",  "rename",       "replace",  "returning", "revoke",    "right",
    "rollback",       "rows",          "schema",      "select",       "set",      "show",      "table",     "temporary",
    "then",           "to",            "transaction", "trigger",      "true",     "truncate",  "union",     "unique",
    "update",         "use",           "using",       "vacuum",       "values",   "view",      "when",      "where",
    "window",         "with",          "without",     "conflict",     "do",       "nothing",   "pragma",    "after",
    "before",         "each",          "row",         "instead",      "of",       "language",  "returns",   "declare",
    "auto_increment", "autoincrement", "engine",      "temp",         "unlogged", "only",      "similar",   "escape",
    "tablespace",     "sequence",      "type",        "enum",         "domain",   "extension", "owner",     "comment",
    "execute",        "call",          "immutable",   "stable",       "volatile", "security",  "definer",   "invoker",
};

pub const builtins = [_][]const u8{
    // functions
    "count",       "sum",        "avg",          "min",               "max",          "coalesce",  "nullif",     "now",
    "lower",       "upper",      "length",       "substr",            "substring",    "trim",      "round",      "abs",
    "concat",      "date",       "extract",      "json_agg",          "jsonb_agg",    "array_agg", "string_agg", "group_concat",
    "row_number",  "rank",       "dense_rank",   "lag",               "lead",         "ifnull",    "isnull",     "greatest",
    "least",       "date_trunc", "current_date", "current_timestamp", "current_user", "random",
    // types
       "int",        "integer",
    "bigint",      "smallint",   "tinyint",      "serial",            "bigserial",    "text",      "varchar",    "char",
    "boolean",     "bool",       "real",         "float",             "double",       "numeric",   "decimal",    "timestamp",
    "timestamptz", "time",       "interval",     "uuid",              "json",         "jsonb",     "blob",       "bytea",
    "datetime",    "precision",  "varying",      "character",         "mediumtext",   "longtext",
};

fn inList(comptime list: []const []const u8, word: []const u8) bool {
    if (word.len > 32) return false;
    var buf: [32]u8 = undefined;
    const lower = std.ascii.lowerString(&buf, word);
    const map = comptime blk: {
        var kvs: [list.len]struct { []const u8 } = undefined;
        for (list, 0..) |w, idx| kvs[idx] = .{w};
        break :blk std.StaticStringMap(void).initComptime(kvs);
    };
    return map.has(lower);
}

pub fn isKeyword(word: []const u8) bool {
    return inList(&keywords, word);
}

pub fn isBuiltin(word: []const u8) bool {
    return inList(&builtins, word);
}

/// True when the script contains a DELETE statement without a top-level
/// WHERE clause (WHERE inside subqueries, strings or comments does not count).
/// Such statements are refused so a table cannot be emptied by accident.
pub fn hasDeleteWithoutWhere(src: []const u8, dialect: Dialect) bool {
    var it: Iterator = .initDialect(src, dialect);
    var depth: usize = 0;
    var in_delete = false;
    var has_where = false;
    while (it.next()) |t| {
        switch (t.tag) {
            .punctuation => switch (src[t.start]) {
                '(' => depth += 1,
                ')' => depth -|= 1,
                ';' => if (depth == 0) {
                    if (in_delete and !has_where) return true;
                    in_delete = false;
                    has_where = false;
                },
                else => {},
            },
            .keyword => if (depth == 0) {
                const w = t.text(src);
                if (std.ascii.eqlIgnoreCase(w, "delete")) {
                    in_delete = true;
                    has_where = false;
                } else if (in_delete and std.ascii.eqlIgnoreCase(w, "where")) {
                    has_where = true;
                }
            },
            else => {},
        }
    }
    return in_delete and !has_where;
}

/// Confirm all UPDATE/DELETE statements: a WHERE clause does not bound their impact.
pub fn dangerousStatement(src: []const u8, dialect: Dialect) ?[]const u8 {
    var it: Iterator = .initDialect(src, dialect);
    while (it.next()) |t| switch (t.tag) {
        .keyword, .identifier => if (inList(&.{ "drop", "truncate", "update", "delete", "do", "call", "execute" }, t.text(src))) return t.text(src),
        .comment => if (dialect == .mysql and (std.mem.startsWith(u8, t.text(src), "/*!") or std.mem.startsWith(u8, t.text(src), "/*M!"))) return "executable comment",
        else => {},
    };
    return null;
}

test "dangerous actions include batches and CTEs but exclude quoted text" {
    for ([_][]const u8{ "DROP SCHEMA public CASCADE", "TRUNCATE t", "update t set x = 1", "delete from t where true", "select 1; drop table t", "with d as (delete from t where id = 1 returning *) select * from d", "DO $$ BEGIN EXECUTE 'DROP TABLE t'; END $$", "CALL cleanup()" }) |sql|
        try std.testing.expect(dangerousStatement(sql, .postgres) != null);
    try std.testing.expect(dangerousStatement("select 'drop table t', \"update\" -- delete\n", .postgres) == null);
}

test "delete without where" {
    try std.testing.expect(hasDeleteWithoutWhere("DELETE FROM users", .postgres));
    try std.testing.expect(hasDeleteWithoutWhere("delete from users;", .mysql));
    try std.testing.expect(hasDeleteWithoutWhere("select 1; delete from t", .sqlite));
    try std.testing.expect(hasDeleteWithoutWhere("delete from t where id in (select id from x); delete from y", .postgres));
    try std.testing.expect(hasDeleteWithoutWhere("delete from t -- where id = 1", .postgres));
    try std.testing.expect(hasDeleteWithoutWhere("delete from t using x", .postgres));
    try std.testing.expect(hasDeleteWithoutWhere("with a as (select 1) delete from t", .postgres));
    try std.testing.expect(hasDeleteWithoutWhere("delete from t returning (select 1 where true)", .postgres));
    try std.testing.expect(!hasDeleteWithoutWhere("DELETE FROM users WHERE id = 1", .postgres));
    try std.testing.expect(!hasDeleteWithoutWhere("delete from t where true", .sqlite));
    try std.testing.expect(!hasDeleteWithoutWhere("select 'delete from t'", .postgres));
    try std.testing.expect(!hasDeleteWithoutWhere("create trigger x after insert on t begin delete from y where 1; end", .sqlite));
}

/// Statements a read-only connection may start with.
const read_statements = [_][]const u8{ "select", "with", "show", "explain", "describe", "desc", "values", "table", "pragma", "exists" };
/// Words that write when nested: `WITH … DELETE`, `SELECT … INTO`, `EXPLAIN ANALYZE INSERT`,
/// `SELECT … FOR UPDATE`; `set_config` could turn PostgreSQL's read-only session off.
const write_words = [_][]const u8{ "insert", "update", "delete", "merge", "into", "create", "drop", "alter", "truncate", "grant", "revoke", "set_config" };

/// For read-only connections: the first word that may change the database,
/// or null when every statement only reads. The server enforces read-only
/// too; this check gives a clear message before anything is sent.
pub fn readOnlyViolation(src: []const u8, dialect: Dialect) ?[]const u8 {
    return restrictedViolation(src, dialect, false);
}

pub fn readDeleteViolation(src: []const u8, dialect: Dialect) ?[]const u8 {
    return restrictedViolation(src, dialect, true);
}

pub fn isReadPragma(name: []const u8) bool {
    return inList(&.{ "table_info", "table_xinfo", "index_info", "index_xinfo", "index_list", "foreign_key_list", "database_list", "compile_options" }, name);
}

fn restrictedViolation(src: []const u8, dialect: Dialect, allow_delete: bool) ?[]const u8 {
    var it: Iterator = .initDialect(src, dialect);
    var depth: usize = 0;
    var at_start = true;
    var in_pragma = false;
    var pragma_name = false;
    while (it.next()) |t| {
        switch (t.tag) {
            .whitespace => {},
            .comment => {
                const text = t.text(src);
                if (dialect == .mysql and (std.mem.startsWith(u8, text, "/*!") or std.mem.startsWith(u8, text, "/*M!"))) return "executable comment";
            },
            .punctuation => switch (src[t.start]) {
                '(' => depth += 1,
                ')' => depth -|= 1,
                ';' => if (depth == 0) {
                    at_start = true;
                    in_pragma = false;
                    pragma_name = false;
                },
                else => if (at_start) return t.text(src),
            },
            .keyword, .identifier, .builtin => {
                const w = t.text(src);
                if (at_start) {
                    at_start = false;
                    if (!inList(&read_statements, w) and !(allow_delete and std.ascii.eqlIgnoreCase(w, "delete"))) return w;
                    in_pragma = std.ascii.eqlIgnoreCase(w, "pragma");
                    pragma_name = in_pragma;
                } else if (pragma_name) {
                    pragma_name = false;
                    if (!isReadPragma(w)) return w;
                } else if (inList(&write_words, w) and !(allow_delete and std.ascii.eqlIgnoreCase(w, "delete"))) return w;
                if (allow_delete and depth > 0 and std.ascii.eqlIgnoreCase(w, "delete")) return w;
                if (inList(&.{ "load_extension", "set_config" }, w)) return w;
                if (std.ascii.eqlIgnoreCase(w, "replace")) {
                    // REPLACE writes rows; replace(...) is a string function.
                    var lookahead = it;
                    while (lookahead.next()) |next| {
                        if (next.tag == .whitespace or next.tag == .comment) continue;
                        if (next.tag != .punctuation or src[next.start] != '(') return w;
                        break;
                    } else return w;
                }
                if (allow_delete and std.ascii.eqlIgnoreCase(w, "settings")) return w;
            },
            .quoted_identifier => {
                const word = t.text(src);
                if (word.len >= 2 and inList(&.{ "set_config", "load_extension" }, word[1 .. word.len - 1])) return word;
                if (at_start or pragma_name) return word;
            },
            .operator => if (at_start or in_pragma) return t.text(src),
            else => if (at_start) return t.text(src),
        }
    }
    return null;
}

test "read-delete allows row deletes but refuses schema changes and other writes" {
    for ([_][]const u8{
        "select * from people",
        "delete from people where id = 1",
        "with ids as (select id from people) delete from people where id in (select id from ids)",
        "select 'drop table people'; delete from people where id = 2 returning *",
        "pragma table_info(people)",
        "select replace(name, 'old', 'new') from people",
    }) |sql| try std.testing.expect(readDeleteViolation(sql, .sqlite) == null);
    for ([_][]const u8{
        "create table other(id integer)",
        "create view other as select * from people",
        "create index idx on people(id)",
        "alter table people add column other text",
        "drop schema public cascade",
        "drop table people",
        "truncate people",
        "insert into people values (1)",
        "update people set id = 1",
        "with ids as (select 1) replace people values (1)",
        "delete from people where id = 1; drop table people",
        "with x as (delete from people returning *) select * from x",
        "explain analyze update people set id = 2",
        "pragma writable_schema = 1",
        "pragma foreign_keys(off)",
        "select load_extension('evil')",
        "select \"set_config\"('transaction_read_only', 'off', false)",
        "select 1; /*!50000 DROP TABLE people */",
        "select 1; /*M! DROP TABLE people */",
        "select 1 settings readonly = 0",
        "call change_schema()",
    }) |sql| try std.testing.expect(readDeleteViolation(sql, .mysql) != null);
}

test "read-only violation" {
    const ok = [_][]const u8{
        "select * from users",
        "SELECT 1; select 2;",
        "(select 1) union (select 2)",
        "with a as (select 1) select * from a",
        "-- note\nselect replace(name, 'a', 'b') from t",
        "select 'delete from t', \"update\" from t",
        "show tables",
        "explain select 1",
        "pragma table_info(t)",
        "  ",
    };
    for (ok) |sql| try std.testing.expectEqual(@as(?[]const u8, null), readOnlyViolation(sql, .postgres));
    const bad = [_]struct { []const u8, []const u8 }{
        .{ "delete from t where id = 1", "delete" },
        .{ "INSERT INTO t values (1)", "INSERT" },
        .{ "update t set a = 1", "update" },
        .{ "select 1; drop table t", "drop" },
        .{ "with d as (delete from t returning *) select * from d", "delete" },
        .{ "select * into t2 from t", "into" },
        .{ "explain analyze insert into t values (1)", "insert" },
        .{ "select * from t for update", "update" },
        .{ "select set_config('default_transaction_read_only', 'off', false)", "set_config" },
        .{ "set default_transaction_read_only = off", "set" },
        .{ "begin", "begin" },
        .{ "replace into t values (1)", "replace" },
        .{ "vacuum", "vacuum" },
        .{ "copy t to '/tmp/x'", "copy" },
        .{ "'x'", "'x'" },
    };
    for (bad) |c| try std.testing.expectEqualStrings(c[1], readOnlyViolation(c[0], .postgres).?);
}

/// Splits a script into statements at top-level semicolons (ignoring those in
/// strings, comments and dollar quotes). Empty statements are skipped.
pub fn splitStatements(src: []const u8, dialect: Dialect, out: *std.ArrayList([]const u8), gpa: std.mem.Allocator) !void {
    // In MySQL, \' is ambiguous because NO_BACKSLASH_ESCAPES is session state.
    // Let the server parse the complete script instead of guessing that state.
    if ((dialect == .mysql and std.mem.indexOf(u8, src, "\\'") != null) or containsCompoundDefinition(src, dialect)) {
        const stmt = std.mem.trim(u8, src, " \t\r\n;");
        if (stmt.len > 0) try out.append(gpa, stmt);
        return;
    }
    var it: Iterator = .initDialect(src, dialect);
    var start: usize = 0;
    while (it.next()) |t| {
        if (t.tag == .punctuation and src[t.start] == ';') {
            const stmt = std.mem.trim(u8, src[start..t.start], " \t\r\n");
            if (stmt.len > 0 and !isOnlyComments(stmt, dialect)) try out.append(gpa, stmt);
            start = t.end;
        }
    }
    const stmt = std.mem.trim(u8, src[start..], " \t\r\n");
    if (stmt.len > 0 and !isOnlyComments(stmt, dialect)) try out.append(gpa, stmt);
}

/// Compound trigger and routine bodies contain semicolons that only the
/// database parser can classify correctly. Keep such input as one query.
fn containsCompoundDefinition(src: []const u8, dialect: Dialect) bool {
    var it: Iterator = .initDialect(src, dialect);
    var saw_create = false;
    var saw_compound_kind = false;
    while (it.next()) |t| {
        if (t.tag == .whitespace or t.tag == .comment) continue;
        if (t.tag == .punctuation and src[t.start] == ';') return false;
        const word = t.text(src);
        if (!saw_create) {
            if (t.tag == .keyword and std.ascii.eqlIgnoreCase(word, "create")) saw_create = true;
            continue;
        }
        if (t.tag == .keyword) {
            for ([_][]const u8{ "trigger", "function", "procedure" }) |kind| {
                if (std.ascii.eqlIgnoreCase(word, kind)) saw_compound_kind = true;
            }
            if (saw_compound_kind and std.ascii.eqlIgnoreCase(word, "begin")) return true;
        }
    }
    return false;
}

fn isOnlyComments(s: []const u8, dialect: Dialect) bool {
    var it: Iterator = .initDialect(s, dialect);
    while (it.next()) |t| switch (t.tag) {
        .whitespace, .comment => {},
        else => return false,
    };
    return true;
}

const testing = std.testing;

test "tokens" {
    const src = "SELECT u.name, 'it''s' AS x -- hi\nFROM \"Users\" u WHERE id = $1 AND n > 3.5";
    var it: Iterator = .init(src);
    var tags: std.ArrayList(Tag) = .empty;
    defer tags.deinit(testing.allocator);
    while (it.next()) |t| if (t.tag != .whitespace) try tags.append(testing.allocator, t.tag);
    try testing.expectEqualSlices(Tag, &.{
        .keyword,  .identifier,        .punctuation, .identifier, .punctuation, .string,   .keyword,   .identifier, .comment,
        .keyword,  .quoted_identifier, .identifier,  .keyword,    .identifier,  .operator, .parameter, .keyword,    .identifier,
        .operator, .number,
    }, tags.items);
}

test "dollar quotes and split" {
    const src = "create function f() returns int as $body$ select 1; $body$ language sql; select 2; -- end";
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(testing.allocator);
    try splitStatements(src, .postgres, &parts, testing.allocator);
    try testing.expectEqual(@as(usize, 2), parts.items.len);
    try testing.expectEqualStrings("select 2", parts.items[1]);
}

test "compound trigger body is not split" {
    const src = "create trigger tr after insert on t begin insert into log values (new.id); update stats set n = n + 1; end;";
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(testing.allocator);
    try splitStatements(src, .sqlite, &parts, testing.allocator);
    try testing.expectEqual(@as(usize, 1), parts.items.len);
    try testing.expectEqualStrings(std.mem.trimEnd(u8, src, ";"), parts.items[0]);
}

test "statement splitting follows string rules of each dialect" {
    const src = "select 'a\\'; select 2;";

    for ([_]Dialect{ .postgres, .sqlite }) |dialect| {
        var parts: std.ArrayList([]const u8) = .empty;
        defer parts.deinit(testing.allocator);
        try splitStatements(src, dialect, &parts, testing.allocator);
        try testing.expectEqual(@as(usize, 2), parts.items.len);
        try testing.expectEqualStrings("select 2", parts.items[1]);
    }

    var mysql_parts: std.ArrayList([]const u8) = .empty;
    defer mysql_parts.deinit(testing.allocator);
    try splitStatements(src, .mysql, &mysql_parts, testing.allocator);
    try testing.expectEqual(@as(usize, 1), mysql_parts.items.len);
}
