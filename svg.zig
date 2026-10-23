const std = @import("std");

// ------------------------------------------------------------------ geometry
const Pt = struct { x: f32, y: f32 };
const Edge = struct { a: Pt, b: Pt };

const Mat = struct {
    a: f32 = 1, b: f32 = 0, c: f32 = 0, d: f32 = 1, e: f32 = 0, f: f32 = 0,
    fn apply(m: Mat, p: Pt) Pt {
        return .{ .x = m.a * p.x + m.c * p.y + m.e, .y = m.b * p.x + m.d * p.y + m.f };
    }
    fn mul(m: Mat, n: Mat) Mat { // applies n first, then m
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

fn dist(a: Pt, b: Pt) f32 {
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    return @sqrt(dx * dx + dy * dy);
}

fn cubicAt(p0: Pt, p1: Pt, p2: Pt, p3: Pt, t: f32) Pt {
    const u = 1 - t;
    const w0 = u * u * u;
    const w1 = 3 * u * u * t;
    const w2 = 3 * u * t * t;
    const w3 = t * t * t;
    return .{ .x = p0.x * w0 + p1.x * w1 + p2.x * w2 + p3.x * w3, .y = p0.y * w0 + p1.y * w1 + p2.y * w2 + p3.y * w3 };
}

// ------------------------------------------------------------------ path sink
const PathBuf = struct {
    gpa: std.mem.Allocator,
    edges: std.ArrayList(Edge) = .empty,
    m: Mat = .{},
    cur: Pt = .{ .x = 0, .y = 0 },

    fn moveTo(pb: *PathBuf, p: Pt) void {
        pb.cur = p;
    }
    fn segTo(pb: *PathBuf, p: Pt) !void {
        try pb.edges.append(pb.gpa, .{ .a = pb.m.apply(pb.cur), .b = pb.m.apply(p) });
        pb.cur = p;
    }
    fn cubic(pb: *PathBuf, c1: Pt, c2: Pt, p: Pt) !void {
        const p0 = pb.cur;
        const poly = dist(p0, c1) + dist(c1, c2) + dist(c2, p);
        const n: usize = std.math.clamp(@as(usize, @intFromFloat(@ceil(poly / 0.4))), 4, 400);
        const nf: f32 = @floatFromInt(n);
        var k: usize = 1;
        while (k <= n) : (k += 1) {
            const t: f32 = @as(f32, @floatFromInt(k)) / nf;
            try pb.segTo(cubicAt(p0, c1, c2, p, t));
        }
        pb.cur = p;
    }
    fn quad(pb: *PathBuf, q: Pt, p: Pt) !void {
        const p0 = pb.cur;
        const c1 = Pt{ .x = p0.x + 2.0 / 3.0 * (q.x - p0.x), .y = p0.y + 2.0 / 3.0 * (q.y - p0.y) };
        const c2 = Pt{ .x = p.x + 2.0 / 3.0 * (q.x - p.x), .y = p.y + 2.0 / 3.0 * (q.y - p.y) };
        try pb.cubic(c1, c2, p);
    }
    // SVG F.6.5 endpoint -> centre parameterisation, then cubics per segment
    fn arc(pb: *PathBuf, rx_in: f32, ry_in: f32, rot_deg: f32, large: bool, sweep: bool, to: Pt) !void {
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
        const nseg: usize = std.math.clamp(@as(usize, @intFromFloat(@ceil(@abs(dt) / (std.math.pi / 2)))), 1, 8);
        const seg = dt / @as(f32, @floatFromInt(nseg));
        const alpha = @sin(seg) * (@sqrt(4 + 3 * std.math.pow(f32, @tan(seg / 2), 2)) - 1) / 3;
        var i: usize = 0;
        while (i < nseg) : (i += 1) {
            const ta = t1 + seg * @as(f32, @floatFromInt(i));
            const tb = ta + seg;
            const e = struct {
                fn pt(x: f32, y: f32, c: f32, s: f32, r0: f32, r1: f32, t: f32) Pt {
                    return .{ .x = x + r0 * c * @cos(t) - r1 * s * @sin(t), .y = y + r0 * s * @cos(t) + r1 * c * @sin(t) };
                }
                fn dv(c: f32, s: f32, r0: f32, r1: f32, t: f32) Pt {
                    return .{ .x = -r0 * c * @sin(t) - r1 * s * @cos(t), .y = -r0 * s * @sin(t) + r1 * c * @cos(t) };
                }
            };
            const pa = e.pt(cx, cy, cp, sp, rx, ry, ta);
            const pbb = e.pt(cx, cy, cp, sp, rx, ry, tb);
            const da = e.dv(cp, sp, rx, ry, ta);
            const db = e.dv(cp, sp, rx, ry, tb);
            const c1 = Pt{ .x = pa.x + alpha * da.x, .y = pa.y + alpha * da.y };
            const c2 = Pt{ .x = pbb.x - alpha * db.x, .y = pbb.y - alpha * db.y };
            try pb.cubic(c1, c2, pbb);
        }
        pb.cur = to;
    }
};

// ------------------------------------------------------------------ numbers
fn isNumStart(c: u8) bool {
    return c == '-' or c == '+' or c == '.' or (c >= '0' and c <= '9');
}

fn scanNum(s: []const u8, i: *usize) ?f32 {
    var j = i.*;
    const start = j;
    if (j < s.len and (s[j] == '-' or s[j] == '+')) j += 1;
    var digits: usize = 0;
    while (j < s.len and s[j] >= '0' and s[j] <= '9') : (j += 1) digits += 1;
    if (j < s.len and s[j] == '.') {
        j += 1;
        while (j < s.len and s[j] >= '0' and s[j] <= '9') : (j += 1) digits += 1;
    }
    if (digits == 0) return null;
    if (j < s.len and (s[j] == 'e' or s[j] == 'E')) {
        var k = j + 1;
        if (k < s.len and (s[k] == '-' or s[k] == '+')) k += 1;
        var ed: usize = 0;
        while (k < s.len and s[k] >= '0' and s[k] <= '9') : (k += 1) ed += 1;
        if (ed > 0) j = k;
    }
    const body = if (s[start] == '+') s[start + 1 .. j] else s[start..j];
    const v = std.fmt.parseFloat(f32, body) catch return null;
    i.* = j;
    return v;
}

fn skipSep(s: []const u8, i: *usize) void {
    while (i.* < s.len) {
        const c = s[i.*];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == ',') i.* += 1 else break;
    }
}

// ------------------------------------------------------------------ the `d` grammar
const DStats = struct { cmds: [16]u32 = [_]u32{0} ** 16, arc_count: usize = 0 };

fn parseD(pb: *PathBuf, d: []const u8, st: *DStats) !void {
    var i: usize = 0;
    var cmd: u8 = 0;
    var startp = Pt{ .x = 0, .y = 0 };
    var last_c: ?Pt = null;
    var last_q: ?Pt = null;
    while (true) {
        skipSep(d, &i);
        if (i >= d.len) break;
        const c = d[i];
        if (std.ascii.isAlphabetic(c)) {
            cmd = c;
            i += 1;
        } else {
            if (cmd == 0) return error.BadPath;
            // implicit repeat: a second moveto pair is a lineto
            if (cmd == 'M') cmd = 'L';
            if (cmd == 'm') cmd = 'l';
        }
        const rel = std.ascii.isLower(cmd);
        const base = if (rel) pb.cur else Pt{ .x = 0, .y = 0 };
        const tag: u8 = std.ascii.toUpper(cmd);
        st.cmds[tag & 15] += 1;
        switch (tag) {
            'Z' => {
                try pb.segTo(startp);
                pb.moveTo(startp);
                last_c = null;
                last_q = null;
            },
            'M' => {
                skipSep(d, &i);
                const x = scanNum(d, &i) orelse return error.BadPath;
                skipSep(d, &i);
                const y = scanNum(d, &i) orelse return error.BadPath;
                const p = Pt{ .x = base.x + x, .y = base.y + y };
                pb.moveTo(p);
                startp = p;
                last_c = null;
                last_q = null;
            },
            'L' => {
                skipSep(d, &i);
                const x = scanNum(d, &i) orelse return error.BadPath;
                skipSep(d, &i);
                const y = scanNum(d, &i) orelse return error.BadPath;
                try pb.segTo(.{ .x = base.x + x, .y = base.y + y });
                last_c = null;
                last_q = null;
            },
            'H' => {
                skipSep(d, &i);
                const x = scanNum(d, &i) orelse return error.BadPath;
                try pb.segTo(.{ .x = base.x + x, .y = pb.cur.y });
                last_c = null;
                last_q = null;
            },
            'V' => {
                skipSep(d, &i);
                const y = scanNum(d, &i) orelse return error.BadPath;
                try pb.segTo(.{ .x = pb.cur.x, .y = base.y + y });
                last_c = null;
                last_q = null;
            },
            'C', 'S' => {
                skipSep(d, &i);
                const ax1 = scanNum(d, &i) orelse return error.BadPath;
                skipSep(d, &i);
                const ay1 = scanNum(d, &i) orelse return error.BadPath;
                skipSep(d, &i);
                const ax2 = scanNum(d, &i) orelse return error.BadPath;
                skipSep(d, &i);
                const ay2 = scanNum(d, &i) orelse return error.BadPath;
                var c2: Pt = undefined;
                var c1: Pt = undefined;
                if (tag == 'C') {
                    c1 = .{ .x = base.x + ax1, .y = base.y + ay1 };
                    c2 = .{ .x = base.x + ax2, .y = base.y + ay2 };
                } else {
                    c1 = if (last_c) |lc| Pt{ .x = 2 * pb.cur.x - lc.x, .y = 2 * pb.cur.y - lc.y } else pb.cur;
                    c2 = .{ .x = base.x + ax1, .y = base.y + ay1 };
                }
                skipSep(d, &i);
                const ex = scanNum(d, &i) orelse return error.BadPath;
                skipSep(d, &i);
                const ey = scanNum(d, &i) orelse return error.BadPath;
                try pb.cubic(c1, c2, .{ .x = base.x + ex, .y = base.y + ey });
                last_c = c2;
                last_q = null;
            },
            'Q', 'T' => {
                skipSep(d, &i);
                const x1 = scanNum(d, &i) orelse return error.BadPath;
                skipSep(d, &i);
                const y1 = scanNum(d, &i) orelse return error.BadPath;
                var q = Pt{ .x = base.x + x1, .y = base.y + y1 };
                if (tag == 'T') {
                    if (last_q) |lq| q = .{ .x = 2 * pb.cur.x - lq.x, .y = 2 * pb.cur.y - lq.y } else q = pb.cur;
                }
                var end: Pt = q;
                if (tag == 'Q') {
                    skipSep(d, &i);
                    const x2 = scanNum(d, &i) orelse return error.BadPath;
                    skipSep(d, &i);
                    const y2 = scanNum(d, &i) orelse return error.BadPath;
                    end = .{ .x = base.x + x2, .y = base.y + y2 };
                } else {
                    // T's args are the end point
                    end = Pt{ .x = base.x + x1, .y = base.y + y1 };
                }
                try pb.quad(q, end);
                last_q = q;
                last_c = null;
            },
            'A' => {
                skipSep(d, &i);
                const rx = scanNum(d, &i) orelse return error.BadPath;
                skipSep(d, &i);
                const ry = scanNum(d, &i) orelse return error.BadPath;
                skipSep(d, &i);
                const rot = scanNum(d, &i) orelse return error.BadPath;
                skipSep(d, &i);
                const la = scanNum(d, &i) orelse return error.BadPath;
                skipSep(d, &i);
                const sw = scanNum(d, &i) orelse return error.BadPath;
                skipSep(d, &i);
                const x = scanNum(d, &i) orelse return error.BadPath;
                skipSep(d, &i);
                const y = scanNum(d, &i) orelse return error.BadPath;
                try pb.arc(rx, ry, rot, la != 0, sw != 0, .{ .x = base.x + x, .y = base.y + y });
                st.arc_count += 1;
                last_c = null;
                last_q = null;
            },
            else => return error.BadPath,
        }
    }
}

test "compact numbers" {
    var i: usize = 0;
    const s = "1.5.5-3e2+4";
    try std.testing.expectEqual(@as(f32, 1.5), scanNum(s, &i).?);
    try std.testing.expectEqual(@as(f32, 0.5), scanNum(s, &i).?);
    try std.testing.expectEqual(@as(f32, -300), scanNum(s, &i).?);
    try std.testing.expectEqual(@as(f32, 4), scanNum(s, &i).?);
}

// ------------------------------------------------------------------ transforms
fn eqStr(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn matFor(name: []const u8, a: [6]f32, n: usize) Mat {
    if (eqStr(name, "matrix") and n >= 6) return .{ .a = a[0], .b = a[1], .c = a[2], .d = a[3], .e = a[4], .f = a[5] };
    if (eqStr(name, "translate")) return .{ .e = a[0], .f = if (n > 1) a[1] else 0 };
    if (eqStr(name, "scale")) {
        const sy = if (n > 1) a[1] else a[0];
        return .{ .a = a[0], .d = sy };
    }
    if (eqStr(name, "rotate")) {
        const r = a[0] * (std.math.pi / 180.0);
        const cs = @cos(r);
        const sn = @sin(r);
        const rot = Mat{ .a = cs, .b = sn, .c = -sn, .d = cs };
        if (n >= 3) {
            const cx = a[1];
            const cy = a[2];
            const to_origin = Mat{ .e = -cx, .f = -cy };
            const back = Mat{ .e = cx, .f = cy };
            return back.mul(rot).mul(to_origin);
        }
        return rot;
    }
    if (eqStr(name, "skewX")) return .{ .c = @tan(a[0] * (std.math.pi / 180.0)) };
    if (eqStr(name, "skewY")) return .{ .b = @tan(a[0] * (std.math.pi / 180.0)) };
    return .{};
}

fn parseTransform(s: []const u8) Mat {
    var m = Mat{};
    var i: usize = 0;
    while (i < s.len) {
        while (i < s.len and (s[i] == ' ' or s[i] == ',' or s[i] == '\t' or s[i] == '\n')) i += 1;
        if (i >= s.len) break;
        const ns = i;
        while (i < s.len and std.ascii.isAlphabetic(s[i])) i += 1;
        const name = s[ns..i];
        while (i < s.len and s[i] != '(') i += 1;
        if (i >= s.len) break;
        i += 1;
        var args = [_]f32{0} ** 6;
        var n: usize = 0;
        while (i < s.len and s[i] != ')') {
            skipSep(s, &i);
            if (i < s.len and s[i] == ')') break;
            if (n >= 6) break;
            if (scanNum(s, &i)) |v| {
                args[n] = v;
                n += 1;
            } else break;
        }
        while (i < s.len and s[i] != ')') i += 1;
        if (i < s.len) i += 1;
        m = m.mul(matFor(name, args, n));
    }
    return m;
}

// ------------------------------------------------------------------ document scan
const Attrs = struct {
    keys: [32][]const u8 = undefined,
    vals: [32][]const u8 = undefined,
    n: usize = 0,
    fn get(self: *const Attrs, k: []const u8) ?[]const u8 {
        var i: usize = 0;
        while (i < self.n) : (i += 1) if (eqStr(self.keys[i], k)) return self.vals[i];
        return null;
    }
    fn num(self: *const Attrs, k: []const u8, dflt: f32) f32 {
        const v = self.get(k) orelse return dflt;
        var i: usize = 0;
        return scanNum(v, &i) orelse dflt;
    }
};

const Report = struct {
    paths: usize = 0,
    shapes: usize = 0,
    skipped_subtrees: usize = 0,
    no_fill: usize = 0,
    stroked: usize = 0,
    unsupported: std.ArrayList([]const u8) = .empty,

    fn add(self: *Report, gpa: std.mem.Allocator, s: []const u8) void {
        self.unsupported.append(gpa, s) catch {};
    }
};

const Scanner = struct {
    gpa: std.mem.Allocator,
    pb: *PathBuf,
    rep: *Report,
    view: ?[4]f32 = null,
    dstat: DStats = .{},

    fn isSkipTag(name: []const u8) bool {
        const tags = [_][]const u8{ "defs", "clipPath", "mask", "symbol", "pattern", "marker", "style", "title", "desc", "metadata" };
        for (tags) |t| if (eqStr(name, t)) return true;
        return false;
    }

    fn run(self: *Scanner, doc: []const u8) !void {
        var i: usize = 0;
        var ctm = Mat{};
        var stack: std.ArrayList(Mat) = .empty;
        defer stack.deinit(self.gpa);
        var depth: usize = 0;
        var skip_depth: ?usize = null;

        while (i < doc.len) {
            const lt = std.mem.indexOfScalarPos(u8, doc, i, '<') orelse break;
            i = lt;
            if (std.mem.startsWith(u8, doc[i..], "<!--")) {
                const e = std.mem.indexOfPos(u8, doc, i + 4, "-->") orelse break;
                i = e + 3;
                continue;
            }
            if (std.mem.startsWith(u8, doc[i..], "<?")) {
                const e = std.mem.indexOfScalarPos(u8, doc, i, '>') orelse break;
                i = e + 1;
                continue;
            }
            if (std.mem.startsWith(u8, doc[i..], "<!")) {
                const e = std.mem.indexOfScalarPos(u8, doc, i, '>') orelse break;
                i = e + 1;
                continue;
            }
            if (std.mem.startsWith(u8, doc[i..], "</")) {
                const e = std.mem.indexOfScalarPos(u8, doc, i, '>') orelse break;
                i = e + 1;
                if (depth > 0) depth -= 1;
                if (stack.pop()) |v| ctm = v;
                if (skip_depth) |sd| {
                    if (depth < sd) {
                        skip_depth = null;
                        self.rep.skipped_subtrees += 1;
                    }
                }
                continue;
            }
            i += 1;
            const ns = i;
            while (i < doc.len and (std.ascii.isAlphanumeric(doc[i]) or doc[i] == ':' or doc[i] == '-' or doc[i] == '_')) i += 1;
            const name = doc[ns..i];

            var at = Attrs{};
            var selfclose = false;
            while (i < doc.len) {
                while (i < doc.len and (doc[i] == ' ' or doc[i] == '\t' or doc[i] == '\n' or doc[i] == '\r')) i += 1;
                if (i >= doc.len) break;
                if (doc[i] == '>') {
                    i += 1;
                    break;
                }
                if (doc[i] == '/') {
                    selfclose = true;
                    i += 1;
                    continue;
                }
                const ks = i;
                while (i < doc.len and doc[i] != '=' and doc[i] != '>' and doc[i] != ' ' and doc[i] != '/') i += 1;
                const key = doc[ks..i];
                while (i < doc.len and (doc[i] == ' ' or doc[i] == '\t')) i += 1;
                var val: []const u8 = "";
                if (i < doc.len and doc[i] == '=') {
                    i += 1;
                    while (i < doc.len and (doc[i] == ' ' or doc[i] == '\t')) i += 1;
                    if (i < doc.len and (doc[i] == '"' or doc[i] == '\'')) {
                        const q = doc[i];
                        i += 1;
                        const vs = i;
                        while (i < doc.len and doc[i] != q) i += 1;
                        val = doc[vs..i];
                        if (i < doc.len) i += 1;
                    } else {
                        const vs = i;
                        while (i < doc.len and doc[i] != '>' and doc[i] != ' ' and doc[i] != '/') i += 1;
                        val = doc[vs..i];
                    }
                }
                if (at.n < at.keys.len and key.len > 0) {
                    at.keys[at.n] = key;
                    at.vals[at.n] = val;
                    at.n += 1;
                }
            }

            var local = Mat{};
            if (at.get("transform")) |t| local = parseTransform(t);
            const eff = ctm.mul(local);

            if (!selfclose) {
                try stack.append(self.gpa, ctm);
                ctm = eff;
                depth += 1;
                if (skip_depth == null and isSkipTag(name)) skip_depth = depth;
            }

            if (skip_depth == null) self.element(name, &at, eff, selfclose) catch |e| {
                if (e == error.BadPath) self.rep.add(self.gpa, "path data did not parse");
            };
        }
    }

    fn setM(self: *Scanner, m: Mat) void {
        self.pb.m = m;
        self.pb.cur = .{ .x = 0, .y = 0 };
    }

    fn element(self: *Scanner, name: []const u8, at: *const Attrs, eff: Mat, selfclose: bool) !void {
        _ = selfclose;
        if (eqStr(name, "svg")) {
            if (at.get("viewBox")) |vb| {
                var arr = [_]f32{0} ** 4;
                var k: usize = 0;
                var i: usize = 0;
                while (k < 4) {
                    skipSep(vb, &i);
                    arr[k] = scanNum(vb, &i) orelse break;
                    k += 1;
                }
                if (k == 4) self.view = arr;
            }
            return;
        }
        // fill / stroke intent
        const fill_attr = at.get("fill");
        const style_attr = at.get("style");
        const fill_none = if (fill_attr) |f| eqStr(f, "none") else false;
        const fill_opacity_zero = if (at.get("fill-opacity")) |o| (blk: {
            var i: usize = 0;
            const v = scanNum(o, &i) orelse break :blk false;
            break :blk v == 0;
        }) else false;
        const style_fill_none = if (style_attr) |s| std.mem.indexOf(u8, s, "fill:none") != null else false;
        if (at.get("stroke")) |s| {
            if (!eqStr(s, "none")) {
                self.rep.stroked += 1;
                self.rep.add(self.gpa, "stroke is not implemented (fill only)");
            }
        }
        if (fill_none or fill_opacity_zero or style_fill_none) {
            self.rep.no_fill += 1;
            return;
        }

        if (eqStr(name, "path")) {
            const d = at.get("d") orelse return;
            self.setM(eff);
            try parseD(self.pb, d, &self.dstat);
            self.rep.paths += 1;
            return;
        }
        if (eqStr(name, "rect")) {
            const x = at.num("x", 0);
            const y = at.num("y", 0);
            const w = at.num("width", 0);
            const h = at.num("height", 0);
            if (w <= 0 or h <= 0) return;
            if (at.get("rx") != null or at.get("ry") != null) self.rep.add(self.gpa, "rect rx/ry ignored (square corners)");
            self.setM(eff);
            self.pb.moveTo(.{ .x = x, .y = y });
            try self.pb.segTo(.{ .x = x + w, .y = y });
            try self.pb.segTo(.{ .x = x + w, .y = y + h });
            try self.pb.segTo(.{ .x = x, .y = y + h });
            try self.pb.segTo(.{ .x = x, .y = y });
            self.rep.shapes += 1;
            return;
        }
        if (eqStr(name, "circle") or eqStr(name, "ellipse")) {
            const cx = at.num("cx", 0);
            const cy = at.num("cy", 0);
            const rx = if (eqStr(name, "circle")) at.num("r", 0) else at.num("rx", 0);
            const ry = if (eqStr(name, "circle")) at.num("r", 0) else at.num("ry", 0);
            if (rx <= 0 or ry <= 0) return;
            self.setM(eff);
            const k: f32 = 0.5522847498307936;
            const ox = k * rx;
            const oy = k * ry;
            self.pb.moveTo(.{ .x = cx + rx, .y = cy });
            try self.pb.cubic(.{ .x = cx + rx, .y = cy + oy }, .{ .x = cx + ox, .y = cy + ry }, .{ .x = cx, .y = cy + ry });
            try self.pb.cubic(.{ .x = cx - ox, .y = cy + ry }, .{ .x = cx - rx, .y = cy + oy }, .{ .x = cx - rx, .y = cy });
            try self.pb.cubic(.{ .x = cx - rx, .y = cy - oy }, .{ .x = cx - ox, .y = cy - ry }, .{ .x = cx, .y = cy - ry });
            try self.pb.cubic(.{ .x = cx + ox, .y = cy - ry }, .{ .x = cx + rx, .y = cy - oy }, .{ .x = cx + rx, .y = cy });
            self.rep.shapes += 1;
            return;
        }
        if (eqStr(name, "polygon") or eqStr(name, "polyline")) {
            const pts = at.get("points") orelse return;
            self.setM(eff);
            var i: usize = 0;
            var first = true;
            var startp = Pt{ .x = 0, .y = 0 };
            while (true) {
                skipSep(pts, &i);
                if (i >= pts.len) break;
                const x = scanNum(pts, &i) orelse break;
                skipSep(pts, &i);
                const y = scanNum(pts, &i) orelse break;
                const p = Pt{ .x = x, .y = y };
                if (first) {
                    self.pb.moveTo(p);
                    startp = p;
                    first = false;
                } else try self.pb.segTo(p);
            }
            if (eqStr(name, "polygon")) try self.pb.segTo(startp);
            self.rep.shapes += 1;
            return;
        }
        if (eqStr(name, "line")) {
            self.rep.add(self.gpa, "line is stroke-only, nothing to fill");
            return;
        }
    }
};

// ------------------------------------------------------------------ raster
const Cross = struct { x: f32, dir: i32 };
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

const Raster = struct {
    gpa: std.mem.Allocator,
    w: usize,
    h: usize,
    px: []u8,
    acc: []f32,
    xs: std.ArrayList(Cross) = .empty,

    fn fill(self: *Raster, edges: []const Edge, col: [3]u8) void {
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
            }
            var x: usize = 0;
            while (x < self.w) : (x += 1) {
                const cov = std.math.clamp(self.acc[x] / @as(f32, @floatFromInt(SSY)), 0, 1);
                if (cov <= 0.002) continue;
                const o = (y * self.w + x) * 4;
                inline for (0..3) |ch| {
                    const d: f32 = @floatFromInt(self.px[o + ch]);
                    const s: f32 = @floatFromInt(col[ch]);
                    self.px[o + ch] = @intFromFloat(std.math.clamp(d + (s - d) * cov, 0, 255));
                }
                self.px[o + 3] = 255;
            }
        }
    }
};

