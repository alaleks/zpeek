//! Driver-independent connection interface.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const conninfo = @import("../conninfo.zig");
const lexer = @import("../sql/lexer.zig");
pub const Kind = conninfo.Kind;

const sqlite = @import("sqlite.zig");
const postgres = @import("postgres.zig");
const mysql = @import("mysql.zig");
const clickhouse = @import("clickhouse.zig");

/// Result of one statement. Values are kept in their text form; `null` is SQL NULL.
pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    columns: []const []const u8 = &.{},
    /// PostgreSQL boolean columns; empty when the driver does not provide types.
    boolean_columns: []const bool = &.{},
    rows: []const []const ?[]const u8 = &.{},
    row_storage: ?struct { gpa: Allocator, allocation: [][]const ?[]const u8 } = null,
    /// Rows changed by INSERT/UPDATE/DELETE when the server reports it.
    affected_rows: ?u64 = null,
    elapsed_ms: ?i64 = null,
    /// Short status line, e.g. "SELECT 3" or "CREATE TABLE".
    status: []const u8 = "",
    /// True when more rows were returned than `QueryOptions.max_rows`; the
    /// extra rows were read and discarded.
    truncated: bool = false,
    /// Approximate retained row storage, used to bound transcript memory.
    retained_bytes: usize = 0,

    pub fn deinit(r: *Result) void {
        if (r.row_storage) |storage| storage.gpa.free(storage.allocation);
        r.arena.deinit();
    }

    pub fn capacity(r: *const Result) usize {
        return r.arena.queryCapacity() +| (if (r.row_storage) |storage| storage.allocation.len *| @sizeOf([]const ?[]const u8) else @as(usize, 0));
    }

    pub fn hasRows(r: Result) bool {
        return r.columns.len > 0;
    }
};

/// A row pointer array and one contiguous buffer for its non-null values.
pub const RowBuffer = struct {
    row: []?[]const u8,
    remaining: []u8,

    pub fn put(r: *RowBuffer, index: usize, value: ?[]const u8) void {
        const v = value orelse {
            r.row[index] = null;
            return;
        };
        const dest = r.reserve(index, v.len);
        @memcpy(dest, v);
    }

    pub fn reserve(r: *RowBuffer, index: usize, len: usize) []u8 {
        const dest = r.remaining[0..len];
        r.row[index] = dest;
        r.remaining = r.remaining[len..];
        return dest;
    }
};

