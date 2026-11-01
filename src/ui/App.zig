//! The interactive console: a transcript of commands and results above an
//! input box, in the spirit of Claude Code. Queries run on a background task
//! so the UI stays responsive and can cancel them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const vaxis = @import("vaxis");
const Segment = vaxis.Segment;

const config = @import("../config.zig");
const conninfo = @import("../conninfo.zig");
const db = @import("../db/db.zig");
const schema = @import("../db/schema.zig");
const lexer = @import("../sql/lexer.zig");
const render = @import("../render.zig");
const theme = @import("theme.zig");
const Editor = @import("Editor.zig");
const Transcript = @import("Transcript.zig");
const TableView = @import("TableView.zig");
const Picker = @import("Picker.zig");
const complete = @import("complete.zig");
const queries = @import("../queries.zig");
const exporter = @import("../export.zig");
const plan = @import("../plan.zig");

const App = @This();

pub const Options = struct {
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    config: config.Config,
    initial: ?config.Entry,
};

const Event = union(enum) {
    key_press: vaxis.Key,
    mouse: vaxis.Mouse,
    winsize: vaxis.Winsize,
    paste_start,
    paste_end,
    paste: []const u8,
    focus_in,
    job_done,
    tick,
};

const Loop = vaxis.Loop(Event);

/// Max rows kept for ad-hoc queries; protects memory on `select * from huge`.
const console_row_limit = 10_000;
const history_limit = 1000;
const connect_job_timeout_ms = 30_000;

const commands = [_]complete.Command{
    .{ .name = "/help", .help = "show commands and keys", .aliases = &.{"/?"} },
    .{ .name = "/connect", .args = "[name|url]", .help = "connect (no argument: pick from config)", .arg = .connection, .aliases = &.{"/c"} },
    .{ .name = "/disconnect", .help = "close the connection" },
    .{ .name = "/config", .args = "[edit | add <name> <#RRGGBB> <url|path> | remove <name>]", .help = "edit config, save/remove connections; no argument: list and help" },
    .{ .name = "/tables", .help = "pick a table to browse", .aliases = &.{"/t"} },
    .{ .name = "/views", .help = "pick a view to show its SQL", .aliases = &.{"/v"} },
    .{ .name = "/types", .help = "pick a type to show its values", .aliases = &.{"/enums"} },
    .{ .name = "/functions", .help = "pick a function or procedure to show its source", .aliases = &.{ "/fn", "/routines" } },
    .{ .name = "/triggers", .help = "pick a trigger to show its source" },
    .{ .name = "/describe", .args = "<table>", .help = "columns, indexes and constraints", .arg = .table, .aliases = &.{"/d"} },
    .{ .name = "/browse", .args = "<table> [where …]", .help = "open table data (no argument: pick a table)", .arg = .table, .aliases = &.{"/b"} },
    .{ .name = "/def", .args = "<name>", .help = "source of a view, function, trigger or enum" },
    .{ .name = "/databases", .help = "list databases", .aliases = &.{"/dbs"} },
    .{ .name = "/refresh", .help = "reload table/column names for completion" },
    .{ .name = "/history", .args = "[search]", .help = "search SQL history (alt+r) and load into editor" },
    .{ .name = "/export", .args = "<csv|json> [path]", .help = "export the last retained result to a new file" },
    .{ .name = "/explain", .args = "[SQL]", .help = "view a query plan without ANALYZE; default: last SQL" },
    .{ .name = "/save", .args = "[name]", .help = "save SQL (no name: open save dialog)" },
    .{ .name = "/copy", .help = "copy the last SQL query or displayed definition to the clipboard" },
    .{ .name = "/queries", .args = "[name]", .help = "saved queries: pick one to put it in the input", .arg = .query, .aliases = &.{"/sq"} },
    .{ .name = "/unsave", .args = "<name>", .help = "delete a saved query", .arg = .query },
    .{ .name = "/clear", .help = "clear the screen" },
    .{ .name = "/quit", .help = "exit", .aliases = &.{ "/q", "/exit" } },
};

const Mode = enum { console, table, picker, config };

const ConfigEdit = struct {
    previous: Editor,
    original: ?[]const u8,
    message: ?[]const u8 = null,
    discard_armed: bool = false,
    show_help: bool = true,
    help_top: usize = 0,
    help_page_size: usize = 5,
};

const config_help = [_][]const u8{
    "default = \"local\"  (before connection sections)",
    "[connections.local]  (one section per connection)",
    "access = \"full\" | \"read_only\" | \"read_delete\"",
    "  full: all; read_only: read; read_delete: read + DELETE",
    "  default: full; DELETE requires WHERE",
    "url = \"postgres://user@localhost/app\"",
    "path = \"~/app.sqlite\"  (SQLite, instead of url)",
    "driver = \"postgres\"  (when url/path is absent)",
    "  postgres | mysql | mariadb | sqlite | clickhouse",
    "host = \"localhost\"",
    "port = 5432  (number; driver default if omitted)",
    "user = \"user\"",
    "database = \"app\"",
    "password_env = \"DB_PASSWORD\"  (environment variable)",
    "password = \"...\"  (plain text; prefer password_env)",
    "color = \"#2F6B43\"  (#RRGGBB)",
    "sslmode = \"prefer\"",
    "  disable | prefer | require | verify-ca | verify-full",
    "read_only = true | false  (legacy; prefer access)",
    "Do not combine conflicting access and read_only values.",
    "Explicit connection fields override values from the URL.",
};

const JobKind = union(enum) {
    connect: struct { name: []const u8, params: conninfo.Params },
    console,
    explain,
    list: schema.Object,
    describe: []const u8,
    definition: []const u8,
    browse_open: TableView.Browse,
    browse_reload,
    browse_count,
    browse_fk,
    /// A confirmed single-row DELETE from the table viewer.
    browse_delete,
    cache,
};

const Outcome = union(enum) {
    result: struct { result: db.Result, ms: i64 },
    failed: []const u8,
    canceled,
};

const Job = struct {
    arena: std.heap.ArenaAllocator,
    kind: JobKind,
    sqls: []const []const u8 = &.{},
    max_rows: usize = std.math.maxInt(usize),
    max_result_bytes: usize = 32 * 1024 * 1024,
    /// Stop at the first failing statement.
    stop_on_error: bool = true,
    outcomes: std.ArrayList(Outcome) = .empty,
    /// Set by connect jobs.
    conn: ?db.Connection = null,
    connect_error: ?[]const u8 = null,
    started: Io.Timestamp,
    future: Io.Future(void) = undefined,
    cancel_requested: std.atomic.Value(bool) = .init(false),
    timed_out: bool = false,
    connection_lost: bool = false,
};

gpa: Allocator,
io: Io,
env: *std.process.Environ.Map,
cfg: config.Config,
config_arena: ?std.heap.ArenaAllocator = null,
config_edit: ?ConfigEdit = null,

tty: vaxis.Tty = undefined,
tty_buf: [4096]u8 = undefined,
vx: vaxis.Vaxis = undefined,
loop: Loop = undefined,

running: bool = true,
mode: Mode = .console,
editor: Editor,
transcript: Transcript,
table_view: ?*TableView = null,
picker: ?*Picker = null,

conn: ?db.Connection = null,
conn_name: []const u8 = "",
conn_params: ?conninfo.Params = null,
conn_color: ?config.Color = null,
conn_arena: std.heap.ArenaAllocator,
cache: ?complete.SchemaCache = null,

job: ?*Job = null,
busy: std.atomic.Value(bool) = .init(false),
spinner: usize = 0,
ticker: ?Io.Future(void) = null,

popup: ?Popup = null,
popup_arena: std.heap.ArenaAllocator,
pasting: bool = false,
exit_armed: bool = false,
notice: std.ArrayList(u8) = .empty,
/// The last SQL text sent to the server, for /save and /copy.
last_sql: std.ArrayList(u8) = .empty,
pending_save: std.ArrayList(u8) = .empty,
frame_arena: std.heap.ArenaAllocator,
history_path: ?[]const u8 = null,
export_table: bool = false,

const Popup = struct {
    completion: complete.Completion,
    selected: usize = 0,
    top: usize = 0,
    /// The user moved the selection; Enter then inserts instead of running.
    navigated: bool = false,
};

pub fn run(opts: Options) !void {
    const app = try opts.gpa.create(App);
    defer opts.gpa.destroy(app);
    app.* = .{
        .gpa = opts.gpa,
        .io = opts.io,
        .env = opts.env,
        .cfg = opts.config,
        .editor = .init(opts.gpa),
        .transcript = .init(opts.gpa),
        .conn_arena = .init(opts.gpa),
        .popup_arena = .init(opts.gpa),
        .frame_arena = .init(opts.gpa),
    };
    defer app.deinit();
    try app.loadHistory();
    defer app.saveHistory();

    app.tty = try vaxis.Tty.init(app.io, &app.tty_buf);
    defer app.tty.deinit();
    const writer = app.tty.writer();

    app.vx = try vaxis.init(app.io, app.gpa, app.env, .{
        .kitty_keyboard_flags = .{ .report_events = false },
    });
    defer app.vx.deinit(app.gpa, app.tty.writer());

    app.loop = .init(app.io, &app.tty, &app.vx);
    try app.loop.installResizeHandler();
    defer app.loop.uninstallResizeHandler();
    try app.loop.start();
    defer app.stopJob();
    defer app.loop.stop();

    try app.vx.enterAltScreen(writer);
    try app.vx.setBracketedPaste(writer, true);
    try app.vx.setMouseMode(writer, true);
    try app.vx.setTitle(writer, "zpeek");
    try writer.flush();
    try app.vx.queryTerminal(writer, .fromSeconds(1));
    // RGB colors as `38;2;r;g;b`: the colon form vaxis uses by default is not
    // understood by several terminals (Zed, Terminal.app, …), which then print
    // the parameters as text and shift the layout.
    app.vx.sgr = .legacy;

    app.ticker = try app.io.concurrent(tickerTask, .{app});
    defer if (app.ticker) |*t| t.cancel(app.io);

    try app.welcome();
    if (opts.initial) |e| {
        try app.startConnect(e.name, e.params);
    } else if (app.cfg.connections.len > 0) {
        try app.openConnectPicker();
    }

    while (app.running) {
        const event = try app.loop.nextEvent();
        try app.handleEvent(event);
        while (try app.loop.tryEvent()) |ev| try app.handleEvent(ev);
        if (!app.running) break;
        if (app.table_view == null or app.table_view.?.owns_result) {
            app.transcript.compact() catch {}; // only frees memory; keeping rows is safe
            app.transcript.prune();
        }
        try app.draw();
        try app.vx.render(writer);
        try writer.flush();
    }
}

fn deinit(app: *App) void {
    app.stopJob();
    if (app.table_view) |tv| tv.deinit();
    if (app.picker) |p| p.deinit();
    if (app.conn) |c| c.close();
    if (app.cache) |*c| c.deinit();
    app.editor.deinit();
    if (app.config_edit) |*edit| {
        edit.previous.deinit();
        if (edit.original) |text| app.gpa.free(text);
        if (edit.message) |message| app.gpa.free(message);
    }
    app.transcript.deinit();
    app.conn_arena.deinit();
    app.popup_arena.deinit();
    app.frame_arena.deinit();
    if (app.config_arena) |*arena| arena.deinit();
    app.notice.deinit(app.gpa);
    app.last_sql.deinit(app.gpa);
    app.pending_save.deinit(app.gpa);
    if (app.history_path) |path| app.gpa.free(path);
}

fn tickerTask(app: *App) void {
    while (true) {
        app.io.sleep(.fromMilliseconds(250), .awake) catch return;
        if (app.busy.load(.acquire)) {
            _ = app.loop.tryPostEvent(.tick) catch return;
        }
    }
}

/// History lives in $XDG_STATE_HOME/zpeek/history (default ~/.local/state),
/// entries separated by NUL so multi-line SQL survives.
fn historyPath(app: *App) !?[]const u8 {
    const a = app.conn_arena.allocator();
    if (app.env.get("XDG_STATE_HOME")) |x| {
        if (x.len > 0) return try std.fs.path.join(a, &.{ x, "zpeek", "history" });
    }
    if (app.env.get("HOME")) |home| return try std.fs.path.join(a, &.{ home, ".local", "state", "zpeek", "history" });
    if (app.env.get("LOCALAPPDATA")) |local| return try std.fs.path.join(a, &.{ local, "zpeek", "history" });
    return null;
}

fn loadHistory(app: *App) !void {
    // Stored outside conn_arena's resettable lifetime: copy into gpa.
    const path = (try app.historyPath()) orelse return;
    app.history_path = try app.gpa.dupe(u8, path);
    _ = app.conn_arena.reset(.retain_capacity);
    const data = Io.Dir.cwd().readFileAlloc(app.io, app.history_path.?, app.gpa, .limited(16 * 1024 * 1024)) catch return;
    defer app.gpa.free(data);
    var entries = std.mem.splitScalar(u8, data, 0);
    while (entries.next()) |entry| {
        if (entry.len == 0) continue;
        try app.editor.commitHistoryText(redactConnectionInput(entry));
    }
}

fn saveHistory(app: *App) void {
    const path = app.history_path orelse return;
    const items = if (app.config_edit) |edit| edit.previous.history.items else app.editor.history.items;
    const start = items.len -| history_limit;
    var file = Io.Dir.cwd().createFileAtomic(app.io, path, .{
        .replace = true,
        .make_path = true,
        .permissions = if (@import("builtin").os.tag == .windows) .default_file else .fromMode(0o600),
    }) catch return;
    defer file.deinit(app.io);
    var buffer: [4096]u8 = undefined;
    var writer = file.file.writer(app.io, &buffer);
    for (items[start..]) |h| {
        writer.interface.writeAll(h) catch return;
        writer.interface.writeByte(0) catch return;
    }
    writer.interface.flush() catch return;
    file.replace(app.io) catch {};
}

test "history rewrites connection URLs without credentials" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();
    const state_dir = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "state" });
    defer a.free(state_dir);
    try env.put("XDG_STATE_HOME", state_dir);
    const history_file = try std.fs.path.join(a, &.{ state_dir, "zpeek", "history" });
    defer a.free(history_file);
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(std.testing.io, std.fs.path.dirname(history_file).?);
    try cwd.writeFile(std.testing.io, .{ .sub_path = history_file, .data = "/connect postgres://user:secret@localhost/db\x00" });

    var app: App = .{
        .gpa = a,
        .io = std.testing.io,
        .env = &env,
        .cfg = .{ .path = "", .found = false },
        .editor = .init(a),
        .transcript = .init(a),
        .conn_arena = .init(a),
        .popup_arena = .init(a),
        .frame_arena = .init(a),
    };
    defer app.deinit();
    try app.loadHistory();
    try std.testing.expectEqual(@as(usize, 1), app.editor.history.items.len);
    try std.testing.expectEqualStrings("/connect <redacted>", app.editor.history.items[0]);
    app.saveHistory();
    // Persistence streams directly to disk and can be repeated without consuming the path.
    try app.editor.commitHistoryText("select 42");
    var failing: std.testing.FailingAllocator = .init(a, .{ .fail_index = 0 });
    app.gpa = failing.allocator();
    app.saveHistory();
    app.gpa = a;
    try std.testing.expectEqual(@as(usize, 0), failing.alloc_index);
    try std.testing.expect(!failing.has_induced_failure);
    const saved = try cwd.readFileAlloc(std.testing.io, history_file, a, .limited(1024));
    defer a.free(saved);
    try std.testing.expectEqualStrings("/connect <redacted>\x00select 42\x00", saved);
}

// ───────────────────────────── events ─────────────────────────────

fn handleEvent(app: *App, event: Event) !void {
    switch (event) {
        .winsize => |ws| try app.vx.resize(app.gpa, app.tty.writer(), ws),
        .tick => {
            app.spinner +%= 1;
            if (app.job) |job| {
                if (job.kind == .connect and !job.cancel_requested.load(.acquire) and
                    job.started.untilNow(app.io, .awake).toMilliseconds() >= connect_job_timeout_ms)
                {
                    app.cancelJob(true);
                }
            }
        },
        .job_done => app.finishJob(),
        .paste_start => app.pasting = true,
        .paste_end => {
            app.pasting = false;
            app.closePopup();
        },
        .paste => |text| {
            defer app.gpa.free(text);
            if (app.config_edit) |*edit| edit.discard_armed = false;
            if (app.picker) |p| {
                _ = try p.handleKey(.{ .codepoint = 0, .text = text });
                return;
            }
            if (app.mode == .console or app.mode == .config) try app.editor.insertPaste(text);
        },
        .focus_in => {},
        .mouse => |m| app.handleMouse(m),
        .key_press => |key| try app.handleKey(key),
    }
}

fn handleMouse(app: *App, m: vaxis.Mouse) void {
    const delta: isize = switch (m.button) {
        .wheel_up => -3,
        .wheel_down => 3,
        else => return,
    };
    switch (app.mode) {
        .console => app.transcript.scrollBy(-delta, app.transcriptHeight()),
        .table => if (app.table_view) |tv| {
            if (delta < 0) tv.row -|= 3 else tv.row = @min(tv.row + 3, tv.view.items.len -| 1);
        },
        .picker, .config => {},
    }
}

