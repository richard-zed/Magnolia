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

    // An optional third argument sizes the render. Hardcoding 96 made every
    // comparison against rsvg-convert invalid whenever the reference was
    // rendered at any other size -- the two images were never the same grid,
    // and per-pixel reads off them silently described different coordinates.
    const size: f32 = blk: {
        const a = args.next() orelse break :blk 96;
        break :blk std.fmt.parseFloat(f32, a) catch 96;
    };
    // Fit through the library's own CTM rather than scaling edges by hand
    // here. Hand-rolled fitting is what produced the double-shrink bug in
    // `sheet`, and a second copy of the mapping is a second thing to keep in
    // step with xMidYMid meet.
    // Optional 4th arg: output HEIGHT, for non-square documents. A square
    // render of a 60x30 viewBox letterboxes the artwork, and comparing that
    // against a reference rendered at the document's own ratio compares two
    // different placements rather than two renders of the same gradient.
    const size_h: f32 = blk: {
        const a = args.next() orelse break :blk size;
        break :blk std.fmt.parseFloat(f32, a) catch size;
    };
    var icon = try mag.parseIconSized(gpa, src, size, size_h);
    defer icon.deinit(gpa);
    const px = try gpa.alloc(u8, @as(usize, @intFromFloat(size)) * @as(usize, @intFromFloat(size_h)) * 4);
    defer gpa.free(px);
    // Transparent, not white. A reference renderer leaves untouched pixels at
    // alpha 0, and filling the canvas opaque is what made every untouched
    // pixel disagree with it.
    @memset(px, 0);
    const nw: usize = @intFromFloat(size);
    const nh: usize = @intFromFloat(size_h);
    const acc = try gpa.alloc(f32, nw);
    defer gpa.free(acc);
    var r = mag.Raster{ .gpa = gpa, .w = nw, .h = nh, .px = px, .acc = acc };
    defer r.xs.deinit(gpa);
    var ng: usize = 0;
    var nc: usize = 0;
    for (icon.gradients.items) |g| if (g != null) { ng += 1; };
    for (icon.colors.items) |c| if (c != null) { nc += 1; };
    std.debug.print("gradients={d} colors={d} total={d}\n", .{ ng, nc, icon.gradients.items.len });
    for (icon.gradients.items, 0..) |g, gi| {
        if (g) |gg| {
            switch (gg) {
                .linear => |l| std.debug.print(" g{d} linear: ({d:.1},{d:.1})->({d:.1},{d:.1}) stops={d}\n", .{ gi, l.x0, l.y0, l.x1, l.y1, l.stops.len }),
                .radial => |rd| std.debug.print(" g{d} radial: c=({d:.1},{d:.1}) rx={d:.1} ry={d:.1} stops={d}\n", .{ gi, rd.cx, rd.cy, rd.rx, rd.ry, rd.stops.len }),
            }
            break;
        }
    }
    icon.draw(&r, .{ 0, 0, 0 });

    const vb = icon.view orelse .{ 0, 0, 24, 24 };
    std.debug.print("{s}: edges={d} stroked={d} view={any}\n", .{ in_path, icon.edges.items.len, icon.report.stroked, vb });

    const png = try mag.png.encode(gpa, nw, nh, px);
    defer gpa.free(png);
    var f = try std.Io.Dir.cwd().createFile(io, out_path, .{ .truncate = true });
    defer f.close(io);
    try f.writeStreamingAll(io, png);
}
