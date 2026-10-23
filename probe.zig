const std = @import("std");
pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var list: std.ArrayList(u32) = .empty;
    defer list.deinit(gpa);
    try list.append(gpa, 7);

    const data = try std.fs.cwd().readFileAlloc(gpa, "/tmp/svg/probe.zig", 1 << 20);
    defer gpa.free(data);
    std.debug.print("list={} len={} alloc={} hash={x}\n", .{ list.items[0], data.len, std.heap.page_size_min, std.hash.Crc32.hash(data[0..4]) });
}
