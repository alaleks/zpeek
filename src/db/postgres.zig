//! PostgreSQL driver: frontend/backend protocol v3 over TCP or a Unix socket,
//! with TLS, SCRAM-SHA-256, MD5 and cleartext authentication. Queries use
//! the simple query protocol, so every value arrives in text form.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const db = @import("db.zig");
const conninfo = @import("../conninfo.zig");
const Transport = @import("net.zig").Transport;

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Md5 = std.crypto.hash.Md5;
const base64 = std.base64.standard;

const protocol_version: u32 = 196608; // 3.0
const ssl_request_code: u32 = 80877103;
const cancel_request_code: u32 = 80877102;
const max_message_size: usize = 64 * 1024 * 1024;

const Pg = struct {
    gpa: Allocator,
    io: Io,
    t: *Transport,
    /// Kept to open a second connection for CancelRequest.
    host: []const u8,
    port: u16,
    unix_path: ?[]const u8,
    backend_pid: u32 = 0,
    secret_key: u32 = 0,
    server_version: []const u8 = "",
    err: db.ErrorText = .{},
    msg: std.ArrayList(u8) = .empty,
    broken: bool = false,

    const vtable: db.Connection.VTable = .{
        .query = query,
        .last_error = lastError,
        .cancel = cancel,
        .close = close,
    };

    const Error = error{ ReadFailed, WriteFailed, EndOfStream, StreamTooLong, ProtocolError } || Allocator.Error;

    // ───────────── message I/O ─────────────

    /// Reads one backend message into `self.msg`; returns its type byte.
    fn readMessage(self: *Pg) Error!u8 {
        const r = self.t.reader();
        const kind = try r.takeByte();
        const len = try r.takeInt(u32, .big);
        const body_len = try checkedMessageBodyLength(len);
        try self.msg.resize(self.gpa, body_len);
        try r.readSliceAll(self.msg.items);
        return kind;
    }

    fn sendMessage(self: *Pg, kind: ?u8, parts: []const []const u8) Error!void {
        const w = self.t.writer();
        var len: usize = 4;
        for (parts) |p| len += p.len;
        if (kind) |k| try w.writeByte(k);
        try w.writeInt(u32, @intCast(len), .big);
        for (parts) |p| try w.writeAll(p);
        try self.t.flush();
    }

    // ───────────── startup ─────────────

    fn startup(self: *Pg, params: conninfo.Params) (Error || error{ AuthFailed, ServerError })!void {
        const user = if (params.user.len > 0) params.user else "postgres";
        const database = if (params.database.len > 0) params.database else user;
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.gpa);
        var ver: [4]u8 = undefined;
        std.mem.writeInt(u32, &ver, protocol_version, .big);
        try body.appendSlice(self.gpa, &ver);
        for ([_][2][]const u8{
            .{ "user", user },
            .{ "database", database },
            .{ "application_name", "zpeek" },
            .{ "client_encoding", "UTF8" },
            .{ "DateStyle", "ISO, YMD" },
        }) |kv| {
            try body.appendSlice(self.gpa, kv[0]);
            try body.append(self.gpa, 0);
            try body.appendSlice(self.gpa, kv[1]);
            try body.append(self.gpa, 0);
        }
        try body.append(self.gpa, 0);
        try self.sendMessage(null, &.{body.items});

        var scram: ?Scram = null;
        while (true) {
            const kind = try self.readMessage();
            const m = self.msg.items;
            switch (kind) {
                'R' => {
                    if (m.len < 4) return error.ProtocolError;
                    const code = std.mem.readInt(u32, m[0..4], .big);
                    switch (code) {
                        0 => {}, // AuthenticationOk
                        3 => { // cleartext
                            try self.sendPassword(params.password);
                        },
                        5 => { // MD5
                            if (m.len < 8) return error.ProtocolError;
                            var salt: [4]u8 = m[4..8].*;
                            try self.sendMd5(user, params.password, &salt);
                        },
                        10 => { // SASL: list of mechanisms
                            if (std.mem.indexOf(u8, m[4..], "SCRAM-SHA-256\x00") == null) {
                                self.err.set(self.gpa, "server requires an unsupported SASL mechanism", .{});
                                return error.AuthFailed;
                            }
                            scram = Scram.init(self.io);
                            const first = scram.?.clientFirst("");
                            var len_buf: [4]u8 = undefined;
                            std.mem.writeInt(u32, &len_buf, @intCast(first.len), .big);
                            try self.sendMessage('p', &.{ "SCRAM-SHA-256\x00", &len_buf, first });
                        },
                        11 => { // SASLContinue
                            const s = &(scram orelse return error.ProtocolError);
                            const final = s.clientFinal(self.gpa, m[4..], params.password) catch |e| switch (e) {
                                error.OutOfMemory => return error.OutOfMemory,
                                else => {
                                    self.err.set(self.gpa, "SCRAM authentication: invalid server message", .{});
                                    return error.AuthFailed;
                                },
                            };
                            defer self.gpa.free(final);
                            try self.sendMessage('p', &.{final});
                        },
                        12 => { // SASLFinal
                            const s = &(scram orelse return error.ProtocolError);
                            if (!s.verifyServer(m[4..])) {
                                self.err.set(self.gpa, "SCRAM authentication: server signature mismatch", .{});
                                return error.AuthFailed;
                            }
                        },
                        else => {
                            self.err.set(self.gpa, "unsupported authentication method (code {d})", .{code});
                            return error.AuthFailed;
                        },
                    }
                },
                'S' => self.parameterStatus(m),
                'K' => {
                    if (m.len >= 8) {
                        self.backend_pid = std.mem.readInt(u32, m[0..4], .big);
                        self.secret_key = std.mem.readInt(u32, m[4..8], .big);
                    }
                },
                'E' => {
                    self.setServerError(m);
                    return error.ServerError;
                },
                'N' => {},
                'Z' => return,
                else => return error.ProtocolError,
            }
        }
    }

    fn sendPassword(self: *Pg, password: []const u8) Error!void {
        try self.sendMessage('p', &.{ password, "\x00" });
    }

    fn sendMd5(self: *Pg, user: []const u8, password: []const u8, salt: *const [4]u8) Error!void {
        // "md5" + md5(md5(password + user) + salt), hex encoded
        var inner: [Md5.digest_length]u8 = undefined;
        var h = Md5.init(.{});
        h.update(password);
        h.update(user);
        h.final(&inner);
        const inner_hex = std.fmt.bytesToHex(inner, .lower);
        var outer: [Md5.digest_length]u8 = undefined;
        h = Md5.init(.{});
        h.update(&inner_hex);
        h.update(salt);
        h.final(&outer);
        const outer_hex = std.fmt.bytesToHex(outer, .lower);
        try self.sendMessage('p', &.{ "md5", &outer_hex, "\x00" });
    }

    fn parameterStatus(self: *Pg, m: []const u8) void {
        var it = std.mem.splitScalar(u8, m, 0);
        const name = it.next() orelse return;
        const value = it.next() orelse return;
        if (std.mem.eql(u8, name, "server_version")) {
            const short = if (std.mem.indexOfScalar(u8, value, ' ')) |sp| value[0..sp] else value;
            if (self.server_version.len > 0) self.gpa.free(self.server_version);
            self.server_version = self.gpa.dupe(u8, short) catch "";
        }
    }

    /// Formats an ErrorResponse: "ERROR: message (SQLSTATE) DETAIL … HINT …".
    fn setServerError(self: *Pg, m: []const u8) void {
        var severity: []const u8 = "ERROR";
        var code: []const u8 = "";
        var message: []const u8 = "";
        var detail: []const u8 = "";
        var hint: []const u8 = "";
        var position: []const u8 = "";
        var it = std.mem.splitScalar(u8, m, 0);
        while (it.next()) |field| {
            if (field.len == 0) continue;
            const v = field[1..];
            switch (field[0]) {
                'V' => severity = v,
                'S' => if (severity.len == 0) {
                    severity = v;
                },
                'C' => code = v,
                'M' => message = v,
                'D' => detail = v,
                'H' => hint = v,
                'P' => position = v,
                else => {},
            }
        }
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.gpa);
        buf.print(self.gpa, "{s}: {s}", .{ severity, message }) catch {};
        if (code.len > 0) buf.print(self.gpa, " (SQLSTATE {s})", .{code}) catch {};
        if (position.len > 0) buf.print(self.gpa, " at character {s}", .{position}) catch {};
        if (detail.len > 0) buf.print(self.gpa, "\nDETAIL: {s}", .{detail}) catch {};
        if (hint.len > 0) buf.print(self.gpa, "\nHINT: {s}", .{hint}) catch {};
        self.err.set(self.gpa, "{s}", .{buf.items});
    }

    // ───────────── queries ─────────────

    fn query(ptr: *anyopaque, gpa: Allocator, sql: []const u8, opts: db.QueryOptions) db.QueryError!db.Result {
        const self: *Pg = @ptrCast(@alignCast(ptr));
        if (self.broken) {
            self.err.set(self.gpa, "connection lost — reconnect with /connect", .{});
            return error.ConnectionLost;
        }
        return self.runQuery(gpa, sql, opts) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.QueryFailed => return error.QueryFailed,
            error.Canceled => return error.Canceled,
            else => {
                self.broken = true;
                self.err.set(self.gpa, "connection lost: {t}", .{err});
                return error.ConnectionLost;
            },
        };
    }

    fn runQuery(self: *Pg, gpa: Allocator, sql: []const u8, opts: db.QueryOptions) (Error || error{ QueryFailed, Canceled })!db.Result {
        try self.sendMessage('Q', &.{ sql, "\x00" });

        var b: db.ResultBuilder = .init(gpa);
        errdefer b.deinit();
        const a = b.allocator();
        var failed = false;
        var canceled = false;
        var copy_out = false;

        while (true) {
            const kind = try self.readMessage();
            const m = self.msg.items;
            switch (kind) {
                'T' => {
                    var r: Io.Reader = .fixed(m);
                    const n = try r.takeInt(u16, .big);
                    const names = try a.alloc([]const u8, n);
                    for (names) |*name| {
                        name.* = try a.dupe(u8, try r.takeDelimiterExclusive(0));
                        r.toss(1);
                        try r.discardAll(18); // table oid, attnum, type oid, typlen, typmod, format
                    }
                    try b.setColumns(names);
                    b.result.truncated = false;
                    b.result.affected_rows = null;
                },
                'D' => {
                    if (b.full(opts)) {
                        b.result.truncated = true;
                        continue;
                    }
                    var r: Io.Reader = .fixed(m);
                    const n = try r.takeInt(u16, .big);
                    const row = try a.alloc(?[]const u8, n);
                    for (row) |*cell| {
                        const len = try r.takeInt(i32, .big);
                        cell.* = if (len < 0) null else try a.dupe(u8, try r.take(@intCast(len)));
                    }
                    try b.addRow(row);
                },
                'C' => {
                    const tag = std.mem.sliceTo(m, 0);
                    b.result.status = try a.dupe(u8, tag);
                    if (std.mem.lastIndexOfScalar(u8, tag, ' ')) |sp| {
                        const verb_end = std.mem.indexOfScalar(u8, tag, ' ') orelse sp;
                        const verb = tag[0..verb_end];
                        const is_dml = for ([_][]const u8{ "INSERT", "UPDATE", "DELETE", "MERGE", "COPY" }) |v| {
                            if (std.mem.eql(u8, verb, v)) break true;
                        } else false;
                        if (is_dml) b.result.affected_rows = std.fmt.parseInt(u64, tag[sp + 1 ..], 10) catch null;
                    }
                    if (b.result.columns.len > 0) {
                        const rows = b.rows.items.len;
                        b.result.status = try std.fmt.allocPrint(a, "{d}{s} row{s}", .{ rows, if (b.result.truncated) "+" else "", if (rows == 1) "" else "s" });
                    }
                },
                'I' => b.result.status = "empty query",
                'E' => {
                    self.setServerError(m);
                    // 57014 = query_canceled
                    canceled = std.mem.indexOf(u8, m, "C57014\x00") != null;
                    failed = true;
                },
                'G' => try self.sendMessage('f', &.{"COPY FROM STDIN is not supported by zpeek\x00"}),
                'H' => {
                    if (m.len < 3 or m[0] != 0) {
                        self.err.set(self.gpa, "COPY TO STDOUT binary format is not supported", .{});
                        failed = true;
                    } else {
                        const names = try a.alloc([]const u8, 1);
                        names[0] = "COPY";
                        try b.setColumns(names);
                        copy_out = true;
                    }
                },
                'd' => if (copy_out and !b.full(opts)) {
                    const row = try a.alloc(?[]const u8, 1);
                    row[0] = try a.dupe(u8, std.mem.trimEnd(u8, m, "\r\n"));
                    try b.addRow(row);
                } else if (copy_out) {
                    b.result.truncated = true;
                },
                'c' => {},
                'W' => {
                    self.err.set(self.gpa, "COPY BOTH is not supported by zpeek", .{});
                    failed = true;
                },
                'S' => self.parameterStatus(m),
                'N', 'A', 'n', '1', '2', 's' => {},
                'Z' => break,
                else => return error.ProtocolError,
            }
        }
        if (canceled) return error.Canceled;
        if (failed) return error.QueryFailed;
        return b.finish();
    }

    fn cancel(ptr: *anyopaque) void {
        const self: *Pg = @ptrCast(@alignCast(ptr));
        if (self.backend_pid == 0) return;
        var diag: []const u8 = "";
        const t = Transport.connect(self.gpa, self.io, self.host, self.port, self.unix_path, &diag) catch return;
        defer t.close();
        var body: [12]u8 = undefined;
        std.mem.writeInt(u32, body[0..4], cancel_request_code, .big);
        std.mem.writeInt(u32, body[4..8], self.backend_pid, .big);
        std.mem.writeInt(u32, body[8..12], self.secret_key, .big);
        const w = t.writer();
        w.writeInt(u32, 16, .big) catch return;
        w.writeAll(&body) catch return;
        t.flush() catch return;
    }

    fn lastError(ptr: *anyopaque) []const u8 {
        const self: *Pg = @ptrCast(@alignCast(ptr));
        return self.err.slice();
    }

    fn close(ptr: *anyopaque) void {
        const self: *Pg = @ptrCast(@alignCast(ptr));
        if (!self.broken) self.sendMessage('X', &.{}) catch {};
        self.t.close();
        self.destroy();
    }

    fn destroy(self: *Pg) void {
        self.err.deinit(self.gpa);
        self.msg.deinit(self.gpa);
        if (self.server_version.len > 0) self.gpa.free(self.server_version);
        self.gpa.free(self.host);
        if (self.unix_path) |p| self.gpa.free(p);
        self.gpa.destroy(self);
    }
};

