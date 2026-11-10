//! Context-aware completion for slash commands and SQL.

const std = @import("std");
const Allocator = std.mem.Allocator;
const lexer = @import("../sql/lexer.zig");
const db = @import("../db/db.zig");
const toml = @import("../toml.zig");

pub const Kind = enum { command, table, column, operator, keyword, function, connection, query, config_key, config_value };

pub const Candidate = struct {
    text: []const u8,
    kind: Kind,
    detail: []const u8 = "",
};

pub const Command = struct {
    name: []const u8,
    args: []const u8 = "",
    help: []const u8,
    /// What the first argument completes to.
    arg: enum { none, table, connection, query } = .none,
    aliases: []const []const u8 = &.{},
};

/// Table and column names of the connected database.
pub const SchemaCache = struct {
    arena: std.heap.ArenaAllocator,
    tables: []const []const u8 = &.{},
    /// Parallel to `tables`.
    columns: []const []const []const u8 = &.{},
    /// Distinct column names across all tables.
    all_columns: []const []const u8 = &.{},

    /// Builds the cache from a (table, column) result; takes ownership of nothing.
    pub fn fromResult(gpa: Allocator, r: db.Result) Allocator.Error!SchemaCache {
        var c: SchemaCache = .{ .arena = .init(gpa) };
        errdefer c.arena.deinit();
        const a = c.arena.allocator();
        var tables: std.ArrayList([]const u8) = .empty;
        var columns: std.ArrayList([]const []const u8) = .empty;
        var current: std.ArrayList([]const u8) = .empty;
        var interned: std.StringHashMapUnmanaged([]const u8) = .empty;
        var all: std.ArrayList([]const u8) = .empty;
        for (r.rows) |row| {
            const t = row[0] orelse continue;
            if (tables.items.len == 0 or !std.mem.eql(u8, tables.items[tables.items.len - 1], t)) {
                if (tables.items.len > 0) try columns.append(a, current.items);
                current = .empty;
                try tables.append(a, try a.dupe(u8, t));
            }
            if (row.len > 1) if (row[1]) |col| {
                const gop = try interned.getOrPut(a, col);
                if (!gop.found_existing) {
                    const owned = try a.dupe(u8, col);
                    gop.key_ptr.* = owned;
                    gop.value_ptr.* = owned;
                    try all.append(a, owned);
                }
                try current.append(a, gop.value_ptr.*);
            };
        }
        if (tables.items.len > 0) try columns.append(a, current.items);
        c.tables = tables.items;
        c.columns = columns.items;
        c.all_columns = all.items;
        return c;
    }

    pub fn deinit(c: *SchemaCache) void {
        c.arena.deinit();
    }

    pub fn columnsOf(c: *const SchemaCache, table: []const u8) ?[]const []const u8 {
        for (c.tables, 0..) |t, i| {
            if (std.ascii.eqlIgnoreCase(t, table)) return c.columns[i];
            // allow unqualified lookups of schema-qualified names
            if (std.mem.lastIndexOfScalar(u8, t, '.')) |dot| {
                if (std.ascii.eqlIgnoreCase(t[dot + 1 ..], table)) return c.columns[i];
            }
        }
        return null;
    }
};

pub const Completion = struct {
    /// Number of bytes before the cursor that the chosen candidate replaces.
    replace_len: usize,
    replace_after: usize = 0,
    candidates: []const Candidate,
    /// False for long generic lists (e.g. all clause keywords after a space)
    /// that should only appear on Tab, not while typing.
    auto: bool = true,
    /// The typed word equals a known name/keyword; Enter can run it without
    /// first accepting the unchanged suggestion.
    exact_match: bool = false,
};

pub const Context = struct {
    text: []const u8,
    cursor: usize,
    cache: ?*const SchemaCache,
    connections: []const []const u8,
    /// Names of saved queries.
    queries: []const []const u8 = &.{},
    commands: []const Command,
    /// Connected SQL dialect. Enables context-sensitive operator completion.
    kind: ?db.Kind = null,
};

const postgres_operators = [_]Candidate{
    .{ .text = "IN", .kind = .operator, .detail = "membership" },
    .{ .text = "NOT IN", .kind = .operator, .detail = "not a member" },
    .{ .text = "ILIKE", .kind = .operator, .detail = "case-insensitive match" },
    .{ .text = "NOT ILIKE", .kind = .operator, .detail = "case-insensitive mismatch" },
    .{ .text = "LIKE", .kind = .operator, .detail = "pattern match" },
    .{ .text = "NOT LIKE", .kind = .operator, .detail = "pattern mismatch" },
    .{ .text = "IS NULL", .kind = .operator, .detail = "null check" },
    .{ .text = "IS NOT NULL", .kind = .operator, .detail = "null check" },
    .{ .text = "BETWEEN", .kind = .operator, .detail = "range" },
    .{ .text = "=", .kind = .operator, .detail = "equal" },
    .{ .text = "<>", .kind = .operator, .detail = "not equal" },
    .{ .text = "<", .kind = .operator, .detail = "less than" },
    .{ .text = "<=", .kind = .operator, .detail = "at most" },
    .{ .text = ">", .kind = .operator, .detail = "greater than" },
    .{ .text = ">=", .kind = .operator, .detail = "at least" },
    .{ .text = "~", .kind = .operator, .detail = "regular expression" },
    .{ .text = "~*", .kind = .operator, .detail = "case-insensitive regex" },
};

const mysql_operators = [_]Candidate{
    .{ .text = "IN", .kind = .operator, .detail = "membership" },
    .{ .text = "NOT IN", .kind = .operator, .detail = "not a member" },
    .{ .text = "LIKE", .kind = .operator, .detail = "pattern match" },
    .{ .text = "NOT LIKE", .kind = .operator, .detail = "pattern mismatch" },
    .{ .text = "IS NULL", .kind = .operator, .detail = "null check" },
    .{ .text = "IS NOT NULL", .kind = .operator, .detail = "null check" },
    .{ .text = "BETWEEN", .kind = .operator, .detail = "range" },
    .{ .text = "REGEXP", .kind = .operator, .detail = "regular expression" },
    .{ .text = "NOT REGEXP", .kind = .operator, .detail = "regex mismatch" },
    .{ .text = "=", .kind = .operator, .detail = "equal" },
    .{ .text = "!=", .kind = .operator, .detail = "not equal" },
    .{ .text = "<>", .kind = .operator, .detail = "not equal" },
    .{ .text = "<", .kind = .operator, .detail = "less than" },
    .{ .text = "<=", .kind = .operator, .detail = "at most" },
    .{ .text = ">", .kind = .operator, .detail = "greater than" },
    .{ .text = ">=", .kind = .operator, .detail = "at least" },
};

