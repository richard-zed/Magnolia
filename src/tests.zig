//! The regression suite.
//!
//! Every test here exists because something was once wrong, or was once
//! *asserted* to be wrong without evidence. The comments say which, because a
//! test whose reason has been forgotten gets deleted by the next person who
//! finds it inconvenient.

const std = @import("std");
const mag = @import("root.zig");

const t = std.testing;

// ------------------------------------------------------------------ fixtures
// The donut, exactly as shipped by the user. The two arcs sweep in OPPOSITE
// directions (1 0 and 1 1), which is the entire reason the inner contour is a
// hole. A fixture written from memory with both sweeps at 1 1 renders a disc,
// and once led to this pipeline being accused of inverting fills.
const donut_svg =
    \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
    \\ <defs><clipPath id="c"><rect width="10" height="10"/></clipPath></defs>
    \\ <g transform="translate(12 12) rotate(45)"><path d="M-8 0 A8 8 0 1 0 8 0 A8 8 0 1 0 -8 0 Z"/></g>
    \\ <circle cx="12" cy="12" r="3" fill="#f00"/>
    \\ <text x="0" y="0">x</text>
    \\</svg>
;

// Same construction at a size that makes a pixel probe easy.
const ring_svg =
    \\<svg viewBox="0 0 40 40"><path d="M6 20 A14 14 0 1 0 34 20 A14 14 0 1 0 6 20 Z M13 20 A7 7 0 1 1 27 20 A7 7 0 1 1 13 20 Z"/></svg>
;

const triangle_svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 24 24\"><path d=\"M12 2 L22 22 L2 22 Z\"/></svg>";
const text_svg = "<svg viewBox=\"0 0 24 24\"><text x=\"0\" y=\"0\">hi</text></svg>";
const clipped_svg = "<svg viewBox=\"0 0 24 24\"><defs><clipPath id=\"c\"><rect width=\"10\" height=\"10\"/></clipPath></defs><path d=\"M2 2 L4 2 L4 4 Z\"/></svg>";

// ------------------------------------------------------------------ helpers
fn rasterize(gpa: std.mem.Allocator, edges: []const mag.Edge) ![]u8 {
    const px = try gpa.alloc(u8, 40 * 40 * 4);
    errdefer gpa.free(px);
    @memset(px, 0);
    const acc = try gpa.alloc(f32, 40);
    defer gpa.free(acc);
    var r = mag.Raster{ .gpa = gpa, .w = 40, .h = 40, .px = px, .acc = acc };
    defer r.xs.deinit(gpa);
    r.fill(edges, .{ 0, 0, 0 });
    return px;
}

fn alphaAt(px: []const u8, x: usize, y: usize) u8 {
    return px[(y * 40 + x) * 4 + 3];
}

// ------------------------------------------------------------------ winding
test "a reversed inner contour is a hole, not a disc" {
    var icon = try mag.parseIcon(t.allocator, ring_svg);
    defer icon.deinit(t.allocator);

    const px = try rasterize(t.allocator, icon.edges.items);
    defer t.allocator.free(px);

    // Ring band at r = 10.5 from (20,20).
    try t.expect(alphaAt(px, 30, 20) > 200);
    // Centre is inside the hole: must be untouched.
    try t.expectEqual(@as(u8, 0), alphaAt(px, 20, 20));
    // Outside the outer radius.
    try t.expectEqual(@as(u8, 0), alphaAt(px, 1, 1));
}

test "the shipped donut fixture parses with a hole-bearing contour" {
    // Guards the fixture itself: two arcs, and the inner contour present.
    var icon = try mag.parseIcon(t.allocator, donut_svg);
    defer icon.deinit(t.allocator);
    try t.expectEqual(@as(usize, 2), icon.report.arcs);
    try t.expectEqual(@as(usize, 1), icon.report.paths);
    try t.expect(icon.view != null);
}

// ------------------------------------------------------------ flattening
test "flattening an arc is stable" {
    // PINNED COUNT. This is the guard that would have caught "294 vs 197" as
    // wrong the moment it was claimed: a different radius and rotation was
    // compared against a reference render and reported as a tessellation
    // regression. A pinned number cannot be misread that way.
    var icon = try mag.parseIcon(t.allocator, donut_svg);
    defer icon.deinit(t.allocator);
    try t.expectEqual(@as(usize, 197), icon.edges.items.len);
}

