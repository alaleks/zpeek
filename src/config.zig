//! Loads `config.toml` with named connections.
//!
//! ```toml
//! default = "local"
//!
//! [connections.local]
//! url = "postgres://me@localhost/app"
//! color = "#2F6B43"                # optional database badge color
//!
//! [connections.shop]
//! driver = "mysql"                 # postgres | mysql | mariadb | sqlite | clickhouse
//! host = "127.0.0.1"
//! port = 3306
//! user = "root"
//! password_env = "SHOP_PASSWORD"   # or: password = "..."
//! database = "shop"
//!
//! [connections.notes]
//! path = "~/notes.db"              # SQLite
//! ```
//!
//! Location: $ZPEEK_CONFIG, else $XDG_CONFIG_HOME/zpeek/config.toml, else
//! ~/.config/zpeek/config.toml, else (Windows) %APPDATA%\zpeek\config.toml.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const toml = @import("toml.zig");
const conninfo = @import("conninfo.zig");

pub const Entry = struct {
    name: []const u8,
    params: conninfo.Params,
    color: ?Color = null,
};

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,

    /// Nearest color in the portable 6×6×6 ANSI terminal palette.
    pub fn ansi256(c: Color) u8 {
        const r: u8 = @intCast((@as(u16, c.r) * 5 + 127) / 255);
        const g: u8 = @intCast((@as(u16, c.g) * 5 + 127) / 255);
        const b: u8 = @intCast((@as(u16, c.b) * 5 + 127) / 255);
        return 16 + 36 * r + 6 * g + b;
    }
};

pub const Config = struct {
    /// Path the config was loaded from (or would be loaded from).
    path: []const u8,
    /// False when no config file exists.
    found: bool,
    default: ?[]const u8 = null,
    connections: []const Entry = &.{},

    pub fn find(cfg: Config, name: []const u8) ?Entry {
        for (cfg.connections) |e| {
            if (std.mem.eql(u8, e.name, name)) return e;
        }
        return null;
    }
};

pub const Diagnostic = struct {
    message: []const u8 = "",
};

pub const LoadError = error{ InvalidConfig, ReadFailed } || Allocator.Error;

pub fn defaultPath(arena: Allocator, env: *const std.process.Environ.Map) Allocator.Error!?[]const u8 {
    if (env.get("ZPEEK_CONFIG")) |p| return try arena.dupe(u8, p);
    if (env.get("XDG_CONFIG_HOME")) |x| {
        if (x.len > 0) return try std.fs.path.join(arena, &.{ x, "zpeek", "config.toml" });
    }
    if (env.get("HOME")) |home| return try std.fs.path.join(arena, &.{ home, ".config", "zpeek", "config.toml" });
    // Windows outside of Git Bash/MSYS has no HOME.
    if (env.get("APPDATA")) |appdata| return try std.fs.path.join(arena, &.{ appdata, "zpeek", "config.toml" });
    return null;
}

/// The user's home directory: $HOME, or %USERPROFILE% on Windows.
pub fn homeDir(env: *const std.process.Environ.Map) ?[]const u8 {
    return env.get("HOME") orelse env.get("USERPROFILE");
}

/// Loads the config. A missing file yields an empty config with `found = false`.
pub fn load(
    arena: Allocator,
    io: Io,
    env: *const std.process.Environ.Map,
    path_override: ?[]const u8,
    diag: *Diagnostic,
) LoadError!Config {
    const path = path_override orelse (try defaultPath(arena, env)) orelse
        return .{ .path = "", .found = false };

    const src = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return .{ .path = path, .found = false },
        else => {
            diag.message = try std.fmt.allocPrint(arena, "{s}: {t}", .{ path, err });
            return error.ReadFailed;
        },
    };
    return parse(arena, env, path, src, diag);
}

