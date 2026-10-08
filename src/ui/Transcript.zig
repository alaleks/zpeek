//! The scrollback of commands and their results, laid out into lines that fit
//! the current width. Layout is cached per entry and redone on resize.

const std = @import("std");
const Allocator = std.mem.Allocator;
const vaxis = @import("vaxis");
const Segment = vaxis.Segment;
const Style = vaxis.Style;
const db = @import("../db/db.zig");
const render = @import("../render.zig");
const theme = @import("theme.zig");

const Transcript = @This();

pub const Line = []const Segment;

pub const MessageKind = enum { info, ok, err, dim, warn };

pub const Content = union(enum) {
    /// A command or SQL typed by the user.
    input: []const u8,
    result: struct {
        result: db.Result,
        elapsed_ms: i64,
        /// Optional heading, e.g. "Tables" or the statement for multi-statement runs.
        title: ?[]const u8 = null,
    },
    message: struct { kind: MessageKind, text: []const u8 },
    /// SQL source shown with highlighting (function/view definitions).
    code: []const u8,
    /// Free-form pre-styled lines (help, welcome banner).
    lines: []const Line,
};

pub const Entry = struct {
    arena: std.heap.ArenaAllocator,
    content: Content,
    layout_arena: std.heap.ArenaAllocator,
    layout: []const Line = &.{},
    layout_width: u16 = 0,

    fn deinit(e: *Entry) void {
        if (e.content == .result) e.content.result.result.deinit();
        e.layout_arena.deinit();
        e.arena.deinit();
    }
};

/// Max rows of a result shown inline; the rest is in the table viewer.
pub const inline_rows = 50;
const max_col_width = 40;

gpa: Allocator,
entries: std.ArrayList(*Entry) = .empty,
/// Lines scrolled up from the bottom.
scroll: usize = 0,
/// Total line count from the last draw, used to clamp scrolling.
total_lines: usize = 0,

pub fn init(gpa: Allocator) Transcript {
    return .{ .gpa = gpa };
}

pub fn deinit(t: *Transcript) void {
    for (t.entries.items) |e| {
        e.deinit();
        t.gpa.destroy(e);
    }
    t.entries.deinit(t.gpa);
}

pub fn clear(t: *Transcript) void {
    for (t.entries.items) |e| {
        e.deinit();
        t.gpa.destroy(e);
    }
    t.entries.clearRetainingCapacity();
    t.scroll = 0;
}

/// Adds an entry; string data in `content` is copied.
pub fn add(t: *Transcript, content: Content) Allocator.Error!void {
    const e = try t.gpa.create(Entry);
    errdefer t.gpa.destroy(e);
    e.* = .{ .arena = .init(t.gpa), .layout_arena = .init(t.gpa), .content = undefined };
    const a = e.arena.allocator();
    e.content = switch (content) {
        .input => |s| .{ .input = try a.dupe(u8, s) },
        .result => |r| .{ .result = .{
            .result = r.result,
            .elapsed_ms = r.elapsed_ms,
            .title = if (r.title) |s| try a.dupe(u8, s) else null,
        } },
        .message => |m| .{ .message = .{ .kind = m.kind, .text = try a.dupe(u8, m.text) } },
        .code => |s| .{ .code = try a.dupe(u8, s) },
        .lines => |lines| .{ .lines = try dupeLines(a, lines) },
    };
    try t.entries.append(t.gpa, e);
    t.scroll = 0;
}

pub fn addMessage(t: *Transcript, kind: MessageKind, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
    const s = try std.fmt.allocPrint(t.gpa, fmt, args);
    defer t.gpa.free(s);
    try t.add(.{ .message = .{ .kind = kind, .text = s } });
}

