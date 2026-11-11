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
        /// Row count before `compact` dropped the rows the feed never shows.
        total_rows: ?usize = null,
        /// Full-screen schema views show every retained row.
        expanded: bool = false,
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
    retained_bytes: usize = 0,

    fn deinit(e: *Entry) void {
        if (e.content == .result) e.content.result.result.deinit();
        e.layout_arena.deinit();
        e.arena.deinit();
    }
};

/// Max rows of a result shown inline; the rest is in the table viewer.
pub const inline_rows = 50;
const max_col_width = 40;
pub const max_entries = 200;
pub const max_retained_bytes = 64 * 1024 * 1024;

gpa: Allocator,
entries: std.ArrayList(*Entry) = .empty,
/// Lines scrolled up from the bottom.
scroll: usize = 0,
/// Total line count from the last draw, used to clamp scrolling.
total_lines: usize = 0,
layout_width: u16 = 0,
layout_dirty: bool = true,
retained_bytes: usize = 0,

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
    t.total_lines = 0;
    t.layout_dirty = true;
    t.retained_bytes = 0;
}

/// Adds an entry; string data in `content` is copied.
pub fn add(t: *Transcript, content: Content) Allocator.Error!void {
    const e = try t.gpa.create(Entry);
    errdefer t.gpa.destroy(e);
    e.* = .{ .arena = .init(t.gpa), .layout_arena = .init(t.gpa), .content = undefined };
    errdefer e.arena.deinit();
    errdefer e.layout_arena.deinit();
    const a = e.arena.allocator();
    e.content = switch (content) {
        .input => |s| .{ .input = try a.dupe(u8, s) },
        .result => |r| .{ .result = .{
            .result = r.result,
            .elapsed_ms = r.elapsed_ms,
            .title = if (r.title) |s| try a.dupe(u8, s) else null,
            .total_rows = r.total_rows,
            .expanded = r.expanded,
        } },
        .message => |m| .{ .message = .{ .kind = m.kind, .text = try a.dupe(u8, m.text) } },
        .code => |s| .{ .code = try a.dupe(u8, s) },
        .lines => |lines| .{ .lines = try dupeLines(a, lines) },
    };
    e.retained_bytes = switch (e.content) {
        .input => |s| s.len,
        .result => |r| r.result.retained_bytes,
        .message => |m| m.text.len,
        .code => |s| s.len,
        .lines => |lines| blk: {
            var size: usize = 0;
            for (lines) |line| for (line) |segment| {
                size +|= segment.text.len;
            };
            break :blk size;
        },
    };
    try t.entries.append(t.gpa, e);
    t.retained_bytes +|= e.retained_bytes;
    t.scroll = 0;
    t.layout_dirty = true;
}

/// Older results keep only the rows the feed shows: ctrl+o opens just the
/// newest one. Like `prune`, call only when no table view borrows a result.
pub fn compact(t: *Transcript) Allocator.Error!void {
    const newest = t.lastResult();
    for (t.entries.items) |e| {
        if (e.content != .result) continue;
        const r = &e.content.result.result;
        if (r == newest or e.content.result.total_rows != null) continue;
        try t.compactEntry(e);
    }
}

