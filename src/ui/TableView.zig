//! Full-screen grid for a result set with cursor navigation, a cell detail
//! view, filtering, sorting and column hiding. In browse mode filter/sort/paging are done by
//! the database (the App re-runs the query); otherwise they are applied locally.

const std = @import("std");
const Allocator = std.mem.Allocator;
const vaxis = @import("vaxis");
const Segment = vaxis.Segment;
const db = @import("../db/db.zig");
const schema = @import("../db/schema.zig");
const render = @import("../render.zig");
const theme = @import("theme.zig");
const Editor = @import("Editor.zig");
const Transcript = @import("Transcript.zig");
const complete = @import("complete.zig");
const lexer = @import("../sql/lexer.zig");
const Kind = @import("../conninfo.zig").Kind;

const TableView = @This();

pub const Browse = struct {
    table: []const u8,
    filter: []const u8 = "",
    order: ?schema.Order = null,
    offset: usize = 0,
    page_size: usize = 500,
    /// Total rows matching the filter, when known.
    total: ?u64 = null,
    /// SQL dialect, used to quote completed column names.
    kind: Kind = .postgres,
};

pub const Action = union(enum) {
    none,
    close,
    /// Browse parameters changed; the App should fetch a new page.
    reload,
    copy: []const u8,
    /// Show a short message in the status bar.
    notice: []const u8,
};

gpa: Allocator,
/// Owned when `owns_result` is true (browse mode), otherwise borrowed from the transcript.
result: *db.Result,
owns_result: bool,
title: []const u8,
browse: ?Browse,

/// Row indices into `result.rows` after local filter/sort.
view: std.ArrayList(usize) = .empty,
widths: std.ArrayList(u16) = .empty,
/// Per column: true when hidden by the user.
hidden: std.ArrayList(bool) = .empty,
/// Indices of the shown columns, in order. `col` and `left` index into this.
visible: std.ArrayList(usize) = .empty,

row: usize = 0,
/// Position of the cursor column within `visible`.
col: usize = 0,
top: usize = 0,
/// First drawn position within `visible`.
left: usize = 0,

/// Column chooser overlay state (`c` key).
chooser: ?struct { sel: usize = 0, top: usize = 0 } = null,

local_filter: std.ArrayList(u8) = .empty,
local_sort: ?struct { col: usize, desc: bool } = null,

filter_editor: Editor,
editing_filter: bool = false,
/// Column and SQL-operator completion while editing the filter.
completion: std.ArrayList(complete.Candidate) = .empty,
completion_sel: usize = 0,
/// Bytes before the cursor replaced by the chosen candidate.
completion_len: usize = 0,
detail: bool = false,
detail_scroll: usize = 0,
notice: ?[]const u8 = null,

/// Visible rows from the last draw (for paging).
page_rows: usize = 20,

frame_arena: std.heap.ArenaAllocator,

pub fn init(gpa: Allocator, result: *db.Result, owns_result: bool, title: []const u8, browse: ?Browse) Allocator.Error!*TableView {
    const tv = try gpa.create(TableView);
    tv.* = .{
        .gpa = gpa,
        .result = result,
        .owns_result = owns_result,
        .title = try gpa.dupe(u8, title),
        .browse = browse,
        .filter_editor = .init(gpa),
        .frame_arena = .init(gpa),
    };
    if (tv.browse) |*b| {
        b.table = try gpa.dupe(u8, b.table);
        b.filter = try gpa.dupe(u8, b.filter);
        if (b.order) |*o| o.column = try gpa.dupe(u8, o.column);
    }
    try tv.rebuild();
    return tv;
}

pub fn deinit(tv: *TableView) void {
    if (tv.owns_result) {
        tv.result.deinit();
        tv.gpa.destroy(tv.result);
    }
    if (tv.browse) |b| {
        tv.gpa.free(b.table);
        tv.gpa.free(b.filter);
        if (b.order) |o| tv.gpa.free(o.column);
    }
    tv.gpa.free(tv.title);
    tv.view.deinit(tv.gpa);
    tv.widths.deinit(tv.gpa);
    tv.hidden.deinit(tv.gpa);
    tv.visible.deinit(tv.gpa);
    tv.local_filter.deinit(tv.gpa);
    tv.filter_editor.deinit();
    tv.completion.deinit(tv.gpa);
    tv.frame_arena.deinit();
    tv.gpa.destroy(tv);
}

/// Replaces the result after a browse reload.
pub fn setResult(tv: *TableView, result: *db.Result) Allocator.Error!void {
    if (tv.owns_result) {
        tv.result.deinit();
        tv.gpa.destroy(tv.result);
    }
    tv.result = result;
    tv.owns_result = true;
    tv.row = 0;
    tv.top = 0;
    // A page reload keeps the same columns, so hidden columns stay hidden;
    // rebuild() resets them only if the column count changed.
    try tv.rebuild();
    tv.col = @min(tv.col, tv.visible.items.len -| 1);
    if (tv.left > tv.col) tv.left = tv.col;
}