const sqlite_operators = [_]Candidate{
    .{ .text = "IN", .kind = .operator, .detail = "membership" },
    .{ .text = "NOT IN", .kind = .operator, .detail = "not a member" },
    .{ .text = "LIKE", .kind = .operator, .detail = "case-insensitive ASCII match" },
    .{ .text = "NOT LIKE", .kind = .operator, .detail = "pattern mismatch" },
    .{ .text = "GLOB", .kind = .operator, .detail = "case-sensitive pattern" },
    .{ .text = "NOT GLOB", .kind = .operator, .detail = "case-sensitive mismatch" },
    .{ .text = "IS NULL", .kind = .operator, .detail = "null check" },
    .{ .text = "IS NOT NULL", .kind = .operator, .detail = "null check" },
    .{ .text = "BETWEEN", .kind = .operator, .detail = "range" },
    .{ .text = "=", .kind = .operator, .detail = "equal" },
    .{ .text = "!=", .kind = .operator, .detail = "not equal" },
    .{ .text = "<>", .kind = .operator, .detail = "not equal" },
    .{ .text = "<", .kind = .operator, .detail = "less than" },
    .{ .text = "<=", .kind = .operator, .detail = "at most" },
    .{ .text = ">", .kind = .operator, .detail = "greater than" },
    .{ .text = ">=", .kind = .operator, .detail = "at least" },
};

const clickhouse_operators = [_]Candidate{
    .{ .text = "IN", .kind = .operator, .detail = "membership" },
    .{ .text = "NOT IN", .kind = .operator, .detail = "not a member" },
    .{ .text = "GLOBAL IN", .kind = .operator, .detail = "distributed membership" },
    .{ .text = "LIKE", .kind = .operator, .detail = "pattern match" },
    .{ .text = "NOT LIKE", .kind = .operator, .detail = "pattern mismatch" },
    .{ .text = "ILIKE", .kind = .operator, .detail = "case-insensitive match" },
    .{ .text = "NOT ILIKE", .kind = .operator, .detail = "case-insensitive mismatch" },
    .{ .text = "IS NULL", .kind = .operator, .detail = "null check" },
    .{ .text = "IS NOT NULL", .kind = .operator, .detail = "null check" },
    .{ .text = "BETWEEN", .kind = .operator, .detail = "range" },
    .{ .text = "=", .kind = .operator, .detail = "equal" },
    .{ .text = "!=", .kind = .operator, .detail = "not equal" },
    .{ .text = "<", .kind = .operator, .detail = "less than" },
    .{ .text = "<=", .kind = .operator, .detail = "at most" },
    .{ .text = ">", .kind = .operator, .detail = "greater than" },
    .{ .text = ">=", .kind = .operator, .detail = "at least" },
};

pub fn operators(kind: db.Kind) []const Candidate {
    return switch (kind) {
        .postgres => &postgres_operators,
        .mysql => &mysql_operators,
        .sqlite => &sqlite_operators,
        .clickhouse => &clickhouse_operators,
    };
}

pub const OperatorSnippet = struct {
    suffix: []const u8,
    /// ASCII bytes to move left after inserting the completed text.
    cursor_back: usize = 0,
};

/// Adds useful paired syntax and places the cursor at the first value slot.
pub fn operatorSnippet(operator: []const u8) OperatorSnippet {
    if (std.ascii.eqlIgnoreCase(operator, "IN") or std.ascii.eqlIgnoreCase(operator, "NOT IN")) {
        return .{ .suffix = " ()", .cursor_back = 1 };
    }
    if (std.ascii.eqlIgnoreCase(operator, "BETWEEN")) {
        return .{ .suffix = "  AND ", .cursor_back = 5 };
    }
    for ([_][]const u8{ "LIKE", "NOT LIKE", "ILIKE", "NOT ILIKE", "GLOB", "NOT GLOB", "REGEXP", "NOT REGEXP", "~", "~*" }) |pattern_operator| {
        if (std.ascii.eqlIgnoreCase(operator, pattern_operator)) return .{ .suffix = " ''", .cursor_back = 1 };
    }
    return .{ .suffix = " " };
}

const max_candidates = 200;

const config_fields = [_]Candidate{
    .{ .text = "url", .kind = .config_key, .detail = "connection URL" },
    .{ .text = "path", .kind = .config_key, .detail = "SQLite file path" },
    .{ .text = "driver", .kind = .config_key, .detail = "database driver (without url/path)" },
    .{ .text = "host", .kind = .config_key, .detail = "host or socket path" },
    .{ .text = "port", .kind = .config_key, .detail = "port number" },
    .{ .text = "user", .kind = .config_key, .detail = "database user" },
    .{ .text = "password", .kind = .config_key, .detail = "plain text password" },
    .{ .text = "password_env", .kind = .config_key, .detail = "password environment variable" },
    .{ .text = "database", .kind = .config_key, .detail = "database name" },
    .{ .text = "color", .kind = .config_key, .detail = "badge color: #RRGGBB" },
    .{ .text = "access", .kind = .config_key, .detail = "full / read_only / read_delete" },
    .{ .text = "sslmode", .kind = .config_key, .detail = "TLS mode" },
    .{ .text = "read_only", .kind = .config_key, .detail = "legacy boolean; prefer access" },
};

