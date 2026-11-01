//! PNG encoder: stored deflate, no compression of any kind.

const std = @import("std");

pub fn crc32(data: []const u8) u32 {
    var c: u32 = 0xFFFFFFFF;
    for (data) |b| {
        c ^= b;
        var k: u8 = 0;
        while (k < 8) : (k += 1) c = if (c & 1 != 0) (c >> 1) ^ 0xEDB88320 else c >> 1;
    }
    return ~c;
}

pub fn adler32(data: []const u8) u32 {
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

/// Encodes an RGBA8 buffer as a PNG byte slice using stored (uncompressed)
/// deflate. No compressor dependency: files are larger than they need to be,
/// but the encoder is ~80 lines and cannot fail beyond allocation.
///
/// Callers own the returned slice.
pub fn encode(gpa: std.mem.Allocator, w: usize, h: usize, rgba: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
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

    return out.toOwnedSlice(gpa);
}

test "crc32 matches the zlib reference value" {
    // CRC-32 of the ASCII string "123456789" is the canonical check value.
    try std.testing.expectEqual(@as(u32, 0xCBF43926), crc32("123456789"));
}

test "adler32 matches the zlib reference value" {
    // Adler-32 of "123456789".
    try std.testing.expectEqual(@as(u32, 0x091E01DE), adler32("123456789"));
}
