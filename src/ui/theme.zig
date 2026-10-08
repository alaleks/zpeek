//! Colors and text styles. Uses the 16 ANSI colors so the terminal theme decides
//! the actual palette (works on light and dark backgrounds).

const std = @import("std");
const vaxis = @import("vaxis");
const lexer = @import("../sql/lexer.zig");
const Style = vaxis.Style;
const Segment = vaxis.Segment;

/// Soft green, readable on dark backgrounds (borders, prompt, titles, SQL keywords).
pub const accent: vaxis.Color = .{ .rgb = .{ 0x7e, 0xe7, 0x87 } };
const string_color: vaxis.Color = .{ .rgb = .{ 0xe5, 0xc0, 0x7b } }; // amber
const number_color: vaxis.Color = .{ .rgb = .{ 0xd1, 0x9a, 0x66 } }; // orange
pub const ok_color: vaxis.Color = .{ .index = 2 };
pub const err_color: vaxis.Color = .{ .index = 1 };
pub const warn_color: vaxis.Color = .{ .index = 3 };
pub const info_color: vaxis.Color = .{ .index = 4 };
pub const muted_color: vaxis.Color = .{ .index = 8 };
/// Background of the selected cell / list item.
pub const selection_bg: vaxis.Color = .{ .rgb = .{ 0x2f, 0x6b, 0x43 } }; // deep green, pairs with `accent`

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
pub const header: Style = .{ .bold = true, .fg = info_color };
pub const selected: Style = .{ .reverse = true };
pub const selected_cell: Style = .{ .bg = selection_bg, .fg = .{ .index = 15 }, .bold = true };
pub const row_highlight: Style = .{ .bg = .{ .index = 0 } };
pub const popup: Style = .{};
pub const popup_selected: Style = .{ .bg = selection_bg, .fg = .{ .index = 15 } };

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