/// Completes ordinary TOML fields; inline tables and multiline values are left alone.
// shortcut: completion follows line-based fields, extend when inline-table editing needs it.
pub fn configComplete(a: Allocator, text: []const u8, cursor: usize, connections: []const []const u8) Allocator.Error!Completion {
    const empty: Completion = .{ .replace_len = 0, .candidates = &.{} };
    if (cursor > text.len) return empty;
    const start = if (std.mem.lastIndexOfScalar(u8, text[0..cursor], '\n')) |i| i + 1 else 0;
    const end = if (std.mem.indexOfScalar(u8, text[cursor..], '\n')) |i| cursor + i else text.len;
    var field_start = start;
    while (field_start < cursor and std.ascii.isWhitespace(text[field_start])) field_start += 1;
    if (field_start < end and text[field_start] == '#') return empty;
    const equal = if (std.mem.indexOfScalar(u8, text[start..end], '=')) |i| start + i else end;
    if (cursor > equal) {
        const key = std.mem.trim(u8, text[field_start..equal], " \t\"'");
        const has_values = for ([_][]const u8{ "access", "driver", "sslmode", "read_only", "default" }) |name| {
            if (std.mem.eql(u8, name, key)) break true;
        } else false;
        if (!has_values) return empty;
    }
    // An incomplete multiline value must not suggest setting names inside its text.
    const document = toml.parseDocument(a, text[0..start], null) catch |err| switch (err) {
        error.SyntaxError => return empty,
        error.OutOfMemory => return error.OutOfMemory,
    };
    var fields: []const Candidate = &.{
        .{ .text = "default", .kind = .config_key, .detail = "default connection name" },
        .{ .text = "[connections.local]", .kind = .config_key, .detail = "new connection section" },
    };
    if (document.current != document.root) {
        fields = &.{};
        if (document.root.get("connections")) |v| {
            if (v == .table) for (v.table.values()) |entry| {
                if (entry == .table and entry.table == document.current) {
                    fields = &config_fields;
                    break;
                }
            };
        }
    }
    var candidates: std.ArrayList(Candidate) = .empty;
    if (cursor <= equal) {
        const prefix = std.mem.trim(u8, text[field_start..cursor], " \t\"'");
        const key_end = @max(cursor, start + std.mem.trimEnd(u8, text[start..equal], " \t").len);
        for (fields) |field| {
            if (!std.mem.startsWith(u8, field.text, prefix)) continue;
            try candidates.append(a, .{
                .text = if (equal == end and field.text[0] != '[') try std.mem.concat(a, u8, &.{ field.text, " = " }) else field.text,
                .kind = .config_key,
                .detail = field.detail,
            });
        }
        return .{ .replace_len = cursor - field_start, .replace_after = key_end - cursor, .candidates = candidates.items, .auto = prefix.len > 0 };
    }
    const key = std.mem.trim(u8, text[field_start..equal], " \t\"'");
    const supported = for (fields) |field| {
        if (std.mem.eql(u8, field.text, key)) break true;
    } else false;
    if (!supported) return empty;
    const boolean = std.mem.eql(u8, key, "read_only");
    const values: []const []const u8 = if (std.mem.eql(u8, key, "access"))
        &.{ "full", "read_only", "read_delete" }
    else if (std.mem.eql(u8, key, "driver"))
        &.{ "postgres", "mysql", "mariadb", "sqlite", "clickhouse" }
    else if (std.mem.eql(u8, key, "sslmode"))
        &.{ "disable", "prefer", "require", "verify-ca", "verify-full" }
    else if (boolean)
        &.{ "true", "false" }
    else if (std.mem.eql(u8, key, "default") and fields.len == 2)
        connections
    else
        return empty;
    var value_start = equal + 1;
    while (value_start < end and std.ascii.isWhitespace(text[value_start])) value_start += 1;
    if (cursor < value_start) return empty;
    const quote: ?u8 = if (value_start < end and (text[value_start] == '"' or text[value_start] == '\'')) text[value_start] else null;
    var value_end = value_start;
    if (quote) |q| {
        value_end += 1;
        while (value_end < end) : (value_end += 1) {
            if (text[value_end] == '\\' and q == '"' and value_end + 1 < end) {
                value_end += 1;
            } else if (text[value_end] == q) {
                value_end += 1;
                break;
            }
        }
    } else {
        while (value_end < end and !std.ascii.isWhitespace(text[value_end]) and text[value_end] != '#') value_end += 1;
    }
    if (cursor > value_end) return empty;
    const prefix = std.mem.trim(u8, text[value_start..cursor], "\"'");
    var exact = false;
    for (values) |value| {
        if (!std.mem.startsWith(u8, value, prefix)) continue;
        const insertion = if (boolean) value else if (quote == '\'' and std.mem.indexOfScalar(u8, value, '\'') == null)
            try std.fmt.allocPrint(a, "'{s}'", .{value})
        else
            try std.json.Stringify.valueAlloc(a, value, .{});
        if (cursor == value_end and std.mem.eql(u8, text[value_start..cursor], insertion)) exact = true;
        const detail: []const u8 = if (std.mem.eql(u8, key, "access")) blk: {
            if (std.mem.eql(u8, value, "read_only")) break :blk "reading only";
            if (std.mem.eql(u8, value, "read_delete")) break :blk "reading + DELETE with WHERE";
            break :blk "all operations (default)";
        } else "";
        try candidates.append(a, .{ .text = insertion, .kind = .config_value, .detail = detail });
    }
    return .{ .replace_len = cursor - value_start, .replace_after = value_end - cursor, .candidates = candidates.items, .exact_match = exact };
}

test "free-form config values need no allocations" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    for ([_][]const u8{
        "[connections.local]\nurl = 'postgres://localhost/app'",
        "[connections.local]\npassword = 'secret'",
        "[connections.local]\ncolor = '#ffffff'",
    }) |input| try std.testing.expectEqual(@as(usize, 0), (try configComplete(failing.allocator(), input, input.len, &.{})).candidates.len);
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
}

test "config completion releases parser allocations on failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(a: Allocator) !void {
            var arena: std.heap.ArenaAllocator = .init(a);
            defer arena.deinit();
            const input = "[connections.local]\nurl = 'postgres://localhost/app'\naccess = re";
            _ = try configComplete(arena.allocator(), input, input.len, &.{});
        }
    }.run, .{});
}

test "config completion replaces fields and values without duplicating quotes or suffixes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_][3][]const u8{
        .{ "[connections.local]\nacc|", "access = ", "[connections.local]\naccess = " },
        .{ "[connections.local]\ndriver = p|", "\"postgres\"", "[connections.local]\ndriver = \"postgres\"" },
        .{ "[connections.local]\naccess = \"read_o|nly\" # keep", "\"read_only\"", "[connections.local]\naccess = \"read_only\" # keep" },
        .{ "[connections.local]\nsslmode = 'verify-f|ull'", "'verify-full'", "[connections.local]\nsslmode = 'verify-full'" },
        .{ "[connections.local]\nread_only = t|rue # keep", "true", "[connections.local]\nread_only = true # keep" },
        .{ "default = lo|", "\"local\"", "default = \"local\"" },
        .{ "note = '''\n[connections.fake]\n'''\ndef|", "default = ", "note = '''\n[connections.fake]\n'''\ndefault = " },
        .{ "['connections'.'local']\n'co|lor' = '#FF0000'", "color", "['connections'.'local']\ncolor = '#FF0000'" },
    };
    for (cases) |case| {
        const cursor = std.mem.indexOfScalar(u8, case[0], '|').?;
        const text = try std.mem.concat(a, u8, &.{ case[0][0..cursor], case[0][cursor + 1 ..] });
        const result = try configComplete(a, text, cursor, &.{"local"});
        var found = false;
        for (result.candidates) |candidate| {
            if (!std.mem.eql(u8, candidate.text, case[1])) continue;
            found = true;
            const edited = try std.mem.concat(a, u8, &.{ text[0 .. cursor - result.replace_len], candidate.text, text[cursor + result.replace_after ..] });
            try std.testing.expectEqualStrings(case[2], edited);
        }
        try std.testing.expect(found);
    }
    for ([_][]const u8{
        "[connections.local]\ncolor = \"#FF",
        "[connections.local]\nurl = \"postgres://",
        "[connections.local]\npassword = \"secret",
        "[connections.local]\n# access",
        "[connections.local]\nurl = \"\"\"\naccess = ",
        "[other]\naccess = ",
        "access = ",
    }) |text| try std.testing.expectEqual(@as(usize, 0), (try configComplete(a, text, text.len, &.{})).candidates.len);
    const finished = "[connections.local]\naccess = \"read_only\"";
    try std.testing.expect((try configComplete(a, finished, finished.len, &.{})).exact_match);
}

