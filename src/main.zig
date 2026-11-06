const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const config = @import("config.zig");
const exporter = @import("export.zig");
const OutputFormat = enum { table, csv, json };
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
    \\      --format FORMAT table (default), csv or json; requires --execute
    \\      --allow-dangerous  confirm DROP/TRUNCATE/UPDATE/DELETE in full mode
    \\  -c, --config PATH   use this config file
    \\      --driver NAME   postgres | mysql | mariadb | sqlite | clickhouse
    \\      --host HOST     server host (or a Unix socket directory/path)
    \\      --port PORT     server port
    \\      --user USER     user name
    \\      --password PW   password (default: $PGPASSWORD / $MYSQL_PWD / $CLICKHOUSE_PASSWORD)
    \\      --database DB   database name (or SQLite file)
    \\  -l, --list          list configured connections
    \\      --init-config   write an example config file if none exists
    \\  -V, --version       print the version
    \\  -h, --help          show this help
    \\
    \\Connection fields override the matching parts of [connection].
    \\PostgreSQL- and MySQL-compatible servers (CockroachDB, YugabyteDB, TiDB,
    \\Redshift, Aurora, …) work with postgres:// and mysql:// URLs.
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
    output_format: ?[]const u8 = null,
    allow_dangerous: bool = false,
    config_path: ?[]const u8 = null,
    list: bool = false,
    init_config: bool = false,
    help: bool = false,
    version: bool = false,
};

