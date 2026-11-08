//! Path sink: accumulates flattened edges in device space.
//!
//! Every curve is flattened on the way in, so the rasteriser only ever sees
//! line segments. Tolerance is fixed rather than adaptive to viewport: icons
//! are drawn at small sizes and a flat 0.4 unit step is under half a pixel
//! at every size an icon is used at.

const std = @import("std");
const geom = @import("geom.zig");
const FillRule = @import("raster.zig").FillRule;
const gradient = @import("gradient.zig");

const Pt = geom.Pt;
const Edge = geom.Edge;
const Mat = geom.Mat;

/// An unresolved `objectBoundingBox` paint server.
pub const PendingGrad = struct {
    val: []const u8,
    /// The element's own CTM, captured where it is in scope. The transfer
    /// point no longer has `eff`, and recomputing it means re-walking the
    /// transform stack.
    eff: Mat,
};

pub const PathBuf = struct {
    gpa: std.mem.Allocator,
    edges: std.ArrayList(Edge) = .empty,
    /// One entry per edge, parallel to `edges`. `fill-rule` is a per-element
    /// property and elements interleave into one list, so the rule has to
    /// travel with each edge rather than with the list.
    rules: std.ArrayList(FillRule) = .empty,
    /// Parallel to `edges`; see `Icon.colors`.
    colors: std.ArrayList(?[3]u8) = .empty,
    /// Parallel to `edges`. Set when the element's fill is a paint server;
    /// `colors` stays null in that case so a caller unaware of gradients keeps
    /// its old behaviour.
    gradients: std.ArrayList(?gradient.Linear) = .empty,
    /// Parallel to `edges`; see `Icon.alphas`.
    alphas: std.ArrayList(f32) = .empty,
    /// Opacity stamped onto every edge emitted from now on. Set per element
    /// before its geometry is dispatched.
    alpha: f32 = 1,
    /// Fill colour stamped onto every edge, same lifetime as `alpha`. Null
    /// means the element declared no colour and the renderer's default stands.
    color: ?[3]u8 = null,
    /// Gradient fill stamped onto every edge, same lifetime as `color`.
    grad: ?gradient.Linear = null,
    /// A paint server that could not be placed yet, because
    /// `gradientUnits="objectBoundingBox"` needs the element's bounding box
    /// and the box is not known until the element is finished. Carried to the
    /// dispatcher, which resolves it against the completed geometry.
    ///
    /// This is a relocation of one call, not deferred painting: the resolution
    /// still happens inside the same element's dispatch, so nothing has to be
    /// remembered across elements.
    pending_grad: ?PendingGrad = null,
    /// Rule applied to edges appended from now on.
    rule: FillRule = .nonzero,
    /// Index into `edges` where each subpath begins. A stroker needs this to
    /// know where one contour ends: the edge list alone is flat, so joining
    /// `edges[i].b` to `edges[i+1].a` would weld the end of one subpath onto
    /// the start of the next. Only recorded when a subpath actually receives
    /// an edge -- a `moveTo` that is never followed by a segment leaves no
    /// empty contour behind.
    subpaths: std.ArrayList(usize) = .empty,
    /// True while the current subpath has received no segment yet. Read by
    /// `pathdata` so a closepath on an empty subpath emits nothing.
    pending: bool = true,
    m: Mat = .{},
    cur: geom.Pt = .{ .x = 0, .y = 0 },

    /// Frees the parallel edge lists. `parseIcon` transfers ownership of
    /// `edges`/`rules`/`subpaths` to the Icon and deinits nothing, so this is
    /// only for scratch buffers.
    pub fn deinit(pb: *PathBuf) void {
        pb.edges.deinit(pb.gpa);
        pb.rules.deinit(pb.gpa);
        pb.alphas.deinit(pb.gpa);
        pb.colors.deinit(pb.gpa);
        pb.gradients.deinit(pb.gpa);
        pb.subpaths.deinit(pb.gpa);
    }

    pub fn moveTo(pb: *PathBuf, p: geom.Pt) void {
        pb.cur = p;
        pb.pending = true;
    }
    pub fn segTo(pb: *PathBuf, p: geom.Pt) !void {
        if (pb.pending) {
            try pb.subpaths.append(pb.gpa, pb.edges.items.len);
            pb.pending = false;
        }
        try pb.edges.append(pb.gpa, .{ .a = pb.m.apply(pb.cur), .b = pb.m.apply(p) });
        try pb.rules.append(pb.gpa, pb.rule);
        try pb.alphas.append(pb.gpa, pb.alpha);
        try pb.colors.append(pb.gpa, pb.color);
        try pb.gradients.append(pb.gpa, pb.grad);
        pb.cur = p;
    }
    pub fn cubic(pb: *PathBuf, c1: geom.Pt, c2: geom.Pt, p: geom.Pt) !void {
        const p0 = pb.cur;
        const poly = geom.dist(p0, c1) + geom.dist(c1, c2) + geom.dist(c2, p);
        const n: usize = std.math.clamp(@as(usize, @intFromFloat(@ceil(poly / 0.4))), 4, 400);
        const nf: f32 = @floatFromInt(n);
        var k: usize = 1;
        while (k <= n) : (k += 1) {
            const t: f32 = @as(f32, @floatFromInt(k)) / nf;
            try pb.segTo(geom.cubicAt(p0, c1, c2, p, t));
        }
        pb.cur = p;
    }
    pub fn quad(pb: *PathBuf, q: geom.Pt, p: geom.Pt) !void {
        const p0 = pb.cur;
        const c1 = geom.Pt{ .x = p0.x + 2.0 / 3.0 * (q.x - p0.x), .y = p0.y + 2.0 / 3.0 * (q.y - p0.y) };
        const c2 = geom.Pt{ .x = p.x + 2.0 / 3.0 * (q.x - p.x), .y = p.y + 2.0 / 3.0 * (q.y - p.y) };
        try pb.cubic(c1, c2, p);
    }
    // SVG F.6.5 endpoint -> centre parameterisation, then cubics per segment
    pub fn arc(pb: *PathBuf, rx_in: f32, ry_in: f32, rot_deg: f32, large: bool, sweep: bool, to: geom.Pt) !void {
        const p0 = pb.cur;
        var rx = @abs(rx_in);
        var ry = @abs(ry_in);
        if (rx == 0 or ry == 0 or (p0.x == to.x and p0.y == to.y)) return pb.segTo(to);
        const phi = rot_deg * (std.math.pi / 180.0);
        const cp = @cos(phi);
        const sp = @sin(phi);
        const dx2 = (p0.x - to.x) / 2;
        const dy2 = (p0.y - to.y) / 2;
        const x1p = cp * dx2 + sp * dy2;
        const y1p = -sp * dx2 + cp * dy2;
        const lam = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry);
        if (lam > 1) {
            const s = @sqrt(lam);
            rx *= s;
            ry *= s;
        }
        const rx2 = rx * rx;
        const ry2 = ry * ry;
        const num = rx2 * ry2 - rx2 * y1p * y1p - ry2 * x1p * x1p;
        const den = rx2 * y1p * y1p + ry2 * x1p * x1p;
        var coef = @sqrt(@max(0, num / den));
        if (large == sweep) coef = -coef;
        const cxp = coef * rx * y1p / ry;
        const cyp = -coef * ry * x1p / rx;
        const cx = cp * cxp - sp * cyp + (p0.x + to.x) / 2;
        const cy = sp * cxp + cp * cyp + (p0.y + to.y) / 2;
        const ux = (x1p - cxp) / rx;
        const uy = (y1p - cyp) / ry;
        const vx = (-x1p - cxp) / rx;
        const vy = (-y1p - cyp) / ry;
        const t1 = std.math.atan2(uy, ux);
        var dt = std.math.atan2(ux * vy - uy * vx, ux * vx + uy * vy);
        if (!sweep and dt > 0) dt -= 2 * std.math.pi;
        if (sweep and dt < 0) dt += 2 * std.math.pi;
        const nseg: usize = std.math.clamp(@as(usize, @intFromFloat(@ceil(@abs(dt) / (std.math.pi / @as(f32, 2.0))))), 1, 8);
        const seg = dt / @as(f32, @floatFromInt(nseg));
        const alpha = @sin(seg) * (@sqrt(4 + 3 * std.math.pow(f32, @tan(seg / 2), 2)) - 1) / 3;
        var i: usize = 0;
        while (i < nseg) : (i += 1) {
            const ta = t1 + seg * @as(f32, @floatFromInt(i));
            const tb = ta + seg;
            const e = struct {
                fn pt(x: f32, y: f32, c: f32, s: f32, r0: f32, r1: f32, t: f32) geom.Pt {
                    return .{ .x = x + r0 * c * @cos(t) - r1 * s * @sin(t), .y = y + r0 * s * @cos(t) + r1 * c * @sin(t) };
                }
                fn dv(c: f32, s: f32, r0: f32, r1: f32, t: f32) geom.Pt {
                    return .{ .x = -r0 * c * @sin(t) - r1 * s * @cos(t), .y = -r0 * s * @sin(t) + r1 * c * @cos(t) };
                }
            };
            const pa = e.pt(cx, cy, cp, sp, rx, ry, ta);
            const pbb = e.pt(cx, cy, cp, sp, rx, ry, tb);
            const da = e.dv(cp, sp, rx, ry, ta);
            const db = e.dv(cp, sp, rx, ry, tb);
            const c1 = geom.Pt{ .x = pa.x + alpha * da.x, .y = pa.y + alpha * da.y };
            const c2 = geom.Pt{ .x = pbb.x - alpha * db.x, .y = pbb.y - alpha * db.y };
            try pb.cubic(c1, c2, pbb);
        }
        pb.cur = to;
    }
};