/// Helper used by drivers to accumulate rows into a Result.
pub const ResultBuilder = struct {
    result: Result,
    gpa: Allocator,
    rows: std.ArrayList([]const ?[]const u8) = .empty,
    row_chunk: []align(@alignOf(?[]const u8)) u8 = &.{},
    next_chunk_bytes: usize = 8 * 1024,
    stored_bytes: usize = 0,

    pub fn init(gpa: Allocator) ResultBuilder {
        return .{ .gpa = gpa, .result = .{ .arena = .init(gpa) } };
    }

    pub fn allocator(b: *ResultBuilder) Allocator {
        return b.result.arena.allocator();
    }

    pub fn allocRow(b: *ResultBuilder, ncols: usize, value_bytes: usize, opts: QueryOptions) Allocator.Error!?RowBuffer {
        const pointer_bytes = std.math.mul(usize, ncols, @sizeOf(?[]const u8)) catch return error.OutOfMemory;
        const row_bytes = std.math.add(usize, pointer_bytes, value_bytes) catch return error.OutOfMemory;
        if (!b.acceptsRow(row_bytes, opts)) return null;
        const a = b.allocator();
        const alignment = @alignOf(?[]const u8);
        const padded_bytes = std.math.add(usize, row_bytes, alignment - 1) catch return error.OutOfMemory;
        const stride = std.mem.alignBackward(usize, padded_bytes, alignment);
        if (b.row_chunk.len < stride) {
            const chunk_bytes = @max(stride, @min(b.next_chunk_bytes, opts.max_bytes - b.stored_bytes, stride *| (opts.max_rows - b.rows.items.len)));
            b.row_chunk = try a.alignedAlloc(u8, .of(?[]const u8), std.mem.alignBackward(usize, chunk_bytes, alignment));
            b.next_chunk_bytes = @min(64 * 1024, @max(b.next_chunk_bytes, stride) *| 2);
        }
        const block = b.row_chunk[0..row_bytes];
        b.row_chunk = @alignCast(b.row_chunk[stride..]);
        const row = std.mem.bytesAsSlice(?[]const u8, block[0..pointer_bytes]);
        const data = block[pointer_bytes..];
        return .{ .row = row, .remaining = data };
    }

    pub fn setColumns(b: *ResultBuilder, names: []const []const u8) Allocator.Error!void {
        b.result.columns = names;
        b.rows.clearRetainingCapacity();
    }

    pub fn addRow(b: *ResultBuilder, row: []const ?[]const u8, opts: QueryOptions) Allocator.Error!void {
        var row_bytes: usize = row.len *| @sizeOf(?[]const u8);
        for (row) |cell| if (cell) |value| {
            row_bytes +|= value.len;
        };
        if (!b.acceptsRow(row_bytes, opts)) return;
        try b.rows.append(b.gpa, row);
        b.stored_bytes += row_bytes;
    }

    /// Drivers call this before copying a row into the result arena.
    pub fn acceptsRow(b: *ResultBuilder, row_bytes: usize, opts: QueryOptions) bool {
        if (b.full(opts) or row_bytes > opts.max_bytes -| b.stored_bytes) {
            b.result.truncated = true;
            return false;
        }
        return true;
    }

    /// True when a result limit is reached; drivers then skip storing rows.
    pub fn full(b: *const ResultBuilder, opts: QueryOptions) bool {
        return b.result.truncated or b.rows.items.len >= opts.max_rows or b.stored_bytes >= opts.max_bytes;
    }

    pub fn finish(b: *ResultBuilder) Result {
        b.result.rows = b.rows.items;
        b.result.row_storage = .{ .gpa = b.gpa, .allocation = b.rows.allocatedSlice() };
        b.result.retained_bytes +|= b.stored_bytes +| b.rows.capacity *| @sizeOf([]const ?[]const u8);
        b.rows = .empty;
        return b.result;
    }

    pub fn deinit(b: *ResultBuilder) void {
        b.rows.deinit(b.gpa);
        b.result.deinit();
    }
};

test "packed rows preserve nulls and empty values and respect the byte budget" {
    var builder = ResultBuilder.init(std.testing.allocator);
    defer builder.deinit();
    var row = (try builder.allocRow(4, 3, .{})).?;
    row.put(0, "ab");
    row.put(1, null);
    row.put(2, "");
    row.put(3, "c");
    try std.testing.expectEqualStrings("ab", row.row[0].?);
    try std.testing.expect(row.row[1] == null);
    try std.testing.expectEqualStrings("", row.row[2].?);
    try std.testing.expectEqualStrings("c", row.row[3].?);
    try std.testing.expectEqual(@intFromPtr(row.row.ptr) + 4 * @sizeOf(?[]const u8), @intFromPtr(row.row[0].?.ptr));
    try std.testing.expectEqual(@as(usize, 0), row.remaining.len);
    try builder.addRow(row.row, .{});
    try std.testing.expect((try builder.allocRow(1, 1, .{ .max_bytes = builder.stored_bytes })) == null);
    try std.testing.expectError(error.OutOfMemory, builder.allocRow(std.math.maxInt(usize), 1, .{}));
}

pub const QueryOptions = struct {
    max_rows: usize = std.math.maxInt(usize),
    max_bytes: usize = 16 * 1024 * 1024,
};