// ------------------------------------------------------------------ PNG (stored deflate, no compressor)
fn crc32(data: []const u8) u32 {
    var c: u32 = 0xFFFFFFFF;
    for (data) |b| {
        c ^= b;
        var k: u8 = 0;
        while (k < 8) : (k += 1) c = if (c & 1 != 0) (c >> 1) ^ 0xEDB88320 else c >> 1;
    }
    return ~c;
}

fn adler32(data: []const u8) u32 {
    var a: u32 = 1;
    var b: u32 = 0;
    for (data) |x| {
        a = (a + x) % 65521;
        b = (b + a) % 65521;
    }
    return (b << 16) | a;
}

fn putBE32(out: *std.ArrayList(u8), gpa: std.mem.Allocator, v: u32) !void {
    try out.append(gpa, @truncate(v >> 24));
    try out.append(gpa, @truncate(v >> 16));
    try out.append(gpa, @truncate(v >> 8));
    try out.append(gpa, @truncate(v));
}

fn chunk(out: *std.ArrayList(u8), gpa: std.mem.Allocator, tag: *const [4]u8, data: []const u8) !void {
    try putBE32(out, gpa, @intCast(data.len));
    const at = out.items.len;
    try out.appendSlice(gpa, tag);
    try out.appendSlice(gpa, data);
    try putBE32(out, gpa, crc32(out.items[at..]));
}