pub fn parse(
    arena: Allocator,
    env: *const std.process.Environ.Map,
    path: []const u8,
    src: []const u8,
    diag: *Diagnostic,
) LoadError!Config {
    var tdiag: toml.Diagnostic = .{};
    const root = toml.parse(arena, src, &tdiag) catch |err| switch (err) {
        error.SyntaxError => {
            diag.message = try std.fmt.allocPrint(arena, "{s}:{d}: {s}", .{ path, tdiag.line, tdiag.message });
            return error.InvalidConfig;
        },
        else => |e| return e,
    };

    var cfg: Config = .{ .path = path, .found = true };
    if (root.get("default")) |v| switch (v) {
        .string => |s| cfg.default = s,
        else => return invalid(arena, diag, "{s}: 'default' must be a string", .{path}),
    };

    const conns: *const toml.Table = if (root.get("connections")) |v| switch (v) {
        .table => |t| t,
        else => return invalid(arena, diag, "{s}: 'connections' must be a table", .{path}),
    } else &.empty;

    var entries: std.ArrayList(Entry) = .empty;
    for (conns.keys(), conns.values()) |name, value| {
        const t = switch (value) {
            .table => |t| t,
            else => return invalid(arena, diag, "{s}: connections.{s} must be a table", .{ path, name }),
        };
        const params = entryParams(arena, env, t) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return invalid(arena, diag, "{s}: connections.{s}: {s}", .{ path, name, errorText(err) }),
        };
        const color = entryColor(t) catch |err| {
            return invalid(arena, diag, "{s}: connections.{s}: {s}", .{ path, name, errorText(err) });
        };
        try entries.append(arena, .{ .name = name, .params = params, .color = color });
    }
    cfg.connections = entries.items;

    if (cfg.default) |d| {
        if (cfg.find(d) == null) return invalid(arena, diag, "{s}: default connection '{s}' is not defined", .{ path, d });
    }
    return cfg;
}

const EntryError = error{
    MissingDriver,
    UnknownDriver,
    InvalidField,
    InvalidColor,
} || conninfo.ParseError;

fn errorText(err: EntryError) []const u8 {
    return switch (err) {
        error.MissingDriver => "set 'url', 'path' or 'driver'",
        error.UnknownDriver => "unknown driver (expected postgres, mysql, mariadb or sqlite)",
        error.InvalidField => "field has the wrong type",
        error.InvalidColor => "invalid color (expected #RRGGBB)",
        error.InvalidConnectionString => "invalid 'url'",
        error.UnknownScheme => "unknown scheme in 'url'",
        error.InvalidPort => "invalid port",
        error.InvalidSslMode => "invalid sslmode (expected disable, prefer, require, verify-ca or verify-full)",
        error.OutOfMemory => "out of memory",
    };
}

fn entryParams(arena: Allocator, env: *const std.process.Environ.Map, t: *const toml.Table) EntryError!conninfo.Params {
    var params: conninfo.Params = blk: {
        if (try getString(t, "url")) |url| break :blk try conninfo.parse(arena, url);
        if (try getString(t, "path")) |p| break :blk .{ .kind = .sqlite, .database = p };
        const driver = (try getString(t, "driver")) orelse return error.MissingDriver;
        break :blk .{ .kind = conninfo.Kind.fromName(driver) orelse return error.UnknownDriver };
    };

    // Explicit fields override what came from the URL.
    if (try getString(t, "host")) |v| params.host = v;
    if (t.get("port")) |v| switch (v) {
        .integer => |i| params.port = std.math.cast(u16, i) orelse return error.InvalidPort,
        else => return error.InvalidField,
    };
    if (try getString(t, "user")) |v| params.user = v;
    if (try getString(t, "password")) |v| params.password = v;
    if (try getString(t, "password_env")) |name| {
        // A missing variable must not break the whole config: the password
        // stays empty and only this connection fails to authenticate.
        if (env.get(name)) |pw| params.password = pw;
    }
    if (try getString(t, "database")) |v| params.database = v;
    if (try getString(t, "sslmode")) |v| {
        params.ssl = conninfo.SslMode.fromName(v) orelse return error.InvalidField;
    }

    if (params.kind == .sqlite) params.database = try expandHome(arena, env, params.database);
    return params;
}

