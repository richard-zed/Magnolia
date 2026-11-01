//! Stroke-to-fill: turns a centreline into the closed outline a scanline
//! rasteriser can fill.
//!
//! A stroke is not a line with thickness. It is the region swept by a disc of
//! radius width/2 travelling along the path, and the scanline only knows how
//! to fill a region bounded by an edge loop. So the job is to build that loop:
//! offset the centreline to +r on one side and -r on the other, insert join
//! geometry at every corner so the outline stays closed, and emit an edge
//! list whose interior is the stroke.
//!
//! Deliberately unsupported, and reported rather than approximated: dashes,
//! gradient paint along the stroke, and variable width.
//!
//! Why this is not twenty lines: offsetting each segment independently and
//! joining the results gives a parallel curve whose segments have DIFFERENT
//! lengths. A convex corner leaves a gap that has to be bridged; a concave
//! corner makes the two offsets overrun into each other, which is harmless
//! because they overlap in the fill region. A miter's bridge grows as
//! 1/sin(theta/2) and tends to infinity as the corner sharpens, which is what
//! `miter_limit` clamps.

const std = @import("std");
const geom = @import("geom.zig");

const Pt = geom.Pt;
const Edge = geom.Edge;

pub const Join = enum { miter, round, bevel };
pub const Cap = enum { butt, round, square };

/// SVG's default and CSS's initial value. The spec falls back to bevel when
/// the ratio is greater than the limit, so the comparison is strict.
pub const default_miter_limit: f32 = 4.0;

/// Icon sets overwhelmingly use round joins and caps: a mitered acute corner
/// at 2px reads as a spike. Defaults follow them.
pub const Options = struct {
    width: f32 = 1.0,
    join: Join = .round,
    cap: Cap = .butt,
    miter_limit: f32 = default_miter_limit,
};

fn add(a: Pt, b: Pt) Pt {
    return .{ .x = a.x + b.x, .y = a.y + b.y };
}
fn sub(a: Pt, b: Pt) Pt {
    return .{ .x = a.x - b.x, .y = a.y - b.y };
}
fn smul(a: Pt, k: f32) Pt {
    return .{ .x = a.x * k, .y = a.y * k };
}
fn dot2(a: Pt, b: Pt) f32 {
    return a.x * b.x + a.y * b.y;
}
fn len(a: Pt) f32 {
    return @sqrt(a.x * a.x + a.y * a.y);
}
fn unit(a: Pt) ?Pt {
    const l = len(a);
    if (l <= 1e-9) return null;
    return smul(a, 1.0 / l);
}
/// Left-hand normal of a direction: rotate +90 degrees.
fn leftNormal(d: Pt) Pt {
    return .{ .x = -d.y, .y = d.x };
}

const Emitter = struct {
    out: *std.ArrayList(Edge),
    gpa: std.mem.Allocator,

    fn edge(self: Emitter, a: Pt, b: Pt) !void {
        if (@abs(a.x - b.x) < 1e-7 and @abs(a.y - b.y) < 1e-7) return;
        try self.out.append(self.gpa, .{ .a = a, .b = b });
    }
};

