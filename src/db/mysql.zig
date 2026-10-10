//! MySQL / MariaDB driver: client/server protocol 4.1 over TCP or a Unix
//! socket, with TLS, mysql_native_password, caching_sha2_password (fast and
//! full auth, RSA when there is no TLS) and mysql_clear_password.
//! Queries use COM_QUERY, so values arrive in text form.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const db = @import("db.zig");
const conninfo = @import("../conninfo.zig");
const Transport = @import("net.zig").Transport;
const Sha1 = std.crypto.hash.Sha1;
const Sha256 = std.crypto.hash.sha2.Sha256;
const rsa = std.crypto.Certificate.rsa;
const der = std.crypto.Certificate.der;

const Cap = struct {
    const long_password: u32 = 1;
    const long_flag: u32 = 4;
    const connect_with_db: u32 = 8;
    const protocol_41: u32 = 0x200;
    const ssl: u32 = 0x800;
    const transactions: u32 = 0x2000;
    const secure_connection: u32 = 0x8000;
    const multi_statements: u32 = 0x10000;
    const multi_results: u32 = 0x20000;
    const plugin_auth: u32 = 0x80000;
    const plugin_auth_lenenc: u32 = 0x200000;
};

const server_more_results_exists: u16 = 0x0008;
const utf8mb4_general_ci: u8 = 45;
const max_packet: u32 = 16 * 1024 * 1024;
const max_logical_packet_size: usize = max_packet;

const Packet = struct {
    payload: []const u8,
};

