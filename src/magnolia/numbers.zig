//! SVG number scanning shared by path data, transforms and attributes.

const std = @import("std");

pub fn isNumStart(c: u8) bool {
    return c == '-' or c == '+' or c == '.' or (c >= '0' and c <= '9');
}

/// Scans one SVG number starting at `i.*`, advancing it. Handles sign,
/// decimal, and exponent forms.
pub fn scanNum(s: []const u8, i: *usize) ?f32 {
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

/// Skips whitespace and commas, the SVG separator set.
pub fn skipSep(s: []const u8, i: *usize) void {
    while (i.* < s.len) {
        const c = s[i.*];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == ',') i.* += 1 else break;
    }
}
