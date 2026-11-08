//! Collects `<linearGradient>` paint servers out of the document.
//!
//! Runs as its own pass over the bytes rather than inside the main scanner.
//! Gradients live under `<defs>`, which the main scanner deliberately skips,
//! and threading a second mode through that state machine risks disturbing
//! shape handling for a feature that only ever reads declarations.

const std = @import("std");
const gradient = @import("gradient.zig");

pub const LinearDef = struct {
    id: []const u8,
    href: ?[]const u8 = null,
    x1: ?f32 = null,
    y1: ?f32 = null,
    x2: ?f32 = null,
    y2: ?f32 = null,
    user_space: bool = false,
    /// True only when `gradientUnits="userSpaceOnUse"`. The SVG default is
    /// objectBoundingBox, which cannot be resolved without the element bbox.
    units_declared_obb: bool = false,
    stops: std.ArrayList(StopDef) = .empty,
};

pub const StopDef = struct {
    offset: f32 = 0,
    color: [3]u8 = .{ 0, 0, 0 },
    opacity: f32 = 1,
};

pub const Set = struct {
    gpa: std.mem.Allocator,
    items: std.ArrayList(LinearDef) = .empty,
    /// Slices point into the source document, which outlives this Set.
    src: []const u8 = "",

    pub fn deinit(self: *Set) void {
        for (self.items.items) |*d| d.stops.deinit(self.gpa);
        self.items.deinit(self.gpa);
        self.* = .{ .gpa = self.gpa };
    }

    /// `href="#grad"` and `url(#grad)` both name a gradient with a leading
    /// `#`, while `id` never carries one. Normalising here rather than at each
    /// call site means a future reference form cannot reintroduce the
    /// mismatch -- the href chain silently resolved to nothing and the
    /// gradient rendered as the caller's default colour.
    pub fn find(self: *const Set, id_raw: []const u8) ?*const LinearDef {
        var id = std.mem.trim(u8, id_raw, " \t\r\n");
        if (id.len > 0 and id[0] == '#') id = id[1..];
        for (self.items.items) |*d| {
            if (std.mem.eql(u8, d.id, id)) return d;
        }
        return null;
    }
};

fn attr(tag: []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < tag.len) : (i += 1) {
        if (tag[i] != name[0]) continue;
        if (!std.mem.startsWith(u8, tag[i..], name)) continue;
        // Must be at a word boundary, or "x1" matches inside "max-x1".
        if (i > 0 and (std.ascii.isAlphanumeric(tag[i - 1]) or tag[i - 1] == '-')) continue;
        var j = i + name.len;
        while (j < tag.len and (tag[j] == ' ' or tag[j] == '\t' or tag[j] == '\n' or tag[j] == '\r')) j += 1;
        if (j >= tag.len or tag[j] != '=') continue;
        j += 1;
        while (j < tag.len and (tag[j] == ' ' or tag[j] == '\t')) j += 1;
        if (j >= tag.len) return null;
        if (tag[j] == '"' or tag[j] == '\'') {
            const q = tag[j];
            j += 1;
            const s = j;
            while (j < tag.len and tag[j] != q) j += 1;
            return tag[s..j];
        }
        const s = j;
        while (j < tag.len and tag[j] != '>' and tag[j] != ' ' and tag[j] != '/') j += 1;
        return tag[s..j];
    }
    return null;
}

fn num(v: []const u8) ?f32 {
    return std.fmt.parseFloat(f32, std.mem.trim(u8, v, " \t\r\n")) catch null;
}

fn colorOf(v: []const u8) ?[3]u8 {
    const t = std.mem.trim(u8, v, " \t\r\n");
    if (t.len != 7 or t[0] != '#') return null;
    const r = std.fmt.parseInt(u8, t[1..3], 16) catch return null;
    const g = std.fmt.parseInt(u8, t[3..5], 16) catch return null;
    const b = std.fmt.parseInt(u8, t[5..7], 16) catch return null;
    return .{ r, g, b };
}