const My = struct {
    gpa: Allocator,
    io: Io,
    t: *Transport,
    seq: u8 = 0,
    buf: std.ArrayList(u8) = .empty,
    err: db.ErrorText = .{},
    server_version: []const u8 = "",
    connection_id: u32 = 0,
    caps: u32 = 0,
    broken: bool = false,
    /// Kept to open a second connection for KILL QUERY.
    params: conninfo.Params,
    params_arena: std.heap.ArenaAllocator,

    const vtable: db.Connection.VTable = .{
        .query = query,
        .last_error = lastError,
        .cancel = cancel,
        .close = close,
    };

    const Error = error{ ReadFailed, WriteFailed, EndOfStream, StreamTooLong, ProtocolError } || Allocator.Error;

    // ───────────── packet I/O ─────────────

    /// Reads one logical packet (joining 16 MB continuation packets) into `buf`.
    fn readPacket(self: *My) Error![]const u8 {
        const r = self.t.reader();
        self.buf.clearRetainingCapacity();
        while (true) {
            const header = try r.takeArray(4);
            const len: usize = @as(usize, header[0]) | (@as(usize, header[1]) << 8) | (@as(usize, header[2]) << 16);
            self.seq = header[3] +% 1;
            const start = self.buf.items.len;
            const end = try checkedLogicalPacketEnd(start, len);
            try self.buf.resize(self.gpa, end);
            try r.readSliceAll(self.buf.items[start..]);
            if (len < 0xFFFFFF) break;
        }
        return self.buf.items;
    }

    fn writePacket(self: *My, payload: []const u8) Error!void {
        const w = self.t.writer();
        var rest = payload;
        while (true) {
            const chunk = rest[0..@min(rest.len, 0xFFFFFF)];
            const len: u32 = @intCast(chunk.len);
            try w.writeAll(&.{ @truncate(len), @truncate(len >> 8), @truncate(len >> 16), self.seq });
            self.seq +%= 1;
            try w.writeAll(chunk);
            rest = rest[chunk.len..];
            if (chunk.len < 0xFFFFFF) break;
        }
        try self.t.flush();
    }

    fn setServerError(self: *My, p: []const u8) void {
        // 0xFF, code(2), ['#', sqlstate(5)], message
        if (p.len < 3) {
            self.err.set(self.gpa, "ERROR: malformed error packet", .{});
            return;
        }
        const code = std.mem.readInt(u16, p[1..3], .little);
        var msg = p[3..];
        var state: []const u8 = "";
        if (msg.len >= 6 and msg[0] == '#') {
            state = msg[1..6];
            msg = msg[6..];
        }
        if (state.len > 0) {
            self.err.set(self.gpa, "ERROR {d} ({s}): {s}", .{ code, state, msg });
        } else {
            self.err.set(self.gpa, "ERROR {d}: {s}", .{ code, msg });
        }
    }

    // ───────────── handshake ─────────────

    fn handshake(self: *My, params: conninfo.Params, host: []const u8) (Error || error{ AuthFailed, ServerError, TlsFailed, TlsRequired })!void {
        const greeting = try self.readPacket();
        if (greeting.len > 0 and greeting[0] == 0xFF) {
            self.setServerError(greeting);
            return error.ServerError;
        }
        var r: Io.Reader = .fixed(greeting);
        const proto = try r.takeByte();
        if (proto != 10) {
            self.err.set(self.gpa, "unsupported protocol version {d}", .{proto});
            return error.ProtocolError;
        }
        const version = try r.takeDelimiterExclusive(0);
        r.toss(1);
        self.server_version = try self.gpa.dupe(u8, cleanVersion(version));
        self.connection_id = try r.takeInt(u32, .little);
        var nonce: [20]u8 = undefined;
        @memcpy(nonce[0..8], try r.take(8));
        r.toss(1);
        var server_caps: u32 = try r.takeInt(u16, .little);
        _ = try r.takeByte(); // charset
        _ = try r.takeInt(u16, .little); // status
        server_caps |= @as(u32, try r.takeInt(u16, .little)) << 16;
        const auth_data_len = try r.takeByte();
        try r.discardAll(10);
        var plugin: []const u8 = "mysql_native_password";
        if (server_caps & Cap.secure_connection != 0) {
            const part2_len: usize = @max(13, @as(usize, auth_data_len) -| 8);
            const part2 = try r.take(part2_len);
            @memcpy(nonce[8..20], part2[0..12]);
        }
        if (server_caps & Cap.plugin_auth != 0) {
            if (r.takeDelimiterExclusive(0)) |name| plugin = name else |_| {}
        }
        // `plugin` points into `buf`; copy before the next read.
        var plugin_buf: [64]u8 = undefined;
        const plugin_name = plugin_buf[0..@min(plugin.len, plugin_buf.len)];
        @memcpy(plugin_name, plugin[0..plugin_name.len]);

        var caps: u32 = Cap.long_password | Cap.long_flag | Cap.protocol_41 | Cap.transactions |
            Cap.secure_connection | Cap.multi_statements | Cap.multi_results | Cap.plugin_auth |
            Cap.plugin_auth_lenenc;
        if (params.database.len > 0) caps |= Cap.connect_with_db;
        caps &= server_caps | Cap.connect_with_db;

        const want_tls = params.ssl != .disable and self.t.isTls() == false and !isUnixHost(host);
        if (want_tls and server_caps & Cap.ssl != 0) {
            caps |= Cap.ssl;
            var req: [32]u8 = @splat(0);
            std.mem.writeInt(u32, req[0..4], caps, .little);
            std.mem.writeInt(u32, req[4..8], max_packet, .little);
            req[8] = utf8mb4_general_ci;
            try self.writePacket(&req);
            var diag: []const u8 = "";
            self.t.startTls(host, params.ssl, &diag) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.TlsFailed => {
                    self.err.set(self.gpa, "TLS handshake failed: {s}", .{diag});
                    return error.TlsFailed;
                },
            };
        } else if (params.ssl.requiresTls() and !isUnixHost(host)) {
            self.err.set(self.gpa, "server does not support TLS, but ssl mode is require", .{});
            return error.TlsRequired;
        }
        self.caps = caps;

        // HandshakeResponse41
        var resp: std.ArrayList(u8) = .empty;
        defer resp.deinit(self.gpa);
        var head: [32]u8 = @splat(0);
        std.mem.writeInt(u32, head[0..4], caps, .little);
        std.mem.writeInt(u32, head[4..8], max_packet, .little);
        head[8] = utf8mb4_general_ci;
        try resp.appendSlice(self.gpa, &head);
        try resp.appendSlice(self.gpa, params.user);
        try resp.append(self.gpa, 0);
        var auth_buf: [32]u8 = undefined;
        const auth = scramble(plugin_name, params.password, &nonce, &auth_buf);
        try appendLenenc(&resp, self.gpa, auth.len);
        try resp.appendSlice(self.gpa, auth);
        if (caps & Cap.connect_with_db != 0) {
            try resp.appendSlice(self.gpa, params.database);
            try resp.append(self.gpa, 0);
        }
        try resp.appendSlice(self.gpa, plugin_name);
        try resp.append(self.gpa, 0);
        try self.writePacket(resp.items);

        try self.authLoop(params.password, plugin_name, &nonce);
    }

    fn authLoop(self: *My, password: []const u8, initial_plugin: []const u8, initial_nonce: *const [20]u8) (Error || error{ AuthFailed, ServerError })!void {
        var plugin_buf: [64]u8 = undefined;
        var plugin: []const u8 = initial_plugin;
        var nonce: [20]u8 = initial_nonce.*;
        while (true) {
            const p = try self.readPacket();
            if (p.len == 0) return error.ProtocolError;
            switch (p[0]) {
                0x00 => return, // OK
                0xFF => {
                    self.setServerError(p);
                    return error.AuthFailed;
                },
                0xFE => { // auth switch request: plugin name, nonce
                    var r: Io.Reader = .fixed(p[1..]);
                    const name = r.takeDelimiterExclusive(0) catch return error.ProtocolError;
                    r.toss(1);
                    const data = r.buffered();
                    const n = @min(name.len, plugin_buf.len);
                    @memcpy(plugin_buf[0..n], name[0..n]);
                    plugin = plugin_buf[0..n];
                    const nd = std.mem.trimEnd(u8, data, "\x00");
                    @memset(&nonce, 0);
                    @memcpy(nonce[0..@min(nd.len, 20)], nd[0..@min(nd.len, 20)]);
                    var auth_buf: [32]u8 = undefined;
                    if (std.mem.eql(u8, plugin, "mysql_clear_password")) {
                        if (!self.t.isTls()) {
                            self.err.set(self.gpa, "authentication plugin 'mysql_clear_password' requires TLS", .{});
                            return error.AuthFailed;
                        }
                        const cleartext = try std.mem.concat(self.gpa, u8, &.{ password, "\x00" });
                        defer self.gpa.free(cleartext);
                        try self.writePacket(cleartext);
                    } else if (isKnownPlugin(plugin)) {
                        try self.writePacket(scramble(plugin, password, &nonce, &auth_buf));
                    } else {
                        self.err.set(self.gpa, "unsupported authentication plugin '{s}'", .{plugin});
                        return error.AuthFailed;
                    }
                },
                0x01 => { // AuthMoreData (caching_sha2_password)
                    if (p.len >= 2 and p[1] == 0x03) continue; // fast auth ok; OK packet follows
                    if (p.len >= 2 and p[1] == 0x04) {
                        // full authentication
                        if (self.t.isTls()) {
                            const cleartext = try std.mem.concat(self.gpa, u8, &.{ password, "\x00" });
                            defer self.gpa.free(cleartext);
                            try self.writePacket(cleartext);
                        } else {
                            try self.writePacket(&.{0x02}); // request public key
                            const key_packet = try self.readPacket();
                            if (key_packet.len < 2 or key_packet[0] != 0x01) return error.ProtocolError;
                            const pem = try self.gpa.dupe(u8, key_packet[1..]);
                            defer self.gpa.free(pem);
                            const encrypted = rsaEncryptPassword(self.gpa, self.io, pem, password, &nonce) catch |e| switch (e) {
                                error.OutOfMemory => return error.OutOfMemory,
                                else => {
                                    self.err.set(self.gpa, "cannot encrypt password with the server RSA key: {t}", .{e});
                                    return error.AuthFailed;
                                },
                            };
                            defer self.gpa.free(encrypted);
                            try self.writePacket(encrypted);
                        }
                        continue;
                    }
                    // Public key sent unrequested or other data: ignore.
                },
                else => return error.ProtocolError,
            }
        }
    }

    // ───────────── queries ─────────────

    fn query(ptr: *anyopaque, gpa: Allocator, sql: []const u8, opts: db.QueryOptions) db.QueryError!db.Result {
        const self: *My = @ptrCast(@alignCast(ptr));
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
                if (self.t.read_timed_out) {
                    self.err.set(self.gpa, "database response timed out after 300 s", .{});
                } else {
                    self.err.set(self.gpa, "connection lost: {t}", .{err});
                }
                return error.ConnectionLost;
            },
        };
    }

    fn runQuery(self: *My, gpa: Allocator, sql: []const u8, opts: db.QueryOptions) (Error || error{ QueryFailed, Canceled })!db.Result {
        self.seq = 0;
        const cmd = try self.gpa.alloc(u8, sql.len + 1);
        defer self.gpa.free(cmd);
        cmd[0] = 0x03; // COM_QUERY
        @memcpy(cmd[1..], sql);
        try self.writePacket(cmd);

        var b: db.ResultBuilder = .init(gpa);
        errdefer b.deinit();
        const a = b.allocator();
        var failure: ?error{ QueryFailed, Canceled } = null;

        // One iteration per result set (multi-statements / procedures).
        while (true) {
            const first = try self.readPacket();
            if (first.len == 0) return error.ProtocolError;
            var more = false;
            switch (first[0]) {
                0x00 => {
                    var r: Io.Reader = .fixed(first[1..]);
                    const affected = try readLenenc(&r);
                    _ = try readLenenc(&r); // last insert id
                    const status = try r.takeInt(u16, .little);
                    more = status & server_more_results_exists != 0;
                    if (b.result.columns.len == 0 or !more) {
                        // Keep the last row-returning result; report DML counts otherwise.
                        if (b.result.columns.len == 0) {
                            b.result.affected_rows = affected;
                            b.result.status = try std.fmt.allocPrint(a, "OK, {d} row{s} affected", .{ affected, if (affected == 1) "" else "s" });
                        }
                    }
                },
                0xFF => {
                    self.setServerError(first);
                    // 1317 = ER_QUERY_INTERRUPTED
                    failure = if (first.len >= 3 and std.mem.readInt(u16, first[1..3], .little) == 1317) error.Canceled else error.QueryFailed;
                },
                0xFB => {
                    // LOCAL INFILE request: refuse by sending an empty packet.
                    try self.writePacket(&.{});
                    continue;
                },
                else => {
                    var r: Io.Reader = .fixed(first);
                    const ncols: usize = @intCast(try readLenenc(&r));
                    const names = try a.alloc([]const u8, ncols);
                    for (names) |*name| {
                        const def = try self.readPacket();
                        name.* = try a.dupe(u8, try columnName(def));
                    }
                    try self.readEofIfPresent();
                    try b.setColumns(names);
                    b.result.truncated = false;
                    b.result.affected_rows = null;
                    // rows
                    while (true) {
                        const p = try self.readPacket();
                        if (p.len > 0 and p[0] == 0xFE and p.len < 9) {
                            var er: Io.Reader = .fixed(p[1..]);
                            _ = try er.takeInt(u16, .little); // warnings
                            const status = try er.takeInt(u16, .little);
                            more = status & server_more_results_exists != 0;
                            break;
                        }
                        if (p.len > 0 and p[0] == 0xFF) {
                            self.setServerError(p);
                            failure = if (p.len >= 3 and std.mem.readInt(u16, p[1..3], .little) == 1317) error.Canceled else error.QueryFailed;
                            break;
                        }
                        if (b.full(opts)) {
                            b.result.truncated = true;
                            continue;
                        }
                        var rr: Io.Reader = .fixed(p);
                        const row = try a.alloc(?[]const u8, ncols);
                        for (row) |*cell| {
                            const lead = try rr.peekByte();
                            if (lead == 0xFB) {
                                rr.toss(1);
                                cell.* = null;
                            } else {
                                const len: usize = @intCast(try readLenenc(&rr));
                                cell.* = try a.dupe(u8, try rr.take(len));
                            }
                        }
                        try b.addRow(row, opts);
                    }
                    const n = b.rows.items.len;
                    b.result.status = try std.fmt.allocPrint(a, "{d}{s} row{s}", .{ n, if (b.result.truncated) "+" else "", if (n == 1) "" else "s" });
                },
            }
            if (!more or failure != null) break;
        }
        if (failure) |f| return f;
        return b.finish();
    }

    /// Without CLIENT_DEPRECATE_EOF an EOF packet follows column definitions.
    fn readEofIfPresent(self: *My) Error!void {
        const p = try self.readPacket();
        if (p.len > 0 and p[0] == 0xFE and p.len < 9) return;
        return error.ProtocolError;
    }

    fn cancel(ptr: *anyopaque) void {
        const self: *My = @ptrCast(@alignCast(ptr));
        var err: db.ErrorText = .{};
        defer err.deinit(self.gpa);
        const other = connectImpl(self.gpa, self.io, self.params, &err) catch return;
        defer other.close();
        var buf: [32]u8 = undefined;
        const sql = std.fmt.bufPrint(&buf, "KILL QUERY {d}", .{self.connection_id}) catch return;
        var r = other.query(self.gpa, sql) catch return;
        r.deinit();
    }

    fn lastError(ptr: *anyopaque) []const u8 {
        const self: *My = @ptrCast(@alignCast(ptr));
        return self.err.slice();
    }

    fn close(ptr: *anyopaque) void {
        const self: *My = @ptrCast(@alignCast(ptr));
        if (!self.broken) {
            self.seq = 0;
            self.writePacket(&.{0x01}) catch {}; // COM_QUIT
        }
        self.t.close();
        self.destroy();
    }

    fn destroy(self: *My) void {
        self.err.deinit(self.gpa);
        self.buf.deinit(self.gpa);
        if (self.server_version.len > 0) self.gpa.free(self.server_version);
        self.params_arena.deinit();
        self.gpa.destroy(self);
    }
};