fn dupeLines(a: Allocator, lines: []const Line) Allocator.Error![]const Line {
    const out = try a.alloc(Line, lines.len);
    for (lines, out) |line, *o| {
        const segs = try a.alloc(Segment, line.len);
        for (line, segs) |s, *d| d.* = .{ .text = try a.dupe(u8, s.text), .style = s.style };
        o.* = segs;
    }
    return out;
}

/// Index of the newest entry holding a result with rows.
pub fn lastResult(t: *const Transcript) ?*db.Result {
    var i = t.entries.items.len;
    while (i > 0) {
        i -= 1;
        const e = t.entries.items[i];
        if (e.content == .result and e.content.result.result.hasRows()) return &e.content.result.result;
    }
    return null;
}

pub fn scrollBy(t: *Transcript, delta: isize, viewport: u16) void {
    const max = t.total_lines -| viewport;
    if (delta < 0) {
        t.scroll -|= @intCast(-delta);
    } else {
        t.scroll = @min(t.scroll + @as(usize, @intCast(delta)), max);
    }
}

pub fn draw(t: *Transcript, win: vaxis.Window) Allocator.Error!void {
    if (win.height == 0 or win.width == 0) return;
    var total: usize = 0;
    for (t.entries.items, 0..) |e, i| {
        try ensureLayout(e, win.width);
        total += e.layout.len;
        if (i + 1 < t.entries.items.len and gapAfter(e, t.entries.items[i + 1])) total += 1;
    }
    t.total_lines = total;
    t.scroll = @min(t.scroll, total -| win.height);

    // Walk lines from the bottom up and draw those inside the viewport.
    const bottom_skip = t.scroll;
    var row: isize = @as(isize, win.height) - 1;
    var skipped: usize = 0;
    var i = t.entries.items.len;
    outer: while (i > 0) {
        i -= 1;
        const e = t.entries.items[i];
        const gap: usize = if (i + 1 < t.entries.items.len and gapAfter(e, t.entries.items[i + 1])) 1 else 0;
        // gap line
        if (gap == 1) {
            if (skipped < bottom_skip) skipped += 1 else {
                row -= 1;
                if (row < 0) break :outer;
            }
        }
        var l = e.layout.len;
        while (l > 0) {
            l -= 1;
            if (skipped < bottom_skip) {
                skipped += 1;
                continue;
            }
            _ = win.print(e.layout[l], .{ .row_offset = @intCast(row), .wrap = .none });
            row -= 1;
            if (row < 0) break :outer;
        }
    }
}

fn gapAfter(e: *const Entry, next: *const Entry) bool {
    // Keep a command visually attached to its output.
    _ = e;
    return next.content == .input or next.content == .lines;
}

fn ensureLayout(e: *Entry, width: u16) Allocator.Error!void {
    if (e.layout_width == width and e.layout.len > 0) return;
    _ = e.layout_arena.reset(.retain_capacity);
    const a = e.layout_arena.allocator();
    var lines: std.ArrayList(Line) = .empty;
    switch (e.content) {
        .input => |s| {
            const segs = try theme.highlight(a, s, .{});
            try wrapWithPrefix(a, &lines, segs, width, .{ .text = "❯ ", .style = theme.accent_bold }, "  ");
        },
        .message => |m| {
            const style: Style = switch (m.kind) {
                .info => theme.plain,
                .ok => theme.ok,
                .err => theme.err,
                .dim => theme.dim,
                .warn => theme.warn,
            };
            const segs = try a.dupe(Segment, &.{.{ .text = m.text, .style = style }});
            try wrapWithPrefix(a, &lines, segs, width, .{ .text = "  ⎿ ", .style = theme.dim }, "    ");
        },
        .code => |s| {
            const segs = try theme.highlight(a, s, .{});
            try wrapWithPrefix(a, &lines, segs, width, .{ .text = "  ", .style = .{} }, "  ");
        },
        .lines => |ls| {
            for (ls) |line| try lines.append(a, line);
        },
        .result => |r| try layoutResult(a, &lines, r.result, r.elapsed_ms, r.title, width),
    }
    e.layout = lines.items;
    e.layout_width = width;
}

