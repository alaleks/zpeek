//! Connection parameters and parsing of connection strings.
//!
//! Supported forms:
//!   postgres://user:pass@host:5432/db?sslmode=disable   (also postgresql://)
//!   mysql://user:pass@host:3306/db                      (also mariadb://)
//!   user:pass@tcp(host:3306)/db                         (Go-style MySQL DSN)
//!   host=localhost port=5432 user=me dbname=app         (libpq keyword/value)
//!   sqlite:///abs/path.db, sqlite://rel.db, sqlite::memory:
//!   ./file.db, /abs/file.sqlite3                        (bare SQLite paths)

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Kind = enum {
    postgres,
    mysql,
    sqlite,

    pub fn defaultPort(kind: Kind) u16 {
        return switch (kind) {
            .postgres => 5432,
            .mysql => 3306,
            .sqlite => 0,
        };
    }

    pub fn label(kind: Kind) []const u8 {
        return switch (kind) {
            .postgres => "PostgreSQL",
            .mysql => "MySQL/MariaDB",
            .sqlite => "SQLite",
        };
    }

    /// Accepts driver names as they appear in configs and URL schemes.
    pub fn fromName(name: []const u8) ?Kind {
        const map = std.StaticStringMap(Kind).initComptime(.{
            .{ "postgres", .postgres },
            .{ "postgresql", .postgres },
            .{ "pg", .postgres },
            .{ "mysql", .mysql },
            .{ "mariadb", .mysql },
            .{ "sqlite", .sqlite },
            .{ "sqlite3", .sqlite },
        });
        return map.get(name);
    }
};

pub const SslMode = enum {
    disable,
    prefer,
    require,
    verify_ca,
    verify_full,

    pub fn requiresTls(mode: SslMode) bool {
        return mode == .require or mode == .verify_ca or mode == .verify_full;
    }

    pub fn fromName(name: []const u8) ?SslMode {
        const map = std.StaticStringMap(SslMode).initComptime(.{
            .{ "disable", .disable },
            .{ "allow", .prefer },
            .{ "prefer", .prefer },
            .{ "require", .require },
            .{ "verify-ca", .verify_ca },
            .{ "verify-full", .verify_full },
            // MySQL spellings
            .{ "false", .disable },
            .{ "true", .require },
            .{ "preferred", .prefer },
            .{ "required", .require },
            .{ "disabled", .disable },
        });
        return map.get(name);
    }
};

pub const Params = struct {
    kind: Kind,
    host: []const u8 = "localhost",
    port: u16 = 0,
    user: []const u8 = "",
    password: []const u8 = "",
    /// Database name, or the file path for SQLite.
    database: []const u8 = "",
    ssl: SslMode = .prefer,

    pub fn effectivePort(p: Params) u16 {
        return if (p.port != 0) p.port else p.kind.defaultPort();
    }

    /// Short human readable description without the password.
    pub fn describe(p: Params, buf: []u8) []const u8 {
        return switch (p.kind) {
            .sqlite => std.fmt.bufPrint(buf, "sqlite {s}", .{p.database}) catch p.database,
            else => std.fmt.bufPrint(buf, "{s}@{s}:{d}/{s}", .{
                p.user, p.host, p.effectivePort(), p.database,
            }) catch p.host,
        };
    }
};

/// Fills an empty password from $PGPASSWORD (PostgreSQL) or $MYSQL_PWD (MySQL),
/// like the official clients do.
pub fn passwordFromEnv(p: *Params, env: *const std.process.Environ.Map) void {
    if (p.password.len > 0) return;
    const name: []const u8 = switch (p.kind) {
        .postgres => "PGPASSWORD",
        .mysql => "MYSQL_PWD",
        .sqlite => return,
    };
    if (env.get(name)) |v| p.password = v;
}

pub const ParseError = error{ InvalidConnectionString, UnknownScheme, InvalidPort, InvalidSslMode } || Allocator.Error;

/// Human readable explanation of a parse error.
pub fn errorText(err: ParseError) []const u8 {
    return switch (err) {
        error.InvalidConnectionString => "malformed connection string",
        error.UnknownScheme => "unknown scheme (expected postgres://, postgresql://, mysql://, mariadb:// or sqlite://)",
        error.InvalidPort => "invalid port",
        error.InvalidSslMode => "invalid sslmode (expected disable, prefer, require, verify-ca or verify-full)",
        error.OutOfMemory => "out of memory",
    };
}