fn handleKey(app: *App, key: vaxis.Key) !void {
    if (app.pasting) {
        if (app.picker) |p| {
            if (key.text) |text| _ = try p.handleKey(.{ .codepoint = 0, .text = text });
            return;
        }
        if (app.mode != .console and app.mode != .config) return;
        if (key.matches(vaxis.Key.enter, .{}) or key.matches('j', .{ .ctrl = true })) {
            try app.editor.insert("\n");
        } else if (key.matches(vaxis.Key.tab, .{})) {
            try app.editor.insert("    ");
        } else if (key.text) |t| {
            try app.editor.insert(t);
        }
        return;
    }

    switch (app.mode) {
        .picker => return app.handlePickerKey(key),
        .table => return app.handleTableKey(key),
        .console, .config => {},
    }

    const editing_config = app.mode == .config;
    if (editing_config) {
        if (app.popup != null and try app.handlePopupKey(key)) return;
        if (key.matches(vaxis.Key.f1, .{})) {
            app.config_edit.?.show_help = !app.config_edit.?.show_help;
            return;
        }
        if (app.config_edit.?.show_help) {
            if (key.matches(vaxis.Key.page_down, .{})) {
                app.config_edit.?.help_top = @min(app.config_edit.?.help_top + app.config_edit.?.help_page_size, config_help.len - 1);
                return;
            }
            if (key.matches(vaxis.Key.page_up, .{})) {
                app.config_edit.?.help_top -|= app.config_edit.?.help_page_size;
                return;
            }
        }
        if (key.matches('s', .{ .ctrl = true })) return app.saveConfigEditor();
        if (key.matches(vaxis.Key.escape, .{}) or key.matches('c', .{ .ctrl = true })) {
            const edit = &app.config_edit.?;
            if (!edit.discard_armed and !std.mem.eql(u8, app.editor.text(), edit.original orelse config.example)) {
                edit.discard_armed = true;
                return app.configNotice("Unsaved changes — press esc again to discard, or ctrl+s to save");
            }
            app.closeConfigEditor();
            return;
        }
        app.config_edit.?.discard_armed = false;
        if (key.matches(vaxis.Key.enter, .{}) or key.matches('j', .{ .ctrl = true })) return app.editor.insert("\n");
        if (key.matches(vaxis.Key.tab, .{})) return app.openCompletion(true);
        if (key.matches(vaxis.Key.up, .{}) or key.matches('p', .{ .ctrl = true })) {
            app.editor.up();
            return;
        }
        if (key.matches(vaxis.Key.down, .{}) or key.matches('n', .{ .ctrl = true })) {
            app.editor.down();
            return;
        }
        if (key.matches('d', .{ .ctrl = true }) or key.matches('y', .{ .ctrl = true }) or
            key.matches('r', .{ .ctrl = true }) or key.matches('o', .{ .ctrl = true }) or key.matches('l', .{ .ctrl = true }) or
            key.matches(vaxis.Key.page_up, .{}) or key.matches(vaxis.Key.page_down, .{}) or
            key.matches(vaxis.Key.up, .{ .shift = true }) or key.matches(vaxis.Key.down, .{ .shift = true })) return;
        if (key.matches('r', .{ .alt = true })) return;
    }

    const exit_was_armed = app.exit_armed;
    app.exit_armed = false;

    if (key.matches('c', .{ .ctrl = true })) {
        if (app.job != null) {
            app.cancelJob(false);
        } else if (app.popup != null) {
            app.closePopup();
        } else if (!app.editor.isEmpty()) {
            app.editor.clear();
        } else if (exit_was_armed) {
            app.running = false;
        } else {
            app.exit_armed = true;
        }
        return;
    }
    if (key.matches('d', .{ .ctrl = true }) and app.editor.isEmpty()) {
        app.running = false;
        return;
    }
    if (key.matches('y', .{ .ctrl = true })) {
        return app.copyQuery(if (app.editor.isEmpty()) app.sqlToCopy() else app.editor.text());
    }
    if (key.matches('s', .{ .ctrl = true })) return app.saveQuery("");
    if (key.matches('r', .{ .ctrl = true })) {
        app.closePopup();
        return app.openQueriesPicker();
    }
    if (key.matches('r', .{ .alt = true })) {
        app.closePopup();
        return app.openHistory("");
    }

    if (app.popup != null) {
        if (try app.handlePopupKey(key)) return;
    }

    const e = &app.editor;
    if (key.matches(vaxis.Key.enter, .{ .alt = true }) or key.matches(vaxis.Key.enter, .{ .shift = true }) or
        key.matches('j', .{ .ctrl = true }))
    {
        try e.insert("\n");
    } else if (key.matches(vaxis.Key.enter, .{})) {
        // A trailing backslash continues the input on a new line.
        if (std.mem.endsWith(u8, e.text()[0..e.cursor], "\\")) {
            e.backspace();
            try e.insert("\n");
        } else {
            try app.submit();
        }
        return;
    } else if (key.matches(vaxis.Key.tab, .{})) {
        try app.openCompletion(true);
        return;
    } else if (key.matches(vaxis.Key.up, .{}) or key.matches('p', .{ .ctrl = true })) {
        if (e.onFirstLine()) try e.historyPrev() else e.up();
    } else if (key.matches(vaxis.Key.down, .{}) or key.matches('n', .{ .ctrl = true })) {
        if (e.onLastLine()) try e.historyNext() else e.down();
    } else if (key.matches(vaxis.Key.left, .{}) or key.matches('b', .{ .ctrl = true })) {
        e.left();
    } else if (key.matches(vaxis.Key.right, .{}) or key.matches('f', .{ .ctrl = true })) {
        e.right();
    } else if (key.matches(vaxis.Key.left, .{ .alt = true }) or key.matches('b', .{ .alt = true }) or key.matches(vaxis.Key.left, .{ .ctrl = true })) {
        e.wordLeft();
    } else if (key.matches(vaxis.Key.right, .{ .alt = true }) or key.matches('f', .{ .alt = true }) or key.matches(vaxis.Key.right, .{ .ctrl = true })) {
        e.wordRight();
    } else if (key.matches(vaxis.Key.home, .{}) or key.matches('a', .{ .ctrl = true })) {
        e.home();
    } else if (key.matches(vaxis.Key.end, .{}) or key.matches('e', .{ .ctrl = true })) {
        e.end();
    } else if (key.matches(vaxis.Key.backspace, .{}) or key.matches('h', .{ .ctrl = true })) {
        e.backspace();
    } else if (key.matches(vaxis.Key.backspace, .{ .alt = true }) or key.matches('w', .{ .ctrl = true })) {
        e.deleteWordLeft();
    } else if (key.matches(vaxis.Key.delete, .{})) {
        e.deleteForward();
    } else if (key.matches('u', .{ .ctrl = true })) {
        e.killToLineStart();
    } else if (key.matches('k', .{ .ctrl = true })) {
        e.killToLineEnd();
    } else if (key.matches('l', .{ .ctrl = true })) {
        app.transcript.clear();
        app.vx.queueRefresh();
    } else if (key.matches('o', .{ .ctrl = true })) {
        try app.openLastResult();
    } else if (key.matches(vaxis.Key.page_up, .{}) or key.matches(vaxis.Key.up, .{ .shift = true })) {
        const step: isize = if (key.codepoint == vaxis.Key.page_up) @intCast(app.transcriptHeight() -| 2) else 1;
        app.transcript.scrollBy(step, app.transcriptHeight());
    } else if (key.matches(vaxis.Key.page_down, .{}) or key.matches(vaxis.Key.down, .{ .shift = true })) {
        const step: isize = if (key.codepoint == vaxis.Key.page_down) @intCast(app.transcriptHeight() -| 2) else 1;
        app.transcript.scrollBy(-step, app.transcriptHeight());
    } else if (key.matches(vaxis.Key.escape, .{})) {
        app.closePopup();
    } else if (key.text) |t| {
        if (!key.mods.ctrl and !(key.mods.alt and t.len == 1)) {
            try e.insert(t);
            if (editing_config) return app.openCompletion(false);
            if (std.mem.startsWith(u8, e.text(), "/")) {
                try app.openCompletion(false);
            } else if (app.conn != null) {
                // SQL suggestions follow typing (keywords for the dialect,
                // tables after FROM, columns after WHERE, operators).
                try app.openCompletion(false);
                if (app.popup) |p| {
                    if (!p.completion.auto or p.completion.exact_match) app.closePopup();
                }
            }
        }
    }
}

/// Returns true when the popup consumed the key.
fn handlePopupKey(app: *App, key: vaxis.Key) !bool {
    const p = &(app.popup orelse return false);
    const n = p.completion.candidates.len;
    if (key.matches(vaxis.Key.down, .{}) or key.matches('n', .{ .ctrl = true })) {
        p.selected = (p.selected + 1) % n;
        p.navigated = true;
        return true;
    }
    if (key.matches(vaxis.Key.up, .{}) or key.matches('p', .{ .ctrl = true })) {
        p.selected = (p.selected + n - 1) % n;
        p.navigated = true;
        return true;
    }
    if (key.matches(vaxis.Key.tab, .{}) or key.matches(vaxis.Key.enter, .{})) {
        const is_enter = key.matches(vaxis.Key.enter, .{});
        const cand = p.completion.candidates[p.selected];
        // Enter on an already complete slash command runs it.
        if (is_enter and cand.kind == .command and p.completion.replace_len == cand.text.len) {
            app.closePopup();
            return false;
        }
        // While the list is open, Enter inserts the selected suggestion (like
        // Tab). The list closes on space or punctuation, and it does not open
        // for an already complete word, so Enter then runs the query.
        try app.acceptCandidate(cand, p.completion.replace_len, p.completion.replace_after);
        return true;
    }
    if (key.matches(vaxis.Key.escape, .{})) {
        app.closePopup();
        return true;
    }
    if (key.matches(vaxis.Key.backspace, .{})) {
        app.editor.backspace();
        try app.openCompletion(false);
        return true;
    }
    if (key.text) |t| {
        if (!key.mods.ctrl and !key.mods.alt) {
            try app.editor.insert(t);
            if (app.mode == .config) {
                try app.openCompletion(false);
                return true;
            }
            // keep filtering while typing identifier characters
            if (t.len == 1 and !lexer.isIdentChar(t[0]) and t[0] != '/' and t[0] != '.') {
                app.closePopup();
            } else {
                try app.openCompletion(false);
                if (app.popup) |np| {
                    const is_command = std.mem.startsWith(u8, app.editor.text(), "/");
                    if (!is_command and (np.completion.exact_match or !np.completion.auto)) app.closePopup();
                }
            }
            return true;
        }
    }
    app.closePopup();
    return false;
}

fn acceptCandidate(app: *App, cand: complete.Candidate, replace_len: usize, replace_after: usize) Allocator.Error!void {
    var text = cand.text;
    var cursor_back: usize = 0;
    const a = app.popup_arena.allocator();
    if (cand.kind == .table or cand.kind == .column) text = try app.maybeQuote(a, text);
    if (cand.kind == .command) {
        const cmd = findCommand(text);
        if (cmd != null and cmd.?.args.len > 0) text = try std.mem.concat(a, u8, &.{ text, " " });
    }
    if (cand.kind == .operator) {
        const snippet = complete.operatorSnippet(text);
        text = try std.mem.concat(a, u8, &.{ text, snippet.suffix });
        cursor_back = snippet.cursor_back;
    }
    if (cand.kind == .keyword) text = try std.mem.concat(a, u8, &.{ text, " " });
    if (replace_after > 0) try app.editor.buf.replaceRange(app.gpa, app.editor.cursor, replace_after, "");
    try app.editor.replaceBeforeCursorAndMove(replace_len, text, cursor_back);
    app.closePopup();
    if (cand.kind == .config_key and std.mem.endsWith(u8, text, " = ")) return app.openCompletion(false);
    // Show what can follow right away: tables after FROM, columns after WHERE…
    if ((cand.kind == .command or cand.kind == .keyword) and std.mem.endsWith(u8, text, " ")) {
        try app.openCompletion(false);
        if (app.popup) |p| {
            if (!p.completion.auto) app.closePopup();
        }
    }
}

/// Quotes identifiers that are not plain lowercase names.
fn maybeQuote(app: *App, a: Allocator, name: []const u8) Allocator.Error![]const u8 {
    const kind = if (app.conn) |c| c.kind else conninfo.Kind.postgres;
    var plain = name.len > 0 and !std.ascii.isDigit(name[0]);
    for (name) |c| {
        if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '_' or c == '.')) plain = false;
    }
    // MySQL and ClickHouse accept mixed-case bare identifiers.
    if ((kind == .mysql or kind == .clickhouse) and !lexer.isKeyword(name)) {
        for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '.')) return schema.quoteName(a, kind, name);
        return name;
    }
    if (plain and !lexer.isKeyword(name)) return name;
    if (std.mem.indexOfScalar(u8, name, '.') != null) return schema.quoteName(a, kind, name);
    return schema.quoteIdent(a, kind, name);
}

fn openCompletion(app: *App, explicit: bool) Allocator.Error!void {
    app.closePopup();
    _ = app.popup_arena.reset(.{ .retain_with_limit = render.scratch_limit });
    const a = app.popup_arena.allocator();
    const input = app.editor.text();
    const name_end = std.mem.indexOfAny(u8, input, " \t\n") orelse input.len;
    const command = findCommand(input[0..name_end]);
    var names: std.ArrayList([]const u8) = .empty;
    if (app.mode == .config or (command != null and command.?.arg == .connection)) {
        for (app.cfg.connections) |c| try names.append(a, c.name);
    }
    const result = if (app.mode == .config) try complete.configComplete(a, app.editor.text(), app.editor.cursor, names.items) else try complete.complete(a, .{
        .text = app.editor.text(),
        .cursor = app.editor.cursor,
        .cache = if (app.cache) |*c| c else null,
        .connections = names.items,
        .queries = if (command != null and command.?.arg == .query) try app.savedQueryNames(a) else &.{},
        .commands = &commands,
        .kind = if (app.conn) |conn| conn.kind else null,
    });
    if (result.candidates.len == 0 or (app.mode == .config and !explicit and (!result.auto or result.exact_match))) {
        app.popup = null;
        return;
    }
    if (explicit and result.candidates.len == 1) {
        try app.acceptCandidate(result.candidates[0], result.replace_len, result.replace_after);
        return;
    }
    if (explicit and app.mode != .config) {
        // Insert the longest common prefix right away.
        const lcp = commonPrefix(result.candidates);
        if (lcp.len > result.replace_len) {
            const typed = app.editor.text()[app.editor.cursor - result.replace_len .. app.editor.cursor];
            if (std.ascii.startsWithIgnoreCase(lcp, typed)) {
                try app.editor.replaceBeforeCursor(result.replace_len, lcp);
                return app.openCompletion(false);
            }
        }
    }
    app.popup = .{ .completion = result };
}

fn commonPrefix(cands: []const complete.Candidate) []const u8 {
    var p = cands[0].text;
    for (cands[1..]) |c| {
        var i: usize = 0;
        while (i < p.len and i < c.text.len and p[i] == c.text[i]) i += 1;
        p = p[0..i];
    }
    return p;
}

fn closePopup(app: *App) void {
    app.popup = null;
}

fn handlePickerKey(app: *App, key: vaxis.Key) !void {
    const p = app.picker.?;
    switch (try p.handleKey(key)) {
        .none => {},
        .cancel => app.closePicker(),
        .choose => |i| {
            const label = p.items[i].label;
            const purpose = p.purpose;
            switch (purpose) {
                .connect => {
                    const name = try app.gpa.dupe(u8, p.items[i].label);
                    defer app.gpa.free(name);
                    app.closePicker();
                    try app.transcript.add(.{ .input = try app.tmpPrint("/connect {s}", .{name}) });
                    try app.connectTarget(name);
                },
                .browse, .describe => {
                    const name = try app.gpa.dupe(u8, label);
                    defer app.gpa.free(name);
                    app.closePicker();
                    if (purpose == .browse) try app.startBrowse(name, "") else try app.startDescribe(name);
                },
                .definition => {
                    try app.startDefinitionSql(label, p.items[i].value);
                    app.closePicker();
                },
                .type_value => {
                    try app.transcript.add(.{ .code = p.items[i].value });
                    app.closePicker();
                },
                .query => {
                    const name = try app.gpa.dupe(u8, label);
                    defer app.gpa.free(name);
                    app.closePicker();
                    try app.loadSavedQuery(name);
                },
                .history => {
                    try app.editor.setText(p.items[i].value);
                    app.editor.history_pos = null;
                    app.closePicker();
                },
                .confirm_sql => {
                    if (i == 1) try app.executeSql(p.items[i].value, true);
                    app.closePicker();
                },
                .export_format => {
                    const format: exporter.Format = if (i == 0) .csv else .json;
                    app.closePicker();
                    try app.openExportPath(format);
                },
                .export_csv, .export_json => {},
                .save_query, .overwrite_query => {
                    const name = try app.gpa.dupe(u8, if (purpose == .overwrite_query) p.items[i].value else label);
                    defer app.gpa.free(name);
                    app.closePicker();
                    if (name.len > 0) try app.writeSavedQuery(name, purpose == .overwrite_query);
                },
            }
        },
        .raw => |text| {
            const purpose = p.purpose;
            const t = try app.gpa.dupe(u8, text);
            defer app.gpa.free(t);
            app.closePicker();
            if (purpose == .export_csv or purpose == .export_json) {
                try app.exportResult(if (purpose == .export_csv) .csv else .json, t);
            } else if (purpose == .save_query) try app.writeSavedQuery(t, false) else try app.connectTarget(t);
        },
    }
}

fn closePicker(app: *App) void {
    const returning_to_table = if (app.picker) |p| app.export_table and (p.purpose == .export_format or p.purpose == .export_csv or p.purpose == .export_json) else false;
    if (app.picker) |p| p.deinit();
    app.picker = null;
    app.mode = if (returning_to_table and app.table_view != null) .table else .console;
}

fn handleTableKey(app: *App, key: vaxis.Key) !void {
    const tv = app.table_view.?;
    if (app.job != null) {
        if (key.matches('c', .{ .ctrl = true })) {
            if (app.conn) |c| c.cancel();
        }
        return;
    }
    if (key.matches('e', .{}) and !tv.editing_filter and tv.chooser == null and !tv.detail and tv.confirm_delete == null) {
        app.export_table = true;
        app.picker = try Picker.init(app.gpa, .export_format, "Export current view · retained rows and visible columns", &.{ .{ .label = "CSV" }, .{ .label = "JSON" } }, false);
        app.mode = .picker;
        return;
    }
    const action = try tv.handleKey(key);
    // After a failed reconnect the viewer stays open without a connection.
    if (app.conn == null) switch (action) {
        .reload, .count, .follow_fk, .delete_row => {
            switch (action) {
                .follow_fk, .delete_row => |sql| app.gpa.free(sql),
                else => {},
            }
            tv.notice = "not connected — close with q and use /connect";
            return;
        },
        else => {},
    };
    switch (action) {
        .none => {},
        .close => {
            tv.deinit();
            app.table_view = null;
            app.mode = .console;
        },
        .reload => try app.startBrowseReload(),
        .count => try app.startBrowseCount(),
        .follow_fk => |sql| {
            defer app.gpa.free(sql);
            const job = try app.newJob(.browse_fk);
            job.sqls = try job.arena.allocator().dupe([]const u8, &.{try job.arena.allocator().dupe(u8, sql)});
            try app.startJob(job);
        },
        .copy => |text| {
            try app.vx.copyToSystemClipboard(app.tty.writer(), text, app.gpa);
            tv.notice = "copied to clipboard";
        },
        .notice => |n| tv.notice = n,
        .delete_row => |sql| {
            defer app.gpa.free(sql);
            if (app.readOnly()) {
                tv.notice = "read-only connection — row delete is disabled";
                return;
            }
            const job = try app.newJob(.browse_delete);
            job.sqls = try job.arena.allocator().dupe([]const u8, &.{try job.arena.allocator().dupe(u8, sql)});
            try app.startJob(job);
        },
    }
}

// ───────────────────────────── commands ─────────────────────────────

fn submit(app: *App) !void {
    const raw = std.mem.trim(u8, app.editor.text(), " \t\r\n");
    if (raw.len == 0) return;
    if (raw[0] != '/') {
        if (app.job != null) return app.transcript.addMessage(.warn, "a query is still running (ctrl+c cancels it)", .{});
        if (app.conn == null) return app.transcript.addMessage(.err, "not connected — use /connect", .{});
    }
    app.closePopup();
    const text = try app.gpa.dupe(u8, raw);
    defer app.gpa.free(text);
    const visible_text = redactConnectionInput(text);
    try app.editor.commitHistoryText(visible_text);
    app.editor.clear();
    try app.transcript.add(.{ .input = visible_text });

    if (text[0] == '/') return app.runCommand(text);
    return app.executeSql(text, false);
}

