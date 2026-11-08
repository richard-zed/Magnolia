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

/// RGB of one pixel in the 40x40 stroke harness. Asserting on colour rather
/// than alpha is what catches "painted, but with the wrong paint" -- a stroked
/// outline with no resolved colour is fully inked and reads black.
fn pixelAt(px: []const u8, x: usize, y: usize) [3]u8 {
    const o = (y * 40 + x) * 4;
    return .{ px[o], px[o + 1], px[o + 2] };
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

// ------------------------------------------------------------------- colour
// Colour was absent from the data model entirely: `fill` was reduced to a
// none/not-none flag and `stroke` tracked geometry but never paint, so every
// shape rendered in one caller-supplied colour regardless of the source.
// These tests exist because that was invisible for as long as no coloured
// fixture was ever rendered.

test "a hex fill is parsed and travels per edge" {
    const svg = "<svg viewBox=\"0 0 10 10\"><path fill=\"#e8e833\" d=\"M0 0 L10 0 L10 10 Z\"/></svg>";
    var icon = try mag.parseIconSized(t.allocator, svg, 10, 10);
    defer icon.deinit(t.allocator);
    try t.expect(icon.colors.items.len == icon.edges.items.len);
    for (icon.colors.items) |c| {
        try t.expect(c != null);
        try t.expectEqual(@as(u8, 0xe8), c.?[0]);
        try t.expectEqual(@as(u8, 0xe8), c.?[1]);
        try t.expectEqual(@as(u8, 0x33), c.?[2]);
    }
}

test "fill in style= is read, not only the bare attribute" {
    // Editors write every presentation property into style="". Reading only
    // the attribute form silently painted these shapes in the default colour.
    const svg = "<svg viewBox=\"0 0 10 10\"><path style=\"fill:#e8e833\" d=\"M0 0 L10 0 L10 10 Z\"/></svg>";
    var icon = try mag.parseIconSized(t.allocator, svg, 10, 10);
    defer icon.deinit(t.allocator);
    try t.expect(icon.colors.items.len > 0);
    try t.expectEqual(@as(u8, 0x33), icon.colors.items[0].?[2]);
}

test "a fill url() is reported rather than painted flat" {
    const svg = "<svg viewBox=\"0 0 10 10\"><circle style=\"fill:url(#g)\" cx=\"5\" cy=\"5\" r=\"4\"/></svg>";
    var icon = try mag.parseIconSized(t.allocator, svg, 10, 10);
    defer icon.deinit(t.allocator);
    var found = false;
    for (icon.report.unsupported.items) |u| {
        if (std.mem.indexOf(u8, u, "paint server") != null) found = true;
    }
    try t.expect(found);
}

test "colour inherits through a group" {
    const svg = "<svg viewBox=\"0 0 20 20\"><g fill=\"#ff0000\"><path d=\"M0 0 L5 0 L5 5 Z\"/></g><path fill=\"#0000ff\" d=\"M10 10 L15 10 L15 15 Z\"/></svg>";
    var icon = try mag.parseIconSized(t.allocator, svg, 20, 20);
    defer icon.deinit(t.allocator);
    var saw_red = false;
    var saw_blue = false;
    for (icon.colors.items) |c| {
        if (c) |v| {
            if (v[0] == 255 and v[1] == 0) saw_red = true;
            if (v[2] == 255 and v[0] == 0) saw_blue = true;
        }
    }
    try t.expect(saw_red);
    try t.expect(saw_blue);
}

test "stroke colour is distinct from fill colour" {
    // A stroked outline is painted with the stroke colour. Borrowing the fill
    // colour painted the daisy's white petals in the petal-disc yellow.
    const svg =
        "<svg viewBox=\"0 0 20 20\"><path style=\"fill:none;stroke:#ffffff;stroke-width:2\" d=\"M2 10 L18 10\"/></svg>";
    var icon = try mag.parseIconSized(t.allocator, svg, 20, 20);
    defer icon.deinit(t.allocator);
    try t.expect(icon.edges.items.len > 0);
    for (icon.colors.items) |c| {
        try t.expect(c != null);
        try t.expectEqual(@as(u8, 255), c.?[0]);
        try t.expectEqual(@as(u8, 255), c.?[1]);
        try t.expectEqual(@as(u8, 255), c.?[2]);
    }
}

test "a stroke declared in style= is not dropped" {
    // fill:none plus a styled stroke looked like an empty element, so the
    // element was discarded before emitting geometry -- the daisy's petals
    // vanished entirely.
    const svg =
        "<svg viewBox=\"0 0 20 20\"><path style=\"fill:none;stroke:#ffffff;stroke-width:2\" d=\"M2 10 L18 10\"/></svg>";
    var icon = try mag.parseIconSized(t.allocator, svg, 20, 20);
    defer icon.deinit(t.allocator);
    try t.expect(icon.edges.items.len > 0);
}

test "styleProp does not match a property inside a longer name" {
    // `stroke` must not match the `stroke` inside `stroke-width`, which
    // substring matching would do and then paint the stroke with a number.
    const st = "fill:none;stroke-width:10.6;stroke:#ffffff";
    try t.expectEqualStrings("#ffffff", mag.doc.Scanner.styleProp(st, "stroke").?);
    try t.expectEqualStrings("10.6", mag.doc.Scanner.styleProp(st, "stroke-width").?);
    try t.expect(mag.doc.Scanner.styleProp("stroke-width:4", "stroke") == null);
}

// --------------------------------------------------------------- round caps
// The round cap once built its circle from `hw` centred at `from + dir*hw`.
// That is only correct when the two cap endpoints are exactly 2*hw apart; in
// general the offset sides meet the perpendicular nearer or further, so the
// centre sat off the chord's midpoint, the arc missed `to`, and the gap was
// closed with a straight chord across the end. On a real icon that chord
// measured 64px and read as a shelf dropping out of the stroke.
//
// A count going the right way proves nothing here: the first attempted fix
// closed the polyline, which moved the edge count in the correct direction
// while destroying the stroke body. Hence geometry assertions below.

test "a round cap closes on its own endpoint, with no chord across it" {
    // Deliberately diagonal: the horizontal case puts the endpoints exactly
    // 2*hw apart, which is the one geometry where the old bug was invisible.
    const svg = strokeSvg("<path d=\"M8 8 L32 30\" fill=\"none\" stroke=\"#000\" stroke-width=\"4\" stroke-linecap=\"round\"/>");
    var r = try renderStroke(t.allocator, svg);
    defer r.icon.deinit(t.allocator);
    defer t.allocator.free(r.px);
    try t.expect(r.icon.report.stroked == 1);
    try t.expect(r.icon.edges.items.len > 0);

    // The cap is an ARC of radius hw centred on the line endpoint. The bug
    // this guards put the centre at from+dir*hw instead of the midpoint
    // between the two side endpoints, which threw the arc off by ~35 units and
    // left a straight chord (the "shelf") across the end.
    //
    // Assert the property directly: every vertex of the far cap lies exactly
    // hw from (32,30). A chord has vertices inside that circle; a correct arc
    // has none.
    const ex: f32 = 32; const ey: f32 = 30; const hw: f32 = 2;

    var cap_verts: usize = 0;
    var worst: f32 = 0;
    for (r.icon.edges.items) |e| {
        for ([_]mag.Pt{ e.a, e.b }) |p| {
            // Only look at vertices in the cap neighbourhood, so body corners
            // (which are legitimately at distance > hw) are excluded.
            const dx = p.x - ex;
            const dy = p.y - ey;
            const d = @sqrt(dx * dx + dy * dy);
            if (d > hw * 2.5) continue; // outside the cap disc entirely
            cap_verts += 1;
            worst = @max(worst, @abs(d - hw));
        }
    }

    try t.expect(cap_verts > 8); // a real arc, not a stub
    // Every cap vertex sits on the circle. Allow sub-0.1 slack for flattening.
    try t.expect(worst < 0.1);
}

test "a round cap does not leak past the stroke body" {
    // The visible symptom: with a diagonal stroke, the bad chord left ink
    // below and to the right of where the cap should end.
    const svg = strokeSvg("<path d=\"M8 8 L32 30\" fill=\"none\" stroke=\"#000\" stroke-width=\"4\" stroke-linecap=\"round\"/>");
    var r = try renderStroke(t.allocator, svg);
    defer r.icon.deinit(t.allocator);
    defer t.allocator.free(r.px);
    // Far corner is empty at every cap style.
    try t.expectEqual(@as(u8, 0), alphaAt(r.px, 37, 37));
    try t.expectEqual(@as(u8, 0), alphaAt(r.px, 2, 2));
    // The body between the ends is inked.
    try t.expect(alphaAt(r.px, 20, 19) > 150);
}

fn reportsContains(icon: *const mag.Icon, needle: []const u8) bool {
    for (icon.report.unsupported.items) |u| {
        if (std.mem.indexOf(u8, u, needle) != null) return true;
    }
    return false;
}

test "a gradient stroke paints its stops, not black" {
    // Was asserted the other way round: the stroke had no paint at all, so the
    // honest behaviour was to report it. Now it resolves, and the check has to
    // be on PIXELS -- an element with fill:none and a url() stroke used to
    // render solid black, which a report-based test happily passed.
    const svg =
        "<svg viewBox=\"0 0 20 20\"><defs>" ++
        "<linearGradient id=\"g\" gradientUnits=\"userSpaceOnUse\" x1=\"2\" y1=\"0\" x2=\"18\" y2=\"0\">" ++
        "<stop offset=\"0\" stop-color=\"#ff0000\"/><stop offset=\"1\" stop-color=\"#00ff00\"/>" ++
        "</linearGradient></defs>" ++
        "<path style=\"fill:none;stroke:url(#g);stroke-width:4\" d=\"M2 10 L18 10\"/></svg>";
    var r = try renderStroke(t.allocator, svg);
    defer r.icon.deinit(t.allocator);
    defer t.allocator.free(r.px);

    // Left end near the red stop, right end near the green one. Neither is
    // black: a stroked outline with no resolved paint falls through to the
    // draw default and reads 0,0,0.
    // The stroke is 4 rows thick and the fit centres a 20-unit viewBox in
    // canvas 24, so the body sits near y=8..11 -- not the vertical middle.
    const left = pixelAt(r.px, 6, 9);
    try t.expect(left[0] > 150 and left[1] < 100);
    // Greenward: the ramp must move toward green along the stroke.
    const right = pixelAt(r.px, 16, 9);
    try t.expect(right[1] > left[1] and right[0] < left[0]);
    // Nothing black: a stroked outline with no resolved paint reads 0,0,0.
    const body = pixelAt(r.px, 12, 9);
    try t.expect(!(body[0] < 30 and body[1] < 30 and body[2] < 30));
}

test "a gradient fill is reported" {
    const svg =
        "<svg viewBox=\"0 0 20 20\"><path style=\"fill:url(#g);stroke:none\" d=\"M2 2 L18 18\"/></svg>";
    var icon = try mag.parseIconSized(t.allocator, svg, 20, 20);
    defer icon.deinit(t.allocator);
    try t.expect(reportsContains(&icon, "fill url("));
}

test "the same limitation is reported once, not once per element" {
    // Un-deduplicated, a document of gradient paths buries every other report.
    // These reference gradients that do not exist, so the report is the only
    // thing the parser can do with them.
    const svg =
        "<svg viewBox=\"0 0 20 20\">" ++
        "<path style=\"fill:url(#a);stroke:none\" d=\"M2 2 L8 8\"/>" ++
        "<path style=\"fill:url(#b);stroke:none\" d=\"M10 2 L18 8\"/>" ++
        "<path style=\"fill:url(#c);stroke:none\" d=\"M2 10 L8 18\"/>" ++
        "</svg>";
    var icon = try mag.parseIconSized(t.allocator, svg, 20, 20);
    defer icon.deinit(t.allocator);
    var n: usize = 0;
    for (icon.report.unsupported.items) |u| {
        if (std.mem.indexOf(u8, u, "paint server") != null) n += 1;
    }
    try t.expectEqual(@as(usize, 1), n);
}

const gradSvg =
    "<svg viewBox=\"0 0 20 20\">" ++
    "<defs><linearGradient id=\"g\" gradientUnits=\"userSpaceOnUse\" x1=\"0\" y1=\"0\" x2=\"20\" y2=\"0\">" ++
    "<stop offset=\"0\" style=\"stop-color:#000000;stop-opacity:1\"/>" ++
    "<stop offset=\"1\" style=\"stop-color:#ffffff;stop-opacity:1\"/>" ++
    "</linearGradient></defs>" ++
    "<rect x=\"0\" y=\"0\" width=\"20\" height=\"20\" style=\"fill:url(#g);stroke:none\"/>" ++
    "</svg>";

test "a resolvable gradient fills, and is not reported" {
    var icon = try mag.parseIconSized(t.allocator, gradSvg, 20, 20);
    defer icon.deinit(t.allocator);
    var n: usize = 0;
    for (icon.gradients.items) |g| if (g != null) { n += 1; };
    try t.expect(n > 0);
    // Resolving it means there is nothing to complain about.
    for (icon.report.unsupported.items) |u| {
        try t.expect(std.mem.indexOf(u8, u, "paint server") == null);
    }
}

test "an href chain borrows the referenced gradient's stops" {
    // Inkscape writes the stops on one <linearGradient> and the geometry on
    // another that only points at it. Missing the chain leaves a gradient with
    // no stops, which paints nothing at all.
    const svg =
        "<svg viewBox=\"0 0 20 20\">" ++
        "<defs>" ++
        "<linearGradient id=\"base\"><stop offset=\"0\" style=\"stop-color:#000000\"/>" ++
        "<stop offset=\"1\" style=\"stop-color:#ffffff\"/></linearGradient>" ++
        "<linearGradient id=\"g2\" xlink:href=\"#base\" gradientUnits=\"userSpaceOnUse\" x1=\"0\" y1=\"0\" x2=\"20\" y2=\"0\"/>" ++
        "</defs>" ++
        "<rect x=\"0\" y=\"0\" width=\"20\" height=\"20\" style=\"fill:url(#g2);stroke:none\"/>" ++
        "</svg>";
    var icon = try mag.parseIconSized(t.allocator, svg, 20, 20);
    defer icon.deinit(t.allocator);
    var found = false;
    for (icon.gradients.items) |g| {
        if (g) |gg| {
            try t.expectEqual(@as(usize, 2), gg.stops.len);
            found = true;
        }
    }
    try t.expect(found);
}

test "objectBoundingBox maps fractions of the element box" {
    // The SVG default unit, and the case that used to be refused outright.
    // x1/x2 here are 0 and 1 -- FRACTIONS, not user units -- and with no
    // gradientUnits attribute at all, so this is also the "tool omitted the
    // attribute" case that every real exporter produces.
    //
    // A rect at x=5 w=10 puts the axis at user-space x 5..15. If the
    // fractions were misread as user units the axis would be 0..1 and the
    // whole rect would land past the last stop, painting one flat colour.
    const svg =
        \\<svg viewBox="0 0 20 20">
        \\  <defs>
        \\    <linearGradient id="g" x1="0" y1="0" x2="1" y2="0">
        \\      <stop offset="0" stop-color="#ff0000"/>
        \\      <stop offset="1" stop-color="#0000ff"/>
        \\    </linearGradient>
        \\  </defs>
        \\  <rect x="5" y="5" width="10" height="10" fill="url(#g)"/>
        \\</svg>
    ;
    var icon = try mag.parseIconSized(t.allocator, svg, 20, 20);
    defer icon.deinit(t.allocator);

    // Placed gradient: axis must be the rect's box, not the viewBox.
    var g: ?mag.gradient.Linear = null;
    for (icon.gradients.items) |it| if (it) |gg| {
        g = gg;
        break;
    };
    const lin = g orelse return error.NoGradient;
    try t.expectApproxEqAbs(@as(f32, 5), lin.x0, 0.01);
    try t.expectApproxEqAbs(@as(f32, 15), lin.x1, 0.01);

    // And it actually sweeps: red near the left edge of the rect, blue near
    // the right. An inert gradient reads one colour at both samples.
    var px: [20 * 20 * 4]u8 = undefined;
    @memset(&px, 0);
    var acc: [20]f32 = undefined;
    var r = mag.Raster{ .gpa = t.allocator, .w = 20, .h = 20, .px = &px, .acc = &acc };
    defer r.xs.deinit(t.allocator);
    icon.draw(&r, .{ 0, 0, 0 });

    const left = (10 * 20 + 6) * 4;
    const right = (10 * 20 + 14) * 4;
    try t.expect(px[left] > 180 and px[left + 2] < 80);
    try t.expect(px[right + 2] > 180 and px[right] < 80);
}

test "a gradient sweeps across the shape rather than painting one colour" {
    // The end-to-end assertion. An inert gradient compiles, resolves and fills
    // with a single colour, so only the pixels can tell the difference.
    const svg = gradSvg;
    var icon = try mag.parseIconSized(t.allocator, svg, 20, 20);
    defer icon.deinit(t.allocator);
    const px = try t.allocator.alloc(u8, 20 * 20 * 4);
    defer t.allocator.free(px);
    @memset(px, 0);
    const acc = try t.allocator.alloc(f32, 20);
    defer t.allocator.free(acc);
    var r = mag.Raster{ .gpa = t.allocator, .w = 20, .h = 20, .px = px, .acc = acc };
    defer r.xs.deinit(t.allocator);
    icon.draw(&r, .{ 255, 0, 0 });

    // Circle radius 2 at x=2 and x=18, well clear of the antialiased ends.
    const left = px[(10 * 20 + 2) * 4];
    const right = px[(10 * 20 + 18) * 4];
    try t.expect(left < 40);
    try t.expect(right > 215);
}

test "a 45 degree edge antialiases to half coverage" {
    // The analytic answer for an edge crossing the pixel centre diagonally is
    // exactly 0.5. Partial coverage used to be computed correctly and then
    // discarded: the alpha channel was forced to 255 whenever the shape's
    // opacity was 1, so a black shape on a blank background came out hard
    // edged however good the sampling was.
    const svg =
        "<svg viewBox=\"0 0 32 32\">" ++
        "<rect x=\"0\" y=\"0\" width=\"32\" height=\"32\" fill=\"#ffffff\"/>" ++
        "<path d=\"M4 4 L28 28 L4 28 Z\" fill=\"#000000\"/>" ++
        "</svg>";
    var icon = try mag.parseIconSized(t.allocator, svg, 32, 32);
    defer icon.deinit(t.allocator);
    const px = try t.allocator.alloc(u8, 32 * 32 * 4);
    defer t.allocator.free(px);
    @memset(px, 255);
    const acc = try t.allocator.alloc(f32, 32);
    defer t.allocator.free(acc);
    var r = mag.Raster{ .gpa = t.allocator, .w = 32, .h = 32, .px = px, .acc = acc };
    defer r.xs.deinit(t.allocator);
    icon.draw(&r, .{ 255, 0, 0 });

    // Row 16, the pixel straddling the diagonal: half covered, so the colour
    // must land near mid grey rather than white or black.
    const o = (16 * 32 + 16) * 4;
    const v = px[o];
    try t.expect(v > 105);
    try t.expect(v < 150);
    // And it must NOT be a hard edge: the pixel inside the shape is solidly
    // black (the fill), while the one past the boundary is pure white.
    try t.expectEqual(@as(u8, 0), px[(16 * 32 + 13) * 4]);
    try t.expectEqual(@as(u8, 255), px[(16 * 32 + 18) * 4]);
}

// -------------------------------------------------------------- currentColor
// `currentColor` is the single most common paint value in icon sets: Feather,
// Lucide and Tabler all put `fill="none" stroke="currentColor"` on the root
// <svg> and expect the caller to choose. The failure this guards against is
// that `parseColor` returns null for it, and every call site treats null as
// "attribute absent" -- so a currentColor element and a colourless one are
// indistinguishable, and nothing records that the caller's colour was asked
// for. Both render wherever the fallback happens to land, which hides the bug.
test "currentColor resolves to the caller's colour, not the fallback" {
    const gpa = std.testing.allocator;
    const src =
        \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"
        \\     fill="none" stroke="currentColor" stroke-width="4">
        \\  <line x1="2" y1="8" x2="14" y2="8"/>
        \\</svg>
    ;
    var icon = try mag.parseIcon(gpa, src);
    defer icon.deinit(gpa);
    const px = try gpa.alloc(u8, 16 * 16 * 4);
    defer gpa.free(px);
    @memset(px, 0);
    const acc = try gpa.alloc(f32, 16);
    defer gpa.free(acc);
    var r = mag.Raster{ .gpa = gpa, .w = 16, .h = 16, .px = px, .acc = acc };
    defer r.xs.deinit(gpa);
    const caller: [3]u8 = .{ 0, 200, 100 };
    icon.draw(&r, caller);
    const o = (8 * 16 + 8) * 4;
    try t.expectEqual(caller[0], px[o]);
    try t.expectEqual(caller[1], px[o + 1]);
    try t.expectEqual(caller[2], px[o + 2]);
}

test "an explicitly coloured stroke ignores the caller's colour" {
    const gpa = std.testing.allocator;
    const src =
        \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"
        \\     fill="none" stroke="#ff0000" stroke-width="4">
        \\  <line x1="2" y1="8" x2="14" y2="8"/>
        \\</svg>
    ;
    var icon = try mag.parseIcon(gpa, src);
    defer icon.deinit(gpa);
    const px = try gpa.alloc(u8, 16 * 16 * 4);
    defer gpa.free(px);
    @memset(px, 0);
    const acc = try gpa.alloc(f32, 16);
    defer gpa.free(acc);
    var r = mag.Raster{ .gpa = gpa, .w = 16, .h = 16, .px = px, .acc = acc };
    defer r.xs.deinit(gpa);
    icon.draw(&r, .{ 0, 200, 100 });
    const o = (8 * 16 + 8) * 4;
    try t.expectEqual(@as(u8, 255), px[o]);
    try t.expectEqual(@as(u8, 0), px[o + 1]);
    try t.expectEqual(@as(u8, 0), px[o + 2]);
}

// -------------------------------------------------------- gradientTransform
// Both gradients in iris.svg carry a pure translate, where "applied" and
// "ignored" can look alike. A rotation about a centre point cannot: the axis
// changes direction, so reading it back proves the matrix ran in gradient
// space rather than being dropped or mis-composed with the CTM.
test "gradientTransform rotates the axis in gradient space" {
    const src =
        \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20">
        \\  <defs>
        \\    <linearGradient id="g" gradientUnits="userSpaceOnUse"
        \\                    x1="0" y1="0" x2="20" y2="0"
        \\                    gradientTransform="rotate(90 10 10)">
        \\      <stop offset="0" stop-color="#ff0000"/>
        \\      <stop offset="1" stop-color="#0000ff"/>
        \\    </linearGradient>
        \\  </defs>
        \\  <rect x="0" y="0" width="20" height="20" fill="url(#g)"/>
        \\</svg>
    ;
    var icon = try mag.parseIcon(t.allocator, src);
    defer icon.deinit(t.allocator);

    var found: ?mag.gradient.Linear = null;
    for (icon.gradients.items) |g| if (g) |gg| {
        found = gg;
        break;
    };
    const g = found orelse return error.NoGradient;

    // Declared horizontal, rotated 90 degrees about the centre: the axis must
    // come back vertical, top to bottom.
    try t.expectApproxEqAbs(@as(f32, 20), g.x0, 0.01);
    try t.expectApproxEqAbs(@as(f32, 0), g.y0, 0.01);
    try t.expectApproxEqAbs(@as(f32, 20), g.x1, 0.01);
    try t.expectApproxEqAbs(@as(f32, 20), g.y1, 0.01);
}

test "a gradient with no gradientTransform is unchanged" {
    const src =
        \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20">
        \\  <defs>
        \\    <linearGradient id="g" gradientUnits="userSpaceOnUse"
        \\                    x1="0" y1="0" x2="20" y2="0">
        \\      <stop offset="0" stop-color="#ff0000"/>
        \\      <stop offset="1" stop-color="#0000ff"/>
        \\    </linearGradient>
        \\  </defs>
        \\  <rect x="0" y="0" width="20" height="20" fill="url(#g)"/>
        \\</svg>
    ;
    var icon = try mag.parseIcon(t.allocator, src);
    defer icon.deinit(t.allocator);

    var found: ?mag.gradient.Linear = null;
    for (icon.gradients.items) |g| if (g) |gg| {
        found = gg;
        break;
    };
    const g = found orelse return error.NoGradient;
    try t.expectApproxEqAbs(@as(f32, 0), g.x0, 0.01);
    try t.expectApproxEqAbs(@as(f32, 20), g.x1, 0.01);
    try t.expectApproxEqAbs(@as(f32, 0), g.y1, 0.01);
}


// ------------------------------------------------------------ blind-spot fixture
// <line> and currentColor were both broken while the suite was green: every
// other test draws a <rect> or a <path>, and neither fixture icon uses either
// feature. These exist to fail loudly if the shape arms regress again.

test "a stroked <line> produces geometry" {
    // The bug: <line> returned before emitting anything, correct when only
    // fills existed and wrong once strokes became outlines. Asserting on the
    // edge count alone is not enough -- a stroked line's outline is the only
    // geometry it can ever have.
    const svg =
        \\<svg viewBox="0 0 20 20">
        \\  <line x1="4" y1="10" x2="16" y2="10" stroke="#000000" stroke-width="2"/>
        \\</svg>
    ;
    var icon = try mag.parseIconSized(t.allocator, svg, 20, 20);
    defer icon.deinit(t.allocator);

    try t.expect(icon.edges.items.len > 0);
    try t.expect(icon.report.stroked >= 1);

    // And it inks: a horizontal bar across the middle row, nothing at the top.
    var px: [20 * 20 * 4]u8 = undefined;
    @memset(&px, 0);
    var acc: [20]f32 = undefined;
    var r = mag.Raster{ .gpa = t.allocator, .w = 20, .h = 20, .px = &px, .acc = &acc };
    defer r.xs.deinit(t.allocator);
    icon.draw(&r, .{ 0, 0, 0 });

    try t.expect(px[(10 * 20 + 10) * 4 + 3] > 200);
    try t.expectEqual(@as(u8, 0), px[(2 * 20 + 10) * 4 + 3]);
}

test "currentColor takes the caller colour, not black" {
    // currentColor has no value inside an icon: the icon does not know the
    // page's colour, so the draw-time default supplies it. Falling through to
    // black would silently override every themed icon.
    const svg =
        \\<svg viewBox="0 0 20 20">
        \\  <rect x="4" y="4" width="12" height="12" fill="currentColor"/>
        \\</svg>
    ;
    var icon = try mag.parseIconSized(t.allocator, svg, 20, 20);
    defer icon.deinit(t.allocator);

    var px: [20 * 20 * 4]u8 = undefined;
    @memset(&px, 0);
    var acc: [20]f32 = undefined;
    var r = mag.Raster{ .gpa = t.allocator, .w = 20, .h = 20, .px = &px, .acc = &acc };
    defer r.xs.deinit(t.allocator);
    icon.draw(&r, .{ 17, 200, 90 });

    const o = (10 * 20 + 10) * 4;
    try t.expectEqual(@as(u8, 17), px[o]);
    try t.expectEqual(@as(u8, 200), px[o + 1]);
    try t.expectEqual(@as(u8, 90), px[o + 2]);
}


test "a gradient with no gradientUnits attribute uses the SVG default" {
    // gradientUnits is optional and defaults to objectBoundingBox. An SVG that
    // simply omits it is valid and box-relative; refusing it painted the shape
    // flat, which looks like a missing gradient rather than an unsupported one.
    // This test has no gradientUnits attribute anywhere.
    const svg =
        \\<svg viewBox="0 0 20 20">
        \\  <defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="0">
        \\    <stop offset="0" stop-color="#ff0000"/>
        \\    <stop offset="1" stop-color="#0000ff"/>
        \\  </linearGradient></defs>
        \\  <rect x="5" y="5" width="10" height="10" fill="url(#g)"/>
        \\</svg>
    ;
    var icon = try mag.parseIconSized(t.allocator, svg, 20, 20);
    defer icon.deinit(t.allocator);

    var g: ?mag.gradient.Linear = null;
    for (icon.gradients.items) |it| if (it) |gg| {
        g = gg;
        break;
    };
    const lin = g orelse return error.NoGradient;
    // Fractions of a rect at x=5 w=10 -> user space 5..15.
    try t.expectApproxEqAbs(@as(f32, 5), lin.x0, 0.01);
    try t.expectApproxEqAbs(@as(f32, 15), lin.x1, 0.01);
    // And it must not be reported as unsupported.
    try t.expect(!reportsContains(&icon, "objectBoundingBox"));
}
