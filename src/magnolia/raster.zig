//! Scanline rasteriser: edges in, coverage blended into an RGBA buffer.

const std = @import("std");
const gradient = @import("gradient.zig");
const geom = @import("geom.zig");

const Edge = geom.Edge;

const Cross = struct { x: f32, dir: i32 };

/// How the scanline decides inside from outside.
pub const FillRule = enum { nonzero, evenodd };
fn crossLess(_: void, a: Cross, b: Cross) bool {
    return a.x < b.x;
}

fn addSpan(acc: []f32, x0: f32, x1: f32) void {
    var a = x0;
    var b = x1;
    if (b < a) {
        const t = a;
        a = b;
        b = t;
    }
    if (b <= 0) return;
    const w: f32 = @floatFromInt(acc.len);
    if (a >= w) return;
    if (a < 0) a = 0;
    if (b > w) b = w;
    const ia: usize = @intFromFloat(@floor(a));
    const ib: usize = @intFromFloat(@floor(b));
    if (ia == ib) {
        if (ia < acc.len) acc[ia] += b - a;
        return;
    }
    acc[ia] += @as(f32, @floatFromInt(ia + 1)) - a;
    var i = ia + 1;
    while (i < ib and i < acc.len) : (i += 1) acc[i] += 1;
    if (ib < acc.len) acc[ib] += b - @as(f32, @floatFromInt(ib));
}