pub fn complete(a: Allocator, ctx: Context) Allocator.Error!Completion {
    const before = ctx.text[0..ctx.cursor];
    var list: List = .{ .a = a };

    // Slash commands
    if (std.mem.startsWith(u8, std.mem.trimStart(u8, before, " "), "/")) {
        const trimmed = std.mem.trimStart(u8, before, " ");
        if (std.mem.indexOfAny(u8, trimmed, " \t") == null) {
            for (ctx.commands) |cmd| {
                try list.addIfMatch(cmd.name, trimmed, .command, cmd.help);
            }
            return .{ .replace_len = trimmed.len, .candidates = list.items.items, .exact_match = list.exact };
        }
        const name_end = std.mem.indexOfAny(u8, trimmed, " \t").?;
        const name = trimmed[0..name_end];
        const cmd = findCommand(ctx.commands, name) orelse return .{ .replace_len = 0, .candidates = &.{} };
        const word = argWord(before);
        switch (cmd.arg) {
            .none => {},
            .connection => for (ctx.connections) |c| try list.addIfMatch(c, word, .connection, ""),
            .query => for (ctx.queries) |q| try list.addIfMatch(q, word, .query, ""),
            .table => if (ctx.cache) |cache| {
                for (cache.tables) |t| try list.addIfMatch(t, word, .table, "");
            },
        }
        return .{ .replace_len = word.len, .candidates = list.items.items, .exact_match = list.exact };
    }

    const word = sqlWord(before);
    const stmt = currentStatement(ctx.text, ctx.cursor);
    const cache = ctx.cache;

    if (ctx.kind) |kind| {
        const relative_cursor = ctx.cursor - stmt.start;
        if (operatorPrefix(stmt.text, relative_cursor, false)) |prefix| {
            const upper = prefix.len == 0 or std.ascii.isUpper(prefix[0]);
            for (operators(kind)) |op| {
                try list.addIfMatchCase(op.text, prefix, .operator, op.detail, upper);
            }
            // Typing e.g. "a" after a column may also mean AND/AS: fall through.
            if (list.items.items.len > 0) return .{ .replace_len = prefix.len, .candidates = list.items.items, .exact_match = list.exact };
        }
    }

    // qualifier.partial -> columns of the qualifier's table
    if (std.mem.lastIndexOfScalar(u8, word, '.')) |dot| {
        const qualifier = unquote(word[0..dot]);
        const partial = word[dot + 1 ..];
        if (cache) |c| {
            const table = resolveAlias(a, stmt.text, qualifier) catch qualifier;
            if (c.columnsOf(table)) |cols| {
                for (cols) |col| try list.addIfMatch(col, partial, .column, table);
            }
            // schema.table
            for (c.tables) |t| {
                if (t.len > dot and std.ascii.startsWithIgnoreCase(t, word[0 .. dot + 1])) {
                    try list.addIfMatch(t[dot + 1 ..], partial, .table, "");
                }
            }
        }
        return .{ .replace_len = partial.len, .candidates = list.items.items, .exact_match = list.exact };
    }

    const before_word = stmt.text[0 .. ctx.cursor - stmt.start - word.len];
    const prev_token = lastSignificant(before_word);
    const prev = previousKeyword(stmt.text[0 .. ctx.cursor - stmt.start]);
    const wants_table = if (prev) |p| isTableKeyword(p) else false;
    const upper = word.len > 0 and std.ascii.isUpper(word[0]);
    const kind = ctx.kind orelse .postgres;

    // 1. Start of a statement: only statements valid for this dialect.
    if (prev_token == null) {
        for (statementKeywords(kind)) |k| try list.addIfMatchCase(k, word, .keyword, "", upper);
        return .{ .replace_len = word.len, .candidates = list.items.items, .exact_match = list.exact, .auto = word.len > 0 };
    }
    const prev_text = prev_token.?.text(before_word);

    // 2. Keywords that must follow the previous one (DELETE -> FROM, ORDER -> BY).
    if (prev_token.?.tag == .keyword) {
        for (followUps(prev_text)) |k| try list.addIfMatchCase(k, word, .keyword, "", upper or prev_text.len > 0 and std.ascii.isUpper(prev_text[0]));
        if (list.items.items.len > 0 and word.len == 0) return .{ .replace_len = 0, .candidates = list.items.items, .exact_match = list.exact };
    }

    // 3. Table names after FROM / JOIN / INTO / UPDATE.
    if (wants_table) {
        if (cache) |c| for (c.tables) |t| try list.addIfMatch(t, word, .table, "");
        return .{ .replace_len = word.len, .candidates = list.items.items, .exact_match = list.exact };
    }

    const after_expression = switch (prev_token.?.tag) {
        .identifier, .quoted_identifier, .number, .string, .parameter, .builtin => true,
        .punctuation => prev_text[0] == ')',
        .operator => std.mem.eql(u8, prev_text, "*"),
        else => false,
    };
    const prefer_upper = upper or word.len == 0;

    if (after_expression) {
        // 4. "SELECT * F" -> FROM, "WHERE a = 1 A" -> AND: clause keywords first.
        for (clauseKeywords(kind)) |k| try list.addIfMatchCase(k, word, .keyword, "", prefer_upper);
        if (word.len == 0) return .{ .replace_len = 0, .candidates = list.items.items, .exact_match = list.exact, .auto = false };
    }

    // 5. An expression is expected (after SELECT, WHERE, AND, SET, a comma…):
    // columns of the tables in this statement come first.
    if (cache) |c| {
        var referenced: std.ArrayList([]const u8) = .empty;
        try referencedTables(a, stmt.text, &referenced);
        for (referenced.items) |t| {
            if (c.columnsOf(t)) |cols| for (cols) |col| try list.addIfMatch(col, word, .column, t);
        }
        if (word.len > 0) {
            for (c.all_columns) |col| try list.addIfMatch(col, word, .column, "");
            for (c.tables) |t| try list.addIfMatch(t, word, .table, "");
        }
    }
    if (word.len > 0) {
        for (expressionKeywords) |k| try list.addIfMatchCase(k, word, .keyword, "", upper);
        for (lexer.builtins) |k| try list.addIfMatchCase(k, word, .function, "", upper);
        if (!after_expression) for (clauseKeywords(kind)) |k| try list.addIfMatchCase(k, word, .keyword, "", upper);
        for (lexer.keywords) |k| {
            if (keywordAllowed(kind, k)) try list.addIfMatchCase(k, word, .keyword, "", upper);
        }
    }
    return .{ .replace_len = word.len, .candidates = list.items.items, .exact_match = list.exact };
}

