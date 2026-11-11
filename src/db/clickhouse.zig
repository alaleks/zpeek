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
const lexer = @import("../sql/lexer.zig");

/// ClickHouse error code for a query stopped by KILL QUERY.
const query_was_cancelled = "394";

/// One reusable line buffer; retained values belong only to the result arena.
const BodySink = struct {
    gpa: Allocator,
    response: *Ch.Response,
    builder: ?*db.ResultBuilder,
    opts: db.QueryOptions,
    line: std.ArrayList(u8) = .empty,
    pending_empty: usize = 0,

    fn feed(s: *BodySink, bytes: []const u8) !void {
        if (s.builder == null and bytes.len > s.opts.max_bytes -| s.response.body_bytes) return error.ResponseTooLarge;
        s.response.body_bytes += bytes.len;
        if (s.builder == null) return s.response.body.appendSlice(s.gpa, bytes);
        var remaining = bytes;
        while (remaining.len > 0) {
            const b = s.builder.?;
            if (b.result.columns.len > 0 and b.full(s.opts) and std.mem.eql(u8, s.response.format(), "TabSeparatedWithNames")) {
                b.result.truncated = true;
                return;
            }
            const end = std.mem.indexOfScalar(u8, remaining, '\n') orelse {
                try s.line.appendSlice(s.gpa, remaining);
                return;
            };
            if (s.line.items.len == 0) {
                try s.consumeLine(remaining[0..end]);
            } else {
                try s.line.appendSlice(s.gpa, remaining[0..end]);
                try s.consumeLine(s.line.items);
            }
            @import("../memory.zig").clear(&s.line, s.gpa);
            remaining = remaining[end + 1 ..];
        }
    }

    fn finish(s: *BodySink) !void {
        if (s.builder == null) return;
        if (s.line.items.len > 0) try s.consumeLine(s.line.items);
        // Raw FORMAT output historically ignores trailing newlines.
        if (s.pending_empty > 0 and s.builder.?.rows.items.len == 0) try s.rawRow("");
    }

    fn rawRow(s: *BodySink, line: []const u8) !void {
        const b = s.builder.?;
        var row = (try b.allocRow(1, line.len, s.opts)) orelse return;
        row.put(0, line);
        try b.addRow(row.row, s.opts);
    }

    fn consumeLine(s: *BodySink, line: []const u8) !void {
        const b = s.builder.?;
        const a = b.allocator();
        if (!std.mem.eql(u8, s.response.format(), "TabSeparatedWithNames")) {
            if (b.result.columns.len == 0) try b.setColumns(try a.dupe([]const u8, &.{"output"}));
            if (line.len == 0) {
                s.pending_empty += 1;
                return;
            }
            while (s.pending_empty > 0) : (s.pending_empty -= 1) try s.rawRow("");
            return s.rawRow(line);
        }
        var fields = std.mem.splitScalar(u8, line, '\t');
        if (b.result.columns.len == 0) {
            var names: std.ArrayList([]const u8) = .empty;
            while (fields.next()) |field| try names.append(a, (try ownedField(a, field)) orelse return error.ProtocolError);
            return b.setColumns(names.items);
        }
        const ncols = b.result.columns.len;
        var value_bytes: usize = 0;
        for (0..ncols) |_| value_bytes +|= decodedSize(fields.next() orelse "");
        var row = (try b.allocRow(ncols, value_bytes, s.opts)) orelse return;
        fields.reset();
        for (0..ncols) |i| putField(&row, i, fields.next() orelse "");
        try b.addRow(row.row, s.opts);
    }
};

fn putField(row: *db.RowBuffer, index: usize, field: []const u8) void {
    if (std.mem.eql(u8, field, "\\N")) {
        row.put(index, null);
        return;
    }
    const dest = row.reserve(index, decodedSize(field));
    unescapeInto(dest, field);
}

fn decodedSize(field: []const u8) usize {
    if (std.mem.eql(u8, field, "\\N")) return 0;
    var size: usize = 0;
    var i: usize = 0;
    while (i < field.len) : (i += 1) {
        if (field[i] == '\\' and i + 1 < field.len) i += 1;
        size += 1;
    }
    return size;
}

fn ownedField(a: Allocator, field: []const u8) !?[]const u8 {
    const value = (try unescape(a, field)) orelse return null;
    return if (value.ptr == field.ptr) try a.dupe(u8, value) else value;
}

