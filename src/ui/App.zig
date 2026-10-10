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
    .{ .name = "/tables", .help = "list tables", .aliases = &.{"/t"} },
    .{ .name = "/views", .help = "list views", .aliases = &.{"/v"} },
    .{ .name = "/types", .help = "list user types and enum values", .aliases = &.{"/enums"} },
    .{ .name = "/functions", .help = "list functions and procedures", .aliases = &.{ "/fn", "/routines" } },
    .{ .name = "/triggers", .help = "list triggers" },
    .{ .name = "/describe", .args = "<table>", .help = "columns, indexes and constraints", .arg = .table, .aliases = &.{"/d"} },
    .{ .name = "/browse", .args = "<table> [where …]", .help = "open table data (no argument: pick a table)", .arg = .table, .aliases = &.{"/b"} },
    .{ .name = "/def", .args = "<name>", .help = "source of a view, function, trigger or enum", .arg = .object },
    .{ .name = "/databases", .help = "list databases", .aliases = &.{"/dbs"} },
    .{ .name = "/refresh", .help = "reload table/column names for completion" },
    .{ .name = "/save", .args = "<name>", .help = "save the last SQL you ran under a name" },
    .{ .name = "/queries", .args = "[name]", .help = "saved queries: pick one to put it in the input", .arg = .query, .aliases = &.{"/sq"} },
    .{ .name = "/unsave", .args = "<name>", .help = "delete a saved query", .arg = .query },
    .{ .name = "/clear", .help = "clear the screen" },
    .{ .name = "/quit", .help = "exit", .aliases = &.{ "/q", "/exit" } },
};

const Mode = enum { console, table, picker };

const JobKind = union(enum) {
    connect: struct { name: []const u8, params: conninfo.Params },
    console,
    list: schema.Object,
    describe: []const u8,
    definition: []const u8,
    browse_open: TableView.Browse,
    browse_reload,
    browse_count,
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
/// The last SQL text sent to the server, for /save.
last_sql: std.ArrayList(u8) = .empty,
frame_arena: std.heap.ArenaAllocator,
history_path: ?[]const u8 = null,

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
        if (app.table_view == null or app.table_view.?.owns_result) app.transcript.prune();
        try app.draw();
        try app.vx.render(writer);
        try writer.flush();
    }

    if (app.job) |job| {
        app.cancelJob(false);
        job.future.await(app.io);
        app.finishJob();
    }
}

fn deinit(app: *App) void {
    if (app.table_view) |tv| tv.deinit();
    if (app.picker) |p| p.deinit();
    if (app.conn) |c| c.close();
    if (app.cache) |*c| c.deinit();
    app.editor.deinit();
    app.transcript.deinit();
    app.conn_arena.deinit();
    app.popup_arena.deinit();
    app.frame_arena.deinit();
    app.notice.deinit(app.gpa);
    app.last_sql.deinit(app.gpa);
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
    defer app.gpa.free(path);
    const items = app.editor.history.items;
    const start = items.len -| history_limit;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(app.gpa);
    for (items[start..]) |h| {
        out.appendSlice(app.gpa, h) catch return;
        out.append(app.gpa, 0) catch return;
    }
    const cwd = Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |dir| cwd.createDirPath(app.io, dir) catch return;
    cwd.writeFile(app.io, .{ .sub_path = path, .data = out.items }) catch {};
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
            if (app.mode == .console) try app.editor.insertPaste(text);
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
        .picker => {},
    }
}

fn handleKey(app: *App, key: vaxis.Key) !void {
    if (app.pasting) {
        if (app.mode != .console) return;
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
        .console => {},
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
        try app.acceptCandidate(cand, p.completion.replace_len);
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

fn acceptCandidate(app: *App, cand: complete.Candidate, replace_len: usize) Allocator.Error!void {
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
    try app.editor.replaceBeforeCursorAndMove(replace_len, text, cursor_back);
    app.closePopup();
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
    _ = app.popup_arena.reset(.retain_capacity);
    const a = app.popup_arena.allocator();
    var names: std.ArrayList([]const u8) = .empty;
    for (app.cfg.connections) |c| try names.append(a, c.name);
    const result = try complete.complete(a, .{
        .text = app.editor.text(),
        .cursor = app.editor.cursor,
        .cache = if (app.cache) |*c| c else null,
        .connections = names.items,
        .queries = try app.savedQueryNames(a),
        .commands = &commands,
        .kind = if (app.conn) |conn| conn.kind else null,
    });
    if (result.candidates.len == 0) {
        app.popup = null;
        return;
    }
    if (explicit and result.candidates.len == 1) {
        try app.acceptCandidate(result.candidates[0], result.replace_len);
        return;
    }
    if (explicit) {
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
                    const entry = app.cfg.connections[i];
                    app.closePicker();
                    try app.transcript.add(.{ .input = try app.tmpPrint("/connect {s}", .{entry.name}) });
                    try app.startConnect(entry.name, entry.params);
                },
                .browse, .describe => {
                    const name = try app.gpa.dupe(u8, label);
                    defer app.gpa.free(name);
                    app.closePicker();
                    if (purpose == .browse) try app.startBrowse(name, "") else try app.startDescribe(name);
                },
                .query => {
                    const name = try app.gpa.dupe(u8, label);
                    defer app.gpa.free(name);
                    app.closePicker();
                    try app.loadSavedQuery(name);
                },
            }
        },
        .raw => |text| {
            const t = try app.gpa.dupe(u8, text);
            defer app.gpa.free(t);
            app.closePicker();
            try app.connectTarget(t);
        },
    }
}

