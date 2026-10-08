//! A modal list with type-to-filter, used to pick a connection or a table.

const std = @import("std");
const Allocator = std.mem.Allocator;
const vaxis = @import("vaxis");
const Segment = vaxis.Segment;
const theme = @import("theme.zig");
const render = @import("../render.zig");

const Picker = @This();

pub const Purpose = enum { connect, browse, describe };

pub const Item = struct {
    label: []const u8,
    detail: []const u8 = "",
};

pub const Action = union(enum) {
    none,
    cancel,
    /// Index into the original item list.
    choose: usize,
    /// Text typed that matches no item (e.g. a connection URL).
    raw: []const u8,
};

gpa: Allocator,
arena: std.heap.ArenaAllocator,
purpose: Purpose,
title: []const u8,
items: []const Item,
query: std.ArrayList(u8) = .empty,
matches: std.ArrayList(usize) = .empty,
selected: usize = 0,
top: usize = 0,
/// When true, Enter with no match returns the typed text (`raw`).
allow_raw: bool = false,

pub fn init(gpa: Allocator, purpose: Purpose, title: []const u8, items: []const Item, allow_raw: bool) Allocator.Error!*Picker {
    const p = try gpa.create(Picker);
    p.* = .{ .gpa = gpa, .arena = .init(gpa), .purpose = purpose, .title = undefined, .items = undefined, .allow_raw = allow_raw };
    const a = p.arena.allocator();
    p.title = try a.dupe(u8, title);
    const copy = try a.alloc(Item, items.len);
    for (items, copy) |it, *c| c.* = .{ .label = try a.dupe(u8, it.label), .detail = try a.dupe(u8, it.detail) };
    p.items = copy;
    try p.refilter();
    return p;
}

pub fn deinit(p: *Picker) void {
    p.query.deinit(p.gpa);
    p.matches.deinit(p.gpa);
    p.arena.deinit();
    p.gpa.destroy(p);
}

fn refilter(p: *Picker) Allocator.Error!void {
    p.matches.clearRetainingCapacity();
    const q = p.query.items;
    // Prefix matches first, then substring matches.
    for (p.items, 0..) |it, i| {
        if (q.len == 0 or std.ascii.startsWithIgnoreCase(it.label, q)) try p.matches.append(p.gpa, i);
    }
    if (q.len > 0) {
        for (p.items, 0..) |it, i| {
            if (!std.ascii.startsWithIgnoreCase(it.label, q) and
                (std.ascii.findIgnoreCase(it.label, q) != null or std.ascii.findIgnoreCase(it.detail, q) != null))
                try p.matches.append(p.gpa, i);
        }
    }
    p.selected = 0;
    p.top = 0;
}

pub fn handleKey(p: *Picker, key: vaxis.Key) Allocator.Error!Action {
    if (key.matches(vaxis.Key.escape, .{}) or key.matches('c', .{ .ctrl = true })) return .cancel;
    if (key.matches(vaxis.Key.enter, .{}) or key.matches(vaxis.Key.tab, .{})) {
        if (p.matches.items.len > 0) return .{ .choose = p.matches.items[p.selected] };
        if (p.allow_raw and p.query.items.len > 0) return .{ .raw = p.query.items };
        return .none;
    }
    if (key.matches(vaxis.Key.down, .{}) or key.matches('n', .{ .ctrl = true })) {
        if (p.selected + 1 < p.matches.items.len) p.selected += 1;
    } else if (key.matches(vaxis.Key.up, .{}) or key.matches('p', .{ .ctrl = true })) {
        p.selected -|= 1;
    } else if (key.matches(vaxis.Key.page_down, .{})) {
        p.selected = @min(p.selected + 10, p.matches.items.len -| 1);
    } else if (key.matches(vaxis.Key.page_up, .{})) {
        p.selected -|= 10;
    } else if (key.matches(vaxis.Key.backspace, .{})) {
        if (p.query.items.len > 0) {
            var i = p.query.items.len - 1;
            while (i > 0 and (p.query.items[i] & 0xC0) == 0x80) i -= 1;
            p.query.shrinkRetainingCapacity(i);
            try p.refilter();
        }
    } else if (key.matches('u', .{ .ctrl = true })) {
        p.query.clearRetainingCapacity();
        try p.refilter();
    } else if (key.text) |t| {
        if (!key.mods.ctrl and !key.mods.alt) {
            try p.query.appendSlice(p.gpa, t);
            try p.refilter();
        }
    }
    return .none;
}