fn readBody(gpa: Allocator, r: *Io.Reader, response: *Ch.Response, builder: ?*db.ResultBuilder, opts: db.QueryOptions, content_length: ?usize, chunked: bool) !void {
    var sink: BodySink = .{
        .gpa = gpa,
        .response = response,
        .builder = if (response.status == 200 and response.exceptionCode() == null) builder else null,
        .opts = opts,
    };
    defer sink.line.deinit(gpa);
    var buffer: [4096]u8 = undefined;
    if (chunked) {
        while (true) {
            const line = std.mem.trimEnd(u8, try r.takeDelimiterInclusive('\n'), "\r\n");
            const end = std.mem.indexOfScalar(u8, line, ';') orelse line.len;
            var remaining = std.fmt.parseInt(usize, line[0..end], 16) catch return error.ProtocolError;
            if (remaining == 0) {
                while (std.mem.trimEnd(u8, try r.takeDelimiterInclusive('\n'), "\r\n").len != 0) {}
                break;
            }
            if (sink.builder == null and remaining > opts.max_bytes -| response.body_bytes) return error.ResponseTooLarge;
            while (remaining > 0) {
                const part = buffer[0..@min(remaining, buffer.len)];
                try r.readSliceAll(part);
                try sink.feed(part);
                remaining -= part.len;
            }
            if (!std.mem.eql(u8, try r.take(2), "\r\n")) return error.ProtocolError;
        }
    } else if (content_length) |length| {
        if (sink.builder == null and length > opts.max_bytes) return error.ResponseTooLarge;
        var remaining = length;
        while (remaining > 0) {
            const part = buffer[0..@min(remaining, buffer.len)];
            try r.readSliceAll(part);
            try sink.feed(part);
            remaining -= part.len;
        }
    } else {
        while (true) {
            const n = try r.readSliceShort(&buffer);
            if (n == 0) break;
            try sink.feed(buffer[0..n]);
        }
    }
    try sink.finish();
}

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
    /// HTTP keep-alive connection reused by queries (job thread only; cancel
    /// opens its own). Reused only while the server's Keep-Alive timeout says
    /// it is open, so a request never needs a retry on a stale socket.
    idle: ?*Transport = null,
    idle_since: Io.Timestamp = .zero,
    idle_limit_ms: i64 = 0,

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
        self.err.set(self.gpa, "", .{});
        var id_buf: [16]u8 = undefined;
        self.io.random(&id_buf);
        const id = std.fmt.bytesToHex(id_buf, .lower);
        @memcpy(&self.query_id, &id);
        self.query_id_len.store(id.len, .release);
        defer self.query_id_len.store(0, .release);

        var b: db.ResultBuilder = .init(gpa);
        errdefer b.deinit();
        const a = b.allocator();
        var resp = self.request(self.gpa, sql, &id, opts.max_rows, opts.max_bytes, true, true, &b) catch |first| retry: {
            // The server closed the kept-alive connection before answering (e.g.
            // it restarted). Replay reads on a fresh connection; never writes,
            // in case the server ran them before closing.
            if (first == error.StaleConnection and lexer.readOnlyViolation(sql, .mysql) == null) {
                break :retry self.request(self.gpa, sql, &id, opts.max_rows, opts.max_bytes, true, true, &b);
            }
            break :retry first;
        } catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.StaleConnection => {
                self.err.set(self.gpa, "ClickHouse closed the idle connection; check whether the statement ran before repeating it", .{});
                return error.ConnectionLost;
            },
            error.ConnectFailed => return error.ConnectionLost,
            error.ResponseTooLarge => {
                self.err.set(self.gpa, "ClickHouse response exceeds {d} bytes", .{opts.max_bytes});
                return error.QueryFailed;
            },
            else => {
                if (self.err.slice().len == 0) self.err.set(self.gpa, "ClickHouse request failed: {t}", .{err});
                return error.ConnectionLost;
            },
        };
        defer resp.deinit(self.gpa);
        if (resp.status != 200 or resp.exceptionCode() != null) {
            const code = resp.exceptionCode() orelse "";
            self.err.set(self.gpa, "{s}", .{std.mem.trim(u8, resp.body.items, " \t\r\n")});
            return if (std.mem.eql(u8, code, query_was_cancelled)) error.Canceled else error.QueryFailed;
        }

        if (resp.body_bytes == 0) {
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
            b.result.status = try std.fmt.allocPrint(a, "{d} lines ({s})", .{ b.rows.items.len, resp.format() });
            return b.finish();
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
        body_bytes: usize = 0,

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
    /// The idle keep-alive connection if the server still keeps it open.
    fn takeIdle(self: *Ch) ?*Transport {
        const t = self.idle orelse return null;
        self.idle = null;
        // One second of margin against the server closing it right now.
        if (self.idle_since.untilNow(self.io, .awake).toMilliseconds() < self.idle_limit_ms - 1000) return t;
        t.close();
        return null;
    }

    fn open(self: *Ch, record_error: bool) !*Transport {
        const p = self.params;
        const host = if (p.host.len > 0) p.host else "localhost";
        var diag: []const u8 = "";
        const t = Transport.connect(self.gpa, self.io, host, port(p), null, &diag) catch |err| {
            if (record_error) self.err.set(self.gpa, "cannot connect to {s}:{d}: {s}", .{ host, port(p), diag });
            return err;
        };
        errdefer t.close();
        if (useTls(p)) {
            t.startTls(host, if (p.ssl.requiresTls()) p.ssl else .require, &diag) catch |err| {
                if (record_error) self.err.set(self.gpa, "TLS handshake failed: {s}", .{diag});
                return err;
            };
        }
        return t;
    }

    /// Writes the request and returns the response status line.
    fn sendHead(self: *Ch, t: *Transport, target: []const u8, host: []const u8, sql: []const u8, reuse: bool) ![]u8 {
        const p = self.params;
        const w = t.writer();
        try w.print("POST {s} HTTP/1.1\r\nHost: {s}\r\nUser-Agent: zpeek\r\n", .{ target, host });
        try w.print("X-ClickHouse-User: {s}\r\n", .{if (p.user.len > 0) p.user else "default"});
        if (p.password.len > 0) try w.print("X-ClickHouse-Key: {s}\r\n", .{p.password});
        try w.print("Content-Type: text/plain; charset=utf-8\r\nContent-Length: {d}\r\nConnection: {s}\r\n\r\n", .{ sql.len, if (reuse) "keep-alive" else "close" });
        try w.writeAll(sql);
        try t.flush();
        return t.reader().takeDelimiterInclusive('\n');
    }

    /// `reuse`: keep the connection open for the next query (job thread only).
    fn request(self: *Ch, gpa: Allocator, sql: []const u8, query_id: []const u8, max_rows: usize, max_bytes: usize, record_error: bool, reuse: bool, builder: ?*db.ResultBuilder) !Response {
        const p = self.params;
        const host = if (p.host.len > 0) p.host else "localhost";
        const reused = if (reuse) self.takeIdle() else null;
        const t = reused orelse try self.open(record_error);
        var keep_alive_ms: ?i64 = null;
        defer if (keep_alive_ms) |ms| {
            self.idle = t;
            self.idle_since = .now(self.io, .awake);
            self.idle_limit_ms = ms;
        } else t.close();
        errdefer if (record_error and t.read_timed_out) self.err.set(self.gpa, "database response timed out after 300 s", .{});

        // Query string: database, output format, id, and a row cap so huge
        // results stop on the server instead of streaming everything.
        var target: std.ArrayList(u8) = .empty;
        defer target.deinit(gpa);
        try target.appendSlice(gpa, "/?default_format=TabSeparatedWithNames&wait_end_of_query=1&query_id=");
        try target.appendSlice(gpa, query_id);
        // readonly=2 forbids writes but still lets zpeek set the row cap below.
        if (p.access == .read_only) try target.appendSlice(gpa, "&readonly=2");
        if (max_rows != std.math.maxInt(usize)) {
            try target.print(gpa, "&max_result_rows={d}&result_overflow_mode=break", .{max_rows + 1});
        }
        if (p.database.len > 0) {
            try target.appendSlice(gpa, "&database=");
            try percentEncode(gpa, &target, p.database);
        }

        // Until the first response line, a failure on a reused connection means
        // the server had already closed it (a timed-out read is a slow query).
        const status_line = self.sendHead(t, target.items, host, sql, reuse) catch |err| {
            if (reused != null and !t.read_timed_out and err != error.OutOfMemory) return error.StaleConnection;
            return err;
        };

        var resp: Response = .{};
        errdefer resp.deinit(gpa);
        const r = t.reader();

        // Status line and headers.
        var parts = std.mem.splitScalar(u8, std.mem.trimEnd(u8, status_line, "\r\n"), ' ');
        _ = parts.next();
        resp.status = std.fmt.parseInt(u16, parts.next() orelse "0", 10) catch 0;
        var content_length: ?usize = null;
        var chunked = false;
        var server_timeout_ms: ?i64 = null;
        var server_closes = false;
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
            } else if (std.ascii.eqlIgnoreCase(name, "connection")) {
                server_closes = std.ascii.findIgnoreCase(value, "close") != null;
            } else if (std.ascii.eqlIgnoreCase(name, "keep-alive")) {
                server_timeout_ms = keepAliveTimeoutMs(value);
            } else if (std.ascii.eqlIgnoreCase(name, "x-clickhouse-summary")) {
                resp.written_rows = summaryNumber(value, "written_rows");
            }
        }
        try readBody(gpa, r, &resp, builder, .{ .max_rows = max_rows, .max_bytes = max_bytes }, content_length, chunked);
        // A fully read, length-delimited response leaves the connection reusable.
        if (reuse and !server_closes and (chunked or content_length != null)) keep_alive_ms = server_timeout_ms;
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
        var resp = self.request(self.gpa, sql, &id, std.math.maxInt(usize), 16 * 1024 * 1024, false, false, null) catch return;
        resp.deinit(self.gpa);
    }

    fn lastError(ptr: *anyopaque) []const u8 {
        const self: *Ch = @ptrCast(@alignCast(ptr));
        return self.err.slice();
    }

    fn close(ptr: *anyopaque) void {
        const self: *Ch = @ptrCast(@alignCast(ptr));
        if (self.idle) |t| t.close();
        self.err.deinit(self.gpa);
        if (self.server_version.len > 0) self.gpa.free(self.server_version);
        self.params_arena.deinit();
        self.gpa.destroy(self);
    }
};