/// Wraps segments to `width`, splitting on newlines. The first line gets
/// `first`, following lines get `cont` as prefix.
pub fn wrapWithPrefix(
    a: Allocator,
    out: *std.ArrayList(Line),
    segs: []const Segment,
    width: u16,
    first: Segment,
    cont: []const u8,
) Allocator.Error!void {
    const prefix_w = render.displayWidth(first.text);
    const avail: usize = @max(@as(usize, width) -| prefix_w, 8);
    var line: std.ArrayList(Segment) = .empty;
    try line.append(a, first);
    var col: usize = 0;

    for (segs) |seg| {
        var rest = seg.text;
        while (rest.len > 0) {
            if (rest[0] == '\n') {
                try out.append(a, line.items);
                line = .empty;
                try line.append(a, .{ .text = cont, .style = first.style });
                col = 0;
                rest = rest[1..];
                continue;
            }
            const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
            const piece = rest[0..nl];
            const fit = render.fitWidth(piece, avail - col);
            if (fit.text.len == 0 and col > 0) {
                // wrap
                try out.append(a, line.items);
                line = .empty;
                try line.append(a, .{ .text = cont, .style = first.style });
                col = 0;
                continue;
            }
            const take = if (fit.text.len == 0) firstGrapheme(piece) else fit.text;
            try line.append(a, .{ .text = take, .style = seg.style });
            col += render.displayWidth(take);
            rest = rest[take.len..];
            if (rest.len > 0 and rest[0] != '\n' and col >= avail) {
                try out.append(a, line.items);
                line = .empty;
                try line.append(a, .{ .text = cont, .style = first.style });
                col = 0;
            }
        }
    }
    try out.append(a, line.items);
}

fn firstGrapheme(s: []const u8) []const u8 {
    var it = vaxis.unicode.graphemeIterator(s);
    const g = it.next() orelse return s;
    return g.bytes(s);
}