fn executeSql(app: *App, text: []const u8, approved: bool) !void {
    const conn = app.conn orelse return app.transcript.addMessage(.err, "not connected — use /connect", .{});
    if (app.job != null) return app.transcript.addMessage(.warn, "busy — wait for the running query", .{});

    var stmts: std.ArrayList([]const u8) = .empty;
    defer stmts.deinit(app.gpa);
    const dialect: lexer.Dialect = switch (conn.kind) {
        .postgres => .postgres,
        .mysql => .mysql,
        .sqlite => .sqlite,
        // Backslash escapes in strings, like MySQL.
        .clickhouse => .mysql,
    };
    if ((if (app.conn_params) |p| p.access else conn.access).violation(text, dialect)) |word| {
        if (app.readOnly()) return app.transcript.addMessage(.err, read_only_message, .{word});
        return app.transcript.addMessage(.err, read_delete_message, .{word});
    }
    if (lexer.hasDeleteWithoutWhere(text, dialect)) {
        return app.transcript.addMessage(.err, "{s}", .{delete_without_where_message});
    }
    const access = if (app.conn_params) |p| p.access else conn.access;
    if (!approved and access == .full) if (lexer.dangerousStatement(text, dialect)) |word| {
        app.picker = try Picker.init(app.gpa, .confirm_sql, "Confirm full-access SQL · review before running", &.{
            .{ .label = "Cancel", .detail = "keep the database unchanged" },
            .{ .label = "Run SQL", .detail = word, .value = text },
        }, false);
        app.mode = .picker;
        return;
    };
    try lexer.splitStatements(text, dialect, &stmts, app.gpa);
    if (stmts.items.len == 0) return;
    const job = try app.newJob(.console);
    const a = job.arena.allocator();
    const sqls = try a.alloc([]const u8, stmts.items.len);
    for (stmts.items, sqls) |s, *d| d.* = try a.dupe(u8, s);
    job.sqls = sqls;
    job.max_rows = console_row_limit;
    app.last_sql.clearRetainingCapacity();
    try app.last_sql.appendSlice(app.gpa, text);
    try app.startJob(job);
}

// ───────────────────────────── saved queries ─────────────────────────────

fn openHistory(app: *App, search: []const u8) !void {
    const a = app.frame_arena.allocator();
    var items: std.ArrayList(Picker.Item) = .empty;
    var i = app.editor.history.items.len;
    while (i > 0) {
        i -= 1;
        const sql = app.editor.history.items[i];
        if (sql.len == 0 or sql[0] == '/') continue;
        const first_line = sql[0 .. std.mem.indexOfScalar(u8, sql, '\n') orelse sql.len];
        try items.append(a, .{ .label = try std.fmt.allocPrint(a, "#{d}", .{i + 1}), .detail = first_line, .value = sql });
    }
    if (items.items.len == 0) return app.transcript.addMessage(.dim, "no SQL history yet — type a query first", .{});
    const p = try Picker.init(app.gpa, .history, "SQL history · newest first · type to search · enter loads", items.items, false);
    errdefer p.deinit();
    if (search.len > 0) _ = try p.handleKey(.{ .codepoint = 0, .text = search });
    app.picker = p;
    app.mode = .picker;
}

fn openExportPath(app: *App, format: exporter.Format) !void {
    app.picker = try Picker.init(app.gpa, if (format == .csv) .export_csv else .export_json, "Export · type a new file path · existing files are never overwritten", &.{}, true);
    app.mode = .picker;
}

fn exportResult(app: *App, format: exporter.Format, path: []const u8) !void {
    const result = if (app.export_table and app.table_view != null) app.table_view.?.result else app.transcript.lastResult() orelse
        return app.transcript.addMessage(.warn, "no result to export — run a query first", .{});
    const selection: exporter.Selection = if (app.export_table and app.table_view != null)
        .{ .rows = app.table_view.?.view.items, .columns = app.table_view.?.visible.items }
    else
        .{};
    exporter.save(app.io, path, result.*, format, selection) catch |err| {
        if (app.export_table) {
            if (app.table_view) |tv| {
                app.notice.clearRetainingCapacity();
                try app.notice.print(app.gpa, "export failed: {t}", .{err});
                tv.notice = app.notice.items;
            }
        }
        return app.transcript.addMessage(.err, "cannot export: {t} — use a new path; JSON columns need unique names", .{err});
    };
    if (app.export_table) {
        if (app.table_view) |tv| tv.notice = "exported current view (retained rows only)";
    }
    try app.transcript.addMessage(.ok, "exported {d} retained rows to {s}{s}", .{
        if (selection.rows) |rows| rows.len else result.rows.len,
        path,
        if (result.truncated) " (source result was truncated)" else "",
    });
}

fn startExplain(app: *App, query: []const u8) !void {
    const source = if (query.len > 0) query else app.last_sql.items;
    if (source.len == 0) return app.transcript.addMessage(.err, "usage: /explain <SQL> — or run a query first", .{});
    const sql = plan.sql(app.frame_arena.allocator(), app.conn.?.kind, source) catch |err| {
        return app.transcript.addMessage(.err, "cannot explain: {t} — supply one SELECT or DML statement; ANALYZE is not enabled", .{err});
    };
    const job = try app.newJob(.explain);
    const a = job.arena.allocator();
    job.sqls = try a.dupe([]const u8, &.{try a.dupe(u8, sql)});
    job.max_rows = console_row_limit;
    try app.startJob(job);
}

fn queriesDir(app: *App) !?[]const u8 {
    return queries.dirPath(app.frame_arena.allocator(), app.cfg.path);
}

fn savedQueryNames(app: *App, a: Allocator) ![]const []const u8 {
    const dir = (try app.queriesDir()) orelse return &.{};
    const entries = queries.list(a, app.io, dir, false) catch return &.{};
    const names = try a.alloc([]const u8, entries.len);
    for (entries, names) |e, *n| n.* = e.name;
    return names;
}

fn sqlToCopy(app: *const App) []const u8 {
    var i = app.transcript.entries.items.len;
    while (i > 0) {
        i -= 1;
        switch (app.transcript.entries.items[i].content) {
            .code => |sql| return sql,
            .input => |text| if (!std.mem.startsWith(u8, text, "/")) break,
            else => {},
        }
    }
    return app.last_sql.items;
}

fn copyQuery(app: *App, sql: []const u8) !void {
    if (sql.len == 0) return app.transcript.addMessage(.warn, "nothing to copy — type or run an SQL query first", .{});
    app.vx.copyToSystemClipboard(app.tty.writer(), sql, app.gpa) catch |err| {
        return app.transcript.addMessage(.err, "cannot copy query: {t}", .{err});
    };
    try app.transcript.addMessage(.ok, "query copied to clipboard", .{});
}

test "copy command and shortcut preserve SQL and handle empty input" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var app: App = .{
        .gpa = a,
        .io = std.testing.io,
        .env = &env,
        .cfg = .{ .path = "", .found = false },
        .editor = .init(a),
        .transcript = .init(a),
        .conn_arena = .init(a),
        .popup_arena = .init(a),
        .frame_arena = .init(a),
    };
    defer app.deinit();
    app.tty = try vaxis.Tty.init(app.io, &app.tty_buf);
    defer app.tty.deinit();
    var output: [1024]u8 = undefined;
    const writer = app.tty.writer();
    const original_writer = writer.*;
    writer.* = .fixed(&output);
    defer writer.* = original_writer;
    app.vx = try vaxis.init(app.io, a, &env, .{});
    defer app.vx.deinit(a, writer);

    try app.runCommand("/copy");
    try app.handleKey(.{ .codepoint = 'y', .mods = .{ .ctrl = true } });
    try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);
    try std.testing.expectEqual(.warn, app.transcript.entries.items[0].content.message.kind);
    try std.testing.expectEqual(.warn, app.transcript.entries.items[1].content.message.kind);

    const sql = "select 'Привет';\nselect 2;";
    try app.last_sql.appendSlice(a, "select 1;");
    try app.editor.setText(sql);
    try app.handleKey(.{ .codepoint = 'y', .mods = .{ .ctrl = true } });
    try std.testing.expectEqualStrings(sql, app.editor.text());
    app.editor.clear();
    try app.handleKey(.{ .codepoint = 'y', .mods = .{ .ctrl = true } });
    try app.runCommand("/copy");
    try std.testing.expectEqualStrings(
        "\x1b]52;c;c2VsZWN0ICfQn9GA0LjQstC10YInOwpzZWxlY3QgMjs=\x1b\\" ++
            "\x1b]52;c;c2VsZWN0IDE7\x1b\\" ++
            "\x1b]52;c;c2VsZWN0IDE7\x1b\\",
        writer.buffered(),
    );

    var db_error: db.ErrorText = .{};
    defer db_error.deinit(a);
    app.conn = try @import("../db/sqlite.zig").connect(a, .{ .kind = .sqlite, .database = ":memory:" }, &db_error);
    const definition = "CREATE VIEW recent_orders AS SELECT 1";
    var setup = try app.conn.?.query(a, definition);
    defer setup.deinit();
    var views = try app.conn.?.query(a, schema.listSql(.sqlite, .views).?);
    defer views.deinit();
    app.loop = .init(app.io, &app.tty, &app.vx);
    try app.openObjectPicker(.views, views);
    try app.handlePickerKey(.{ .codepoint = vaxis.Key.enter });
    app.job.?.future.await(app.io);
    app.finishJob();
    try std.testing.expectEqualStrings(definition, app.sqlToCopy());
    // /copy itself must not hide the displayed definition.
    try app.transcript.add(.{ .input = "/copy" });
    var encoded: [128]u8 = undefined;
    const expected = try std.fmt.allocPrint(a, "\x1b]52;c;{s}\x1b\\", .{std.base64.standard.Encoder.encode(&encoded, definition)});
    defer a.free(expected);
    writer.end = 0;
    try app.runCommand("/copy");
    try std.testing.expectEqualStrings(expected, writer.buffered());
    writer.end = 0;
    try app.handleKey(.{ .codepoint = 'y', .mods = .{ .ctrl = true } });
    try std.testing.expectEqualStrings(expected, writer.buffered());
    try std.testing.expectEqualStrings("select 1;", app.last_sql.items);
    try app.transcript.add(.{ .input = "select 1;" });
    try std.testing.expectEqualStrings("select 1;", app.sqlToCopy());
}

test "saved query shortcuts preserve drafts and confirm replacement" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "config.toml" });
    defer a.free(path);
    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();
    var app: App = .{
        .gpa = a,
        .io = std.testing.io,
        .env = &env,
        .cfg = .{ .path = path, .found = false },
        .editor = .init(a),
        .transcript = .init(a),
        .conn_arena = .init(a),
        .popup_arena = .init(a),
        .frame_arena = .init(a),
    };
    defer app.deinit();
    const sql = "select *\nfrom people;";
    try app.editor.setText(sql);
    try app.handleKey(.{ .codepoint = 's', .mods = .{ .ctrl = true } });
    try std.testing.expectEqual(Picker.Purpose.save_query, app.picker.?.purpose);
    try app.handlePickerKey(.{ .codepoint = 'r', .text = "recent" });
    try app.handlePickerKey(.{ .codepoint = vaxis.Key.enter });
    try std.testing.expectEqualStrings(sql, app.editor.text());
    const dir = (try app.queriesDir()).?;
    try std.testing.expectEqualStrings(sql, try queries.load(app.frame_arena.allocator(), app.io, dir, "recent"));
    try app.editor.setText("select 2;");
    try app.saveQuery("recent");
    try std.testing.expectEqual(Picker.Purpose.overwrite_query, app.picker.?.purpose);
    try app.handlePickerKey(.{ .codepoint = vaxis.Key.enter });
    try std.testing.expectEqualStrings(sql, try queries.load(app.frame_arena.allocator(), app.io, dir, "recent"));
    try app.handleKey(.{ .codepoint = 'r', .mods = .{ .ctrl = true } });
    try app.handlePickerKey(.{ .codepoint = 'p', .text = "people" });
    try std.testing.expectEqual(@as(usize, 1), app.picker.?.matches.items.len);
    try app.handlePickerKey(.{ .codepoint = vaxis.Key.escape });
    try std.testing.expectEqualStrings("select 2;", app.editor.text());
    try app.handleKey(.{ .codepoint = 'r', .mods = .{ .ctrl = true } });
    try app.handlePickerKey(.{ .codepoint = vaxis.Key.enter });
    try std.testing.expectEqualStrings(sql, app.editor.text());
    try std.testing.expect(app.conn == null);
    try app.editor.setText("select 2;");
    try app.saveQuery("recent");
    try app.handlePickerKey(.{ .codepoint = vaxis.Key.down });
    try app.handlePickerKey(.{ .codepoint = vaxis.Key.enter });
    try std.testing.expectEqualStrings("select 2;", try queries.load(app.frame_arena.allocator(), app.io, dir, "recent"));
    try app.editor.setText("select 3;");
    try app.runCommand("/save");
    try app.handlePickerKey(.{ .codepoint = 'r', .text = "rec" });
    try app.handlePickerKey(.{ .codepoint = vaxis.Key.enter });
    try std.testing.expectEqualStrings("select 3;", try queries.load(app.frame_arena.allocator(), app.io, dir, "rec"));
}

fn saveQuery(app: *App, name: []const u8) !void {
    const input = std.mem.trim(u8, app.editor.text(), " \t\r\n");
    const sql = if (input.len > 0 and input[0] != '/') input else app.last_sql.items;
    if (sql.len == 0) return app.transcript.addMessage(.warn, "nothing to save — type SQL first, then press ctrl+s", .{});
    app.pending_save.clearRetainingCapacity();
    try app.pending_save.appendSlice(app.gpa, sql);
    app.closePopup();
    if (name.len > 0) return app.writeSavedQuery(name, false);
    const dir = (try app.queriesDir()) orelse return app.transcript.addMessage(.err, "cannot determine the config directory", .{});
    const a = app.frame_arena.allocator();
    const entries = queries.list(a, app.io, dir, true) catch |err| return app.transcript.addMessage(.err, "cannot read saved queries: {t}", .{err});
    var items: std.ArrayList(Picker.Item) = .empty;
    for (entries) |entry| try items.append(a, .{ .label = entry.name, .detail = entry.preview });
    app.picker = try Picker.init(app.gpa, .save_query, "Save query · type a name · enter saves · tab selects · esc cancels", items.items, true);
    app.mode = .picker;
}

fn writeSavedQuery(app: *App, name: []const u8, overwrite: bool) !void {
    if (!queries.validName(name)) return app.transcript.addMessage(.err, "invalid query name — use letters, digits, '_', '-', '.' (up to 64 characters)", .{});
    const dir = (try app.queriesDir()) orelse return app.transcript.addMessage(.err, "cannot determine the config directory", .{});
    queries.save(app.io, dir, name, app.pending_save.items, overwrite) catch |err| {
        if (err == error.PathAlreadyExists and !overwrite) {
            app.picker = try Picker.init(app.gpa, .overwrite_query, "Query already exists · overwrite?", &.{
                .{ .label = "Cancel" },
                .{ .label = "Overwrite", .detail = name, .value = name },
            }, false);
            app.mode = .picker;
            return;
        }
        return app.transcript.addMessage(.err, "cannot save query: {t}", .{err});
    };
    try app.transcript.addMessage(.ok, "saved as '{s}' ({s}) — /queries to use it", .{ name, dir });
}

fn loadSavedQuery(app: *App, name: []const u8) !void {
    const dir = (try app.queriesDir()) orelse return;
    const sql = queries.load(app.frame_arena.allocator(), app.io, dir, name) catch {
        return app.transcript.addMessage(.err, "no saved query named '{s}'", .{name});
    };
    // Put it in the input for review instead of running it right away.
    try app.editor.setText(sql);
}

fn openQueriesPicker(app: *App) !void {
    const dir = (try app.queriesDir()) orelse return app.transcript.addMessage(.err, "cannot determine the config directory", .{});
    const a = app.frame_arena.allocator();
    const entries = queries.list(a, app.io, dir, true) catch |err| return app.transcript.addMessage(.err, "cannot read {s}: {t}", .{ dir, err });
    if (entries.len == 0) return app.transcript.addMessage(.dim, "no saved queries yet — type SQL and press ctrl+s to save it", .{});
    var items: std.ArrayList(Picker.Item) = .empty;
    for (entries) |e| try items.append(a, .{ .label = e.name, .detail = e.preview, .value = e.sql });
    app.picker = try Picker.init(app.gpa, .query, "Saved queries", items.items, false);
    app.mode = .picker;
}

pub const read_only_message = "read-only connection: only reading statements run ('{s}' was refused, nothing was run)";
pub const read_delete_message = "read-delete connection: only reading statements and DELETE with WHERE are allowed ('{s}' was refused, nothing was run)";

fn readOnly(app: *const App) bool {
    return if (app.conn_params) |p| p.access == .read_only else false;
}

/// A browse filter is a reading expression, never a second channel for SQL writes.
fn filterViolation(app: *App, filter: []const u8) !?[]const u8 {
    if (filter.len == 0) return null;
    const conn = app.conn orelse return null;
    const dialect: lexer.Dialect = switch (conn.kind) {
        .postgres => .postgres,
        .mysql, .clickhouse => .mysql,
        .sqlite => .sqlite,
    };
    return lexer.readOnlyViolation(try app.tmpPrint("select 1 where {s}", .{filter}), dialect);
}

pub const delete_without_where_message = "DELETE without WHERE is blocked: nothing was run. Add a WHERE clause (WHERE true deletes every row).";

fn redactConnectionInput(text: []const u8) []const u8 {
    const name_end = std.mem.indexOfAny(u8, text, " \t\n") orelse return text;
    const name = text[0..name_end];
    if (std.mem.eql(u8, name, "/config")) {
        var words = std.mem.tokenizeAny(u8, text[name_end..], " \t\r\n");
        if (words.next()) |action| {
            if (std.mem.eql(u8, action, "add")) return "/config add <redacted>";
        }
    }
    if (!std.mem.eql(u8, name, "/connect") and !std.mem.eql(u8, name, "/c")) return text;
    const arg = std.mem.trim(u8, text[name_end..], " \t\r\n");
    if (arg.len == 0 or !conninfo.isConnectionString(arg)) return text;
    return "/connect <redacted>";
}

test "connection URLs are redacted before display and history" {
    try std.testing.expectEqualStrings("/connect <redacted>", redactConnectionInput("/connect postgres://user:secret@localhost/db"));
    try std.testing.expectEqualStrings("/connect <redacted>", redactConnectionInput("/c ./private.sqlite"));
    try std.testing.expectEqualStrings("/connect production", redactConnectionInput("/connect production"));
    try std.testing.expectEqualStrings("/config add <redacted>", redactConnectionInput("/config add prod #ff0000 postgres://user:secret@localhost/db"));
    try std.testing.expectEqualStrings("/config remove prod", redactConnectionInput("/config remove prod"));
}

fn findCommand(name: []const u8) ?complete.Command {
    for (commands) |c| {
        if (std.mem.eql(u8, c.name, name)) return c;
        for (c.aliases) |al| if (std.mem.eql(u8, al, name)) return c;
    }
    return null;
}