fn compactEntry(t: *Transcript, e: *Entry) Allocator.Error!void {
    const old = &e.content.result.result;
    var arena: std.heap.ArenaAllocator = .init(t.gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    // Everything is copied before `arena` is moved into the new Result.
    const columns = try a.alloc([]const u8, old.columns.len);
    for (columns, old.columns) |*dst, src| dst.* = try a.dupe(u8, src);
    const boolean_columns = try a.dupe(bool, old.boolean_columns);
    const status = try a.dupe(u8, old.status);
    var bytes: usize = 0;
    const shown_rows = @min(inline_rows, old.rows.len);
    const rows = try a.alloc([]const ?[]const u8, shown_rows);
    for (rows, old.rows[0..shown_rows]) |*dst, row| {
        const cells = try a.alloc(?[]const u8, row.len);
        for (cells, row) |*cell, value| {
            cell.* = if (value) |v| blk: {
                const preview = try render.preview(a, v, max_col_width);
                break :blk if (preview.ptr == v.ptr) try a.dupe(u8, preview) else preview;
            } else null;
            bytes += if (cell.*) |v| v.len else 0;
        }
        bytes += cells.len * @sizeOf(?[]const u8);
        dst.* = cells;
    }
    const total = old.rows.len;
    var dropped = old.*;
    old.* = .{
        .arena = arena,
        .columns = columns,
        .boolean_columns = boolean_columns,
        .rows = rows,
        .affected_rows = dropped.affected_rows,
        .elapsed_ms = dropped.elapsed_ms,
        .status = status,
        .truncated = dropped.truncated,
        .retained_bytes = bytes,
    };
    dropped.deinit();
    e.content.result.total_rows = total;
    // The cached layout pointed into the dropped arena.
    _ = e.layout_arena.reset(.{ .retain_with_limit = render.scratch_limit });
    e.layout = &.{};
    e.layout_width = 0;
    t.retained_bytes -|= e.retained_bytes;
    e.retained_bytes = bytes;
    t.retained_bytes +|= bytes;
    t.layout_dirty = true;
}

test "compact stores previews even for a single large cell and preserves newest result" {
    const a = std.testing.allocator;
    var transcript: Transcript = .init(a);
    defer transcript.deinit();
    for (0..2) |_| {
        var builder = db.ResultBuilder.init(a);
        errdefer builder.deinit();
        const value = try builder.allocator().alloc(u8, 1024 * 1024);
        @memset(value, 'x');
        try builder.setColumns(&.{"large"});
        const row = try builder.allocator().alloc(?[]const u8, 1);
        row[0] = value;
        try builder.addRow(row, .{});
        try transcript.add(.{ .result = .{ .result = builder.finish(), .elapsed_ms = 0 } });
    }
    try transcript.compact();
    const older = &transcript.entries.items[0].content.result.result;
    try std.testing.expect(older.rows[0][0].?.len < 128);
    try std.testing.expect(std.mem.endsWith(u8, older.rows[0][0].?, "…"));
    try std.testing.expect(older.arena.queryCapacity() < 8192);
    try std.testing.expectEqual(@as(usize, 1024 * 1024), transcript.lastResult().?.rows[0][0].?.len);
    const capacity = older.arena.queryCapacity();
    try transcript.compact();
    try std.testing.expectEqual(capacity, older.arena.queryCapacity());
    try ensureLayout(transcript.entries.items[0], 80);
}

test "compact keeps shown rows of older results only" {
    const gpa = std.testing.allocator;
    var transcript: Transcript = .init(gpa);
    defer transcript.deinit();
    for (0..2) |_| {
        var b = db.ResultBuilder.init(gpa);
        errdefer b.deinit();
        try b.setColumns(try b.allocator().dupe([]const u8, &.{ "id", "name" }));
        for (0..inline_rows + 30) |i| {
            const row = try b.allocator().alloc(?[]const u8, 2);
            row[0] = try std.fmt.allocPrint(b.allocator(), "{d}", .{i});
            row[1] = if (i % 2 == 0) null else "x";
            try b.addRow(row, .{});
        }
        b.result.status = "80 rows";
        try transcript.add(.{ .result = .{ .result = b.finish(), .elapsed_ms = 1 } });
    }
    try transcript.compact();
    const older = transcript.entries.items[0].content.result;
    try std.testing.expectEqual(@as(usize, inline_rows), older.result.rows.len);
    try std.testing.expectEqual(@as(?usize, inline_rows + 30), older.total_rows);
    try std.testing.expectEqualStrings("49", older.result.rows[49][0].?);
    try std.testing.expect(older.result.rows[0][1] == null);
    try std.testing.expectEqualStrings("80 rows", older.result.status);
    // The newest result stays complete for ctrl+o.
    try std.testing.expectEqual(@as(usize, inline_rows + 30), transcript.lastResult().?.rows.len);
    // Layout still renders "showing 50 of 80".
    try ensureLayout(transcript.entries.items[0], 100);
    const status_line = transcript.entries.items[0].layout[transcript.entries.items[0].layout.len - 1];
    var found = false;
    for (status_line) |seg| {
        if (std.mem.indexOf(u8, seg.text, "showing 50 of 80 rows") != null) found = true;
    }
    try std.testing.expect(found);
}

/// Drops old entries after the App has released any borrowed table result.
pub fn prune(t: *Transcript) void {
    while (t.entries.items.len > 1 and
        (t.entries.items.len > max_entries or t.retained_bytes > max_retained_bytes))
    {
        const oldest = t.entries.orderedRemove(0);
        t.retained_bytes -= oldest.retained_bytes;
        oldest.deinit();
        t.gpa.destroy(oldest);
        t.layout_dirty = true;
    }
}

test "layout rebuild releases oversized scratch capacity" {
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    var transcript: Transcript = .init(std.testing.allocator);
    defer transcript.deinit();
    try transcript.add(.{ .input = "select 1" });
    const entry = transcript.entries.items[0];
    try ensureLayout(entry, 80);
    _ = try entry.layout_arena.allocator().alloc(u8, render.scratch_limit * 4);
    try std.testing.expect(entry.layout_arena.queryCapacity() > render.scratch_limit);
    try ensureLayout(entry, 79);
    try std.testing.expect(entry.layout.len > 0);
    try std.testing.expect(entry.layout_arena.queryCapacity() <= render.scratch_limit);
    const large = try entry.arena.allocator().alloc(u8, render.scratch_limit * 4);
    @memset(large, 'x');
    entry.content.input = large;
    entry.layout_arena.child_allocator = failing.allocator();
    try std.testing.expectError(error.OutOfMemory, ensureLayout(entry, 80));
    try std.testing.expectEqual(@as(usize, 0), entry.layout.len);
    try std.testing.expectEqual(@as(u16, 0), entry.layout_width);
    entry.layout_arena.child_allocator = std.testing.allocator;
    entry.content.input = "select 1";
    try ensureLayout(entry, 79);
    try std.testing.expect(entry.layout.len > 0);
}

test "narrow result layout clips measured cells to the forced width" {
    const a = std.testing.allocator;
    var transcript: Transcript = .init(a);
    defer transcript.deinit();
    var builder = db.ResultBuilder.init(a);
    errdefer builder.deinit();
    try builder.setColumns(&.{"value"});
    const row = try builder.allocator().alloc(?[]const u8, 1);
    row[0] = "abc";
    try builder.addRow(row, .{});
    try transcript.add(.{ .result = .{ .result = builder.finish(), .elapsed_ms = 0 } });
    const entry = transcript.entries.items[0];
    try ensureLayout(entry, 8);
    try std.testing.expectEqualStrings("a", entry.layout[3][2].text);
}

test "prune old transcript entries" {
    var transcript: Transcript = .init(std.testing.allocator);
    defer transcript.deinit();
    for (0..max_entries + 1) |_| try transcript.add(.{ .input = "select 1" });
    transcript.prune();
    try std.testing.expectEqual(@as(usize, max_entries), transcript.entries.items.len);
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
    if (t.layout_dirty or t.layout_width != win.width) {
        var total: usize = 0;
        for (t.entries.items, 0..) |e, i| {
            try ensureLayout(e, win.width);
            total += e.layout.len;
            if (i + 1 < t.entries.items.len and gapAfter(e, t.entries.items[i + 1])) total += 1;
        }
        t.total_lines = total;
        t.layout_width = win.width;
        t.layout_dirty = false;
    }
    t.scroll = @min(t.scroll, t.total_lines -| win.height);

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
    e.layout = &.{};
    e.layout_width = 0;
    _ = e.layout_arena.reset(.{ .retain_with_limit = render.scratch_limit });
    const a = e.layout_arena.allocator();
    var lines: std.ArrayList(Line) = .empty;
    switch (e.content) {
        .input => |s| {
            const segs = try theme.highlight(a, s, .{});
            try wrapWithPrefix(a, &lines, segs, width, .{ .text = "> ", .style = theme.accent_bold }, "  ");
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
            try wrapWithPrefix(a, &lines, segs, width, .{ .text = "  └ ", .style = theme.dim }, "    ");
        },
        .code => |s| {
            const segs = try theme.highlight(a, s, .{});
            try wrapWithPrefix(a, &lines, segs, width, .{ .text = "  ", .style = .{} }, "  ");
        },
        .lines => |ls| {
            for (ls) |line| try lines.append(a, line);
        },
        .result => |r| try layoutResult(a, &lines, r.result, r.total_rows orelse r.result.rows.len, r.elapsed_ms, r.title, width, r.expanded),
    }
    e.layout = lines.items;
    e.layout_width = width;
}

/// Wraps at word boundaries, splitting oversized words only at graphemes.
/// The first line gets `first`, following lines get `cont` as prefix.
pub fn wrapWithPrefix(
    a: Allocator,
    out: *std.ArrayList(Line),
    segs: []const Segment,
    width: u16,
    first: Segment,
    cont: []const u8,
) Allocator.Error!void {
    const prefix_w = render.displayWidth(first.text);
    const avail: usize = @max(@as(usize, width) -| prefix_w, 1);
    var line: std.ArrayList(Segment) = .empty;
    try line.append(a, first);
    var col: usize = 0;
    var has_content = false;

    for (segs) |seg| {
        var rest = seg.text;
        while (rest.len > 0) {
            if (rest[0] == '\n') {
                try out.append(a, line.items);
                line = .empty;
                try line.append(a, .{ .text = cont, .style = first.style });
                col = 0;
                has_content = false;
                rest = rest[1..];
                continue;
            }
            const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
            const piece = rest[0..nl];
            var fit = render.fitWidth(piece, avail -| col);
            if (fit.text.len > 0 and fit.text.len < piece.len and
                !std.ascii.isWhitespace(piece[fit.text.len - 1]) and !std.ascii.isWhitespace(piece[fit.text.len]))
            {
                const space = std.mem.lastIndexOfAny(u8, fit.text, " \t");
                if (space != null and std.mem.trim(u8, fit.text[0 .. space.? + 1], " \t").len > 0) {
                    const text = fit.text[0 .. space.? + 1];
                    fit = .{ .text = text, .width = render.displayWidth(text) };
                } else if (has_content) {
                    fit = .{ .text = "", .width = 0 };
                }
            }
            if (fit.text.len == 0 and col > 0) {
                // wrap
                try out.append(a, line.items);
                line = .empty;
                try line.append(a, .{ .text = cont, .style = first.style });
                col = 0;
                has_content = false;
                continue;
            }
            const take = if (fit.text.len == 0) firstGrapheme(piece) else fit.text;
            try line.append(a, .{ .text = take, .style = seg.style });
            col += if (fit.text.len == 0) render.displayWidth(take) else fit.width;
            has_content = has_content or std.mem.trim(u8, take, " \t\r").len > 0;
            rest = rest[take.len..];
            if (rest.len > 0 and rest[0] != '\n' and col >= avail) {
                try out.append(a, line.items);
                line = .empty;
                try line.append(a, .{ .text = cont, .style = first.style });
                col = 0;
                has_content = false;
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

test "trigger source wraps whole highlighted words and reflows on resize" {
    const a = std.testing.allocator;
    const source = "CREATE TRIGGER audit_orders BEFORE INSERT ON orders\nEXECUTE FUNCTION audit_orders();";
    var transcript = Transcript.init(a);
    defer transcript.deinit();
    try transcript.add(.{ .code = source });
    const entry = transcript.entries.items[0];
    for ([_]u16{ 22, 80, 22 }) |width| {
        try ensureLayout(entry, width);
        const expected: []const []const u8 = if (width == 22) &.{
            "  CREATE TRIGGER",
            "  audit_orders BEFORE",
            "  INSERT ON orders",
            "  EXECUTE FUNCTION",
            "  audit_orders();",
        } else &.{
            "  CREATE TRIGGER audit_orders BEFORE INSERT ON orders",
            "  EXECUTE FUNCTION audit_orders();",
        };
        try std.testing.expectEqual(expected.len, entry.layout.len);
        var found_keyword = false;
        for (entry.layout, expected) |line, text| {
            var memory: [128]u8 = undefined;
            var writer: std.Io.Writer = .fixed(&memory);
            for (line) |segment| {
                try writer.writeAll(segment.text);
                if (std.mem.eql(u8, segment.text, "CREATE")) {
                    try std.testing.expect(std.meta.eql(theme.sqlStyle(.keyword), segment.style));
                    found_keyword = true;
                }
            }
            try std.testing.expectEqualStrings(text, std.mem.trimEnd(u8, writer.buffered(), " \t"));
            try std.testing.expect(render.displayWidth(writer.buffered()) <= width);
        }
        try std.testing.expect(found_keyword);
        try std.testing.expectEqualStrings(source, entry.content.code);
    }
}

test "wrapping prefers spaces within a segment and preserves long Unicode words" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var lines: std.ArrayList(Line) = .empty;
    try wrapWithPrefix(arena.allocator(), &lines, &.{.{ .text = "alpha beta gamma", .style = theme.info }}, 14, .{ .text = "  " }, "  ");
    try std.testing.expectEqual(@as(usize, 2), lines.items.len);
    const expected = [_][]const u8{ "  alpha beta ", "  gamma" };
    for (lines.items, expected) |line, text| {
        var memory: [64]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&memory);
        for (line) |segment| try writer.writeAll(segment.text);
        try std.testing.expectEqualStrings(text, writer.buffered());
        for (line[1..]) |segment| try std.testing.expect(std.meta.eql(theme.info, segment.style));
    }
    const segments = [_]Segment{
        .{ .text = "日本é0123456789", .style = theme.info },
        .{ .text = "語abc", .style = theme.bold },
    };
    for ([_]u16{ 3, 4, 5, 8 }) |width| {
        lines = .empty;
        try wrapWithPrefix(arena.allocator(), &lines, &segments, width, .{ .text = "  " }, "  ");
        var joined: std.ArrayList(u8) = .empty;
        defer joined.deinit(a);
        for (lines.items) |line| {
            var line_width: usize = 0;
            for (line, 0..) |segment, i| {
                try std.testing.expect(std.unicode.utf8ValidateSlice(segment.text));
                line_width += render.displayWidth(segment.text);
                if (i > 0) try joined.appendSlice(a, segment.text);
            }
            // A two-cell grapheme cannot fit beside the prefix in a three-cell window.
            try std.testing.expect(line_width <= @max(width, 4));
        }
        try std.testing.expectEqualStrings("日本é0123456789語abc", joined.items);
    }
}

test "expanded schema results show rows beyond the console preview" {
    const a = std.testing.allocator;
    var rows: [inline_rows + 1][]const ?[]const u8 = @splat(&.{"value"});
    rows[inline_rows] = &.{"last_column"};
    for ([_]bool{ false, true }) |expanded| {
        var transcript = Transcript.init(a);
        defer transcript.deinit();
        try transcript.add(.{ .result = .{
            .result = .{ .arena = .init(a), .columns = &.{"column"}, .rows = &rows },
            .elapsed_ms = 0,
            .expanded = expanded,
        } });
        const entry = transcript.entries.items[0];
        try ensureLayout(entry, 80);
        var found = false;
        for (entry.layout) |line| {
            for (line) |segment| {
                if (std.mem.indexOf(u8, segment.text, "last_column") != null) found = true;
            }
        }
        try std.testing.expectEqual(expanded, found);
    }
}

test "wide result layout retains only screen-sized previews" {
    const a = std.testing.allocator;
    const payload: [512]u8 = @splat('x');
    for ([_]usize{ 8, 128, 1024 }) |ncols| {
        var input = std.heap.ArenaAllocator.init(a);
        defer input.deinit();
        const columns = try input.allocator().alloc([]const u8, ncols);
        for (columns, 0..) |*column, i| column.* = try std.fmt.allocPrint(input.allocator(), "column_{d}", .{i});
        const values = try input.allocator().alloc(?[]const u8, ncols);
        @memset(values, &payload);
        values[0] = null;
        values[2] = "日本\n語";
        const rows: [inline_rows][]const ?[]const u8 = @splat(values);
        var counted = std.testing.FailingAllocator.init(std.heap.c_allocator, .{});
        {
            var transcript = Transcript.init(a);
            defer transcript.deinit();
            try transcript.add(.{ .result = .{
                .result = .{ .arena = .init(a), .columns = columns, .rows = &rows },
                .elapsed_ms = 0,
            } });
            const entry = transcript.entries.items[0];
            entry.layout_arena.child_allocator = counted.allocator();
            const start = std.Io.Timestamp.now(std.testing.io, .awake);
            try ensureLayout(entry, 120);
            const elapsed = start.untilNow(std.testing.io, .awake).toMicroseconds();
            var hash = std.hash.Wyhash.init(0);
            for (entry.layout) |line| {
                for (line) |segment| hash.update(segment.text);
                hash.update("\n");
            }
            const text_hash = hash.final();
            if (@import("build_options").bench_tui) std.debug.print("\nUI layout: {d} columns, {d} rows, {d} allocations, {d} cached bytes, {d} us, text hash {x}\n", .{
                ncols, rows.len, counted.allocations, entry.layout_arena.queryCapacity(), elapsed, text_hash,
            });
            try std.testing.expect(entry.layout_arena.queryCapacity() < 512 * 1024);
            try std.testing.expectEqual(ncols, entry.content.result.result.columns.len);
            try std.testing.expectEqualStrings(&payload, entry.content.result.result.rows[0][ncols - 1].?);
            const allocations = counted.allocations;
            try ensureLayout(entry, 120);
            try std.testing.expectEqual(allocations, counted.allocations);
            try ensureLayout(entry, 40);
            try ensureLayout(entry, 120);
            var resized_hash = std.hash.Wyhash.init(0);
            for (entry.layout) |line| {
                for (line) |segment| resized_hash.update(segment.text);
                resized_hash.update("\n");
            }
            try std.testing.expectEqual(text_hash, resized_hash.final());
        }
        try std.testing.expectEqual(counted.allocated_bytes, counted.freed_bytes);
    }
}

fn layoutResult(
    a: Allocator,
    out: *std.ArrayList(Line),
    r: db.Result,
    total_rows: usize,
    elapsed_ms: i64,
    title: ?[]const u8,
    width: u16,
    expanded: bool,
) Allocator.Error!void {
    if (title) |t| try out.append(a, try a.dupe(Segment, &.{
        .{ .text = "  " },
        .{ .text = t, .style = theme.bold },
    }));

    if (!r.hasRows()) {
        var status: std.Io.Writer.Allocating = .init(a);
        render.writeStatus(&status.writer, r, elapsed_ms) catch return error.OutOfMemory;
        try out.append(a, try a.dupe(Segment, &.{
            .{ .text = "  └ ", .style = theme.dim },
            .{ .text = status.written(), .style = theme.ok },
        }));
        return;
    }

    const shown_rows = if (expanded) r.rows.len else @min(r.rows.len, inline_rows);
    const ncols = r.columns.len;
    const avail: usize = @as(usize, width) -| 3;
    // Each column needs at least three screen cells; always keep the first.
    const column_limit = @min(ncols, @max(1, (avail -| 1) / 3));
    const widths = try a.alloc(usize, column_limit);
    const header = try a.alloc([]const u8, column_limit);
    const cells = try a.alloc(?render.Measured, column_limit * shown_rows);
    var used: usize = 1;
    var visible: usize = 0;
    for (r.columns[0..column_limit], 0..) |name, i| {
        header[i] = try render.singleLine(a, name); // names are never truncated
        widths[i] = render.displayWidth(header[i]);
        for (r.rows[0..shown_rows], 0..) |row, ri| {
            const v = row[i];
            const cell = if (v) |s| try cellText(a, s) else null;
            cells[ri * column_limit + i] = cell;
            widths[i] = @max(widths[i], if (cell) |c| c.width else render.null_text.len);
        }
        if (used + widths[i] + 3 > avail) break;
        used += widths[i] + 3;
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
            const cell = cells[ri * column_limit + i];
            if (cell) |c| {
                if (c.width > widths[i]) {
                    try appendCell(a, &line, c.text, widths[i], theme.plain);
                } else {
                    try appendMeasuredCell(a, &line, c, widths[i], theme.plain);
                }
            } else {
                try appendCell(a, &line, render.null_text, widths[i], theme.null_value);
            }
        }
        if (hidden > 0) try line.append(a, .{ .text = " …", .style = theme.dim });
        try out.append(a, line.items);
    }
    try out.append(a, try ruleLine(a, widths[0..visible], "  └", "┴", "┘", hidden > 0));

    var status: std.ArrayList(u8) = .empty;
    try status.print(a, "{s} · {d} ms", .{ r.status, elapsed_ms });
    if (r.affected_rows) |n| try status.print(a, " · {d} row{s} affected", .{ n, if (n == 1) "" else "s" });
    if (r.truncated) try status.appendSlice(a, " · row limit reached");
    if (shown_rows < total_rows or hidden > 0) {
        try status.appendSlice(a, " · ");
        if (shown_rows < total_rows) try status.print(a, "showing {d} of {d} rows", .{ shown_rows, total_rows });
        if (shown_rows < total_rows and hidden > 0) try status.appendSlice(a, ", ");
        if (hidden > 0) try status.print(a, "{d} column{s} hidden", .{ hidden, if (hidden == 1) "" else "s" });
        try status.appendSlice(a, if (expanded) " — widen terminal to see all columns" else " — ctrl+o to open");
    }
    try out.append(a, try a.dupe(Segment, &.{
        .{ .text = "  └ ", .style = theme.dim },
        .{ .text = status.items, .style = theme.dim },
    }));
}

fn cellText(a: Allocator, s: []const u8) Allocator.Error!render.Measured {
    return render.previewMeasured(a, s, max_col_width);
}

fn appendMeasuredCell(a: Allocator, line: *std.ArrayList(Segment), cell: render.Measured, width: usize, style: Style) Allocator.Error!void {
    std.debug.assert(cell.width <= width);
    const pad = width - cell.width;
    try line.append(a, .{ .text = " " });
    try line.append(a, .{ .text = cell.text, .style = style });
    if (pad > 0) try line.append(a, .{ .text = try spaces(a, pad) });
    try line.append(a, .{ .text = " │", .style = theme.border });
}

fn appendCell(a: Allocator, line: *std.ArrayList(Segment), text: []const u8, width: usize, style: Style) Allocator.Error!void {
    const fit = render.fitWidth(text, width);
    try appendMeasuredCell(a, line, .{ .text = fit.text, .width = fit.width }, width, style);
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
