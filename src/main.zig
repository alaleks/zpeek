const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const config = @import("config.zig");
const conninfo = @import("conninfo.zig");
const db = @import("db/db.zig");
const render = @import("render.zig");
const App = @import("ui/App.zig");
const vaxis = @import("vaxis");

/// Restore the terminal (leave the alternate screen, raw mode) before printing a panic.
pub const panic = std.debug.FullPanic(panicHandler);

fn panicHandler(msg: []const u8, first_trace_addr: ?usize) noreturn {
    vaxis.recover();
    std.debug.defaultPanic(msg, first_trace_addr);
}

const usage =
    \\zpeek — terminal client for PostgreSQL, MySQL/MariaDB, SQLite and ClickHouse
    \\
    \\Usage:
    \\  zpeek [options] [connection]
    \\
    \\  connection   a name from the config file, a URL
    \\               (postgres://…, mysql://…, mariadb://…, clickhouse://…, sqlite://…),
    \\               a libpq "host=… dbname=…" string, or a path to a SQLite file
    \\
    \\Options:
    \\  -e, --execute SQL   run SQL, print the result and exit
    \\  -c, --config PATH   use this config file
    \\      --driver NAME   postgres | mysql | mariadb | sqlite | clickhouse
    \\      --host HOST     server host (or a Unix socket directory/path)
    \\      --port PORT     server port
    \\      --user USER     user name
    \\      --password PW   password (default: $PGPASSWORD / $MYSQL_PWD)
    \\      --database DB   database name (or SQLite file)
    \\  -l, --list          list configured connections
    \\      --init-config   write an example config file if none exists
    \\  -h, --help          show this help
    \\
    \\Connection fields override the matching parts of [connection].
    \\
;

const Cli = struct {
    target: ?[]const u8 = null,
    driver: ?[]const u8 = null,
    host: ?[]const u8 = null,
    port: ?[]const u8 = null,
    user: ?[]const u8 = null,
    password: ?[]const u8 = null,
    database: ?[]const u8 = null,
    execute: ?[]const u8 = null,
    config_path: ?[]const u8 = null,
    list: bool = false,
    init_config: bool = false,
    help: bool = false,
};

fn parseArgs(args: []const [:0]const u8, stderr: *Io.Writer) !Cli {
    var cli: Cli = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];
        if (eqlAny(arg, &.{ "-h", "--help" })) {
            cli.help = true;
        } else if (eqlAny(arg, &.{ "-l", "--list" })) {
            cli.list = true;
        } else if (std.mem.eql(u8, arg, "--init-config")) {
            cli.init_config = true;
        } else if (valueOption(&cli, arg)) |field| {
            i += 1;
            if (i >= args.len) {
                try stderr.print("zpeek: {s} needs an argument\n", .{arg});
                return error.InvalidArgs;
            }
            field.* = args[i];
        } else if (arg.len > 1 and arg[0] == '-') {
            try stderr.print("zpeek: unknown option {s}\n", .{arg});
            return error.InvalidArgs;
        } else if (cli.target == null) {
            cli.target = arg;
        } else {
            try stderr.print("zpeek: unexpected argument {s}\n", .{arg});
            return error.InvalidArgs;
        }
    }
    return cli;
}

/// Options that take a value; returns the field to store it in.
fn valueOption(cli: *Cli, arg: []const u8) ?*?[]const u8 {
    if (eqlAny(arg, &.{ "-e", "--execute" })) return &cli.execute;
    if (eqlAny(arg, &.{ "-c", "--config" })) return &cli.config_path;
    if (eqlAny(arg, &.{"--driver"})) return &cli.driver;
    if (eqlAny(arg, &.{"--host"})) return &cli.host;
    if (eqlAny(arg, &.{"--port"})) return &cli.port;
    if (eqlAny(arg, &.{"--user"})) return &cli.user;
    if (eqlAny(arg, &.{"--password"})) return &cli.password;
    if (eqlAny(arg, &.{ "--database", "--db" })) return &cli.database;
    return null;
}