fn rebuild(tv: *TableView) Allocator.Error!void {
    const r = tv.result;
    tv.view.clearRetainingCapacity();
    const needle = tv.local_filter.items;
    const filter = parseLocalFilter(r.columns, needle);
    for (r.rows, 0..) |row, i| {
        if (needle.len == 0 or filter.matches(row)) try tv.view.append(tv.gpa, i);
    }
    if (tv.local_sort) |s| {
        const Ctx = struct {
            rows: []const []const ?[]const u8,
            col: usize,
            desc: bool,
            fn lessThan(ctx: @This(), a: usize, b: usize) bool {
                const ord = compareValues(ctx.rows[a][ctx.col], ctx.rows[b][ctx.col]);
                return if (ctx.desc) ord == .gt else ord == .lt;
            }
        };
        std.sort.block(usize, tv.view.items, Ctx{ .rows = r.rows, .col = s.col, .desc = s.desc }, Ctx.lessThan);
    }

    tv.widths.clearRetainingCapacity();
    for (r.columns, 0..) |name, ci| {
        // Values are capped at 50 columns; the name (plus room for a sort
        // marker) always fits, so column names are never truncated.
        const name_w = render.displayWidth(name) + 2;
        var data_w: usize = 4;
        for (r.rows) |row| {
            const v = row[ci] orelse render.null_text;
            data_w = @max(data_w, cellWidth(v));
            if (data_w >= 50) break;
        }
        const w = @max(name_w, @min(data_w, 50));
        try tv.widths.append(tv.gpa, @intCast(@min(w, std.math.maxInt(u16) / 2)));
    }
    if (tv.hidden.items.len != r.columns.len) {
        try tv.hidden.resize(tv.gpa, r.columns.len);
        @memset(tv.hidden.items, false);
    }
    try tv.rebuildVisible();
    tv.row = @min(tv.row, tv.view.items.len -| 1);
}

fn rebuildVisible(tv: *TableView) Allocator.Error!void {
    tv.visible.clearRetainingCapacity();
    for (tv.hidden.items, 0..) |h, i| {
        if (!h) try tv.visible.append(tv.gpa, i);
    }
    tv.col = @min(tv.col, tv.visible.items.len -| 1);
    tv.left = @min(tv.left, tv.col);
}

/// Index into `result.columns` of the cursor column.
fn curCol(tv: *const TableView) usize {
    if (tv.visible.items.len == 0) return 0;
    return tv.visible.items[tv.col];
}

fn hiddenCount(tv: *const TableView) usize {
    return tv.hidden.items.len - tv.visible.items.len;
}

/// Hides or shows column `ci`, keeping at least one column visible.
fn toggleColumn(tv: *TableView, ci: usize) Allocator.Error!?[]const u8 {
    if (!tv.hidden.items[ci] and tv.visible.items.len <= 1) return "at least one column must stay visible";
    const cursor_col = tv.curCol();
    tv.hidden.items[ci] = !tv.hidden.items[ci];
    try tv.rebuildVisible();
    // Keep the cursor on the same column, or the nearest one after it.
    for (tv.visible.items, 0..) |v, pos| {
        if (v >= cursor_col) {
            tv.col = pos;
            break;
        }
    } else tv.col = tv.visible.items.len -| 1;
    if (tv.left > tv.col) tv.left = tv.col;
    return null;
}

fn cellWidth(v: []const u8) usize {
    // Fast path: avoid full grapheme scanning for long values.
    const head = v[0..@min(v.len, 200)];
    return render.displayWidth(head);
}

const LocalFilter = struct {
    column: ?usize,
    text: []const u8,
    exact: bool,

    fn matches(f: LocalFilter, row: []const ?[]const u8) bool {
        if (f.column) |c| return f.cellMatches(row[c]);
        for (row) |v| if (f.cellMatches(v)) return true;
        return false;
    }

    fn cellMatches(f: LocalFilter, v: ?[]const u8) bool {
        const s = v orelse return std.ascii.eqlIgnoreCase(f.text, "null");
        if (f.exact) return std.mem.eql(u8, s, f.text);
        return std.ascii.findIgnoreCase(s, f.text) != null;
    }
};

/// `text` searches all columns; `col:text` one column; `col=value` exact match.
fn parseLocalFilter(columns: []const []const u8, s: []const u8) LocalFilter {
    for ([_]u8{ '=', ':' }) |sep| {
        if (std.mem.indexOfScalar(u8, s, sep)) |i| {
            const name = std.mem.trim(u8, s[0..i], " ");
            for (columns, 0..) |c, ci| {
                if (std.ascii.eqlIgnoreCase(c, name)) {
                    return .{ .column = ci, .text = std.mem.trim(u8, s[i + 1 ..], " "), .exact = sep == '=' };
                }
            }
        }
    }
    return .{ .column = null, .text = s, .exact = false };
}

fn compareValues(a: ?[]const u8, b: ?[]const u8) std.math.Order {
    const x = a orelse return if (b == null) .eq else .gt; // NULLs last
    const y = b orelse return .lt;
    const fx = std.fmt.parseFloat(f64, x) catch null;
    const fy = std.fmt.parseFloat(f64, y) catch null;
    if (fx != null and fy != null) return std.math.order(fx.?, fy.?);
    return std.mem.order(u8, x, y);
}

fn currentValue(tv: *const TableView) ?[]const u8 {
    if (tv.view.items.len == 0 or tv.result.columns.len == 0) return null;
    return tv.result.rows[tv.view.items[tv.row]][tv.curCol()];
}