fn checkedLogicalPacketEnd(start: usize, len: usize) error{StreamTooLong}!usize {
    if (start > max_logical_packet_size or len > max_logical_packet_size - start) return error.StreamTooLong;
    return start + len;
}

test "mysql logical packet size is bounded" {
    try std.testing.expectEqual(max_logical_packet_size, try checkedLogicalPacketEnd(1, max_logical_packet_size - 1));
    try std.testing.expectError(error.StreamTooLong, checkedLogicalPacketEnd(1, max_logical_packet_size));
}

fn isUnixHost(host: []const u8) bool {
    return host.len > 0 and host[0] == '/';
}

/// "5.5.5-11.4.2-MariaDB-log" -> "11.4.2-MariaDB-log"
fn cleanVersion(v: []const u8) []const u8 {
    if (std.mem.startsWith(u8, v, "5.5.5-")) return v[6..];
    return v;
}

fn isKnownPlugin(name: []const u8) bool {
    return std.mem.eql(u8, name, "mysql_native_password") or std.mem.eql(u8, name, "caching_sha2_password");
}

/// Computes the auth response for a plugin. Empty passwords send nothing.
fn scramble(plugin: []const u8, password: []const u8, nonce: *const [20]u8, out: *[32]u8) []const u8 {
    if (password.len == 0) return out[0..0];
    if (std.mem.eql(u8, plugin, "caching_sha2_password")) {
        // XOR(SHA256(pw), SHA256(SHA256(SHA256(pw)) + nonce))
        var h1: [32]u8 = undefined;
        Sha256.hash(password, &h1, .{});
        var h2: [32]u8 = undefined;
        Sha256.hash(&h1, &h2, .{});
        var h3: [32]u8 = undefined;
        var s = Sha256.init(.{});
        s.update(&h2);
        s.update(nonce);
        s.final(&h3);
        for (out, h1, h3) |*o, x, y| o.* = x ^ y;
        return out[0..32];
    }
    // mysql_native_password: XOR(SHA1(pw), SHA1(nonce + SHA1(SHA1(pw))))
    var h1: [20]u8 = undefined;
    Sha1.hash(password, &h1, .{});
    var h2: [20]u8 = undefined;
    Sha1.hash(&h1, &h2, .{});
    var h3: [20]u8 = undefined;
    var s = Sha1.init(.{});
    s.update(nonce);
    s.update(&h2);
    s.final(&h3);
    for (out[0..20], h1, h3) |*o, x, y| o.* = x ^ y;
    return out[0..20];
}