fn writePng(gpa: std.mem.Allocator, path: []const u8, w: usize, h: usize, rgba: []const u8) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try out.appendSlice(gpa, &[_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' });

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], @intCast(w), .big);
    std.mem.writeInt(u32, ihdr[4..8], @intCast(h), .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 6; // RGBA
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try chunk(&out, gpa, "IHDR", &ihdr);

    // raw scanlines with filter byte 0
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(gpa);
    var y: usize = 0;
    while (y < h) : (y += 1) {
        try raw.append(gpa, 0);
        try raw.appendSlice(gpa, rgba[y * w * 4 .. (y + 1) * w * 4]);
    }

    var z: std.ArrayList(u8) = .empty;
    defer z.deinit(gpa);
    try z.appendSlice(gpa, &[_]u8{ 0x78, 0x01 });
    var pos: usize = 0;
    while (pos < raw.items.len) {
        const n = @min(raw.items.len - pos, 65535);
        const last: u8 = if (pos + n >= raw.items.len) 1 else 0;
        try z.append(gpa, last);
        try z.append(gpa, @truncate(n));
        try z.append(gpa, @truncate(n >> 8));
        try z.append(gpa, @truncate(~n));
        try z.append(gpa, @truncate((~n) >> 8));
        try z.appendSlice(gpa, raw.items[pos .. pos + n]);
        pos += n;
    }
    try putBE32(&z, gpa, adler32(raw.items));
    try chunk(&out, gpa, "IDAT", z.items);
    try chunk(&out, gpa, "IEND", "");

    const fd = try std.posix.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    defer std.posix.close(fd);
    var off: usize = 0;
    while (off < out.items.len) {
        off += try std.posix.write(fd, out.items[off..]);
    }
}