/// `timeout=10, max=9999` -> 10000 ms; null when absent.
fn keepAliveTimeoutMs(value: []const u8) ?i64 {
    var it = std.mem.tokenizeAny(u8, value, ", ");
    while (it.next()) |part| {
        if (std.mem.startsWith(u8, part, "timeout=")) {
            const seconds = std.fmt.parseInt(i64, part["timeout=".len..], 10) catch return null;
            return seconds * 1000;
        }
    }
    return null;
}

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
    if (std.mem.indexOfScalar(u8, field, '\\') == null) return field;
    const out = try a.alloc(u8, decodedSize(field));
    unescapeInto(out, field);
    return out;
}

fn unescapeInto(out: []u8, field: []const u8) void {
    var written: usize = 0;
    var i: usize = 0;
    while (i < field.len) : (i += 1) {
        if (field[i] != '\\' or i + 1 == field.len) {
            out[written] = field[i];
            written += 1;
            continue;
        }
        i += 1;
        out[written] = switch (field[i]) {
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            'b' => 8,
            'f' => 12,
            '0' => 0,
            else => field[i], // \\ \' and anything else
        };
        written += 1;
    }
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

test "complete TSV lines need no scratch allocation and retain owned values" {
    const a = std.testing.allocator;
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    var response: Ch.Response = .{ .status = 200 };
    defer response.deinit(failing.allocator());
    const format = "TabSeparatedWithNames";
    @memcpy(response.format_buf[0..format.len], format);
    response.format_len = format.len;
    var builder = db.ResultBuilder.init(a);
    defer builder.deinit();
    var sink: BodySink = .{ .gpa = failing.allocator(), .response = &response, .builder = &builder, .opts = .{} };
    defer sink.line.deinit(failing.allocator());
    var body = "id\tvalue\n1\t日本\\t語\n2\t\\N\n".*;
    try sink.feed(&body);
    try sink.finish();
    @memset(&body, 'x');
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try std.testing.expectEqual(@as(usize, 2), builder.rows.items.len);
    try std.testing.expectEqualStrings("value", builder.result.columns[1]);
    try std.testing.expectEqualStrings("日本\t語", builder.rows.items[0][1].?);
    try std.testing.expect(builder.rows.items[1][1] == null);
}

test "discarded TSV rows need no scratch allocation after row or byte limits" {
    const a = std.testing.allocator;
    const prefix = "value\nkept\n";
    const body_len = prefix.len + 1024 * 1024 + 1;
    const wire = try a.alloc(u8, body_len + 4);
    defer a.free(wire);
    @memcpy(wire[0..prefix.len], prefix);
    @memset(wire[prefix.len .. body_len - 1], 'x');
    wire[body_len - 1] = '\n';
    @memcpy(wire[body_len..], "NEXT");
    for ([_]db.QueryOptions{ .{ .max_rows = 1 }, .{ .max_bytes = @sizeOf(?[]const u8) + 4 } }) |opts| {
        var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
        var response: Ch.Response = .{ .status = 200 };
        defer response.deinit(failing.allocator());
        const format = "TabSeparatedWithNames";
        @memcpy(response.format_buf[0..format.len], format);
        response.format_len = format.len;
        var builder = db.ResultBuilder.init(a);
        defer builder.deinit();
        var reader: Io.Reader = .fixed(wire);
        try readBody(failing.allocator(), &reader, &response, &builder, opts, body_len, false);
        try std.testing.expectEqual(@as(usize, 0), failing.allocations);
        try std.testing.expectEqual(@as(usize, 1), builder.rows.items.len);
        try std.testing.expectEqualStrings("kept", builder.rows.items[0][0].?);
        try std.testing.expect(builder.result.truncated);
        try std.testing.expectEqual(body_len, response.body_bytes);
        try std.testing.expectEqualStrings("NEXT", try reader.take(4));
    }
}

test "stream limits preserve exact row counts and raw trailing newlines" {
    const a = std.testing.allocator;
    for ([_]struct { body: []const u8, tsv: bool = true, limit: usize = 1, rows: usize = 1, truncated: bool = false }{
        .{ .body = "value\nkept\n" },
        .{ .body = "value\nkept" },
        .{ .body = "value\nkept\n\n", .truncated = true },
        .{ .body = "value\n", .limit = 0, .rows = 0 },
        .{ .body = "value\n\n", .limit = 0, .rows = 0, .truncated = true },
        .{ .body = "first\n\n", .tsv = false },
        .{ .body = "first\n\nlast\n\n", .tsv = false, .truncated = true },
    }) |case| {
        var response: Ch.Response = .{ .status = 200 };
        defer response.deinit(a);
        if (case.tsv) {
            const format = "TabSeparatedWithNames";
            @memcpy(response.format_buf[0..format.len], format);
            response.format_len = format.len;
        }
        var builder = db.ResultBuilder.init(a);
        defer builder.deinit();
        var reader: Io.Reader = .fixed(case.body);
        try readBody(a, &reader, &response, &builder, .{ .max_rows = case.limit }, case.body.len, false);
        try std.testing.expectEqual(case.rows, builder.rows.items.len);
        try std.testing.expectEqual(case.truncated, builder.result.truncated);
    }
}

test "streamed TSV survives chunk boundaries and drains trailers after row limits" {
    const a = std.testing.allocator;
    const text = "id\tvalue\n1\ta\\tb\n2\t\\N\n3\tlast\n";
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(a);
    for (text) |byte| try wire.print(a, "1\r\n{c}\r\n", .{byte});
    try wire.appendSlice(a, "0\r\nX-Trailer: done\r\n\r\nNEXT");
    var reader: Io.Reader = .fixed(wire.items);
    var response: Ch.Response = .{ .status = 200 };
    defer response.deinit(a);
    const format = "TabSeparatedWithNames";
    @memcpy(response.format_buf[0..format.len], format);
    response.format_len = format.len;
    var builder: db.ResultBuilder = .init(a);
    defer builder.deinit();
    try readBody(a, &reader, &response, &builder, .{ .max_rows = 2 }, null, true);
    try std.testing.expectEqualStrings("a\tb", builder.rows.items[0][1].?);
    try std.testing.expect(builder.rows.items[1][1] == null);
    try std.testing.expect(builder.result.truncated);
    try std.testing.expectEqualStrings("NEXT", try reader.take(4));
    try std.testing.expectEqual(@as(usize, 0), response.body.capacity);
}

test "streamed result does not retain the HTTP body or borrowed input" {
    const a = std.testing.allocator;
    const header = "value\n";
    const body = try a.alloc(u8, header.len + 5000 * 256);
    defer a.free(body);
    @memcpy(body[0..header.len], header);
    @memset(body[header.len..], 'a');
    for (0..5000) |i| body[header.len + i * 256 + 255] = '\n';
    var scratch: [32 * 1024]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&scratch);
    var reader: Io.Reader = .fixed(body);
    var response: Ch.Response = .{ .status = 200 };
    defer response.deinit(fixed.allocator());
    const format = "TabSeparatedWithNames";
    @memcpy(response.format_buf[0..format.len], format);
    response.format_len = format.len;
    var builder: db.ResultBuilder = .init(a);
    defer builder.deinit();
    try readBody(fixed.allocator(), &reader, &response, &builder, .{ .max_rows = 1 }, body.len, false);
    @memset(body, 'z');
    @memset(&scratch, 0);
    try std.testing.expectEqual(@as(usize, 1), builder.rows.items.len);
    try std.testing.expectEqual(@as(usize, 255), builder.rows.items[0][0].?.len);
    try std.testing.expectEqual(@as(u8, 'a'), builder.rows.items[0][0].?[0]);
    try std.testing.expectEqualStrings("value", builder.result.columns[0]);
    try std.testing.expect(builder.result.arena.queryCapacity() < 8192);
    try std.testing.expectEqual(@as(usize, 0), response.body.capacity);
}