fn runCommand(app: *App, text: []const u8) !void {
    const name_end = std.mem.indexOfAny(u8, text, " \t\n") orelse text.len;
    const name = text[0..name_end];
    const arg = std.mem.trim(u8, text[name_end..], " \t\r\n");
    const cmd = findCommand(name) orelse
        return app.transcript.addMessage(.err, "unknown command {s} — /help lists commands", .{name});

    const needs_conn = !(std.mem.eql(u8, cmd.name, "/help") or std.mem.eql(u8, cmd.name, "/connect") or
        std.mem.eql(u8, cmd.name, "/clear") or std.mem.eql(u8, cmd.name, "/quit") or
        std.mem.eql(u8, cmd.name, "/queries") or std.mem.eql(u8, cmd.name, "/save") or std.mem.eql(u8, cmd.name, "/unsave") or
        std.mem.eql(u8, cmd.name, "/copy") or std.mem.eql(u8, cmd.name, "/config") or std.mem.eql(u8, cmd.name, "/history") or std.mem.eql(u8, cmd.name, "/export"));
    if (needs_conn and app.conn == null) return app.transcript.addMessage(.err, "not connected — use /connect", .{});
    const needs_idle = !(std.mem.eql(u8, cmd.name, "/help") or std.mem.eql(u8, cmd.name, "/clear") or std.mem.eql(u8, cmd.name, "/quit") or
        std.mem.eql(u8, cmd.name, "/copy"));
    if (needs_idle and app.job != null) return app.transcript.addMessage(.warn, "busy — wait for the running query or press ctrl+c", .{});

    const eql = std.mem.eql;
    if (eql(u8, cmd.name, "/help")) return app.showHelp();
    if (eql(u8, cmd.name, "/config")) return app.configure(arg);
    if (eql(u8, cmd.name, "/history")) return app.openHistory(arg);
    if (eql(u8, cmd.name, "/explain")) return app.startExplain(arg);
    if (eql(u8, cmd.name, "/export")) {
        var args = std.mem.tokenizeAny(u8, arg, " \t");
        const format = std.meta.stringToEnum(exporter.Format, args.next() orelse "") orelse
            return app.transcript.addMessage(.err, "usage: /export <csv|json> [new-file-path]", .{});
        app.export_table = false;
        const path = std.mem.trim(u8, args.rest(), " \t");
        if (path.len == 0) return app.openExportPath(format);
        return app.exportResult(format, path);
    }
    if (eql(u8, cmd.name, "/quit")) {
        app.running = false;
        return;
    }
    if (eql(u8, cmd.name, "/clear")) {
        app.transcript.clear();
        app.vx.queueRefresh();
        return;
    }
    if (eql(u8, cmd.name, "/connect")) {
        if (arg.len == 0) return app.openConnectPicker();
        return app.connectTarget(arg);
    }
    if (eql(u8, cmd.name, "/disconnect")) {
        app.disconnect();
        return app.transcript.addMessage(.dim, "disconnected", .{});
    }
    if (eql(u8, cmd.name, "/tables")) return app.startList(.tables);
    if (eql(u8, cmd.name, "/views")) return app.startList(.views);
    if (eql(u8, cmd.name, "/types")) return app.startList(.types);
    if (eql(u8, cmd.name, "/functions")) return app.startList(.functions);
    if (eql(u8, cmd.name, "/triggers")) return app.startList(.triggers);
    if (eql(u8, cmd.name, "/describe")) {
        if (arg.len == 0) return app.openTablePicker(.describe);
        return app.startDescribe(arg);
    }
    if (eql(u8, cmd.name, "/browse")) {
        if (arg.len == 0) return app.openTablePicker(.browse);
        const split = splitBrowseArg(arg);
        return app.startBrowse(split.table, split.filter);
    }
    if (eql(u8, cmd.name, "/def")) {
        if (arg.len == 0) return app.transcript.addMessage(.err, "usage: /def <name>", .{});
        return app.startDefinition(arg);
    }
    if (eql(u8, cmd.name, "/databases")) {
        const sql = schema.databasesSql(app.conn.?.kind) orelse return;
        const job = try app.newJob(.console);
        job.sqls = try job.arena.allocator().dupe([]const u8, &.{sql});
        return app.startJob(job);
    }
    if (eql(u8, cmd.name, "/refresh")) return app.startCacheLoad(true);
    if (eql(u8, cmd.name, "/save")) return app.saveQuery(arg);
    if (eql(u8, cmd.name, "/copy")) return app.copyQuery(app.sqlToCopy());
    if (eql(u8, cmd.name, "/queries")) {
        if (arg.len == 0) return app.openQueriesPicker();
        return app.loadSavedQuery(arg);
    }
    if (eql(u8, cmd.name, "/unsave")) {
        const dir = (try app.queriesDir()) orelse return;
        queries.remove(app.io, dir, arg) catch return app.transcript.addMessage(.err, "no saved query named '{s}'", .{arg});
        return app.transcript.addMessage(.dim, "deleted saved query '{s}'", .{arg});
    }
}

fn openConfigEditor(app: *App) !void {
    if (app.cfg.path.len == 0) return app.transcript.addMessage(.err, "cannot determine config path — start zpeek with --config <path>", .{});
    const original = Io.Dir.cwd().readFileAlloc(app.io, app.cfg.path, app.gpa, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return app.transcript.addMessage(.err, "cannot open config: {t}", .{err}),
    };
    errdefer if (original) |text| app.gpa.free(text);
    var editor: Editor = .init(app.gpa);
    errdefer editor.deinit();
    try editor.setText(original orelse config.example);
    editor.cursor = 0;
    app.closePopup();
    app.config_edit = .{ .previous = app.editor, .original = original };
    app.editor = editor;
    app.mode = .config;
}

fn closeConfigEditor(app: *App) void {
    app.closePopup();
    const edit = app.config_edit.?;
    app.editor.deinit();
    app.editor = edit.previous;
    if (edit.original) |text| app.gpa.free(text);
    if (edit.message) |message| app.gpa.free(message);
    app.config_edit = null;
    app.mode = .console;
}

fn configNotice(app: *App, message: []const u8) !void {
    const owned = try app.gpa.dupe(u8, message);
    if (app.config_edit.?.message) |old| app.gpa.free(old);
    app.config_edit.?.message = owned;
}

fn saveConfigEditor(app: *App) !void {
    app.config_edit.?.discard_armed = false;
    var arena: std.heap.ArenaAllocator = .init(app.gpa);
    var transferred = false;
    defer if (!transferred) arena.deinit();
    var diag: config.Diagnostic = .{};
    const cfg = config.saveText(arena.allocator(), app.io, app.env, app.cfg.path, app.editor.text(), app.config_edit.?.original, &diag) catch |err| {
        return app.configNotice(switch (err) {
            error.InvalidConfig => try app.tmpPrint("Not saved: {s}", .{diag.message}),
            error.ConfigChanged => "Not saved: config changed outside zpeek — reopen /config edit to load the latest version",
            error.ConfigTooLarge => "Not saved: config exceeds the 4 MiB limit",
            else => try app.tmpPrint("Not saved: {t} — check the config path and file permissions", .{err}),
        });
    };
    const access_changed = app.useConfig(cfg, arena);
    transferred = true;
    app.closeConfigEditor();
    if (access_changed) {
        return app.transcript.addMessage(.warn, "config saved; access changed or active entry was removed — old session closed; use /connect <name> to apply the saved settings", .{});
    }
    return app.transcript.addMessage(.ok, "config saved: {s} — saved connections updated; reconnect to apply changed connection parameters", .{cfg.path});
}

/// Takes ownership of arena and closes sessions whose saved access no longer matches.
fn useConfig(app: *App, cfg: config.Config, arena: std.heap.ArenaAllocator) bool {
    const active_entry = cfg.find(app.conn_name);
    const access_changed = if (app.conn_params) |params|
        (if (active_entry) |entry| params.access != entry.params.access else app.cfg.find(app.conn_name) != null)
    else
        false;
    if (app.config_arena) |*old| old.deinit();
    app.config_arena = arena;
    app.cfg = cfg;
    if (active_entry) |entry| app.conn_color = entry.color;
    if (access_changed) app.disconnect();
    return access_changed;
}

fn reloadConfig(app: *App) !bool {
    if (app.cfg.path.len == 0) return true;
    var arena: std.heap.ArenaAllocator = .init(app.gpa);
    var transferred = false;
    defer if (!transferred) arena.deinit();
    const a = arena.allocator();
    var diag: config.Diagnostic = .{};
    const path = try a.dupe(u8, app.cfg.path);
    const cfg = config.load(a, app.io, app.env, path, &diag) catch |err| {
        try app.transcript.addMessage(.err, "cannot reload config: {s} — connection was not opened", .{if (diag.message.len > 0) diag.message else @errorName(err)});
        return false;
    };
    const closed = app.useConfig(cfg, arena);
    transferred = true;
    if (closed) try app.transcript.addMessage(.warn, "saved access changed or active entry was removed — old session closed", .{});
    return true;
}

fn configure(app: *App, arg: []const u8) !void {
    const add_usage = "usage: /config add <name> <#RRGGBB> <url|path> — example: /config add local #2F6B43 postgres://postgres@localhost/app";
    const remove_usage = "usage: /config remove <name> — example: /config remove local";
    var words = std.mem.tokenizeAny(u8, arg, " \t\r\n");
    const action = words.next() orelse {
        try app.transcript.addMessage(.dim, "config: {s}", .{app.cfg.path});
        if (app.cfg.connections.len == 0) try app.transcript.addMessage(.dim, "no saved connections yet — add one with /config add", .{});
        for (app.cfg.connections) |entry| try app.transcript.addMessage(.dim, "  {s}", .{entry.name});
        try app.transcript.addMessage(.info, "{s}", .{add_usage});
        try app.transcript.addMessage(.info, "edit the file in zpeek: /config edit", .{});
        return app.transcript.addMessage(.info, "{s}", .{remove_usage});
    };
    if (std.mem.eql(u8, action, "edit")) {
        if (words.next() != null) return app.transcript.addMessage(.err, "usage: /config edit — no arguments needed", .{});
        return app.openConfigEditor();
    }
    const adding = std.mem.eql(u8, action, "add");
    if (!adding and !std.mem.eql(u8, action, "remove"))
        return app.transcript.addMessage(.err, "unknown /config action — use add, remove or edit; /config shows examples", .{});
    const usage = if (adding) add_usage else remove_usage;
    const name = words.next() orelse return app.transcript.addMessage(.err, "missing connection name; {s}", .{usage});
    const change: config.Change = if (adding) blk: {
        const color = words.next() orelse return app.transcript.addMessage(.err, "missing connection color (example: #2F6B43); {s}", .{usage});
        _ = config.parseColor(color) catch return app.transcript.addMessage(.err, "invalid connection color — use # followed by 6 hexadecimal digits (example: #2F6B43); {s}", .{usage});
        const url = std.mem.trim(u8, words.rest(), " \t\r\n");
        if (url.len == 0) return app.transcript.addMessage(.err, "missing connection URL or SQLite file path; {s}", .{usage});
        break :blk .{ .add = .{ .name = name, .url = url, .color = color } };
    } else if (words.next() == null)
        .{ .remove = name }
    else
        return app.transcript.addMessage(.err, "too many arguments — remove accepts only a connection name; {s}", .{usage});

    var arena: std.heap.ArenaAllocator = .init(app.gpa);
    var transferred = false;
    defer if (!transferred) arena.deinit();
    const cfg = config.update(arena.allocator(), app.io, app.env, app.cfg.path, change) catch |err| {
        const message = switch (err) {
            error.ConnectionExists => "this connection name is already saved — choose another name or remove the existing connection first",
            error.UnknownConnection => "no saved connection has this name — use /config to list saved connections",
            error.InvalidName => "invalid connection name — use a non-empty name without spaces",
            error.InvalidConnectionString => "malformed connection string — example: postgres://postgres@localhost/app or ./app.sqlite",
            error.UnknownScheme => "unsupported connection URL scheme — use postgres://, mysql://, mariadb://, sqlite:// or clickhouse://",
            error.InvalidPort => "invalid connection port — use a number between 0 and 65535",
            error.InvalidSslMode => "invalid sslmode — use disable, prefer, require, verify-ca or verify-full",
            error.InvalidConfig => "the config file contains invalid settings or TOML syntax — fix it before saving connections",
            error.MissingConfigPath => "cannot determine the config path — start zpeek with --config <path>",
            error.ConfigTooLarge => "the config file exceeds the 4 MiB limit — reduce its size before saving",
            else => return app.transcript.addMessage(.err, "cannot read or write config {s}: {t} — check the file and directory permissions; no changes were saved", .{ app.cfg.path, err }),
        };
        return app.transcript.addMessage(.err, "{s}; config was not changed ({s})", .{ message, app.cfg.path });
    };
    if (app.config_arena) |*old| old.deinit();
    app.config_arena = arena;
    transferred = true;
    app.cfg = cfg;
    return app.transcript.addMessage(.dim, "{s} connection '{s}' in {s}", .{ if (change == .add) "saved" else "removed", name, cfg.path });
}

test "config editor preserves SQL drafts and never submits config as SQL" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "config.toml" });
    defer a.free(path);
    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();
    var app: App = .{
        .gpa = a,
        .io = std.testing.io,
        .env = &env,
        .cfg = .{ .path = path, .found = false },
        .editor = .init(a),
        .transcript = .init(a),
        .conn_arena = .init(a),
        .popup_arena = .init(a),
        .frame_arena = .init(a),
    };
    defer app.deinit();
    try app.editor.setText("select 42;");
    try app.editor.commitHistoryText("select 1;");
    try app.runCommand("/config edit extra");
    try std.testing.expectEqual(Mode.console, app.mode);
    try app.runCommand("/config edit");
    try std.testing.expectEqual(Mode.config, app.mode);
    try std.testing.expectEqualStrings(config.example, app.editor.text());
    try std.testing.expect(app.config_edit.?.show_help);
    try app.handleKey(.{ .codepoint = vaxis.Key.page_down });
    try std.testing.expectEqual(@as(usize, 5), app.config_edit.?.help_top);
    try app.handleKey(.{ .codepoint = vaxis.Key.page_up });
    try std.testing.expectEqual(@as(usize, 0), app.config_edit.?.help_top);
    try app.handleKey(.{ .codepoint = vaxis.Key.f1 });
    try std.testing.expect(!app.config_edit.?.show_help);
    try std.testing.expectEqualStrings(config.example, app.editor.text());
    try app.handleKey(.{ .codepoint = vaxis.Key.f1 });
    try std.testing.expect(app.config_edit.?.show_help);
    var output: [4096]u8 = undefined;
    var writer: Io.Writer = .fixed(&output);
    app.vx = try vaxis.init(app.io, a, &env, .{});
    defer app.vx.deinit(a, &writer);
    var long_url: [400]u8 = undefined;
    @memset(&long_url, 'x');
    std.mem.copyForwards(u8, &long_url, "url = \"postgres://");
    long_url[long_url.len - 1] = '"';
    for ([_]u16{ 120, 80, 40 }) |cols| {
        try app.vx.resize(a, &writer, .{ .cols = cols, .rows = 24, .x_pixel = 0, .y_pixel = 0 });
        try app.editor.setText(&long_url);
        const editor_width = if (cols >= 110) cols - 56 else cols;
        app.editor.cursor = editor_width - 4;
        try app.draw();
        const win = app.vx.window();
        try std.testing.expect(app.vx.screen.cursor_vis);
        try std.testing.expectEqual(@as(u16, 7), app.vx.screen.cursor.col);
        try std.testing.expectEqual(@as(u16, 2), app.vx.screen.cursor.row);
        try std.testing.expect(win.readCell(3, 2).?.default);
        try std.testing.expectEqualStrings("x", win.readCell(7, 2).?.char.grapheme);
        const help_col: u16 = if (cols >= 110) cols - 53 else 1;
        const help_row: u16 = if (cols >= 110) 1 else 13;
        try std.testing.expectEqualStrings("P", win.readCell(help_col, help_row).?.char.grapheme);
        if (cols >= 110) try std.testing.expect(win.readCell(cols - 56, 2).?.default);
        _ = app.drawInput(win.child(.{ .width = 40, .height = 1 }));
        _ = app.drawInput(win.child(.{ .width = 40, .height = 0 }));
    }
    {
        app.mode = .console;
        defer app.mode = .config;
        const win = app.vx.window();
        try app.editor.setText("select 1;");
        _ = app.drawInput(win);
        try std.testing.expect(std.meta.eql(theme.sqlStyle(.keyword), win.readCell(3, 0).?.style));
        try std.testing.expect(std.meta.eql(theme.sqlStyle(.number), win.readCell(10, 0).?.style));
        try app.editor.setText("/tables");
        _ = app.drawInput(win);
        try std.testing.expect(std.meta.eql(theme.accent_bold, win.readCell(3, 0).?.style));
    }
    try app.editor.setText("[connections.local]\nacc");
    try app.openCompletion(false);
    try std.testing.expect(app.popup != null);
    try app.handleKey(.{ .codepoint = vaxis.Key.tab });
    try std.testing.expectEqualStrings("[connections.local]\naccess = ", app.editor.text());
    try std.testing.expectEqual(@as(usize, 3), app.popup.?.completion.candidates.len);
    for ([_]u16{ 120, 80, 40 }) |cols| {
        try app.vx.resize(a, &writer, .{ .cols = cols, .rows = 24, .x_pixel = 0, .y_pixel = 0 });
        try app.draw();
        const help_col: u16 = if (cols >= 110) cols - 53 else 1;
        const help_row: u16 = if (cols >= 110) 1 else 13;
        try std.testing.expectEqualStrings("P", app.vx.window().readCell(help_col, help_row).?.char.grapheme);
        try std.testing.expect(app.vx.screen.cursor_vis);
    }
    try app.handleKey(.{ .codepoint = vaxis.Key.down });
    try app.handleKey(.{ .codepoint = vaxis.Key.down });
    try app.handleKey(.{ .codepoint = vaxis.Key.enter });
    try std.testing.expectEqualStrings("[connections.local]\naccess = \"read_delete\"", app.editor.text());
    try std.testing.expect(app.popup == null);
    try app.editor.setText("[connections.local]\nsslmode = 'verify-full' # keep");
    app.editor.cursor = "[connections.local]\nsslmode = 'verify-f".len;
    try app.handleKey(.{ .codepoint = vaxis.Key.tab });
    try std.testing.expectEqualStrings("[connections.local]\nsslmode = 'verify-full' # keep", app.editor.text());
    try app.editor.setText("[connections.local]\nco");
    try app.openCompletion(false);
    try app.handleKey(.{ .codepoint = vaxis.Key.escape });
    try std.testing.expectEqual(Mode.config, app.mode);
    try std.testing.expect(!app.config_edit.?.discard_armed);
    try app.handleKey(.{ .codepoint = vaxis.Key.tab });
    try std.testing.expectEqualStrings("[connections.local]\ncolor = ", app.editor.text());
    try std.testing.expect(app.popup == null);
    try app.editor.setText("[broken");
    try app.handleKey(.{ .codepoint = vaxis.Key.enter });
    try std.testing.expectEqualStrings("[broken\n", app.editor.text());
    try std.testing.expectEqual(@as(usize, 0), app.editor.history.items.len);
    try app.handleKey(.{ .codepoint = 's', .mods = .{ .ctrl = true } });
    try std.testing.expectEqual(Mode.config, app.mode);
    try std.testing.expect(std.mem.indexOf(u8, app.config_edit.?.message.?, "Not saved:") != null);
    try std.testing.expect(!app.cfg.found);
    try app.handleKey(.{ .codepoint = vaxis.Key.escape });
    try std.testing.expectEqual(Mode.config, app.mode);
    try app.handleKey(.{ .codepoint = vaxis.Key.escape });
    try std.testing.expectEqualStrings("select 42;", app.editor.text());
    try app.runCommand("/config edit");
    const text = "# preserved comment\n[connections.local]\nurl = 'postgres://user:secret@localhost/app'\ncolor = '#2F6B43'\n";
    try app.editor.setText(text);
    try app.handleKey(.{ .codepoint = 's', .mods = .{ .ctrl = true } });
    try std.testing.expectEqual(Mode.console, app.mode);
    try std.testing.expectEqualStrings("select 42;", app.editor.text());
    try std.testing.expectEqual(@as(usize, 1), app.editor.history.items.len);
    try std.testing.expect(app.cfg.find("local") != null);
    const saved = try Io.Dir.cwd().readFileAlloc(app.io, path, a, .limited(4096));
    defer a.free(saved);
    try std.testing.expectEqualStrings(text, saved);
    for (app.transcript.entries.items) |entry| {
        if (entry.content == .message) try std.testing.expect(std.mem.indexOf(u8, entry.content.message.text, "secret") == null);
    }
    try app.runCommand("/config edit");
    try std.testing.expectEqualStrings(text, app.editor.text());
    try app.handleKey(.{ .codepoint = vaxis.Key.escape });
    try std.testing.expectEqual(Mode.console, app.mode);
}

