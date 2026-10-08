//! Multi-line input buffer with a cursor and command history.

const std = @import("std");
const Allocator = std.mem.Allocator;
const lexer = @import("../sql/lexer.zig");

const Editor = @This();

gpa: Allocator,
buf: std.ArrayList(u8) = .empty,
/// Byte offset of the cursor in `buf`.
cursor: usize = 0,
/// Preferred display column when moving vertically.
goal_col: ?usize = null,

history: std.ArrayList([]const u8) = .empty,
/// Index into `history` while browsing it; null when editing a fresh line.
history_pos: ?usize = null,
/// The unsent text saved when history browsing started.
draft: std.ArrayList(u8) = .empty,

pub fn init(gpa: Allocator) Editor {
    return .{ .gpa = gpa };
}

pub fn deinit(e: *Editor) void {
    for (e.history.items) |h| e.gpa.free(h);
    e.history.deinit(e.gpa);
    e.buf.deinit(e.gpa);
    e.draft.deinit(e.gpa);
}

pub fn text(e: *const Editor) []const u8 {
    return e.buf.items;
}

pub fn isEmpty(e: *const Editor) bool {
    return e.buf.items.len == 0;
}

pub fn clear(e: *Editor) void {
    e.buf.clearRetainingCapacity();
    e.cursor = 0;
    e.goal_col = null;
    e.history_pos = null;
}

pub fn setText(e: *Editor, s: []const u8) Allocator.Error!void {
    e.buf.clearRetainingCapacity();
    try e.buf.appendSlice(e.gpa, s);
    e.cursor = s.len;
    e.goal_col = null;
}

pub fn insert(e: *Editor, s: []const u8) Allocator.Error!void {
    try e.buf.insertSlice(e.gpa, e.cursor, s);
    e.cursor += s.len;
    e.goal_col = null;
}

/// Inserts pasted text, normalizing CRLF/CR to LF.
pub fn insertPaste(e: *Editor, s: []const u8) Allocator.Error!void {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '\r') {
            if (i + 1 < s.len and s[i + 1] == '\n') continue;
            try e.insert("\n");
        } else if (c == '\t') {
            try e.insert("    ");
        } else {
            try e.insert(s[i .. i + 1]);
        }
    }
}

fn prevCharStart(s: []const u8, pos: usize) usize {
    if (pos == 0) return 0;
    var i = pos - 1;
    while (i > 0 and (s[i] & 0xC0) == 0x80) i -= 1;
    return i;
}

fn nextCharEnd(s: []const u8, pos: usize) usize {
    if (pos >= s.len) return s.len;
    var i = pos + 1;
    while (i < s.len and (s[i] & 0xC0) == 0x80) i += 1;
    return i;
}

pub fn backspace(e: *Editor) void {
    if (e.cursor == 0) return;
    const start = prevCharStart(e.buf.items, e.cursor);
    e.buf.replaceRangeAssumeCapacity(start, e.cursor - start, "");
    e.cursor = start;
    e.goal_col = null;
}

pub fn deleteForward(e: *Editor) void {
    if (e.cursor >= e.buf.items.len) return;
    const stop = nextCharEnd(e.buf.items, e.cursor);
    e.buf.replaceRangeAssumeCapacity(e.cursor, stop - e.cursor, "");
    e.goal_col = null;
}

pub fn left(e: *Editor) void {
    e.cursor = prevCharStart(e.buf.items, e.cursor);
    e.goal_col = null;
}

pub fn right(e: *Editor) void {
    e.cursor = nextCharEnd(e.buf.items, e.cursor);
    e.goal_col = null;
}

pub fn lineStart(e: *const Editor, pos: usize) usize {
    return if (std.mem.lastIndexOfScalar(u8, e.buf.items[0..pos], '\n')) |nl| nl + 1 else 0;
}

pub fn lineEnd(e: *const Editor, pos: usize) usize {
    return std.mem.indexOfScalarPos(u8, e.buf.items, pos, '\n') orelse e.buf.items.len;
}

pub fn home(e: *Editor) void {
    e.cursor = e.lineStart(e.cursor);
    e.goal_col = null;
}

