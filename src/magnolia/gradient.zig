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

        if (self.stops.len == 0) return .{ 0, 0, 0, 0 };
        if (self.stops.len == 1) {
            const s = self.stops[0];
            return .{ @floatFromInt(s.color[0]), @floatFromInt(s.color[1]), @floatFromInt(s.color[2]), s.opacity };
        }
        var i: usize = 0;
        while (i + 1 < self.stops.len and self.stops[i + 1].offset < tt) : (i += 1) {}
        const a = self.stops[i];
        const b = self.stops[@min(i + 1, self.stops.len - 1)];
        const span = b.offset - a.offset;
        const k = if (span <= 0) 0 else std.math.clamp((tt - a.offset) / span, 0, 1);
        return .{
            std.math.lerp(@as(f32, @floatFromInt(a.color[0])), @as(f32, @floatFromInt(b.color[0])), k),
            std.math.lerp(@as(f32, @floatFromInt(a.color[1])), @as(f32, @floatFromInt(b.color[1])), k),
            std.math.lerp(@as(f32, @floatFromInt(a.color[2])), @as(f32, @floatFromInt(b.color[2])), k),
            std.math.lerp(a.opacity, b.opacity, k),
        };
    }
};