fn hasFields(cli: Cli) bool {
    return cli.driver != null or cli.host != null or cli.port != null or cli.user != null or
        cli.password != null or cli.database != null;
}

/// Builds or adjusts a connection from --driver/--host/... flags.
fn applyFields(arena: Allocator, cli: Cli, base: ?config.Entry, stderr: *Io.Writer) !?config.Entry {
    var p: conninfo.Params = if (base) |b| b.params else blk: {
        const name = cli.driver orelse {
            // Without a driver, guess from the port.
            if (cli.port) |port| if (std.mem.eql(u8, port, "3306")) break :blk .{ .kind = .mysql };
            if (cli.database) |d| if (conninfo.looksLikeSqlitePath(d)) break :blk .{ .kind = .sqlite };
            break :blk .{ .kind = .postgres };
        };
        break :blk .{ .kind = conninfo.Kind.fromName(name) orelse {
            try stderr.print("zpeek: unknown driver '{s}'\n", .{name});
            return error.InvalidArgs;
        } };
    };
    if (cli.driver) |d| p.kind = conninfo.Kind.fromName(d) orelse p.kind;
    if (cli.host) |v| p.host = v;
    if (cli.port) |v| p.port = std.fmt.parseInt(u16, v, 10) catch {
        try stderr.print("zpeek: invalid port '{s}'\n", .{v});
        return error.InvalidArgs;
    };
    if (cli.user) |v| p.user = v;
    if (cli.password) |v| p.password = v;
    if (cli.database) |v| p.database = v;
    var buf: [256]u8 = undefined;
    const name = if (base) |b| b.name else if (p.kind == .sqlite) std.fs.path.basename(p.database) else p.describe(&buf);
    return .{ .name = try arena.dupe(u8, name), .params = p };
}

fn eqlAny(a: []const u8, options: []const []const u8) bool {
    for (options) |o| if (std.mem.eql(u8, a, o)) return true;
    return false;
}

pub const ResolveError = error{UnknownConnection} || conninfo.ParseError;

/// Turns a CLI/console target into connection parameters.
pub fn resolveTarget(arena: Allocator, cfg: config.Config, target: []const u8) ResolveError!config.Entry {
    if (cfg.find(target)) |e| return e;
    if (conninfo.isConnectionString(target)) {
        const params = try conninfo.parse(arena, target);
        // The display name must not contain the password from the URL.
        var buf: [256]u8 = undefined;
        const name = if (params.kind == .sqlite) std.fs.path.basename(params.database) else params.describe(&buf);
        return .{ .name = try arena.dupe(u8, name), .params = params };
    }
    return error.UnknownConnection;
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_fw: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const stdout = &stdout_fw.interface;
    var stderr_buf: [1024]u8 = undefined;
    var stderr_fw: Io.File.Writer = .init(.stderr(), io, &stderr_buf);
    const stderr = &stderr_fw.interface;
    defer stdout.flush() catch {};
    defer stderr.flush() catch {};

    const args = try init.minimal.args.toSlice(arena);
    const cli = parseArgs(args, stderr) catch return 2;
    if (cli.help) {
        try stdout.writeAll(usage);
        return 0;
    }

    var diag: config.Diagnostic = .{};
    const cfg = config.load(arena, io, init.environ_map, cli.config_path, &diag) catch |err| switch (err) {
        error.InvalidConfig, error.ReadFailed => {
            try stderr.print("zpeek: {s}\n", .{diag.message});
            return 1;
        },
        else => |e| return e,
    };

    if (cli.init_config) return initConfig(io, cfg, stdout, stderr);

    if (cli.list) {
        try listConnections(cfg, stdout);
        return 0;
    }

    var entry: ?config.Entry = blk: {
        if (cli.target == null and hasFields(cli)) break :blk null;
        const target = cli.target orelse cfg.default orelse {
            if (cfg.connections.len == 1) break :blk cfg.connections[0];
            break :blk null;
        };
        break :blk resolveTarget(arena, cfg, target) catch |err| {
            switch (err) {
                error.UnknownConnection => try stderr.print("zpeek: no connection named '{s}' in {s}\n", .{ target, if (cfg.found) cfg.path else "config (file not found)" }),
                else => |e| try stderr.print("zpeek: invalid connection string: {s}\n", .{conninfo.errorText(e)}),
            }
            return 1;
        };
    };

    if (hasFields(cli)) entry = applyFields(arena, cli, entry, stderr) catch return 2;
    if (entry) |*e| conninfo.passwordFromEnv(&e.params, init.environ_map);

    if (cli.execute) |sql| {
        const e = entry orelse {
            try stderr.writeAll("zpeek: --execute needs a connection\n");
            return 2;
        };
        return executeOnce(gpa, io, e, sql, stdout, stderr);
    }

    try stdout.flush();
    try App.run(.{
        .gpa = gpa,
        .io = io,
        .env = init.environ_map,
        .config = cfg,
        .initial = entry,
    });
    return 0;
}