/// Strips whitespace and quotes left over from copy-pasting, e.g.
/// `"postgres://…"` or a stray trailing `"`. Quotes are never valid
/// unescaped at either end of a URL.
fn stripPasted(s: []const u8) []const u8 {
    var t = std.mem.trim(u8, s, " \t\r\n");
    if (t.len >= 2 and (t[0] == '"' or t[0] == '\'') and t[t.len - 1] == t[0]) t = t[1 .. t.len - 1];
    if (std.mem.indexOf(u8, t, "://") != null) t = std.mem.trim(u8, t, "\"'` ");
    return t;
}

const sqlite_extensions = [_][]const u8{ ".db", ".sqlite", ".sqlite3", ".db3" };

pub fn looksLikeSqlitePath(s: []const u8) bool {
    for (sqlite_extensions) |ext| {
        if (std.ascii.endsWithIgnoreCase(s, ext)) return true;
    }
    return std.mem.eql(u8, s, ":memory:");
}

/// Returns true if `s` is something `parse` can understand (as opposed to a
/// connection name from the config file).
pub fn isConnectionString(s: []const u8) bool {
    if (std.mem.indexOf(u8, s, "://") != null) return true;
    if (std.mem.startsWith(u8, s, "sqlite:")) return true;
    if (std.mem.indexOf(u8, s, "@tcp(") != null) return true;
    if (std.mem.indexOfScalar(u8, s, '=') != null) return true;
    if (std.mem.indexOfScalar(u8, s, '/') != null) return true;
    return looksLikeSqlitePath(s);
}

/// Parses a connection string. All returned slices are allocated in `arena`.
pub fn parse(arena: Allocator, s: []const u8) ParseError!Params {
    const input = stripPasted(s);
    if (input.len == 0) return error.InvalidConnectionString;

    if (std.mem.startsWith(u8, input, "sqlite:")) {
        var path = input["sqlite:".len..];
        if (std.mem.startsWith(u8, path, "//")) path = path[2..];
        if (path.len == 0) return error.InvalidConnectionString;
        return .{ .kind = .sqlite, .database = try percentDecode(arena, path) };
    }

    if (std.mem.indexOf(u8, input, "://")) |sep| {
        const kind = Kind.fromName(input[0..sep]) orelse return error.UnknownScheme;
        if (kind == .sqlite) unreachable; // handled above
        return parseUrl(arena, kind, input[sep + 3 ..]);
    }

    if (std.mem.indexOf(u8, input, "@tcp(") != null) return parseGoDsn(arena, input);

    if (std.mem.indexOfScalar(u8, input, '=') != null) return parseKeywordValue(arena, input);

    return .{ .kind = .sqlite, .database = try arena.dupe(u8, input) };
}

fn parseUrl(arena: Allocator, kind: Kind, rest_in: []const u8) ParseError!Params {
    var p: Params = .{ .kind = kind };
    var rest = rest_in;

    if (std.mem.indexOfScalar(u8, rest, '?')) |q| {
        try applyQuery(arena, &p, rest[q + 1 ..]);
        rest = rest[0..q];
    }

    var hostport = rest;
    if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
        hostport = rest[0..slash];
        p.database = try percentDecode(arena, rest[slash + 1 ..]);
    }

    if (std.mem.lastIndexOfScalar(u8, hostport, '@')) |at| {
        const userinfo = hostport[0..at];
        hostport = hostport[at + 1 ..];
        if (std.mem.indexOfScalar(u8, userinfo, ':')) |colon| {
            p.user = try percentDecode(arena, userinfo[0..colon]);
            p.password = try percentDecode(arena, userinfo[colon + 1 ..]);
        } else {
            p.user = try percentDecode(arena, userinfo);
        }
    }

    try parseHostPort(arena, &p, hostport);
    return p;
}

