//! The filesystem boundary.
//!
//! Everything in this library is a pure function over slices: bytes in, edges
//! out, pixels out. This file is the single place that touches the OS, so the
//! rest of the tree never sees a `std.Io` handle and never sees a Zig API
//! migration of the std I/O layer again.
//!
//! Callers who already have an `std.Io` (a `runApp`-style entry point, a test
//! harness) use the functions here directly. Callers who just want the files
//! read can stay out of it entirely and hand slices to `doc` and `raster`.

const std = @import("std");
const Io = std.Io;

/// Reads a whole file into memory. Caller owns the result.
pub fn readFile(io: Io, gpa: std.mem.Allocator, path: []const u8, limit: Io.Limit) ![]u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, gpa, limit);
}

/// Writes `bytes` to `path`, creating or truncating it.
pub fn writeFile(io: Io, path: []const u8, bytes: []const u8) !void {
    const f = try Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer f.close(io);
    try f.writeStreamingAll(io, bytes);
}