test "short results fit in a small allocation budget" {
    var memory: [16 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&memory);
    var result = blk: {
        var builder = ResultBuilder.init(fixed.allocator());
        errdefer builder.deinit();
        try builder.setColumns(&.{ "id", "name", "note" });
        var row = (try builder.allocRow(3, 7, .{})).?;
        row.put(0, "1");
        row.put(1, "日本");
        row.put(2, null);
        try builder.addRow(row.row, .{});
        break :blk builder.finish();
    };
    defer result.deinit();
    try std.testing.expect(result.capacity() < memory.len);
    try std.testing.expectEqualStrings("日本", result.rows[0][1].?);
    try std.testing.expect(result.rows[0][2] == null);
}

test "row chunks bound backing allocations and preserve earlier values" {
    var counted = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    var builder = ResultBuilder.init(std.testing.allocator);
    builder.result.arena.child_allocator = counted.allocator();
    defer builder.deinit();
    try builder.setColumns(&.{"id"});
    for (0..5000) |i| {
        const value: [3]u8 = @splat(@intCast(i % 251));
        var row = (try builder.allocRow(1, value.len, .{})).?;
        row.put(0, &value);
        try builder.addRow(row.row, .{});
    }
    // Count row data separately from growth of the array of row references.
    try std.testing.expect(counted.allocations <= 4);
    counted.fail_index = counted.alloc_index;
    try std.testing.expect(builder.result.arena.queryCapacity() < 1024 * 1024);
    try std.testing.expectError(error.OutOfMemory, builder.allocRow(1, 1024 * 1024, .{}));
    for (builder.rows.items, 0..) |row, i| {
        const value: [3]u8 = @splat(@intCast(i % 251));
        try std.testing.expectEqualStrings(&value, row[0].?);
    }
}

test "row chunks respect small limits and accept values larger than a chunk" {
    for ([_]QueryOptions{ .{ .max_rows = 1 }, .{ .max_bytes = @sizeOf(?[]const u8) + 1 } }) |opts| {
        var memory: [256]u8 = undefined;
        var fixed = std.heap.FixedBufferAllocator.init(&memory);
        // Bound row chunks independently of the row-reference list's growth.
        var builder = ResultBuilder.init(std.testing.allocator);
        builder.result.arena.child_allocator = fixed.allocator();
        defer builder.deinit();
        var row = (try builder.allocRow(1, 1, opts)).?;
        row.put(0, "x");
        try builder.addRow(row.row, opts);
        try std.testing.expect((try builder.allocRow(1, 1, opts)) == null);
        try std.testing.expectEqualStrings("x", builder.rows.items[0][0].?);
    }
    var builder = ResultBuilder.init(std.testing.allocator);
    defer builder.deinit();
    const value: [64 * 1024 + 1]u8 = @splat('x');
    var row = (try builder.allocRow(1, value.len, .{})).?;
    row.put(0, &value);
    try builder.addRow(row.row, .{});
    try std.testing.expectEqualStrings(&value, builder.rows.items[0][0].?);
}

pub const QueryError = error{
    /// The server rejected the statement; see `Connection.lastError`.
    QueryFailed,
    /// The connection is unusable; the caller should reconnect.
    ConnectionLost,
    Canceled,
    AccessDenied,
} || Allocator.Error;

pub const ConnectError = error{ConnectFailed} || Allocator.Error;

/// Human readable error text written by drivers.
pub const ErrorText = struct {
    buf: std.ArrayList(u8) = .empty,

    pub fn set(e: *ErrorText, gpa: Allocator, comptime fmt: []const u8, args: anytype) void {
        e.buf.clearRetainingCapacity();
        e.buf.print(gpa, fmt, args) catch {};
    }

    pub fn slice(e: ErrorText) []const u8 {
        return e.buf.items;
    }

    pub fn deinit(e: *ErrorText, gpa: Allocator) void {
        e.buf.deinit(gpa);
    }
};

