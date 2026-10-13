//! Driver-independent connection interface.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const conninfo = @import("../conninfo.zig");
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
    /// Rows changed by INSERT/UPDATE/DELETE when the server reports it.
    affected_rows: ?u64 = null,
    /// Short status line, e.g. "SELECT 3" or "CREATE TABLE".
    status: []const u8 = "",
    /// True when more rows were returned than `QueryOptions.max_rows`; the
    /// extra rows were read and discarded.
    truncated: bool = false,
    /// Approximate retained row storage, used to bound transcript memory.
    retained_bytes: usize = 0,

    pub fn deinit(r: *Result) void {
        r.arena.deinit();
    }

    pub fn hasRows(r: Result) bool {
        return r.columns.len > 0;
    }
};

/// Helper used by drivers to accumulate rows into a Result.
pub const ResultBuilder = struct {
    result: Result,
    rows: std.ArrayList([]const ?[]const u8) = .empty,
    stored_bytes: usize = 0,

    pub fn init(gpa: Allocator) ResultBuilder {
        return .{ .result = .{ .arena = .init(gpa) } };
    }

    pub fn allocator(b: *ResultBuilder) Allocator {
        return b.result.arena.allocator();
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
        if (row_bytes > opts.max_bytes -| b.stored_bytes) {
            b.result.truncated = true;
            return;
        }
        try b.rows.append(b.allocator(), row);
        b.stored_bytes += row_bytes;
    }

    /// True when a result limit is reached; drivers then skip storing rows.
    pub fn full(b: *const ResultBuilder, opts: QueryOptions) bool {
        return b.result.truncated or b.rows.items.len >= opts.max_rows or b.stored_bytes >= opts.max_bytes;
    }

    pub fn finish(b: *ResultBuilder) Result {
        b.result.rows = b.rows.items;
        b.result.retained_bytes +|= b.stored_bytes;
        return b.result;
    }

    pub fn deinit(b: *ResultBuilder) void {
        b.result.arena.deinit();
    }
};

pub const QueryOptions = struct {
    max_rows: usize = std.math.maxInt(usize),
    max_bytes: usize = 16 * 1024 * 1024,
};

pub const QueryError = error{
    /// The server rejected the statement; see `Connection.lastError`.
    QueryFailed,
    /// The connection is unusable; the caller should reconnect.
    ConnectionLost,
    Canceled,
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
        return c.vtable.query(c.ptr, gpa, sql, .{});
    }

    pub fn queryOpts(c: Connection, gpa: Allocator, sql: []const u8, opts: QueryOptions) QueryError!Result {
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
    return switch (params.kind) {
        .sqlite => sqlite.connect(gpa, params, err_out),
        .postgres => postgres.connect(gpa, io, params, err_out),
        .mysql => mysql.connect(gpa, io, params, err_out),
        .clickhouse => clickhouse.connect(gpa, io, params, err_out),
    };
}

test {
    _ = sqlite;
    _ = postgres;
    _ = mysql;
    _ = clickhouse;
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
