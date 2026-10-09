//! ClickHouse driver over the HTTP interface (port 8123, or 8443 with TLS).
//! Each query is one POST request; results come back as
//! TabSeparatedWithNames, so every value is text and `\N` is NULL.
//! Cancellation runs `KILL QUERY` for the query id on a second request.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const db = @import("db.zig");
const conninfo = @import("../conninfo.zig");
const Transport = @import("net.zig").Transport;

/// ClickHouse error code for a query stopped by KILL QUERY.
const query_was_cancelled = "394";

const Ch = struct {
    gpa: Allocator,
    io: Io,
    params: conninfo.Params,
    params_arena: std.heap.ArenaAllocator,
    server_version: []const u8 = "",
    err: db.ErrorText = .{},
    /// Query id of the running request, for cancellation.
    query_id: [32]u8 = undefined,
    query_id_len: std.atomic.Value(usize) = .init(0),

    const vtable: db.Connection.VTable = .{
        .query = query,
        .last_error = lastError,
        .cancel = cancel,
        .close = close,
    };

    fn useTls(p: conninfo.Params) bool {
        return p.ssl.requiresTls() or p.port == 8443;
    }

    fn port(p: conninfo.Params) u16 {
        if (p.port != 0) return p.port;
        return if (useTls(p)) 8443 else 8123;
    }

    fn query(ptr: *anyopaque, gpa: Allocator, sql: []const u8, opts: db.QueryOptions) db.QueryError!db.Result {
        const self: *Ch = @ptrCast(@alignCast(ptr));
        var id_buf: [16]u8 = undefined;
        self.io.random(&id_buf);
        const id = std.fmt.bytesToHex(id_buf, .lower);
        @memcpy(&self.query_id, &id);
        self.query_id_len.store(id.len, .release);
        defer self.query_id_len.store(0, .release);

        var resp = self.request(gpa, sql, &id, opts.max_rows) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ConnectFailed => return error.ConnectionLost,
            else => {
                self.err.set(self.gpa, "ClickHouse request failed: {t}", .{err});
                return error.ConnectionLost;
            },
        };
        defer resp.deinit(gpa);

        if (resp.status != 200 or resp.exceptionCode() != null) {
            const code = resp.exceptionCode() orelse "";
            self.err.set(self.gpa, "{s}", .{std.mem.trim(u8, resp.body.items, " \t\r\n")});
            return if (std.mem.eql(u8, code, query_was_cancelled)) error.Canceled else error.QueryFailed;
        }

        var b: db.ResultBuilder = .init(gpa);
        errdefer b.deinit();
        const a = b.allocator();
        const body = resp.body.items;

        if (body.len == 0) {
            // DDL / INSERT: no result set.
            if (resp.written_rows) |n| if (n > 0) {
                b.result.affected_rows = n;
                b.result.status = try std.fmt.allocPrint(a, "OK, {d} row{s} written", .{ n, if (n == 1) "" else "s" });
                return b.finish();
            };
            b.result.status = "OK";
            return b.finish();
        }

        if (!std.mem.eql(u8, resp.format(), "TabSeparatedWithNames")) {
            // The query chose its own FORMAT: show the raw output as one column.
            try b.setColumns(try a.dupe([]const u8, &.{"output"}));
            var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, body, "\n"), '\n');
            while (lines.next()) |line| {
                const row = try a.alloc(?[]const u8, 1);
                row[0] = try a.dupe(u8, line);
                try b.addRow(row);
            }
            b.result.status = try std.fmt.allocPrint(a, "{d} lines ({s})", .{ b.rows.items.len, resp.format() });
            return b.finish();
        }

        var lines = std.mem.splitScalar(u8, body, '\n');
        const header = lines.next() orelse "";
        var names: std.ArrayList([]const u8) = .empty;
        var fields = std.mem.splitScalar(u8, header, '\t');
        while (fields.next()) |f| try names.append(a, (try unescape(a, f)).?);
        try b.setColumns(names.items);

        while (lines.next()) |line| {
            if (line.len == 0 and lines.peek() == null) break; // trailing newline
            if (b.full(opts)) {
                b.result.truncated = true;
                break;
            }
            const row = try a.alloc(?[]const u8, names.items.len);
            var it = std.mem.splitScalar(u8, line, '\t');
            for (row) |*cell| cell.* = try unescape(a, it.next() orelse "");
            try b.addRow(row);
        }
        const n = b.rows.items.len;
        b.result.status = try std.fmt.allocPrint(a, "{d}{s} row{s}", .{ n, if (b.result.truncated) "+" else "", if (n == 1) "" else "s" });
        return b.finish();
    }

    const Response = struct {
        status: u16 = 0,
        // Lengths, not slices: the struct is returned by value.
        format_buf: [64]u8 = undefined,
        format_len: usize = 0,
        code_buf: [16]u8 = undefined,
        code_len: ?usize = null,
        written_rows: ?u64 = null,
        body: std.ArrayList(u8) = .empty,

        fn format(r: *const Response) []const u8 {
            return r.format_buf[0..r.format_len];
        }

        fn exceptionCode(r: *const Response) ?[]const u8 {
            return if (r.code_len) |n| r.code_buf[0..n] else null;
        }

        fn deinit(r: *Response, gpa: Allocator) void {
            r.body.deinit(gpa);
        }
    };

    /// Sends one POST request with `sql` as the body and reads the full response.
    fn request(self: *Ch, gpa: Allocator, sql: []const u8, query_id: []const u8, max_rows: usize) !Response {
        const p = self.params;
        const host = if (p.host.len > 0) p.host else "localhost";
        var diag: []const u8 = "";
        const t = Transport.connect(self.gpa, self.io, host, port(p), null, &diag) catch |err| {
            self.err.set(self.gpa, "cannot connect to {s}:{d}: {s}", .{ host, port(p), diag });
            return err;
        };
        defer t.close();
        if (useTls(p)) {
            t.startTls(host, if (p.ssl.requiresTls()) p.ssl else .require, &diag) catch |err| {
                self.err.set(self.gpa, "TLS handshake failed: {s}", .{diag});
                return err;
            };
        }

        // Query string: database, output format, id, and a row cap so huge
        // results stop on the server instead of streaming everything.
        var target: std.ArrayList(u8) = .empty;
        defer target.deinit(gpa);
        try target.appendSlice(gpa, "/?default_format=TabSeparatedWithNames&wait_end_of_query=1&query_id=");
        try target.appendSlice(gpa, query_id);
        if (max_rows != std.math.maxInt(usize)) {
            try target.print(gpa, "&max_result_rows={d}&result_overflow_mode=break", .{max_rows + 1});
        }
        if (p.database.len > 0) {
            try target.appendSlice(gpa, "&database=");
            try percentEncode(gpa, &target, p.database);
        }

        const w = t.writer();
        try w.print("POST {s} HTTP/1.1\r\nHost: {s}\r\nUser-Agent: zpeek\r\n", .{ target.items, host });
        try w.print("X-ClickHouse-User: {s}\r\n", .{if (p.user.len > 0) p.user else "default"});
        if (p.password.len > 0) try w.print("X-ClickHouse-Key: {s}\r\n", .{p.password});
        try w.print("Content-Type: text/plain; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{sql.len});
        try w.writeAll(sql);
        try t.flush();

        var resp: Response = .{};
        errdefer resp.deinit(gpa);
        const r = t.reader();

        // Status line and headers.
        const status_line = try r.takeDelimiterInclusive('\n');
        var parts = std.mem.splitScalar(u8, std.mem.trimEnd(u8, status_line, "\r\n"), ' ');
        _ = parts.next();
        resp.status = std.fmt.parseInt(u16, parts.next() orelse "0", 10) catch 0;
        var content_length: ?usize = null;
        var chunked = false;
        while (true) {
            const line = std.mem.trimEnd(u8, try r.takeDelimiterInclusive('\n'), "\r\n");
            if (line.len == 0) break;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const name = std.mem.trim(u8, line[0..colon], " ");
            const value = std.mem.trim(u8, line[colon + 1 ..], " ");
            if (std.ascii.eqlIgnoreCase(name, "content-length")) {
                content_length = std.fmt.parseInt(usize, value, 10) catch null;
            } else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
                chunked = std.ascii.findIgnoreCase(value, "chunked") != null;
            } else if (std.ascii.eqlIgnoreCase(name, "x-clickhouse-format")) {
                // Header lines live in the reader buffer: copy what we keep.
                const n = @min(value.len, resp.format_buf.len);
                @memcpy(resp.format_buf[0..n], value[0..n]);
                resp.format_len = n;
            } else if (std.ascii.eqlIgnoreCase(name, "x-clickhouse-exception-code")) {
                const n = @min(value.len, resp.code_buf.len);
                @memcpy(resp.code_buf[0..n], value[0..n]);
                resp.code_len = n;
            } else if (std.ascii.eqlIgnoreCase(name, "x-clickhouse-summary")) {
                resp.written_rows = summaryNumber(value, "written_rows");
            }
        }
        // Body.
        if (chunked) {
            while (true) {
                const size_line = std.mem.trimEnd(u8, try r.takeDelimiterInclusive('\n'), "\r\n");
                const semi = std.mem.indexOfScalar(u8, size_line, ';') orelse size_line.len;
                const size = std.fmt.parseInt(usize, size_line[0..semi], 16) catch return error.ProtocolError;
                if (size == 0) break;
                const start = resp.body.items.len;
                try resp.body.resize(gpa, start + size);
                try r.readSliceAll(resp.body.items[start..]);
                _ = try r.takeDelimiterInclusive('\n'); // CRLF after the chunk
            }
        } else if (content_length) |len| {
            try resp.body.resize(gpa, len);
            try r.readSliceAll(resp.body.items);
        } else {
            // Connection: close without length: read to the end.
            var buf: [4096]u8 = undefined;
            while (true) {
                const n = r.readSliceShort(&buf) catch break;
                if (n == 0) break;
                try resp.body.appendSlice(gpa, buf[0..n]);
            }
        }
        return resp;
    }

    fn cancel(ptr: *anyopaque) void {
        const self: *Ch = @ptrCast(@alignCast(ptr));
        const len = self.query_id_len.load(.acquire);
        if (len == 0) return;
        var sql_buf: [96]u8 = undefined;
        const sql = std.fmt.bufPrint(&sql_buf, "KILL QUERY WHERE query_id = '{s}' ASYNC", .{self.query_id[0..len]}) catch return;
        var id_buf: [16]u8 = undefined;
        self.io.random(&id_buf);
        const id = std.fmt.bytesToHex(id_buf, .lower);
        var resp = self.request(self.gpa, sql, &id, std.math.maxInt(usize)) catch return;
        resp.deinit(self.gpa);
    }

    fn lastError(ptr: *anyopaque) []const u8 {
        const self: *Ch = @ptrCast(@alignCast(ptr));
        return self.err.slice();
    }

    fn close(ptr: *anyopaque) void {
        const self: *Ch = @ptrCast(@alignCast(ptr));
        self.err.deinit(self.gpa);
        if (self.server_version.len > 0) self.gpa.free(self.server_version);
        self.params_arena.deinit();
        self.gpa.destroy(self);
    }
};