pub fn handleKey(tv: *TableView, key: vaxis.Key) Allocator.Error!Action {
    tv.notice = null;
    if (tv.editing_filter) return tv.handleFilterKey(key);
    if (tv.chooser != null) return tv.handleChooserKey(key);
    if (tv.detail) {
        if (key.matchesAny(&.{ vaxis.Key.escape, vaxis.Key.enter, 'q' }, .{})) {
            tv.detail = false;
        } else if (key.matchesAny(&.{ vaxis.Key.down, 'j' }, .{})) {
            tv.detail_scroll += 1;
        } else if (key.matchesAny(&.{ vaxis.Key.up, 'k' }, .{})) {
            tv.detail_scroll -|= 1;
        } else if (key.matches('y', .{})) {
            return .{ .copy = tv.currentValue() orelse "" };
        }
        return .none;
    }

    const nrows = tv.view.items.len;
    const ncols = tv.visible.items.len;
    if (key.matchesAny(&.{ vaxis.Key.escape, 'q' }, .{}) or key.matches('c', .{ .ctrl = true })) return .close;
    if (key.matchesAny(&.{ vaxis.Key.down, 'j' }, .{})) {
        if (tv.row + 1 < nrows) tv.row += 1 else return tv.nextPage();
    } else if (key.matchesAny(&.{ vaxis.Key.up, 'k' }, .{})) {
        if (tv.row > 0) tv.row -= 1;
    } else if (key.matchesAny(&.{ vaxis.Key.right, 'l', vaxis.Key.tab }, .{})) {
        if (tv.col + 1 < ncols) tv.col += 1;
    } else if (key.matchesAny(&.{ vaxis.Key.left, 'h' }, .{}) or key.matches(vaxis.Key.tab, .{ .shift = true })) {
        if (tv.col > 0) tv.col -= 1;
    } else if (key.matches(vaxis.Key.page_down, .{}) or key.matches('f', .{ .ctrl = true }) or key.matches(' ', .{})) {
        if (tv.row + 1 >= nrows) return tv.nextPage();
        tv.row = @min(tv.row + tv.page_rows, nrows -| 1);
    } else if (key.matches(vaxis.Key.page_up, .{}) or key.matches('b', .{ .ctrl = true })) {
        tv.row -|= tv.page_rows;
    } else if (key.matches('d', .{ .ctrl = true })) {
        tv.row = @min(tv.row + tv.page_rows / 2, nrows -| 1);
    } else if (key.matches('u', .{ .ctrl = true })) {
        tv.row -|= tv.page_rows / 2;
    } else if (key.matchesAny(&.{ vaxis.Key.home, 'g' }, .{})) {
        tv.row = 0;
    } else if (key.matchesAny(&.{ vaxis.Key.end, 'G' }, .{}) or key.matches('g', .{ .shift = true })) {
        tv.row = nrows -| 1;
    } else if (key.matches('0', .{}) or key.matches('^', .{})) {
        tv.col = 0;
    } else if (key.matches('$', .{})) {
        tv.col = ncols -| 1;
    } else if (key.matches(vaxis.Key.enter, .{}) or key.matches('v', .{})) {
        if (nrows > 0) {
            tv.detail = true;
            tv.detail_scroll = 0;
        }
    } else if (key.matches('/', .{}) or key.matches('f', .{})) {
        tv.editing_filter = true;
        const current = if (tv.browse) |b| b.filter else tv.local_filter.items;
        try tv.filter_editor.setText(current);
        tv.completion.clearRetainingCapacity();
    } else if (key.matches('s', .{})) {
        return tv.toggleSort();
    } else if (key.matches('c', .{})) {
        if (tv.result.columns.len > 0) tv.chooser = .{ .sel = tv.curCol() };
    } else if (key.matches('x', .{})) {
        if (tv.result.columns.len > 0) {
            if (try tv.toggleColumn(tv.curCol())) |msg| return .{ .notice = msg };
        }
    } else if (key.matches('n', .{}) or key.matches(']', .{})) {
        return tv.nextPage();
    } else if (key.matches('p', .{}) or key.matches('[', .{})) {
        return tv.prevPage();
    } else if (key.matches('r', .{})) {
        if (tv.browse != null) return .reload;
    } else if (key.matches('y', .{})) {
        return .{ .copy = tv.currentValue() orelse "" };
    } else if (key.matches('Y', .{}) or key.matches('y', .{ .shift = true })) {
        return .{ .copy = try tv.rowAsTsv() };
    }
    return .none;
}