test "changing access closes the old session and schema SQL is blocked after reconnect" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "config.toml" });
    defer a.free(path);
    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();
    var err: db.ErrorText = .{};
    defer err.deinit(a);
    const conn = try db.connect(a, std.testing.io, .{ .kind = .sqlite, .database = ":memory:" }, &err);
    var app: App = .{
        .gpa = a,
        .io = std.testing.io,
        .env = &env,
        .cfg = .{ .path = path, .found = false },
        .editor = .init(a),
        .transcript = .init(a),
        .conn_arena = .init(a),
        .popup_arena = .init(a),
        .frame_arena = .init(a),
        .conn = conn,
        .conn_name = "local",
        .conn_params = .{ .kind = .sqlite, .database = ":memory:" },
    };
    defer app.deinit();
    app.loop = .init(app.io, &app.tty, &app.vx);
    try app.runCommand("/config edit");
    try app.editor.setText("[connections.local]\npath = ':memory:'\naccess = 'read_delete'\n");
    try app.saveConfigEditor();
    defer while (app.job) |job| {
        job.future.await(app.io);
        app.finishJob();
    };
    const sql = "DROP SCHEMA IF EXISTS public CASCADE;\nCREATE SCHEMA IF NOT EXISTS public;";
    try std.testing.expect(app.conn == null);
    try app.editor.setText(sql);
    try app.submit();
    try std.testing.expect(app.job == null);
    const entry = app.cfg.find("local").?;
    app.conn = try db.connect(a, app.io, entry.params, &err);
    app.conn_name = "local";
    app.conn_params = entry.params;
    try app.editor.setText(sql);
    try app.submit();
    try std.testing.expect(app.job == null);
    try std.testing.expectEqual(conninfo.Access.read_delete, app.conn.?.access);
    try std.testing.expectEqual(conninfo.Access.read_delete, app.conn_params.?.access);
    try std.testing.expectError(error.AccessDenied, app.conn.?.query(a, sql));
    try Io.Dir.cwd().writeFile(app.io, .{ .sub_path = path, .data = "[connections.local]\npath = ':memory:'\naccess = 'read_only'\n" });
    try app.connectTarget("local");
    try std.testing.expectEqual(conninfo.Access.read_only, app.job.?.kind.connect.params.access);
}

test "config commands work disconnected and refresh saved connections" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "config.toml" });
    defer a.free(path);
    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();
    var app: App = .{
        .gpa = a,
        .io = std.testing.io,
        .env = &env,
        .cfg = .{ .path = path, .found = false },
        .editor = .init(a),
        .transcript = .init(a),
        .conn_arena = .init(a),
        .popup_arena = .init(a),
        .frame_arena = .init(a),
    };
    defer app.deinit();
    const invalid_commands = [_][2][]const u8{
        .{ "/config", "example: /config remove local" },
        .{ "/config nonsense", "unknown /config action" },
        .{ "/config add", "missing connection name" },
        .{ "/config remove", "missing connection name" },
        .{ "/config add local", "missing connection color" },
        .{ "/config add local red ./app.sqlite", "invalid connection color" },
        .{ "/config add local #2F6B43", "missing connection URL" },
        .{ "/config remove local extra", "too many arguments" },
        .{ "/config remove missing", "no saved connection has this name" },
        .{ "/config add local #2F6B43 unknown://user:secret@host/db", "unsupported connection URL scheme" },
    };
    for (invalid_commands) |case| {
        try app.runCommand(case[0]);
        const message = app.transcript.entries.items[app.transcript.entries.items.len - 1].content.message;
        try std.testing.expect(std.mem.indexOf(u8, message.text, case[1]) != null);
        try std.testing.expect(std.mem.indexOf(u8, message.text, "secret") == null);
        try std.testing.expectEqual(if (std.mem.eql(u8, case[0], "/config")) Transcript.MessageKind.info else .err, message.kind);
        try std.testing.expect(!app.cfg.found);
    }
    try app.runCommand("/config add local #2F6B43 ./my database.sqlite");
    try std.testing.expect(app.cfg.found);
    try std.testing.expectEqualStrings("./my database.sqlite", app.cfg.find("local").?.params.database);
    try app.runCommand("/config add local #2F6B43 ./other.sqlite");
    try std.testing.expect(std.mem.indexOf(u8, app.transcript.entries.items[app.transcript.entries.items.len - 1].content.message.text, "already saved") != null);
    try std.testing.expectEqualStrings("./my database.sqlite", app.cfg.find("local").?.params.database);
    try app.runCommand("/config add second #FF0000 ./second.sqlite");
    try std.testing.expectEqual(@as(usize, 2), app.cfg.connections.len);
    try app.runCommand("/config add invalid #bad ./bad.sqlite");
    try std.testing.expectEqual(@as(usize, 2), app.cfg.connections.len);
    try app.openConnectPicker();
    try std.testing.expectEqual(Mode.picker, app.mode);
    app.closePicker();
    try app.runCommand("/config remove local");
    try std.testing.expect(app.cfg.find("local") == null);
    try std.testing.expect(app.cfg.find("second") != null);
    try app.runCommand("/config");
}

/// `users where id > 3` -> table + filter. Also accepts a bare filter after the name.
fn splitBrowseArg(arg: []const u8) struct { table: []const u8, filter: []const u8 } {
    const space = std.mem.indexOfAny(u8, arg, " \t") orelse return .{ .table = arg, .filter = "" };
    var rest = std.mem.trim(u8, arg[space..], " \t");
    if (rest.len >= 5 and std.ascii.eqlIgnoreCase(rest[0..5], "where")) rest = std.mem.trim(u8, rest[5..], " \t");
    return .{ .table = arg[0..space], .filter = rest };
}

fn showHelp(app: *App) !void {
    const a = app.frame_arena.allocator();
    var lines: std.ArrayList(Transcript.Line) = .empty;
    try lines.append(a, try a.dupe(Segment, &.{.{ .text = "  Commands", .style = theme.bold }}));
    for (commands) |c| {
        const left = try std.fmt.allocPrint(a, "{s} {s}", .{ c.name, c.args });
        const pad = 30 -| render.displayWidth(left);
        var alias_text: []const u8 = "";
        if (c.aliases.len > 0) alias_text = try std.fmt.allocPrint(a, "  ({s})", .{try std.mem.join(a, ", ", c.aliases)});
        try lines.append(a, try a.dupe(Segment, &.{
            .{ .text = "    " },
            .{ .text = left, .style = theme.accent_bold },
            .{ .text = try Transcript.spaces(a, pad) },
            .{ .text = c.help },
            .{ .text = alias_text, .style = theme.dim },
        }));
    }
    try lines.append(a, &.{});
    try lines.append(a, try a.dupe(Segment, &.{.{ .text = "  Keys", .style = theme.bold }}));
    const keys = [_][2][]const u8{
        .{ "enter", "run SQL / command (several statements separated by ;)" },
        .{ "shift+enter, alt+enter, ctrl+j, \\", "new line" },
        .{ "tab", "complete commands, tables, columns, operators, keywords" },
        .{ "tab, enter (list open)", "insert the highlighted suggestion; esc closes the list" },
        .{ "↑ ↓", "history (or move between lines)" },
        .{ "ctrl+o", "open the last result in the table viewer" },
        .{ "ctrl+y", "copy input (or the last SQL / definition if input is empty)" },
        .{ "ctrl+s", "save input SQL (or the last query if input is empty)" },
        .{ "ctrl+r", "search saved queries and preview SQL" },
        .{ "alt+r", "search SQL history and load a query for review" },
        .{ "pgup pgdn, mouse wheel", "scroll" },
        .{ "ctrl+c", "cancel query / clear input / exit (twice)" },
        .{ "ctrl+d", "exit (on an empty input)" },
        .{ "ctrl+l", "clear the screen" },
    };
    for (keys) |k| {
        const pad = 34 -| render.displayWidth(k[0]);
        try lines.append(a, try a.dupe(Segment, &.{
            .{ .text = "    " },
            .{ .text = k[0], .style = theme.info },
            .{ .text = try Transcript.spaces(a, pad) },
            .{ .text = k[1] },
        }));
    }
    try app.transcript.add(.{ .lines = lines.items });
}

fn welcome(app: *App) !void {
    const a = app.frame_arena.allocator();
    const inner: usize = 62;
    var lines: std.ArrayList(Transcript.Line) = .empty;
    const top = try std.mem.concat(a, u8, &.{ " ╭", try repeat(a, "─", inner), "╮" });
    const bottom = try std.mem.concat(a, u8, &.{ " ╰", try repeat(a, "─", inner), "╯" });
    try lines.append(a, try a.dupe(Segment, &.{.{ .text = top, .style = theme.border_focus }}));
    const rows = [_][]const Segment{
        &.{.{ .text = "  zpeek", .style = .{ .fg = theme.accent } }},
        &.{.{ .text = "  terminal database client", .style = theme.dim }},
        &.{},
        &.{.{ .text = "  PostgreSQL · MySQL/MariaDB · SQLite · ClickHouse", .style = theme.dim }},
        &.{.{ .text = "  + CockroachDB · YugabyteDB · TiDB · Redshift · Aurora…", .style = theme.dim }},
        &.{.{ .text = "  /help · tab completes · ctrl+c twice exits", .style = theme.dim }},
    };
    for (rows) |segs| {
        var line: std.ArrayList(Segment) = .empty;
        try line.append(a, .{ .text = " │", .style = theme.border_focus });
        var w: usize = 0;
        for (segs) |s| {
            try line.append(a, s);
            w += render.displayWidth(s.text);
        }
        try line.append(a, .{ .text = try Transcript.spaces(a, inner -| w) });
        try line.append(a, .{ .text = "│", .style = theme.border_focus });
        try lines.append(a, line.items);
    }
    try lines.append(a, try a.dupe(Segment, &.{.{ .text = bottom, .style = theme.border_focus }}));
    try app.transcript.add(.{ .lines = lines.items });

    if (!app.cfg.found) {
        try app.transcript.addMessage(.dim, "no config at {s} — connect with /connect <url>, or run `zpeek --init-config`", .{app.cfg.path});
    }
}

fn repeat(a: Allocator, s: []const u8, n: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (0..n) |_| try out.appendSlice(a, s);
    return out.items;
}

fn tmpPrint(app: *App, comptime fmt: []const u8, args: anytype) ![]const u8 {
    return std.fmt.allocPrint(app.frame_arena.allocator(), fmt, args);
}

fn openConnectPicker(app: *App) !void {
    if (!try app.reloadConfig()) return;
    if (app.cfg.connections.len == 0) {
        return app.transcript.addMessage(.dim, "no connections in config — use /connect <url|path>", .{});
    }
    const a = app.frame_arena.allocator();
    var items: std.ArrayList(Picker.Item) = .empty;
    var buf: [256]u8 = undefined;
    for (app.cfg.connections) |c| {
        const desc = c.params.describe(&buf);
        try items.append(a, .{ .label = c.name, .detail = try std.fmt.allocPrint(a, "{s}  {s}", .{ c.params.kind.label(), desc }) });
    }
    app.picker = try Picker.init(app.gpa, .connect, "Connect to", items.items, true);
    app.mode = .picker;
    // preselect the default connection
    if (app.cfg.default) |d| {
        for (app.picker.?.matches.items, 0..) |m, i| {
            if (std.mem.eql(u8, app.cfg.connections[m].name, d)) app.picker.?.selected = i;
        }
    }
}

fn openTablePicker(app: *App, purpose: Picker.Purpose) !void {
    const cache = if (app.cache) |*c| c else return app.transcript.addMessage(.warn, "table list is still loading — try again in a moment", .{});
    if (cache.tables.len == 0) return app.transcript.addMessage(.dim, "no tables", .{});
    const a = app.frame_arena.allocator();
    var items: std.ArrayList(Picker.Item) = .empty;
    for (cache.tables, cache.columns) |t, cols| {
        try items.append(a, .{ .label = t, .detail = try std.fmt.allocPrint(a, "{d} columns", .{cols.len}) });
    }
    const title: []const u8 = if (purpose == .browse) "Browse table" else "Describe table";
    app.picker = try Picker.init(app.gpa, purpose, title, items.items, false);
    app.mode = .picker;
}

fn openLastResult(app: *App) !void {
    const r = app.transcript.lastResult() orelse return app.transcript.addMessage(.dim, "no result to open yet", .{});
    app.table_view = try TableView.init(app.gpa, r, false, "Result", null, app.conn_name, app.conn_color);
    app.mode = .table;
}

fn connectTarget(app: *App, target: []const u8) !void {
    if (app.cfg.find(target) != null or !conninfo.isConnectionString(target)) {
        if (!try app.reloadConfig()) return;
        if (app.cfg.find(target)) |e| return app.startConnect(e.name, e.params);
        return app.transcript.addMessage(.err, "no connection named '{s}' (and it does not look like a URL or file path)", .{target});
    }
    const params = conninfo.parse(app.frame_arena.allocator(), target) catch |err| {
        return app.transcript.addMessage(.err, "invalid connection string: {s}", .{conninfo.errorText(err)});
    };
    var p = params;
    if (p.kind == .sqlite) p.database = try config.expandHome(app.frame_arena.allocator(), app.env, p.database);
    // Never show the raw string: it may carry a password.
    var buf: [256]u8 = undefined;
    const name = if (p.kind == .sqlite) std.fs.path.basename(p.database) else p.describe(&buf);
    return app.startConnect(try app.tmpPrint("{s}", .{name}), p);
}

fn disconnect(app: *App) void {
    if (app.conn) |c| c.close();
    app.conn = null;
    if (app.conn_params) |p| @memset(@constCast(p.password), 0);
    app.conn_params = null;
    app.conn_color = null;
    if (app.cache) |*c| c.deinit();
    app.cache = null;
    _ = app.conn_arena.reset(.retain_capacity);
    app.conn_name = "";
}

// ───────────────────────────── jobs ─────────────────────────────

fn newJob(app: *App, kind: JobKind) !*Job {
    const job = try app.gpa.create(Job);
    job.* = .{ .arena = .init(app.gpa), .kind = kind, .started = .now(app.io, .awake) };
    return job;
}

fn startJob(app: *App, job: *Job) !void {
    std.debug.assert(app.job == null);
    app.job = job;
    app.busy.store(true, .release);
    job.started = .now(app.io, .awake);
    job.future = app.io.concurrent(jobTask, .{ app, job }) catch |err| {
        app.job = null;
        app.busy.store(false, .release);
        job.arena.deinit();
        app.gpa.destroy(job);
        return app.transcript.addMessage(.err, "cannot start query: {t}", .{err});
    };
}

fn cancelJob(app: *App, timed_out: bool) void {
    const job = app.job orelse return;
    job.timed_out = timed_out;
    job.cancel_requested.store(true, .release);
    if (job.kind == .connect) {
        job.future.cancel(app.io);
    } else if (app.conn) |conn| {
        conn.cancel();
    }
}

fn destroyJob(app: *App, job: *Job) void {
    if (job.conn) |conn| conn.close();
    for (job.outcomes.items) |*outcome| if (outcome.* == .result) outcome.result.result.deinit();
    job.arena.deinit();
    app.gpa.destroy(job);
}

fn stopJob(app: *App) void {
    const job = app.job orelse return;
    // A worker may be blocked posting completion to a full event queue.
    app.loop.queue.close(error.Closed);
    app.cancelJob(false);
    job.future.await(app.io);
    app.job = null;
    app.busy.store(false, .release);
    app.destroyJob(job);
}

/// Runs on a background task. Only touches `job` and the connection.
fn jobTask(app: *App, job: *Job) void {
    defer _ = app.loop.postEvent(.job_done) catch {};
    const a = job.arena.allocator();

    if (job.kind == .connect) {
        var err: db.ErrorText = .{};
        defer err.deinit(app.gpa);
        const conn = db.connect(app.gpa, app.io, job.kind.connect.params, &err) catch |e| {
            job.connect_error = switch (e) {
                error.ConnectFailed => a.dupe(u8, err.slice()) catch "connection failed",
                error.OutOfMemory => "out of memory",
            };
            return;
        };
        if (job.cancel_requested.load(.acquire)) {
            conn.close();
            return;
        }
        job.conn = conn;
        return;
    }

    const conn = app.conn orelse return;
    var retained: usize = 0;
    for (job.sqls) |sql| {
        if (job.cancel_requested.load(.acquire)) {
            job.outcomes.append(a, .canceled) catch return;
            return;
        }
        const remaining = job.max_result_bytes - retained;
        if (remaining == 0) {
            job.outcomes.append(a, .{ .failed = "batch result memory limit reached; remaining statements were not run" }) catch {};
            return;
        }
        const t0: Io.Timestamp = .now(app.io, .awake);
        const result = conn.queryOpts(app.gpa, sql, .{
            .max_rows = job.max_rows,
            .max_bytes = @min((db.QueryOptions{}).max_bytes, remaining),
        });
        const ms = t0.untilNow(app.io, .awake).toMilliseconds();
        if (result) |r| {
            var timed_result = r;
            const capacity = r.arena.queryCapacity();
            if (capacity > remaining) {
                timed_result.deinit();
                job.outcomes.append(a, .{ .failed = "statement completed but its result exceeded the batch memory limit and was discarded; remaining statements were not run" }) catch {};
                return;
            }
            retained += capacity;
            timed_result.elapsed_ms = ms;
            job.outcomes.append(a, .{ .result = .{ .result = timed_result, .ms = ms } }) catch {
                var rr = r;
                rr.deinit();
                return;
            };
        } else |e| {
            const outcome: Outcome = switch (e) {
                error.Canceled => .canceled,
                error.AccessDenied => .{ .failed = "connection access policy blocked this statement; nothing was run" },
                error.OutOfMemory => .{ .failed = "out of memory" },
                error.QueryFailed => .{ .failed = a.dupe(u8, conn.lastError()) catch "query failed" },
                error.ConnectionLost => blk: {
                    job.connection_lost = true;
                    break :blk .{ .failed = a.dupe(u8, conn.lastError()) catch "connection lost" };
                },
            };
            job.outcomes.append(a, outcome) catch return;
            if (job.stop_on_error or outcome == .canceled) return;
        }
    }
}

test "browse keys after a lost connection do not crash" {
    const a = std.testing.allocator;
    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();
    var app: App = .{
        .gpa = a,
        .io = std.testing.io,
        .env = &env,
        .cfg = .{ .path = "", .found = false },
        .editor = .init(a),
        .transcript = .init(a),
        .conn_arena = .init(a),
        .popup_arena = .init(a),
        .frame_arena = .init(a),
    };
    defer app.deinit();
    var builder = db.ResultBuilder.init(a);
    try builder.setColumns(&.{"id"});
    try builder.addRow(&.{"1"}, .{});
    const result = try a.create(db.Result);
    result.* = builder.finish();
    app.table_view = TableView.init(a, result, true, "t", .{ .table = "t", .kind = .postgres }, "", null) catch |err| {
        result.deinit();
        a.destroy(result);
        return err;
    };
    app.mode = .table;
    for ("rt") |c| {
        try app.handleTableKey(.{ .codepoint = c });
        try std.testing.expect(app.job == null);
        try std.testing.expectEqualStrings("not connected — close with q and use /connect", app.table_view.?.notice.?);
    }
}