fn lastSignificant(s: []const u8) ?lexer.Token {
    var it: lexer.Iterator = .init(s);
    var last: ?lexer.Token = null;
    while (it.next()) |t| switch (t.tag) {
        .whitespace, .comment => {},
        else => last = t,
    };
    return last;
}

// ───────────── dialect keyword lists (most common first) ─────────────

const statements_common = [_][]const u8{
    "SELECT",      "WITH",         "INSERT INTO", "UPDATE",     "DELETE FROM", "CREATE TABLE",
    "CREATE VIEW", "CREATE INDEX", "ALTER TABLE", "DROP TABLE", "DROP VIEW",   "EXPLAIN",
    "BEGIN",       "COMMIT",       "ROLLBACK",
};
const statements_postgres = statements_common ++ [_][]const u8{
    "TRUNCATE",                  "EXPLAIN ANALYZE", "CREATE FUNCTION", "CREATE TYPE", "CREATE MATERIALIZED VIEW",
    "REFRESH MATERIALIZED VIEW", "VACUUM",          "ANALYZE",         "SET",         "SHOW",
    "COPY",
};
const statements_mysql = statements_common ++ [_][]const u8{
    "TRUNCATE",     "SHOW TABLES", "SHOW DATABASES", "SHOW CREATE TABLE", "SHOW PROCESSLIST", "DESCRIBE",
    "REPLACE INTO", "USE",         "CALL",           "CREATE PROCEDURE",  "SET",
};
const statements_sqlite = statements_common ++ [_][]const u8{
    "PRAGMA", "REPLACE INTO", "CREATE TRIGGER", "VACUUM", "ANALYZE", "ATTACH DATABASE",
};

const statements_clickhouse = [_][]const u8{
    "SELECT",          "WITH",       "INSERT INTO",    "ALTER TABLE", "CREATE TABLE", "CREATE VIEW",    "CREATE MATERIALIZED VIEW",
    "CREATE DATABASE", "DROP TABLE", "TRUNCATE TABLE", "DELETE FROM", "SHOW TABLES",  "SHOW DATABASES", "SHOW CREATE TABLE",
    "DESCRIBE TABLE",  "EXPLAIN",    "OPTIMIZE TABLE", "EXISTS",      "SYSTEM",       "KILL QUERY",
};

fn statementKeywords(kind: db.Kind) []const []const u8 {
    return switch (kind) {
        .postgres => &statements_postgres,
        .mysql => &statements_mysql,
        .sqlite => &statements_sqlite,
        .clickhouse => &statements_clickhouse,
    };
}

const clauses_common = [_][]const u8{
    "FROM",      "WHERE",      "AND",        "OR",         "AS",          "ON",       "JOIN",
    "LEFT JOIN", "INNER JOIN", "RIGHT JOIN", "CROSS JOIN", "ORDER BY",    "GROUP BY", "HAVING",
    "LIMIT",     "OFFSET",     "UNION",      "UNION ALL",  "ASC",         "DESC",     "SET",
    "VALUES",    "IN",         "NOT",        "IS NULL",    "IS NOT NULL", "LIKE",     "BETWEEN",
    "USING",
};
const clauses_postgres = clauses_common ++ [_][]const u8{
    "ILIKE", "RETURNING", "FULL JOIN", "NULLS FIRST", "NULLS LAST", "ON CONFLICT", "FILTER", "OVER",
};
const clauses_mysql = clauses_common ++ [_][]const u8{
    "REGEXP", "ON DUPLICATE KEY UPDATE", "FOR UPDATE", "STRAIGHT_JOIN",
};
const clauses_sqlite = clauses_common ++ [_][]const u8{ "GLOB", "RETURNING", "ON CONFLICT" };

const clauses_clickhouse = clauses_common ++ [_][]const u8{
    "PREWHERE", "FINAL",     "SAMPLE",   "ARRAY JOIN", "LEFT ARRAY JOIN", "LIMIT BY", "ILIKE", "GLOBAL IN",
    "ANY JOIN", "ASOF JOIN", "SETTINGS", "FORMAT",     "WITH TOTALS",
};

fn clauseKeywords(kind: db.Kind) []const []const u8 {
    return switch (kind) {
        .postgres => &clauses_postgres,
        .mysql => &clauses_mysql,
        .sqlite => &clauses_sqlite,
        .clickhouse => &clauses_clickhouse,
    };
}

const expressionKeywords = [_][]const u8{
    "DISTINCT", "CASE", "WHEN", "THEN", "ELSE", "END", "NOT", "NULL", "EXISTS", "TRUE", "FALSE", "CAST",
};

/// Keywords that can only follow `prev`.
fn followUps(prev: []const u8) []const []const u8 {
    const map = std.StaticStringMap([]const []const u8).initComptime(.{
        .{ "delete", &[_][]const u8{"FROM"} },
        .{ "insert", &[_][]const u8{"INTO"} },
        .{ "replace", &[_][]const u8{"INTO"} },
        .{ "order", &[_][]const u8{"BY"} },
        .{ "group", &[_][]const u8{"BY"} },
        .{ "left", &[_][]const u8{ "JOIN", "OUTER JOIN" } },
        .{ "right", &[_][]const u8{ "JOIN", "OUTER JOIN" } },
        .{ "inner", &[_][]const u8{"JOIN"} },
        .{ "cross", &[_][]const u8{"JOIN"} },
        .{ "full", &[_][]const u8{ "JOIN", "OUTER JOIN" } },
        .{ "is", &[_][]const u8{ "NULL", "NOT NULL" } },
        .{ "union", &[_][]const u8{ "ALL", "SELECT" } },
        .{ "create", &[_][]const u8{ "TABLE", "VIEW", "INDEX", "UNIQUE INDEX" } },
        .{ "drop", &[_][]const u8{ "TABLE", "VIEW", "INDEX" } },
        .{ "alter", &[_][]const u8{"TABLE"} },
        .{ "show", &[_][]const u8{ "TABLES", "DATABASES", "CREATE TABLE", "COLUMNS FROM", "INDEX FROM", "PROCESSLIST", "VARIABLES" } },
    });
    var buf: [16]u8 = undefined;
    if (prev.len > buf.len) return &.{};
    return map.get(std.ascii.lowerString(&buf, prev)) orelse &.{};
}