fn checkedMessageBodyLength(len: u32) error{ ProtocolError, StreamTooLong }!usize {
    if (len < 4) return error.ProtocolError;
    const body_len: usize = len - 4;
    if (body_len > max_message_size) return error.StreamTooLong;
    return body_len;
}

test "postgres message size is bounded" {
    try std.testing.expectEqual(@as(usize, 0), try checkedMessageBodyLength(4));
    try std.testing.expectError(error.ProtocolError, checkedMessageBodyLength(3));
    try std.testing.expectError(error.StreamTooLong, checkedMessageBodyLength(max_message_size + 5));
}

/// SCRAM-SHA-256 client state (RFC 5802 / 7677) without channel binding.
const Scram = struct {
    nonce_buf: [32]u8 = undefined,
    nonce_len: usize = 0,
    first_buf: [160]u8 = undefined,
    first_len: usize = 0,
    server_signature: [HmacSha256.mac_length]u8 = undefined,

    /// GS2 header: no channel binding, no authzid.
    const gs2_header = "n,,";

    fn init(io: Io) Scram {
        var raw: [18]u8 = undefined;
        io.random(&raw);
        var s: Scram = .{};
        s.nonce_len = base64.Encoder.encode(&s.nonce_buf, &raw).len;
        return s;
    }

    fn setNonce(s: *Scram, value: []const u8) void {
        @memcpy(s.nonce_buf[0..value.len], value);
        s.nonce_len = value.len;
    }

    fn nonce(s: *const Scram) []const u8 {
        return s.nonce_buf[0..s.nonce_len];
    }

    /// PostgreSQL ignores the SCRAM user name (it uses the startup user), so
    /// callers pass "" there; the parameter exists for the RFC test vector.
    fn clientFirst(s: *Scram, user: []const u8) []const u8 {
        const full = std.fmt.bufPrint(&s.first_buf, gs2_header ++ "n={s},r={s}", .{ user, s.nonce() }) catch unreachable;
        s.first_len = full.len;
        return full;
    }

    fn firstBare(s: *const Scram) []const u8 {
        return s.first_buf[gs2_header.len..s.first_len];
    }

    fn clientFinal(s: *Scram, gpa: Allocator, server_first: []const u8, password: []const u8) ![]u8 {
        var server_nonce: []const u8 = "";
        var salt_b64: []const u8 = "";
        var iterations: u32 = 0;
        var it = std.mem.splitScalar(u8, server_first, ',');
        while (it.next()) |attr| {
            if (attr.len < 2 or attr[1] != '=') continue;
            switch (attr[0]) {
                'r' => server_nonce = attr[2..],
                's' => salt_b64 = attr[2..],
                'i' => iterations = try std.fmt.parseInt(u32, attr[2..], 10),
                else => {},
            }
        }
        if (!std.mem.startsWith(u8, server_nonce, s.nonce()) or salt_b64.len == 0 or iterations == 0) return error.InvalidServerMessage;

        const salt_len = try base64.Decoder.calcSizeForSlice(salt_b64);
        const salt = try gpa.alloc(u8, salt_len);
        defer gpa.free(salt);
        try base64.Decoder.decode(salt, salt_b64);

        var salted: [32]u8 = undefined;
        try std.crypto.pwhash.pbkdf2(&salted, password, salt, iterations, HmacSha256);

        var client_key: [32]u8 = undefined;
        HmacSha256.create(&client_key, "Client Key", &salted);
        var stored_key: [32]u8 = undefined;
        Sha256.hash(&client_key, &stored_key, .{});

        const without_proof = try std.fmt.allocPrint(gpa, "c=biws,r={s}", .{server_nonce});
        defer gpa.free(without_proof);
        const auth_message = try std.fmt.allocPrint(gpa, "{s},{s},{s}", .{
            s.firstBare(), server_first, without_proof,
        });
        defer gpa.free(auth_message);

        var client_sig: [32]u8 = undefined;
        HmacSha256.create(&client_sig, auth_message, &stored_key);
        var proof: [32]u8 = undefined;
        for (&proof, client_key, client_sig) |*p, k, sig| p.* = k ^ sig;

        var server_key: [32]u8 = undefined;
        HmacSha256.create(&server_key, "Server Key", &salted);
        HmacSha256.create(&s.server_signature, auth_message, &server_key);

        var proof_b64: [base64.Encoder.calcSize(32)]u8 = undefined;
        _ = base64.Encoder.encode(&proof_b64, &proof);
        return std.fmt.allocPrint(gpa, "{s},p={s}", .{ without_proof, proof_b64 });
    }

    fn verifyServer(s: *const Scram, server_final: []const u8) bool {
        if (!std.mem.startsWith(u8, server_final, "v=")) return false;
        var expected: [base64.Encoder.calcSize(32)]u8 = undefined;
        _ = base64.Encoder.encode(&expected, &s.server_signature);
        const got = std.mem.trimEnd(u8, server_final[2..], "\x00");
        return std.mem.eql(u8, got, &expected);
    }
};

