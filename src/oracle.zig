//! Oracle harness: render an SVG with Magnolia at a fixed size, matching what
//! a reference renderer produces, so the two can be compared pixel by pixel.
const std = @import("std");
const mag = @import("root.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.next();
    const in_path = args.next() orelse return error.Usage;
    const out_path = args.next() orelse return error.Usage;

    const src = try std.Io.Dir.cwd().readFileAlloc(io, in_path, gpa, .limited(1 << 24));
    defer gpa.free(src);

    const size: f32 = 96;
    // Fit through the library's own CTM rather than scaling edges by hand
    // here. Hand-rolled fitting is what produced the double-shrink bug in
    // `sheet`, and a second copy of the mapping is a second thing to keep in
    // step with xMidYMid meet.
    var icon = try mag.parseIconSized(gpa, src, size, size);
    defer icon.deinit(gpa);
    const px = try gpa.alloc(u8, 96 * 96 * 4);
    defer gpa.free(px);
    // Transparent, not white. A reference renderer leaves untouched pixels at
    // alpha 0, and filling the canvas opaque is what made every untouched
    // pixel disagree with it.
    @memset(px, 0);
    const acc = try gpa.alloc(f32, 96);
    defer gpa.free(acc);
    var r = mag.Raster{ .gpa = gpa, .w = 96, .h = 96, .px = px, .acc = acc };
    defer r.xs.deinit(gpa);
    icon.draw(&r, .{ 0, 0, 0 });

    const vb = icon.view orelse .{ 0, 0, 24, 24 };
    std.debug.print("{s}: edges={d} stroked={d} view={any}\n", .{ in_path, icon.edges.items.len, icon.report.stroked, vb });

    const png = try mag.png.encode(gpa, 96, 96, px);
    defer gpa.free(png);
    var f = try std.Io.Dir.cwd().createFile(io, out_path, .{ .truncate = true });
    defer f.close(io);
    try f.writeStreamingAll(io, png);
}