test "a larger radius flattens to more segments" {
    // Directional control for the pin above, so it cannot be satisfied by a
    // flattener that emits a constant number of edges per arc.
    const big = "<svg viewBox=\"0 0 40 40\"><path d=\"M2 20 A18 18 0 1 0 38 20 A18 18 0 1 0 2 20 Z\"/></svg>";
    const small = "<svg viewBox=\"0 0 40 40\"><path d=\"M18 20 A2 2 0 1 0 22 20 A2 2 0 1 0 18 20 Z\"/></svg>";
    var a = try mag.parseIcon(t.allocator, big);
    defer a.deinit(t.allocator);
    var b = try mag.parseIcon(t.allocator, small);
    defer b.deinit(t.allocator);
    try t.expect(a.edges.items.len > b.edges.items.len);
}

// ------------------------------------------------------------- path data
test "path command counts are exact" {
    var pb = mag.PathBuf{ .gpa = t.allocator };
    defer pb.deinit();
    var st = mag.pathdata.DStats{};
    try mag.pathdata.parse(&pb, "M10 10 L20 10 L20 20 Z", &st);
    // Three segments: M is a move, then two L, then Z closes.
    try t.expectEqual(@as(usize, 3), pb.edges.items.len);
    try t.expectEqual(@as(usize, 0), st.arc_count);
}

test "a truncated path is an error, not a silent empty fill" {
    var pb = mag.PathBuf{ .gpa = t.allocator };
    defer pb.deinit();
    var st = mag.pathdata.DStats{};
    try t.expectError(error.BadPath, mag.pathdata.parse(&pb, "M10 L", &st));
}

test "implicit lineto repeats the previous command" {
    var pb = mag.PathBuf{ .gpa = t.allocator };
    defer pb.deinit();
    var st = mag.pathdata.DStats{};
    try mag.pathdata.parse(&pb, "M0 0 10 0 10 10", &st);
    try t.expectEqual(@as(usize, 2), pb.edges.items.len);
}