/// Samples an arc around `c` from angle `a0` to `a1`, in increasing angle
/// order (the caller chooses which is which). Step count follows arc length
/// so a big radius is not silently under-sampled.
fn arcPoints(
    pts: *std.ArrayList(Pt),
    gpa: std.mem.Allocator,
    c: Pt,
    r: f32,
    a0: f32,
    a1: f32,
) !void {
    // Take the SHORT way round. Forcing the sweep into [0, 2pi) makes every
    // arc counter-clockwise, so a corner whose arc runs clockwise gets
    // 2pi - theta instead of theta and the join traces the outside of the
    // whole stroke rather than the corner wedge. Measured on a right angle at
    // (10,10) r=3: the arc ran from (10,7) through (12.99,9.71) to (13,10) and
    // kept going, ~270 degrees for a 90 degree corner, leaving a spur beside
    // the joint. A join arc is never more than pi, so shortest-way is exact.
    var sweep = a1 - a0;
    if (@abs(@abs(sweep) - 2 * std.math.pi) < 1e-5) {
        // A full turn is a cap or a dot, not a join. Shortest-way would
        // collapse it to nothing.
    } else {
        while (sweep > std.math.pi) sweep -= 2 * std.math.pi;
        while (sweep < -std.math.pi) sweep += 2 * std.math.pi;
    }
    if (@abs(sweep) < 1e-6) return;
    const n: usize = std.math.clamp(@as(usize, @intFromFloat(@ceil(@abs(sweep) * r / 0.3))), 2, 400);
    var k: usize = 1;
    while (k <= n) : (k += 1) {
        const ang = a0 + sweep * (@as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(n)));
        try pts.append(gpa, .{ .x = c.x + r * @cos(ang), .y = c.y + r * @sin(ang) });
    }
}

fn angleOf(c: Pt, p: Pt) f32 {
    return std.math.atan2(p.y - c.y, p.x - c.x);
}

/// Emits a filled dot for a zero-length subpath with a round or square cap.
/// A butt cap on a degenerate subpath draws nothing, which SVG requires.
fn dot(em: Emitter, c: Pt, hw: f32, cap: Cap) !void {
    switch (cap) {
        .butt => {},
        .square => {
            const s = hw;
            try em.edge(.{ .x = c.x - s, .y = c.y - s }, .{ .x = c.x + s, .y = c.y - s });
            try em.edge(.{ .x = c.x + s, .y = c.y - s }, .{ .x = c.x + s, .y = c.y + s });
            try em.edge(.{ .x = c.x + s, .y = c.y + s }, .{ .x = c.x - s, .y = c.y + s });
            try em.edge(.{ .x = c.x - s, .y = c.y + s }, .{ .x = c.x - s, .y = c.y - s });
        },
        .round => {
            var pts: std.ArrayList(Pt) = .empty;
            defer pts.deinit(em.gpa);
            try pts.append(em.gpa, .{ .x = c.x + hw, .y = c.y });
            try arcPoints(&pts, em.gpa, c, hw, 0, 2 * std.math.pi);
            var i: usize = 0;
            while (i + 1 < pts.items.len) : (i += 1) try em.edge(pts.items[i], pts.items[i + 1]);
        },
    }
}