fn parseHostPort(arena: Allocator, p: *Params, hostport: []const u8) ParseError!void {
    if (hostport.len == 0) return;
    // [ipv6]:port
    if (hostport[0] == '[') {
        const close = std.mem.indexOfScalar(u8, hostport, ']') orelse return error.InvalidConnectionString;
        p.host = try arena.dupe(u8, hostport[1..close]);
        const after = hostport[close + 1 ..];
        if (after.len > 0) {
            if (after[0] != ':') return error.InvalidConnectionString;
            p.port = std.fmt.parseInt(u16, after[1..], 10) catch return error.InvalidPort;
        }
        return;
    }
    if (std.mem.lastIndexOfScalar(u8, hostport, ':')) |colon| {
        p.host = try percentDecode(arena, hostport[0..colon]);
        p.port = std.fmt.parseInt(u16, hostport[colon + 1 ..], 10) catch return error.InvalidPort;
    } else {
        p.host = try percentDecode(arena, hostport);
    }
    if (p.host.len == 0) p.host = "localhost";
}

fn applyQuery(arena: Allocator, p: *Params, query: []const u8) ParseError!void {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const key = pair[0..eq];
        const value = try percentDecode(arena, pair[eq + 1 ..]);
        try applyKey(p, key, value);
    }
}

/// Applies one `key=value` option shared by the URL query and keyword forms.
fn applyKey(p: *Params, key: []const u8, value: []const u8) ParseError!void {
    const eql = std.mem.eql;
    if (eql(u8, key, "sslmode") or eql(u8, key, "ssl-mode") or eql(u8, key, "tls") or eql(u8, key, "ssl")) {
        p.ssl = SslMode.fromName(value) orelse return error.InvalidSslMode;
    } else if (eql(u8, key, "host")) {
        p.host = value;
    } else if (eql(u8, key, "port")) {
        p.port = std.fmt.parseInt(u16, value, 10) catch return error.InvalidPort;
    } else if (eql(u8, key, "user")) {
        p.user = value;
    } else if (eql(u8, key, "password")) {
        p.password = value;
    } else if (eql(u8, key, "dbname") or eql(u8, key, "database")) {
        p.database = value;
    }
    // Unknown options are ignored on purpose: connection strings copied from
    // other tools often carry options we don't need.
}

/// libpq style: `host=localhost port=5432 dbname=app user=me password='a b'`
fn parseKeywordValue(arena: Allocator, s: []const u8) ParseError!Params {
    var p: Params = .{ .kind = .postgres };
    var i: usize = 0;
    while (i < s.len) {
        while (i < s.len and std.ascii.isWhitespace(s[i])) i += 1;
        if (i >= s.len) break;
        const key_start = i;
        while (i < s.len and s[i] != '=' and !std.ascii.isWhitespace(s[i])) i += 1;
        const key = s[key_start..i];
        while (i < s.len and std.ascii.isWhitespace(s[i])) i += 1;
        if (i >= s.len or s[i] != '=') return error.InvalidConnectionString;
        i += 1;
        while (i < s.len and std.ascii.isWhitespace(s[i])) i += 1;

        var value: std.ArrayList(u8) = .empty;
        if (i < s.len and s[i] == '\'') {
            i += 1;
            while (i < s.len and s[i] != '\'') : (i += 1) {
                if (s[i] == '\\' and i + 1 < s.len) i += 1;
                try value.append(arena, s[i]);
            }
            if (i >= s.len) return error.InvalidConnectionString;
            i += 1;
        } else {
            while (i < s.len and !std.ascii.isWhitespace(s[i])) : (i += 1) {
                try value.append(arena, s[i]);
            }
        }
        if (std.mem.eql(u8, key, "driver")) {
            p.kind = Kind.fromName(value.items) orelse return error.UnknownScheme;
        } else {
            try applyKey(&p, key, value.items);
        }
    }
    return p;
}

