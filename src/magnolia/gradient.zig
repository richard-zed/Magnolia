//! Linear gradients.
//!
//! Only `userSpaceOnUse` is supported. The SVG default is
//! `objectBoundingBox`, which needs the element's bounding box to place the
//! gradient -- not available where paint is resolved (the scanner sees edges
//! one at a time and the whole element is not together yet). That case is
//! reported unsupported rather than guessed at.

const std = @import("std");
const geom = @import("geom.zig");

pub const Stop = struct {
    offset: f32,
    color: [3]u8,
    opacity: f32 = 1,
};

pub const Linear = struct {
    /// Gradient axis in device space, already through the CTM. `x0,y0` is
    /// offset 0 and `x1,y1` offset 1.
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
    stops: []Stop,

    /// Colour at `t` in 0..1, interpolated between the surrounding stops.
    /// Before the first and after the last stop the end colours hold, which
    /// is `pad` spread -- the SVG default.
    pub fn sample(self: Linear, t: f32, px: f32, py: f32) [4]f32 {
        // Project the point onto the axis. Sampling from the real coordinate
        // rather than a caller-supplied t keeps the rasteriser from having to
        // know the gradient exists.
        const dx = self.x1 - self.x0;
        const dy = self.y1 - self.y0;
        const len2 = dx * dx + dy * dy;
        const u = if (len2 <= 0) 0 else ((px - self.x0) * dx + (py - self.y0) * dy) / len2;
        const tt = std.math.clamp(u, 0, 1);
        _ = t;

        return rampAt(self.stops, tt);
    }
};

/// Interpolate the stop ramp at `t` in 0..1.
///
/// Shared by both gradient kinds: the ramp is identical, and only how a pixel
/// becomes `t` differs (projection onto an axis, distance from a centre). Keeping
/// one implementation is what stops radial from drifting from linear on
/// edge cases like one stop, zero-width spans, and out-of-range t.
pub fn rampAt(stops: []const Stop, t: f32) [4]f32 {
    if (stops.len == 0) return .{ 0, 0, 0, 0 };
    if (stops.len == 1) {
        const s = stops[0];
        return .{ @floatFromInt(s.color[0]), @floatFromInt(s.color[1]), @floatFromInt(s.color[2]), s.opacity };
    }
    const tt = std.math.clamp(t, 0, 1);
    var i: usize = 0;
    while (i + 1 < stops.len and stops[i + 1].offset < tt) : (i += 1) {}
    const a = stops[i];
    const b = stops[@min(i + 1, stops.len - 1)];
    const span = b.offset - a.offset;
    const k = if (span <= 0) 0 else std.math.clamp((tt - a.offset) / span, 0, 1);
    return .{
        std.math.lerp(@as(f32, @floatFromInt(a.color[0])), @as(f32, @floatFromInt(b.color[0])), k),
        std.math.lerp(@as(f32, @floatFromInt(a.color[1])), @as(f32, @floatFromInt(b.color[1])), k),
        std.math.lerp(@as(f32, @floatFromInt(a.color[2])), @as(f32, @floatFromInt(b.color[2])), k),
        std.math.lerp(a.opacity, b.opacity, k),
    };
}

/// A radial gradient in device space.
pub const Radial = struct {
    /// Centre, already through the CTM.
    cx: f32,
    cy: f32,
    /// Radius per axis. Under objectBoundingBox the unit radius is a
    /// fraction resolved in a UNIT square and then stretched by the box,
    /// so an r=0.5 gradient on a 60x30 box is an ELLIPSE, not a circle.
    /// Equal values (userSpaceOnUse) give a circle.
    rx: f32,
    ry: f32,
    stops: []Stop,

    pub fn sample(self: Radial, px: f32, py: f32) [4]f32 {
        if (self.rx <= 0 or self.ry <= 0) return rampAt(self.stops, 1);
        const dx = (px - self.cx) / self.rx;
        const dy = (py - self.cy) / self.ry;
        const d = @sqrt(dx * dx + dy * dy);
        return rampAt(self.stops, d);
    }
};

/// Any paint server, after placement.
///
/// The stops slice lives in the Icon's arena in both cases, so identity
/// comparisons for batching work the same way whichever kind it is.
pub const Paint = union(enum) {
    linear: Linear,
    radial: Radial,

    pub fn stops(p: Paint) []Stop {
        return switch (p) {
            .linear => |g| g.stops,
            .radial => |g| g.stops,
        };
    }

    pub fn sample(p: Paint, px: f32, py: f32) [4]f32 {
        return switch (p) {
            .linear => |g| g.sample(0, px, py),
            .radial => |g| g.sample(px, py),
        };
    }
};