/// Hides keywords that do not exist in a dialect.
fn keywordAllowed(kind: db.Kind, k: []const u8) bool {
    const Owner = enum { postgres, mysql, sqlite, not_sqlite };
    const only = std.StaticStringMap(Owner).initComptime(.{
        .{ "ilike", .postgres }, .{ "lateral", .postgres },     .{ "materialized", .postgres },
        .{ "pragma", .sqlite },  .{ "autoincrement", .sqlite }, .{ "auto_increment", .mysql },
        .{ "engine", .mysql },   .{ "show", .not_sqlite },      .{ "truncate", .not_sqlite },
    });
    const owner = only.get(k) orelse return true;
    return switch (owner) {
        .postgres => kind == .postgres,
        .mysql => kind == .mysql,
        .sqlite => kind == .sqlite,
        .not_sqlite => kind != .sqlite,
    };
}

const List = struct {
    a: Allocator,
    items: std.ArrayList(Candidate) = .empty,
    exact: bool = false,

    fn addIfMatch(l: *List, text: []const u8, prefix: []const u8, kind: Kind, detail: []const u8) Allocator.Error!void {
        const needle = unquote(prefix);
        if (std.ascii.findIgnoreCase(text, needle) == null) return;
        const exact = std.ascii.eqlIgnoreCase(text, needle);
        const is_prefix = std.ascii.startsWithIgnoreCase(text, needle);
        l.exact = l.exact or exact;
        if (l.items.items.len >= max_candidates) {
            const replaces_substring = is_prefix and !std.ascii.startsWithIgnoreCase(l.items.items[l.items.items.len - 1].text, needle);
            if (!exact and !replaces_substring) return;
        }
        for (l.items.items) |c| if (std.mem.eql(u8, c.text, text)) return;
        if (l.items.items.len >= max_candidates) _ = l.items.pop();
        var index = if (exact) @as(usize, 0) else l.items.items.len;
        if (!exact and is_prefix) {
            for (l.items.items, 0..) |c, i| {
                if (!std.ascii.startsWithIgnoreCase(c.text, needle)) {
                    index = i;
                    break;
                }
            }
        }
        try l.items.insert(l.a, index, .{ .text = text, .kind = kind, .detail = detail });
    }

    fn addIfMatchCase(l: *List, text: []const u8, prefix: []const u8, kind: Kind, detail: []const u8, upper: bool) Allocator.Error!void {
        if (std.ascii.findIgnoreCase(text, unquote(prefix)) == null) return;
        const cased = try caseLike(l.a, text, upper);
        try l.addIfMatch(cased, prefix, kind, detail);
    }
};

/// Matches the case the user is typing in: "se" -> "select", "SE" -> "SELECT".
fn caseLike(a: Allocator, word: []const u8, upper: bool) Allocator.Error![]const u8 {
    return if (upper) std.ascii.allocUpperString(a, word) else std.ascii.allocLowerString(a, word);
}

fn findCommand(commands: []const Command, name: []const u8) ?Command {
    for (commands) |c| {
        if (std.mem.eql(u8, c.name, name)) return c;
        for (c.aliases) |al| if (std.mem.eql(u8, al, name)) return c;
    }
    return null;
}

fn argWord(before: []const u8) []const u8 {
    var i = before.len;
    while (i > 0 and !std.ascii.isWhitespace(before[i - 1])) i -= 1;
    return before[i..];
}

fn sqlWord(before: []const u8) []const u8 {
    var i = before.len;
    while (i > 0 and (lexer.isIdentChar(before[i - 1]) or before[i - 1] == '.' or before[i - 1] == '"' or before[i - 1] == '`')) i -= 1;
    return before[i..];
}

/// Returns the partial operator at the cursor when it follows a column in a
/// condition. Browse filters set `condition_only`; console SQL must contain a
/// WHERE, HAVING or JOIN ON clause.
pub fn operatorPrefix(text: []const u8, cursor: usize, condition_only: bool) ?[]const u8 {
    const before = text[0..cursor];
    const word = sqlWord(before);
    const base = before[0 .. before.len - word.len];
    var it: lexer.Iterator = .init(base);
    var last: ?lexer.Token = null;
    var in_condition = condition_only;
    while (it.next()) |t| {
        if (t.tag == .whitespace or t.tag == .comment) continue;
        last = t;
        if (t.tag != .keyword) continue;
        const keyword = t.text(base);
        if (std.ascii.eqlIgnoreCase(keyword, "where") or std.ascii.eqlIgnoreCase(keyword, "having") or std.ascii.eqlIgnoreCase(keyword, "on")) {
            in_condition = true;
        } else if (std.ascii.eqlIgnoreCase(keyword, "group") or std.ascii.eqlIgnoreCase(keyword, "order") or
            std.ascii.eqlIgnoreCase(keyword, "limit") or std.ascii.eqlIgnoreCase(keyword, "returning") or
            std.ascii.eqlIgnoreCase(keyword, "union"))
        {
            in_condition = false;
        }
    }
    if (!in_condition) return null;
    const previous = last orelse return null;
    return switch (previous.tag) {
        .identifier, .quoted_identifier, .builtin => word,
        else => null,
    };
}

fn unquote(s: []const u8) []const u8 {
    var r = s;
    if (r.len > 0 and (r[0] == '"' or r[0] == '`')) r = r[1..];
    if (r.len > 0 and (r[r.len - 1] == '"' or r[r.len - 1] == '`')) r = r[0 .. r.len - 1];
    return r;
}

const Statement = struct { text: []const u8, start: usize };

fn currentStatement(text: []const u8, cursor: usize) Statement {
    var it: lexer.Iterator = .init(text);
    var start: usize = 0;
    var end: usize = text.len;
    while (it.next()) |t| {
        if (t.tag == .punctuation and text[t.start] == ';') {
            if (t.start < cursor) start = t.end else {
                end = t.start;
                break;
            }
        }
    }
    return .{ .text = text[start..end], .start = start };
}