/// Go MySQL driver style: `user:pass@tcp(host:3306)/db?tls=true`
fn parseGoDsn(arena: Allocator, s: []const u8) ParseError!Params {
    var p: Params = .{ .kind = .mysql };
    const at = std.mem.indexOf(u8, s, "@tcp(").?;
    const userinfo = s[0..at];
    if (std.mem.indexOfScalar(u8, userinfo, ':')) |colon| {
        p.user = try arena.dupe(u8, userinfo[0..colon]);
        p.password = try arena.dupe(u8, userinfo[colon + 1 ..]);
    } else {
        p.user = try arena.dupe(u8, userinfo);
    }
    const rest = s[at + "@tcp(".len ..];
    const close = std.mem.indexOfScalar(u8, rest, ')') orelse return error.InvalidConnectionString;
    try parseHostPort(arena, &p, rest[0..close]);
    var tail = rest[close + 1 ..];
    if (std.mem.indexOfScalar(u8, tail, '?')) |q| {
        try applyQuery(arena, &p, tail[q + 1 ..]);
        tail = tail[0..q];
    }
    if (std.mem.startsWith(u8, tail, "/")) p.database = try arena.dupe(u8, tail[1..]);
    return p;
}

fn percentDecode(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '%') == null) return arena.dupe(u8, s);
    var out = try arena.alloc(u8, s.len);
    var o: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '%' and i + 2 < s.len) {
            if (std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16)) |b| {
                out[o] = b;
                o += 1;
                i += 2;
                continue;
            } else |_| {}
        }
        out[o] = s[i];
        o += 1;
    }
    return out[0..o];
}

const testing = std.testing;

test "postgres url" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const p = try parse(arena.allocator(), "postgresql://bob:p%40ss@db.local:6543/shop?sslmode=disable");
    try testing.expectEqual(Kind.postgres, p.kind);
    try testing.expectEqualStrings("bob", p.user);
    try testing.expectEqualStrings("p@ss", p.password);
    try testing.expectEqualStrings("db.local", p.host);
    try testing.expectEqual(@as(u16, 6543), p.port);
    try testing.expectEqualStrings("shop", p.database);
    try testing.expectEqual(SslMode.disable, p.ssl);
}

test "mysql url defaults" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const p = try parse(arena.allocator(), "mariadb://root@localhost/app");
    try testing.expectEqual(Kind.mysql, p.kind);
    try testing.expectEqualStrings("root", p.user);
    try testing.expectEqualStrings("", p.password);
    try testing.expectEqual(@as(u16, 3306), p.effectivePort());
}

test "go dsn" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const p = try parse(arena.allocator(), "u:pw@tcp(10.0.0.1:3307)/db?tls=true");
    try testing.expectEqual(Kind.mysql, p.kind);
    try testing.expectEqualStrings("10.0.0.1", p.host);
    try testing.expectEqual(@as(u16, 3307), p.port);
    try testing.expectEqualStrings("db", p.database);
    try testing.expectEqual(SslMode.require, p.ssl);
}

test "keyword value" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const p = try parse(arena.allocator(), "host=h port=5433 dbname=d user=u password='a b'");
    try testing.expectEqual(Kind.postgres, p.kind);
    try testing.expectEqualStrings("h", p.host);
    try testing.expectEqual(@as(u16, 5433), p.port);
    try testing.expectEqualStrings("a b", p.password);
}

test "sqlite forms" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("/tmp/x.db", (try parse(a, "sqlite:///tmp/x.db")).database);
    try testing.expectEqualStrings("rel.db", (try parse(a, "sqlite://rel.db")).database);
    try testing.expectEqualStrings(":memory:", (try parse(a, "sqlite::memory:")).database);
    const p = try parse(a, "./data/app.sqlite3");
    try testing.expectEqual(Kind.sqlite, p.kind);
    try testing.expect(isConnectionString("app.db"));
    try testing.expect(!isConnectionString("prod"));
}

test "pasted quotes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try parse(a, "postgres://postgres:pw@localhost:6432/db?sslmode=disable\"");
    try testing.expectEqual(SslMode.disable, p.ssl);
    try testing.expectEqualStrings("db", p.database);
    try testing.expectEqualStrings("x", (try parse(a, "'mysql://u@h/x'")).database);
    try testing.expectError(error.InvalidSslMode, parse(a, "postgres://h/db?sslmode=nope"));
}

test "ipv6 host" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const p = try parse(arena.allocator(), "postgres://u@[::1]:5432/d");
    try testing.expectEqualStrings("::1", p.host);
}

test "connection string detection accepts one libpq parameter" {
    try testing.expect(isConnectionString("dbname=app"));
    try testing.expect(isConnectionString("host=localhost"));
}
