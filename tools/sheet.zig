//! Renders SVGs side by side into one contact sheet PNG.
//!
//!   sheet <out.png> <cell_px> <file.svg>...
//!
//! Thin by design: this is the only place in the tree that touches argv, the
//! filesystem or the PNG writer. Everything else is a call into the library,
//! so the exact same pipeline can be driven by a test or by a UI.
//!
//! This is the original demo harness (formerly SVG_IN / SVG_OUT / SVG_CELL),
//! moved onto a module boundary and off the removed `std.posix` env API.

const std = @import("std");
const magnolia = @import("magnolia");

const bg = [3]u8{ 250, 250, 252 }; // light background so coverage is visible
const palette = [_][3]u8{
    .{ 30, 30, 46 },    .{ 137, 180, 250 }, .{ 203, 166, 247 },
    .{ 166, 227, 161 }, .{ 243, 139, 168 }, .{ 249, 226, 175 },
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 4) {
        std.debug.print("usage: sheet <out.png> <cell_px> <file.svg>...\n", .{});
        return error.BadArgs;
    }
    const out_path = args[1];
    const cell = try std.fmt.parseInt(usize, args[2], 10);
    if (cell == 0) return error.BadArgs;

    const n = args.len - 3;
    const icons = try arena.alloc(magnolia.Icon, n);
    for (args[3..], 0..) |path, i| {
        const bytes = try magnolia.io.readFile(io, arena, path, .limited(1 << 26));
        // Size through the library's CTM, not by scaling edges here. The
        // viewBox -> target mapping (xMidYMid meet) belongs in one place, and
        // doing it twice shrank every icon by 0.78 twice over.
        const cf: f32 = @floatFromInt(cell);
        icons[i] = try magnolia.parseIconSized(arena, bytes, cf, cf);

        const r = icons[i].report;
        std.debug.print("{s}: paths={} shapes={} edges={} arcs={} no_fill={} stroked={}\n", .{
            std.fs.path.basename(path), r.paths,   r.shapes,
            icons[i].edges.items.len,   r.arcs,
            r.no_fill,                  r.stroked,
        });
        for (r.unsupported.items) |u| std.debug.print("    ! {s}\n", .{u});
    }

    // One cell per input, laid out left to right.
    const out_w = cell * n;
    const out_h = cell;
    const px = try arena.alloc(u8, out_w * out_h * 4);
    var i: usize = 0;
    while (i < out_w * out_h) : (i += 1) {
        px[i * 4 + 0] = bg[0];
        px[i * 4 + 1] = bg[1];
        px[i * 4 + 2] = bg[2];
        px[i * 4 + 3] = 255;
    }

    const acc = try arena.alloc(f32, out_w);
    // One scratch edge list shared by every icon: enough for the densest icon
    // measured so far (197 edges) with a wide margin. Overflow clips rather
    // than corrupting, so a pathological file loses detail, not memory safety.
    const scratch = try arena.alloc(magnolia.Edge, 200_000);

    for (icons, 0..) |*icon, idx| {
        if (icon.edges.items.len == 0) continue;
        // Geometry is already in cell pixels and centred by the CTM; shift it
        // into its column and go.
        const tx: f32 = @floatFromInt(idx * cell);

        var cnt: usize = 0;
        for (icon.edges.items) |e| {
            if (cnt == scratch.len) break;
            scratch[cnt] = .{
                .a = .{ .x = e.a.x + tx, .y = e.a.y },
                .b = .{ .x = e.b.x + tx, .y = e.b.y },
            };
            cnt += 1;
        }

        var r = magnolia.Raster{ .gpa = arena, .w = out_w, .h = out_h, .px = px, .acc = acc };
        defer r.xs.deinit(arena);
        r.fill(scratch[0..cnt], palette[idx % palette.len]);
    }

    const png_bytes = try magnolia.png.encode(arena, out_w, out_h, px);
    try magnolia.io.writeFile(io, out_path, png_bytes);
    std.debug.print("wrote {s} ({}x{}, {} icons)\n", .{ out_path, out_w, out_h, n });
}