/// RSA-OAEP (SHA-1) encryption of `password\0` XOR nonce, as expected by
/// caching_sha2_password full authentication without TLS.
fn rsaEncryptPassword(gpa: Allocator, io: Io, pem: []const u8, password: []const u8, nonce: *const [20]u8) ![]u8 {
    // PEM -> DER (SubjectPublicKeyInfo)
    const begin = "-----BEGIN PUBLIC KEY-----";
    const end_marker = "-----END PUBLIC KEY-----";
    const b = std.mem.indexOf(u8, pem, begin) orelse return error.InvalidKey;
    const e = std.mem.indexOfPos(u8, pem, b, end_marker) orelse return error.InvalidKey;
    var b64: std.ArrayList(u8) = .empty;
    defer b64.deinit(gpa);
    for (pem[b + begin.len .. e]) |c| if (!std.ascii.isWhitespace(c)) try b64.append(gpa, c);
    const der_len = try std.base64.standard.Decoder.calcSizeForSlice(b64.items);
    const spki = try gpa.alloc(u8, der_len);
    defer gpa.free(spki);
    try std.base64.standard.Decoder.decode(spki, b64.items);

    // SEQUENCE { SEQUENCE { algorithm }, BIT STRING { RSAPublicKey } }
    const outer = try der.Element.parse(spki, 0);
    const algo = try der.Element.parse(spki, outer.slice.start);
    const bits = try der.Element.parse(spki, algo.slice.end);
    if (bits.identifier.tag != .bitstring) return error.InvalidKey;
    const rsa_der = spki[bits.slice.start + 1 .. bits.slice.end]; // skip unused-bits byte
    const parts = try rsa.PublicKey.parseDer(rsa_der);
    const key = try rsa.PublicKey.fromBytes(parts.exponent, parts.modulus);
    const k = parts.modulus.len;

    // message = (password + "\0") XOR nonce (repeated)
    const msg = try gpa.alloc(u8, password.len + 1);
    defer gpa.free(msg);
    @memcpy(msg[0..password.len], password);
    msg[password.len] = 0;
    for (msg, 0..) |*m, i| m.* ^= nonce[i % nonce.len];

    const h_len = Sha1.digest_length;
    if (msg.len > k - 2 * h_len - 2) return error.PasswordTooLong;

    // EME-OAEP encoding (RFC 8017 7.1.1) with empty label
    const em = try gpa.alloc(u8, k);
    defer gpa.free(em);
    @memset(em, 0);
    const seed = em[1 .. 1 + h_len];
    const db_block = em[1 + h_len ..];
    Sha1.hash("", db_block[0..h_len], .{});
    db_block[db_block.len - msg.len - 1] = 0x01;
    @memcpy(db_block[db_block.len - msg.len ..], msg);
    io.random(seed);
    mgf1Xor(db_block, seed);
    mgf1Xor(seed, db_block);

    const Fe = @TypeOf(key.n).Fe;
    const m = try Fe.fromBytes(key.n, em, .big);
    const c = try key.n.powPublic(m, key.e);
    const out = try gpa.alloc(u8, k);
    try c.toBytes(out, .big);
    return out;
}