fn layoutResult(
    a: Allocator,
    out: *std.ArrayList(Line),
    r: db.Result,
    elapsed_ms: i64,
    title: ?[]const u8,
    width: u16,
) Allocator.Error!void {
    if (title) |t| try out.append(a, try a.dupe(Segment, &.{
        .{ .text = "  " },
        .{ .text = t, .style = theme.bold },
    }));

    if (!r.hasRows()) {
        const status = try std.fmt.allocPrint(a, "{s} · {d} ms", .{ if (r.status.len > 0) r.status else "OK", elapsed_ms });
        try out.append(a, try a.dupe(Segment, &.{
            .{ .text = "  ⎿ ", .style = theme.dim },
            .{ .text = status, .style = theme.ok },
        }));
        return;
    }

    const shown_rows = @min(r.rows.len, inline_rows);
    const ncols = r.columns.len;
    const widths = try a.alloc(usize, ncols);
    const header = try a.alloc([]const u8, ncols);
    for (r.columns, 0..) |name, i| {
        header[i] = try cellText(a, name);
        widths[i] = render.displayWidth(header[i]);
    }
    const cells = try a.alloc(?[]const u8, ncols * shown_rows);
    for (r.rows[0..shown_rows], 0..) |row, ri| {
        for (row, 0..) |v, i| {
            const t = if (v) |s| try cellText(a, s) else null;
            cells[ri * ncols + i] = t;
            widths[i] = @max(widths[i], render.displayWidth(t orelse render.null_text));
        }
    }

    // Fit columns into the width: indent(2) + "│" + per column (w + 3).
    const avail: usize = @as(usize, width) -| 3;
    var used: usize = 1;
    var visible: usize = 0;
    for (widths) |w| {
        if (used + w + 3 > avail) break;
        used += w + 3;
        visible += 1;
    }
    if (visible == 0) {
        visible = 1;
        widths[0] = @max(avail -| 4, 1);
    }
    const hidden = ncols - visible;

    try out.append(a, try ruleLine(a, widths[0..visible], "  ┌", "┬", "┐", hidden > 0));
    {
        var line: std.ArrayList(Segment) = .empty;
        try line.append(a, .{ .text = "  │", .style = theme.border });
        for (header[0..visible], widths[0..visible]) |h, w| try appendCell(a, &line, h, w, theme.header);
        if (hidden > 0) try line.append(a, .{ .text = " …", .style = theme.dim });
        try out.append(a, line.items);
    }
    try out.append(a, try ruleLine(a, widths[0..visible], "  ├", "┼", "┤", hidden > 0));
    for (0..shown_rows) |ri| {
        var line: std.ArrayList(Segment) = .empty;
        try line.append(a, .{ .text = "  │", .style = theme.border });
        for (0..visible) |i| {
            const v = cells[ri * ncols + i];
            try appendCell(a, &line, v orelse render.null_text, widths[i], if (v == null) theme.null_value else theme.plain);
        }
        if (hidden > 0) try line.append(a, .{ .text = " …", .style = theme.dim });
        try out.append(a, line.items);
    }
    try out.append(a, try ruleLine(a, widths[0..visible], "  └", "┴", "┘", hidden > 0));

    var status: std.ArrayList(u8) = .empty;
    try status.print(a, "{s} · {d} ms", .{ r.status, elapsed_ms });
    if (r.truncated) try status.appendSlice(a, " · row limit reached");
    if (shown_rows < r.rows.len or hidden > 0) {
        try status.appendSlice(a, " · ");
        if (shown_rows < r.rows.len) try status.print(a, "showing {d} of {d} rows", .{ shown_rows, r.rows.len });
        if (shown_rows < r.rows.len and hidden > 0) try status.appendSlice(a, ", ");
        if (hidden > 0) try status.print(a, "{d} column{s} hidden", .{ hidden, if (hidden == 1) "" else "s" });
        try status.appendSlice(a, " — ctrl+o to open");
    }
    try out.append(a, try a.dupe(Segment, &.{
        .{ .text = "  ⎿ ", .style = theme.dim },
        .{ .text = status.items, .style = theme.dim },
    }));
}

fn cellText(a: Allocator, s: []const u8) Allocator.Error![]const u8 {
    const one = try render.singleLine(a, s);
    const fit = render.fitWidth(one, max_col_width);
    if (fit.text.len == one.len) return one;
    return std.mem.concat(a, u8, &.{ render.fitWidth(one, max_col_width - 1).text, "…" });
}

fn appendCell(a: Allocator, line: *std.ArrayList(Segment), text: []const u8, width: usize, style: Style) Allocator.Error!void {
    const fit = render.fitWidth(text, width);
    const pad = width - fit.width;
    try line.append(a, .{ .text = " " });
    try line.append(a, .{ .text = fit.text, .style = style });
    if (pad > 0) try line.append(a, .{ .text = try spaces(a, pad) });
    try line.append(a, .{ .text = " │", .style = theme.border });
}

fn ruleLine(a: Allocator, widths: []const usize, l: []const u8, m: []const u8, r: []const u8, more: bool) Allocator.Error!Line {
    var s: std.ArrayList(u8) = .empty;
    try s.appendSlice(a, l);
    for (widths, 0..) |w, i| {
        if (i > 0) try s.appendSlice(a, m);
        for (0..w + 2) |_| try s.appendSlice(a, "─");
    }
    try s.appendSlice(a, r);
    if (more) try s.appendSlice(a, " ");
    return a.dupe(Segment, &.{.{ .text = s.items, .style = theme.border }});
}

pub fn spaces(a: Allocator, n: usize) Allocator.Error![]const u8 {
    const s = try a.alloc(u8, n);
    @memset(s, ' ');
    return s;
}
