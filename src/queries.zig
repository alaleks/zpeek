//! Saved SQL queries: one `<name>.sql` file per query in a `queries`
//! directory next to the config file (e.g. ~/.config/zpeek/queries/). Plain
//! files are easy to edit by hand and work the same on every platform.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Entry = struct {
    name: []const u8,
    /// First non-empty line of the query, for previews.
    preview: []const u8,
};

pub const max_size = 1024 * 1024;

/// Directory for saved queries, derived from the config path.
pub fn dirPath(arena: Allocator, config_path: []const u8) Allocator.Error!?[]const u8 {
    if (config_path.len == 0) return null;
    const dir = std.fs.path.dirname(config_path) orelse return null;
    return try std.fs.path.join(arena, &.{ dir, "queries" });
}

/// Names become file names, so only a safe portable subset is allowed.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64 or name[0] == '.') return false;
    for (name) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.')) return false;
    }
    return true;
}

fn fileName(buf: []u8, name: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}.sql", .{name}) catch unreachable;
}

pub fn save(gpa: Allocator, io: Io, dir_path: []const u8, name: []const u8, sql: []const u8) !void {
    std.debug.assert(validName(name));
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, dir_path);
    var dir = try cwd.openDir(io, dir_path, .{});
    defer dir.close(io);
    var buf: [80]u8 = undefined;
    const trimmed = std.mem.trim(u8, sql, " \t\r\n");
    if (trimmed.len + 1 > max_size) return error.QueryTooLarge;
    const data = try std.mem.concat(gpa, u8, &.{ trimmed, "\n" });
    defer gpa.free(data);
    try dir.writeFile(io, .{ .sub_path = fileName(&buf, name), .data = data });
}

pub fn load(arena: Allocator, io: Io, dir_path: []const u8, name: []const u8) ![]const u8 {
    if (!validName(name)) return error.FileNotFound;
    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{});
    defer dir.close(io);
    var buf: [80]u8 = undefined;
    const data = try dir.readFileAlloc(io, fileName(&buf, name), arena, .limited(max_size));
    return std.mem.trim(u8, data, " \t\r\n");
}

pub fn remove(io: Io, dir_path: []const u8, name: []const u8) !void {
    if (!validName(name)) return error.FileNotFound;
    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{});
    defer dir.close(io);
    var buf: [80]u8 = undefined;
    try dir.deleteFile(io, fileName(&buf, name));
}

/// Saved queries sorted by name. A missing directory means no queries.
pub fn list(arena: Allocator, io: Io, dir_path: []const u8) ![]const Entry {
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => |e| return e,
    };
    defer dir.close(io);
    var out: std.ArrayList(Entry) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".sql")) continue;
        const name = entry.name[0 .. entry.name.len - ".sql".len];
        if (!validName(name)) continue;
        const owned = try arena.dupe(u8, name);
        const sql = load(arena, io, dir_path, owned) catch "";
        try out.append(arena, .{ .name = owned, .preview = previewLine(sql) });
    }
    std.mem.sort(Entry, out.items, {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            return std.ascii.lessThanIgnoreCase(a.name, b.name);
        }
    }.lessThan);
    return out.items;
}

fn previewLine(sql: []const u8) []const u8 {
    var it = std.mem.tokenizeAny(u8, sql, "\r\n");
    return std.mem.trim(u8, it.next() orelse "", " \t");
}

test "valid names" {
    try std.testing.expect(validName("active_users"));
    try std.testing.expect(validName("report-2026.v2"));
    try std.testing.expect(!validName("../etc/passwd"));
    try std.testing.expect(!validName("a b"));
    try std.testing.expect(!validName(".hidden"));
    try std.testing.expect(!validName(""));
}

test "saved queries round trip through files" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "queries" });
    const io = std.testing.io;

    try std.testing.expectEqual(@as(usize, 0), (try list(a, io, dir)).len);
    try save(gpa, io, dir, "recent", " \nSELECT *\nFROM people; \n");
    try save(gpa, io, dir, "active", "select * from people where active = 1;");
    try std.testing.expectEqualStrings("SELECT *\nFROM people;", try load(a, io, dir, "recent"));
    const entries = try list(a, io, dir);
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("active", entries[0].name);
    try std.testing.expectEqualStrings("SELECT *", entries[1].preview);

    try remove(io, dir, "recent");
    try std.testing.expectError(error.FileNotFound, load(a, io, dir, "recent"));
    try std.testing.expectEqual(@as(usize, 1), (try list(a, io, dir)).len);
}