pub fn end(e: *Editor) void {
    e.cursor = e.lineEnd(e.cursor);
    e.goal_col = null;
}

pub fn onFirstLine(e: *const Editor) bool {
    return e.lineStart(e.cursor) == 0;
}

pub fn onLastLine(e: *const Editor) bool {
    return e.lineEnd(e.cursor) == e.buf.items.len;
}

fn columnOf(s: []const u8, from: usize, to: usize) usize {
    return std.unicode.utf8CountCodepoints(s[from..to]) catch to - from;
}

fn posAtColumn(s: []const u8, line_start: usize, line_end: usize, col: usize) usize {
    var pos = line_start;
    var c: usize = 0;
    while (pos < line_end and c < col) : (c += 1) pos = nextCharEnd(s, pos);
    return pos;
}

pub fn up(e: *Editor) void {
    const ls = e.lineStart(e.cursor);
    if (ls == 0) return;
    const col = e.goal_col orelse columnOf(e.buf.items, ls, e.cursor);
    const prev_start = e.lineStart(ls - 1);
    e.cursor = posAtColumn(e.buf.items, prev_start, ls - 1, col);
    e.goal_col = col;
}

pub fn down(e: *Editor) void {
    const le = e.lineEnd(e.cursor);
    if (le >= e.buf.items.len) return;
    const col = e.goal_col orelse columnOf(e.buf.items, e.lineStart(e.cursor), e.cursor);
    const next_start = le + 1;
    e.cursor = posAtColumn(e.buf.items, next_start, e.lineEnd(next_start), col);
    e.goal_col = col;
}

fn isWordByte(c: u8) bool {
    return lexer.isIdentChar(c);
}

pub fn wordLeft(e: *Editor) void {
    const s = e.buf.items;
    var i = e.cursor;
    while (i > 0 and !isWordByte(s[i - 1])) i -= 1;
    while (i > 0 and isWordByte(s[i - 1])) i -= 1;
    e.cursor = i;
    e.goal_col = null;
}

pub fn wordRight(e: *Editor) void {
    const s = e.buf.items;
    var i = e.cursor;
    while (i < s.len and !isWordByte(s[i])) i += 1;
    while (i < s.len and isWordByte(s[i])) i += 1;
    e.cursor = i;
    e.goal_col = null;
}

pub fn deleteWordLeft(e: *Editor) void {
    const old = e.cursor;
    e.wordLeft();
    e.buf.replaceRangeAssumeCapacity(e.cursor, old - e.cursor, "");
}

pub fn killToLineStart(e: *Editor) void {
    const ls = e.lineStart(e.cursor);
    if (ls == e.cursor and ls > 0) {
        // at line start: join with previous line
        e.backspace();
        return;
    }
    e.buf.replaceRangeAssumeCapacity(ls, e.cursor - ls, "");
    e.cursor = ls;
    e.goal_col = null;
}

pub fn killToLineEnd(e: *Editor) void {
    const le = e.lineEnd(e.cursor);
    if (le == e.cursor) {
        e.deleteForward();
        return;
    }
    e.buf.replaceRangeAssumeCapacity(e.cursor, le - e.cursor, "");
}

/// The identifier-ish word ending at the cursor (may include dots and a leading slash).
pub fn wordBeforeCursor(e: *const Editor) []const u8 {
    const s = e.buf.items;
    var i = e.cursor;
    while (i > 0 and (isWordByte(s[i - 1]) or s[i - 1] == '.' or s[i - 1] == '"' or s[i - 1] == '`')) i -= 1;
    if (i > 0 and s[i - 1] == '/' and i - 1 == 0) i -= 1;
    return s[i..e.cursor];
}

/// Replaces the last `len` bytes before the cursor with `replacement`.
pub fn replaceBeforeCursor(e: *Editor, len: usize, replacement: []const u8) Allocator.Error!void {
    return e.replaceBeforeCursorAndMove(len, replacement, 0);
}