fn handleFilterKey(tv: *TableView, key: vaxis.Key) Allocator.Error!Action {
    const e = &tv.filter_editor;
    if (tv.completion.items.len > 0) {
        const n = tv.completion.items.len;
        if (key.matches(vaxis.Key.down, .{}) or key.matches('n', .{ .ctrl = true })) {
            tv.completion_sel = (tv.completion_sel + 1) % n;
            return .none;
        }
        if (key.matches(vaxis.Key.up, .{}) or key.matches('p', .{ .ctrl = true })) {
            tv.completion_sel = (tv.completion_sel + n - 1) % n;
            return .none;
        }
        if (key.matches(vaxis.Key.tab, .{}) or key.matches(vaxis.Key.enter, .{})) {
            try tv.acceptCompletion();
            return .none;
        }
        if (key.matches(vaxis.Key.escape, .{})) {
            tv.completion.clearRetainingCapacity();
            return .none;
        }
    }
    defer tv.updateCompletion() catch {};
    if (key.matches(vaxis.Key.escape, .{}) or key.matches('c', .{ .ctrl = true })) {
        tv.editing_filter = false;
    } else if (key.matches(vaxis.Key.enter, .{})) {
        tv.editing_filter = false;
        const text = std.mem.trim(u8, e.text(), " \t");
        if (tv.browse) |*b| {
            tv.gpa.free(b.filter);
            b.filter = try tv.gpa.dupe(u8, text);
            b.offset = 0;
            b.total = null;
            return .reload;
        }
        tv.local_filter.clearRetainingCapacity();
        try tv.local_filter.appendSlice(tv.gpa, text);
        tv.row = 0;
        tv.top = 0;
        try tv.rebuild();
    } else if (key.matches(vaxis.Key.backspace, .{})) {
        e.backspace();
    } else if (key.matches(vaxis.Key.delete, .{})) {
        e.deleteForward();
    } else if (key.matches(vaxis.Key.left, .{})) {
        e.left();
    } else if (key.matches(vaxis.Key.right, .{})) {
        e.right();
    } else if (key.matches(vaxis.Key.home, .{}) or key.matches('a', .{ .ctrl = true })) {
        e.home();
    } else if (key.matches(vaxis.Key.end, .{}) or key.matches('e', .{ .ctrl = true })) {
        e.end();
    } else if (key.matches('u', .{ .ctrl = true })) {
        e.killToLineStart();
    } else if (key.matches('w', .{ .ctrl = true })) {
        e.deleteWordLeft();
    } else if (key.text) |t| {
        if (!key.mods.ctrl and !key.mods.alt) try e.insert(t);
    }
    return .none;
}

fn handleChooserKey(tv: *TableView, key: vaxis.Key) Allocator.Error!Action {
    const ch = &tv.chooser.?;
    const n = tv.result.columns.len;
    if (key.matchesAny(&.{ vaxis.Key.escape, vaxis.Key.enter, 'q', 'c' }, .{}) or key.matches('c', .{ .ctrl = true })) {
        tv.chooser = null;
    } else if (key.matchesAny(&.{ vaxis.Key.down, 'j' }, .{})) {
        if (ch.sel + 1 < n) ch.sel += 1;
    } else if (key.matchesAny(&.{ vaxis.Key.up, 'k' }, .{})) {
        ch.sel -|= 1;
    } else if (key.matchesAny(&.{ vaxis.Key.page_down, vaxis.Key.end, 'G' }, .{})) {
        ch.sel = if (key.codepoint == vaxis.Key.page_down) @min(ch.sel + 10, n - 1) else n - 1;
    } else if (key.matchesAny(&.{ vaxis.Key.page_up, vaxis.Key.home, 'g' }, .{})) {
        ch.sel = if (key.codepoint == vaxis.Key.page_up) ch.sel -| 10 else 0;
    } else if (key.matchesAny(&.{ ' ', 'x' }, .{})) {
        if (try tv.toggleColumn(ch.sel)) |msg| return .{ .notice = msg };
    } else if (key.matches('a', .{})) {
        // show all
        @memset(tv.hidden.items, false);
        try tv.rebuildVisible();
    } else if (key.matches('o', .{})) {
        // only this column
        @memset(tv.hidden.items, true);
        tv.hidden.items[ch.sel] = false;
        try tv.rebuildVisible();
        tv.col = 0;
        tv.left = 0;
    }
    return .none;
}

const max_completions = 8;

fn filterLabel(tv: *const TableView) []const u8 {
    return if (tv.browse != null) " WHERE " else " filter ";
}

/// The identifier being typed before the cursor (with an opening quote, if any),
/// or null when the cursor is inside a string literal or comment.
fn completionWord(tv: *const TableView) ?[]const u8 {
    const e = &tv.filter_editor;
    const before = e.text()[0..e.cursor];
    var start = before.len;
    while (start > 0 and lexer.isIdentChar(before[start - 1])) start -= 1;
    if (start > 0 and (before[start - 1] == '"' or before[start - 1] == '`')) start -= 1;
    const word = before[start..];
    if (word.len == 0) return null;
    // Only complete outside of strings/comments: the token ending at the
    // cursor must be an identifier, keyword or quoted identifier.
    var it: lexer.Iterator = .init(before);
    var last: ?lexer.Token = null;
    while (it.next()) |t| last = t;
    const t = last orelse return null;
    if (t.end != before.len) return null;
    return switch (t.tag) {
        .identifier, .keyword, .builtin, .quoted_identifier => word,
        else => null,
    };
}

