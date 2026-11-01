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
    var tokens: lexer.Iterator = .initDialect(statement, dialect);
    while (tokens.next()) |token| {
        if (token.tag == .whitespace or token.tag == .comment) continue;
        const word = token.text(statement);
        for ([_][]const u8{ "select", "with", "values", "table", "insert", "update", "delete", "replace", "merge" }) |allowed| {
            if (std.ascii.eqlIgnoreCase(word, allowed)) break;
        } else return error.ExpectedPlannableQuery;
        break;
    }
    const prefix = switch (kind) {
        .sqlite => "EXPLAIN QUERY PLAN ",
        .clickhouse => "EXPLAIN PLAN ",
        .postgres, .mysql => "EXPLAIN ",
    };
    return std.mem.concat(a, u8, &.{ prefix, statement });
}

test "plan SQL uses each dialect and refuses executing a second statement" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("EXPLAIN QUERY PLAN select 1", try sql(a, .sqlite, "select 1;"));
    try std.testing.expectEqualStrings("EXPLAIN select 1", try sql(a, .postgres, "select 1"));
    try std.testing.expectEqualStrings("EXPLAIN select 1", try sql(a, .mysql, "select 1"));
    try std.testing.expectEqualStrings("EXPLAIN PLAN select 1", try sql(a, .clickhouse, "select 1"));
    try std.testing.expectEqualStrings("EXPLAIN update users set name='Ada'", try sql(a, .postgres, "update users set name='Ada'"));
    try std.testing.expectError(error.ExpectedOneQuery, sql(a, .postgres, "select 1; drop table users"));
    try std.testing.expectError(error.ExpectedPlannableQuery, sql(a, .sqlite, "pragma journal_mode=off"));
    try std.testing.expectError(error.ExpectedPlannableQuery, sql(a, .postgres, "explain analyze delete from users where true"));
}