/// Replaces text before the cursor, then moves the cursor left within the
/// inserted ASCII suffix. Used by completion snippets with paired delimiters.
pub fn replaceBeforeCursorAndMove(e: *Editor, len: usize, replacement: []const u8, cursor_back: usize) Allocator.Error!void {
    std.debug.assert(cursor_back <= replacement.len);
    const start = e.cursor - len;
    try e.buf.replaceRange(e.gpa, start, len, replacement);
    e.cursor = start + replacement.len - cursor_back;
    e.goal_col = null;
}

pub fn lineCount(e: *const Editor) usize {
    return std.mem.count(u8, e.buf.items, "\n") + 1;
}

/// Records the current text in history (skipping consecutive duplicates).
pub fn commitHistory(e: *Editor) Allocator.Error!void {
    return e.commitHistoryText(e.buf.items);
}

/// Records explicit text in history. Callers can use this to avoid persisting
/// a sensitive form of the text currently displayed by the editor.
pub fn commitHistoryText(e: *Editor, text_value: []const u8) Allocator.Error!void {
    const t = std.mem.trim(u8, text_value, " \t\r\n");
    if (t.len == 0) return;
    if (e.history.items.len > 0 and std.mem.eql(u8, e.history.items[e.history.items.len - 1], t)) return;
    try e.history.append(e.gpa, try e.gpa.dupe(u8, t));
}

pub fn historyPrev(e: *Editor) Allocator.Error!void {
    if (e.history.items.len == 0) return;
    const pos = if (e.history_pos) |p| (if (p == 0) return else p - 1) else blk: {
        e.draft.clearRetainingCapacity();
        try e.draft.appendSlice(e.gpa, e.buf.items);
        break :blk e.history.items.len - 1;
    };
    e.history_pos = pos;
    try e.setText(e.history.items[pos]);
}

pub fn historyNext(e: *Editor) Allocator.Error!void {
    const p = e.history_pos orelse return;
    if (p + 1 < e.history.items.len) {
        e.history_pos = p + 1;
        try e.setText(e.history.items[p + 1]);
    } else {
        e.history_pos = null;
        try e.setText(e.draft.items);
    }
}

/// Loads history from a file, one entry per record separated by NUL bytes.
pub fn loadHistory(e: *Editor, data: []const u8) Allocator.Error!void {
    var it = std.mem.splitScalar(u8, data, 0);
    while (it.next()) |entry| {
        if (entry.len == 0) continue;
        try e.history.append(e.gpa, try e.gpa.dupe(u8, entry));
    }
}

const testing = std.testing;

test "editing and cursor movement" {
    var e: Editor = .init(testing.allocator);
    defer e.deinit();
    try e.insert("select 1\nfrom tääble");
    e.up();
    try testing.expectEqual(@as(usize, 8), e.cursor);
    e.down();
    try testing.expectEqual(e.buf.items.len, e.cursor);
    e.backspace();
    try testing.expect(std.mem.endsWith(u8, e.text(), "tääbl"));
    e.wordLeft();
    try testing.expectEqualStrings("tääbl", e.text()[e.cursor..]);
    e.end();
    try testing.expectEqualStrings("tääbl", e.wordBeforeCursor());
    try e.replaceBeforeCursor(e.wordBeforeCursor().len, "users");
    try testing.expectEqualStrings("select 1\nfrom users", e.text());
}

test "history" {
    var e: Editor = .init(testing.allocator);
    defer e.deinit();
    try e.setText("a");
    try e.commitHistory();
    try e.setText("b");
    try e.commitHistory();
    try e.setText("draft");
    try e.historyPrev();
    try testing.expectEqualStrings("b", e.text());
    try e.historyPrev();
    try testing.expectEqualStrings("a", e.text());
    try e.historyNext();
    try e.historyNext();
    try testing.expectEqualStrings("draft", e.text());
}

test "completion snippet positions cursor inside delimiters" {
    var e: Editor = .init(testing.allocator);
    defer e.deinit();
    try e.insert("where id I");
    try e.replaceBeforeCursorAndMove(1, "IN ()", 1);
    try testing.expectEqualStrings("where id IN ()", e.text());
    try testing.expectEqualStrings(")", e.text()[e.cursor..]);
}
