//! Linear gradients.
//!
//! Only `userSpaceOnUse` is supported. The SVG default is
//! `objectBoundingBox`, which needs the element's bounding box to place the
//! gradient -- not available where paint is resolved (the scanner sees edges
//! one at a time and the whole element is not together yet). That case is
//! reported unsupported rather than guessed at.

const std = @import("std");
const geom = @import("geom.zig");

/// How a gradient behaves OUTSIDE its reference span, `spreadMethod`.
///
/// This is a fold applied to the unbounded `t` before the ramp sees it, not a
/// change to where the gradient lives -- which is why both gradient kinds
/// share one implementation.
pub const Spread = enum {
    /// Clamp to the end stops. The SVG default.
    pad,
    /// Mirror: t=1.2 reads as 0.8, t=2.5 as 0.5.
    reflect,
    /// Wrap: t=1.2 reads as 0.2.
    repeat,

    /// Map an unbounded `t` into 0..1.
    pub fn fold(self: Spread, t: f32) f32 {
        switch (self) {
            .pad => return std.math.clamp(t, 0, 1),
            .repeat => {
                // Plain fractional part. A point on a tile seam lands on the
                // LOW end (f == 0), which is what rsvg draws and what keeps
                // the tile continuous with the one below it. Snapping f to the
                // high end instead paints a black line across every seam; the
                // only hazard is f arriving as 0.9999999 when it should be 0,
                // so collapse that case rather than nudging the general one.
                // A seam takes the END of the tile below it, so an exact
                // integer reads as 1 rather than 0. The plain fractional part
                // gives 0 and paints the start colour, which put a dark line
                // across all 28 pixels of the seam diagonal in a 30x30 repeat
                // -- verified against rsvg, which draws the end colour there.
                //
                // `t != 0` keeps the origin itself at 0; without it the first
                // pixel of the tile would jump to the far end.
                const f = t - @floor(t);
                return if (f == 0 and t != 0) 1 else f;
            },
            .reflect => {
                // Period 2: 0..1 forward, 1..2 backward.
                var u = t - 2 * @floor(t / 2);
                if (u < 0) u += 2;
                if (u > 1) u = 2 - u;
                return std.math.clamp(u, 0, 1);
            },
        }
    }
};

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
    spread: Spread = .pad,
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
        _ = t;

        return rampAt(self.stops, self.spread.fold(u));
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
    spread: Spread = .pad,
    /// Focal point, the same units as cx/cy. Equal to the centre means the
    /// colour rings are concentric, which is the overwhelmingly common case
    /// and the default when fx/fy are absent.
    fx: f32,
    fy: f32,
    stops: []Stop,

    pub fn sample(self: Radial, px: f32, py: f32) [4]f32 {
        if (self.rx <= 0 or self.ry <= 0) return rampAt(self.stops, 1);

        // Concentric is the common case and must stay cheap AND exact: the
        // normalised radial distance is just the distance to the centre.
        const fx = (self.fx - self.cx) / self.rx;
        const fy = (self.fy - self.cy) / self.ry;
        if (fx == 0 and fy == 0) {
            const dx = (px - self.cx) / self.rx;
            const dy = (py - self.cy) / self.ry;
            return rampAt(self.stops, self.spread.fold(@sqrt(dx * dx + dy * dy)));
        }

        // Focal point offset. SVG 1.1 says the rings stay CIRCULAR in the
        // gradient's frame and only their centre moves, which for a pannable
        // focal is exactly the "2-centre" construction: the colour is
        // constant on circles tangent to the unit circle at the far side.
        // Solve for the parameter s of the circle through (px,py) that is
        // tangent there; s is the ramp position.
        const dx = (px - self.cx) / self.rx;
        const dy = (py - self.cy) / self.ry;
        const f2 = fx * fx + fy * fy;
        // The focal must sit strictly inside the unit circle for this
        // construction to have a finite answer; SVG clamps it to the edge.
        if (f2 >= 1) return rampAt(self.stops, self.spread.fold(@sqrt(dx * dx + dy * dy)));

        const a = dx * dx + dy * dy;
        const g = (dx * fx + dy * fy) / f2;
        const disc = g * g - (a - 1) / f2;
        if (disc < 0) return rampAt(self.stops, 1);

        // Take the root that stays outside the focal point: s is the radius
        // of the tangent circle, and it equals 1 on the unit circle itself.
        const s = g + @sqrt(disc);
        return rampAt(self.stops, self.spread.fold(s));
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