test "SQL tools confirm writes, search history, export views and show plans" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const csv_path = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "rows.csv" });
    defer a.free(csv_path);
    const json_path = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "view.json" });
    defer a.free(json_path);
    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();
    var err: db.ErrorText = .{};
    defer err.deinit(a);
    const conn = try db.connect(a, std.testing.io, .{ .kind = .sqlite, .database = ":memory:" }, &err);
    var app: App = .{
        .gpa = a,
        .io = std.testing.io,
        .env = &env,
        .cfg = .{ .path = "", .found = false },
        .editor = .init(a),
        .transcript = .init(a),
        .conn_arena = .init(a),
        .popup_arena = .init(a),
        .frame_arena = .init(a),
        .conn = conn,
        .conn_params = .{ .kind = .sqlite, .database = ":memory:" },
    };
    defer app.deinit();
    app.loop = .init(app.io, &app.tty, &app.vx);
    defer while (app.job) |job| {
        job.future.await(app.io);
        app.finishJob();
    };
    var setup = try conn.query(a, "create table people(id integer primary key, name text); insert into people values (1,'Ada'),(2,'Grace'),(3,'Linus');");
    setup.deinit();
    const update = "update people set name = 'changed' where true";
    try app.editor.setText(update);
    try app.submit();
    try std.testing.expect(app.job == null);
    try std.testing.expectEqual(Picker.Purpose.confirm_sql, app.picker.?.purpose);
    try app.handlePickerKey(.{ .codepoint = vaxis.Key.enter });
    var unchanged = try conn.query(a, "select name from people where id=1");
    defer unchanged.deinit();
    try std.testing.expectEqualStrings("Ada", unchanged.rows[0][0].?);
    try app.editor.setText(update);
    try app.submit();
    try app.handlePickerKey(.{ .codepoint = vaxis.Key.down });
    try app.handlePickerKey(.{ .codepoint = vaxis.Key.enter });
    app.job.?.future.await(app.io);
    app.finishJob();
    const changed = app.transcript.entries.items[app.transcript.entries.items.len - 1].content.result.result;
    try std.testing.expectEqual(@as(?u64, 3), changed.affected_rows);
    try std.testing.expect(changed.elapsed_ms != null);
    try app.editor.setText("select id, name from people order by id");
    try app.submit();
    app.job.?.future.await(app.io);
    app.finishJob();
    try app.runCommand(try app.tmpPrint("/export csv {s}", .{csv_path}));
    const csv = try Io.Dir.cwd().readFileAlloc(app.io, csv_path, a, .limited(4096));
    defer a.free(csv);
    try std.testing.expect(std.mem.indexOf(u8, csv, "\"1\",\"changed\"") != null);
    try app.runCommand("/history changed");
    try std.testing.expectEqual(@as(usize, 1), app.picker.?.matches.items.len);
    try app.handlePickerKey(.{ .codepoint = vaxis.Key.enter });
    try std.testing.expectEqualStrings(update, app.editor.text());
    try std.testing.expect(app.job == null);
    try app.openLastResult();
    const tv = app.table_view.?;
    tv.col = 1;
    _ = try tv.handleKey(.{ .codepoint = 'x' });
    _ = try tv.handleKey(.{ .codepoint = 's' });
    _ = try tv.handleKey(.{ .codepoint = 's' });
    try app.handleTableKey(.{ .codepoint = 'e' });
    try app.handlePickerKey(.{ .codepoint = vaxis.Key.down });
    try app.handlePickerKey(.{ .codepoint = vaxis.Key.enter });
    try app.handlePickerKey(.{ .codepoint = 0, .text = json_path });
    try app.handlePickerKey(.{ .codepoint = vaxis.Key.enter });
    try std.testing.expectEqual(Mode.table, app.mode);
    const json = try Io.Dir.cwd().readFileAlloc(app.io, json_path, a, .limited(4096));
    defer a.free(json);
    try std.testing.expectEqualStrings("[\n  {\"id\": \"3\"},\n  {\"id\": \"2\"},\n  {\"id\": \"1\"}\n]\n", json);
    try app.handleTableKey(.{ .codepoint = 'q' });
    try app.runCommand("/explain select * from people where id=2");
    app.job.?.future.await(app.io);
    app.finishJob();
    try std.testing.expectEqual(Mode.table, app.mode);
    try std.testing.expect(std.mem.indexOf(u8, app.table_view.?.result.rows[0][3].?, "SEARCH") != null);
    try std.testing.expect(app.table_view.?.result.elapsed_ms != null);
    try app.handleTableKey(.{ .codepoint = 'q' });
    try app.runCommand("/explain update people set name='should not execute' where id=2");
    app.job.?.future.await(app.io);
    app.finishJob();
    try std.testing.expectEqual(Mode.table, app.mode);
    try app.handleTableKey(.{ .codepoint = 'q' });
    try app.runCommand("/explain select 1; drop table people");
    try std.testing.expect(app.job == null);
    try app.startBrowse("people", "true; drop table people");
    try std.testing.expect(app.job == null);
    var rows = try conn.query(a, "select count(*) from people");
    defer rows.deinit();
    try std.testing.expectEqualStrings("3", rows.rows[0][0].?);
    var name = try conn.query(a, "select name from people where id=2");
    defer name.deinit();
    try std.testing.expectEqualStrings("changed", name.rows[0][0].?);
}

test "read-only connections refuse writes before running them" {
    const a = std.testing.allocator;
    var err: db.ErrorText = .{};
    defer err.deinit(a);
    // A writable SQLite session: only the client-side check stands in the way.
    const conn = try @import("../db/sqlite.zig").connect(a, .{ .kind = .sqlite, .database = ":memory:" }, &err);
    var app: App = .{
        .gpa = a,
        .io = std.testing.io,
        .env = undefined,
        .cfg = .{ .path = "", .found = false },
        .editor = .init(a),
        .transcript = .init(a),
        .conn_arena = .init(a),
        .popup_arena = .init(a),
        .frame_arena = .init(a),
        .conn = conn,
        .conn_name = "test",
        .conn_params = .{ .kind = .sqlite, .database = ":memory:", .access = .read_only },
    };
    defer app.deinit();
    var setup = try conn.query(a, "create table people(id integer primary key); insert into people values (1);");
    setup.deinit();

    for ([_][]const u8{ "delete from people where id = 1", "select 1; insert into people values (2)", "with x as (select 1) update people set id = 3" }) |sql| {
        try app.editor.setText(sql);
        try app.submit();
        try std.testing.expect(app.job == null);
        const last = app.transcript.entries.items[app.transcript.entries.items.len - 1].content;
        try std.testing.expect(last == .message and last.message.kind == .err);
        try std.testing.expect(std.mem.startsWith(u8, last.message.text, "read-only connection"));
    }
    app.conn_params.?.access = .read_delete;
    for ([_][]const u8{ "create table other(id integer)", "update people set id = 2", "delete from people where id = 1; drop table people" }) |sql| {
        try app.editor.setText(sql);
        try app.submit();
        try std.testing.expect(app.job == null);
        const last = app.transcript.entries.items[app.transcript.entries.items.len - 1].content;
        try std.testing.expect(std.mem.startsWith(u8, last.message.text, "read-delete connection"));
    }
    try app.startBrowse("people", "id = 1; delete from people");
    try std.testing.expect(app.job == null);
    var left = try conn.query(a, "select count(*) from people");
    defer left.deinit();
    try std.testing.expectEqualStrings("1", left.rows[0][0].?);
}

test "query jobs honor cancellation and stop after connection loss" {
    const Fake = struct {
        calls: usize = 0,
        canceled: bool = false,
        closed: bool = false,

        const vtable: db.Connection.VTable = .{
            .query = query,
            .last_error = lastError,
            .cancel = cancel,
            .close = close,
        };

        fn query(ptr: *anyopaque, _: Allocator, _: []const u8, _: db.QueryOptions) db.QueryError!db.Result {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            return error.ConnectionLost;
        }

        fn lastError(_: *anyopaque) []const u8 {
            return "server disconnected";
        }

        fn cancel(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.canceled = true;
        }

        fn close(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.closed = true;
        }
    };

    const a = std.testing.allocator;
    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();
    var app: App = .{
        .gpa = a,
        .io = std.testing.io,
        .env = &env,
        .cfg = .{ .path = "", .found = false },
        .editor = .init(a),
        .transcript = .init(a),
        .conn_arena = .init(a),
        .popup_arena = .init(a),
        .frame_arena = .init(a),
    };
    defer app.deinit();
    app.loop = .init(app.io, &app.tty, &app.vx);
    var fake: Fake = .{};
    app.conn = .{ .ptr = &fake, .vtable = &Fake.vtable, .kind = .postgres };

    {
        const job = try app.newJob(.console);
        defer {
            job.arena.deinit();
            a.destroy(job);
        }
        job.sqls = &.{"select 1"};
        app.job = job;
        app.cancelJob(false);
        app.jobTask(job);
        try std.testing.expect(fake.canceled);
        try std.testing.expectEqual(@as(usize, 0), fake.calls);
        try std.testing.expect(job.outcomes.items[0] == .canceled);
        try std.testing.expect((try app.loop.tryEvent()).? == .job_done);
        app.job = null;
    }

    {
        const job = try app.newJob(.console);
        defer {
            job.arena.deinit();
            a.destroy(job);
        }
        job.sqls = &.{ "select 1", "select 2" };
        app.jobTask(job);
        try std.testing.expectEqual(@as(usize, 1), fake.calls);
        try std.testing.expect(job.connection_lost);
        try std.testing.expectEqual(@as(usize, 1), job.outcomes.items.len);
        try std.testing.expectEqualStrings("server disconnected", job.outcomes.items[0].failed);
        try std.testing.expect((try app.loop.tryEvent()).? == .job_done);
    }

    app.conn.?.kind = .sqlite;
    app.conn_name = "local";
    app.conn_params = .{ .kind = .sqlite, .database = ":memory:" };
    const job = try app.newJob(.console);
    job.sqls = &.{ "select 1", "select 2" };
    try app.startJob(job);
    try app.handleEvent(try app.loop.nextEvent());
    try std.testing.expect(fake.closed);
    try std.testing.expectEqual(@as(usize, 2), fake.calls);
    try std.testing.expect(app.conn == null);
    try std.testing.expect(app.job != null);
    try app.handleEvent(try app.loop.nextEvent());
    try app.handleEvent(try app.loop.nextEvent());
    try std.testing.expect(app.job == null);
    try std.testing.expectEqual(db.Kind.sqlite, app.conn.?.kind);
    try std.testing.expectEqualStrings("local", app.conn_name);
}

test "shutdown joins a worker even when the event queue is full" {
    const Fake = struct {
        started: Io.Event = .unset,
        released: Io.Event = .unset,
        finished: Io.Event = .unset,
        closed: bool = false,

        const vtable: db.Connection.VTable = .{ .query = query, .last_error = lastError, .cancel = cancel, .close = close };

        fn query(ptr: *anyopaque, a: Allocator, _: []const u8, _: db.QueryOptions) db.QueryError!db.Result {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.started.set(std.testing.io);
            self.released.waitUncancelable(std.testing.io);
            defer self.finished.set(std.testing.io);
            var result: db.Result = .{ .arena = .init(a) };
            errdefer result.deinit();
            result.status = try result.arena.allocator().dupe(u8, "completed during shutdown");
            return result;
        }

        fn lastError(_: *anyopaque) []const u8 {
            return "";
        }

        fn cancel(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.released.set(std.testing.io);
        }

        fn close(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            std.debug.assert(self.finished.isSet());
            self.closed = true;
        }
    };
    const a = std.testing.allocator;
    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();
    var fake: Fake = .{};
    {
        var app: App = .{
            .gpa = a,
            .io = std.testing.io,
            .env = &env,
            .cfg = .{ .path = "", .found = false },
            .editor = .init(a),
            .transcript = .init(a),
            .conn_arena = .init(a),
            .popup_arena = .init(a),
            .frame_arena = .init(a),
        };
        defer app.deinit();
        app.loop = .init(app.io, &app.tty, &app.vx);
        while (try app.loop.tryPostEvent(.tick)) {}
        const job = try app.newJob(.console);
        job.sqls = &.{"select 1"};
        app.conn = .{ .ptr = &fake, .vtable = &Fake.vtable, .kind = .postgres };
        try app.startJob(job);
        try fake.started.wait(app.io);
        app.stopJob();
        try std.testing.expect(app.job == null);
        try std.testing.expect(!app.busy.load(.acquire));
        try std.testing.expect(!fake.closed);
    }
    try std.testing.expect(fake.closed);
}

test "SQL batch budgets include retained arenas and skip subsequent writes" {
    const a = std.testing.allocator;
    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();
    var err: db.ErrorText = .{};
    defer err.deinit(a);
    const conn = try db.connect(a, std.testing.io, .{ .kind = .sqlite, .database = ":memory:" }, &err);
    var app: App = .{
        .gpa = a,
        .io = std.testing.io,
        .env = &env,
        .cfg = .{ .path = "", .found = false },
        .editor = .init(a),
        .transcript = .init(a),
        .conn_arena = .init(a),
        .popup_arena = .init(a),
        .frame_arena = .init(a),
        .conn = conn,
    };
    defer app.deinit();
    app.loop = .init(app.io, &app.tty, &app.vx);
    var setup = try conn.query(a, "create table t(id integer)");
    setup.deinit();
    var sample = try conn.query(a, "select 1");
    const capacity = sample.arena.queryCapacity();
    sample.deinit();
    try std.testing.expect(capacity > 0);
    for ([_]usize{ 0, capacity, capacity + 1 }) |budget| {
        const job = try app.newJob(.console);
        defer app.destroyJob(job);
        job.max_result_bytes = budget;
        job.sqls = &.{ "select 1", "select 2", "insert into t values (1)" };
        app.jobTask(job);
        const n: usize = if (budget == 0) 1 else 2;
        try std.testing.expectEqual(n, job.outcomes.items.len);
        if (budget > 0) try std.testing.expect(job.outcomes.items[0] == .result);
        try std.testing.expect(job.outcomes.items[n - 1] == .failed);
        try std.testing.expect(std.mem.indexOf(u8, job.outcomes.items[n - 1].failed, "remaining statements were not run") != null);
    }
    var count = try conn.query(a, "select count(*) from t");
    defer count.deinit();
    try std.testing.expectEqualStrings("0", count.rows[0][0].?);
}

fn finishJob(app: *App) void {
    const job = app.job orelse return;
    job.future.await(app.io);
    app.job = null;
    app.busy.store(false, .release);
    defer app.destroyJob(job);
    app.processJob(job) catch |err| {
        app.transcript.addMessage(.err, "internal error: {t}", .{err}) catch {};
    };
    if (job.connection_lost) {
        if (app.conn_params) |params| {
            if (app.job == null) {
                app.startConnect(app.conn_name, params) catch |err| {
                    app.transcript.addMessage(.err, "cannot reconnect: {t}", .{err}) catch {};
                };
            }
        }
        const reconnecting = app.job != null;
        app.disconnect();
        if (reconnecting) {
            app.transcript.addMessage(.warn, "connection lost — reconnecting", .{}) catch {};
        } else {
            app.transcript.addMessage(.warn, "connection lost — disconnected", .{}) catch {};
        }
    }
}