/// Builds the offset polyline on one side of the centreline, inserting join
/// geometry at each corner.
///
/// `sign` is +1 for the left offset and -1 for the right. The outline is walked
/// in a consistent rotational direction so it forms a simple loop.
fn offsetSide(
    out: *std.ArrayList(Pt),
    gpa: std.mem.Allocator,
    pts: []const Pt,
    dirs: []const Pt,
    segs: usize,
    closed: bool,
    hw: f32,
    opts: Options,
    sign: f32,
) !void {
    const n = pts.len;
    // Number of offset points per segment: one per segment, plus the corner
    // walk between consecutive ones.
    var s: usize = 0;
    while (s < segs) : (s += 1) {
        const d = dirs[s];
        const nrm = smul(leftNormal(d), sign * hw);
        const a = pts[s];
        const b = pts[(s + 1) % n];
        try out.append(gpa, add(a, nrm));
        try out.append(gpa, add(b, nrm));

        // Corner between this segment and the next.
        const next: ?usize = if (s + 1 < segs) s + 1 else if (closed) 0 else null;
        const nb = b;
        const next_d = if (next) |nx| dirs[nx] else continue;
        const next_nrm = smul(leftNormal(next_d), sign * hw);
        const p_in = add(nb, nrm);
        const p_out = add(nb, next_nrm);
        const cross = d.x * next_d.y - d.y * next_d.x;
        // Convex on this side when the turn is away from the offset normal.
        // On the left side (sign +1) a left turn (cross < 0) is convex; on the
        // right side it is the mirror.
        const convex = (sign > 0) == (cross < 0);
        // Both sides need a bridging edge. On the convex side the offsets
        // diverge and the bridge fills a wedge; on the concave side the
        // offset points sit either side of the corner and NOT bridging them
        // leaves the outline open, which shows up as a white spot at every
        // sharp turn. The convexity test only decides which join shape is
        // correct, never whether to emit anything.
        if (!convex) {
            // `p_in` is already the last point appended above; pushing it
            // again duplicates the vertex and knots the contour, which reads
            // as a hole where the stroke overlaps itself at an interior
            // corner. Only the far offset belongs here.
            try out.append(gpa, p_out);
            continue;
        }
        switch (opts.join) {
            .bevel => {
                try out.append(gpa, p_out);
            },
            .round => {
                try arcPoints(out, gpa, nb, hw, angleOf(nb, p_in), angleOf(nb, p_out));
            },
            .miter => {
                // Intersect the two offset lines.
                const denom = d.x * next_d.y - d.y * next_d.x;
                if (@abs(denom) < 1e-9) continue;
                const t = ((p_out.x - p_in.x) * next_d.y - (p_out.y - p_in.y) * next_d.x) / denom;
                const m = add(p_in, smul(d, t));
                const ratio = len(sub(m, nb)) / hw;
                if (ratio <= opts.miter_limit) {
                    try out.append(gpa, m);
                } else {
                    // Over the limit: bevel. Emitting nothing here (the old
                    // behaviour) left the corner open — a visible notch in
                    // the outline at every sharp point.
                    try out.append(gpa, p_in);
                    try out.append(gpa, p_out);
                }
            },
        }
    }
}

fn emitPolyline(em: Emitter, pts: []const Pt) !void {
    var i: usize = 0;
    while (i + 1 < pts.len) : (i += 1) try em.edge(pts[i], pts[i + 1]);
}

/// Bridges the two offset sides across an open end.
fn emitCap(em: Emitter, from: Pt, to: Pt, dir: Pt, hw: f32, cap: Cap) !void {
    switch (cap) {
        .butt => try em.edge(from, to),
        .square => {
            const off = smul(dir, hw);
            const a = add(from, off);
            const b = add(to, off);
            try em.edge(from, a);
            try em.edge(a, b);
            try em.edge(b, to);
        },
        .round => {
            // The two endpoints are NOT always 2*hw apart: `hw` is the scaled
            // half-width and the offset sides meet the perpendicular, so the
            // gap can be shorter. Deriving the circle from `hw` alone puts the
            // centre off the chord's midpoint and the arc misses `to`
            // entirely, leaving a long chord across the end that reads as the
            // stroke leaking past its own body. Take the circle from the two
            // points we actually have: centre = midpoint, radius = half the
            // gap. That is the only circle through both.
            const c = Pt{ .x = (from.x + to.x) * 0.5, .y = (from.y + to.y) * 0.5 };
            const rad = 0.5 * @sqrt((to.x - from.x) * (to.x - from.x) + (to.y - from.y) * (to.y - from.y));
            var pts: std.ArrayList(Pt) = .empty;
            defer pts.deinit(em.gpa);
            try pts.append(em.gpa, from);
            // A round cap is a half-circle, and the two endpoints are
            // diametrically opposite, so the sweep sign is ambiguous: a
            // shortest-way rule picks a half arbitrarily and half the time the
            // arc bulges INTO the stroke, leaving a flat-looking end. Aim it
            // explicitly at the apex c + dir*rad so the bulge is always on the
            // outside. This is why a cap needs its own entry point and cannot
            // share the join's shortest-way rule.
            const apex = angleOf(c, add(c, smul(dir, rad)));
            var da = apex - angleOf(c, from);
            while (da > std.math.pi) da -= 2 * std.math.pi;
            while (da < -std.math.pi) da += 2 * std.math.pi;
            const sweep: f32 = if (da >= 0) std.math.pi else -std.math.pi;
            const a0 = angleOf(c, from);
            var k: usize = 1;
            const n: usize = 16;
            while (k < n) : (k += 1) {
                const ang = a0 + sweep * (@as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(n)));
                try pts.append(em.gpa, .{ .x = c.x + rad * @cos(ang), .y = c.y + rad * @sin(ang) });
            }
            try pts.append(em.gpa, to);
            try emitPolyline(em, pts.items);
        },
    }
}