pub const Connection = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    kind: Kind,
    access: conninfo.Access = .full,
    /// Server version string, e.g. "16.2" or "11.4.2-MariaDB".
    server_version: []const u8 = "",

    pub const VTable = struct {
        query: *const fn (ptr: *anyopaque, gpa: Allocator, sql: []const u8, opts: QueryOptions) QueryError!Result,
        last_error: *const fn (ptr: *anyopaque) []const u8,
        /// Asks the server to stop the running query. Called from another
        /// thread while `query` is in progress; must be thread-safe.
        cancel: *const fn (ptr: *anyopaque) void,
        close: *const fn (ptr: *anyopaque) void,
    };

    pub fn query(c: Connection, gpa: Allocator, sql: []const u8) QueryError!Result {
        return c.queryOpts(gpa, sql, .{});
    }

    pub fn queryOpts(c: Connection, gpa: Allocator, sql: []const u8, opts: QueryOptions) QueryError!Result {
        const dialect: lexer.Dialect = switch (c.kind) {
            .postgres => .postgres,
            .mysql, .clickhouse => .mysql,
            .sqlite => .sqlite,
        };
        if (c.access.violation(sql, dialect) != null) return error.AccessDenied;
        if (c.access != .full and lexer.hasDeleteWithoutWhere(sql, dialect)) return error.AccessDenied;
        return c.vtable.query(c.ptr, gpa, sql, opts);
    }

    pub fn cancel(c: Connection) void {
        c.vtable.cancel(c.ptr);
    }

    pub fn lastError(c: Connection) []const u8 {
        return c.vtable.last_error(c.ptr);
    }

    pub fn close(c: Connection) void {
        c.vtable.close(c.ptr);
    }
};

/// Opens a connection. On failure `err_out` receives a description.
pub fn connect(gpa: Allocator, io: Io, params: conninfo.Params, err_out: *ErrorText) ConnectError!Connection {
    const Race = union(enum) {
        connection: ConnectError!Connection,
        timer: Io.Cancelable!void,
    };
    var results: [2]Race = undefined;
    var race: Io.Select(Race) = .init(io, &results);
    race.concurrent(.connection, connectRaw, .{ gpa, io, params, err_out }) catch return connectRaw(gpa, io, params, err_out);
    race.concurrent(.timer, Io.sleep, .{ io, Io.Duration.fromSeconds(30), Io.Clock.awake }) catch {
        const first = race.await() catch {
            while (race.cancel()) |late| closeLateConnection(late);
            return error.ConnectFailed;
        };
        return first.connection;
    };
    const first = race.await() catch {
        while (race.cancel()) |late| closeLateConnection(late);
        return error.ConnectFailed;
    };
    while (race.cancel()) |late| closeLateConnection(late);
    return switch (first) {
        .connection => |result| result,
        .timer => {
            err_out.set(gpa, "connection timed out after 30 s during handshake", .{});
            return error.ConnectFailed;
        },
    };
}

fn closeLateConnection(result: anytype) void {
    switch (result) {
        .connection => |conn| if (conn) |c| c.close() else |_| {},
        .timer => {},
    }
}

fn connectRaw(gpa: Allocator, io: Io, params: conninfo.Params, err_out: *ErrorText) ConnectError!Connection {
    var conn = try switch (params.kind) {
        .sqlite => sqlite.connect(gpa, params, err_out),
        .postgres => postgres.connect(gpa, io, params, err_out),
        .mysql => mysql.connect(gpa, io, params, err_out),
        .clickhouse => clickhouse.connect(gpa, io, params, err_out),
    };
    // SQLite opens the file read-only and ClickHouse sends readonly=2 with
    // every request; the network servers get a read-only session.
    if (params.access != .read_only) {
        conn.access = params.access;
        return conn;
    }
    const sql = switch (params.kind) {
        .postgres => "SET default_transaction_read_only = on",
        .mysql => "SET SESSION TRANSACTION READ ONLY",
        .sqlite, .clickhouse => {
            conn.access = params.access;
            return conn;
        },
    };
    var r = conn.query(gpa, sql) catch |err| {
        // Fail closed: never hand out a writable session for a read-only entry.
        err_out.set(gpa, "cannot make the session read-only: {s}", .{conn.lastError()});
        conn.close();
        return if (err == error.OutOfMemory) error.OutOfMemory else error.ConnectFailed;
    };
    r.deinit();
    conn.access = params.access;
    return conn;
}