fn closePicker(app: *App) void {
    if (app.picker) |p| p.deinit();
    app.picker = null;
    app.mode = .console;
}

fn handleTableKey(app: *App, key: vaxis.Key) !void {
    const tv = app.table_view.?;
    if (app.job != null) {
        if (key.matches('c', .{ .ctrl = true })) {
            if (app.conn) |c| c.cancel();
        }
        return;
    }
    switch (try tv.handleKey(key)) {
        .none => {},
        .close => {
            tv.deinit();
            app.table_view = null;
            app.mode = .console;
        },
        .reload => try app.startBrowseReload(),
        .count => try app.startBrowseCount(),
        .copy => |text| {
            try app.vx.copyToSystemClipboard(app.tty.writer(), text, app.gpa);
            tv.notice = "copied to clipboard";
        },
        .notice => |n| tv.notice = n,
        .delete_row => |sql| {
            defer app.gpa.free(sql);
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
    const conn = app.conn.?;

    var stmts: std.ArrayList([]const u8) = .empty;
    defer stmts.deinit(app.gpa);
    const dialect: lexer.Dialect = switch (conn.kind) {
        .postgres => .postgres,
        .mysql => .mysql,
        .sqlite => .sqlite,
        // Backslash escapes in strings, like MySQL.
        .clickhouse => .mysql,
    };
    if (lexer.hasDeleteWithoutWhere(text, dialect)) {
        return app.transcript.addMessage(.err, "{s}", .{delete_without_where_message});
    }
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

fn queriesDir(app: *App) !?[]const u8 {
    return queries.dirPath(app.frame_arena.allocator(), app.cfg.path);
}

fn savedQueryNames(app: *App, a: Allocator) ![]const []const u8 {
    const dir = (try app.queriesDir()) orelse return &.{};
    const entries = queries.list(a, app.io, dir) catch return &.{};
    const names = try a.alloc([]const u8, entries.len);
    for (entries, names) |e, *n| n.* = e.name;
    return names;
}

fn saveQuery(app: *App, name: []const u8) !void {
    if (!queries.validName(name)) return app.transcript.addMessage(.err, "usage: /save <name> — letters, digits, '_', '-', '.'", .{});
    if (app.last_sql.items.len == 0) return app.transcript.addMessage(.err, "nothing to save yet — run an SQL query first", .{});
    const dir = (try app.queriesDir()) orelse return app.transcript.addMessage(.err, "cannot determine the config directory", .{});
    queries.save(app.gpa, app.io, dir, name, app.last_sql.items) catch |err| {
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
    const entries = queries.list(a, app.io, dir) catch |err| return app.transcript.addMessage(.err, "cannot read {s}: {t}", .{ dir, err });
    if (entries.len == 0) return app.transcript.addMessage(.dim, "no saved queries yet — run SQL, then /save <name>", .{});
    var items: std.ArrayList(Picker.Item) = .empty;
    for (entries) |e| try items.append(a, .{ .label = e.name, .detail = e.preview });
    app.picker = try Picker.init(app.gpa, .query, "Saved queries", items.items, false);
    app.mode = .picker;
}

pub const delete_without_where_message = "DELETE without WHERE is blocked: nothing was run. Add a WHERE clause (WHERE true deletes every row) or use TRUNCATE.";

fn redactConnectionInput(text: []const u8) []const u8 {
    const name_end = std.mem.indexOfAny(u8, text, " \t\n") orelse return text;
    const name = text[0..name_end];
    if (!std.mem.eql(u8, name, "/connect") and !std.mem.eql(u8, name, "/c")) return text;
    const arg = std.mem.trim(u8, text[name_end..], " \t\r\n");
    if (arg.len == 0 or !conninfo.isConnectionString(arg)) return text;
    return "/connect <redacted>";
}

test "connection URLs are redacted before display and history" {
    try std.testing.expectEqualStrings("/connect <redacted>", redactConnectionInput("/connect postgres://user:secret@localhost/db"));
    try std.testing.expectEqualStrings("/connect <redacted>", redactConnectionInput("/c ./private.sqlite"));
    try std.testing.expectEqualStrings("/connect production", redactConnectionInput("/connect production"));
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
        std.mem.eql(u8, cmd.name, "/queries") or std.mem.eql(u8, cmd.name, "/save") or std.mem.eql(u8, cmd.name, "/unsave"));
    if (needs_conn and app.conn == null) return app.transcript.addMessage(.err, "not connected — use /connect", .{});
    const needs_idle = !(std.mem.eql(u8, cmd.name, "/help") or std.mem.eql(u8, cmd.name, "/clear") or std.mem.eql(u8, cmd.name, "/quit"));
    if (needs_idle and app.job != null) return app.transcript.addMessage(.warn, "busy — wait for the running query or press ctrl+c", .{});

    const eql = std.mem.eql;
    if (eql(u8, cmd.name, "/help")) return app.showHelp();
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
    if (app.cfg.find(target)) |e| return app.startConnect(e.name, e.params);
    if (!conninfo.isConnectionString(target)) {
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
    for (job.sqls) |sql| {
        if (job.cancel_requested.load(.acquire)) {
            job.outcomes.append(a, .canceled) catch return;
            return;
        }
        const t0: Io.Timestamp = .now(app.io, .awake);
        const result = conn.queryOpts(app.gpa, sql, .{ .max_rows = job.max_rows });
        const ms = t0.untilNow(app.io, .awake).toMilliseconds();
        if (result) |r| {
            job.outcomes.append(a, .{ .result = .{ .result = r, .ms = ms } }) catch {
                var rr = r;
                rr.deinit();
                return;
            };
        } else |e| {
            const outcome: Outcome = switch (e) {
                error.Canceled => .canceled,
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

fn finishJob(app: *App) void {
    const job = app.job orelse return;
    job.future.await(app.io);
    app.job = null;
    app.busy.store(false, .release);
    defer {
        // results that were handed over are marked consumed by setting them to .canceled
        for (job.outcomes.items) |*o| if (o.* == .result) o.result.result.deinit();
        job.arena.deinit();
        app.gpa.destroy(job);
    }
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
                try app.transcript.addMessage(.ok, "connected to {s} · {s} {s}", .{ c.name, conn.kind.label(), conn.server_version });
                try app.startCacheLoad(false);
            } else {
                try app.transcript.addMessage(.err, "{s}", .{job.connect_error orelse "connection failed"});
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
        .list => |obj| try app.showOutcomes(job, &.{obj.title()}, true),
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
    const job = try app.newJob(.{ .definition = undefined });
    const a = job.arena.allocator();
    job.kind = .{ .definition = try a.dupe(u8, name) };
    job.sqls = try a.dupe([]const u8, &.{try schema.definitionSql(a, app.conn.?.kind, name)});
    try app.startJob(job);
}

fn startBrowse(app: *App, table: []const u8, filter: []const u8) !void {
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
    };
    job.kind = .{ .browse_open = b };
    job.sqls = try a.dupe([]const u8, &.{
        try schema.browseSql(a, kind, b.table, b.filter, null, b.page_size, 0),
        try schema.primaryKeySql(a, kind, b.table),
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
    const job = try app.newJob(.browse_reload);
    const a = job.arena.allocator();
    const kind = app.conn.?.kind;
    job.sqls = try a.dupe([]const u8, &.{try schema.browseSql(a, kind, b.table, b.filter, b.order, b.page_size, b.offset)});
    try app.startJob(job);
}

fn startBrowseCount(app: *App) !void {
    const tv = app.table_view orelse return;
    const b = tv.browse orelse return;
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
    _ = app.frame_arena.reset(.retain_capacity);
    const a = app.frame_arena.allocator();
    const win = app.vx.window();
    win.clear();
    win.hideCursor();
    if (win.width < 20 or win.height < 8) {
        _ = win.printSegment(.{ .text = "terminal too small" }, .{});
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
    const cursor = try app.drawInput(a, box);

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
fn drawInput(app: *App, a: Allocator, box: vaxis.Window) !CursorPos {
    const text = app.editor.text();
    const prompt_w: u16 = 3;
    const width = box.width -| prompt_w;
    if (width == 0) return .{ .col = 0, .row = 0 };

    // Styles per byte from the lexer.
    const styles = try a.alloc(vaxis.Style, text.len);
    {
        var it: lexer.Iterator = .init(text);
        const is_command = std.mem.startsWith(u8, text, "/");
        while (it.next()) |t| {
            var st = theme.sqlStyle(t.tag);
            if (is_command and t.start == 0) st = theme.accent_bold;
            if (is_command and t.start > 0 and t.start <= (std.mem.indexOfAny(u8, text, " \t") orelse text.len)) st = theme.accent_bold;
            @memset(styles[t.start..t.end], st);
        }
    }

    // Lay out graphemes into rows.
    const Cell = struct { start: usize, len: usize, row: usize, col: usize };
    var cells: std.ArrayList(Cell) = .empty;
    var row: usize = 0;
    var col: usize = 0;
    var cursor_pos: CursorPos = .{ .col = prompt_w, .row = 0 };
    var cursor_row: usize = 0;
    var found_cursor = false;
    var gi = vaxis.unicode.graphemeIterator(text);
    while (gi.next()) |g| {
        if (g.start == app.editor.cursor) {
            cursor_row = row;
            cursor_pos = .{ .col = @intCast(col + prompt_w), .row = 0 };
            found_cursor = true;
        }
        const s = g.bytes(text);
        if (std.mem.eql(u8, s, "\n")) {
            row += 1;
            col = 0;
            continue;
        }
        const w = vaxis.gwidth.gwidth(s, .unicode);
        if (col + w > width) {
            row += 1;
            col = 0;
        }
        try cells.append(a, .{ .start = g.start, .len = g.len, .row = row, .col = col });
        col += w;
    }
    if (!found_cursor) {
        if (col >= width) {
            row += 1;
            col = 0;
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

    for (cells.items) |c| {
        if (c.row < first or c.row >= first + visible) continue;
        box.writeCell(@intCast(c.col + prompt_w), @intCast(c.row - first), .{
            .char = .{ .grapheme = text[c.start .. c.start + c.len], .width = @intCast(vaxis.gwidth.gwidth(text[c.start .. c.start + c.len], .unicode)) },
            .style = styles[c.start],
        });
    }

    if (text.len == 0) {
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
    } else {
        try left.append(a, .{ .text = "  ○ not connected", .style = theme.dim });
    }
    _ = win.print(left.items, .{ .row_offset = 0, .wrap = .none });

    const hint = "/help · tab complete · ctrl+o viewer ";
    const hw: u16 = @intCast(render.displayWidth(hint));
    var lw: usize = 0;
    for (left.items) |s| lw += render.displayWidth(s.text);
    if (lw + hw + 2 < win.width) {
        _ = win.print(&.{.{ .text = hint, .style = theme.dim }}, .{ .row_offset = 0, .col_offset = win.width - hw, .wrap = .none });
    }
}

/// Draws the completion list just above the input box.
fn drawPopup(app: *App, a: Allocator, win: vaxis.Window, p: *Popup, box_top: u16, cursor_col: u16) !void {
    _ = app;
    const cands = p.completion.candidates;
    const max_visible: usize = @min(10, @as(usize, box_top));
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
    label_w = @min(label_w, 40);
    detail_w = @min(detail_w, 40);
    const inner: usize = 2 + 2 + label_w + (if (detail_w > 0) detail_w + 2 else 0) + 1;
    const w: u16 = @intCast(@min(inner, win.width));
    const x: u16 = @min(cursor_col -| @as(u16, @intCast(@min(p.completion.replace_len, cursor_col))), win.width -| w);
    const y: u16 = box_top - @as(u16, @intCast(visible));
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
        };
        const fit = render.fitWidth(c.text, label_w);
        _ = pop.print(&.{
            .{ .text = " ", .style = .{ .bg = bg } },
            .{ .text = icon, .style = .{ .fg = if (sel) fg else theme.muted_color, .bg = bg } },
            .{ .text = " ", .style = .{ .bg = bg } },
            .{ .text = fit.text, .style = .{ .fg = fg, .bg = bg, .bold = sel } },
            .{ .text = try Transcript.spaces(a, label_w - fit.width + 2), .style = .{ .bg = bg } },
            .{ .text = render.fitWidth(c.detail, detail_w).text, .style = .{ .fg = if (sel) fg else theme.muted_color, .bg = bg } },
        }, .{ .row_offset = @intCast(i), .wrap = .none });
    }
}