/// Recomputes column or SQL-operator suggestions before the cursor.
fn updateCompletion(tv: *TableView) Allocator.Error!void {
    tv.completion.clearRetainingCapacity();
    tv.completion_sel = 0;
    if (!tv.editing_filter) return;
    if (tv.browse) |b| {
        if (complete.operatorPrefix(tv.filter_editor.text(), tv.filter_editor.cursor, true)) |prefix| {
            tv.completion_len = prefix.len;
            for (complete.operators(b.kind)) |candidate| {
                if (tv.completion.items.len >= max_completions) return;
                if (!std.ascii.startsWithIgnoreCase(candidate.text, prefix)) continue;
                if (std.ascii.eqlIgnoreCase(candidate.text, prefix)) continue;
                try tv.completion.append(tv.gpa, candidate);
            }
            return;
        }
    }
    const word = tv.completionWord() orelse return;
    tv.completion_len = word.len;
    const needle = std.mem.trimStart(u8, word, "\"`");
    if (needle.len == 0) return;
    const cols = tv.result.columns;
    // Prefix matches first, then other substring matches; hidden columns are skipped.
    for ([_]bool{ true, false }) |prefix_pass| {
        for (tv.visible.items) |ci| {
            if (tv.completion.items.len >= max_completions) return;
            const name = cols[ci];
            const is_prefix = std.ascii.startsWithIgnoreCase(name, needle);
            if (is_prefix != prefix_pass) continue;
            if (!is_prefix and std.ascii.findIgnoreCase(name, needle) == null) continue;
            if (std.mem.eql(u8, name, needle)) continue; // already complete
            try tv.completion.append(tv.gpa, .{ .text = name, .kind = .column });
        }
    }
}

fn acceptCompletion(tv: *TableView) Allocator.Error!void {
    const candidate = tv.completion.items[tv.completion_sel];
    const a = tv.frame_arena.allocator();
    var text = candidate.text;
    var cursor_back: usize = 0;
    if (candidate.kind == .column) text = if (tv.browse) |b| try quoteIfNeeded(a, b.kind, text) else text;
    if (candidate.kind == .operator) {
        const snippet = complete.operatorSnippet(text);
        text = try std.mem.concat(a, u8, &.{ text, snippet.suffix });
        cursor_back = snippet.cursor_back;
    }
    try tv.filter_editor.replaceBeforeCursorAndMove(tv.completion_len, text, cursor_back);
    tv.completion.clearRetainingCapacity();
}

/// Plain lowercase identifiers stay as-is; anything else is quoted for the dialect.
fn quoteIfNeeded(a: Allocator, kind: Kind, name: []const u8) Allocator.Error![]const u8 {
    var plain = name.len > 0 and !std.ascii.isDigit(name[0]) and !lexer.isKeyword(name);
    for (name) |c| {
        const ok = if (kind == .mysql) std.ascii.isAlphanumeric(c) or c == '_' else std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '_';
        if (!ok) plain = false;
    }
    return if (plain) name else schema.quoteIdent(a, kind, name);
}

fn drawCompletion(tv: *TableView, a: Allocator, win: vaxis.Window, input_row: u16) Allocator.Error!void {
    const items = tv.completion.items;
    if (items.len == 0 or input_row < items.len) return;
    const e = &tv.filter_editor;
    const word_start = e.cursor - tv.completion_len;
    const x_raw = render.displayWidth(tv.filterLabel()) + render.displayWidth(e.text()[0..word_start]);
    var name_w: usize = 0;
    for (items) |candidate| name_w = @max(name_w, render.displayWidth(candidate.text));
    const w: u16 = @intCast(@min(name_w + 4, @as(usize, win.width)));
    const x: u16 = @intCast(@min(x_raw, @as(usize, win.width -| w)));
    const pop = win.child(.{
        .x_off = x,
        .y_off = @intCast(input_row - items.len),
        .width = w,
        .height = @intCast(items.len),
    });
    pop.fill(.{ .char = .{ .grapheme = " ", .width = 1 }, .style = .{ .bg = .{ .index = 0 } } });
    for (items, 0..) |candidate, i| {
        const sel = i == tv.completion_sel;
        const bg: vaxis.Color = if (sel) theme.selection_bg else .{ .index = 0 };
        if (sel) {
            var cx: u16 = 0;
            while (cx < pop.width) : (cx += 1) pop.writeCell(cx, @intCast(i), .{ .char = .{ .grapheme = " ", .width = 1 }, .style = .{ .bg = bg } });
        }
        const icon: []const u8 = if (candidate.kind == .operator) "=" else "◦";
        _ = pop.print(&.{
            .{ .text = " ", .style = .{ .bg = bg } },
            .{ .text = icon, .style = .{ .fg = if (sel) .{ .index = 15 } else theme.muted_color, .bg = bg } },
            .{ .text = " ", .style = .{ .bg = bg } },
            .{ .text = try a.dupe(u8, render.fitWidth(candidate.text, w -| 4).text), .style = .{ .fg = if (sel) .{ .index = 15 } else .default, .bg = bg, .bold = sel } },
        }, .{ .row_offset = @intCast(i), .wrap = .none });
    }
}

fn toggleSort(tv: *TableView) Allocator.Error!Action {
    if (tv.result.columns.len == 0) return .none;
    const name = tv.result.columns[tv.curCol()];
    if (tv.browse) |*b| {
        // asc -> desc -> none
        if (b.order) |o| {
            const same = std.mem.eql(u8, o.column, name);
            tv.gpa.free(o.column);
            b.order = if (same and !o.descending) .{ .column = try tv.gpa.dupe(u8, name), .descending = true } else if (same) null else .{ .column = try tv.gpa.dupe(u8, name) };
        } else {
            b.order = .{ .column = try tv.gpa.dupe(u8, name) };
        }
        b.offset = 0;
        return .reload;
    }
    const cc = tv.curCol();
    if (tv.local_sort) |s| {
        tv.local_sort = if (s.col == cc and !s.desc) .{ .col = cc, .desc = true } else if (s.col == cc) null else .{ .col = cc, .desc = false };
    } else {
        tv.local_sort = .{ .col = cc, .desc = false };
    }
    try tv.rebuild();
    return .none;
}