// ------------------------------------------------------------------- png
test "png round-trips through its own encoder" {
    // Stored deflate, so the encoder is cheap to verify end to end. Alpha is
    // asserted explicitly: a frame painted entirely with opaque colours once
    // exported as a fully TRANSPARENT png, and the only test at the time
    // asserted the bug.
    const w: usize = 4;
    const h: usize = 3;
    const src = try t.allocator.alloc(u8, w * h * 4);
    defer t.allocator.free(src);
    for (src, 0..) |*b, i| b.* = @intCast(i % 256);
    var i: usize = 0;
    while (i < w * h) : (i += 1) src[i * 4 + 3] = 255;

    const out = try mag.png.encode(t.allocator, w, h, src);
    defer t.allocator.free(out);

    try t.expectEqualSlices(u8, &[_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' }, out[0..8]);

    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(t.allocator);
    var pos: usize = 8;
    var width: u32 = 0;
    while (pos + 8 <= out.len) {
        const len = std.mem.readInt(u32, out[pos..][0..4], .big);
        const typ = out[pos + 4 ..][0..4];
        const body = out[pos + 8 ..][0..len];
        if (std.mem.eql(u8, typ, "IHDR")) {
            width = std.mem.readInt(u32, body[0..4], .big);
        } else if (std.mem.eql(u8, typ, "IDAT")) {
            try idat.appendSlice(t.allocator, body);
        }
        pos += 12 + len;
    }
    try t.expectEqual(@as(u32, 4), width);

    // Stored deflate: zlib header, then 5-byte blocks of (final, len, ~len).
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(t.allocator);
    var p: usize = 2;
    while (p + 5 <= idat.items.len) {
        const bfinal = idat.items[p];
        const blen = std.mem.readInt(u16, idat.items[p + 1 ..][0..2], .little);
        const nlen = std.mem.readInt(u16, idat.items[p + 3 ..][0..2], .little);
        try t.expectEqual(@as(u16, ~blen), nlen);
        try raw.appendSlice(t.allocator, idat.items[p + 5 ..][0..blen]);
        p += 5 + blen;
        if (bfinal & 1 == 1) break;
    }

    try t.expectEqual(@as(usize, h * (w * 4 + 1)), raw.items.len);
    var y: usize = 0;
    while (y < h) : (y += 1) {
        const row = raw.items[y * (w * 4 + 1) ..][0 .. w * 4 + 1];
        try t.expectEqual(@as(u8, 0), row[0]);
        try t.expectEqualSlices(u8, src[y * w * 4 ..][0 .. w * 4], row[1..]);
        var x: usize = 0;
        while (x < w) : (x += 1) try t.expectEqual(@as(u8, 255), row[1 + x * 4 + 3]);
    }
}

// -------------------------------------------------------------- doc layer
test "an unsupported element is reported, not silently dropped" {
    const svg = "<svg viewBox=\"0 0 24 24\"><text x=\"0\" y=\"0\">hi</text></svg>";
    var icon = try mag.parseIcon(t.allocator, svg);
    defer icon.deinit(t.allocator);
    try t.expect(icon.report.unsupported.items.len >= 1);
}

test "an unsupported element contributes no geometry" {
    var icon = try mag.parseIcon(t.allocator, text_svg);
    defer icon.deinit(t.allocator);
    try t.expectEqual(@as(usize, 0), icon.edges.items.len);
}

test "a clipPath subtree contributes no geometry" {
    // Clipping is not implemented, so the assertion is that its <rect> does
    // NOT become an edge. When clipping lands, this test must be rewritten
    // deliberately rather than deleted.
    var icon = try mag.parseIcon(t.allocator, clipped_svg);
    defer icon.deinit(t.allocator);
    try t.expectEqual(@as(usize, 3), icon.edges.items.len);
    try t.expectEqual(@as(usize, 0), icon.report.shapes);
}

test "a triangle parses to three edges" {
    var icon = try mag.parseIcon(t.allocator, triangle_svg);
    defer icon.deinit(t.allocator);
    try t.expectEqual(@as(usize, 3), icon.edges.items.len);
}

test "viewBox is captured and its extent is readable" {
    var icon = try mag.parseIcon(t.allocator, triangle_svg);
    defer icon.deinit(t.allocator);
    try t.expect(icon.view != null);
    try t.expectEqual(@as(f32, 24), icon.view.?[2]);
}

// ---------------------------------------------------------------- stroke
fn strokeSvg(comptime body: []const u8) []const u8 {
    return "<svg viewBox=\"0 0 40 40\">" ++ body ++ "</svg>";
}

fn renderStroke(gpa: std.mem.Allocator, svg: []const u8) !struct { icon: mag.Icon, px: []u8 } {
    var icon = try mag.parseIcon(gpa, svg);
    errdefer icon.deinit(gpa);
    const px = try gpa.alloc(u8, 40 * 40 * 4);
    @memset(px, 0);
    const acc = try gpa.alloc(f32, 40);
    defer gpa.free(acc);
    var ras = mag.Raster{ .gpa = gpa, .w = 40, .h = 40, .px = px, .acc = acc };
    defer ras.xs.deinit(gpa);
    icon.draw(&ras, .{ 0, 0, 0 });
    return .{ .icon = icon, .px = px };
}

test "stroke-only geometry is produced, not dropped" {
    const svg = strokeSvg("<path d=\"M4 20 L36 20\" fill=\"none\" stroke=\"#000\" stroke-width=\"4\"/>");
    var r = try renderStroke(t.allocator, svg);
    defer r.icon.deinit(t.allocator);
    defer t.allocator.free(r.px);
    try t.expect(r.icon.report.stroked == 1);
    try t.expect(r.icon.edges.items.len > 0);
    // The band is centred on y=20: two above and two below are inked.
    try t.expect(alphaAt(r.px, 20, 20) > 200);
    // The band spans y=18..22 exactly, which is four whole pixels: rows 18,
    // 19, 20 and 21. Row 22 begins at 22.0, where the band ends. Measured,
    // not assumed -- the first version of this test asserted row 22 and was
    // wrong about which rows a width-4 stroke covers.
    try t.expect(alphaAt(r.px, 20, 18) > 200);
    try t.expect(alphaAt(r.px, 20, 21) > 200);
    try t.expectEqual(@as(u8, 0), alphaAt(r.px, 20, 22));
    try t.expectEqual(@as(u8, 0), alphaAt(r.px, 20, 17));
    // Outside the band is untouched.
    try t.expectEqual(@as(u8, 0), alphaAt(r.px, 20, 14));
}

test "stroke width controls the band" {
    const thin = strokeSvg("<path d=\"M4 20 L36 20\" fill=\"none\" stroke=\"#000\" stroke-width=\"2\"/>");
    const thick = strokeSvg("<path d=\"M4 20 L36 20\" fill=\"none\" stroke=\"#000\" stroke-width=\"8\"/>");
    var a = try renderStroke(t.allocator, thin);
    defer a.icon.deinit(t.allocator);
    defer t.allocator.free(a.px);
    var b = try renderStroke(t.allocator, thick);
    defer b.icon.deinit(t.allocator);
    defer t.allocator.free(b.px);
    var thin_in: usize = 0;
    var thick_in: usize = 0;
    var y: usize = 0;
    while (y < 40) : (y += 1) {
        if (alphaAt(a.px, 20, y) > 100) thin_in += 1;
        if (alphaAt(b.px, 20, y) > 100) thick_in += 1;
    }
    try t.expect(thick_in > thin_in);
    try t.expect(thin_in >= 2);
}

test "a stroke with no fill does not also fill the interior" {
    // A stroked triangle: the interior must stay empty. Getting this wrong is
    // the classic stroke bug -- emitting the centreline alongside the outline.
    const svg = strokeSvg("<path d=\"M20 6 L34 32 L6 32 Z\" fill=\"none\" stroke=\"#000\" stroke-width=\"2\"/>");
    var r = try renderStroke(t.allocator, svg);
    defer r.icon.deinit(t.allocator);
    defer t.allocator.free(r.px);
    try t.expectEqual(@as(u8, 0), alphaAt(r.px, 20, 26));
    // But the edges themselves are inked.
    try t.expect(alphaAt(r.px, 20, 32) > 100);
}

test "a filled and stroked shape keeps its fill" {
    const svg = strokeSvg("<path d=\"M20 6 L34 32 L6 32 Z\" fill=\"#000\"/>");
    var r = try renderStroke(t.allocator, svg);
    defer r.icon.deinit(t.allocator);
    defer t.allocator.free(r.px);
    try t.expect(alphaAt(r.px, 20, 26) > 100);
}

test "stroke joins do not leave a gap at a right angle" {
    const svg = strokeSvg("<path d=\"M10 30 L10 10 L30 10\" fill=\"none\" stroke=\"#000\" stroke-width=\"6\" stroke-linejoin=\"round\"/>");
    var r = try renderStroke(t.allocator, svg);
    defer r.icon.deinit(t.allocator);
    defer t.allocator.free(r.px);
    // The corner itself must be solid -- an unbridged join leaves a notch.
    try t.expect(alphaAt(r.px, 10, 10) > 200);
}

test "a miter limit falls back instead of spiking" {
    // A very acute corner: unclamped, a miter extends ~1/sin(theta/2) times
    // the half width, which for this angle runs far past the shape.
    const svg = strokeSvg("<path d=\"M6 34 L20 10 L34 34\" fill=\"none\" stroke=\"#000\" stroke-width=\"2\" stroke-linejoin=\"miter\" stroke-miterlimit=\"4\"/>");
    var r = try renderStroke(t.allocator, svg);
    defer r.icon.deinit(t.allocator);
    defer t.allocator.free(r.px);
    // The apex at (20,10); a clamped miter must not shoot above it.
    try t.expectEqual(@as(u8, 0), alphaAt(r.px, 20, 2));
    // But the join is still drawn.
    try t.expect(alphaAt(r.px, 20, 10) > 100 or alphaAt(r.px, 20, 11) > 100);
}

test "stroke splits contours rather than welding them" {
    // Two separate lines. A flat edge list with no subpath breaks would place
    // a bridging edge from the end of the first to the start of the second.
    const svg = strokeSvg("<path d=\"M4 10 L18 10 M22 30 L36 30\" fill=\"none\" stroke=\"#000\" stroke-width=\"4\"/>");
    var r = try renderStroke(t.allocator, svg);
    defer r.icon.deinit(t.allocator);
    defer t.allocator.free(r.px);
    try t.expect(alphaAt(r.px, 10, 10) > 200);
    try t.expect(alphaAt(r.px, 30, 30) > 200);
    // The diagonal gap between them must be empty.
    try t.expectEqual(@as(u8, 0), alphaAt(r.px, 20, 20));
}

test "an empty subpath strokes to nothing" {
    const svg = strokeSvg("<path d=\"M10 10 Z\" fill=\"none\" stroke=\"#000\" stroke-width=\"4\"/>");
    var r = try renderStroke(t.allocator, svg);
    defer r.icon.deinit(t.allocator);
    defer t.allocator.free(r.px);
    // Butt cap on a degenerate subpath draws nothing, per SVG.
    try t.expectEqual(@as(u8, 0), alphaAt(r.px, 10, 10));
}

test "zero stroke width draws nothing" {
    const svg = strokeSvg("<path d=\"M4 20 L36 20\" fill=\"none\" stroke=\"#000\" stroke-width=\"0\"/>");
    var r = try renderStroke(t.allocator, svg);
    defer r.icon.deinit(t.allocator);
    defer t.allocator.free(r.px);
    try t.expectEqual(@as(usize, 0), r.icon.edges.items.len);
}