fn getString(t: *const toml.Table, key: []const u8) error{InvalidField}!?[]const u8 {
    const v = t.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => error.InvalidField,
    };
}

fn entryColor(t: *const toml.Table) EntryError!?Color {
    const value = (try getString(t, "color")) orelse return null;
    return try parseColor(value);
}

fn parseColor(value: []const u8) error{InvalidColor}!Color {
    if (value.len != 7 or value[0] != '#') return error.InvalidColor;
    return .{
        .r = std.fmt.parseInt(u8, value[1..3], 16) catch return error.InvalidColor,
        .g = std.fmt.parseInt(u8, value[3..5], 16) catch return error.InvalidColor,
        .b = std.fmt.parseInt(u8, value[5..7], 16) catch return error.InvalidColor,
    };
}

pub fn expandHome(arena: Allocator, env: *const std.process.Environ.Map, path: []const u8) Allocator.Error![]const u8 {
    if (!std.mem.startsWith(u8, path, "~/") and !std.mem.startsWith(u8, path, "~\\")) return path;
    const home = homeDir(env) orelse return path;
    return std.fs.path.join(arena, &.{ home, path[2..] });
}

fn invalid(arena: Allocator, diag: *Diagnostic, comptime fmt: []const u8, args: anytype) LoadError {
    diag.message = try std.fmt.allocPrint(arena, fmt, args);
    return error.InvalidConfig;
}

pub const example =
    \\# zpeek connections
    \\# default = "local"
    \\
    \\# [connections.local]
    \\# url = "postgres://postgres@localhost:5432/postgres?sslmode=disable"
    \\# color = "#2F6B43"          # connection name badge background
    \\
    \\# [connections.shop]
    \\# driver = "mysql"            # postgres | mysql | mariadb | sqlite | clickhouse
    \\# host = "127.0.0.1"
    \\# port = 3306
    \\# user = "root"
    \\# password_env = "SHOP_DB_PASSWORD"
    \\# database = "shop"
    \\
    \\# [connections.notes]
    \\# path = "~/notes.db"
    \\
;

const testing = std.testing;

test "config entries" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: std.process.Environ.Map = .init(a);
    try env.put("HOME", "/home/me");
    try env.put("PW", "secret");

    const src =
        \\default = "pg"
        \\[connections.pg]
        \\url = "postgres://u@h/db"
        \\port = 6000
        \\color = "#2F6B43"
        \\[connections.my]
        \\driver = "mariadb"
        \\user = "root"
        \\password_env = "PW"
        \\database = "shop"
        \\[connections.lite]
        \\path = "~/x.db"
    ;
    var diag: Diagnostic = .{};
    const cfg = try parse(a, &env, "cfg.toml", src, &diag);
    try testing.expectEqual(@as(usize, 3), cfg.connections.len);
    const pg = cfg.find("pg").?.params;
    try testing.expectEqual(@as(u16, 6000), pg.port);
    try testing.expectEqualStrings("h", pg.host);
    try testing.expectEqual(Color{ .r = 0x2f, .g = 0x6b, .b = 0x43 }, cfg.find("pg").?.color.?);
    try testing.expectEqual(@as(u8, 209), (try parseColor("#FF6347")).ansi256());
    const my = cfg.find("my").?.params;
    try testing.expectEqual(conninfo.Kind.mysql, my.kind);
    try testing.expectEqualStrings("secret", my.password);
    try testing.expectEqualStrings("/home/me/x.db", cfg.find("lite").?.params.database);
}

test "config errors" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: std.process.Environ.Map = .init(a);
    var diag: Diagnostic = .{};
    try testing.expectError(error.InvalidConfig, parse(a, &env, "c", "[connections.x]\nhost = \"h\"\n", &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message, "connections.x") != null);
    try testing.expectError(error.InvalidConfig, parse(a, &env, "c", "default = \"nope\"\n", &diag));
    try testing.expectError(error.InvalidConfig, parse(a, &env, "c", "[connections.x]\nurl = \"postgres://h/db\"\ncolor = \"green\"\n", &diag));
}