/// Reads a number from X-ClickHouse-Summary, e.g. {"written_rows":"3",...}.
fn summaryNumber(summary: []const u8, key: []const u8) ?u64 {
    var buf: [48]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "\"{s}\":\"", .{key}) catch return null;
    const start = (std.mem.indexOf(u8, summary, needle) orelse return null) + needle.len;
    const end = std.mem.indexOfScalarPos(u8, summary, start, '"') orelse return null;
    return std.fmt.parseInt(u64, summary[start..end], 10) catch null;
}

fn percentEncode(gpa: Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try out.append(gpa, c);
        } else {
            try out.print(gpa, "%{X:0>2}", .{c});
        }
    }
}

/// Decodes one TSV field; `\N` is NULL.
fn unescape(a: Allocator, field: []const u8) Allocator.Error!?[]const u8 {
    if (std.mem.eql(u8, field, "\\N")) return null;
    if (std.mem.indexOfScalar(u8, field, '\\') == null) return try a.dupe(u8, field);
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < field.len) : (i += 1) {
        if (field[i] != '\\' or i + 1 == field.len) {
            try out.append(a, field[i]);
            continue;
        }
        i += 1;
        try out.append(a, switch (field[i]) {
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            'b' => 8,
            'f' => 12,
            '0' => 0,
            else => field[i], // \\ \' and anything else
        });
    }
    return out.items;
}