/// target ^= MGF1-SHA1(seed, target.len)
fn mgf1Xor(target: []u8, seed: []const u8) void {
    var counter: u32 = 0;
    var off: usize = 0;
    while (off < target.len) : (counter += 1) {
        var h = Sha1.init(.{});
        h.update(seed);
        var cbuf: [4]u8 = undefined;
        std.mem.writeInt(u32, &cbuf, counter, .big);
        h.update(&cbuf);
        var digest: [Sha1.digest_length]u8 = undefined;
        h.final(&digest);
        const n = @min(digest.len, target.len - off);
        for (target[off .. off + n], digest[0..n]) |*t, d| t.* ^= d;
        off += n;
    }
}

fn readLenenc(r: *Io.Reader) !u64 {
    const first = try r.takeByte();
    return switch (first) {
        0xFC => try r.takeInt(u16, .little),
        0xFD => try r.takeInt(u24, .little),
        0xFE => try r.takeInt(u64, .little),
        else => first,
    };
}

fn appendLenenc(list: *std.ArrayList(u8), gpa: Allocator, n: usize) Allocator.Error!void {
    if (n < 0xFB) {
        try list.append(gpa, @intCast(n));
    } else if (n <= 0xFFFF) {
        try list.append(gpa, 0xFC);
        try list.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u16, @intCast(n))));
    } else if (n <= 0xFFFFFF) {
        try list.append(gpa, 0xFD);
        const v: u32 = @intCast(n);
        try list.appendSlice(gpa, &.{ @truncate(v), @truncate(v >> 8), @truncate(v >> 16) });
    } else {
        try list.append(gpa, 0xFE);
        try list.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u64, n)));
    }
}