pub fn draw(p: *Picker, win: vaxis.Window, a: Allocator) Allocator.Error!void {
    const w: u16 = @min(win.width -| 4, 90);
    const visible: usize = @min(@max(p.matches.items.len, 1), @as(usize, win.height -| 8), 15);
    // borders (2) + title + query + blank line
    const h: u16 = @intCast(visible + 5);
    const box = win.child(.{
        .x_off = @intCast((win.width -| w) / 2),
        .y_off = @intCast(@max((win.height -| h) / 3, 1)),
        .width = w,
        .height = h,
        .border = .{ .where = .all, .style = theme.border_focus },
    });
    box.clear();

    _ = box.print(&.{.{ .text = p.title, .style = theme.accent_bold }}, .{ .row_offset = 0, .col_offset = 1, .wrap = .none });
    const prompt = "❯ ";
    _ = box.print(&.{
        .{ .text = prompt, .style = theme.accent_bold },
        .{ .text = p.query.items },
    }, .{ .row_offset = 1, .col_offset = 1, .wrap = .none });
    box.showCursor(@intCast(@min(1 + render.displayWidth(prompt) + render.displayWidth(p.query.items), box.width -| 1)), 1);

    if (p.selected < p.top) p.top = p.selected;
    if (p.selected >= p.top + visible) p.top = p.selected + 1 - visible;

    if (p.matches.items.len == 0) {
        const msg: []const u8 = if (p.allow_raw and p.query.items.len > 0) "no match — enter connects to this URL / path" else "no matches";
        _ = box.print(&.{.{ .text = msg, .style = theme.dim }}, .{ .row_offset = 3, .col_offset = 1, .wrap = .none });
        return;
    }
    var label_w: usize = 0;
    for (p.matches.items) |m| label_w = @max(label_w, render.displayWidth(p.items[m].label));
    label_w = @min(label_w, w / 2);

    for (p.matches.items[p.top..], 0..) |m, i| {
        if (i >= visible) break;
        const it = p.items[m];
        const sel = p.top + i == p.selected;
        const style: vaxis.Style = if (sel) theme.popup_selected else .{};
        const row: u16 = @intCast(i + 3);
        if (sel) {
            var x: u16 = 0;
            while (x < box.width) : (x += 1) box.writeCell(x, row, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = style });
        }
        const fit = render.fitWidth(it.label, label_w);
        const pad = label_w - fit.width + 2;
        var detail_style = theme.dim;
        if (sel) detail_style = .{ .fg = .{ .index = 15 }, .bg = style.bg };
        _ = box.print(&.{
            .{ .text = if (sel) " ❯ " else "   ", .style = style },
            .{ .text = fit.text, .style = if (sel) .{ .bold = true, .bg = style.bg, .fg = style.fg } else theme.bold },
            .{ .text = try spaces(a, pad), .style = style },
            .{ .text = it.detail, .style = detail_style },
        }, .{ .row_offset = row, .wrap = .none });
    }
    if (p.matches.items.len > visible) {
        const more = try std.fmt.allocPrint(a, "{d}/{d}", .{ p.selected + 1, p.matches.items.len });
        _ = box.print(&.{.{ .text = more, .style = theme.dim }}, .{
            .row_offset = 0,
            .col_offset = box.width -| @as(u16, @intCast(more.len + 1)),
            .wrap = .none,
        });
    }
}

fn spaces(a: Allocator, n: usize) Allocator.Error![]const u8 {
    const s = try a.alloc(u8, n);
    @memset(s, ' ');
    return s;
}
