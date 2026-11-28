const std = @import("std");
const conninfo = @import("conninfo.zig");
const lexer = @import("sql/lexer.zig");

/// Only a single plannable statement is accepted; never generates ANALYZE.
pub fn sql(a: std.mem.Allocator, kind: conninfo.Kind, query: []const u8) ![]const u8 {
    const dialect: lexer.Dialect = switch (kind) {
        .postgres => .postgres,
        .mysql, .clickhouse => .mysql,
        .sqlite => .sqlite,
    };
    var statements: std.ArrayList([]const u8) = .empty;
    defer statements.deinit(a);
    try lexer.splitStatements(query, dialect, &statements, a);
    if (statements.items.len != 1) return error.ExpectedOneQuery;
    const statement = statements.items[0];
    try validate(statement, dialect, false);
    // MySQL quote escaping also depends on the session's NO_BACKSLASH_ESCAPES mode.
    if (dialect == .mysql) try validate(statement, dialect, true);
    const prefix = switch (kind) {
        .sqlite => "EXPLAIN QUERY PLAN ",
        .clickhouse => "EXPLAIN PLAN ",
        .postgres, .mysql => "EXPLAIN ",
    };
    return std.mem.concat(a, u8, &.{ prefix, statement });
}

fn validate(statement: []const u8, dialect: lexer.Dialect, mysql_no_backslash_escapes: bool) error{ ExpectedOneQuery, ExpectedPlannableQuery }!void {
    var tokens: lexer.Iterator = .{ .src = statement, .dialect = dialect, .mysql_no_backslash_escapes = mysql_no_backslash_escapes };
    var saw_first = false;
    while (tokens.next()) |token| {
        if (token.tag == .whitespace) continue;
        if (token.tag == .comment) {
            if (dialect == .mysql) {
                const comment = token.text(statement);
                if (std.mem.startsWith(u8, comment, "/*!") or std.mem.startsWith(u8, comment, "/*M!")) {
                    return error.ExpectedPlannableQuery;
                }
            }
            continue;
        }
        if (token.tag == .punctuation and statement[token.start] == ';') return error.ExpectedOneQuery;
        if (!saw_first) {
            saw_first = true;
            const word = token.text(statement);
            for ([_][]const u8{ "select", "with", "values", "table", "insert", "update", "delete", "replace", "merge" }) |allowed| {
                if (std.ascii.eqlIgnoreCase(word, allowed)) break;
            } else return error.ExpectedPlannableQuery;
        }
    }
    if (!saw_first) return error.ExpectedPlannableQuery;
}

test "plan SQL uses each dialect and refuses executing a second statement" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("EXPLAIN QUERY PLAN select 1", try sql(a, .sqlite, "select 1;"));
    try std.testing.expectEqualStrings("EXPLAIN select 1", try sql(a, .postgres, "select 1"));
    try std.testing.expectEqualStrings("EXPLAIN select 1", try sql(a, .mysql, "select 1"));
    try std.testing.expectEqualStrings("EXPLAIN select 1 # note; comment", try sql(a, .mysql, "select 1 # note; comment"));
    try std.testing.expectEqualStrings("EXPLAIN PLAN select 1", try sql(a, .clickhouse, "select 1"));
    try std.testing.expectEqualStrings("EXPLAIN update users set name='Ada'", try sql(a, .postgres, "update users set name='Ada'"));
    try std.testing.expectEqualStrings("EXPLAIN select 'a\\'b'", try sql(a, .mysql, "select 'a\\'b'"));
    try std.testing.expectError(error.ExpectedOneQuery, sql(a, .postgres, "select 1; drop table users"));
    try std.testing.expectError(error.ExpectedOneQuery, sql(a, .mysql, "select 'a\\'; drop table users"));
    try std.testing.expectError(error.ExpectedOneQuery, sql(a, .sqlite, "select 1; create trigger tr after insert on t begin drop table u; end"));
    try std.testing.expectError(error.ExpectedPlannableQuery, sql(a, .sqlite, "pragma journal_mode=off"));
    try std.testing.expectError(error.ExpectedPlannableQuery, sql(a, .postgres, "explain analyze delete from users where true"));
    try std.testing.expectError(error.ExpectedPlannableQuery, sql(a, .mysql, "/*!50000 ANALYZE */ delete from users"));
    try std.testing.expectError(error.ExpectedPlannableQuery, sql(a, .mysql, "/*M! ANALYZE */ select 1"));
    try std.testing.expectError(error.ExpectedPlannableQuery, sql(a, .mysql, "/* \\' */"));
}
