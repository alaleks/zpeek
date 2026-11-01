//! Streaming export of retained results; values keep the driver's text representation.
const std = @import("std");
const db = @import("db/db.zig");

pub const Format = enum { csv, json };
pub const Selection = struct {
    rows: ?[]const usize = null,
    columns: ?[]const usize = null,
};

pub fn write(w: *std.Io.Writer, result: db.Result, format: Format, selection: Selection) !void {
    const ncols = if (selection.columns) |cols| cols.len else result.columns.len;
    const nrows = if (selection.rows) |rows| rows.len else result.rows.len;
    for (0..ncols) |i| {
        const ci = if (selection.columns) |cols| cols[i] else i;
        if (ci >= result.columns.len) return error.InvalidSelection;
        if (format == .json) for (0..i) |j| {
            const cj = if (selection.columns) |cols| cols[j] else j;
            if (std.mem.eql(u8, result.columns[ci], result.columns[cj])) return error.DuplicateColumns;
        };
    }
    if (format == .csv) {
        for (0..ncols) |i| {
            if (i > 0) try w.writeByte(',');
            try csvString(w, result.columns[if (selection.columns) |cols| cols[i] else i]);
        }
        try w.writeAll("\r\n");
    } else try w.writeByte('[');
    for (0..nrows) |i| {
        const ri = if (selection.rows) |rows| rows[i] else i;
        if (ri >= result.rows.len) return error.InvalidSelection;
        const row = result.rows[ri];
        if (format == .json) try w.writeAll(if (i == 0) "\n  {" else ",\n  {");
        for (0..ncols) |j| {
            const ci = if (selection.columns) |cols| cols[j] else j;
            if (ci >= row.len) return error.InvalidSelection;
            if (j > 0) try w.writeAll(if (format == .csv) "," else ", ");
            if (format == .json) {
                try std.json.Stringify.value(result.columns[ci], .{}, w);
                try w.writeAll(": ");
                try std.json.Stringify.value(row[ci], .{}, w);
            } else if (row[ci]) |value| try csvString(w, value);
        }
        try w.writeAll(if (format == .csv) "\r\n" else "}");
    }
    if (format == .json) try w.writeAll(if (nrows == 0) "]\n" else "\n]\n");
}

fn csvString(w: *std.Io.Writer, value: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('"');
    var from: usize = 0;
    for (value, 0..) |c, i| if (c == '"') {
        try w.writeAll(value[from..i]);
        try w.writeAll("\"\"");
        from = i + 1;
    };
    try w.writeAll(value[from..]);
    try w.writeByte('"');
}

pub fn save(io: std.Io, path: []const u8, result: db.Result, format: Format, selection: Selection) !void {
    var file = try std.Io.Dir.cwd().createFileAtomic(io, path, .{
        .permissions = if (@import("builtin").os.tag == .windows) .default_file else .fromMode(0o600),
    });
    defer file.deinit(io);
    var buffer: [4096]u8 = undefined;
    var writer = file.file.writer(io, &buffer);
    try write(&writer.interface, result, format, selection);
    try writer.interface.flush();
    try file.link(io);
}

test "CSV and JSON preserve nulls, quotes, Unicode and selected row order" {
    var result: db.Result = .{ .arena = .init(std.testing.allocator), .columns = &.{ "name", "note" }, .rows = &.{ &.{ "Ada, \"A\"", "a\nb" }, &.{ "日本", null } } };
    defer result.deinit();
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try write(&writer, result, .csv, .{});
    try std.testing.expectEqualStrings("\"name\",\"note\"\r\n\"Ada, \"\"A\"\"\",\"a\nb\"\r\n\"日本\",\r\n", writer.buffered());
    writer.end = 0;
    try write(&writer, result, .json, .{ .rows = &.{ 1, 0 }, .columns = &.{1} });
    try std.testing.expectEqualStrings("[\n  {\"note\": null},\n  {\"note\": \"a\\nb\"}\n]\n", writer.buffered());
    writer.end = 0;
    try std.testing.expectError(error.DuplicateColumns, write(&writer, result, .json, .{ .columns = &.{ 0, 0 } }));
}

test "file export is atomic and refuses to overwrite existing data" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "result.csv" });
    defer a.free(path);
    var result: db.Result = .{ .arena = .init(a), .columns = &.{"value"}, .rows = &.{&.{"first"}} };
    defer result.deinit();
    try std.testing.expectError(error.InvalidSelection, save(std.testing.io, path, result, .csv, .{ .rows = &.{99} }));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(4096)));
    try save(std.testing.io, path, result, .csv, .{});
    result.rows = &.{&.{"second"}};
    try std.testing.expectError(error.PathAlreadyExists, save(std.testing.io, path, result, .csv, .{}));
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(4096));
    defer a.free(bytes);
    try std.testing.expectEqualStrings("\"value\"\r\n\"first\"\r\n", bytes);
}
