const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sakura_dep = b.dependency("sakura", .{ .target = target, .optimize = optimize });
    const sakura = sakura_dep.module("sakura");

    const mod = b.addModule("magnolia", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run the test suite");
    test_step.dependOn(&run_tests.step);

    const sheet = b.addExecutable(.{
        .name = "sheet",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/sheet.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "magnolia", .module = mod }},
        }),
    });
    b.installArtifact(sheet);



    // Oracle: render one SVG at a fixed size for pixel comparison against a
    // reference renderer. Kept because the only trustworthy check on this
    // rasteriser is a diff, not a visual opinion.
    const oracle = b.addExecutable(.{
        .name = "oracle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/oracle.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "root.zig", .module = mod }},
        }),
    });
    b.installArtifact(oracle);

    // Pixel verification goes through Sakura, an independent decoder. Checking
    // our output with a decoder written the same session as the encoder proves
    // nothing.
    const decode = b.addExecutable(.{
        .name = "decode",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/decode.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "sakura", .module = sakura }},
        }),
    });
    b.installArtifact(decode);

    const run_sheet = b.addRunArtifact(sheet);
    run_sheet.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_sheet.addArgs(args);
    b.step("sheet", "Render SVGs to a contact sheet").dependOn(&run_sheet.step);
}
