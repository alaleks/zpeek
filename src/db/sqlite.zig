//! SQLite driver on top of the vendored amalgamation.

const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("sqlite_c");
const db = @import("db.zig");
const conninfo = @import("../conninfo.zig");

const Sqlite = struct {
    gpa: Allocator,
    handle: *c.sqlite3,
    err: db.ErrorText = .{},

    const vtable: db.Connection.VTable = .{
        .query = query,
        .last_error = lastError,
        .cancel = cancel,
        .close = close,
    };

    fn query(ptr: *anyopaque, gpa: Allocator, sql: []const u8, opts: db.QueryOptions) db.QueryError!db.Result {
        const self: *Sqlite = @ptrCast(@alignCast(ptr));
        var builder: db.ResultBuilder = .init(gpa);
        errdefer builder.deinit();

        var rest = sql;
        var ran_any = false;
        while (true) {
            rest = std.mem.trimStart(u8, rest, " \t\r\n;");
            if (rest.len == 0) break;

            var stmt: ?*c.sqlite3_stmt = null;
            var tail: [*c]const u8 = null;
            if (c.sqlite3_prepare_v2(self.handle, rest.ptr, @intCast(rest.len), &stmt, &tail) != c.SQLITE_OK) {
                self.setError();
                return error.QueryFailed;
            }
            const consumed = @intFromPtr(tail) - @intFromPtr(rest.ptr);
            rest = rest[consumed..];
            const s = stmt orelse continue; // comment-only input
            defer _ = c.sqlite3_finalize(s);
            ran_any = true;
            try self.runStatement(s, &builder, opts);
        }
        if (!ran_any) builder.result.status = "OK";
        return builder.finish();
    }

    fn runStatement(self: *Sqlite, s: *c.sqlite3_stmt, b: *db.ResultBuilder, opts: db.QueryOptions) db.QueryError!void {
        const a = b.allocator();
        const ncols: usize = @intCast(c.sqlite3_column_count(s));
        if (ncols > 0) {
            const names = try a.alloc([]const u8, ncols);
            for (names, 0..) |*n, i| {
                n.* = try a.dupe(u8, std.mem.span(c.sqlite3_column_name(s, @intCast(i))));
            }
            try b.setColumns(names);
            b.result.affected_rows = null;
            b.result.truncated = false;
        }

        while (true) {
            const rc = c.sqlite3_step(s);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) {
                self.setError();
                return if (rc == c.SQLITE_INTERRUPT) error.Canceled else error.QueryFailed;
            }
            if (b.full(opts)) {
                // SQLite computes rows lazily, so stopping here is cheap.
                b.result.truncated = true;
                break;
            }
            const row = try a.alloc(?[]const u8, ncols);
            for (row, 0..) |*cell, i| cell.* = try columnText(a, s, @intCast(i));
            try b.addRow(row);
        }

        if (ncols > 0) {
            b.result.status = try std.fmt.allocPrint(a, "{d}{s} row{s}", .{
                b.rows.items.len, if (b.result.truncated) "+" else "", plural(b.rows.items.len),
            });
        } else {
            b.result.columns = &.{};
            b.rows.clearRetainingCapacity();
            const verb = try std.ascii.allocUpperString(a, firstWord(std.mem.span(c.sqlite3_sql(s))));
            if (isDml(verb)) {
                const changes: u64 = @intCast(c.sqlite3_changes64(self.handle));
                b.result.affected_rows = changes;
                b.result.status = try std.fmt.allocPrint(a, "{s} {d}", .{ verb, changes });
            } else {
                b.result.affected_rows = null;
                b.result.status = verb;
            }
        }
    }

    fn columnText(a: Allocator, s: *c.sqlite3_stmt, i: c_int) Allocator.Error!?[]const u8 {
        switch (c.sqlite3_column_type(s, i)) {
            c.SQLITE_NULL => return null,
            c.SQLITE_BLOB => {
                const len: usize = @intCast(c.sqlite3_column_bytes(s, i));
                const ptr: [*]const u8 = @ptrCast(c.sqlite3_column_blob(s, i) orelse return "");
                return try hexBlob(a, ptr[0..len]);
            },
            else => {
                const ptr = c.sqlite3_column_text(s, i) orelse return "";
                const len: usize = @intCast(c.sqlite3_column_bytes(s, i));
                return try a.dupe(u8, ptr[0..len]);
            },
        }
    }

    fn setError(self: *Sqlite) void {
        self.err.set(self.gpa, "ERROR: {s}", .{std.mem.span(c.sqlite3_errmsg(self.handle))});
    }

    fn cancel(ptr: *anyopaque) void {
        const self: *Sqlite = @ptrCast(@alignCast(ptr));
        c.sqlite3_interrupt(self.handle);
    }

    fn lastError(ptr: *anyopaque) []const u8 {
        const self: *Sqlite = @ptrCast(@alignCast(ptr));
        return self.err.slice();
    }

    fn close(ptr: *anyopaque) void {
        const self: *Sqlite = @ptrCast(@alignCast(ptr));
        _ = c.sqlite3_close_v2(self.handle);
        self.err.deinit(self.gpa);
        self.gpa.destroy(self);
    }
};