/// Emits the closed outline of one contour.
///
/// `closed` means the last point is joined back to the first and no caps are
/// drawn. Bad input is tolerated: repeated points are dropped, a single point
/// becomes a dot or nothing depending on the cap, and an empty contour emits
/// nothing.
pub fn contour(
    out: *std.ArrayList(Edge),
    gpa: std.mem.Allocator,
    raw: []const Pt,
    closed: bool,
    opts: Options,
) !void {
    if (opts.width <= 0) return;
    const hw = opts.width / 2;

    // Repeated points have no direction; their normal is (0,0) and would
    // collapse the offset. Real icon data contains them.
    var p: std.ArrayList(Pt) = .empty;
    defer p.deinit(gpa);
    for (raw) |q| {
        if (p.items.len > 0) {
            const last = p.items[p.items.len - 1];
            if (@abs(q.x - last.x) < 1e-7 and @abs(q.y - last.y) < 1e-7) continue;
        }
        try p.append(gpa, q);
    }
    if (closed and p.items.len > 1) {
        const f = p.items[0];
        const l = p.items[p.items.len - 1];
        if (@abs(f.x - l.x) < 1e-7 and @abs(f.y - l.y) < 1e-7) _ = p.pop();
    }
    if (p.items.len < 2) {
        if (p.items.len == 1) try dot(.{ .out = out, .gpa = gpa }, p.items[0], hw, opts.cap);
        return;
    }

    const n = p.items.len;
    const segs = if (closed) n else n - 1;

    const dirs = try gpa.alloc(Pt, segs);
    defer gpa.free(dirs);
    var s: usize = 0;
    while (s < segs) : (s += 1) {
        dirs[s] = unit(sub(p.items[(s + 1) % n], p.items[s])) orelse .{ .x = 1, .y = 0 };
    }

    var lft: std.ArrayList(Pt) = .empty;
    defer lft.deinit(gpa);
    var rgt: std.ArrayList(Pt) = .empty;
    defer rgt.deinit(gpa);
    try offsetSide(&lft, gpa, p.items, dirs, segs, closed, hw, opts, 1);
    try offsetSide(&rgt, gpa, p.items, dirs, segs, closed, hw, opts, -1);
    if (lft.items.len < 2 or rgt.items.len < 2) return;

    const em = Emitter{ .out = out, .gpa = gpa };
    // One loop: out along the left, around the far end, back along the right,
    // around the near end. A simple loop, so nonzero and evenodd agree.
    try emitPolyline(em, lft.items);
    if (closed) {
        try em.edge(lft.items[lft.items.len - 1], rgt.items[rgt.items.len - 1]);
    } else {
        try emitCap(em, lft.items[lft.items.len - 1], rgt.items[rgt.items.len - 1], dirs[segs - 1], hw, opts.cap);
    }
    var rev: std.ArrayList(Pt) = .empty;
    defer rev.deinit(gpa);
    try rev.appendSlice(gpa, rgt.items);
    std.mem.reverse(Pt, rev.items);
    try emitPolyline(em, rev.items);
    if (closed) {
        try em.edge(rev.items[rev.items.len - 1], lft.items[0]);
    } else {
        try emitCap(em, rev.items[rev.items.len - 1], lft.items[0], smul(dirs[0], -1), hw, opts.cap);
    }
}
