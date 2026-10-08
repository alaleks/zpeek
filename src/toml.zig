//! A small TOML parser covering what config files need: tables, dotted and
//! quoted keys, basic/literal strings (including multi-line), integers,
//! floats, booleans, arrays and inline tables. Dates are not supported.
//!
//! All memory is owned by the arena passed to `parse`.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Table = std.array_hash_map.String(Value);

pub const Value = union(enum) {
    string: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
    array: []const Value,
    table: *Table,
};

pub const Diagnostic = struct {
    line: usize = 0,
    message: []const u8 = "",
};

pub const Error = error{SyntaxError} || Allocator.Error;

pub fn parse(arena: Allocator, src: []const u8, diag: ?*Diagnostic) Error!*Table {
    var p: Parser = .{ .arena = arena, .src = src, .diag = diag };
    return p.document();
}

const Parser = struct {
    arena: Allocator,
    src: []const u8,
    pos: usize = 0,
    line: usize = 1,
    diag: ?*Diagnostic,

    fn fail(p: *Parser, message: []const u8) Error {
        if (p.diag) |d| d.* = .{ .line = p.line, .message = message };
        return error.SyntaxError;
    }

    fn peek(p: *Parser) ?u8 {
        return if (p.pos < p.src.len) p.src[p.pos] else null;
    }

    fn advance(p: *Parser) void {
        if (p.src[p.pos] == '\n') p.line += 1;
        p.pos += 1;
    }

    fn startsWith(p: *Parser, s: []const u8) bool {
        return std.mem.startsWith(u8, p.src[p.pos..], s);
    }

    fn skipSpaces(p: *Parser) void {
        while (p.peek()) |c| switch (c) {
            ' ', '\t' => p.advance(),
            else => return,
        };
    }

    /// Skips whitespace, newlines and comments.
    fn skipBlank(p: *Parser) void {
        while (p.peek()) |c| switch (c) {
            ' ', '\t', '\r', '\n' => p.advance(),
            '#' => p.skipComment(),
            else => return,
        };
    }

    fn skipComment(p: *Parser) void {
        while (p.peek()) |c| {
            if (c == '\n') return;
            p.advance();
        }
    }

    /// After a value or header only spaces and a comment may follow.
    fn endOfLine(p: *Parser) Error!void {
        p.skipSpaces();
        if (p.peek()) |c| switch (c) {
            '#' => p.skipComment(),
            '\r', '\n' => {},
            else => return p.fail("unexpected characters after value"),
        };
    }

    fn document(p: *Parser) Error!*Table {
        const root = try p.newTable();
        var current = root;
        while (true) {
            p.skipBlank();
            const c = p.peek() orelse break;
            if (c == '[') {
                if (p.startsWith("[[")) return p.fail("arrays of tables are not supported");
                p.advance();
                p.skipSpaces();
                var path: std.ArrayList([]const u8) = .empty;
                try p.keyPath(&path);
                p.skipSpaces();
                if (p.peek() != ']') return p.fail("expected ']'");
                p.advance();
                try p.endOfLine();
                current = try p.descend(root, path.items);
            } else {
                try p.keyValue(current);
                try p.endOfLine();
            }
        }
        return root;
    }

    fn newTable(p: *Parser) Allocator.Error!*Table {
        const t = try p.arena.create(Table);
        t.* = .empty;
        return t;
    }

    /// Walks/creates nested tables for a dotted path.
    fn descend(p: *Parser, root: *Table, path: []const []const u8) Error!*Table {
        var t = root;
        for (path) |key| {
            const gop = try t.getOrPut(p.arena, key);
            if (gop.found_existing) {
                switch (gop.value_ptr.*) {
                    .table => |sub| t = sub,
                    else => return p.fail("key already defined as a non-table"),
                }
            } else {
                const sub = try p.newTable();
                gop.value_ptr.* = .{ .table = sub };
                t = sub;
            }
        }
        return t;
    }

    fn keyValue(p: *Parser, table: *Table) Error!void {
        var path: std.ArrayList([]const u8) = .empty;
        try p.keyPath(&path);
        p.skipSpaces();
        if (p.peek() != '=') return p.fail("expected '='");
        p.advance();
        p.skipSpaces();
        const value = try p.parseValue();
        const parent = try p.descend(table, path.items[0 .. path.items.len - 1]);
        const gop = try parent.getOrPut(p.arena, path.items[path.items.len - 1]);
        if (gop.found_existing) return p.fail("duplicate key");
        gop.value_ptr.* = value;
    }

    fn keyPath(p: *Parser, path: *std.ArrayList([]const u8)) Error!void {
        while (true) {
            p.skipSpaces();
            try path.append(p.arena, try p.parseKey());
            p.skipSpaces();
            if (p.peek() == '.') {
                p.advance();
                continue;
            }
            return;
        }
    }

    fn parseKey(p: *Parser) Error![]const u8 {
        const c = p.peek() orelse return p.fail("expected key");
        if (c == '"') return p.basicString();
        if (c == '\'') return p.literalString();
        const start = p.pos;
        while (p.peek()) |ch| {
            if (std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-') p.advance() else break;
        }
        if (p.pos == start) return p.fail("expected key");
        return p.src[start..p.pos];
    }

    fn parseValue(p: *Parser) Error!Value {
        const c = p.peek() orelse return p.fail("expected value");
        switch (c) {
            '"' => {
                if (p.startsWith("\"\"\"")) return .{ .string = try p.multilineBasic() };
                return .{ .string = try p.basicString() };
            },
            '\'' => {
                if (p.startsWith("'''")) return .{ .string = try p.multilineLiteral() };
                return .{ .string = try p.literalString() };
            },
            '[' => return p.array(),
            '{' => return p.inlineTable(),
            't' => if (p.startsWith("true")) {
                p.pos += 4;
                return .{ .boolean = true };
            },
            'f' => if (p.startsWith("false")) {
                p.pos += 5;
                return .{ .boolean = false };
            },
            else => {},
        }
        return p.number();
    }

    fn number(p: *Parser) Error!Value {
        const start = p.pos;
        while (p.peek()) |ch| {
            if (std.ascii.isAlphanumeric(ch) or ch == '+' or ch == '-' or ch == '.' or ch == '_') p.advance() else break;
        }
        const raw = p.src[start..p.pos];
        if (raw.len == 0) return p.fail("expected value");
        var buf: [64]u8 = undefined;
        var n: usize = 0;
        for (raw) |ch| {
            if (ch == '_') continue;
            if (n == buf.len) return p.fail("number too long");
            buf[n] = ch;
            n += 1;
        }
        const text = buf[0..n];
        if (std.fmt.parseInt(i64, text, 0)) |i| return .{ .integer = i } else |_| {}
        if (std.fmt.parseFloat(f64, text)) |f| return .{ .float = f } else |_| {}
        return p.fail("invalid value");
    }

    fn array(p: *Parser) Error!Value {
        p.advance(); // [
        var items: std.ArrayList(Value) = .empty;
        while (true) {
            p.skipBlank();
            if (p.peek() == ']') {
                p.advance();
                break;
            }
            try items.append(p.arena, try p.parseValue());
            p.skipBlank();
            const c = p.peek() orelse return p.fail("unterminated array");
            if (c == ',') {
                p.advance();
            } else if (c != ']') {
                return p.fail("expected ',' or ']'");
            }
        }
        return .{ .array = items.items };
    }

    fn inlineTable(p: *Parser) Error!Value {
        p.advance(); // {
        const t = try p.newTable();
        p.skipSpaces();
        if (p.peek() == '}') {
            p.advance();
            return .{ .table = t };
        }
        while (true) {
            p.skipSpaces();
            try p.keyValue(t);
            p.skipSpaces();
            const c = p.peek() orelse return p.fail("unterminated inline table");
            p.advance();
            switch (c) {
                ',' => continue,
                '}' => return .{ .table = t },
                else => return p.fail("expected ',' or '}'"),
            }
        }
    }

    fn literalString(p: *Parser) Error![]const u8 {
        p.advance(); // '
        const start = p.pos;
        while (p.peek()) |c| {
            if (c == '\'') {
                const s = p.src[start..p.pos];
                p.advance();
                return s;
            }
            if (c == '\n') break;
            p.advance();
        }
        return p.fail("unterminated string");
    }

    fn multilineLiteral(p: *Parser) Error![]const u8 {
        p.pos += 3;
        if (p.startsWith("\n")) p.advance() else if (p.startsWith("\r\n")) p.pos += 2;
        const start = p.pos;
        while (p.pos < p.src.len) {
            if (p.startsWith("'''")) {
                const s = p.src[start..p.pos];
                p.pos += 3;
                return s;
            }
            p.advance();
        }
        return p.fail("unterminated string");
    }

    fn basicString(p: *Parser) Error![]const u8 {
        p.advance(); // "
        var out: std.ArrayList(u8) = .empty;
        while (p.peek()) |c| {
            switch (c) {
                '"' => {
                    p.advance();
                    return out.items;
                },
                '\\' => try p.escape(&out),
                '\n' => break,
                else => {
                    try out.append(p.arena, c);
                    p.advance();
                },
            }
        }
        return p.fail("unterminated string");
    }

    fn multilineBasic(p: *Parser) Error![]const u8 {
        p.pos += 3;
        if (p.startsWith("\n")) p.advance() else if (p.startsWith("\r\n")) p.pos += 2;
        var out: std.ArrayList(u8) = .empty;
        while (p.peek()) |c| {
            if (p.startsWith("\"\"\"")) {
                p.pos += 3;
                return out.items;
            }
            if (c == '\\') {
                // line-ending backslash trims following whitespace
                const next = if (p.pos + 1 < p.src.len) p.src[p.pos + 1] else 0;
                if (next == '\n' or next == '\r' or next == ' ' or next == '\t') {
                    p.advance();
                    while (p.peek()) |w| switch (w) {
                        ' ', '\t', '\r', '\n' => p.advance(),
                        else => break,
                    };
                    continue;
                }
                try p.escape(&out);
                continue;
            }
            try out.append(p.arena, c);
            p.advance();
        }
        return p.fail("unterminated string");
    }

    fn escape(p: *Parser, out: *std.ArrayList(u8)) Error!void {
        p.advance(); // backslash
        const c = p.peek() orelse return p.fail("unterminated escape");
        p.advance();
        const byte: u8 = switch (c) {
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            'b' => 8,
            'f' => 12,
            '"' => '"',
            '\\' => '\\',
            'u', 'U' => {
                const len: usize = if (c == 'u') 4 else 8;
                if (p.pos + len > p.src.len) return p.fail("invalid unicode escape");
                const cp = std.fmt.parseInt(u21, p.src[p.pos .. p.pos + len], 16) catch
                    return p.fail("invalid unicode escape");
                p.pos += len;
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &buf) catch return p.fail("invalid unicode escape");
                try out.appendSlice(p.arena, buf[0..n]);
                return;
            },
            else => return p.fail("invalid escape"),
        };
        try out.append(p.arena, byte);
    }
};