fn processJob(app: *App, job: *Job) !void {
    switch (job.kind) {
        .connect => |c| {
            if (job.cancel_requested.load(.acquire)) {
                if (job.conn) |conn| {
                    conn.close();
                    job.conn = null;
                }
                if (job.timed_out) return app.transcript.addMessage(.warn, "connection timed out", .{});
                return app.transcript.addMessage(.warn, "connection canceled", .{});
            }
            if (job.conn) |conn| {
                app.disconnect();
                app.conn = conn;
                job.conn = null;
                const a = app.conn_arena.allocator();
                app.conn_name = try a.dupe(u8, c.name);
                var p = c.params;
                p.host = try a.dupe(u8, p.host);
                p.user = try a.dupe(u8, p.user);
                p.database = try a.dupe(u8, p.database);
                p.password = try a.dupe(u8, p.password);
                app.conn_params = p;
                app.conn_color = if (app.cfg.find(c.name)) |entry| entry.color else null;
                try app.transcript.addMessage(.ok, "connected to {s} · {s} {s} · access: {s}", .{ c.name, conn.kind.label(), conn.server_version, @tagName(p.access) });
                try app.startCacheLoad(false);
            } else {
                try app.transcript.addMessage(.err, "{s}", .{job.connect_error orelse "connection failed"});
            }
        },
        .explain => {
            if (job.outcomes.items.len == 0) return;
            const outcome = &job.outcomes.items[0];
            switch (outcome.*) {
                .result => |r| {
                    const result = try app.gpa.create(db.Result);
                    errdefer app.gpa.destroy(result);
                    result.* = r.result;
                    const tv = try TableView.init(app.gpa, result, true, "Query plan · enter expands a step · e exports", null, app.conn_name, app.conn_color);
                    outcome.* = .canceled;
                    if (app.table_view) |old| old.deinit();
                    app.table_view = tv;
                    app.mode = .table;
                },
                .failed => |msg| try app.transcript.addMessage(.err, "{s}", .{msg}),
                .canceled => try app.transcript.addMessage(.warn, "plan canceled", .{}),
            }
        },
        .console => {
            const multi = job.sqls.len > 1;
            var ddl = false;
            for (job.outcomes.items, 0..) |*o, i| {
                switch (o.*) {
                    .result => |r| {
                        const title: ?[]const u8 = if (multi) try statementTitle(app.frame_arena.allocator(), job.sqls[i]) else null;
                        try app.transcript.add(.{ .result = .{ .result = r.result, .elapsed_ms = r.ms, .title = title } });
                        o.* = .canceled; // ownership moved to the transcript
                        if (isDdl(job.sqls[i])) ddl = true;
                    },
                    .failed => |msg| try app.transcript.addMessage(.err, "{s}", .{msg}),
                    .canceled => try app.transcript.addMessage(.warn, "canceled", .{}),
                }
            }
            if (ddl and !job.connection_lost) try app.startCacheLoad(false);
        },
        .list => |obj| {
            const o = if (job.outcomes.items.len > 0) job.outcomes.items[0] else return;
            switch (o) {
                .result => |r| {
                    if (r.result.rows.len == 0) return app.transcript.addMessage(.dim, "no {s}", .{try std.ascii.allocLowerString(app.frame_arena.allocator(), obj.title())});
                    try app.openObjectPicker(obj, r.result);
                },
                .failed => |msg| try app.transcript.addMessage(.err, "{s}", .{msg}),
                .canceled => try app.transcript.addMessage(.warn, "canceled", .{}),
            }
        },
        .describe => {
            const third: []const u8 = if (app.conn != null and app.conn.?.kind == .clickhouse) "Engine" else "Constraints";
            try app.showOutcomes(job, &.{ "Columns", "Indexes", third }, false);
        },
        .definition => |name| {
            const o = if (job.outcomes.items.len > 0) &job.outcomes.items[0] else return;
            switch (o.*) {
                .result => |r| {
                    if (r.result.rows.len == 0) return app.transcript.addMessage(.dim, "no view, function, trigger or enum named '{s}'", .{name});
                    for (r.result.rows) |row| {
                        try app.transcript.addMessage(.dim, "{s} {s}", .{ row[0] orelse "", row[1] orelse "" });
                        try app.transcript.add(.{ .code = row[2] orelse "-- definition not available" });
                    }
                },
                .failed => |msg| try app.transcript.addMessage(.err, "{s}", .{msg}),
                .canceled => try app.transcript.addMessage(.warn, "canceled", .{}),
            }
        },
        .browse_open => |b| {
            if (job.outcomes.items.len == 0) return;
            switch (job.outcomes.items[0]) {
                .result => |r| {
                    const owned = try app.gpa.create(db.Result);
                    owned.* = r.result;
                    job.outcomes.items[0] = .canceled;
                    const browse = b;
                    const tv = TableView.init(app.gpa, owned, true, b.table, browse, "", null) catch |err| {
                        owned.deinit();
                        app.gpa.destroy(owned);
                        return err;
                    };
                    if (app.table_view) |old| old.deinit();
                    app.table_view = tv;
                    // Primary key (second query) enables row deletion.
                    if (job.outcomes.items.len > 1) switch (job.outcomes.items[1]) {
                        .result => |pk| {
                            var names: std.ArrayList([]const u8) = .empty;
                            defer names.deinit(app.gpa);
                            for (pk.result.rows) |row| if (row.len > 0) if (row[0]) |n| try names.append(app.gpa, n);
                            try tv.setPrimaryKey(names.items);
                        },
                        else => {},
                    };
                    if (job.outcomes.items.len > 2) switch (job.outcomes.items[2]) {
                        .result => |fk| try tv.setForeignKeys(fk.result),
                        else => {},
                    };
                    app.mode = .table;
                    try app.transcript.addMessage(.dim, "{s}: {d} rows loaded in {d} ms", .{ b.table, r.result.rows.len, r.ms });
                },
                .failed => |msg| try app.transcript.addMessage(.err, "{s}", .{msg}),
                .canceled => try app.transcript.addMessage(.warn, "canceled", .{}),
            }
        },
        .browse_delete => {
            const tv = app.table_view orelse return;
            if (job.outcomes.items.len == 0) return;
            switch (job.outcomes.items[0]) {
                .result => |r| {
                    const n = r.result.affected_rows orelse 0;
                    app.notice.clearRetainingCapacity();
                    try app.notice.print(app.gpa, "{d} row{s} deleted", .{ n, if (n == 1) "" else "s" });
                    tv.notice = app.notice.items;
                    if (tv.browse) |*b| b.total = null;
                    try app.startBrowseReload();
                },
                .failed => |msg| {
                    app.notice.clearRetainingCapacity();
                    try app.notice.appendSlice(app.gpa, msg);
                    tv.notice = app.notice.items;
                },
                .canceled => tv.notice = "canceled",
            }
        },
        .browse_fk => {
            const tv = app.table_view orelse return;
            if (job.outcomes.items.len == 0) return;
            switch (job.outcomes.items[0]) {
                .result => |r| {
                    if (r.result.rows.len == 0) {
                        tv.notice = "referenced row not found";
                        return;
                    }
                    const owned = try app.gpa.create(db.Result);
                    owned.* = r.result;
                    job.outcomes.items[0] = .canceled;
                    tv.setForeignResult(owned);
                },
                .failed => |msg| {
                    app.notice.clearRetainingCapacity();
                    try app.notice.appendSlice(app.gpa, msg);
                    tv.notice = app.notice.items;
                },
                .canceled => tv.notice = "foreign key lookup canceled",
            }
        },
        .browse_reload => {
            const tv = app.table_view orelse return;
            if (job.outcomes.items.len == 0) return;
            switch (job.outcomes.items[0]) {
                .result => |r| {
                    const owned = try app.gpa.create(db.Result);
                    owned.* = r.result;
                    job.outcomes.items[0] = .canceled;
                    try tv.setResult(owned);
                },
                .failed => |msg| {
                    app.notice.clearRetainingCapacity();
                    try app.notice.appendSlice(app.gpa, msg);
                    tv.notice = app.notice.items;
                },
                .canceled => tv.notice = "canceled",
            }
        },
        .browse_count => {
            const tv = app.table_view orelse return;
            if (tv.browse == null or job.outcomes.items.len == 0) return;
            switch (job.outcomes.items[0]) {
                .result => {
                    if (countFromOutcome(job.outcomes.items[0])) |total| {
                        tv.browse.?.total = total;
                        tv.notice = null;
                    } else {
                        tv.notice = "could not read row count";
                    }
                },
                .failed => |msg| {
                    app.notice.clearRetainingCapacity();
                    try app.notice.appendSlice(app.gpa, msg);
                    tv.notice = app.notice.items;
                },
                .canceled => tv.notice = "count canceled",
            }
        },
        .cache => {
            if (job.outcomes.items.len == 0) return;
            switch (job.outcomes.items[0]) {
                .result => |r| {
                    if (app.cache) |*c| c.deinit();
                    app.cache = try complete.SchemaCache.fromResult(app.gpa, r.result);
                },
                .failed => |msg| try app.transcript.addMessage(.warn, "could not load table names for completion: {s}", .{msg}),
                .canceled => {},
            }
        },
    }
}

fn countFromOutcome(outcome: Outcome) ?u64 {
    const r = switch (outcome) {
        .result => |value| value.result,
        else => return null,
    };
    if (r.rows.len != 1 or r.rows[0].len == 0) return null;
    const value = r.rows[0][0] orelse return null;
    return std.fmt.parseInt(u64, value, 10) catch null;
}

/// Adds results with titles; secondary empty results are skipped.
fn showOutcomes(app: *App, job: *Job, titles: []const []const u8, show_empty_first: bool) !void {
    for (job.outcomes.items, 0..) |*o, i| {
        const title = if (i < titles.len) titles[i] else null;
        switch (o.*) {
            .result => |r| {
                if (r.result.rows.len == 0) {
                    if (i == 0 and show_empty_first) try app.transcript.addMessage(.dim, "no {s}", .{std.ascii.lowerString(try app.frame_arena.allocator().alloc(u8, title.?.len), title.?)});
                    if (i == 0 and !show_empty_first) try app.transcript.addMessage(.dim, "table not found or has no columns", .{});
                    continue;
                }
                var res = r.result;
                res.status = try countNoun(res.arena.allocator(), res.rows.len, title orelse "rows");
                try app.transcript.add(.{ .result = .{ .result = res, .elapsed_ms = r.ms, .title = title } });
                o.* = .canceled;
            },
            .failed => |msg| try app.transcript.addMessage(.err, "{s}", .{msg}),
            .canceled => try app.transcript.addMessage(.warn, "canceled", .{}),
        }
    }
}

/// "3 tables", "1 table", "2 indexes", "1 index".
fn countNoun(a: Allocator, n: usize, plural_title: []const u8) Allocator.Error![]const u8 {
    const lower = try std.ascii.allocLowerString(a, plural_title);
    var noun: []const u8 = lower;
    if (n == 1) {
        if (std.mem.endsWith(u8, lower, "xes")) noun = lower[0 .. lower.len - 2] else if (std.mem.endsWith(u8, lower, "s")) noun = lower[0 .. lower.len - 1];
    }
    return std.fmt.allocPrint(a, "{d} {s}", .{ n, noun });
}

fn statementTitle(a: Allocator, sql: []const u8) ![]const u8 {
    const one = try render.singleLine(a, sql);
    const fit = render.fitWidth(one, 70);
    if (fit.text.len == one.len) return one;
    return std.mem.concat(a, u8, &.{ fit.text, "…" });
}

fn isDdl(sql: []const u8) bool {
    var it: lexer.Iterator = .init(sql);
    while (it.next()) |t| {
        if (t.tag == .whitespace or t.tag == .comment) continue;
        const w = t.text(sql);
        for ([_][]const u8{ "create", "alter", "drop", "rename" }) |k| if (std.ascii.eqlIgnoreCase(w, k)) return true;
        return false;
    }
    return false;
}

fn startList(app: *App, obj: schema.Object) !void {
    const kind = app.conn.?.kind;
    const sql = schema.listSql(kind, obj) orelse return app.transcript.addMessage(.dim, "{s}", .{schema.unsupportedReason(kind, obj)});
    const job = try app.newJob(.{ .list = obj });
    job.sqls = try job.arena.allocator().dupe([]const u8, &.{sql});
    try app.startJob(job);
}

fn startDescribe(app: *App, table: []const u8) !void {
    const job = try app.newJob(.{ .describe = undefined });
    const a = job.arena.allocator();
    job.kind = .{ .describe = try a.dupe(u8, table) };
    job.sqls = try schema.describeSql(a, app.conn.?.kind, table);
    job.stop_on_error = true;
    try app.startJob(job);
}

fn startDefinition(app: *App, name: []const u8) !void {
    const a = app.frame_arena.allocator();
    try app.startDefinitionSql(name, try schema.definitionSql(a, app.conn.?.kind, name));
}

fn startDefinitionSql(app: *App, name: []const u8, sql: []const u8) !void {
    const job = try app.newJob(.{ .definition = undefined });
    const a = job.arena.allocator();
    job.kind = .{ .definition = try a.dupe(u8, name) };
    job.sqls = try a.dupe([]const u8, &.{try a.dupe(u8, sql)});
    try app.startJob(job);
}

fn objectColumn(result: db.Result, row: []const ?[]const u8, name: []const u8) []const u8 {
    for (result.columns, 0..) |column, i| {
        if (std.ascii.eqlIgnoreCase(column, name)) return row[i] orelse "";
    }
    return "";
}

fn formatTypeValues(a: Allocator, dialect: conninfo.Kind, label: []const u8, type_name: []const u8, raw: []const u8) Allocator.Error![]const u8 {
    var values = raw;
    if (dialect == .clickhouse) {
        for ([_][]const u8{ "Enum8(", "Enum16(", "Enum(" }) |prefix| {
            if (std.mem.indexOf(u8, raw, prefix)) |pos| {
                values = raw[pos + prefix.len ..];
                break;
            }
        }
    }
    var out: std.ArrayList(u8) = .empty;
    try out.print(a, "{s} {s}\n", .{ type_name, label });
    var start: usize = 0;
    var i: usize = 0;
    var depth: usize = 0;
    var quote: u8 = 0;
    var count: usize = 0;
    scan: while (i < values.len) : (i += 1) {
        const c = values[i];
        if (quote != 0) {
            if (c == '\\' and i + 1 < values.len) {
                i += 1;
            } else if (c == quote) {
                if (i + 1 < values.len and values[i + 1] == quote) i += 1 else quote = 0;
            }
            continue;
        }
        switch (c) {
            '\'', '"' => quote = c,
            '(' => depth += 1,
            ')' => {
                if (depth == 0 and dialect == .clickhouse) break :scan;
                depth -|= 1;
            },
            ',' => if (depth == 0) {
                const item = std.mem.trim(u8, values[start..i], " \t\r\n");
                if (item.len > 0) {
                    count += 1;
                    try out.print(a, "  {d}. {s}\n", .{ count, item });
                }
                start = i + 1;
            },
            else => {},
        }
    }
    const last = std.mem.trim(u8, values[start..i], " \t\r\n");
    if (last.len > 0) {
        count += 1;
        try out.print(a, "  {d}. {s}\n", .{ count, last });
    }
    if (count == 0) try out.appendSlice(a, "  (no values available)");
    return out.toOwnedSlice(a);
}

test "custom type values are listed without splitting quoted commas" {
    const a = std.testing.allocator;
    const pg = try formatTypeValues(a, .postgres, "public.mood", "enum", "'happy, calm', 'sad', 'it''s fine'");
    defer a.free(pg);
    try std.testing.expectEqualStrings("enum public.mood\n  1. 'happy, calm'\n  2. 'sad'\n  3. 'it''s fine'\n", pg);
    const mysql = try formatTypeValues(a, .mysql, "orders.status", "enum", "'new, open','done'");
    defer a.free(mysql);
    try std.testing.expectEqualStrings("enum orders.status\n  1. 'new, open'\n  2. 'done'\n", mysql);
    const ch = try formatTypeValues(a, .clickhouse, "events.state", "type", "LowCardinality(Enum8('new' = 1, 'in, progress' = 2))");
    defer a.free(ch);
    try std.testing.expectEqualStrings("type events.state\n  1. 'new' = 1\n  2. 'in, progress' = 2\n", ch);
    const domain = try formatTypeValues(a, .postgres, "public.price", "domain", "numeric(10, 2) CHECK (VALUE > 0)");
    defer a.free(domain);
    try std.testing.expectEqualStrings("domain public.price\n  1. numeric(10, 2) CHECK (VALUE > 0)\n", domain);
}

fn openObjectPicker(app: *App, obj: schema.Object, result: db.Result) !void {
    const a = app.frame_arena.allocator();
    const kind = app.conn.?.kind;
    var items: std.ArrayList(Picker.Item) = .empty;
    for (result.rows) |row| {
        const name = objectColumn(result, row, "name");
        const namespace = objectColumn(result, row, "schema");
        const table = objectColumn(result, row, "table");
        const label = if (obj == .types and name.len == 0)
            try std.fmt.allocPrint(a, "{s}.{s}", .{ table, objectColumn(result, row, "column") })
        else if (kind == .postgres and obj == .triggers)
            try std.fmt.allocPrint(a, "{s}.{s}.{s}", .{ namespace, table, name })
        else if (kind == .postgres)
            try std.fmt.allocPrint(a, "{s}.{s}", .{ namespace, name })
        else
            name;
        const detail = if (obj == .functions) objectColumn(result, row, "arguments") else objectColumn(result, row, "kind");
        const value = if (obj == .tables)
            ""
        else if (obj == .types)
            try formatTypeValues(a, kind, label, if (detail.len > 0) detail else "type", if (objectColumn(result, row, "values").len > 0) objectColumn(result, row, "values") else objectColumn(result, row, "type"))
        else if (kind == .postgres)
            try schema.definitionSqlForOid(a, obj, objectColumn(result, row, "oid"))
        else
            try schema.definitionSqlForObject(a, kind, obj, name, objectColumn(result, row, "kind"));
        try items.append(a, .{ .label = label, .detail = detail, .value = value });
    }
    app.picker = try Picker.init(app.gpa, if (obj == .tables) .browse else if (obj == .types) .type_value else .definition, obj.title(), items.items, false);
    app.mode = .picker;
}

test "schema pickers select the requested object" {
    const a = std.testing.allocator;
    var app: App = .{
        .gpa = a,
        .io = std.testing.io,
        .env = undefined,
        .cfg = .{ .path = "", .found = false },
        .editor = .init(a),
        .transcript = .init(a),
        .conn_arena = .init(a),
        .popup_arena = .init(a),
        .frame_arena = .init(a),
    };
    defer {
        if (app.picker) |p| p.deinit();
        app.editor.deinit();
        app.transcript.deinit();
        app.conn_arena.deinit();
        app.popup_arena.deinit();
        app.frame_arena.deinit();
    }
    app.conn = .{ .ptr = undefined, .vtable = undefined, .kind = .sqlite };

    const table_rows = [_][]const ?[]const u8{ &.{ "users", "table" }, &.{ "orders", "table" } };
    const tables: db.Result = .{ .arena = .init(a), .columns = &.{ "name", "kind" }, .rows = &table_rows };
    try app.openObjectPicker(.tables, tables);
    var p = app.picker.?;
    try std.testing.expectEqual(Picker.Purpose.browse, p.purpose);
    _ = try p.handleKey(.{ .codepoint = 'o', .text = "o" });
    const table_choice = try p.handleKey(.{ .codepoint = vaxis.Key.enter });
    try std.testing.expectEqual(@as(usize, 1), table_choice.choose);
    try std.testing.expectEqualStrings("orders", p.items[table_choice.choose].label);
    app.closePicker();

    const view_rows = [_][]const ?[]const u8{&.{"recent_orders"}};
    const views: db.Result = .{ .arena = .init(a), .columns = &.{"name"}, .rows = &view_rows };
    try app.openObjectPicker(.views, views);
    p = app.picker.?;
    try std.testing.expectEqual(Picker.Purpose.definition, p.purpose);
    try std.testing.expect(std.mem.indexOf(u8, p.items[0].value, "type = 'view'") != null);
    app.closePicker();

    const trigger_rows = [_][]const ?[]const u8{&.{ "orders", "audit_orders" }};
    const triggers: db.Result = .{ .arena = .init(a), .columns = &.{ "table", "name" }, .rows = &trigger_rows };
    try app.openObjectPicker(.triggers, triggers);
    p = app.picker.?;
    try std.testing.expect(std.mem.indexOf(u8, p.items[0].value, "type = 'trigger'") != null);
    app.closePicker();

    app.conn.?.kind = .mysql;
    const type_rows = [_][]const ?[]const u8{&.{ "orders", "status", "enum", "'new','done'" }};
    const types: db.Result = .{ .arena = .init(a), .columns = &.{ "table", "column", "kind", "values" }, .rows = &type_rows };
    try app.openObjectPicker(.types, types);
    p = app.picker.?;
    try std.testing.expectEqual(Picker.Purpose.type_value, p.purpose);
    try std.testing.expectEqualStrings("enum orders.status\n  1. 'new'\n  2. 'done'\n", p.items[0].value);
    app.closePicker();

    app.conn.?.kind = .postgres;
    const function_rows = [_][]const ?[]const u8{ &.{ "public", "calculate", "integer", "101" }, &.{ "public", "calculate", "text", "102" } };
    const functions: db.Result = .{ .arena = .init(a), .columns = &.{ "schema", "name", "arguments", "oid" }, .rows = &function_rows };
    try app.openObjectPicker(.functions, functions);
    p = app.picker.?;
    try std.testing.expectEqual(@as(usize, 2), p.items.len);
    try std.testing.expect(std.mem.indexOf(u8, p.items[0].value, "p.oid = 101") != null);
    try std.testing.expect(std.mem.indexOf(u8, p.items[1].value, "p.oid = 102") != null);
}

test "choosing a table opens its SQLite browse view" {
    const a = std.testing.allocator;
    var err: db.ErrorText = .{};
    defer err.deinit(a);
    const conn = try @import("../db/sqlite.zig").connect(a, .{ .kind = .sqlite, .database = ":memory:" }, &err);
    var app: App = .{
        .gpa = a,
        .io = std.testing.io,
        .env = undefined,
        .cfg = .{ .path = "", .found = false },
        .editor = .init(a),
        .transcript = .init(a),
        .conn_arena = .init(a),
        .popup_arena = .init(a),
        .frame_arena = .init(a),
        .conn = conn,
        .conn_name = "test",
        .conn_params = .{ .kind = .sqlite, .database = ":memory:" },
    };
    defer app.deinit();
    app.loop = .init(app.io, &app.tty, &app.vx);
    var setup = try conn.query(a, "create table people(id integer primary key, name text); insert into people values (1, 'Alice');");
    setup.deinit();
    var listed = try conn.query(a, schema.listSql(.sqlite, .tables).?);
    defer listed.deinit();
    try app.openObjectPicker(.tables, listed);
    try app.handlePickerKey(.{ .codepoint = vaxis.Key.enter });
    try std.testing.expect(app.picker == null);
    try std.testing.expect(app.job != null);
    try app.handleEvent(try app.loop.nextEvent());
    try std.testing.expectEqual(Mode.table, app.mode);
    try std.testing.expectEqualStrings("people", app.table_view.?.browse.?.table);
    try std.testing.expectEqualStrings("Alice", app.table_view.?.result.rows[0][1].?);
}

