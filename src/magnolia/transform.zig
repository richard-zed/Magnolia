//! Transform list parsing (`transform` attribute).

const std = @import("std");
const geom = @import("geom.zig");
const numbers = @import("numbers.zig");

const Mat = geom.Mat;
const scanNum = numbers.scanNum;
const skipSep = numbers.skipSep;

fn eqStr(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn matFor(name: []const u8, a: [6]f32, n: usize) Mat {
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

/// Parses a transform list into a single matrix, applied left to right.
pub fn parse(s: []const u8) Mat {
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
