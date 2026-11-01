//! Scanline rasteriser: edges in, coverage blended into an RGBA buffer.

const std = @import("std");
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
                // Only a fully opaque shape may claim the alpha channel; a
                // translucent one leaves whatever is beneath it visible.
                if (alpha >= 1) {
                    self.px[o + 3] = 255;
                } else {
                    const a: f32 = @floatFromInt(self.px[o + 3]);
                    const na: f32 = a + (255 - a) * cov0;
                    self.px[o + 3] = @intFromFloat(std.math.clamp(na, 0, 255));
                }
            }
        }
    }
};