fn startBrowse(app: *App, table: []const u8, filter: []const u8) !void {
    if (try app.filterViolation(filter)) |word| return app.transcript.addMessage(.err, "browse filters may only read ('{s}' was refused)", .{word});
    const job = try app.newJob(.{ .browse_open = undefined });
    const a = job.arena.allocator();
    const kind = app.conn.?.kind;
    const params = app.conn_params.?;
    // Connections from the config are shown by their name ([connections.core_dev]
    // -> "core_dev"); ad-hoc URLs/paths fall back to the database name.
    const database = if (app.cfg.find(app.conn_name) != null) app.conn_name else databaseLabel(params, app.conn_name);
    const b: TableView.Browse = .{
        .table = try a.dupe(u8, table),
        .database = try a.dupe(u8, database),
        .database_color = app.conn_color,
        .filter = try a.dupe(u8, filter),
        .kind = kind,
        .read_only = params.access == .read_only,
    };
    job.kind = .{ .browse_open = b };
    job.sqls = try a.dupe([]const u8, &.{
        try schema.browseSql(a, kind, b.table, b.filter, null, b.page_size, 0),
        try schema.primaryKeySql(a, kind, b.table),
        (try schema.foreignKeySql(a, kind, b.table)) orelse "select 1 where 0",
    });
    job.stop_on_error = false;
    try app.startJob(job);
}

fn databaseLabel(params: conninfo.Params, connection_name: []const u8) []const u8 {
    if (params.kind == .sqlite) return std.fs.path.basename(params.database);
    if (params.database.len > 0) return params.database;
    if (params.kind == .postgres and params.user.len > 0) return params.user;
    if (params.kind == .postgres) return "postgres";
    return connection_name;
}

test "database label follows driver defaults" {
    try std.testing.expectEqualStrings("app", databaseLabel(.{ .kind = .postgres, .database = "app" }, "local"));
    try std.testing.expectEqualStrings("alice", databaseLabel(.{ .kind = .postgres, .user = "alice" }, "local"));
    try std.testing.expectEqualStrings("notes.db", databaseLabel(.{ .kind = .sqlite, .database = "/tmp/notes.db" }, "notes"));
    try std.testing.expectEqualStrings("shop", databaseLabel(.{ .kind = .mysql }, "shop"));
}

fn startBrowseReload(app: *App) !void {
    const tv = app.table_view orelse return;
    const b = tv.browse orelse return;
    if (try app.filterViolation(b.filter) != null) {
        tv.notice = "browse filters may only read";
        return;
    }
    const job = try app.newJob(.browse_reload);
    const a = job.arena.allocator();
    const kind = app.conn.?.kind;
    job.sqls = try a.dupe([]const u8, &.{try schema.browseSql(a, kind, b.table, b.filter, b.order, b.page_size, b.offset)});
    try app.startJob(job);
}

fn startBrowseCount(app: *App) !void {
    const tv = app.table_view orelse return;
    const b = tv.browse orelse return;
    if (try app.filterViolation(b.filter) != null) {
        tv.notice = "browse filters may only read";
        return;
    }
    const job = try app.newJob(.browse_count);
    const a = job.arena.allocator();
    job.sqls = try a.dupe([]const u8, &.{try schema.countSql(a, b.kind, b.table, b.filter)});
    try app.startJob(job);
}

fn startCacheLoad(app: *App, announce: bool) !void {
    const conn = app.conn orelse return;
    if (app.job != null) return;
    const job = try app.newJob(.cache);
    job.sqls = try job.arena.allocator().dupe([]const u8, &.{schema.completionSql(conn.kind)});
    try app.startJob(job);
    if (announce) try app.transcript.addMessage(.dim, "reloading table and column names…", .{});
}

fn startConnect(app: *App, name: []const u8, params: conninfo.Params) !void {
    if (app.job != null) return app.transcript.addMessage(.warn, "busy — wait for the running query", .{});
    const job = try app.newJob(.{ .connect = undefined });
    const a = job.arena.allocator();
    var p = params;
    conninfo.passwordFromEnv(&p, app.env);
    p.host = try a.dupe(u8, p.host);
    p.user = try a.dupe(u8, p.user);
    p.password = try a.dupe(u8, p.password);
    p.database = try a.dupe(u8, p.database);
    job.kind = .{ .connect = .{ .name = try a.dupe(u8, name), .params = p } };
    try app.startJob(job);
}

// ───────────────────────────── drawing ─────────────────────────────

fn transcriptHeight(app: *App) u16 {
    const win = app.vx.window();
    return win.height -| (app.inputHeight(win.width) + 2 + 1);
}

fn inputHeight(app: *App, width: u16) u16 {
    _ = width;
    const lines = app.editor.lineCount();
    return @intCast(@min(@max(lines, 1), 12));
}

fn draw(app: *App) !void {
    _ = app.frame_arena.reset(.{ .retain_with_limit = render.scratch_limit });
    const a = app.frame_arena.allocator();
    const win = app.vx.window();
    win.clear();
    win.hideCursor();
    if (win.width < 20 or win.height < 8) {
        _ = win.printSegment(.{ .text = "terminal too small" }, .{});
        return;
    }

    if (app.mode == .config) {
        _ = win.print(&.{.{ .text = try app.tmpPrint(" Config: {s}", .{app.cfg.path}), .style = theme.accent_bold }}, .{ .wrap = .none });
        const body = win.child(.{ .y_off = 1, .height = win.height - 3 });
        var box = body;
        const edit = &app.config_edit.?;
        if (edit.show_help) {
            const side = win.width >= 110;
            const help_width: u16 = if (side) 55 else win.width;
            const help_height: u16 = if (side) body.height else @min(10, body.height - 2);
            const panel = body.child(.{
                .x_off = if (side) @intCast(win.width - help_width) else 0,
                .y_off = if (side) 0 else @intCast(body.height - help_height),
                .width = help_width,
                .height = help_height,
                .border = .{ .where = if (side) .left else .top, .style = theme.border },
            });
            const help = panel.child(.{ .x_off = 1, .width = panel.width -| 2 });
            box = body.child(.{
                .width = if (side) body.width - help_width - 1 else body.width,
                .height = if (side) body.height else body.height - help_height - 1,
            });
            edit.help_top = @min(edit.help_top, config_help.len - 1);
            _ = help.print(&.{.{ .text = "Parameters · PgUp/PgDn · F1 hide", .style = theme.accent_bold }}, .{ .wrap = .none });
            var help_row: u16 = 1;
            var shown: usize = 0;
            for (config_help[edit.help_top..]) |line| {
                if (help_row >= help.height) break;
                const result = help.print(&.{.{ .text = line, .style = theme.dim }}, .{ .row_offset = help_row, .wrap = .word });
                shown += 1;
                if (result.overflow) break;
                help_row = result.row + 1;
            }
            edit.help_page_size = @max(1, shown -| 1);
        }
        const cursor = app.drawInput(box);
        if (app.popup) |*p| try app.drawPopup(a, box, p, cursor.row, cursor.col);
        box.showCursor(cursor.col, cursor.row);
        if (app.config_edit.?.message) |message| {
            _ = win.print(&.{.{ .text = message, .style = theme.warn }}, .{ .row_offset = win.height - 2, .wrap = .none });
        }
        _ = win.print(&.{.{ .text = " ctrl+s save · esc cancel · tab complete · F1 parameters", .style = theme.dim }}, .{ .row_offset = win.height - 1, .wrap = .none });
        return;
    }

    if (app.mode == .table) {
        if (app.table_view) |tv| {
            try tv.draw(win);
            if (app.job != null) {
                const msg = try std.fmt.allocPrint(a, " {s} loading… ", .{spinnerFrame(app.spinner)});
                _ = win.print(&.{.{ .text = msg, .style = theme.accent_bold }}, .{ .row_offset = 0, .col_offset = win.width -| @as(u16, @intCast(render.displayWidth(msg) + 1)), .wrap = .none });
            }
            return;
        }
    }

    const input_h = app.inputHeight(win.width);
    const box_h = input_h + 2;
    const footer_h: u16 = 1;
    const status_h: u16 = if (app.job != null) 1 else 0;
    const trans_h = win.height -| (box_h + footer_h + status_h);

    const trans_win = win.child(.{ .x_off = 0, .y_off = 0, .width = win.width, .height = trans_h });
    try app.transcript.draw(trans_win);

    if (app.job) |job| {
        const elapsed = job.started.untilNow(app.io, .awake).toMilliseconds();
        const what: []const u8 = switch (job.kind) {
            .connect => "Connecting",
            .cache => "Loading schema",
            else => "Running",
        };
        const msg = try std.fmt.allocPrint(a, "{s}… {d}.{d}s", .{ what, @divTrunc(elapsed, 1000), @divTrunc(@mod(elapsed, 1000), 100) });
        _ = win.print(&.{
            .{ .text = " " },
            .{ .text = spinnerFrame(app.spinner), .style = theme.accent_bold },
            .{ .text = " " },
            .{ .text = msg, .style = .{ .fg = theme.accent } },
            .{ .text = "  (ctrl+c to cancel)", .style = theme.dim },
        }, .{ .row_offset = trans_h, .wrap = .none });
    }

    const box = win.child(.{
        .x_off = 0,
        .y_off = @intCast(trans_h + status_h),
        .width = win.width,
        .height = box_h,
        .border = .{ .where = .all, .style = if (app.job == null) theme.border_focus else theme.border },
    });
    const cursor = app.drawInput(box);

    try app.drawFooter(a, win.child(.{ .y_off = @intCast(win.height - footer_h), .height = footer_h }));

    if (app.popup) |*p| try app.drawPopup(a, win, p, @intCast(trans_h + status_h), cursor.col);

    if (app.mode == .picker) {
        if (app.picker) |pk| try pk.draw(win, a);
    } else {
        box.showCursor(cursor.col, cursor.row);
    }
}

fn spinnerFrame(i: usize) []const u8 {
    // WGL4 characters only, so every terminal font can draw the spinner.
    const frames = [_][]const u8{ "·", "•", "●", "•" };
    return frames[(i / 1) % frames.len];
}

const CursorPos = struct { col: u16, row: u16 };

/// Draws the editor contents with highlighting and soft wrapping. Returns the
/// cursor position relative to `box`.
fn drawInput(app: *App, box: vaxis.Window) CursorPos {
    const text = app.editor.text();
    const prompt_w: u16 = 3;
    const config_editor = app.mode == .config;
    const width = box.width -| (prompt_w + @as(u16, if (config_editor) 1 else 0));
    if (width == 0 or box.height == 0) return .{ .col = 0, .row = 0 };
    const continuation_indent = if (config_editor) @min(4, width - 1) else 0;

    // Lay out graphemes into rows.
    var row: usize = 0;
    var col: usize = 0;
    var cursor_pos: CursorPos = .{ .col = prompt_w, .row = 0 };
    var cursor_row: usize = 0;
    var found_cursor = false;
    var gi = vaxis.unicode.graphemeIterator(text);
    while (gi.next()) |g| {
        const s = g.bytes(text);
        if (std.mem.eql(u8, s, "\n")) {
            if (g.start == app.editor.cursor) {
                cursor_row = row;
                cursor_pos = .{ .col = @intCast(@min(col, width - 1) + prompt_w), .row = 0 };
                found_cursor = true;
            }
            row += 1;
            col = 0;
            continue;
        }
        const w = vaxis.gwidth.gwidth(s, .unicode);
        if (col + w > width) {
            row += 1;
            col = continuation_indent;
        }
        if (g.start == app.editor.cursor) {
            cursor_row = row;
            cursor_pos = .{ .col = @intCast(col + prompt_w), .row = 0 };
            found_cursor = true;
        }
        col += w;
    }
    if (!found_cursor) {
        if (col >= width) {
            row += 1;
            col = continuation_indent;
        }
        cursor_row = row;
        cursor_pos = .{ .col = @intCast(col + prompt_w), .row = 0 };
    }
    const total_rows = row + 1;
    const visible: usize = box.height;
    // scroll so the cursor row is visible
    var first: usize = 0;
    if (total_rows > visible) {
        first = @min(cursor_row -| (visible - 1), total_rows - visible);
        if (cursor_row < first) first = cursor_row;
    }

    // prompt
    const prompt_style: vaxis.Style = if (app.job == null) theme.accent_bold else theme.dim;
    if (first == 0) _ = box.print(&.{.{ .text = " > ", .style = prompt_style }}, .{ .row_offset = 0, .wrap = .none });

    row = 0;
    col = 0;
    var tokens: lexer.Iterator = .init(text);
    var token: ?lexer.Token = null;
    const command_end = if (std.mem.startsWith(u8, text, "/")) std.mem.indexOfAny(u8, text, " \t") orelse text.len else 0;
    gi = vaxis.unicode.graphemeIterator(text);
    while (gi.next()) |g| {
        if (row >= first + visible) break;
        const s = g.bytes(text);
        if (std.mem.eql(u8, s, "\n")) {
            row += 1;
            col = 0;
            continue;
        }
        const w = vaxis.gwidth.gwidth(s, .unicode);
        if (col + w > width) {
            row += 1;
            col = continuation_indent;
        }
        if (row >= first and row < first + visible) {
            var style: vaxis.Style = .{};
            if (!config_editor) {
                while (token == null or token.?.end <= g.start) {
                    token = tokens.next();
                    if (token == null) break;
                }
                if (token) |t| {
                    style = if (command_end > 0 and t.start <= command_end) theme.accent_bold else theme.sqlStyle(t.tag);
                }
            }
            box.writeCell(@intCast(col + prompt_w), @intCast(row - first), .{
                .char = .{ .grapheme = s, .width = @intCast(w) },
                .style = style,
            });
        }
        col += w;
    }

    if (text.len == 0 and app.mode != .config) {
        const placeholder: []const u8 = if (app.conn == null)
            "/connect to a database, or /help"
        else
            "SQL or /command — try /tables";
        _ = box.print(&.{.{ .text = placeholder, .style = theme.dim }}, .{ .row_offset = 0, .col_offset = prompt_w, .wrap = .none });
    }

    cursor_pos.row = @intCast(cursor_row - first);
    return cursor_pos;
}

fn drawFooter(app: *App, a: Allocator, win: vaxis.Window) !void {
    var left: std.ArrayList(Segment) = .empty;
    if (app.exit_armed) {
        try left.append(a, .{ .text = "  Press ctrl+c again to exit", .style = theme.warn });
    } else if (app.conn) |c| {
        var buf: [256]u8 = undefined;
        const desc = if (app.conn_params) |p| p.describe(&buf) else "";
        try left.append(a, .{ .text = "  ● ", .style = theme.ok });
        if (app.conn_name.len > 0) {
            try left.append(a, .{ .text = try std.fmt.allocPrint(a, " {s} ", .{app.conn_name}), .style = TableView.databaseBadgeStyle(app.conn_color) });
        }
        try left.append(a, .{ .text = try std.fmt.allocPrint(a, "  {s} {s}", .{ c.kind.label(), c.server_version }), .style = theme.dim });
        if (!std.mem.eql(u8, desc, app.conn_name)) try left.append(a, .{ .text = try std.fmt.allocPrint(a, " · {s}", .{desc}), .style = theme.dim });
        if (app.readOnly()) try left.append(a, .{ .text = " · read-only", .style = theme.warn });
        if (app.conn_params) |params| {
            if (params.access == .read_delete) try left.append(a, .{ .text = " · read + delete", .style = theme.warn });
            if (params.access == .full) try left.append(a, .{ .text = " · full", .style = theme.dim });
        }
    } else {
        try left.append(a, .{ .text = "  ○ not connected", .style = theme.dim });
    }
    _ = win.print(left.items, .{ .row_offset = 0, .wrap = .none });

    const hint = "ctrl+s save · ctrl+r queries · /help ";
    const hw: u16 = @intCast(render.displayWidth(hint));
    var lw: usize = 0;
    for (left.items) |s| lw += render.displayWidth(s.text);
    if (lw + hw + 2 < win.width) {
        _ = win.print(&.{.{ .text = hint, .style = theme.dim }}, .{ .row_offset = 0, .col_offset = win.width - hw, .wrap = .none });
    }
}

/// Draws the completion list just above the input box.
fn drawPopup(app: *App, a: Allocator, win: vaxis.Window, p: *Popup, box_top: u16, cursor_col: u16) !void {
    const cands = p.completion.candidates;
    const below = app.mode == .config and box_top < @min(4, win.height / 2);
    const available = if (below) win.height -| (box_top + 1) else box_top;
    const max_visible: usize = @min(10, @as(usize, available));
    if (max_visible == 0) return;
    const visible = @min(cands.len, max_visible);
    if (p.selected < p.top) p.top = p.selected;
    if (p.selected >= p.top + visible) p.top = p.selected + 1 - visible;

    var label_w: usize = 0;
    var detail_w: usize = 0;
    for (cands[p.top .. p.top + visible]) |c| {
        label_w = @max(label_w, render.displayWidth(c.text));
        detail_w = @max(detail_w, render.displayWidth(c.detail));
    }
    label_w = @min(label_w, @min(40, win.width / 2));
    detail_w = @min(detail_w, win.width -| @as(u16, @intCast(label_w + 7)));
    const inner: usize = 2 + 2 + label_w + (if (detail_w > 0) detail_w + 2 else 0) + 1;
    const w: u16 = @intCast(@min(inner, win.width));
    const x: u16 = @min(cursor_col -| @as(u16, @intCast(@min(p.completion.replace_len, cursor_col))), win.width -| w);
    const y: u16 = if (below) box_top + 1 else box_top - @as(u16, @intCast(visible));
    const pop = win.child(.{ .x_off = x, .y_off = y, .width = w, .height = @intCast(visible) });
    pop.fill(.{ .char = .{ .grapheme = " ", .width = 1 }, .style = .{ .bg = .{ .index = 0 } } });

    for (cands[p.top .. p.top + visible], 0..) |c, i| {
        const sel = p.top + i == p.selected;
        const bg: vaxis.Color = if (sel) theme.selection_bg else .{ .index = 0 };
        const fg: vaxis.Color = if (sel) .{ .index = 15 } else .default;
        if (sel) {
            var cx: u16 = 0;
            while (cx < pop.width) : (cx += 1) pop.writeCell(cx, @intCast(i), .{ .char = .{ .grapheme = " ", .width = 1 }, .style = .{ .bg = bg } });
        }
        const icon: []const u8 = switch (c.kind) {
            // Plain letters: decorative symbols are missing from many terminal fonts.
            .command => "·",
            .table => "t",
            .column => "c",
            .operator => "=",
            .keyword => "k",
            .function => "f",
            .connection => "●",
            .query => "q",
            .config_key => "=",
            .config_value => "v",
        };
        const fit = render.fitWidth(c.text, label_w);
        const detail = render.fitWidth(c.detail, detail_w);
        const shown_detail = if (detail.text.len == c.detail.len) c.detail else if (detail_w > 0)
            try std.mem.concat(a, u8, &.{ render.fitWidth(c.detail, detail_w - 1).text, "…" })
        else
            "";
        _ = pop.print(&.{
            .{ .text = " ", .style = .{ .bg = bg } },
            .{ .text = icon, .style = .{ .fg = if (sel) fg else theme.muted_color, .bg = bg } },
            .{ .text = " ", .style = .{ .bg = bg } },
            .{ .text = fit.text, .style = .{ .fg = fg, .bg = bg, .bold = sel } },
            .{ .text = try Transcript.spaces(a, label_w - fit.width + 2), .style = .{ .bg = bg } },
            .{ .text = shown_detail, .style = .{ .fg = if (sel) fg else theme.muted_color, .bg = bg } },
        }, .{ .row_offset = @intCast(i), .wrap = .none });
    }
}
