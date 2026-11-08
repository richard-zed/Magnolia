// ------------------------------------------------------------------ geometry
pub const Pt = struct { x: f32, y: f32 };
pub const Edge = struct { a: Pt, b: Pt };

/// An axis-aligned box in user space. `x1/y1` is the far corner, not a width
/// and height, so an empty box has `x1 < x0` and every consumer tests for it.
pub const Box = struct {
    x0: f32 = 0,
    y0: f32 = 0,
    x1: f32 = 0,
    y1: f32 = 0,

    pub fn isEmpty(b: Box) bool {
        return b.x1 <= b.x0 or b.y1 <= b.y0;
    }
};

pub const Mat = struct {
    a: f32 = 1,
    b: f32 = 0,
    c: f32 = 0,
    d: f32 = 1,
    e: f32 = 0,
    f: f32 = 0,
    pub fn apply(m: Mat, p: Pt) Pt {
        return .{ .x = m.a * p.x + m.c * p.y + m.e, .y = m.b * p.x + m.d * p.y + m.f };
    }
    pub fn mul(m: Mat, n: Mat) Mat { // applies n first, then m
        return .{
            .a = m.a * n.a + m.c * n.b,
            .b = m.b * n.a + m.d * n.b,
            .c = m.a * n.c + m.c * n.d,
            .d = m.b * n.c + m.d * n.d,
            .e = m.a * n.e + m.c * n.f + m.e,
            .f = m.b * n.e + m.d * n.f + m.f,
        };
    }
};

pub fn dist(a: Pt, b: Pt) f32 {
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    return @sqrt(dx * dx + dy * dy);
}

pub fn cubicAt(p0: Pt, p1: Pt, p2: Pt, p3: Pt, t: f32) Pt {
    const u = 1 - t;
    const w0 = u * u * u;
    const w1 = 3 * u * u * t;
    const w2 = 3 * u * t * t;
    const w3 = t * t * t;
    return .{ .x = p0.x * w0 + p1.x * w1 + p2.x * w2 + p3.x * w3, .y = p0.y * w0 + p1.y * w1 + p2.y * w2 + p3.y * w3 };
}
