//! Plain-text rendering of results (used by `-e` mode and for copying).

const std = @import("std");
const Allocator = std.mem.Allocator;
const vaxis = @import("vaxis");
const db = @import("db/db.zig");

pub const null_text = "NULL";

pub fn displayWidth(s: []const u8) usize {
    var total: usize = 0;
    var it = vaxis.unicode.graphemeIterator(s);
    while (it.next()) |g| total += vaxis.gwidth.gwidth(g.bytes(s), .unicode);
    return total;
}

/// Returns the longest prefix of `s` whose display width fits in `max`, and that width.
pub fn fitWidth(s: []const u8, max: usize) struct { text: []const u8, width: usize } {
    var width: usize = 0;
    var it = vaxis.unicode.graphemeIterator(s);
    while (it.next()) |g| {
        const w = vaxis.gwidth.gwidth(g.bytes(s), .unicode);
        if (width + w > max) return .{ .text = s[0..g.start], .width = width };
        width += w;
    }
    return .{ .text = s, .width = width };
}

/// Makes a value printable on one line: control characters become spaces,
/// newlines become `¶` (Latin-1, present in every font). Returns `s` itself when nothing needs changing.
pub fn singleLine(a: Allocator, s: []const u8) Allocator.Error![]const u8 {
    const needs = for (s) |ch| {
        if (ch < 0x20 or ch == 0x7f) break true;
    } else false;
    if (!needs) return s;
    var out: std.ArrayList(u8) = .empty;
    for (s) |ch| switch (ch) {
        '\n' => try out.appendSlice(a, "¶"),
        '\r' => {},
        0...9, 11...12, 14...0x1f, 0x7f => try out.append(a, ' '),
        else => try out.append(a, ch),
    };
    return out.items;
}

pub const TableOptions = struct {
    max_cell_width: usize = 60,
};

/// Writes a box-drawn table followed by the status line.
pub fn writeResult(gpa: Allocator, w: *std.Io.Writer, r: db.Result, opts: TableOptions) !void {
    if (!r.hasRows()) {
        try w.print("{s}\n", .{if (r.status.len > 0) r.status else "OK"});
        return;
    }
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const ncols = r.columns.len;
    const widths = try a.alloc(usize, ncols);
    const cells = try a.alloc([]const u8, ncols * (r.rows.len + 1));
    for (r.columns, 0..) |name, i| {
        cells[i] = try singleLine(a, name); // names are never truncated
        widths[i] = displayWidth(cells[i]);
    }
    for (r.rows, 1..) |row, ri| {
        for (row, 0..) |v, i| {
            const t = try cellText(a, v orelse null_text, opts.max_cell_width);
            cells[ri * ncols + i] = t;
            widths[i] = @max(widths[i], displayWidth(t));
        }
    }

    try rule(w, widths, "┌", "┬", "┐");
    try line(w, widths, cells[0..ncols]);
    try rule(w, widths, "├", "┼", "┤");
    for (1..r.rows.len + 1) |ri| try line(w, widths, cells[ri * ncols ..][0..ncols]);
    try rule(w, widths, "└", "┴", "┘");
    try w.print("{s}\n", .{r.status});
}

fn cellText(a: Allocator, v: []const u8, max: usize) Allocator.Error![]const u8 {
    const s = try singleLine(a, v);
    const fit = fitWidth(s, max);
    if (fit.text.len == s.len) return s;
    const cut = fitWidth(s, max - 1);
    return std.mem.concat(a, u8, &.{ cut.text, "…" });
}

fn rule(w: *std.Io.Writer, widths: []const usize, left: []const u8, mid: []const u8, right: []const u8) !void {
    try w.writeAll(left);
    for (widths, 0..) |width, i| {
        if (i > 0) try w.writeAll(mid);
        for (0..width + 2) |_| try w.writeAll("─");
    }
    try w.writeAll(right);
    try w.writeAll("\n");
}

fn line(w: *std.Io.Writer, widths: []const usize, cells: []const []const u8) !void {
    try w.writeAll("│");
    for (cells, widths) |cell, width| {
        try w.writeAll(" ");
        try w.writeAll(cell);
        try w.splatByteAll(' ', width - displayWidth(cell) + 1);
        try w.writeAll("│");
    }
    try w.writeAll("\n");
}

test "fitWidth and singleLine" {
    try std.testing.expectEqualStrings("hél", fitWidth("hél", 3).text);
    try std.testing.expectEqualStrings("ab", fitWidth("abc", 2).text);
    try std.testing.expectEqual(@as(usize, 4), displayWidth("日本"));
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("a¶b", try singleLine(arena.allocator(), "a\r\nb"));
}