pub fn connect(gpa: Allocator, params: conninfo.Params, err_out: *db.ErrorText) db.ConnectError!db.Connection {
    const path = try gpa.dupeSentinel(u8, params.database, 0);
    defer gpa.free(path);

    var handle: ?*c.sqlite3 = null;
    // No SQLITE_OPEN_CREATE: a typo in the path should not silently create an empty database.
    const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_URI;
    const rc = c.sqlite3_open_v2(path.ptr, &handle, flags, null);
    if (rc != c.SQLITE_OK) {
        if (handle) |h| {
            err_out.set(gpa, "{s}: {s}", .{ params.database, std.mem.span(c.sqlite3_errmsg(h)) });
            _ = c.sqlite3_close_v2(h);
        } else {
            err_out.set(gpa, "{s}: cannot open database", .{params.database});
        }
        return error.ConnectFailed;
    }

    const self = try gpa.create(Sqlite);
    self.* = .{ .gpa = gpa, .handle = handle.? };
    _ = c.sqlite3_extended_result_codes(self.handle, 1);
    return .{
        .ptr = self,
        .vtable = &Sqlite.vtable,
        .kind = .sqlite,
        .server_version = std.mem.span(c.sqlite3_libversion()),
    };
}

fn hexBlob(a: Allocator, bytes: []const u8) Allocator.Error![]const u8 {
    const shown = @min(bytes.len, 64);
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "x'");
    for (bytes[0..shown]) |byte| try out.print(a, "{x:0>2}", .{byte});
    try out.append(a, '\'');
    if (shown < bytes.len) try out.print(a, "… ({d} bytes)", .{bytes.len});
    return out.items;
}

fn firstWord(sql: []const u8) []const u8 {
    const t = std.mem.trimStart(u8, sql, " \t\r\n(");
    var end: usize = 0;
    while (end < t.len and std.ascii.isAlphabetic(t[end])) end += 1;
    return t[0..end];
}

fn isDml(word: []const u8) bool {
    for ([_][]const u8{ "insert", "update", "delete", "replace" }) |w| {
        if (std.ascii.eqlIgnoreCase(word, w)) return true;
    }
    return false;
}

fn plural(n: usize) []const u8 {
    return if (n == 1) "" else "s";
}

test "sqlite in-memory round trip" {
    const gpa = std.testing.allocator;
    var err: db.ErrorText = .{};
    defer err.deinit(gpa);
    const conn = try connect(gpa, .{ .kind = .sqlite, .database = ":memory:" }, &err);
    defer conn.close();

    var r1 = try conn.query(gpa, "create table t(id integer primary key, name text, data blob); insert into t(name, data) values ('a', x'00ff'), (null, null);");
    defer r1.deinit();
    try std.testing.expectEqual(@as(?u64, 2), r1.affected_rows);

    var r2 = try conn.query(gpa, "select id, name, data from t order by id");
    defer r2.deinit();
    try std.testing.expectEqual(@as(usize, 3), r2.columns.len);
    try std.testing.expectEqual(@as(usize, 2), r2.rows.len);
    try std.testing.expectEqualStrings("a", r2.rows[0][1].?);
    try std.testing.expectEqualStrings("x'00ff'", r2.rows[0][2].?);
    try std.testing.expect(r2.rows[1][1] == null);

    var r3 = try conn.queryOpts(gpa, "with recursive n(v) as (select 1 union all select v + 1 from n where v < 1000) select v from n", .{ .max_rows = 10 });
    defer r3.deinit();
    try std.testing.expectEqual(@as(usize, 10), r3.rows.len);
    try std.testing.expect(r3.truncated);

    try std.testing.expectError(error.QueryFailed, conn.query(gpa, "select * from missing"));
    try std.testing.expect(std.mem.indexOf(u8, conn.lastError(), "missing") != null);
}