fn previousKeyword(s: []const u8) ?[]const u8 {
    var it: lexer.Iterator = .init(s);
    var last: ?[]const u8 = null;
    var last_end: usize = 0;
    var prev_sig: ?lexer.Token = null;
    while (it.next()) |t| {
        if (t.tag == .whitespace or t.tag == .comment) continue;
        if (t.end == s.len and t.tag != .punctuation) break; // the word being typed
        prev_sig = t;
        last_end = t.end;
        if (t.tag == .keyword) last = t.text(s);
    }
    const p = prev_sig orelse return null;
    // "from a, b" -> after a comma inside a FROM list still wants tables
    if (p.tag == .keyword) return p.text(s);
    if (p.tag == .punctuation and s[p.start] == ',') return last;
    return null;
}

fn isTableKeyword(k: []const u8) bool {
    for ([_][]const u8{ "from", "join", "into", "update", "table", "describe", "truncate" }) |w| {
        if (std.ascii.eqlIgnoreCase(k, w)) return true;
    }
    return false;
}

/// Collects table names following FROM/JOIN/UPDATE/INTO.
fn referencedTables(a: Allocator, stmt: []const u8, out: *std.ArrayList([]const u8)) Allocator.Error!void {
    var it: lexer.Iterator = .init(stmt);
    var expect_table = false;
    while (it.next()) |t| {
        switch (t.tag) {
            .whitespace, .comment => continue,
            .keyword => expect_table = isTableKeyword(t.text(stmt)),
            .identifier, .quoted_identifier => {
                if (expect_table) {
                    var name = unquote(t.text(stmt));
                    // schema-qualified: identifier . identifier
                    const save = it.pos;
                    if (it.next()) |dot| {
                        if (dot.tag == .punctuation and stmt[dot.start] == '.') {
                            if (it.next()) |n| name = unquote(n.text(stmt));
                        } else it.pos = save;
                    }
                    try out.append(a, name);
                    expect_table = false;
                }
            },
            .punctuation => {
                // FROM a, b
                if (stmt[t.start] != ',') expect_table = false else if (out.items.len > 0) expect_table = true;
            },
            else => expect_table = false,
        }
    }
}

/// Resolves `alias` (FROM users u / JOIN orders AS o) to its table name.
fn resolveAlias(a: Allocator, stmt: []const u8, alias: []const u8) ![]const u8 {
    _ = a;
    var it: lexer.Iterator = .init(stmt);
    var toks: [3]?lexer.Token = .{ null, null, null };
    while (it.next()) |t| {
        if (t.tag == .whitespace or t.tag == .comment) continue;
        // pattern: <table> [as] <alias>
        const is_alias = (t.tag == .identifier or t.tag == .quoted_identifier) and
            std.ascii.eqlIgnoreCase(unquote(t.text(stmt)), alias);
        if (is_alias) {
            const p1 = toks[2];
            const p2 = toks[1];
            if (p1) |x| {
                if (x.tag == .keyword and std.ascii.eqlIgnoreCase(x.text(stmt), "as")) {
                    if (p2) |y| if (y.tag == .identifier or y.tag == .quoted_identifier) return unquote(y.text(stmt));
                } else if (x.tag == .identifier or x.tag == .quoted_identifier) {
                    return unquote(x.text(stmt));
                }
            }
        }
        toks[0] = toks[1];
        toks[1] = toks[2];
        toks[2] = t;
    }
    return error.NotFound;
}

const testing = std.testing;

fn testCache(a: Allocator) !SchemaCache {
    var arena: std.heap.ArenaAllocator = .init(a);
    const ra = arena.allocator();
    const rows = try ra.dupe([]const ?[]const u8, &.{
        &.{ "orders", "id" },
        &.{ "orders", "user_id" },
        &.{ "users", "id" },
        &.{ "users", "name" },
    });
    const r: db.Result = .{ .arena = arena, .columns = &.{ "t", "c" }, .rows = rows };
    defer arena.deinit();
    return SchemaCache.fromResult(a, r);
}

test "schema cache interns repeated column names" {
    var cache = try testCache(testing.allocator);
    defer cache.deinit();
    const orders = cache.columnsOf("orders").?;
    const users = cache.columnsOf("users").?;
    try testing.expect(orders[0].ptr == users[0].ptr);
    try testing.expectEqual(@as(usize, 3), cache.all_columns.len);
}

test "completion filters candidates before allocating case conversions" {
    var counting: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = std.math.maxInt(usize) });
    const text = "select name zzz";
    const result = try complete(counting.allocator(), .{ .text = text, .cursor = text.len, .cache = null, .connections = &.{}, .commands = &.{} });
    try testing.expectEqual(@as(usize, 0), result.candidates.len);
    try testing.expectEqual(@as(usize, 0), counting.allocations);
}

test "table after FROM" {
    var cache = try testCache(testing.allocator);
    defer cache.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const text = "select * from us";
    const c = try complete(arena.allocator(), .{ .text = text, .cursor = text.len, .cache = &cache, .connections = &.{}, .commands = &.{} });
    try testing.expectEqual(@as(usize, 2), c.replace_len);
    try testing.expectEqual(@as(usize, 1), c.candidates.len);
    try testing.expectEqualStrings("users", c.candidates[0].text);
}

test "completion ranks exact names then prefixes then substrings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    for ([_]Kind{ .table, .column, .command, .connection, .query }) |kind| {
        var list: List = .{ .a = arena.allocator() };
        try list.addIfMatch("some_ne", "ne", kind, "");
        try list.addIfMatch("networks", "ne", kind, "");
        try list.addIfMatch("ne", "ne", kind, "");
        try testing.expect(list.exact);
        try testing.expectEqual(@as(usize, 3), list.items.items.len);
        try testing.expectEqualStrings("ne", list.items.items[0].text);
        try testing.expectEqualStrings("networks", list.items.items[1].text);
        try testing.expectEqualStrings("some_ne", list.items.items[2].text);
    }
    var quoted: List = .{ .a = arena.allocator() };
    try quoted.addIfMatch("ne", "\"ne\"", .column, "");
    try testing.expect(quoted.exact);
    try testing.expectEqualStrings("ne", quoted.items.items[0].text);
    var keyword: List = .{ .a = arena.allocator() };
    try keyword.addIfMatchCase("SELECT", "SELECT", .keyword, "", true);
    try testing.expect(keyword.exact);
    try testing.expectEqualStrings("SELECT", keyword.items.items[0].text);
}

test "exact and prefix names survive a full completion list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var list: List = .{ .a = arena.allocator() };
    for (0..max_candidates) |i| {
        try list.addIfMatch(try std.fmt.allocPrint(arena.allocator(), "some_ne_{d}", .{i}), "ne", .table, "");
    }
    try list.addIfMatch("networks", "ne", .table, "");
    try testing.expectEqualStrings("networks", list.items.items[0].text);
    try list.addIfMatch("ne", "ne", .table, "");
    try testing.expectEqualStrings("ne", list.items.items[0].text);
    try testing.expectEqual(@as(usize, max_candidates), list.items.items.len);
}

