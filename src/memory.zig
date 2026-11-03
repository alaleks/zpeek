const std = @import("std");

pub const retained_buffer_limit = 256 * 1024;

/// Reuse ordinary buffers; release unusually large allocations once unused.
pub fn clear(buffer: *std.ArrayList(u8), gpa: std.mem.Allocator) void {
    if (buffer.capacity > retained_buffer_limit) {
        buffer.deinit(gpa);
        buffer.* = .empty;
    } else buffer.clearRetainingCapacity();
}

/// Call after replacement, so input slices may safely refer to the old buffer.
pub fn trim(buffer: *std.ArrayList(u8), gpa: std.mem.Allocator) void {
    if (buffer.capacity > @max(retained_buffer_limit, buffer.items.len *| 2))
        buffer.shrinkAndFree(gpa, buffer.items.len);
}

test "small buffers are reused and oversized buffers release capacity" {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);
    try buffer.appendSlice(std.testing.allocator, "small");
    const capacity = buffer.capacity;
    clear(&buffer, std.testing.allocator);
    try std.testing.expectEqual(capacity, buffer.capacity);
    try buffer.resize(std.testing.allocator, retained_buffer_limit * 2);
    clear(&buffer, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), buffer.capacity);
}