fn nextPage(tv: *TableView) Action {
    const b = &(tv.browse orelse return .none);
    if (tv.result.rows.len < b.page_size) return .{ .notice = "last page" };
    b.offset += b.page_size;
    return .reload;
}

fn prevPage(tv: *TableView) Action {
    const b = &(tv.browse orelse return .none);
    if (b.offset == 0) return .{ .notice = "first page" };
    b.offset -|= b.page_size;
    return .reload;
}

fn rowAsTsv(tv: *TableView) Allocator.Error![]const u8 {
    const a = tv.frame_arena.allocator();
    if (tv.view.items.len == 0) return "";
    const row = tv.result.rows[tv.view.items[tv.row]];
    var out: std.ArrayList(u8) = .empty;
    for (tv.visible.items, 0..) |ci, i| {
        if (i > 0) try out.append(a, '\t');
        try out.appendSlice(a, row[ci] orelse "NULL");
    }
    return out.items;
}

pub fn draw(tv: *TableView, win: vaxis.Window) Allocator.Error!void {
    _ = tv.frame_arena.reset(.retain_capacity);
    const a = tv.frame_arena.allocator();
    win.clear();
    if (win.height < 4 or win.width < 10) return;

    const r = tv.result;
    const footer_h: u16 = 2;
    const grid_h = win.height - footer_h;
    // title line + header + rule
    const body_h: usize = grid_h -| 3;
    tv.page_rows = @max(body_h, 1);

    // Title
    {
        var title: std.ArrayList(Segment) = .empty;
        try title.append(a, .{ .text = " ", .style = .{} });
        try title.append(a, .{ .text = tv.title, .style = theme.accent_bold });
        if (tv.browse) |b| {
            if (b.filter.len > 0) {
                try title.append(a, .{ .text = "  where ", .style = theme.dim });
                try title.appendSlice(a, try theme.highlight(a, b.filter, .{}));
            }
            if (b.order) |o| {
                try title.append(a, .{ .text = try std.fmt.allocPrint(a, "  order by {s}{s}", .{ o.column, if (o.descending) " desc" else "" }), .style = theme.dim });
            }
        } else if (tv.local_filter.items.len > 0) {
            try title.append(a, .{ .text = "  filter: ", .style = theme.dim });
            try title.append(a, .{ .text = tv.local_filter.items, .style = theme.warn });
        }
        _ = win.print(title.items, .{ .row_offset = 0, .wrap = .none });
    }

    if (r.columns.len == 0) {
        _ = win.printSegment(.{ .text = " no columns", .style = theme.dim }, .{ .row_offset = 2 });
        return;
    }

    // Keep the cursor visible.
    if (tv.row < tv.top) tv.top = tv.row;
    if (tv.row >= tv.top + body_h) tv.top = tv.row + 1 - body_h;
    if (tv.col < tv.left) tv.left = tv.col;
    const vis = tv.visible.items;
    const cur_col = tv.curCol();
    // Make sure the cursor column fits; shift `left` until it does.
    while (tv.left < tv.col) {
        var used: usize = 1;
        for (vis[tv.left .. tv.col + 1]) |ci| used += tv.widths.items[ci] + 3;
        if (used <= win.width) break;
        tv.left += 1;
    }

    // Visible positions [left, last_col) are drawn.
    var x: u16 = 1;
    var last_col = tv.left;
    while (last_col < vis.len) : (last_col += 1) {
        const w = tv.widths.items[vis[last_col]];
        if (x + w + 3 > win.width and last_col > tv.left) break;
        x += w + 3;
    }

    const grid = win.child(.{ .y_off = 1, .height = grid_h - 1 });

    // Header
    {
        var col_x: u16 = 0;
        for (vis[tv.left..last_col], tv.left..) |ci, pos| {
            const w = tv.widths.items[ci];
            var name: []const u8 = r.columns[ci];
            const marker: []const u8 = blk: {
                if (tv.browse) |b| if (b.order) |o| if (std.mem.eql(u8, o.column, name)) break :blk if (o.descending) " ↓" else " ↑";
                if (tv.local_sort) |s| if (s.col == ci) break :blk if (s.desc) " ↓" else " ↑";
                break :blk "";
            };
            if (marker.len > 0) name = try std.mem.concat(a, u8, &.{ name, marker });
            const style: vaxis.Style = if (ci == cur_col) .{ .fg = theme.accent } else theme.header;
            drawCell(grid, col_x, 0, w, name, style);
            if (pos + 1 < last_col) grid.writeCell(col_x + w + 2, 0, .{ .char = .{ .grapheme = "│", .width = 1 }, .style = theme.border });
            col_x += w + 3;
        }
        // rule
        var rule: std.ArrayList(u8) = .empty;
        for (vis[tv.left..last_col], tv.left..) |ci, pos| {
            const w = tv.widths.items[ci];
            for (0..w + 2) |_| try rule.appendSlice(a, "─");
            if (pos + 1 < last_col) try rule.appendSlice(a, "┼");
        }
        _ = grid.print(&.{.{ .text = rule.items, .style = theme.border }}, .{ .row_offset = 1, .wrap = .none });
    }

    // Body
    const end_row = @min(tv.top + body_h, tv.view.items.len);
    for (tv.top..end_row, 0..) |vi, screen_row| {
        const row = r.rows[tv.view.items[vi]];
        const y: u16 = @intCast(screen_row + 2);
        const is_cur_row = vi == tv.row;
        var col_x: u16 = 0;
        for (vis[tv.left..last_col], tv.left..) |ci, pos| {
            const w = tv.widths.items[ci];
            const v = row[ci];
            const text = try render.singleLine(a, v orelse render.null_text);
            var style: vaxis.Style = if (v == null) theme.null_value else .{};
            if (is_cur_row) style.bg = .{ .index = 8 };
            if (is_cur_row and ci == cur_col) style = theme.selected_cell;
            // fill the padding around the cell for the current row
            if (is_cur_row) fillRow(grid, col_x, y, w + 2, style);
            drawCell(grid, col_x, y, w, text, style);
            const sep_style: vaxis.Style = if (is_cur_row) .{ .fg = theme.muted_color, .bg = .{ .index = 8 } } else theme.border;
            if (pos + 1 < last_col) grid.writeCell(col_x + w + 2, y, .{ .char = .{ .grapheme = "│", .width = 1 }, .style = sep_style });
            col_x += w + 3;
        }
    }
    if (tv.view.items.len == 0) {
        _ = grid.printSegment(.{ .text = "  (no rows)", .style = theme.dim }, .{ .row_offset = 2 });
    }

    try tv.drawFooter(a, win.child(.{ .y_off = @intCast(win.height - footer_h), .height = footer_h }), last_col);
    if (tv.editing_filter) try tv.drawCompletion(a, win, win.height - footer_h);

    if (tv.detail) try tv.drawDetail(a, win);
    if (tv.chooser != null) try tv.drawChooser(a, win);
}