/// Reads `#id` out of a `url(#id)` reference.
pub fn refId(v: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, v, " \t\r\n");
    if (!std.mem.startsWith(u8, t, "url(")) return null;
    var i: usize = 4;
    while (i < t.len and t[i] == ' ') i += 1;
    if (i >= t.len or t[i] == '\'') i += 1;
    if (i < t.len and t[i] == '#') i += 1;
    const s = i;
    while (i < t.len and t[i] != ')' and t[i] != '\'' and t[i] != ' ' and t[i] != '"') i += 1;
    if (i == s) return null;
    return t[s..i];
}

pub fn collect(gpa: std.mem.Allocator, doc: []const u8) !Set {
    var set = Set{ .gpa = gpa, .src = doc };
    errdefer set.deinit();

    var i: usize = 0;
    while (i < doc.len) {
        const lt = std.mem.indexOfScalarPos(u8, doc, i, '<') orelse break;
        const gt = std.mem.indexOfScalarPos(u8, doc, lt, '>') orelse break;
        const tag = doc[lt + 1 .. gt];
        i = gt + 1;
        if (tag.len == 0) continue;
        if (tag[0] == '/' or tag[0] == '?' or tag[0] == '!') continue;

        if (std.mem.startsWith(u8, tag, "linearGradient")) {
            const id = attr(tag, "id") orelse continue;
            var d = LinearDef{ .id = id };
            if (attr(tag, "xlink:href")) |h| d.href = refId(h) orelse h;
            if (attr(tag, "href")) |h| d.href = refId(h) orelse h;
            if (attr(tag, "x1")) |v| d.x1 = num(v);
            if (attr(tag, "y1")) |v| d.y1 = num(v);
            if (attr(tag, "x2")) |v| d.x2 = num(v);
            if (attr(tag, "y2")) |v| d.y2 = num(v);
            if (attr(tag, "gradientUnits")) |u| {
                d.user_space = std.mem.eql(u8, std.mem.trim(u8, u, " \t\r\n"), "userSpaceOnUse");
                d.units_declared_obb = !d.user_space;
            } else {
                d.units_declared_obb = true;
            }
            try set.items.append(gpa, d);
            continue;
        }

        if (std.mem.startsWith(u8, tag, "stop") and set.items.items.len > 0) {
            var s = StopDef{};
            if (attr(tag, "offset")) |v| {
                const raw = std.mem.trim(u8, v, " \t\r\n");
                if (std.mem.endsWith(u8, raw, "%")) {
                    s.offset = (num(raw[0 .. raw.len - 1]) orelse 0) / 100;
                } else s.offset = num(raw) orelse 0;
            }
            if (attr(tag, "stop-color")) |v| {
                if (colorOf(v)) |c| s.color = c;
            }
            if (attr(tag, "stop-opacity")) |v| {
                if (num(v)) |o| s.opacity = std.math.clamp(o, 0, 1);
            }
            if (attr(tag, "style")) |st| {
                var it = std.mem.splitScalar(u8, st, ';');
                while (it.next()) |decl| {
                    const colon = std.mem.indexOfScalar(u8, decl, ':') orelse continue;
                    const k = std.mem.trim(u8, decl[0..colon], " \t");
                    const v = std.mem.trim(u8, decl[colon + 1 ..], " \t\r\n");
                    if (std.mem.eql(u8, k, "stop-color")) {
                        if (colorOf(v)) |c| s.color = c;
                    } else if (std.mem.eql(u8, k, "stop-opacity")) {
                        if (num(v)) |o| s.opacity = std.math.clamp(o, 0, 1);
                    }
                }
            }
            try set.items.items[set.items.items.len - 1].stops.append(gpa, s);
        }
    }

    // Offsets are required to be ascending; a document can list them any way
    // it likes and interpolation assumes order.
    for (set.items.items) |*d| {
        std.mem.sort(StopDef, d.stops.items, {}, struct {
            fn lt(_: void, a: StopDef, b: StopDef) bool {
                return a.offset < b.offset;
            }
        }.lt);
    }
    return set;
}