fn parseArgs(args: []const [:0]const u8, stderr: *Io.Writer) !Cli {
    var cli: Cli = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];
        if (eqlAny(arg, &.{ "-h", "--help" })) {
            cli.help = true;
        } else if (eqlAny(arg, &.{ "-V", "--version" })) {
            cli.version = true;
        } else if (eqlAny(arg, &.{ "-l", "--list" })) {
            cli.list = true;
        } else if (std.mem.eql(u8, arg, "--init-config")) {
            cli.init_config = true;
        } else if (std.mem.eql(u8, arg, "--allow-dangerous")) {
            cli.allow_dangerous = true;
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
    if (std.mem.eql(u8, arg, "--format")) return &cli.output_format;
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
    if (cli.driver) |d| p.kind = conninfo.Kind.fromName(d) orelse {
        try stderr.print("zpeek: unknown driver '{s}'\n", .{d});
        return error.InvalidArgs;
    };
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
    // Streaming, not positional: `>>` and shared redirects must write at the
    // file's current offset instead of overwriting it from byte 0.
    var stdout_fw: Io.File.Writer = .initStreaming(.stdout(), io, &stdout_buf);
    const stdout = &stdout_fw.interface;
    var stderr_buf: [1024]u8 = undefined;
    var stderr_fw: Io.File.Writer = .initStreaming(.stderr(), io, &stderr_buf);
    const stderr = &stderr_fw.interface;
    defer stdout.flush() catch {};
    defer stderr.flush() catch {};

    const args = try init.minimal.args.toSlice(arena);
    const cli = parseArgs(args, stderr) catch return 2;
    if (cli.help) {
        try stdout.writeAll(usage);
        return 0;
    }
    if (cli.version) {
        try stdout.print("zpeek {s}\n", .{@import("build_options").version});
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
        const format = std.meta.stringToEnum(OutputFormat, cli.output_format orelse "table") orelse {
            try stderr.writeAll("zpeek: --format must be table, csv or json\n");
            return 2;
        };
        return executeOnce(gpa, io, e, sql, stdout, stderr, format, cli.allow_dangerous);
    }
    if (cli.output_format != null or cli.allow_dangerous) {
        try stderr.writeAll("zpeek: --format and --allow-dangerous require --execute\n");
        return 2;
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

fn executeOnce(gpa: Allocator, io: Io, entry: config.Entry, sql: []const u8, stdout: *Io.Writer, stderr: *Io.Writer, format: OutputFormat, allow_dangerous: bool) !u8 {
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
    if (entry.params.access.violation(sql, dialect)) |word| {
        if (entry.params.access == .read_only) {
            try stderr.print("zpeek: " ++ App.read_only_message ++ "\n", .{word});
        } else {
            try stderr.print("zpeek: " ++ App.read_delete_message ++ "\n", .{word});
        }
        return 1;
    }
    if (@import("sql/lexer.zig").hasDeleteWithoutWhere(sql, dialect)) {
        try stderr.print("zpeek: {s}\n", .{App.delete_without_where_message});
        return 1;
    }
    if (entry.params.access == .full and !allow_dangerous) if (@import("sql/lexer.zig").dangerousStatement(sql, dialect)) |word| {
        try stderr.print("zpeek: '{s}' requires confirmation; review the SQL and rerun with --allow-dangerous\n", .{word});
        return 1;
    };

    const started: Io.Timestamp = .now(io, .awake);
    var result = conn.query(gpa, sql) catch |e| switch (e) {
        error.AccessDenied => {
            try stderr.writeAll("zpeek: connection access policy blocked this statement; nothing was run\n");
            return 1;
        },
        error.QueryFailed, error.ConnectionLost => {
            try stderr.print("{s}\n", .{conn.lastError()});
            return 1;
        },
        else => |x| return x,
    };
    defer result.deinit();
    result.elapsed_ms = started.untilNow(io, .awake).toMilliseconds();
    switch (format) {
        .table => try render.writeResult(gpa, stdout, result, .{}),
        .csv, .json => {
            exporter.write(stdout, result, if (format == .csv) .csv else .json, .{}) catch |e| {
                try stderr.print("zpeek: cannot export: {t}; JSON columns need unique names\n", .{e});
                return 1;
            };
            try render.writeStatus(stderr, result, result.elapsed_ms);
            try stderr.writeByte('\n');
            if (result.truncated) try stderr.writeAll("zpeek: exported result was truncated by the row/byte limit\n");
        },
    }
    return 0;
}

test "CLI export and dangerous confirmation preserve database data" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "test.sqlite", .data = "" });
    const path = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "test.sqlite" });
    defer a.free(path);
    var err: db.ErrorText = .{};
    defer err.deinit(a);
    const conn = try db.connect(a, io, .{ .kind = .sqlite, .database = path }, &err);
    defer conn.close();
    var setup = try conn.query(a, "create table people(id integer primary key, name text); insert into people values (1,'Ada');");
    setup.deinit();
    var entry: config.Entry = .{ .name = "test", .params = .{ .kind = .sqlite, .database = path } };
    var out_buf: [4096]u8 = undefined;
    var err_buf: [4096]u8 = undefined;
    var stdout: Io.Writer = .fixed(&out_buf);
    var stderr: Io.Writer = .fixed(&err_buf);
    try std.testing.expectEqual(@as(u8, 1), try executeOnce(a, io, entry, "select 1; drop table people", &stdout, &stderr, .table, false));
    try std.testing.expectEqual(@as(usize, 0), stdout.buffered().len);
    try std.testing.expect(std.mem.indexOf(u8, stderr.buffered(), "--allow-dangerous") != null);
    stdout.end = 0;
    stderr.end = 0;
    try std.testing.expectEqual(@as(u8, 0), try executeOnce(a, io, entry, "select id,name from people", &stdout, &stderr, .csv, false));
    try std.testing.expectEqualStrings("\"id\",\"name\"\r\n\"1\",\"Ada\"\r\n", stdout.buffered());
    try std.testing.expect(std.mem.indexOf(u8, stderr.buffered(), " ms") != null);
    stdout.end = 0;
    stderr.end = 0;
    try std.testing.expectEqual(@as(u8, 0), try executeOnce(a, io, entry, "select id,name from people", &stdout, &stderr, .json, false));
    try std.testing.expectEqualStrings("[\n  {\"id\": \"1\", \"name\": \"Ada\"}\n]\n", stdout.buffered());
    stdout.end = 0;
    stderr.end = 0;
    try std.testing.expectEqual(@as(u8, 0), try executeOnce(a, io, entry, "update people set name='Grace' returning id", &stdout, &stderr, .table, true));
    try std.testing.expect(std.mem.indexOf(u8, stdout.buffered(), "1 row affected") != null);
    entry.params.access = .read_delete;
    stdout.end = 0;
    stderr.end = 0;
    try std.testing.expectEqual(@as(u8, 1), try executeOnce(a, io, entry, "drop table people", &stdout, &stderr, .table, true));
    var rows = try conn.query(a, "select name from people");
    defer rows.deinit();
    try std.testing.expectEqualStrings("Grace", rows.rows[0][0].?);
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
    _ = App;
    _ = @import("ui/TableView.zig");
    _ = @import("ui/complete.zig");
    _ = @import("queries.zig");
}

test "unknown driver rejects saved and new connections" {
    var buffer: [256]u8 = undefined;
    var stderr: Io.Writer = .fixed(&buffer);
    const saved: config.Entry = .{ .name = "local", .params = .{ .kind = .sqlite, .database = ":memory:" } };
    for ([_]?config.Entry{ null, saved }) |base| {
        try std.testing.expectError(error.InvalidArgs, applyFields(std.testing.allocator, .{ .driver = "definitely_invalid" }, base, &stderr));
    }
    try std.testing.expect(std.mem.indexOf(u8, stderr.buffered(), "unknown driver") != null);
}
