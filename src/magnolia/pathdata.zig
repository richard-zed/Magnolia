//! SVG path data grammar (`d` attribute).

const std = @import("std");
const geom = @import("geom.zig");
const numbers = @import("numbers.zig");
const PathBuf = @import("path.zig").PathBuf;

const scanNum = numbers.scanNum;
const skipSep = numbers.skipSep;

/// Counters filled while parsing, kept for diagnostics and tests.
pub const DStats = struct { cmds: [16]u32 = [_]u32{0} ** 16, arc_count: usize = 0 };

/// Parses an SVG `d` attribute into `pb`. Implicit command repeats are
/// handled (`M` continues as `L`).
pub fn parse(pb: *PathBuf, d: []const u8, st: *DStats) !void {
    var i: usize = 0;
    var cmd: u8 = 0;
    var startp = geom.Pt{ .x = 0, .y = 0 };
    var last_c: ?geom.Pt = null;
    var last_q: ?geom.Pt = null;
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
        const base = if (rel) pb.cur else geom.Pt{ .x = 0, .y = 0 };
        const tag: u8 = std.ascii.toUpper(cmd);
        st.cmds[tag & 15] += 1;
        switch (tag) {
            'Z' => {
                // A closepath on a subpath with no segments draws nothing.
                // Emitting it anyway produces a zero-length edge, which costs
                // a scanline test and would give a stroker a degenerate join.
                if (!pb.pending) try pb.segTo(startp);
                pb.moveTo(startp);
                last_c = null;
                last_q = null;
            },
            'M' => {
                skipSep(d, &i);
                const x = scanNum(d, &i) orelse return error.BadPath;
                skipSep(d, &i);
                const y = scanNum(d, &i) orelse return error.BadPath;
                const p = geom.Pt{ .x = base.x + x, .y = base.y + y };
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
                var c2: geom.Pt = undefined;
                var c1: geom.Pt = undefined;
                if (tag == 'C') {
                    c1 = .{ .x = base.x + ax1, .y = base.y + ay1 };
                    c2 = .{ .x = base.x + ax2, .y = base.y + ay2 };
                } else {
                    c1 = if (last_c) |lc| geom.Pt{ .x = 2 * pb.cur.x - lc.x, .y = 2 * pb.cur.y - lc.y } else pb.cur;
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
                var q = geom.Pt{ .x = base.x + x1, .y = base.y + y1 };
                if (tag == 'T') {
                    if (last_q) |lq| q = .{ .x = 2 * pb.cur.x - lq.x, .y = 2 * pb.cur.y - lq.y } else q = pb.cur;
                }
                var end: geom.Pt = q;
                if (tag == 'Q') {
                    skipSep(d, &i);
                    const x2 = scanNum(d, &i) orelse return error.BadPath;
                    skipSep(d, &i);
                    const y2 = scanNum(d, &i) orelse return error.BadPath;
                    end = .{ .x = base.x + x2, .y = base.y + y2 };
                } else {
                    // T's args are the end point
                    end = geom.Pt{ .x = base.x + x1, .y = base.y + y1 };
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