pub fn connect(gpa: Allocator, io: Io, params: conninfo.Params, err_out: *db.ErrorText) db.ConnectError!db.Connection {
    return connectImpl(gpa, io, params, err_out) catch |err| {
        // sslmode=prefer: fall back to plaintext when TLS cannot be established.
        if (err == error.ConnectFailed and params.ssl == .prefer and std.mem.startsWith(u8, err_out.slice(), "TLS handshake failed")) {
            var plain = params;
            plain.ssl = .disable;
            return connectImpl(gpa, io, plain, err_out);
        }
        return err;
    };
}

fn connectImpl(gpa: Allocator, io: Io, params: conninfo.Params, err_out: *db.ErrorText) db.ConnectError!db.Connection {
    const port = params.effectivePort();
    const host = if (params.host.len > 0) params.host else "localhost";
    const unix_path: ?[]const u8 = if (host[0] == '/')
        try std.fmt.allocPrint(gpa, "{s}/.s.PGSQL.{d}", .{ std.mem.trimEnd(u8, host, "/"), port })
    else
        null;
    var unowned_unix_path = unix_path;
    errdefer if (unowned_unix_path) |p| gpa.free(p);

    var diag: []const u8 = "";
    const t = Transport.connect(gpa, io, host, port, unix_path, &diag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ConnectFailed => {
            err_out.set(gpa, "cannot connect to {s}:{d}: {s}", .{ host, port, diag });
            return error.ConnectFailed;
        },
    };

    const self = gpa.create(Pg) catch {
        t.close();
        return error.OutOfMemory;
    };
    self.* = .{
        .gpa = gpa,
        .io = io,
        .t = t,
        .host = gpa.dupe(u8, host) catch {
            gpa.destroy(self);
            t.close();
            return error.OutOfMemory;
        },
        .port = port,
        .unix_path = unix_path,
    };
    unowned_unix_path = null;

    negotiateTlsImpl(self, params, host) catch |err| {
        switch (err) {
            error.OutOfMemory => {},
            else => err_out.set(gpa, "{s}", .{self.err.slice()}),
        }
        self.t.close();
        self.destroy();
        return if (err == error.OutOfMemory) error.OutOfMemory else error.ConnectFailed;
    };

    self.startup(params) catch |err| {
        switch (err) {
            error.OutOfMemory => {},
            error.AuthFailed, error.ServerError => err_out.set(gpa, "{s}", .{self.err.slice()}),
            else => err_out.set(gpa, "connection to {s}:{d} failed during startup: {t}", .{ host, port, err }),
        }
        self.t.close();
        self.destroy();
        return if (err == error.OutOfMemory) error.OutOfMemory else error.ConnectFailed;
    };

    return .{
        .ptr = self,
        .vtable = &Pg.vtable,
        .kind = .postgres,
        .server_version = self.server_version,
    };
}