test {
    _ = sqlite;
    _ = postgres;
    _ = mysql;
    _ = clickhouse;
}

test "read-delete connection refuses schema writes and only deletes matching rows" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "app.sqlite", .data = "" });
    const path = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "app.sqlite" });
    var err: ErrorText = .{};
    defer err.deinit(gpa);
    const full = try connect(gpa, std.testing.io, .{ .kind = .sqlite, .database = path }, &err);
    defer full.close();
    var setup = try full.query(gpa, "create table people(id integer primary key); insert into people values (1), (2), (3);");
    setup.deinit();
    const limited = try connect(gpa, std.testing.io, .{ .kind = .sqlite, .database = path, .access = .read_delete }, &err);
    defer limited.close();
    var columns = try limited.query(gpa, "select * from pragma_table_info('people')");
    columns.deinit();
    var removed = try limited.query(gpa, "delete from people where id = 1");
    removed.deinit();
    for ([_][]const u8{
        "create table other(id integer)",
        "create view other as select * from people",
        "create index idx on people(id)",
        "alter table people add column name text",
        "drop table people",
        "insert into people values (4)",
        "update people set id = 4",
        "delete from people",
        "delete from people where id = 2; drop table people",
        "pragma writable_schema = on",
    }) |sql| try std.testing.expectError(error.AccessDenied, limited.query(gpa, sql));
    var rows = try limited.query(gpa, "select id from people order by id");
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 2), rows.rows.len);
    try std.testing.expectEqualStrings("2", rows.rows[0][0].?);
    var trigger = try full.query(gpa, "create table audit(id integer); create trigger audit_delete after delete on people begin insert into audit values (old.id); end;");
    trigger.deinit();
    // SQLite's authorizer also rejects writes hidden in an existing trigger.
    try std.testing.expectError(error.QueryFailed, limited.query(gpa, "delete from people where id = 2"));
    try std.testing.expectError(error.QueryFailed, limited.vtable.query(limited.ptr, gpa, "drop table people", .{}));
    var remaining = try limited.query(gpa, "select count(*) from people");
    defer remaining.deinit();
    try std.testing.expectEqualStrings("2", remaining.rows[0][0].?);
}

test "result byte limit stops storing rows" {
    var b: ResultBuilder = .init(std.testing.allocator);
    defer b.deinit();
    const opts: QueryOptions = .{ .max_bytes = 3 };
    try b.addRow(&.{"abcd"}, opts);
    try std.testing.expect(b.result.truncated);
    try std.testing.expectEqual(@as(usize, 0), b.rows.items.len);
    try std.testing.expect(b.full(opts));
}

fn buildOwnedRows(a: Allocator) !void {
    var builder = ResultBuilder.init(a);
    errdefer builder.deinit();
    try builder.setColumns(&.{"id"});
    for (0..1000) |_| {
        var row = (try builder.allocRow(1, 3, .{})).?;
        row.put(0, "123");
        try builder.addRow(row.row, .{});
    }
    var result = builder.finish();
    defer result.deinit();
    std.debug.assert(result.row_storage != null);
    std.debug.assert(result.rows.len == 1000);
    std.debug.assert(result.capacity() > result.arena.queryCapacity());
    std.debug.assert(std.mem.eql(u8, result.rows[999][0].?, "123"));
}

test "row storage transfers ownership and survives allocation failures" {
    try buildOwnedRows(std.testing.allocator);
    // In-place arena/list growth otherwise changes the allocation count between runs.
    var no_resize = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(no_resize.allocator(), buildOwnedRows, .{});
}