/// Scanline rasteriser. Analytic coverage via sorted crossings, 4x vertical
/// supersampling and exact horizontal span accumulation, so edges stay smooth
/// without a full 16x sample grid.
pub const Raster = struct {
    gpa: std.mem.Allocator,
    w: usize,
    h: usize,
    px: []u8,
    acc: []f32,
    xs: std.ArrayList(Cross) = .empty,

    /// `rule` selects the winding test. Nonzero (the SVG default) counts
    /// signed crossings: a contour inside another winds to 2 and stays filled.
    /// Evenodd counts crossings mod two, so any overlap cancels and an inner
    /// contour is always a hole regardless of its direction.
    /// Same coverage pass as `fillRuleAlpha`, but the colour comes from
    /// `grad.sample` at each pixel centre instead of a constant. Coverage and
    /// alpha accumulation are identical -- only the colour source differs --
    /// so a gradient antialiases against its own edge exactly like a flat fill.
    pub fn fillRuleGradient(self: *Raster, edges: []const Edge, grad: gradient.Linear, rule: FillRule, opacity: f32) void {
        const alpha = std.math.clamp(opacity, 0, 1);
        if (alpha <= 0) return;
        self.spanPass(edges, rule, .{ .grad = .{ .grad = grad, .opacity = alpha } });
    }

    const PaintSrc = union(enum) {
        flat: struct { col: [3]u8, opacity: f32 },
        grad: struct { grad: gradient.Linear, opacity: f32 },
    };

    /// The per-span colour decision, factored out so the two fill entry points
    /// cannot drift in how they accumulate coverage or alpha.
    fn spanPass(self: *Raster, edges: []const Edge, rule: FillRule, src: PaintSrc) void {
        const SSY: usize = 4;
        const alpha: f32 = switch (src) {
            .flat => |f| f.opacity,
            .grad => |g| g.opacity,
        };
        var y: usize = 0;
        while (y < self.h) : (y += 1) {
            @memset(self.acc, 0);
            var sy: usize = 0;
            while (sy < SSY) : (sy += 1) {
                const py = @as(f32, @floatFromInt(y)) + (@as(f32, @floatFromInt(sy)) + 0.5) / @as(f32, @floatFromInt(SSY));
                self.xs.clearRetainingCapacity();
                for (edges) |e| {
                    if ((e.a.y <= py) != (e.b.y <= py)) {
                        const t = (py - e.a.y) / (e.b.y - e.a.y);
                        self.xs.append(self.gpa, .{
                            .x = e.a.x + t * (e.b.x - e.a.x),
                            .dir = if (e.b.y > e.a.y) 1 else -1,
                        }) catch return;
                    }
                }
                std.mem.sort(Cross, self.xs.items, {}, crossLess);
                switch (rule) {
                    .nonzero => {
                        var wind: i32 = 0;
                        var span: f32 = 0;
                        for (self.xs.items) |c| {
                            const before = wind;
                            wind += c.dir;
                            if (before == 0 and wind != 0) {
                                span = c.x;
                            } else if (before != 0 and wind == 0) {
                                addSpan(self.acc, span, c.x);
                            }
                        }
                    },
                    .evenodd => {
                        var n: usize = 0;
                        var span: f32 = 0;
                        while (n < self.xs.items.len) : (n += 1) {
                            if (n % 2 == 0) {
                                span = self.xs.items[n].x;
                            } else {
                                addSpan(self.acc, span, self.xs.items[n].x);
                            }
                        }
                    },
                }
            }
            const fy = @as(f32, @floatFromInt(y)) + 0.5;
            var x: usize = 0;
            while (x < self.w) : (x += 1) {
                const cov0 = std.math.clamp(self.acc[x] / @as(f32, @floatFromInt(SSY)), 0, 1);
                if (cov0 <= 0) continue;
                const cov = cov0 * alpha;
                if (cov <= 0.002) continue;
                const o = (y * self.w + x) * 4;
                const fx = @as(f32, @floatFromInt(x)) + 0.5;
                const cols: [4]f32 = switch (src) {
                    .flat => |f| .{ @floatFromInt(f.col[0]), @floatFromInt(f.col[1]), @floatFromInt(f.col[2]), 1 },
                    .grad => |g| g.grad.sample(0, fx, fy),
                };
                // A gradient stop carries its own opacity, which is PAINT
                // opacity and must not be confused with shape coverage. Using
                // the product to decide "is this pixel fully covered" forced
                // alpha to 255 wherever coverage was whole, so a stop at
                // opacity 0.86 painted the right colour and then discarded the
                // transparency it asked for.
                const paint = cols[3];
                const pcov = cov * paint;
                if (pcov <= 0.002) continue;
                inline for (0..3) |ch| {
                    const d: f32 = @floatFromInt(self.px[o + ch]);
                    self.px[o + ch] = @intFromFloat(std.math.clamp(d + (cols[ch] - d) * pcov, 0, 255));
                }
                // Alpha accumulates from coverage times paint opacity, never
                // from coverage alone: the pixel is only as opaque as what was
                // actually laid down on it.
                const eff = cov0 * paint;
                if (eff >= 1) {
                    self.px[o + 3] = 255;
                } else {
                    const a: f32 = @floatFromInt(self.px[o + 3]);
                    const na = a + (255 - a) * eff;
                    self.px[o + 3] = @intFromFloat(std.math.clamp(na, 0, 255));
                }
            }
        }
    }

    pub fn fill(self: *Raster, edges: []const Edge, col: [3]u8) void {
        self.fillRule(edges, col, .nonzero);
    }

    pub fn fillRule(self: *Raster, edges: []const Edge, col: [3]u8, rule: FillRule) void {
        self.fillRuleAlpha(edges, col, rule, 1);
    }

    /// `opacity` in 0..1, multiplied into coverage. Applied after the rule has
    /// decided which pixels are inside, so a semi-transparent shape still
    /// antialiases against its own edge exactly as an opaque one does.
    pub fn fillRuleAlpha(self: *Raster, edges: []const Edge, col: [3]u8, rule: FillRule, opacity: f32) void {
        const alpha = std.math.clamp(opacity, 0, 1);
        if (alpha <= 0) return;
        const SSY: usize = 4;
        var y: usize = 0;
        while (y < self.h) : (y += 1) {
            @memset(self.acc, 0);
            var sy: usize = 0;
            while (sy < SSY) : (sy += 1) {
                const py = @as(f32, @floatFromInt(y)) + (@as(f32, @floatFromInt(sy)) + 0.5) / @as(f32, @floatFromInt(SSY));
                self.xs.clearRetainingCapacity();
                for (edges) |e| {
                    if ((e.a.y <= py) != (e.b.y <= py)) {
                        const t = (py - e.a.y) / (e.b.y - e.a.y);
                        self.xs.append(self.gpa, .{
                            .x = e.a.x + t * (e.b.x - e.a.x),
                            .dir = if (e.b.y > e.a.y) 1 else -1,
                        }) catch return;
                    }
                }
                std.mem.sort(Cross, self.xs.items, {}, crossLess);
                switch (rule) {
                    .nonzero => {
                        var wind: i32 = 0;
                        var span: f32 = 0;
                        for (self.xs.items) |c| {
                            const before = wind;
                            wind += c.dir;
                            if (before == 0 and wind != 0) {
                                span = c.x;
                            } else if (before != 0 and wind == 0) {
                                addSpan(self.acc, span, c.x);
                            }
                        }
                    },
                    .evenodd => {
                        // Coverage is on between odd and even crossing counts.
                        // `dir` is irrelevant, which is the whole point: an
                        // inner contour is a hole whichever way it winds.
                        var n: usize = 0;
                        var span: f32 = 0;
                        while (n < self.xs.items.len) : (n += 1) {
                            if (n % 2 == 0) {
                                span = self.xs.items[n].x;
                            } else {
                                addSpan(self.acc, span, self.xs.items[n].x);
                            }
                        }
                    },
                }
            }
            var x: usize = 0;
            while (x < self.w) : (x += 1) {
                const cov0 = std.math.clamp(self.acc[x] / @as(f32, @floatFromInt(SSY)), 0, 1);
                const cov = cov0 * alpha;
                if (cov <= 0.002) continue;
                const o = (y * self.w + x) * 4;
                inline for (0..3) |ch| {
                    const d: f32 = @floatFromInt(self.px[o + ch]);
                    const s: f32 = @floatFromInt(col[ch]);
                    self.px[o + ch] = @intFromFloat(std.math.clamp(d + (s - d) * cov, 0, 255));
                }
                // Coverage drives the alpha channel; `alpha` only scales it.
                // Writing 255 whenever the shape was fully opaque threw away
                // every partial-coverage value the scanline had just computed
                // exactly, so a black shape on a blank background came out
                // hard-edged no matter how good the sampling was.
                const eff = std.math.clamp(cov0 * alpha, 0, 1);
                if (eff >= 1) {
                    self.px[o + 3] = 255;
                } else {
                    const a: f32 = @floatFromInt(self.px[o + 3]);
                    const na = a + (255 - a) * eff;
                    self.px[o + 3] = @intFromFloat(std.math.clamp(na, 0, 255));
                }
            }
        }
    }
};
