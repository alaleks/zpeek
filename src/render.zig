//! Plain-text rendering of results (used by `-e` mode and for copying).

const std = @import("std");
const Allocator = std.mem.Allocator;
const vaxis = @import("vaxis");
const db = @import("db/db.zig");

pub const null_text = "NULL";
pub const scratch_limit = 256 * 1024;

/// Bound both scanning and allocation, including values made entirely of zero-width characters.
pub fn preview(a: Allocator, s: []const u8, max: usize) Allocator.Error![]const u8 {
    if (max == 0) return "";
    var buffer: [4096]u8 = undefined;
    const limit = @min(buffer.len, max *| 16 +| 16);
    var pos: usize = 0;
    var len: usize = 0;
    var changed = false;
    while (pos < s.len and pos < limit) {
        const n = std.unicode.utf8ByteSequenceLength(s[pos]) catch 1;
        if (n > s.len - pos or n > limit - len) break;
        const bytes = s[pos..][0..n];
        const text = switch (s[pos]) {
            '\r' => "",
            '\n' => "¶",
            0...9, 11...12, 14...0x1f, 0x7f => " ",
            else => if (std.unicode.utf8ValidateSlice(bytes)) bytes else "�",
        };
        if (text.len > limit - len) break;
        changed = changed or !std.mem.eql(u8, bytes, text);
        @memcpy(buffer[len..][0..text.len], text);
        len += text.len;
        pos += n;
    }
    const text = buffer[0..len];
    const fit = fitWidth(text, max);
    if (pos == s.len and fit.text.len == len) return if (changed) try a.dupe(u8, text) else s;
    return std.mem.concat(a, u8, &.{ fitWidth(text, max - 1).text, "…" });
}

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

pub fn writeStatus(w: *std.Io.Writer, r: db.Result, elapsed_ms: ?i64) std.Io.Writer.Error!void {
    try w.writeAll(if (r.status.len > 0) r.status else "OK");
    if (r.affected_rows) |n| try w.print(" · {d} row{s} affected", .{ n, if (n == 1) "" else "s" });
    if (elapsed_ms) |ms| try w.print(" · {d} ms", .{ms});
}

/// Writes a box-drawn table followed by the status line.
pub fn writeResult(gpa: Allocator, w: *std.Io.Writer, r: db.Result, opts: TableOptions) !void {
    if (!r.hasRows()) {
        try writeStatus(w, r, r.elapsed_ms);
        try w.writeByte('\n');
        return;
    }
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const ncols = r.columns.len;
    const widths = try gpa.alloc(usize, ncols);
    defer gpa.free(widths);
    for (r.columns, 0..) |name, i| {
        widths[i] = displayWidth(try singleLine(arena.allocator(), name));
        _ = arena.reset(.{ .retain_with_limit = scratch_limit });
    }
    for (r.rows) |row| {
        if (row.len != ncols) return error.InvalidRow;
        for (row, 0..) |v, i| {
            const t = try preview(arena.allocator(), v orelse null_text, opts.max_cell_width);
            widths[i] = @max(widths[i], displayWidth(t));
            _ = arena.reset(.{ .retain_with_limit = scratch_limit });
        }
    }

    try rule(w, widths, "┌", "┬", "┐");
    try w.writeAll("│");
    for (r.columns, widths) |name, width| {
        try writeCell(w, try singleLine(arena.allocator(), name), width);
        _ = arena.reset(.{ .retain_with_limit = scratch_limit });
    }
    try w.writeByte('\n');
    try rule(w, widths, "├", "┼", "┤");
    for (r.rows) |row| {
        try w.writeAll("│");
        for (row, widths) |v, width| {
            try writeCell(w, try preview(arena.allocator(), v orelse null_text, opts.max_cell_width), width);
            _ = arena.reset(.{ .retain_with_limit = scratch_limit });
        }
        try w.writeByte('\n');
    }
    try rule(w, widths, "└", "┴", "┘");
    try writeStatus(w, r, r.elapsed_ms);
    try w.writeByte('\n');
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

fn writeCell(w: *std.Io.Writer, cell: []const u8, width: usize) !void {
    try w.writeAll(" ");
    try w.writeAll(cell);
    try w.splatByteAll(' ', width - displayWidth(cell) + 1);
    try w.writeAll("│");
}

test "fitWidth and singleLine" {
    try std.testing.expectEqualStrings("hél", fitWidth("hél", 3).text);
    try std.testing.expectEqualStrings("ab", fitWidth("abc", 2).text);
    try std.testing.expectEqual(@as(usize, 4), displayWidth("日本"));
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("a¶b", try singleLine(arena.allocator(), "a\r\nb"));
}

test "status explicitly shows zero affected rows and duration" {
    var r: db.Result = .{ .arena = .init(std.testing.allocator), .status = "UPDATE", .affected_rows = 0 };
    defer r.deinit();
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeStatus(&writer, r, 12);
    try std.testing.expectEqualStrings("UPDATE · 0 rows affected · 12 ms", writer.buffered());
}

test "previews bound work and allocation before normalizing large values" {
    const large = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(large);
    @memset(large, '\n');
    var buffer: [256]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&buffer);
    const text = try preview(fixed.allocator(), large, 10);
    try std.testing.expectEqualStrings("¶¶¶¶¶¶¶¶¶…", text);
    try std.testing.expectEqualStrings("", try preview(fixed.allocator(), large, 0));
    @memset(large, '\r');
    try std.testing.expectEqualStrings("…", try preview(fixed.allocator(), large, 10));
    for (0..large.len / 2) |i| @memcpy(large[i * 2 ..][0..2], "́");
    const combining = try preview(fixed.allocator(), large, 1);
    try std.testing.expect(std.unicode.utf8ValidateSlice(combining));
    try std.testing.expect(combining.len < 64);
    const clean = "日本";
    try std.testing.expectEqual(clean.ptr, (try preview(fixed.allocator(), clean, 4)).ptr);
    try std.testing.expectEqualStrings("a¶b", try preview(fixed.allocator(), "a\r\nb", 3));
    try std.testing.expectEqualStrings("日…", try preview(fixed.allocator(), "日本", 3));
}

test "CLI table streams normalized cells with memory independent of row count" {
    var rows: [2000][]const ?[]const u8 = @splat(&.{ "a\nb", "日本", null });
    var result: db.Result = .{ .arena = .init(std.testing.allocator), .columns = &.{ "a", "b", "c" }, .rows = &rows };
    defer result.deinit();
    var memory: [16 * 1024]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&memory);
    var buffer: [256]u8 = undefined;
    var discard: std.Io.Writer.Discarding = .init(&buffer);
    try writeResult(fixed.allocator(), &discard.writer, result, .{});
    try std.testing.expect(discard.fullCount() > 40_000);
    result.rows = rows[0..1];
    var output: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&output);
    try writeResult(std.testing.allocator, &writer, result, .{});
    try std.testing.expectEqualStrings(
        "┌─────┬──────┬──────┐\n│ a   │ b    │ c    │\n├─────┼──────┼──────┤\n│ a¶b │ 日本 │ NULL │\n└─────┴──────┴──────┘\nOK\n",
        writer.buffered(),
    );
    writer.end = 0;
    try writeResult(std.testing.allocator, &writer, result, .{ .max_cell_width = 0 });
    result.rows = &.{&.{"short row"}};
    try std.testing.expectError(error.InvalidRow, writeResult(std.testing.allocator, &writer, result, .{}));
}