/// ColumnDefinition41: catalog, schema, table, org_table, name, ...
fn columnName(def: []const u8) ![]const u8 {
    var r: Io.Reader = .fixed(def);
    var name: []const u8 = "";
    for (0..5) |i| {
        const len: usize = @intCast(try readLenenc(&r));
        const s = try r.take(len);
        if (i == 4) name = s;
    }
    return name;
}

fn connectImpl(gpa: Allocator, io: Io, params: conninfo.Params, err_out: *db.ErrorText) db.ConnectError!db.Connection {
    const host = if (params.host.len > 0) params.host else "localhost";
    const port = params.effectivePort();
    var diag: []const u8 = "";
    const t = Transport.connect(gpa, io, host, port, if (isUnixHost(host)) host else null, &diag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ConnectFailed => {
            err_out.set(gpa, "cannot connect to {s}:{d}: {s}", .{ host, port, diag });
            return error.ConnectFailed;
        },
    };

    const self = gpa.create(My) catch {
        t.close();
        return error.OutOfMemory;
    };
    self.* = .{ .gpa = gpa, .io = io, .t = t, .params = params, .params_arena = .init(gpa) };
    // Own a copy of the parameters for cancel connections.
    const pa = self.params_arena.allocator();
    const copied: ?conninfo.Params = blk: {
        var p = params;
        p.host = pa.dupe(u8, params.host) catch break :blk null;
        p.user = pa.dupe(u8, params.user) catch break :blk null;
        p.password = pa.dupe(u8, params.password) catch break :blk null;
        p.database = pa.dupe(u8, params.database) catch break :blk null;
        break :blk p;
    };
    if (copied) |p| self.params = p else {
        self.t.close();
        self.destroy();
        return error.OutOfMemory;
    }

    self.handshake(params, host) catch |err| {
        switch (err) {
            error.OutOfMemory => {},
            error.AuthFailed, error.ServerError, error.TlsFailed, error.TlsRequired => err_out.set(gpa, "{s}", .{self.err.slice()}),
            else => if (self.t.read_timed_out)
                err_out.set(gpa, "database response timed out after 300 s during handshake", .{})
            else
                err_out.set(gpa, "connection to {s}:{d} failed during handshake: {t}", .{ host, port, err }),
        }
        self.t.close();
        self.destroy();
        return if (err == error.OutOfMemory) error.OutOfMemory else error.ConnectFailed;
    };

    // Cancel connections must not retry a TLS handshake that already failed.
    if (!self.t.isTls()) self.params.ssl = .disable else if (self.params.ssl == .prefer) self.params.ssl = .require;

    return .{
        .ptr = self,
        .vtable = &My.vtable,
        .kind = .mysql,
        .server_version = self.server_version,
    };
}

