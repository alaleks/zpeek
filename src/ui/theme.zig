//! Colors and text styles. Uses the 16 ANSI colors so the terminal theme decides
//! the actual palette (works on light and dark backgrounds).

const std = @import("std");
const vaxis = @import("vaxis");
const lexer = @import("../sql/lexer.zig");
const Style = vaxis.Style;
const Segment = vaxis.Segment;

pub const accent: vaxis.Color = .{ .index = 2 };
pub const fk_color: vaxis.Color = .{ .index = 6 };
const string_color: vaxis.Color = .{ .index = 3 };
const number_color: vaxis.Color = .{ .index = 5 };
pub const ok_color: vaxis.Color = .{ .index = 2 };
pub const err_color: vaxis.Color = .{ .index = 1 };
pub const warn_color: vaxis.Color = .{ .index = 3 };
pub const info_color: vaxis.Color = .{ .index = 4 };
pub const muted_color: vaxis.Color = .{ .index = 8 };
pub const plain: Style = .{};
pub const bold: Style = .{ .bold = true };
pub const dim: Style = .{ .fg = muted_color };
pub const accent_bold: Style = .{ .fg = accent, .bold = true };
pub const ok: Style = .{ .fg = ok_color };
pub const err: Style = .{ .fg = err_color };
pub const err_bold: Style = .{ .fg = err_color, .bold = true };
pub const warn: Style = .{ .fg = warn_color };
pub const info: Style = .{ .fg = info_color };
pub const border: Style = .{ .fg = muted_color };
pub const border_focus: Style = .{ .fg = accent };
pub const null_value: Style = .{ .fg = muted_color, .italic = true };
pub const boolean_value: Style = .{ .fg = .{ .index = 6 } };
pub const number_value: Style = .{ .fg = number_color, .bold = true };
pub const header: Style = .{ .fg = info_color, .bold = true };
pub const selected: Style = .{ .reverse = true };
pub const selected_cell: Style = .{ .reverse = true, .bold = true };
pub const popup: Style = .{};
pub const popup_selected: Style = .{ .reverse = true };

pub fn sqlStyle(tag: lexer.Tag) Style {
    return switch (tag) {
        .keyword => .{ .fg = accent, .bold = true },
        .builtin => .{ .fg = .{ .index = 6 } },
        .string => .{ .fg = string_color },
        .number => .{ .fg = number_color },
        .comment => .{ .fg = muted_color, .italic = true },
        .quoted_identifier => .{ .fg = .{ .index = 4 } },
        .parameter => .{ .fg = number_color, .bold = true },
        .operator => .{ .fg = .{ .index = 6 } },
        .whitespace, .identifier, .punctuation => .{},
    };
}

/// Splits `src` into highlighted segments. Segments reference `src`.
pub fn highlight(a: std.mem.Allocator, src: []const u8, base: Style) std.mem.Allocator.Error![]Segment {
    var out: std.ArrayList(Segment) = .empty;
    var it: lexer.Iterator = .init(src);
    while (it.next()) |t| {
        var style = sqlStyle(t.tag);
        if (std.meta.eql(style.fg, vaxis.Color.default)) style.fg = base.fg;
        style.bg = base.bg;
        try out.append(a, .{ .text = t.text(src), .style = style });
    }
    return out.items;
}