fn drawCell(win: vaxis.Window, x: u16, y: u16, width: u16, text: []const u8, style: vaxis.Style) void {
    const fit = render.fitWidth(text, width);
    var segs = [_]Segment{.{ .text = fit.text, .style = style }};
    _ = win.print(&segs, .{ .row_offset = y, .col_offset = x + 1, .wrap = .none });
    if (fit.text.len < text.len and width > 0) {
        // mark truncation in the last column of the cell
        win.writeCell(x + width, y, .{ .char = .{ .grapheme = "…", .width = 1 }, .style = .{ .fg = theme.muted_color, .bg = style.bg } });
    }
}

fn fillRow(win: vaxis.Window, x: u16, y: u16, width: u16, style: vaxis.Style) void {
    var i: u16 = 0;
    while (i < width) : (i += 1) {
        win.writeCell(x + i, y, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = .{ .bg = style.bg } });
    }
}

fn drawFooter(tv: *TableView, a: Allocator, win: vaxis.Window, last_col: usize) Allocator.Error!void {
    const r = tv.result;
    // Line 1: position / filter editor
    if (tv.editing_filter) {
        const label = tv.filterLabel();
        var segs: std.ArrayList(Segment) = .empty;
        try segs.append(a, .{ .text = label, .style = theme.accent_bold });
        const text = tv.filter_editor.text();
        if (tv.browse != null) {
            try segs.appendSlice(a, try theme.highlight(a, text, .{}));
        } else {
            try segs.append(a, .{ .text = text });
        }
        _ = win.print(segs.items, .{ .row_offset = 0, .wrap = .none });
        const cursor_col = render.displayWidth(label) + render.displayWidth(text[0..tv.filter_editor.cursor]);
        win.showCursor(@intCast(@min(cursor_col, win.width -| 1)), 0);
    } else {
        var info: std.ArrayList(u8) = .empty;
        const col_name = if (r.columns.len > 0) r.columns[tv.curCol()] else "";
        if (tv.browse) |b| {
            const first = b.offset + 1;
            const last = b.offset + r.rows.len;
            if (r.rows.len == 0) {
                try info.print(a, " no rows", .{});
            } else {
                try info.print(a, " rows {d}–{d}", .{ first, last });
                if (b.total) |t| try info.print(a, " of {d}", .{t});
                try info.print(a, " · row {d}", .{b.offset + tv.row + 1});
            }
        } else {
            try info.print(a, " row {d}/{d}", .{ if (tv.view.items.len == 0) 0 else tv.row + 1, tv.view.items.len });
            if (tv.view.items.len != r.rows.len) try info.print(a, " (of {d})", .{r.rows.len});
        }
        try info.print(a, " · col {d}/{d} {s}", .{ tv.col + 1, tv.visible.items.len, col_name });
        if (last_col < tv.visible.items.len) try info.print(a, " · {d} more →", .{tv.visible.items.len - last_col});
        if (tv.hiddenCount() > 0) try info.print(a, " · {d} hidden", .{tv.hiddenCount()});
        var segs: std.ArrayList(Segment) = .empty;
        try segs.append(a, .{ .text = info.items, .style = theme.bold });
        if (tv.notice) |n| try segs.append(a, .{ .text = try std.fmt.allocPrint(a, "  {s}", .{n}), .style = theme.warn });
        _ = win.print(segs.items, .{ .row_offset = 0, .wrap = .none });
        win.hideCursor();
    }

    const hint: []const u8 = if (tv.chooser != null)
        " ↑↓ move · space show/hide · a show all · o only this · esc done"
    else if (tv.editing_filter)
        (if (tv.completion.items.len > 0)
            " ↑↓ choose column · tab/enter insert · esc hide suggestions"
        else if (tv.browse != null)
            " enter apply · esc cancel · empty clears · columns and operators autocomplete"
        else
            " text · col:text · col=value · enter apply · esc cancel")
    else if (tv.browse != null)
        " ↑↓←→ move · enter cell · / where · s sort · c columns · x hide · n/p page · y copy · q back"
    else
        " ↑↓←→ move · enter cell · / filter · s sort · c columns · x hide · y/Y copy · q back";
    _ = win.print(&.{.{ .text = hint, .style = theme.dim }}, .{ .row_offset = 1, .wrap = .none });
}