fn executeOnce(gpa: Allocator, io: Io, entry: config.Entry, sql: []const u8, stdout: *Io.Writer, stderr: *Io.Writer) !u8 {
    var err: db.ErrorText = .{};
    defer err.deinit(gpa);
    const conn = db.connect(gpa, io, entry.params, &err) catch |e| switch (e) {
        error.ConnectFailed => {
            try stderr.print("zpeek: {s}\n", .{err.slice()});
            return 1;
        },
        else => |x| return x,
    };
    defer conn.close();

    const dialect: @import("sql/lexer.zig").Dialect = switch (conn.kind) {
        .postgres => .postgres,
        .mysql => .mysql,
        .sqlite => .sqlite,
        // Backslash escapes in strings, like MySQL.
        .clickhouse => .mysql,
    };
    if (@import("sql/lexer.zig").hasDeleteWithoutWhere(sql, dialect)) {
        try stderr.print("zpeek: {s}\n", .{App.delete_without_where_message});
        return 1;
    }

    var result = conn.query(gpa, sql) catch |e| switch (e) {
        error.QueryFailed, error.ConnectionLost => {
            try stderr.print("{s}\n", .{conn.lastError()});
            return 1;
        },
        else => |x| return x,
    };
    defer result.deinit();
    try render.writeResult(gpa, stdout, result, .{});
    return 0;
}

fn listConnections(cfg: config.Config, w: *Io.Writer) !void {
    if (!cfg.found) {
        try w.print("No config file at {s}. Create one with `zpeek --init-config`.\n", .{cfg.path});
        return;
    }
    if (cfg.connections.len == 0) {
        try w.print("No connections in {s}\n", .{cfg.path});
        return;
    }
    var buf: [256]u8 = undefined;
    for (cfg.connections) |e| {
        const mark: []const u8 = if (cfg.default != null and std.mem.eql(u8, cfg.default.?, e.name)) "*" else " ";
        try w.print("{s} {s:<16} {s:<14} {s}\n", .{ mark, e.name, e.params.kind.label(), e.params.describe(&buf) });
    }
}

fn initConfig(io: Io, cfg: config.Config, stdout: *Io.Writer, stderr: *Io.Writer) !u8 {
    if (cfg.path.len == 0) {
        try stderr.writeAll("zpeek: cannot determine config path (HOME is not set)\n");
        return 1;
    }
    if (cfg.found) {
        try stdout.print("Config already exists: {s}\n", .{cfg.path});
        return 0;
    }
    const cwd = Io.Dir.cwd();
    if (std.fs.path.dirname(cfg.path)) |dir| try cwd.createDirPath(io, dir);
    try cwd.writeFile(io, .{ .sub_path = cfg.path, .data = config.example });
    try stdout.print("Wrote {s}\n", .{cfg.path});
    return 0;
}

test {
    _ = @import("toml.zig");
    _ = config;
    _ = conninfo;
    _ = db;
    _ = render;
    _ = @import("sql/lexer.zig");
    _ = @import("db/schema.zig");
    _ = @import("ui/Editor.zig");
    _ = @import("ui/complete.zig");
    _ = @import("queries.zig");
}
