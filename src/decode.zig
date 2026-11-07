//! Decodes a PNG with Sakura and reports its colour histogram.
//!
//!   decode <file.png> [max_entries]
//!
//! Exists so pixel verification never runs through a decoder written in the
//! same session as the encoder it is checking. Sakura is an independent
//! no-allocator decoder, so agreement between the two is real evidence.
const std = @import("std");
const sakura = @import("sakura");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.next();
    const in_path = args.next() orelse return error.Usage;

    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, in_path, gpa, .limited(1 << 26));
    defer gpa.free(bytes);

    const img = try sakura.imageSize(bytes, .rgba8);
    const out = try gpa.alloc(u8, img.byteLen());
    defer gpa.free(out);
    const scratch = try gpa.alloc(u8, try sakura.scratchSize(bytes, .rgba8));
    defer gpa.free(scratch);

    const dec = try sakura.decode(bytes, .rgba8, .strict, out, scratch);
    std.debug.print("{s}: {d}x{d} damage={s}\n", .{ in_path, img.width, img.height, @tagName(dec.damage) });

    // Count distinct RGB triples. Bounded by construction: 24-bit space is the
    // ceiling and icons never approach it.
    var map = std.AutoHashMap(u24, usize).init(gpa);
    defer map.deinit();
    var px: usize = 0;
    while (px < out.len) : (px += 4) {
        const key: u24 = (@as(u24, out[px]) << 16) | (@as(u24, out[px + 1]) << 8) | out[px + 2];
        const gop = try map.getOrPut(key);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }
    std.debug.print("distinct={d}\n", .{map.count()});

    // Sort by count so the dominant colours come first.
    const Entry = struct { k: u24, n: usize };
    var list = try gpa.alloc(Entry, map.count());
    defer gpa.free(list);
    var it = map.iterator();
    var i: usize = 0;
    while (it.next()) |e| : (i += 1) list[i] = .{ .k = e.key_ptr.*, .n = e.value_ptr.* };
    std.mem.sort(Entry, list, {}, struct {
        fn lt(_: void, a: Entry, b: Entry) bool {
            return a.n > b.n;
        }
    }.lt);
    for (list) |e| {
        std.debug.print("  #{x:0>2}{x:0>2}{x:0>2} {d}\n", .{ @as(u8, @truncate(e.k >> 16)), @as(u8, @truncate(e.k >> 8)), @as(u8, @truncate(e.k)), e.n });
    }
}