test "streamed results may exceed the stored byte limit" {
    const a = std.testing.allocator;
    const body = "value\nfirst\nsecond\n";
    for ([_]bool{ false, true }) |chunked| {
        var response: Ch.Response = .{ .status = 200 };
        defer response.deinit(a);
        var builder: db.ResultBuilder = .init(a);
        defer builder.deinit();
        var reader: Io.Reader = .fixed(if (chunked) "13\r\nvalue\nfirst\nsecond\n\r\n0\r\n\r\n" else body);
        try readBody(a, &reader, &response, &builder, .{ .max_bytes = 6 }, if (chunked) null else body.len, chunked);
        try std.testing.expectEqual(@as(usize, 0), builder.rows.items.len);
        try std.testing.expect(builder.result.truncated);
        try std.testing.expectEqual(@as(usize, body.len), response.body_bytes);
    }
}

test "HTTP streaming handles EOF bodies, raw formats, errors and incomplete framing" {
    const a = std.testing.allocator;
    {
        var response: Ch.Response = .{ .status = 200 };
        defer response.deinit(a);
        var builder: db.ResultBuilder = .init(a);
        defer builder.deinit();
        var reader: Io.Reader = .fixed("first\n\nlast\n\n");
        try readBody(a, &reader, &response, &builder, .{}, null, false);
        try std.testing.expectEqual(@as(usize, 3), builder.rows.items.len);
        try std.testing.expectEqualStrings("", builder.rows.items[1][0].?);
        try std.testing.expectEqualStrings("last", builder.rows.items[2][0].?);
    }
    {
        var response: Ch.Response = .{ .status = 500 };
        defer response.deinit(a);
        var builder: db.ResultBuilder = .init(a);
        defer builder.deinit();
        var reader: Io.Reader = .fixed("failure");
        try readBody(a, &reader, &response, &builder, .{}, 7, false);
        try std.testing.expectEqualStrings("failure", response.body.items);
        try std.testing.expectEqual(@as(usize, 0), builder.rows.items.len);
    }
    for ([_]struct { bytes: []const u8, length: ?usize, chunked: bool }{
        .{ .bytes = "ab", .length = 3, .chunked = false },
        .{ .bytes = "3\r\nab", .length = null, .chunked = true },
        .{ .bytes = "0\r\nX-Trailer: incomplete", .length = null, .chunked = true },
    }) |case| {
        var response: Ch.Response = .{};
        defer response.deinit(a);
        var reader: Io.Reader = .fixed(case.bytes);
        try std.testing.expectError(error.EndOfStream, readBody(a, &reader, &response, null, .{}, case.length, case.chunked));
    }
    var response: Ch.Response = .{};
    defer response.deinit(a);
    var reader: Io.Reader = .fixed("too large");
    try std.testing.expectError(error.ResponseTooLarge, readBody(a, &reader, &response, null, .{ .max_bytes = 3 }, 9, false));
    try std.testing.expectEqual(@as(usize, 0), response.body.capacity);
}

test "tsv unescape" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect((try unescape(a, "\\N")) == null);
    try testing.expectEqualStrings("a\tb\nc\\", (try unescape(a, "a\\tb\\nc\\\\")).?);
    try testing.expectEqualStrings("it's", (try unescape(a, "it\\'s")).?);
}

test "keep-alive timeout" {
    try testing.expectEqual(@as(?i64, 10_000), keepAliveTimeoutMs("timeout=10, max=9999"));
    try testing.expectEqual(@as(?i64, 3_000), keepAliveTimeoutMs("timeout=3"));
    try testing.expectEqual(@as(?i64, null), keepAliveTimeoutMs("max=5"));
}

test "summary" {
    try testing.expectEqual(@as(?u64, 3), summaryNumber("{\"read_rows\":\"0\",\"written_rows\":\"3\"}", "written_rows"));
    try testing.expectEqual(@as(?u64, null), summaryNumber("{}", "written_rows"));
}