// ------------------------------------------------------------------ main
const Icon = struct {
    edges: std.ArrayList(Edge) = .empty,
    view: ?[4]f32 = null,
};

fn readAll(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const fd = try std.posix.open(path, .{}, 0);
    defer std.posix.close(fd);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var buf: [65536]u8 = undefined;
    while (true) {
        const n = try std.posix.read(fd, &buf);
        if (n == 0) break;
        try out.appendSlice(gpa, buf[0..n]);
    }
    return out.toOwnedSlice(gpa);
}

pub fn main() !void {
    var dbg: std.heap.DebugAllocator(.{}) = .init;
    defer _ = dbg.deinit();
    const gpa = dbg.allocator();

    const in_env = std.posix.getenv("SVG_IN") orelse return error.NoInput;
    const out_path = std.posix.getenv("SVG_OUT") orelse "/tmp/svg/out.png";
    var cell: usize = 200;
    if (std.posix.getenv("SVG_CELL")) |cs| {
        cell = std.fmt.parseInt(usize, cs, 10) catch 200;
    }

    var icons: std.ArrayList(Icon) = .empty;
    defer {
        for (icons.items) |*ic| ic.edges.deinit(gpa);
        icons.deinit(gpa);
    }

    var it = std.mem.splitScalar(u8, in_env, ',');
    var reports: std.ArrayList(Report) = .empty;
    defer {
        for (reports.items) |*r| r.unsupported.deinit(gpa);
        reports.deinit(gpa);
    }

    while (it.next()) |path_raw| {
        const path = std.mem.trim(u8, path_raw, " ");
        if (path.len == 0) continue;
        const doc = try readAll(gpa, path);
        var ic = Icon{};
        var rep = Report{};
        var pb = PathBuf{ .gpa = gpa };
        var sc = Scanner{ .gpa = gpa, .pb = &pb, .rep = &rep };
        try sc.run(doc);
        ic.edges = pb.edges;
        ic.view = sc.view;
        try icons.append(gpa, ic);
        try reports.append(gpa, rep);

        const f = std.fs.path.basename(path);
        std.debug.print("{s}: paths={} shapes={} edges={} arcs={} no_fill={} stroked={}\n", .{
            f, rep.paths, rep.shapes, ic.edges.items.len, sc.dstat.arc_count, rep.no_fill, rep.stroked,
        });
        for (rep.unsupported.items) |u| std.debug.print("    ! {s}\n", .{u});
        gpa.free(doc);
    }

    const n = icons.items.len;
    if (n == 0) return error.NoInput;

    // pad = 10% of the cell, fit to the viewBox when present
    const out_w = cell * n;
    const out_h = cell;
    const px = try gpa.alloc(u8, out_w * out_h * 4);
    defer gpa.free(px);
    // light background so coverage is visible
    var k: usize = 0;
    while (k < out_w * out_h) : (k += 1) {
        px[k * 4 + 0] = 250;
        px[k * 4 + 1] = 250;
        px[k * 4 + 2] = 252;
        px[k * 4 + 3] = 255;
    }

    const acc = try gpa.alloc(f32, out_w);
    defer gpa.free(acc);
    const tmp = try gpa.alloc(Edge, 200000);
    defer gpa.free(tmp);

    const cols = [_][3]u8{ .{ 30, 30, 46 }, .{ 137, 180, 250 }, .{ 203, 166, 247 }, .{ 166, 227, 161 }, .{ 243, 139, 168 }, .{ 249, 226, 175 } };

    for (icons.items, 0..) |*ic, idx| {
        var x0: f32 = std.math.inf(f32);
        var y0: f32 = std.math.inf(f32);
        var x1: f32 = -std.math.inf(f32);
        var y1: f32 = -std.math.inf(f32);
        if (ic.view) |v| {
            x0 = v[0];
            y0 = v[1];
            x1 = v[0] + v[2];
            y1 = v[1] + v[3];
        } else for (ic.edges.items) |e| {
            inline for (.{ e.a, e.b }) |p| {
                x0 = @min(x0, p.x);
                y0 = @min(y0, p.y);
                x1 = @max(x1, p.x);
                y1 = @max(y1, p.y);
            }
        }
        const bw = x1 - x0;
        const bh = y1 - y0;
        if (bw <= 0 or bh <= 0) continue;
        const avail: f32 = @as(f32, @floatFromInt(cell)) * 0.78;
        const s = avail / @max(bw, bh);
        const tx: f32 = @as(f32, @floatFromInt(idx * cell)) + (@as(f32, @floatFromInt(cell)) - bw * s) / 2 - x0 * s;
        const ty: f32 = (@as(f32, @floatFromInt(cell)) - bh * s) / 2 - y0 * s;

        var cnt: usize = 0;
        for (ic.edges.items) |e| {
            tmp[cnt] = .{ .a = .{ .x = e.a.x * s + tx, .y = e.a.y * s + ty }, .b = .{ .x = e.b.x * s + tx, .y = e.b.y * s + ty } };
            cnt += 1;
        }

        var r = Raster{ .gpa = gpa, .w = out_w, .h = out_h, .px = px, .acc = acc };
        defer r.xs.deinit(gpa);
        r.fill(tmp[0..cnt], cols[idx % cols.len]);
    }

    try writePng(gpa, out_path, out_w, out_h, px);
    std.debug.print("wrote {s} ({}x{}, {} icons)\n", .{ out_path, out_w, out_h, n });
}