const testing = std.testing;

test "parse config-like document" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const src =
        \\# comment
        \\default = "local"   # trailing
        \\
        \\[connections.local]
        \\url = "postgres://u:p@localhost/app"
        \\
        \\[connections."my shop"]
        \\driver = 'mysql'
        \\port = 3_306
        \\tags = ["a", "b",]
        \\opts = { ssl = true, timeout = 1.5 }
        \\notes = """
        \\multi \
        \\   line"""
    ;
    const root = try parse(arena.allocator(), src, null);
    try testing.expectEqualStrings("local", root.get("default").?.string);
    const conns = root.get("connections").?.table;
    try testing.expectEqual(@as(usize, 2), conns.count());
    try testing.expectEqualStrings("local", conns.keys()[0]);
    const shop = conns.get("my shop").?.table;
    try testing.expectEqualStrings("mysql", shop.get("driver").?.string);
    try testing.expectEqual(@as(i64, 3306), shop.get("port").?.integer);
    try testing.expectEqual(@as(usize, 2), shop.get("tags").?.array.len);
    try testing.expect(shop.get("opts").?.table.get("ssl").?.boolean);
    try testing.expectEqualStrings("multi line", shop.get("notes").?.string);
}

test "syntax error reports line" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    try testing.expectError(error.SyntaxError, parse(arena.allocator(), "a = 1\nb = \"x\n", &diag));
    try testing.expectEqual(@as(usize, 2), diag.line);
}