pub fn connect(gpa: Allocator, io: Io, params: conninfo.Params, err_out: *db.ErrorText) db.ConnectError!db.Connection {
    return connectImpl(gpa, io, params, err_out) catch |err| {
        // sslmode=prefer: fall back to plaintext when TLS cannot be established.
        // (Zig's TLS client rejects servers that request a client certificate,
        // which MariaDB 11.4+ does by default.)
        if (err == error.ConnectFailed and params.ssl == .prefer and std.mem.startsWith(u8, err_out.slice(), "TLS handshake failed")) {
            var plain = params;
            plain.ssl = .disable;
            return connectImpl(gpa, io, plain, err_out);
        }
        return err;
    };
}

test "native password scramble" {
    // Known answer computed with the reference algorithm.
    const nonce: [20]u8 = "abcdefghijklmnopqrst".*;
    var out: [32]u8 = undefined;
    const got = scramble("mysql_native_password", "secret", &nonce, &out);
    try std.testing.expectEqual(@as(usize, 20), got.len);
    // Independent check: SHA1(pw) == got XOR SHA1(nonce + SHA1(SHA1(pw)))
    var h1: [20]u8 = undefined;
    Sha1.hash("secret", &h1, .{});
    var h2: [20]u8 = undefined;
    Sha1.hash(&h1, &h2, .{});
    var h3: [20]u8 = undefined;
    var s = Sha1.init(.{});
    s.update(&nonce);
    s.update(&h2);
    s.final(&h3);
    for (got, h3, h1) |g, x, want| try std.testing.expectEqual(want, g ^ x);
}

test "lenenc" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(std.testing.allocator);
    for ([_]usize{ 5, 300, 70000, 20_000_000 }) |n| {
        list.clearRetainingCapacity();
        try appendLenenc(&list, std.testing.allocator, n);
        var r: Io.Reader = .fixed(list.items);
        try std.testing.expectEqual(@as(u64, n), try readLenenc(&r));
    }
}
