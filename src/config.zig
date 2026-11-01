//! Loads `config.toml` with named connections.
//!
//! ```toml
//! default = "local"
//!
//! [connections.local]
//! url = "postgres://me@localhost/app"
//! color = "#2F6B43"                # optional database badge color
//! access = "read_only"            # full | read_only | read_delete
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
    InvalidAccess,
    ConflictingAccess,
} || conninfo.ParseError;

fn errorText(err: EntryError) []const u8 {
    return switch (err) {
        error.MissingDriver => "set 'url', 'path' or 'driver'",
        error.UnknownDriver => "unknown driver (expected postgres, mysql, mariadb or sqlite)",
        error.InvalidField => "field has the wrong type",
        error.InvalidColor => "invalid color (expected #RRGGBB)",
        error.InvalidAccess => "invalid access (expected full, read_only or read_delete)",
        error.ConflictingAccess => "access and read_only disagree; use only access",
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
    if (t.get("read_only")) |v| switch (v) {
        .boolean => |b| params.access = if (b) .read_only else .full,
        else => return error.InvalidField,
    };
    if (try getString(t, "access")) |value| {
        const access = std.meta.stringToEnum(conninfo.Access, value) orelse return error.InvalidAccess;
        if (t.contains("read_only") and params.access != access) return error.ConflictingAccess;
        params.access = access;
    }
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

pub fn parseColor(value: []const u8) error{InvalidColor}!Color {
    if (value.len != 7 or value[0] != '#') return error.InvalidColor;
    return .{
        .r = std.fmt.parseInt(u8, value[1..3], 16) catch return error.InvalidColor,
        .g = std.fmt.parseInt(u8, value[3..5], 16) catch return error.InvalidColor,
        .b = std.fmt.parseInt(u8, value[5..7], 16) catch return error.InvalidColor,
    };
}

pub const Change = union(enum) {
    add: struct { name: []const u8, url: []const u8, color: []const u8 },
    remove: []const u8,
};

/// Reload before editing so changes made outside the app are retained.
/// Returned strings belong to arena, including the config path.
pub fn update(arena: Allocator, io: Io, env: *const std.process.Environ.Map, path: []const u8, change: Change) !Config {
    if (path.len == 0) return error.MissingConfigPath;
    const owned_path = try arena.dupe(u8, path);
    const src = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };
    var diag: Diagnostic = .{};
    _ = try parse(arena, env, owned_path, src, &diag);
    const root = try toml.parse(arena, src, null);
    const conns = if (root.get("connections")) |v| v.table else blk: {
        const t = try arena.create(toml.Table);
        t.* = .empty;
        try root.put(arena, "connections", .{ .table = t });
        break :blk t;
    };
    switch (change) {
        .add => |entry| {
            if (entry.name.len == 0 or std.mem.indexOfAny(u8, entry.name, " \t\r\n") != null) return error.InvalidName;
            if (conns.contains(entry.name)) return error.ConnectionExists;
            _ = try conninfo.parse(arena, entry.url);
            _ = try parseColor(entry.color);
            const t = try arena.create(toml.Table);
            t.* = .empty;
            try t.put(arena, "url", .{ .string = entry.url });
            try t.put(arena, "color", .{ .string = entry.color });
            try conns.put(arena, entry.name, .{ .table = t });
        },
        .remove => |name| {
            if (!conns.orderedRemove(name)) return error.UnknownConnection;
            if (root.get("default")) |v| {
                if (std.mem.eql(u8, v.string, name)) _ = root.orderedRemove("default");
            }
        },
    }
    var out: Io.Writer.Allocating = .init(arena);
    try writeTable(arena, &out.writer, root, "");
    const data = out.written();
    if (data.len > 4 * 1024 * 1024) return error.ConfigTooLarge;
    const cfg = try parse(arena, env, owned_path, data, &diag);
    try writeAtomic(io, path, data);
    return cfg;
}

/// Validate edited text and refuse to overwrite changes made since it was opened.
pub fn saveText(arena: Allocator, io: Io, env: *const std.process.Environ.Map, path: []const u8, text: []const u8, original: ?[]const u8, diag: *Diagnostic) !Config {
    if (path.len == 0) return error.MissingConfigPath;
    if (text.len > 4 * 1024 * 1024) return error.ConfigTooLarge;
    const owned_path = try arena.dupe(u8, path);
    const cfg = try parse(arena, env, owned_path, try arena.dupe(u8, text), diag);
    const current: ?[]const u8 = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (original) |before| {
        if (current == null or !std.mem.eql(u8, before, current.?)) return error.ConfigChanged;
    } else if (current != null) return error.ConfigChanged;
    try writeAtomic(io, path, text);
    return cfg;
}

fn writeAtomic(io: Io, path: []const u8, data: []const u8) !void {
    var file = try Io.Dir.cwd().createFileAtomic(io, path, .{
        .make_path = true,
        .replace = true,
        .permissions = if (@import("builtin").os.tag == .windows) .default_file else .fromMode(0o600),
    });
    defer file.deinit(io);
    try file.file.writeStreamingAll(io, data);
    try file.replace(io);
}

fn writeTable(arena: Allocator, w: *Io.Writer, table: *const toml.Table, path: []const u8) Io.Writer.Error!void {
    for (table.keys(), table.values()) |key, value| {
        if (value == .table) continue;
        try std.json.Stringify.value(key, .{}, w);
        try w.writeAll(" = ");
        try writeValue(w, value);
        try w.writeByte('\n');
    }
    for (table.keys(), table.values()) |key, value| {
        if (value != .table) continue;
        var header: Io.Writer.Allocating = .init(arena);
        defer header.deinit();
        if (path.len > 0) try header.writer.print("{s}.", .{path});
        try std.json.Stringify.value(key, .{}, &header.writer);
        try w.print("\n[{s}]\n", .{header.written()});
        try writeTable(arena, w, value.table, header.written());
    }
}

fn writeValue(w: *Io.Writer, value: toml.Value) Io.Writer.Error!void {
    switch (value) {
        .string => |v| try std.json.Stringify.value(v, .{}, w),
        .integer => |v| try w.print("{d}", .{v}),
        .float => |v| try w.print("{e}", .{v}),
        .boolean => |v| try w.writeAll(if (v) "true" else "false"),
        .array => |items| {
            try w.writeByte('[');
            for (items, 0..) |item, i| {
                if (i > 0) try w.writeAll(", ");
                try writeValue(w, item);
            }
            try w.writeByte(']');
        },
        .table => |t| {
            try w.writeByte('{');
            for (t.keys(), t.values(), 0..) |key, item, i| {
                if (i > 0) try w.writeAll(", ");
                try std.json.Stringify.value(key, .{}, w);
                try w.writeAll(" = ");
                try writeValue(w, item);
            }
            try w.writeByte('}');
        },
    }
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
    \\# access = "read_only"       # full | read_only | read_delete
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

test "config text editing validates before writing and detects external changes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: std.process.Environ.Map = .init(a);
    const path = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "config.toml" });
    const text = "# Keep my comment\n[connections.local]\npath = './app.sqlite'\ncolor = '#2F6B43'\n";
    var diag: Diagnostic = .{};
    const cfg = try saveText(a, testing.io, &env, path, text, null, &diag);
    try testing.expectEqualStrings("./app.sqlite", cfg.find("local").?.params.database);
    const cwd = Io.Dir.cwd();
    try testing.expectEqualStrings(text, try cwd.readFileAlloc(testing.io, path, a, .limited(4096)));
    try testing.expectError(error.InvalidConfig, saveText(a, testing.io, &env, path, "[broken", text, &diag));
    try testing.expect(diag.message.len > 0);
    try testing.expectError(error.InvalidConfig, saveText(a, testing.io, &env, path, "default = 'missing'", text, &diag));
    try testing.expectEqualStrings(text, try cwd.readFileAlloc(testing.io, path, a, .limited(4096)));
    try testing.expectError(error.ConfigChanged, saveText(a, testing.io, &env, path, "", null, &diag));
    try cwd.writeFile(testing.io, .{ .sub_path = path, .data = "# external edit\n" });
    try testing.expectError(error.ConfigChanged, saveText(a, testing.io, &env, path, text, text, &diag));
    try testing.expectEqualStrings("# external edit\n", try cwd.readFileAlloc(testing.io, path, a, .limited(4096)));
}