fn negotiateTlsImpl(self: *Pg, params: conninfo.Params, host: []const u8) !void {
    if (params.ssl == .disable or self.unix_path != null) return;
    var req: [8]u8 = undefined;
    std.mem.writeInt(u32, req[0..4], 8, .big);
    std.mem.writeInt(u32, req[4..8], ssl_request_code, .big);
    try self.t.writer().writeAll(&req);
    try self.t.flush();
    switch (try self.t.reader().takeByte()) {
        'S' => {
            var diag: []const u8 = "";
            self.t.startTls(host, params.ssl, &diag) catch |err| {
                self.err.set(self.gpa, "TLS handshake failed: {s}", .{diag});
                return err;
            };
        },
        'N' => if (params.ssl.requiresTls()) {
            self.err.set(self.gpa, "server does not support SSL, but sslmode=require", .{});
            return error.TlsRequired;
        },
        else => {
            self.err.set(self.gpa, "unexpected answer to SSL request", .{});
            return error.ProtocolError;
        },
    }
}

test "scram matches RFC 7677 example" {
    const gpa = std.testing.allocator;
    var s: Scram = .{};
    s.setNonce("rOprNGfwEbeRWgbNEkqO");
    try std.testing.expectEqualStrings("n,,n=user,r=rOprNGfwEbeRWgbNEkqO", s.clientFirst("user"));
    const final = try s.clientFinal(gpa, "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096", "pencil");
    defer gpa.free(final);
    try std.testing.expectEqualStrings(
        "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=",
        final,
    );
    try std.testing.expect(s.verifyServer("v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4="));
}