pub fn connect(gpa: Allocator, io: Io, params: conninfo.Params, err_out: *db.ErrorText) db.ConnectError!db.Connection {
    const self = try gpa.create(Ch);
    self.* = .{ .gpa = gpa, .io = io, .params = params, .params_arena = .init(gpa) };
    const pa = self.params_arena.allocator();
    const copied: ?conninfo.Params = blk: {
        var p = params;
        p.host = pa.dupe(u8, params.host) catch break :blk null;
        p.user = pa.dupe(u8, params.user) catch break :blk null;
        p.password = pa.dupe(u8, params.password) catch break :blk null;
        p.database = pa.dupe(u8, params.database) catch break :blk null;
        break :blk p;
    };
    self.params = copied orelse {
        Ch.close(self);
        return error.OutOfMemory;
    };

    // Check the server and credentials right away.
    const conn: db.Connection = .{ .ptr = self, .vtable = &Ch.vtable, .kind = .clickhouse };
    var r = conn.query(gpa, "SELECT version()") catch |err| {
        switch (err) {
            error.OutOfMemory => {},
            else => err_out.set(gpa, "{s}", .{self.err.slice()}),
        }
        Ch.close(self);
        return if (err == error.OutOfMemory) error.OutOfMemory else error.ConnectFailed;
    };
    defer r.deinit();
    if (r.rows.len > 0 and r.rows[0].len > 0) {
        if (r.rows[0][0]) |v| self.server_version = gpa.dupe(u8, v) catch "";
    }
    return .{ .ptr = self, .vtable = &Ch.vtable, .kind = .clickhouse, .server_version = self.server_version };
}

const testing = std.testing;

test "tsv unescape" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect((try unescape(a, "\\N")) == null);
    try testing.expectEqualStrings("a\tb\nc\\", (try unescape(a, "a\\tb\\nc\\\\")).?);
    try testing.expectEqualStrings("it's", (try unescape(a, "it\\'s")).?);
}

test "summary" {
    try testing.expectEqual(@as(?u64, 3), summaryNumber("{\"read_rows\":\"0\",\"written_rows\":\"3\"}", "written_rows"));
    try testing.expectEqual(@as(?u64, null), summaryNumber("{}", "written_rows"));
}