test "edit config atomically and preserve unresolved passwords and other settings" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: std.process.Environ.Map = .init(a);
    const path = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "nested", "config.toml" });
    const io = testing.io;
    const add: Change = .{ .add = .{ .name = "local.db", .url = "sqlite:///tmp/my database.db", .color = "#2F6B43" } };
    var cfg = try update(a, io, &env, path, add);
    try testing.expectEqualStrings("/tmp/my database.db", cfg.find("local.db").?.params.database);
    try testing.expectEqual(Color{ .r = 47, .g = 107, .b = 67 }, cfg.find("local.db").?.color.?);
    try testing.expectError(error.ConnectionExists, update(a, io, &env, path, add));
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data =
        \\default = "prod"
        \\custom = [true, "a\\b\"c", { value = 12 }]
        \\[connections.prod]
        \\url = "postgres://user@localhost/app"
        \\password_env = "SECRET_PASSWORD"
        \\read_only = true
    });
    cfg = try update(a, io, &env, path, add);
    try testing.expectEqual(conninfo.Access.read_only, cfg.find("prod").?.params.access);
    try testing.expectEqualStrings("prod", cfg.default.?);
    const saved = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(4096));
    const root = try toml.parse(a, saved, null);
    try testing.expectEqualStrings("SECRET_PASSWORD", root.get("connections").?.table.get("prod").?.table.get("password_env").?.string);
    try testing.expectEqualStrings("a\\b\"c", root.get("custom").?.array[1].string);
    try testing.expectError(error.InvalidColor, update(a, io, &env, path, .{ .add = .{ .name = "bad", .url = "./db.sqlite", .color = "red" } }));
    try testing.expectError(error.UnknownConnection, update(a, io, &env, path, .{ .remove = "missing" }));
    try testing.expectEqualStrings(saved, try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(4096)));
    cfg = try update(a, io, &env, path, .{ .remove = "prod" });
    try testing.expect(cfg.default == null);
    try testing.expect(cfg.find("prod") == null);
    try testing.expect(cfg.find("local.db") != null);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "[broken" });
    try testing.expectError(error.InvalidConfig, update(a, io, &env, path, add));
    try testing.expectEqualStrings("[broken", try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(4096)));
}

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
        \\read_only = true
    ;
    var diag: Diagnostic = .{};
    const cfg = try parse(a, &env, "cfg.toml", src, &diag);
    try testing.expectEqual(@as(usize, 3), cfg.connections.len);
    const pg = cfg.find("pg").?.params;
    try testing.expectEqual(@as(u16, 6000), pg.port);
    try testing.expectEqualStrings("h", pg.host);
    try testing.expectEqual(Color{ .r = 0x2f, .g = 0x6b, .b = 0x43 }, cfg.find("pg").?.color.?);
    const my = cfg.find("my").?.params;
    try testing.expectEqual(conninfo.Kind.mysql, my.kind);
    try testing.expectEqualStrings("secret", my.password);
    const sqlite_path = if (@import("builtin").os.tag == .windows) "/home/me\\x.db" else "/home/me/x.db";
    try testing.expectEqualStrings(sqlite_path, cfg.find("lite").?.params.database);
    try testing.expectEqual(conninfo.Access.read_only, cfg.find("lite").?.params.access);
    try testing.expectEqual(conninfo.Access.full, pg.access);
}

test "connection access modes and legacy read_only" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: std.process.Environ.Map = .init(a);
    var diag: Diagnostic = .{};
    for (std.enums.values(conninfo.Access)) |access| {
        const src = try std.fmt.allocPrint(a, "[connections.x]\npath = './app.sqlite'\naccess = '{s}'\n", .{@tagName(access)});
        const cfg = try parse(a, &env, "c", src, &diag);
        try testing.expectEqual(access, cfg.find("x").?.params.access);
    }
    for ([_][]const u8{ "access = 'invalid'", "access = true", "access = 'full'\nread_only = true", "access = 'read_delete'\nread_only = true" }) |fields| {
        const src = try std.fmt.allocPrint(a, "[connections.x]\npath = './app.sqlite'\n{s}\n", .{fields});
        try testing.expectError(error.InvalidConfig, parse(a, &env, "c", src, &diag));
    }
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
    try testing.expectError(error.InvalidConfig, parse(a, &env, "c", "[connections.x]\nurl = \"postgres://h/db\"\nread_only = \"yes\"\n", &diag));
}
