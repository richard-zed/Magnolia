const std = @import("std");
const mag = @import("root.zig");
pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const src = try std.Io.Dir.cwd().readFileAlloc(init.io, "/tmp/rad2.svg", gpa, .limited(1 << 20));
    var icon = try mag.parseIconSized(gpa, src, 60, 30);
    defer icon.deinit(gpa);
    for (icon.gradients.items, 0..) |g, i| if (g) |gg| {
        switch (gg) {
            .linear => std.debug.print("g{d} linear\n", .{i}),
            .radial => |rd| {
                std.debug.print("g{d} radial c=({d:.2},{d:.2}) rx={d:.2} ry={d:.2}\n", .{ i, rd.cx, rd.cy, rd.rx, rd.ry });
                break;
            },
        }
    };
}
