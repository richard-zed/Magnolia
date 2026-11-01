//! Magnolia: SVG icon parsing and rasterisation.
//!
//! The pipeline is four pure stages plus one boundary:
//!
//!   bytes -> doc.Scanner -> []Edge -> raster.Raster -> RGBA -> png.encode
//!
//! Nothing above `io` touches the filesystem, so the stages can be driven from
//! a test, a window loop, or an app that already holds an `std.Io`.

const std = @import("std");

pub const geom = @import("magnolia/geom.zig");
pub const path = @import("magnolia/path.zig");
pub const numbers = @import("magnolia/numbers.zig");
pub const pathdata = @import("magnolia/pathdata.zig");
pub const transform = @import("magnolia/transform.zig");
pub const doc = @import("magnolia/scan.zig");
pub const raster = @import("magnolia/raster.zig");
pub const png = @import("magnolia/png.zig");
pub const io = @import("magnolia/io.zig");

pub const Pt = geom.Pt;
pub const Edge = geom.Edge;
pub const Mat = geom.Mat;
pub const PathBuf = path.PathBuf;
pub const Raster = raster.Raster;
pub const Scanner = doc.Scanner;
pub const Attrs = doc.Attrs;
pub const Report = doc.Report;
pub const Rasterizer = raster.Raster;

/// One parsed icon: flattened edges in SVG user space, plus the source
/// viewBox when the document had one.
pub const Icon = struct {
    edges: std.ArrayList(Edge) = .empty,
    /// Parallel to `edges`. An SVG can mix rules across elements, so the rule
    /// is per edge rather than per icon.
    rules: std.ArrayList(raster.FillRule) = .empty,
    /// Parallel to `edges`. Opacity is per element, so it has to travel per
    /// edge; a document mixing `opacity="0.3"` on one path and nothing on the
    /// next cannot be described by one icon-wide number.
    alphas: std.ArrayList(f32) = .empty,
    /// Indices into `edges` where each closed subpath starts. Flat for the
    /// fill path; a stroker needs it to avoid welding contours together.
    subpaths: std.ArrayList(usize) = .empty,
    view: ?[4]f32 = null,
    report: Report = .{},

    /// Number of elliptical arcs the source contained. Arcs are flattened to
    /// cubics on the way in, so nothing downstream sees them, but a nonzero
    /// count is the cheapest signal that arc handling was exercised.
    pub fn arcCount(self: *const Icon) usize {
        return self.report.arcs;
    }

    /// Fills the icon honouring each edge's own fill rule. Edges sharing a
    /// rule are drawn together; overlapping spans accumulate in the raster's
    /// coverage buffer either way, so the split is about which winding test
    /// each span used, not about paint order.
    pub fn draw(self: *const Icon, r: *raster.Raster, col: [3]u8) void {
        var i: usize = 0;
        while (i < self.edges.items.len) : (i += 1) {
            const rule: raster.FillRule = if (i < self.rules.items.len) self.rules.items[i] else .nonzero;
            const alpha: f32 = if (i < self.alphas.items.len) self.alphas.items[i] else 1;
            var j = i;
            while (j < self.edges.items.len) : (j += 1) {
                const rj: raster.FillRule = if (j < self.rules.items.len) self.rules.items[j] else .nonzero;
                const aj: f32 = if (j < self.alphas.items.len) self.alphas.items[j] else 1;
                if (rj != rule or aj != alpha) break;
            }
            r.fillRuleAlpha(self.edges.items[i..j], col, rule, alpha);
            i = j - 1;
        }
    }

    pub fn deinit(self: *Icon, gpa: std.mem.Allocator) void {
        self.edges.deinit(gpa);
        self.rules.deinit(gpa);
        self.alphas.deinit(gpa);
        self.subpaths.deinit(gpa);
        self.report.deinit(gpa);
        self.* = .{};
    }
};

/// Parses one SVG document into an `Icon`. Caller owns it, `deinit` it.
/// Parses one SVG document, mapping its viewBox onto a `tx` x `ty` output
/// extent. Geometry and stroke widths come out in output pixels, so callers
/// can rasterise straight into a frame of that size.
pub fn parseIconSized(gpa: std.mem.Allocator, bytes: []const u8, tx: f32, ty: f32) !Icon {
    return parseIconInner(gpa, bytes, tx, ty);
}

pub fn parseIcon(gpa: std.mem.Allocator, bytes: []const u8) !Icon {
    return parseIconInner(gpa, bytes, null, null);
}

fn parseIconInner(gpa: std.mem.Allocator, bytes: []const u8, tx: ?f32, ty: ?f32) !Icon {
    var pb = PathBuf{ .gpa = gpa };
    errdefer pb.edges.deinit(gpa);
    var rep = Report{};
    errdefer rep.deinit(gpa);

    var sc = Scanner{ .gpa = gpa, .pb = &pb, .rep = &rep, .tx = tx, .ty = ty };
    errdefer pb.rules.deinit(gpa);
    errdefer pb.alphas.deinit(gpa);
    errdefer pb.subpaths.deinit(gpa);
    try sc.run(bytes);

    return .{ .edges = pb.edges, .rules = pb.rules, .alphas = pb.alphas, .subpaths = pb.subpaths, .view = sc.view, .report = rep };
}

test {
    // A sibling file's tests only join the binary if something references its
    // decls, so every module is pulled in explicitly.
    _ = @import("tests.zig");
    std.testing.refAllDecls(@This());
    _ = geom;
    _ = path;
    _ = numbers;
    _ = pathdata;
    _ = transform;
    _ = doc;
    _ = raster;
    _ = png;
    _ = io;
}

test "a triangle parses to three edges" {
    const svg =
        \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path d="M12 2 L22 22 L2 22 Z"/></svg>
    ;
    var icon = try parseIcon(std.testing.allocator, svg);
    defer icon.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), icon.edges.items.len);
}

test "viewBox is captured" {
    const svg =
        \\<svg viewBox="0 0 24 24"><rect x="1" y="2" width="10" height="20"/></svg>
    ;
    var icon = try parseIcon(std.testing.allocator, svg);
    defer icon.deinit(std.testing.allocator);
    try std.testing.expect(icon.view != null);
    try std.testing.expectEqual(@as(f32, 24), icon.view.?[2]);
}

test "an unsupported element is reported, not silently dropped" {
    const svg =
        \\<svg viewBox="0 0 24 24"><text x="0" y="0">hi</text></svg>
    ;
    var icon = try parseIcon(std.testing.allocator, svg);
    defer icon.deinit(std.testing.allocator);
    try std.testing.expect(icon.report.unsupported.items.len > 0);
}