test "alias columns" {
    var cache = try testCache(testing.allocator);
    defer cache.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const text = "select u.na from users as u";
    const cursor = "select u.na".len;
    const c = try complete(arena.allocator(), .{ .text = text, .cursor = cursor, .cache = &cache, .connections = &.{}, .commands = &.{} });
    try testing.expectEqual(@as(usize, 2), c.replace_len);
    try testing.expectEqualStrings("name", c.candidates[0].text);
}

test "keywords keep case and commands" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const c = try complete(arena.allocator(), .{ .text = "SEL", .cursor = 3, .cache = null, .connections = &.{}, .commands = &.{} });
    try testing.expectEqualStrings("SELECT", c.candidates[0].text);
    const cmds = [_]Command{ .{ .name = "/tables", .help = "" }, .{ .name = "/types", .help = "" } };
    const c2 = try complete(arena.allocator(), .{ .text = "/ta", .cursor = 3, .cache = null, .connections = &.{}, .commands = &cmds });
    try testing.expectEqual(@as(usize, 1), c2.candidates.len);
}

test "/def does not suggest ordinary tables" {
    var cache = try testCache(testing.allocator);
    defer cache.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const commands = [_]Command{
        .{ .name = "/def", .help = "definition" },
        .{ .name = "/browse", .help = "browse", .arg = .table },
    };
    const def = try complete(arena.allocator(), .{ .text = "/def us", .cursor = 7, .cache = &cache, .connections = &.{}, .commands = &commands });
    try testing.expectEqual(@as(usize, 0), def.candidates.len);
    const browse = try complete(arena.allocator(), .{ .text = "/browse us", .cursor = 10, .cache = &cache, .connections = &.{}, .commands = &commands });
    try testing.expectEqualStrings("users", browse.candidates[0].text);
}

test "operators depend on SQL dialect" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const text = "select * from users where name I";
    const pg = try complete(arena.allocator(), .{ .text = text, .cursor = text.len, .cache = null, .connections = &.{}, .commands = &.{}, .kind = .postgres });
    try testing.expect(hasCandidate(pg.candidates, "IN"));
    try testing.expect(hasCandidate(pg.candidates, "ILIKE"));

    const mysql = try complete(arena.allocator(), .{ .text = text, .cursor = text.len, .cache = null, .connections = &.{}, .commands = &.{}, .kind = .mysql });
    try testing.expect(hasCandidate(mysql.candidates, "IN"));
    try testing.expect(!hasCandidate(mysql.candidates, "ILIKE"));

    const sqlite_text = "select * from users where name G";
    const sqlite = try complete(arena.allocator(), .{ .text = sqlite_text, .cursor = sqlite_text.len, .cache = null, .connections = &.{}, .commands = &.{}, .kind = .sqlite });
    try testing.expect(hasCandidate(sqlite.candidates, "GLOB"));
    try testing.expect(!hasCandidate(sqlite.candidates, "ILIKE"));
}

test "operator position requires a condition in console SQL" {
    try testing.expect(operatorPrefix("name I", "name I".len, true) != null);
    try testing.expect(operatorPrefix("select name I", "select name I".len, false) == null);
    try testing.expect(operatorPrefix("select * from users where name I", "select * from users where name I".len, false) != null);
}

test "operator snippets place the cursor at the value" {
    const in = operatorSnippet("IN");
    try testing.expectEqualStrings(" ()", in.suffix);
    try testing.expectEqual(@as(usize, 1), in.cursor_back);
    const between = operatorSnippet("between");
    try testing.expectEqualStrings("  AND ", between.suffix);
    try testing.expectEqual(@as(usize, 5), between.cursor_back);
    const like = operatorSnippet("ILIKE");
    try testing.expectEqualStrings(" ''", like.suffix);
    try testing.expectEqual(@as(usize, 1), like.cursor_back);
}

fn hasCandidate(candidates: []const Candidate, text: []const u8) bool {
    for (candidates) |candidate| if (std.mem.eql(u8, candidate.text, text)) return true;
    return false;
}

fn firstTexts(c: Completion, n: usize) []const Candidate {
    return c.candidates[0..@min(n, c.candidates.len)];
}

test "context-aware SQL keywords" {
    var cache = try testCache(testing.allocator);
    defer cache.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Case = struct { text: []const u8, kind: db.Kind, first: []const u8 };
    const cases = [_]Case{
        .{ .text = "SE", .kind = .postgres, .first = "SELECT" },
        .{ .text = "se", .kind = .mysql, .first = "select" },
        .{ .text = "SELECT * F", .kind = .postgres, .first = "FROM" },
        .{ .text = "select * from ", .kind = .postgres, .first = "orders" },
        .{ .text = "select * from u", .kind = .postgres, .first = "users" },
        .{ .text = "DELETE ", .kind = .postgres, .first = "FROM" },
        .{ .text = "DELETE FROM ", .kind = .postgres, .first = "orders" },
        .{ .text = "delete from users where na", .kind = .postgres, .first = "name" },
        .{ .text = "select id from users where id = 1 a", .kind = .postgres, .first = "and" },
        .{ .text = "select * from users order ", .kind = .postgres, .first = "by" },
        .{ .text = "PRA", .kind = .sqlite, .first = "PRAGMA" },
        .{ .text = "SHOW T", .kind = .mysql, .first = "TABLES" },
    };
    for (cases) |c| {
        const r = try complete(a, .{ .text = c.text, .cursor = c.text.len, .cache = &cache, .connections = &.{}, .commands = &.{}, .kind = c.kind });
        if (r.candidates.len == 0 or !std.mem.eql(u8, r.candidates[0].text, c.first)) {
            std.debug.print("case '{s}': expected {s}, got {any}\n", .{ c.text, c.first, firstTexts(r, 3) });
            return error.TestUnexpectedResult;
        }
    }
    // PRAGMA is SQLite-only, TRUNCATE is not SQLite.
    const pg = try complete(a, .{ .text = "PRA", .cursor = 3, .cache = null, .connections = &.{}, .commands = &.{}, .kind = .postgres });
    try testing.expect(!hasCandidate(pg.candidates, "PRAGMA"));
    const lite = try complete(a, .{ .text = "TRUN", .cursor = 4, .cache = null, .connections = &.{}, .commands = &.{}, .kind = .sqlite });
    try testing.expect(!hasCandidate(lite.candidates, "TRUNCATE"));
}