fn drawDetail(tv: *TableView, a: Allocator, win: vaxis.Window) Allocator.Error!void {
    const value = tv.currentValue();
    const w: u16 = @min(win.width -| 4, 100);
    var lines: std.ArrayList(Transcript.Line) = .empty;
    const segs: []const Segment = if (value) |v|
        &.{.{ .text = v }}
    else
        &.{.{ .text = "NULL", .style = theme.null_value }};
    try Transcript.wrapWithPrefix(a, &lines, segs, w -| 2, .{ .text = "" }, "");
    // title + blank line + content + borders
    const h: u16 = @intCast(@min(@as(usize, win.height -| 4), lines.items.len + 4));
    const box = win.child(.{
        .x_off = @intCast((win.width - w) / 2),
        .y_off = @intCast((win.height - h) / 2),
        .width = w,
        .height = h,
        .border = .{ .where = .all, .style = theme.border_focus },
    });
    box.clear();
    const col_name = tv.result.columns[tv.curCol()];
    _ = box.print(&.{
        .{ .text = col_name, .style = theme.accent_bold },
        .{ .text = "  esc close · y copy · ↑↓ scroll", .style = theme.dim },
    }, .{ .row_offset = 0, .wrap = .none });

    const body_h = box.height -| 2;
    tv.detail_scroll = @min(tv.detail_scroll, lines.items.len -| body_h);
    for (lines.items[tv.detail_scroll..], 0..) |line, i| {
        if (i >= body_h) break;
        _ = box.print(line, .{ .row_offset = @intCast(i + 2), .wrap = .none });
    }
}

/// Column chooser: a checklist of all columns over the grid.
fn drawChooser(tv: *TableView, a: Allocator, win: vaxis.Window) Allocator.Error!void {
    const ch = &tv.chooser.?;
    const cols = tv.result.columns;
    var name_w: usize = 0;
    for (cols) |c| name_w = @max(name_w, render.displayWidth(c));
    const title = "Columns";
    const w: u16 = @intCast(@min(@as(usize, win.width -| 4), @max(name_w + 8, 34)));
    const visible: usize = @min(cols.len, @as(usize, win.height -| 8), 20);
    // borders (2) + title + blank line
    const h: u16 = @intCast(visible + 4);
    const box = win.child(.{
        .x_off = @intCast((win.width -| w) / 2),
        .y_off = @intCast(@max((win.height -| h) / 3, 1)),
        .width = w,
        .height = h,
        .border = .{ .where = .all, .style = theme.border_focus },
    });
    box.clear();
    const counter = try std.fmt.allocPrint(a, "{d}/{d} shown", .{ tv.visible.items.len, cols.len });
    _ = box.print(&.{.{ .text = title, .style = theme.accent_bold }}, .{ .row_offset = 0, .col_offset = 1, .wrap = .none });
    _ = box.print(&.{.{ .text = counter, .style = theme.dim }}, .{
        .row_offset = 0,
        .col_offset = box.width -| @as(u16, @intCast(counter.len + 1)),
        .wrap = .none,
    });

    if (ch.sel < ch.top) ch.top = ch.sel;
    if (ch.sel >= ch.top + visible) ch.top = ch.sel + 1 - visible;
    for (cols[ch.top..][0..visible], ch.top..) |name, ci| {
        const sel = ci == ch.sel;
        const row: u16 = @intCast(ci - ch.top + 2);
        const shown = !tv.hidden.items[ci];
        const bg: vaxis.Color = if (sel) theme.selection_bg else .default;
        if (sel) {
            var x: u16 = 0;
            while (x < box.width) : (x += 1) box.writeCell(x, row, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = .{ .bg = bg } });
        }
        _ = box.print(&.{
            .{ .text = " ", .style = .{ .bg = bg } },
            .{ .text = if (shown) "[✓] " else "[ ] ", .style = .{ .fg = if (shown) theme.accent else theme.muted_color, .bg = bg, .bold = shown } },
            .{ .text = render.fitWidth(name, box.width -| 6).text, .style = .{ .bg = bg, .fg = if (shown) .default else theme.muted_color, .bold = sel } },
        }, .{ .row_offset = row, .wrap = .none });
    }
}
